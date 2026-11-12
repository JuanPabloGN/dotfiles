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
const plain = (v) => JSON.parse(JSON.stringify(v))

const ONLINE = [
  "present=1", "battery=available", "level=85", "product=PRO X Wireless Gaming Headset",
  "sidetone_cap=1", "sidetone=64", "ee=1", "bypass=0", "ee_input=", "ee_output=Gaming",
  "out_preset=Equilibrado", "out_preset=Gaming", "in_preset=Micro Gaming"
].join("\n")

test("parses a full online status", () => {
  const s = plain(M.parseStatus(ONLINE))
  assert.deepStrictEqual(s, {
    present: true, battery: "available", level: 85, voltage: 0, product: "PRO X Wireless Gaming Headset",
    sidetoneCap: true, sidetone: 64, ee: true, bypass: false, output: "Gaming", input: "",
    outputPresets: ["Equilibrado", "Gaming"], inputPresets: ["Micro Gaming"]
  })
})

test("headset switched off: offline, no level", () => {
  const s = M.parseStatus("present=1\nbattery=unavailable\nlevel=-1\nee=0")
  assert.strictEqual(s.battery, "offline")
  assert.strictEqual(s.level, -1)
  assert.strictEqual(M.online(s), false)
  assert.strictEqual(M.barText(s, false), "󰟎")
})

test("offline drops a stale level", () => {
  const s = M.parseStatus("present=1\nbattery=hiderror\nlevel=40")
  assert.strictEqual(s.battery, "offline")
  assert.strictEqual(s.level, -1)
})

test("receiver missing or garbage: absent", () => {
  assert.strictEqual(M.parseStatus("present=0\nbattery=available\nlevel=90").battery, "absent")
  assert.strictEqual(M.parseStatus("").battery, "absent")
  assert.strictEqual(M.parseStatus(undefined).battery, "absent")
  assert.strictEqual(M.parseStatus("battery=available\nlevel=90").battery, "absent")
})

test("implausible voltage (reply to a sidetone write) drops the level", () => {
  const glitch = M.parseStatus("present=1\nbattery=available\nlevel=100\nvoltage=12800")
  assert.strictEqual(glitch.level, -1)
  assert.strictEqual(glitch.battery, "available")
  assert.strictEqual(M.barText(glitch, false), "󰋋")
  assert.strictEqual(M.parseStatus("present=1\nbattery=available\nlevel=100\nvoltage=1200").level, -1)
  const real = M.parseStatus("present=1\nbattery=available\nlevel=80\nvoltage=4027")
  assert.strictEqual(real.level, 80)
  assert.strictEqual(real.voltage, 4027)
  // Headsets that report no voltage keep their level.
  assert.strictEqual(M.parseStatus("present=1\nbattery=available\nlevel=55").level, 55)
  assert.strictEqual(M.parseStatus("present=1\nbattery=available\nlevel=55\nvoltage=0").level, 55)
})

test("charging, with and without a level", () => {
  const a = M.parseStatus("present=1\nbattery=charging\nlevel=-1")
  assert.strictEqual(M.barText(a, false), "󰋋 󱐋")
  const b = M.parseStatus("present=1\nbattery=charging\nlevel=42")
  assert.strictEqual(M.barText(b, false), "󰋋 󱐋 42%")
  assert.strictEqual(M.barText(b, true), "󱐋")
  assert.strictEqual(M.online(b), true)
})

test("bar text, horizontal and vertical", () => {
  const s = M.parseStatus(ONLINE)
  assert.strictEqual(M.barText(s, false), "󰋋 85%")
  assert.strictEqual(M.barText(s, true), "󰋋\n85")
})

test("rejects out-of-range and malformed numbers", () => {
  const s = M.parseStatus("present=1\nbattery=available\nlevel=101\nsidetone=129")
  assert.strictEqual(s.level, -1)
  assert.strictEqual(s.sidetone, -1)
  const t = M.parseStatus("present=1\nbattery=available\nlevel=8<b>5</b>\nsidetone=1e3")
  assert.strictEqual(t.level, -1)
  assert.strictEqual(t.sidetone, -1)
})

test("unknown and prototype keys are ignored", () => {
  const s = M.parseStatus("present=1\n__proto__=1\nconstructor=2\nevil=3\n<img src=x>=1\nbattery=available\nlevel=50")
  assert.strictEqual(Object.getPrototypeOf(s), Object.getPrototypeOf(M.emptyState()))
  assert.deepStrictEqual(Object.keys(s).sort(), Object.keys(M.emptyState()).sort())
})

test("markup-shaped product and preset names stay inert text, bounded", () => {
  const evil = '<img src="https://example.invalid/tracker">'
  const s = M.parseStatus(`present=1\nbattery=available\nlevel=5\nproduct=${evil}\nee=1\nout_preset=${evil}\nee_output=${evil}`)
  // Kept as literal text (rendered with Text.PlainText), never reshaped into markup.
  assert.strictEqual(s.product, evil.substring(0, 48))
  assert.ok(s.product.length <= 48)
  assert.strictEqual(s.outputPresets[0], evil.substring(0, 48))
  assert.strictEqual(s.output, evil.substring(0, 48))
})

test("control characters are stripped from names", () => {
  const s = M.parseStatus("present=1\nbattery=available\nlevel=5\nproduct=PRO\u0007 X\u2028Wireless\tGaming Headset\u001b[31m")
  assert.strictEqual(s.product, "PRO X Wireless Gaming Headset [31m")
})

test("preset lists are bounded and de-duplicated", () => {
  let raw = "present=1\nee=1\n"
  for (let i = 0; i < 40; i++) raw += "out_preset=P" + (i % 20) + "\n"
  raw += "out_preset=\nout_preset=   \n"
  const s = M.parseStatus(raw)
  assert.strictEqual(s.outputPresets.length, 16)
  assert.strictEqual(new Set(s.outputPresets).size, 16)
})

test("line count and line length are bounded", () => {
  const long = "product=" + "A".repeat(5000)
  const s = M.parseStatus("present=1\nbattery=available\nlevel=10\n" + long)
  assert.strictEqual(s.product.length, 48)
  const filler = "x=1\n".repeat(500)
  const t = M.parseStatus("present=1\n" + filler + "battery=available\nlevel=10")
  assert.strictEqual(t.battery, "offline")
})

test("EasyEffects not running clears its fields", () => {
  const s = M.parseStatus("present=1\nbattery=available\nlevel=50\nee=0\nee_output=Gaming\nout_preset=Gaming\nbypass=1")
  assert.strictEqual(s.ee, false)
  assert.strictEqual(s.output, "")
  assert.deepStrictEqual(plain(s.outputPresets), [])
  assert.strictEqual(s.bypass, false)
})

test("short product name", () => {
  assert.strictEqual(M.shortProduct("PRO X Wireless Gaming Headset"), "PRO X Wireless")
  assert.strictEqual(M.shortProduct("Arctis Nova 7 Headset"), "Arctis Nova 7")
  assert.strictEqual(M.shortProduct("Cloud II"), "Cloud II")
  assert.strictEqual(M.shortProduct(""), "")
})

test("low battery notifies once per discharge", () => {
  const at = (level, battery) => M.parseStatus(`present=1\nbattery=${battery || "available"}\nlevel=${level}`)
  let n = false, fired = 0
  for (const s of [at(30), at(16), at(15), at(14), at(16), at(12), at(10)]) {
    const r = M.lowBatteryStep(n, s, 15); n = r.notified; if (r.notify) fired++
  }
  assert.strictEqual(fired, 1)
  // Headset switched off keeps the latch (no repeat when it comes back low).
  let r = M.lowBatteryStep(n, M.parseStatus("present=1\nbattery=unavailable"), 15)
  assert.strictEqual(r.notified, true)
  r = M.lowBatteryStep(r.notified, at(10), 15)
  assert.strictEqual(r.notify, false)
  // Charging re-arms it.
  r = M.lowBatteryStep(r.notified, at(-1, "charging"), 15)
  assert.strictEqual(r.notified, false)
  r = M.lowBatteryStep(r.notified, at(14), 15)
  assert.strictEqual(r.notify, true)
  // So does climbing back past threshold + 5.
  r = M.lowBatteryStep(true, at(21), 15)
  assert.strictEqual(r.notified, false)
})

test("came online only on the off -> on edge", () => {
  const off = M.parseStatus("present=1\nbattery=unavailable")
  const on = M.parseStatus("present=1\nbattery=available\nlevel=50")
  const absent = M.parseStatus("present=0")
  assert.strictEqual(M.cameOnline(off, on), true)
  assert.strictEqual(M.cameOnline(absent, on), true)
  assert.strictEqual(M.cameOnline(on, on), false)
  assert.strictEqual(M.cameOnline(on, off), false)
  assert.strictEqual(M.cameOnline(null, on), false)
})

test("sidetone clamp", () => {
  assert.strictEqual(M.clampSidetone(64.4), 64)
  assert.strictEqual(M.clampSidetone(-3), 0)
  assert.strictEqual(M.clampSidetone(500), 128)
  assert.strictEqual(M.clampSidetone("abc"), 0)
})

test("preset cycling wraps", () => {
  const list = ["Equilibrado", "Gaming"]
  assert.strictEqual(M.cyclePreset(list, "Gaming", 1), "Equilibrado")
  assert.strictEqual(M.cyclePreset(list, "Equilibrado", 1), "Gaming")
  assert.strictEqual(M.cyclePreset(list, "Equilibrado", -1), "Gaming")
  assert.strictEqual(M.cyclePreset(list, "", 1), "Equilibrado")
  assert.strictEqual(M.cyclePreset([], "Gaming", 1), "")
})

test("battery fraction", () => {
  assert.strictEqual(M.batteryFraction(M.parseStatus("present=1\nbattery=available\nlevel=50")), 0.5)
  assert.strictEqual(M.batteryFraction(M.parseStatus("present=0")), 0)
})

test("headset.sh status output parses on this machine", () => {
  const raw = execFileSync("bash", [path.join(dir, "headset.sh"), "status"], { encoding: "utf8", timeout: 20000 })
  const s = M.parseStatus(raw)
  assert.ok(["available", "charging", "offline", "absent"].includes(s.battery))
})

test("headset.sh rejects bad arguments without running anything", () => {
  const run = (args) => {
    try { return execFileSync("bash", [path.join(dir, "headset.sh"), ...args], { encoding: "utf8" }) }
    catch (e) { return e.stdout }
  }
  assert.strictEqual(run(["sidetone", "129"]).trim(), "ok=0")
  assert.strictEqual(run(["sidetone", "6;4"]).trim(), "ok=0")
  assert.strictEqual(run(["sidetone", "$(id)"]).trim(), "ok=0")
  assert.strictEqual(run(["preset", "--quit"]).trim(), "ok=0")
  assert.strictEqual(run(["preset", "does not exist $(id)"]).trim(), "ok=0")
  assert.strictEqual(run(["effects", "maybe"]).trim(), "ok=0")
})

if (failures) { console.log(`\n${failures} failing`); process.exit(1) }
console.log("\nall passing")
