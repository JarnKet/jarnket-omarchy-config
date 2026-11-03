// Tests for Model.js. Run with: node tests/js/model.test.js
//
// Model.js is a QML JavaScript resource (`.pragma library`, no exports), so
// it is evaluated here as plain source inside a function scope.
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const source = fs.readFileSync(path.join(__dirname, "..", "..", "Model.js"), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const names = [...source.matchAll(/^(?:function|var) ([A-Za-z_$][\w$]*)/gm)].map(m => m[1])
const M = new Function(source + "\nreturn {" + names.join(",") + "}")()

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}

const GIB = 1024 ** 3
const NOW = 1800000000 * 1000
const config = { auto: true, idleHours: 12, warnIdleHours: 3, criticalIdleHours: 1, keep: [] }

function session(extra) {
  return Object.assign({ sessionId: "id", name: "s", status: "idle", block: null, work: [], keep: false, bytes: 400 * 1024 * 1024,
    wallIdleSeconds: 36 * 3600, awakeIdleSeconds: 3600, stopsInSeconds: 11 * 3600 }, extra || {})
}

test("formats", () => {
  assert.strictEqual(M.formatBytes(1.5 * GIB), "1.5 GB")
  assert.strictEqual(M.formatBytes(400 * 1024 * 1024), "400 MB")
  assert.strictEqual(M.formatShort(13.4 * GIB), "13G")
  assert.strictEqual(M.formatShort(8.24 * GIB), "8.2G")
  assert.strictEqual(M.formatShort(740 * 1024 * 1024), "740M")
  assert.strictEqual(M.formatDuration(120), "2 min")
  assert.strictEqual(M.formatDuration(36 * 3600), "36 h")
  assert.strictEqual(M.formatDuration(72 * 3600), "3 days")
})

test("parseMeminfo reads what the bar needs", () => {
  const m = M.parseMeminfo("MemTotal:  1048576 kB\nMemFree: 1 kB\nMemAvailable:  524288 kB\nSwapTotal: 1048576 kB\nSwapFree: 524288 kB\n")
  assert.strictEqual(m.totalBytes, GIB)
  assert.strictEqual(m.availableBytes, GIB / 2)
  assert.strictEqual(m.swapUsedBytes, GIB / 2)
  assert.strictEqual(M.parseMeminfo(""), null)
})

test("the bar's level follows the same thresholds as the backend", () => {
  const cfg = M.clampConfig(null)
  const mem = (avail, swap) => ({ totalBytes: 30 * GIB, availableBytes: avail * GIB, swapTotalBytes: 30 * GIB, swapUsedBytes: swap * GIB })
  assert.strictEqual(M.barLevel(null, cfg), "ok")
  assert.strictEqual(M.barLevel(mem(15, 1), cfg), "ok")
  assert.strictEqual(M.barLevel(mem(5, 1), cfg), "warn")
  assert.strictEqual(M.barLevel(mem(2, 1), cfg), "critical")
  assert.strictEqual(M.barLevel(mem(15, 22), cfg), "warn")
  assert.strictEqual(M.barLevel(mem(15, 27), cfg), "critical")
  assert.strictEqual(M.barLevel({ totalBytes: GIB, availableBytes: GIB, swapTotalBytes: 0, swapUsedBytes: 0 }, cfg), "ok")
})

test("bar text modes", () => {
  const m = { totalBytes: 30 * GIB, availableBytes: 13 * GIB, swapUsedBytes: 0 }
  assert.strictEqual(M.barText(m, "available"), "13G")
  assert.strictEqual(M.barText(m, "percent"), "57%")
  assert.strictEqual(M.barText(m, "none"), "")
  assert.strictEqual(M.barText(null, "available"), "")
})

test("session detail says why and when", () => {
  assert.strictEqual(M.sessionDetail(session(), config), "idle 36 h · stops after 11 h more")
  assert.strictEqual(M.sessionDetail(session({ stopsInSeconds: 0 }), config), "idle 36 h · stops at the next check")
  assert.strictEqual(M.sessionDetail(session(), { auto: false }), "idle 36 h · auto-stop off")
  assert.strictEqual(M.sessionDetail(session({ status: "busy", block: "busy" }), config), "working")
  assert.strictEqual(M.sessionDetail(session({ status: "waiting", block: "waiting" }), config), "waiting for you")
  assert.ok(M.sessionDetail(session({ block: "running-work", work: ["pnpm", "workerd"] }), config).includes("running pnpm, workerd"))
  assert.ok(M.sessionDetail(session({ block: "keep" }), config).includes("kept"))
  assert.ok(M.sessionDetail(session({ block: "on-screen" }), config).includes("on screen"))
})

test("only the risky stops ask first", () => {
  assert.strictEqual(M.stopNeedsConfirm(session()), false)
  assert.strictEqual(M.stopNeedsConfirm(session({ block: "keep" })), false)
  assert.strictEqual(M.stopNeedsConfirm(session({ block: "running-work" })), true)
  assert.strictEqual(M.stopNeedsConfirm(session({ status: "waiting" })), true)
  assert.strictEqual(M.stopNeedsConfirm(session({ block: "not-herdr" })), true)
})

test("Stop idle only counts sessions that may safely stop", () => {
  const scan = { sessions: [session({ name: "a" }), session({ name: "b", wallIdleSeconds: 60 }), session({ name: "c", block: "keep" }),
                            session({ name: "d", status: "busy", block: "busy" })] }
  assert.deepStrictEqual(M.idleCandidates(scan).map(s => s.name), ["a"])
  assert.deepStrictEqual(M.idleCandidates(null), [])
  assert.ok(M.idleConfirmText(M.idleCandidates(scan)).includes("1 idle session"))
})

const scan = {
  config, level: "ok", reasons: [],
  sessions: [session({ name: "a", sessionId: "1" }), session({ name: "b", sessionId: "2", status: "busy", block: "busy" })],
  stopped: [{ sessionId: "3", name: "c", stoppedAt: NOW / 1000 - 7200, freedBytes: GIB, inputText: "ກວດ  ແລ້ວ\nເດີ" }, { sessionId: "4", name: "d", stoppedAt: NOW / 1000, freedBytes: 0 }],
  apps: [{ name: "Brave", bytes: 4 * GIB }, { name: "Omarchy shell", bytes: GIB }],
  leftovers: [{ pid: 9, start: 1, label: "npm exec wrangl", cwd: "/x", ageSeconds: 90000, bytes: GIB }],
}

test("rows", () => {
  const rows = M.buildRows(scan, false)
  assert.deepStrictEqual(rows.map(r => r.kind), ["auto", "group", "session", "session", "group", "stopped", "stopped", "group", "app", "app", "group", "leftover", "settings"])
  assert.strictEqual(M.buildRows(null, false).length, 0)
  assert.strictEqual(M.buildRows(scan, true).filter(r => r.kind === "setting").length, M.SETTINGS.length)
  const empty = M.buildRows({ config, sessions: [], stopped: [], apps: [], leftovers: [] }, false)
  assert.deepStrictEqual(empty.map(r => r.kind), ["auto", "group", "note", "group", "settings"])
  assert.ok(rows.every(r => r.kind === "group" || r.selectable))
  assert.ok(new Set(rows.filter(r => r.key).map(r => r.key)).size === rows.filter(r => r.key).length)
})

test("row views offer the right actions", () => {
  const rows = M.buildRows(scan, true)
  const view = i => M.rowView(rows[i], scan, true, NOW)
  const ids = i => view(i).actions.map(a => a.id)
  assert.deepStrictEqual(ids(0), ["toggle-auto"])
  assert.strictEqual(view(0).actions[0].label, "On")
  assert.deepStrictEqual(ids(2), ["stop", "keep"])
  assert.deepStrictEqual(ids(3), [])  // busy cannot be stopped
  assert.deepStrictEqual(ids(5), ["resume", "copy"])
  assert.deepStrictEqual(ids(6), ["resume"])
  assert.ok(view(5).detail.includes("2 h ago"))
  assert.ok(view(5).detail.includes("ກວດ ແລ້ວ ເດີ"))
  assert.deepStrictEqual(ids(8), [])
  assert.deepStrictEqual(ids(9), ["restart-shell"])  // the shell at 1 GB
  assert.deepStrictEqual(ids(11), ["stop-leftover"])
  const setting = rows.findIndex(r => r.kind === "setting")
  assert.deepStrictEqual(ids(setting), ["dec", "inc"])
  assert.strictEqual(view(setting).size, "12 h")
})

test("the shell's restart button waits until it has really grown", () => {
  const small = Object.assign({}, scan, { apps: [{ name: "Omarchy shell", bytes: 700 * 1024 * 1024 }] })
  const row = M.buildRows(small, false).find(r => r.kind === "app")
  assert.deepStrictEqual(M.rowView(row, small, false, NOW).actions, [])
})

test("cursor helpers", () => {
  const rows = M.buildRows(scan, false)
  assert.strictEqual(M.firstSelectable(rows), 0)
  assert.strictEqual(M.nextSelectable(rows, 0, 1), 2)  // skips the group
  assert.strictEqual(M.nextSelectable(rows, 2, -1), 0)
  assert.strictEqual(M.nextSelectable(rows, 0, -1), 0)
  assert.strictEqual(M.indexOfKey(rows, "s:1"), 2)
})

test("result messages", () => {
  assert.ok(M.stopResultText({ ok: true, name: "a", freedBytes: GIB }).includes("freed about 1.0 GB"))
  assert.ok(M.stopResultText({ ok: false, name: "a", error: "nope" }).includes("nope"))
  assert.ok(M.stopIdleResultText({ results: [{ ok: true, freedBytes: GIB }, { ok: false }] }).includes("1 would not stop"))
  assert.ok(M.reclaimResultText({ ok: true, askedBytes: 5, freeBefore: GIB, freeAfter: 2 * GIB }).includes("1.0 GB"))
  assert.strictEqual(M.reclaimResultText({ ok: true, askedBytes: 0 }), "No cold cache to free")
})

if (failures) { console.log(failures + " failed"); process.exit(1) }
