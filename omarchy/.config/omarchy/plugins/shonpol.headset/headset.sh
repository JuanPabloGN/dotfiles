#!/bin/bash
# Back end for the shonpol.headset bar widget. The panel runs it with an argv
# list (never a shell string) and every argument is validated again here.
#
#   headset.sh status              key=value lines, parsed by Model.js
#   headset.sh sidetone <0-128>    set sidetone and remember the level
#   headset.sh preset <name>       load an EasyEffects preset that exists
#   headset.sh effects <on|off>    turn EasyEffects' global bypass off/on
#
# headsetcontrol talks HID to the receiver; with the headset switched off it
# still lists the device but battery reads "offline". The PRO X cannot report
# its sidetone level, so the last level set is kept in a state file and the
# panel re-applies it when the headset comes back on.
set -u
export LC_ALL=C

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/shonpol-headset"
sidetone_file="$state_dir/sidetone"

lock_file="${XDG_RUNTIME_DIR:-/tmp}/shonpol-headset.lock"

# A real EasyEffects instance, not just any `easyeffects` process: a CLI call
# such as `easyeffects -s` made while no instance runs becomes the instance
# itself, so only talk to it when its virtual sink exists.
ee_running() {
  pgrep -u "$(id -u)" -x easyeffects >/dev/null 2>&1 &&
    pactl list short sinks 2>/dev/null | awk -F'\t' '$2 == "easyeffects_sink" { found = 1 } END { exit !found }'
}

# One headsetcontrol at a time. On the PRO X the battery query that follows a
# sidetone write reads the write's reply instead (level 100, voltage = level
# x 200 mV, e.g. 12800 mV for 64), and the one after that may say "offline".
# So a sidetone write keeps the lock for a moment while the receiver settles.
hc() {
  (
    flock -w 8 9 || exit 1
    timeout 4 headsetcontrol "$@"
    rc=$?
    [ "${1:-}" = "-s" ] && sleep 0.6
    exit $rc
  ) 9>"$lock_file"
}

# A reading worth believing: the headset answered and, when it reports a
# voltage, it is one a single Li-ion cell can have.
battery_plausible() {
  jq -e '
    (.devices // [])[0].battery as $b
    | $b == null
      or (($b.status == "BATTERY_AVAILABLE" or $b.status == "BATTERY_CHARGING")
          and (($b.voltage_mv // 0) == 0 or ($b.voltage_mv >= 2800 and $b.voltage_mv <= 4600)))
  ' >/dev/null 2>&1
}

# Battery JSON; an "offline" or implausible reading is retried twice before
# it is believed, so one glitch does not show the headset as off or full.
battery_json() {
  local out tries=0
  while :; do
    out=$(hc -b -o json 2>/dev/null)
    tries=$((tries + 1))
    if [ -z "$out" ] || [ "$tries" -ge 3 ] || battery_plausible <<<"$out"; then
      printf '%s' "$out"
      return
    fi
    sleep 0.4
  done
}

# Preset names, one per line, from `easyeffects -p`. $1 is "Output" or "Input".
ee_presets() {
  timeout 3 easyeffects -p 2>/dev/null | awk -v want="$1 presets:" '
    /presets:$/ { on = ($0 == want); next }
    on && /^[0-9]+\t/ { sub(/^[0-9]+\t/, ""); print }
  '
}

status() {
  local json
  json=$(battery_json)
  if [ -n "$json" ] && command -v jq >/dev/null 2>&1; then
    jq -r '
      (.devices // []) as $d
      | if ($d | length) == 0 then "present=0"
        else
          "present=1",
          "battery=" + (($d[0].battery.status // "") | ascii_downcase | sub("^battery_"; "")),
          "level=" + (($d[0].battery.level // -1) | tostring),
          "voltage=" + (($d[0].battery.voltage_mv // 0) | tostring),
          "product=" + (($d[0].product // $d[0].device // "") | tostring | gsub("[\n\r]"; " ")),
          "sidetone_cap=" + (if (($d[0].capabilities_str // []) | index(["sidetone"])) then "1" else "0" end)
        end
    ' <<<"$json" 2>/dev/null || echo "present=0"
  else
    echo "present=0"
  fi

  if [ -r "$sidetone_file" ]; then
    echo "sidetone=$(head -c 8 "$sidetone_file" | tr -dc '0-9')"
  fi

  if ee_running; then
    echo "ee=1"
    case "$(timeout 3 easyeffects -b 3 2>/dev/null | tr -dc '0-9')" in
      1) echo "bypass=1" ;;
      2) echo "bypass=0" ;;
    esac
    timeout 3 easyeffects -s 2>/dev/null | sed -n \
      -e 's/^output: \(.*\)$/ee_output=\1/p' \
      -e 's/^input: \(.*\)$/ee_input=\1/p'
    ee_presets Output | sed 's/^/out_preset=/'
    ee_presets Input | sed 's/^/in_preset=/'
  else
    echo "ee=0"
  fi
}

set_sidetone() {
  local level="${1:-}"
  [[ "$level" =~ ^[0-9]{1,3}$ ]] && [ "$level" -le 128 ] || { echo "ok=0"; exit 2; }
  mkdir -p "$state_dir"
  # Remember the wanted level even if the headset is off right now: it is
  # applied when the headset reconnects.
  printf '%s\n' "$level" >"$sidetone_file"
  local out
  if out=$(hc -s "$level" 2>&1) && ! grep -qiE 'error|fail|offline|not responding' <<<"$out"; then
    echo "ok=1"
  else
    echo "ok=0"
  fi
}

load_preset() {
  local name="${1:-}"
  [ -n "$name" ] && [ "${#name}" -le 64 ] && [[ "$name" != -* ]] || { echo "ok=0"; exit 2; }
  ee_running || { echo "ok=0"; exit 1; }
  # Only names EasyEffects itself lists are accepted.
  if { ee_presets Output; ee_presets Input; } | grep -Fxq -- "$name"; then
    timeout 5 easyeffects -l "$name" >/dev/null 2>&1 && echo "ok=1" || echo "ok=0"
  else
    echo "ok=0"; exit 2
  fi
}

set_effects() {
  ee_running || { echo "ok=0"; exit 1; }
  case "${1:-}" in
    on) timeout 3 easyeffects -b 2 >/dev/null 2>&1 ;;
    off) timeout 3 easyeffects -b 1 >/dev/null 2>&1 ;;
    *) echo "ok=0"; exit 2 ;;
  esac && echo "ok=1" || echo "ok=0"
}

case "${1:-status}" in
  status) status ;;
  sidetone) set_sidetone "${2:-}" ;;
  preset) load_preset "${2:-}" ;;
  effects) set_effects "${2:-}" ;;
  *) echo "usage: headset.sh status|sidetone <0-128>|preset <name>|effects <on|off>" >&2; exit 2 ;;
esac
