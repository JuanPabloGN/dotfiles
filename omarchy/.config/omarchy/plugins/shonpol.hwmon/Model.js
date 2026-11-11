// Pure helpers for the shonpol.hwmon widget: parsing sensors.sh output,
// deriving load and severity, and keeping the temperature history. Kept free
// of QML so tests/model.test.js can run it under node.

// Every key sensors.sh may print, with the largest value accepted for it.
// Anything else (unknown keys, non-integers, out-of-range readings) is
// dropped, so a broken or hostile sensor can never reach the UI as text.
var LIMITS = {
  cpu_temp: 150000,
  cpu_core_max: 150000,
  cpu_total: 9e15,
  cpu_idle: 9e15,
  cpu_mhz: 10000,
  mem_used_mib: 16777216,
  mem_total_mib: 16777216,
  gpu_edge: 150000,
  gpu_junction: 150000,
  gpu_mem: 150000,
  gpu_power_mw: 2000000,
  gpu_fan_rpm: 20000,
  gpu_sclk_mhz: 10000,
  gpu_sclk_min_mhz: 10000,
  gpu_busy: 100,
  gpu_vram_used_mib: 1048576,
  gpu_vram_total_mib: 1048576,
  cool_liquid: 100000,
  cool_fan_rpm: 20000,
  cool_pump_rpm: 20000,
  board_cputin: 150000,
  nvme_max: 150000
}

var MAX_LINES = 64
var MAX_LINE_LENGTH = 64

function parseReadings(raw) {
  var out = {}
  var lines = String(raw || "").split("\n", MAX_LINES)
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length > MAX_LINE_LENGTH) continue
    var match = /^([a-z_]+)=(-?\d{1,16})$/.exec(line.trim())
    if (!match || !Object.prototype.hasOwnProperty.call(LIMITS, match[1])) continue
    var value = Number(match[2])
    if (!isFinite(value) || value < 0 || value > LIMITS[match[1]]) continue
    out[match[1]] = value
  }
  return out
}

// "11th Gen Intel(R) Core(TM) i9-11900K @ 3.50GHz" -> "i9-11900K",
// "AMD Ryzen 7 5800X3D 8-Core Processor" -> "Ryzen 7 5800X3D".
function shortCpuName(raw) {
  var name = String(raw || "").split("\n")[0].replace(/^cpu_name=/, "")
  name = name.replace(/[^A-Za-z0-9 ()@.\-]/g, "").replace(/\s+/g, " ").trim()
  var intel = /\b(i[3579]-\d{4,5}[A-Z]{0,3}|Ultra [3579] \d{3}[A-Z]{0,2})\b/.exec(name)
  if (intel) return intel[1]
  var ryzen = /\b(Ryzen (?:Threadripper )?\d? ?\w+)/.exec(name)
  if (ryzen) return ryzen[1].trim()
  name = name.replace(/\((R|TM)\)/g, "").replace(/ @ .*$/, "").replace(/\s+/g, " ").trim()
  return name.length > 32 ? name.substring(0, 32) : name
}

// Percent busy between two /proc/stat samples, or -1 before the second one.
function cpuLoad(previous, current) {
  if (!previous || !current) return -1
  var total = current.cpu_total - previous.cpu_total
  var idle = current.cpu_idle - previous.cpu_idle
  if (!(total > 0) || idle < 0 || idle > total) return -1
  return Math.round(100 * (total - idle) / total)
}

// [warm, hot] thresholds in °C for each temperature reading.
var THRESHOLDS = {
  cpu_temp: [75, 85],
  cpu_core_max: [80, 90],
  gpu_edge: [75, 85],
  gpu_junction: [85, 95],
  gpu_mem: [85, 95],
  cool_liquid: [40, 45],
  board_cputin: [60, 70],
  nvme_max: [60, 70]
}

// 0 = cool, 1 = warm, 2 = hot, -1 = no reading.
function severity(key, milli) {
  var limits = THRESHOLDS[key]
  if (!limits || milli === undefined || milli === null) return -1
  var celsius = milli / 1000
  if (celsius >= limits[1]) return 2
  if (celsius >= limits[0]) return 1
  return 0
}

function overallSeverity(readings) {
  var worst = -1
  for (var key in THRESHOLDS) worst = Math.max(worst, severity(key, readings[key]))
  return worst
}

// The bar label turns the urgent colour when the CPU package or the GPU
// hotspot is hot, the same rule the old temperaturas script used.
function barAlert(readings) {
  return severity("cpu_temp", readings.cpu_temp) === 2 || severity("gpu_junction", readings.gpu_junction) === 2
}

// True when the GPU core clock sits well under its lowest DPM level, which
// only happens while GFXOFF has the core powered down between bursts.
function gpuIdle(readings) {
  var clock = readings.gpu_sclk_mhz
  var floor = readings.gpu_sclk_min_mhz
  return clock !== undefined && floor !== undefined && clock < floor * 0.9
}

function celsius(milli) {
  return milli === undefined || milli === null ? NaN : milli / 1000
}

// Fill fraction for a temperature bar running from 20 °C to `top` °C.
function tempFraction(milli, top) {
  var c = celsius(milli)
  if (!isFinite(c)) return 0
  return Math.max(0, Math.min(1, (c - 20) / (top - 20)))
}

// Append one sample, keeping the newest `limit`.
function pushHistory(history, value, limit) {
  var next = Array.isArray(history) ? history.slice(Math.max(0, history.length - limit + 1)) : []
  next.push(isFinite(value) ? value : NaN)
  return next
}
