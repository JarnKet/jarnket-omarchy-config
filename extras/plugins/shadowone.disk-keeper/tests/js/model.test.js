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

function cat(id, extra) {
  return Object.assign({ id, group: "dev", title: id, available: true, hiddenWhenEmpty: true, itemized: false,
    defaultSelected: true, estimateKind: "du", bytes: 100, items: [], blocked: null, note: null, privilege: "user",
    confirm: "normal", risk: "regenerates" }, extra || {})
}

function item(key, extra) {
  return Object.assign({ key, label: key, bytes: 10, actionable: true, blocked: null, selected: true }, extra || {})
}

const scan = {
  groups: [{ id: "dev", title: "Developer caches", subtitle: "" }, { id: "docker", title: "Docker", subtitle: "" }],
  categories: [
    cat("npm-cache", { bytes: 3 * GIB }),
    cat("yay-builds", { itemized: true, bytes: 30, items: [item("a"), item("b"), item("busy", { blocked: { reason: "in-use" }, actionable: false, selected: false })] }),
    cat("brave-cache", { bytes: GIB, blocked: { reason: "app-running", detail: "Close Brave" } }),
    cat("empty", { bytes: 0 }),
    cat("pnpm-prune", { bytes: 0, estimateKind: "unknown", hiddenWhenEmpty: false }),
    cat("docker-volumes", { group: "docker", itemized: true, defaultSelected: false, confirm: "extra", risk: "data",
      items: [item("v1", { selected: false })] }),
  ],
}

test("formatBytes and formatShort", () => {
  assert.strictEqual(M.formatBytes(0), "0 B")
  assert.strictEqual(M.formatBytes(1536), "2 KB")
  assert.strictEqual(M.formatBytes(26.04 * GIB), "26.0 GB")
  assert.strictEqual(M.formatBytes(129 * GIB), "129 GB")
  assert.strictEqual(M.formatShort(25.3 * GIB), "25G")
  assert.strictEqual(M.formatShort(8.24 * GIB), "8.2G")
  assert.strictEqual(M.formatShort(700 * 1024 * 1024), "700M")
})

test("clampSettings guards bad values", () => {
  const s = M.clampSettings({ warnFreeGB: "abc", criticalFreeGB: 50, pollMinutes: 0, barLabel: "weird", notifications: false })
  assert.strictEqual(s.warnFreeGB, 20)
  assert.ok(s.criticalFreeGB < s.warnFreeGB)
  assert.strictEqual(s.pollMinutes, 1)
  assert.strictEqual(s.barLabel, "free")
  assert.strictEqual(s.notifications, false)
  assert.deepStrictEqual(M.clampSettings(null).warnFreeGB, 20)
})

test("visible hides empty categories but keeps tool ones", () => {
  const ids = M.visibleCategories(scan).map(c => c.id)
  assert.ok(!ids.includes("empty"))
  assert.ok(ids.includes("pnpm-prune"))
})

test("default selection skips blocked, unselected and opt-in categories", () => {
  const sel = M.defaultSelection(scan)
  assert.deepStrictEqual(Object.keys(sel).sort(), ["npm-cache", "pnpm-prune", "yay-builds:a", "yay-builds:b"])
})

test("toggling an itemized category flips all selectable items only", () => {
  const yay = M.categoryById(scan, "yay-builds")
  let sel = M.toggleCategory(yay, {})
  assert.strictEqual(M.checkState(yay, sel), "all")
  assert.ok(!sel["yay-builds:busy"])
  sel = M.toggleItem(yay, yay.items[0], sel)
  assert.strictEqual(M.checkState(yay, sel), "some")
  sel = M.toggleCategory(yay, sel)
  assert.strictEqual(M.checkState(yay, sel), "all")
  sel = M.toggleCategory(yay, sel)
  assert.strictEqual(M.checkState(yay, sel), "none")
})

test("blocked category cannot be selected or sent", () => {
  const brave = M.categoryById(scan, "brave-cache")
  assert.deepStrictEqual(M.toggleCategory(brave, {}), {})
  assert.deepStrictEqual(M.targetsFor(scan, { "brave-cache": true, "yay-builds:busy": true, "gone:x": true }), [])
})

test("targets and summary", () => {
  const sel = M.defaultSelection(scan)
  sel["docker-volumes:v1"] = true
  assert.deepStrictEqual(M.targetsFor(scan, sel), ["npm-cache", "yay-builds:a", "yay-builds:b", "pnpm-prune", "docker-volumes:v1"])
  const sum = M.selectionSummary(scan, sel)
  assert.strictEqual(sum.bytes, 3 * GIB + 20 + 10)
  assert.strictEqual(sum.unknown, true)
  assert.deepStrictEqual(sum.extraConfirm, ["docker-volumes"])
  assert.ok(M.confirmMessage(sum).includes("cannot be undone"))
})

test("cleanup rows: groups, expansion and cursor walking", () => {
  let rows = M.cleanupRows(scan, {})
  assert.strictEqual(rows[0].kind, "group")
  assert.strictEqual(M.firstSelectable(rows), 1)
  rows = M.cleanupRows(scan, { "yay-builds": true, "brave-cache": true })
  const kinds = rows.map(r => r.kind + (r.item ? ":" + r.item.key : ""))
  assert.ok(kinds.includes("item:a") && kinds.includes("item:busy"))
  assert.ok(rows.some(r => r.kind === "note" && r.urgent))
  const g = rows.findIndex((r, i) => i > 0 && r.kind === "group")
  assert.strictEqual(M.nextSelectable(rows, g - 1, 1), g + 1)
  assert.strictEqual(M.nextSelectable(rows, 1, -1), 1)
  assert.strictEqual(M.indexOfKey(rows, "i:yay-builds:b") >= 0, true)
})

test("projects selection only touches eligible items", () => {
  const data = { projects: [{ path: "~/P/a", items: [
    { key: "P/a/node_modules", eligible: true, selected: true, bytes: 100, exclusiveBytes: 40 },
    { key: "P/a/dist", eligible: false, reason: "tracked-by-git", selected: false, bytes: 5 },
  ] }] }
  let sel = M.projectDefaultSelection(data)
  assert.deepStrictEqual(M.projectTargets(data, sel), ["projects:P/a/node_modules"])
  assert.strictEqual(M.projectSelectionBytes(data, sel, true), 40)
  assert.strictEqual(M.projectCheckState(data.projects[0], sel), "all")
  sel = M.toggleProject(data.projects[0], sel)
  assert.deepStrictEqual(M.projectTargets(data, sel), [])
  sel = M.toggleProjectItem(data.projects[0].items[1], sel)
  assert.deepStrictEqual(M.projectTargets(data, sel), [])
  assert.strictEqual(M.reasonText("tracked-by-git"), "tracked by git")
})

test("snapshots merge marks protected ones", () => {
  const s = { categories: [cat("snapshots", { itemized: true, estimateKind: "unknown" })] }
  const merged = M.withSnapshots(s, [
    { number: 3, date: "2026-10-01", type: "single", description: "before update", cleanup: "number", protected: false },
    { number: 9, date: "2026-10-18", type: "single", description: "newest", cleanup: "", protected: true },
  ])
  const items = merged.categories[0].items
  assert.strictEqual(items.length, 2)
  assert.strictEqual(items[0].actionable, true)
  assert.strictEqual(items[1].actionable, false)
  assert.strictEqual(s.categories[0].items.length, 0, "original scan is not mutated")
})

test("job summaries", () => {
  const job = { state: "done", dryRun: false, measuredFreedBytes: 6 * GIB, results: [
    { target: "a", status: "done" }, { target: "b", status: "skipped", reason: "in-use" }, { target: "c", status: "failed" }] }
  assert.strictEqual(M.jobSummary(job), "Freed 6.0 GB · 1 skipped, 1 failed")
  assert.strictEqual(M.resultText(M.resultFor(job, "b")), "in use")
  assert.strictEqual(M.resultText(M.resultFor(job, "a"), true), "would remove")
  assert.strictEqual(M.categoryResult({ state: "done", results: [{ target: "y:a", status: "done" }, { target: "y:b", status: "skipped", reason: "in-use" }] }, { id: "y" }).text.indexOf("1 skipped") > 0, true)
  assert.strictEqual(M.categoryResult({ state: "running", targets: ["z"], results: [] }, { id: "z" }).text, "waiting…")
  assert.strictEqual(M.categoryResult({ state: "done", targets: [], results: [] }, { id: "q" }), null)
  assert.strictEqual(M.jobProgress({ state: "running", current: "npm cache", targets: [1, 2, 3], results: [1] }), "npm cache · 1 of 3")
})

test("bar text and tooltip", () => {
  const st = { freeBytes: 25 * GIB, totalBytes: 128 * GIB, level: "warn", levelReason: "free" }
  assert.strictEqual(M.barText(st, "free"), "25G")
  assert.strictEqual(M.barText(st, "percent"), "80%")
  assert.strictEqual(M.barText(st, "none"), "")
  assert.ok(M.barTooltip(st).includes("Running low"))
})

if (failures) { console.log(failures + " failed"); process.exit(1) }
console.log("all passed")
