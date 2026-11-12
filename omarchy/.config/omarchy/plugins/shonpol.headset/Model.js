// Pure helpers for the shonpol.headset widget: parse headset.sh output with a
// whitelist, and derive what the bar and panel show. Kept free of QML so
// tests/model.test.js can run it under node. Everything read from the
// script (product name, preset names) is treated as untrusted text: control
// characters are stripped, lengths and counts are bounded, and only known
// keys are kept. The QML side renders it all with Text.PlainText.

var MAX_LINES = 120
var MAX_LINE = 200
var MAX_NAME = 48
var MAX_PRESETS = 16
var SIDETONE_MAX = 128
// A single Li-ion cell; outside this a reading is garbage (see headset.sh).
var VOLTAGE_MIN = 2800
var VOLTAGE_MAX = 4600

function cleanText(value, limit) {
  var s = String(value === undefined || value === null ? "" : value)
  s = s.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").replace(/\s+/g, " ").trim()
  return s.substring(0, limit || MAX_NAME)
}

function intIn(text, lo, hi) {
  if (!/^-?\d{1,6}$/.test(text)) return undefined
  var n = parseInt(text, 10)
  return n >= lo && n <= hi ? n : undefined
}

function emptyState() {
  return {
    present: false,
    battery: "absent",     // available | charging | offline | absent
    level: -1,
    voltage: 0,            // mV, 0 when not reported
    product: "",
    sidetoneCap: false,
    sidetone: -1,          // last level set from this widget, -1 unknown
    ee: false,             // EasyEffects running
    bypass: false,
    output: "",
    input: "",
    outputPresets: [],
    inputPresets: []
  }
}

function parseStatus(raw) {
  var state = emptyState()
  var lines = String(raw === undefined || raw === null ? "" : raw).split("\n").slice(0, MAX_LINES)
  var sawPresent = false

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].substring(0, MAX_LINE)
    var eq = line.indexOf("=")
    if (eq <= 0) continue
    var key = line.substring(0, eq)
    var value = line.substring(eq + 1)

    switch (key) {
    case "present":
      if (value === "1" || value === "0") { state.present = value === "1"; sawPresent = true }
      break
    case "battery":
      if (value === "available" || value === "charging") state.battery = value
      else if (/^[a-z_]{1,24}$/.test(value)) state.battery = "offline"
      break
    case "level":
      var level = intIn(value, -1, 100)
      if (level !== undefined) state.level = level
      break
    case "voltage":
      var mv = intIn(value, 0, 100000)
      if (mv !== undefined) state.voltage = mv
      break
    case "product":
      state.product = cleanText(value, MAX_NAME)
      break
    case "sidetone_cap":
      state.sidetoneCap = value === "1"
      break
    case "sidetone":
      var st = intIn(value, 0, SIDETONE_MAX)
      if (st !== undefined) state.sidetone = st
      break
    case "ee":
      state.ee = value === "1"
      break
    case "bypass":
      state.bypass = value === "1"
      break
    case "ee_output":
      state.output = cleanText(value, MAX_NAME)
      break
    case "ee_input":
      state.input = cleanText(value, MAX_NAME)
      break
    case "out_preset":
      addPreset(state.outputPresets, value)
      break
    case "in_preset":
      addPreset(state.inputPresets, value)
      break
    }
  }

  if (!sawPresent || !state.present) {
    state.present = false
    state.battery = "absent"
    state.level = -1
  } else if (state.battery === "absent") {
    state.battery = "offline"
  }
  if (state.battery === "offline") state.level = -1
  // The PRO X answers a battery query right after a sidetone write with the
  // write's reply: level 100 and a voltage no cell has. Not a real level.
  if (state.voltage > 0 && (state.voltage < VOLTAGE_MIN || state.voltage > VOLTAGE_MAX)) state.level = -1
  if (!state.ee) {
    state.bypass = false
    state.output = ""
    state.input = ""
    state.outputPresets = []
    state.inputPresets = []
  }
  return state
}

function addPreset(list, value) {
  var name = cleanText(value, MAX_NAME)
  if (name === "" || list.length >= MAX_PRESETS || list.indexOf(name) !== -1) return
  list.push(name)
}

// The headset answers (battery or charging), so sidetone can be set.
function online(state) {
  return !!state && (state.battery === "available" || state.battery === "charging")
}

// "PRO X Wireless Gaming Headset" -> "PRO X Wireless"
function shortProduct(product) {
  var s = cleanText(product, MAX_NAME).replace(/\s*(gaming\s+)?headset$/i, "").trim()
  return s
}

// `format` renders the level (the panel passes Commons.I18n.formatNumber so
// it follows the language's digits); plain String() when left out.
function barText(state, vertical, format) {
  if (!online(state)) return "󰟎"
  var fmt = typeof format === "function" ? format : String
  var charging = state.battery === "charging"
  var hasLevel = state.level >= 0
  var level = hasLevel ? fmt(state.level) : ""
  if (vertical) return charging ? "󱐋" : (hasLevel ? "󰋋\n" + level : "󰋋")
  if (charging) return hasLevel ? "󰋋 󱐋 " + level + "%" : "󰋋 󱐋"
  return hasLevel ? "󰋋 " + level + "%" : "󰋋"
}

function isLow(state, threshold) {
  return !!state && state.battery === "available" && state.level >= 0 && state.level <= threshold
}

// Low-battery notice fires once per discharge: when the level first reaches
// the threshold; it re-arms after charging or once the level is back above
// threshold + 5 (so one noisy reading does not notify twice).
function lowBatteryStep(notified, state, threshold) {
  if (isLow(state, threshold)) return { notify: !notified, notified: true }
  if (!state || state.battery === "charging" || (state.battery === "available" && state.level > threshold + 5))
    return { notify: false, notified: false }
  return { notify: false, notified: notified }
}

// True on the poll where the headset goes from off/absent to on.
function cameOnline(previous, next) {
  return !!previous && !online(previous) && online(next)
}

function clampSidetone(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 0
  return Math.max(0, Math.min(SIDETONE_MAX, n))
}

function batteryFraction(state) {
  return state && state.level >= 0 ? Math.max(0, Math.min(1, state.level / 100)) : 0
}

// Next preset after `current` in `list` (wraps). Empty string when none.
function cyclePreset(list, current, direction) {
  if (!list || list.length === 0) return ""
  var i = list.indexOf(current)
  if (i === -1) return list[direction < 0 ? list.length - 1 : 0]
  var n = list.length
  return list[(i + (direction < 0 ? -1 : 1) + n) % n]
}
