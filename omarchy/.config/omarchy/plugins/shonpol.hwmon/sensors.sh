#!/bin/bash
# Hardware readings for the shonpol.hwmon bar widget.
#
#   sensors.sh          key=value lines of integers (temperatures in m°C,
#                       sizes in MiB, power in mW, clocks in MHz)
#   sensors.sh --info   cpu_name=<model name from /proc/cpuinfo>
#
# Reads only /sys and /proc and never runs anything else, so it is cheap
# enough to poll every few seconds. Sensors that are missing are left out.
shopt -s nullglob

int() { local v; [[ -r $1 ]] && read -r v < "$1" 2>/dev/null && [[ $v =~ ^-?[0-9]+$ ]] && printf '%s' "$v"; }
emit() { [[ -n $2 ]] && printf '%s=%s\n' "$1" "$2"; }

# The input file of the first <kind> sensor in <dir> whose label is <want>.
labelled() {
  local f l
  for f in "$1"/"$2"*_label; do
    read -r l < "$f" 2>/dev/null || continue
    [[ $l == "$3" ]] && { int "${f%_label}_input"; return; }
  done
}

if [[ ${1:-} == --info ]]; then
  while IFS=: read -r k v; do
    [[ $k == "model name"* ]] && { printf 'cpu_name=%s\n' "${v# }"; break; }
  done < /proc/cpuinfo
  exit 0
fi

declare -A hw
nvme=()
for h in /sys/class/hwmon/hwmon*; do
  read -r n < "$h/name" 2>/dev/null || continue
  case $n in
    nvme) nvme+=("$h") ;;
    nct67*) [[ -z ${hw[board]} ]] && hw[board]=$h ;;
    *) [[ -z ${hw[$n]} ]] && hw[$n]=$h ;;
  esac
done

# --- CPU ---------------------------------------------------------------------
if c=${hw[coretemp]}; [[ -n $c ]]; then
  emit cpu_temp "$(labelled "$c" temp "Package id 0")"
  max=""
  for f in "$c"/temp*_label; do
    read -r l < "$f"; [[ $l == Core* ]] || continue
    v=$(int "${f%_label}_input"); [[ -n $v ]] && { [[ -z $max ]] || (( v > max )); } && max=$v
  done
  emit cpu_core_max "$max"
elif c=${hw[k10temp]}; [[ -n $c ]]; then
  emit cpu_temp "$(labelled "$c" temp Tctl)"
fi

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
emit cpu_total $(( user + nice + system + idle + iowait + irq + softirq + steal ))
emit cpu_idle $(( idle + iowait ))

sum=0 count=0
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
  read -r v < "$f" && (( sum += v, count++ ))
done
(( count > 0 )) && emit cpu_mhz $(( sum / count / 1000 ))

while read -r k v _; do
  case $k in
    MemTotal:) mem_total=$v ;;
    MemAvailable:) mem_avail=$v ;;
  esac
done < /proc/meminfo
if [[ -n $mem_total && -n $mem_avail ]]; then
  emit mem_used_mib $(( (mem_total - mem_avail) / 1024 ))
  emit mem_total_mib $(( mem_total / 1024 ))
fi

# --- GPU (amdgpu) ------------------------------------------------------------
if g=${hw[amdgpu]}; [[ -n $g ]]; then
  emit gpu_edge "$(labelled "$g" temp edge)"
  emit gpu_junction "$(labelled "$g" temp junction)"
  emit gpu_mem "$(labelled "$g" temp mem)"
  p=$(int "$g/power1_average"); [[ -z $p ]] && p=$(int "$g/power1_input")
  [[ -n $p ]] && emit gpu_power_mw $(( p / 1000 ))
  emit gpu_fan_rpm "$(int "$g/fan1_input")"
  s=$(labelled "$g" freq sclk); [[ -n $s ]] && emit gpu_sclk_mhz $(( s / 1000000 ))
  # Lowest DPM level ("0: 500Mhz"). With GFXOFF an idle GPU powers its core
  # down between bursts, so sclk dips far below this; the panel reads that as idle.
  if read -r _ lvl < "$g/device/pp_dpm_sclk" 2>/dev/null; then
    lvl=${lvl%%[Mm]hz*}; [[ $lvl =~ ^[0-9]+$ ]] && emit gpu_sclk_min_mhz "$lvl"
  fi
  emit gpu_busy "$(int "$g/device/gpu_busy_percent")"
  u=$(int "$g/device/mem_info_vram_used"); t=$(int "$g/device/mem_info_vram_total")
  [[ -n $u && -n $t ]] && { emit gpu_vram_used_mib $(( u / 1048576 )); emit gpu_vram_total_mib $(( t / 1048576 )); }
fi

# --- Cooling -----------------------------------------------------------------
if k=${hw[kraken2]}; [[ -n $k ]]; then
  emit cool_liquid "$(labelled "$k" temp Coolant)"
  emit cool_fan_rpm "$(labelled "$k" fan Fan)"
  emit cool_pump_rpm "$(labelled "$k" fan Pump)"
fi
[[ -n ${hw[board]} ]] && emit board_cputin "$(labelled "${hw[board]}" temp CPUTIN)"

max=""
for h in "${nvme[@]}"; do
  v=$(labelled "$h" temp Composite); [[ -n $v ]] && { [[ -z $max ]] || (( v > max )); } && max=$v
done
emit nvme_max "$max"
exit 0
