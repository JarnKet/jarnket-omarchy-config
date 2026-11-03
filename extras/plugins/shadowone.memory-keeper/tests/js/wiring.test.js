// Static checks over the QML and the manifest. Run with: node tests/js/wiring.test.js
const fs = require("fs")
const path = require("path")
const assert = require("assert")

const root = path.join(__dirname, "..", "..")
const qmlFiles = fs.readdirSync(root).filter(f => f.endsWith(".qml"))
const sources = Object.fromEntries(qmlFiles.concat(["Model.js"]).map(f => [f, fs.readFileSync(path.join(root, f), "utf8")]))
const modelSource = sources["Model.js"]
const modelNames = new Set([...modelSource.matchAll(/^(?:function|var) ([A-Za-z_$][\w$]*)/gm)].map(m => m[1]))

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) } catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}

test("every Model.* used in QML exists", () => {
  for (const [file, src] of Object.entries(sources)) {
    if (!file.endsWith(".qml")) continue
    for (const m of src.matchAll(/(?<!")\bModel\.([A-Za-z_$][\w$]*)/g)) assert.ok(modelNames.has(m[1]), file + ": Model." + m[1])
  }
})

test("words that make omarchy-topbar refuse the widget are absent", () => {
  // The custom top bar greps every file, comments included.
  const banned = ["serviceFor", "firstPartyServiceFor", "appLibrary", "pluginShellForBarEntry", "mutateShellConfig"]
  for (const [file, src] of Object.entries(sources)) for (const word of banned) assert.ok(!src.includes(word), file + " has " + word)
})

test("the read-only reveal property is never assigned", () => {
  for (const [file, src] of Object.entries(sources)) assert.ok(!/centerHoverRevealSuppressed\s*=[^=]/.test(src), file)
})

test("processes are started with argv arrays, never through a shell string", () => {
  for (const [file, src] of Object.entries(sources)) {
    assert.ok(!/["']bash["']\s*,\s*["']-c["']/.test(src), file + " uses bash -c")
    assert.ok(!/["']sh["']\s*,\s*["']-c["']/.test(src), file + " uses sh -c")
    assert.ok(!/bar\.run\(/.test(src), file + " uses bar.run")
    for (const m of src.matchAll(/execDetached\(([^)]*)\)/g)) assert.ok(/^\s*\[/.test(m[1]), file + ": " + m[0])
  }
})

test("python is always started isolated and without bytecode", () => {
  const svc = sources["Service.qml"]
  assert.ok(svc.includes('"/usr/bin/python3", "-IB"'))
})

test("the shell is never restarted without asking, and nothing here stops on a timer", () => {
  const svc = sources["Service.qml"]
  const panel = sources["Panel.qml"]
  assert.ok(panel.includes('kind: "restart"'))
  assert.strictEqual((panel.match(/service\.restartShell\(\)/g) || []).length, 1)
  assert.ok(/p\.kind === "restart"\) service\.restartShell\(\)/.test(panel))
  for (const m of (svc + panel).matchAll(/Timer\s*\{[^}]*onTriggered:\s*([^\n]*)/g)) {
    assert.ok(!/stop|reclaim|restart/i.test(m[1]), "timer acts: " + m[1])
  }
})

test("manifest", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  assert.strictEqual(manifest.entryPoints.barWidget, "Panel.qml")
  assert.deepStrictEqual(manifest.kinds, ["bar-widget"])
  const keys = manifest.barWidget.schema.map(s => s.key).sort()
  const clampBody = modelSource.slice(modelSource.indexOf("function clampSettings"), modelSource.indexOf("function barLevel"))
  for (const k of keys) assert.ok(clampBody.includes(k + ":"), "clampSettings lacks " + k)
  assert.deepStrictEqual(Object.keys(manifest.barWidget.defaults).sort(), keys)
})

test("the panel's settings exist in the backend", () => {
  const state = fs.readFileSync(path.join(root, "backend", "memkeeper", "state.py"), "utf8")
  for (const m of modelSource.matchAll(/\{ key: "(\w+)"/g)) assert.ok(state.includes('"' + m[1] + '"'), m[1])
})

test("no symlinks inside the plugin folder", () => {
  const walk = dir => fs.readdirSync(dir, { withFileTypes: true }).forEach(e => {
    if (e.name === ".git" || e.name === "node_modules") return
    const p = path.join(dir, e.name)
    assert.ok(!e.isSymbolicLink(), "symlink: " + p)
    if (e.isDirectory()) walk(p)
  })
  walk(root)
})

if (failures) { console.log(failures + " failed"); process.exit(1) }
