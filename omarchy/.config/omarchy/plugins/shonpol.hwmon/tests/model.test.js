// Run with: node tests/model.test.js
// Loads Model.js the way QML does (plain script, top-level functions) and
// checks parsing, sanitizing and the derived values.
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")
const { execFileSync } = require("child_process")

const dir = path.join(__dirname, "..")
const M = {}
vm.createContext(M)
vm.runInContext(fs.readFileSync(path.join(dir, "Model.js"), "utf8"), M)

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}

test("parses integer readings", () => {
  const r = M.parseReadings("cpu_temp=48000\ngpu_edge=47000\ngpu_busy=19\n")
  assert.deepStrictEqual({ ...r }, { cpu_temp: 48000, gpu_edge: 47000, gpu_busy: 19 })
})

test("drops markup-shaped values", () => {
  const r = M.parseReadings('cpu_temp=<img src="https://example.invalid/tracker">\ngpu_edge=47000<b>\ncool_liquid=<b>1</b>')
  assert.deepStrictEqual({ ...r }, {})
})

test("drops markup-shaped keys and unknown keys", () => {
  const r = M.parseReadings('<img src=x>=1\nevil_key=5\n__proto__=1\nconstructor=2\ncpu_mhz=4500')
  assert.deepStrictEqual({ ...r }, { cpu_mhz: 4500 })
})

test("drops out-of-range and negative values", () => {
  const r = M.parseReadings("gpu_busy=101\ncpu_temp=-5\ncpu_mhz=99999999\ncool_pump_rpm=2290")
  assert.deepStrictEqual({ ...r }, { cool_pump_rpm: 2290 })
})

test("bounds line length and line count", () => {
  const long = "cpu_temp=" + "1".repeat(200)
  assert.deepStrictEqual({ ...M.parseReadings(long) }, {})
  const many = Array(500).fill("cpu_mhz=1").join("\n") + "\ncpu_temp=40000"
  assert.strictEqual(M.parseReadings(many).cpu_temp, undefined)
})

test("short CPU names", () => {
  assert.strictEqual(M.shortCpuName("cpu_name=11th Gen Intel(R) Core(TM) i9-11900K @ 3.50GHz\n"), "i9-11900K")
  assert.strictEqual(M.shortCpuName("cpu_name=Intel(R) Core(TM) i5-14600KF"), "i5-14600KF")
  assert.strictEqual(M.shortCpuName("cpu_name=AMD Ryzen 7 5800X3D 8-Core Processor"), "Ryzen 7 5800X3D")
})

test("CPU name strips markup characters and is bounded", () => {
  const name = M.shortCpuName('cpu_name=<img src="https://example.invalid/t">' + "x".repeat(100))
  assert.ok(!/[<>"=\/]/.test(name), name)
  assert.ok(name.length <= 32)
})

test("CPU load from two samples", () => {
  assert.strictEqual(M.cpuLoad(null, { cpu_total: 100, cpu_idle: 50 }), -1)
  assert.strictEqual(M.cpuLoad({ cpu_total: 1000, cpu_idle: 900 }, { cpu_total: 1100, cpu_idle: 975 }), 25)
  assert.strictEqual(M.cpuLoad({ cpu_total: 1000, cpu_idle: 900 }, { cpu_total: 1000, cpu_idle: 900 }), -1)
})

test("severity and bar alert", () => {
  assert.strictEqual(M.severity("cpu_temp", 60000), 0)
  assert.strictEqual(M.severity("cpu_temp", 76000), 1)
  assert.strictEqual(M.severity("cpu_temp", 85000), 2)
  assert.strictEqual(M.severity("cpu_temp", undefined), -1)
  assert.strictEqual(M.barAlert({ cpu_temp: 60000, gpu_junction: 95000 }), true)
  assert.strictEqual(M.barAlert({ cpu_temp: 84000, gpu_junction: 94000 }), false)
  assert.strictEqual(M.overallSeverity({ cool_liquid: 41000 }), 1)
})

test("GPU idle when clock is under the lowest DPM level", () => {
  assert.strictEqual(M.gpuIdle({ gpu_sclk_mhz: 11, gpu_sclk_min_mhz: 500 }), true)
  assert.strictEqual(M.gpuIdle({ gpu_sclk_mhz: 498, gpu_sclk_min_mhz: 500 }), false)
  assert.strictEqual(M.gpuIdle({ gpu_sclk_mhz: 2400, gpu_sclk_min_mhz: 500 }), false)
  assert.strictEqual(M.gpuIdle({ gpu_sclk_mhz: 11 }), false)
})

test("history keeps the newest samples", () => {
  let h = []
  for (let i = 0; i < 100; i++) h = M.pushHistory(h, i, 60)
  assert.strictEqual(h.length, 60)
  assert.strictEqual(h[0], 40)
  assert.strictEqual(h[59], 99)
})

test("sensors.sh output parses completely on this machine", () => {
  const raw = execFileSync("bash", [path.join(dir, "sensors.sh")], { encoding: "utf8" })
  const lines = raw.trim().split("\n")
  const parsed = M.parseReadings(raw)
  assert.strictEqual(Object.keys(parsed).length, lines.length, "some lines were rejected:\n" + raw)
})

test("every catalog has the English keys and plural shapes", () => {
  const en = JSON.parse(fs.readFileSync(path.join(dir, "i18n", "en.json"), "utf8"))
  for (const file of fs.readdirSync(path.join(dir, "i18n"))) {
    const cat = JSON.parse(fs.readFileSync(path.join(dir, "i18n", file), "utf8"))
    for (const key of Object.keys(en)) {
      assert.ok(key in cat, file + " is missing " + key)
      assert.strictEqual(typeof cat[key], typeof en[key], file + ": " + key + " has the wrong shape")
      if (typeof en[key] === "object") assert.ok(typeof cat[key].other === "string", file + ": " + key + " needs an 'other' form")
    }
  }
})

test("every string the panel uses exists in en.json", () => {
  const en = JSON.parse(fs.readFileSync(path.join(dir, "i18n", "en.json"), "utf8"))
  const qml = fs.readFileSync(path.join(dir, "Panel.qml"), "utf8")
  const used = [...qml.matchAll(/root\.trn?\("([^"]+)"/g)].map(m => m[1])
  assert.ok(used.length > 20, "found only " + used.length + " lookups")
  for (const key of used) assert.ok(key in en, "en.json is missing " + key)
})

process.exit(failures ? 1 : 0)
