.pragma library

// Pure logic for the Memory Keeper panel: formatting, the bar's level, and the
// flat row list the keyboard cursor walks. No QML types in here, so
// tests/js/model.test.js can load it in node.

var GLYPH_MEMORY = String.fromCodePoint(0xF035B)
var GLYPH_ALERT = String.fromCodePoint(0xF0026)
var GLYPH_REFRESH = String.fromCodePoint(0xF0450)
var GLYPH_EXPANDED = String.fromCodePoint(0xF0140)
var GLYPH_COLLAPSED = String.fromCodePoint(0xF0142)
var GLYPH_KEEP = String.fromCodePoint(0xF0403)
var GLYPH_CLAUDE = String.fromCodePoint(0xF06A9)
var GLYPH_PAUSED = String.fromCodePoint(0xF03E4)
var GLYPH_APP = String.fromCodePoint(0xF0614)
var GLYPH_LEFTOVER = String.fromCodePoint(0xF0493)

var GIB = 1024 * 1024 * 1024
var SHELL_RESTART_BYTES = GIB
var MANUAL_MIN_IDLE = 3600

var SETTINGS = [
  { key: "idleHours", label: "Stop sessions idle for", unit: "h", step: 1 },
  { key: "warnIdleHours", label: "… when memory is low", unit: "h", step: 1 },
  { key: "criticalIdleHours", label: "… when memory is very low", unit: "h", step: 1 },
  { key: "warnAvailablePercent", label: "Low: available under", unit: "%", step: 5 },
  { key: "criticalAvailablePercent", label: "Very low: available under", unit: "%", step: 1 },
  { key: "warnSwapPercent", label: "Low: swap over", unit: "%", step: 5 },
  { key: "criticalSwapPercent", label: "Very low: swap over", unit: "%", step: 1 },
  { key: "criticalPsiFull", label: "Very low: all apps stalled over", unit: "%", step: 5 },
  { key: "reclaimPsiSome", label: "Free cold cache when stalled over", unit: "%", step: 1 }
]

function formatBytes(n) {
  n = Number(n) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  if (i === 0) return Math.round(n) + " B"
  if (i === 1) return Math.round(n) + " KB"
  if (i === 2) return Math.round(n) + " MB"
  return (n >= 100 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i]
}

// "13G" / "740M" for the bar, where width matters.
function formatShort(n) {
  n = Number(n) || 0
  var gib = n / GIB
  if (gib >= 10) return Math.round(gib) + "G"
  if (gib >= 1) return gib.toFixed(1) + "G"
  return Math.round(n / (1024 * 1024)) + "M"
}

function formatDuration(seconds) {
  var s = Math.max(0, Number(seconds) || 0)
  if (s < 3600) return Math.max(1, Math.round(s / 60)) + " min"
  if (s < 48 * 3600) return Math.round(s / 3600) + " h"
  return Math.round(s / 86400) + " days"
}

function relativeTime(ts, now) {
  var s = Math.max(0, (now - ts * 1000) / 1000)
  if (s < 60) return "just now"
  return formatDuration(s) + " ago"
}

// ------------------------------------------------------------ the bar

function parseMeminfo(text) {
  var f = {}
  String(text || "").split("\n").forEach(function(line) {
    var m = /^(\w+):\s+(\d+)/.exec(line)
    if (m) f[m[1]] = Number(m[2]) * 1024
  })
  if (!f.MemTotal) return null
  return {
    totalBytes: f.MemTotal,
    availableBytes: f.MemAvailable || 0,
    swapTotalBytes: f.SwapTotal || 0,
    swapUsedBytes: Math.max(0, (f.SwapTotal || 0) - (f.SwapFree || 0))
  }
}

// The parts of the config the bar needs; bin/memkeeper does the full clamping.
function clampConfig(raw) {
  raw = raw || {}
  function num(key, fallback) {
    var n = Number(raw[key])
    return raw[key] === undefined || raw[key] === null || !isFinite(n) ? fallback : n
  }
  return {
    warnAvailablePercent: num("warnAvailablePercent", 20),
    criticalAvailablePercent: num("criticalAvailablePercent", 10),
    warnSwapPercent: num("warnSwapPercent", 70),
    criticalSwapPercent: num("criticalSwapPercent", 85)
  }
}

function clampSettings(s) {
  s = s || {}
  return { barLabel: ["available", "percent", "none"].indexOf(s.barLabel) >= 0 ? s.barLabel : "available" }
}

function barLevel(mem, cfg) {
  if (!mem) return "ok"
  var available = mem.availableBytes * 100 / mem.totalBytes
  var swap = mem.swapTotalBytes > 0 ? mem.swapUsedBytes * 100 / mem.swapTotalBytes : 0
  if (available < cfg.criticalAvailablePercent || swap > cfg.criticalSwapPercent) return "critical"
  if (available < cfg.warnAvailablePercent || swap > cfg.warnSwapPercent) return "warn"
  return "ok"
}

function usedFraction(mem) {
  if (!mem || !mem.totalBytes) return 0
  return Math.max(0, Math.min(1, 1 - mem.availableBytes / mem.totalBytes))
}

function barText(mem, mode) {
  if (!mem || mode === "none") return ""
  if (mode === "percent") return Math.round(usedFraction(mem) * 100) + "%"
  return formatShort(mem.availableBytes)
}

function barTooltip(mem, level) {
  if (!mem) return "Memory Keeper"
  var text = formatBytes(mem.availableBytes) + " available of " + formatBytes(mem.totalBytes)
  if (mem.swapUsedBytes > 0) text += "\nSwap " + formatBytes(mem.swapUsedBytes)
  if (level === "critical") text += "\nMemory is running out: click to see what uses it"
  else if (level === "warn") text += "\nMemory is getting low"
  return text
}

function levelText(scan) {
  if (!scan || scan.level === "ok") return ""
  var why = { "low-available": "little memory available", "high-swap": "swap nearly full", "stalling": "apps are stalling on memory" }
  return (scan.reasons || []).map(function(r) { return why[r] || r }).join(", ")
}

// ------------------------------------------------------------ sessions

function sessionDetail(s, config) {
  if (s.status === "busy") return "working"
  if (s.status === "waiting") return "waiting for you"
  var base = s.status === "idle" ? "idle " + formatDuration(s.wallIdleSeconds) : s.status
  if (s.block === "keep") return base + " · kept"
  if (s.block === "running-work") return base + " · running " + (s.work || []).slice(0, 3).join(", ")
  if (s.block === "on-screen") return base + " · on screen"
  if (s.block === "not-herdr") return base + " · outside Herdr, stop it yourself"
  if (s.block === "terminal-unknown") return base + " · terminal not found"
  if (s.block === "not-interactive") return base + " · not interactive"
  if (!config || !config.auto) return base + " · auto-stop off"
  if (s.stopsInSeconds === null || s.stopsInSeconds === undefined) return base
  if (s.stopsInSeconds <= 0) return base + " · stops at the next check"
  return base + " · stops after " + formatDuration(s.stopsInSeconds) + " more"
}

// A plain idle session stops at once: Resume brings it back. These ask first.
function stopNeedsConfirm(s) {
  return s.status === "waiting" || s.block === "running-work" || s.block === "not-herdr" || s.block === "terminal-unknown"
}

function stopConfirmText(s) {
  if (s.block === "running-work") return "Stop " + s.name + "? It is running " + (s.work || []).join(", ") + ", which will end too."
  if (s.status === "waiting") return "Stop " + s.name + "? It is waiting for your answer."
  return "Stop " + s.name + "? Text typed in its input box cannot be saved, it runs outside Herdr."
}

function idleCandidates(scan) {
  if (!scan) return []
  return (scan.sessions || []).filter(function(s) {
    return s.status === "idle" && s.block === null && s.wallIdleSeconds >= MANUAL_MIN_IDLE
  })
}

function idleConfirmText(list) {
  var bytes = list.reduce(function(sum, s) { return sum + s.bytes }, 0)
  var names = list.slice(0, 6).map(function(s) { return s.name }).join(", ")
  if (list.length > 6) names += " and " + (list.length - 6) + " more"
  return "Stop " + list.length + (list.length === 1 ? " idle session" : " idle sessions") + " and free about " + formatBytes(bytes) + "?\n" + names
}

// ------------------------------------------------------------ rows

function buildRows(scan, settingsOpen) {
  var rows = []
  if (!scan) return rows
  function group(title, subtitle) { rows.push({ kind: "group", selectable: false, title: title, subtitle: subtitle || "" }) }

  rows.push({ kind: "auto", selectable: true, key: "auto" })

  var sessions = scan.sessions || []
  group("Claude sessions", sessions.length ? String(sessions.length) : "")
  sessions.forEach(function(s) { rows.push({ kind: "session", selectable: true, key: "s:" + s.sessionId, session: s }) })
  if (!sessions.length) rows.push({ kind: "note", selectable: false, text: "None running" })

  var stopped = scan.stopped || []
  if (stopped.length) {
    group("Stopped", "resume any time")
    stopped.forEach(function(e) { rows.push({ kind: "stopped", selectable: true, key: "x:" + e.sessionId, entry: e }) })
  }

  group("Using memory", "")
  ;(scan.apps || []).forEach(function(a) { rows.push({ kind: "app", selectable: true, key: "a:" + a.name, app: a }) })

  var leftovers = scan.leftovers || []
  if (leftovers.length) {
    group("Leftovers", "outlived their terminal")
    leftovers.forEach(function(l) { rows.push({ kind: "leftover", selectable: true, key: "l:" + l.pid, leftover: l }) })
  }

  rows.push({ kind: "settings", selectable: true, key: "settings" })
  if (settingsOpen) {
    SETTINGS.forEach(function(def) { rows.push({ kind: "setting", selectable: true, key: "o:" + def.key, def: def }) })
  }
  return rows
}

// What one row shows, and the actions it offers. The first action is what
// Enter does.
function rowView(row, scan, settingsOpen, now) {
  var cfg = scan ? scan.config : null
  var v = { title: "", detail: "", size: "", badge: "", icon: "", chevron: "", muted: false, actions: [] }
  if (row.kind === "auto") {
    v.title = "Auto-stop idle sessions"
    v.detail = cfg && cfg.auto ? "after " + cfg.idleHours + " h idle, not counting sleep" : "off: nothing stops on its own"
    v.actions = [{ id: "toggle-auto", label: cfg && cfg.auto ? "On" : "Off" }]
  } else if (row.kind === "session") {
    var s = row.session
    v.icon = GLYPH_CLAUDE
    v.title = s.name
    v.detail = sessionDetail(s, cfg)
    v.size = formatBytes(s.bytes)
    v.muted = s.status === "busy"
    if (s.status !== "busy") {
      v.actions.push({ id: "stop", label: "Stop" })
      v.actions.push({ id: "keep", label: s.keep ? "Kept" : "Keep" })
    }
  } else if (row.kind === "stopped") {
    var e = row.entry
    v.icon = GLYPH_PAUSED
    v.title = e.name
    v.detail = relativeTime(e.stoppedAt, now) + (e.inputText ? " · “" + e.inputText.replace(/\s+/g, " ") + "”" : "")
    v.size = formatBytes(e.freedBytes)
    v.actions.push({ id: "resume", label: "Resume" })
    if (e.inputText) v.actions.push({ id: "copy", label: "Copy text" })
  } else if (row.kind === "app") {
    v.icon = GLYPH_APP
    v.title = row.app.name
    v.size = formatBytes(row.app.bytes)
    if (row.app.name === "Omarchy shell" && row.app.bytes >= SHELL_RESTART_BYTES) {
      v.detail = "grown large; a restart gives it back"
      v.actions.push({ id: "restart-shell", label: "Restart" })
    }
  } else if (row.kind === "leftover") {
    var l = row.leftover
    v.icon = GLYPH_LEFTOVER
    v.title = l.label
    v.detail = (l.cwd || "") + " · " + formatDuration(l.ageSeconds)
    v.size = formatBytes(l.bytes)
    v.actions.push({ id: "stop-leftover", label: "Stop" })
  } else if (row.kind === "settings") {
    v.title = "Settings"
    v.chevron = settingsOpen ? GLYPH_EXPANDED : GLYPH_COLLAPSED
    v.actions = [{ id: "toggle-settings", label: "", hidden: true }]
  } else if (row.kind === "setting") {
    v.title = row.def.label
    v.size = (cfg ? cfg[row.def.key] : "") + " " + row.def.unit
    v.actions = [{ id: "dec", label: "−" }, { id: "inc", label: "+" }]
  }
  return v
}

function nextSelectable(rows, from, dir) {
  var i = from
  for (var step = 0; step < rows.length; step++) {
    i += dir
    if (i < 0 || i >= rows.length) return from
    if (rows[i].selectable) return i
  }
  return from
}

function firstSelectable(rows) {
  for (var i = 0; i < rows.length; i++) if (rows[i].selectable) return i
  return -1
}

function indexOfKey(rows, key) {
  for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return i
  return -1
}

function stopResultText(d) {
  if (!d) return "Something went wrong"
  if (!d.ok) return (d.name ? d.name + ": " : "") + (d.error || "failed")
  return "Stopped " + d.name + " · freed about " + formatBytes(d.freedBytes)
}

function stopIdleResultText(d) {
  if (!d || !d.results) return "Something went wrong"
  var done = d.results.filter(function(r) { return r.ok })
  var freed = done.reduce(function(sum, r) { return sum + r.freedBytes }, 0)
  var failed = d.results.length - done.length
  return "Stopped " + done.length + " · freed about " + formatBytes(freed) + (failed ? " · " + failed + " would not stop" : "")
}

function reclaimResultText(d) {
  if (!d) return "Something went wrong"
  if (!d.ok) return "Could not free cache: " + d.error
  if (!d.askedBytes) return "No cold cache to free"
  return "Free memory " + formatBytes(d.freeBefore) + " → " + formatBytes(d.freeAfter)
}
