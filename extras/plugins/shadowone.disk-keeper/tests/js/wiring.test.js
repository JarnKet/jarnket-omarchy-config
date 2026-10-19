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
  for (const [file, src] of Object.entries(sources)) for (const word of banned) assert.ok(!src.includes(word), file + " mentions " + word)
})

test("the read-only reveal property is never assigned", () => {
  for (const [file, src] of Object.entries(sources)) assert.ok(!/centerHoverRevealSuppressed\s*=[^=]/.test(src), file)
})

test("processes are started with argv arrays, never through a shell string", () => {
  for (const [file, src] of Object.entries(sources)) {
    assert.ok(!/["']bash["']\s*,\s*["']-c["']/.test(src), file + " uses bash -c")
    assert.ok(!/["']sh["']\s*,\s*["']-c["']/.test(src), file + " uses sh -c")
    assert.ok(!/bar\.run\(/.test(src), file + " uses bar.run")
    for (const m of src.matchAll(/execDetached\(([^)]*)\)/g)) assert.ok(/^\s*(\[|cli\(|root\.cli\()/.test(m[1]), file + ": " + m[0])
  }
  assert.ok(!/rm -rf/.test(Object.values(sources).join("\n")), "rm -rf in QML")
})

test("python is always started isolated and without bytecode", () => {
  const svc = sources["Service.qml"]
  assert.ok(svc.includes('"/usr/bin/python3", "-IB"'))
  assert.ok(!/python3"\s*,\s*root\.bin/.test(svc))
})

test("manifest schema keys match clampSettings", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "manifest.json"), "utf8"))
  assert.strictEqual(manifest.entryPoints.barWidget, "Panel.qml")
  assert.deepStrictEqual(manifest.kinds, ["bar-widget"])
  const keys = manifest.barWidget.schema.map(s => s.key).sort()
  const clampBody = modelSource.slice(modelSource.indexOf("function clampSettings"), modelSource.indexOf("function usedFraction"))
  for (const k of keys) assert.ok(clampBody.includes(k + ":"), "clampSettings lacks " + k)
  assert.deepStrictEqual(Object.keys(manifest.barWidget.defaults).sort(), keys)
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
console.log("all passed")
