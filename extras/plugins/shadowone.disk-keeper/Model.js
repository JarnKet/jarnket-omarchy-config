.pragma library

// Pure logic for the Disk Keeper panel: formatting, settings, selection and
// the flat row lists the keyboard cursor walks. No QML types in here, so
// test/js/model.test.js can load it in node.

var GLYPH_DISK = String.fromCodePoint(0xF02CA)
var GLYPH_DISK_ALERT = String.fromCodePoint(0xF02CB)
var GLYPH_CHECKED = String.fromCodePoint(0xF0132)
var GLYPH_UNCHECKED = String.fromCodePoint(0xF0131)
var GLYPH_PARTIAL = String.fromCodePoint(0xF0856)
var GLYPH_EXPANDED = String.fromCodePoint(0xF0140)
var GLYPH_COLLAPSED = String.fromCodePoint(0xF0142)
var GLYPH_LOCK = String.fromCodePoint(0xF033E)
var GLYPH_REFRESH = String.fromCodePoint(0xF0450)
var GLYPH_FOLDER = String.fromCodePoint(0xF024B)
var GLYPH_FILE = String.fromCodePoint(0xF0214)
var GLYPH_LINK = String.fromCodePoint(0xF0337)
var GLYPH_UP = String.fromCodePoint(0xF005D)
var GLYPH_DONE = String.fromCodePoint(0xF012C)
var GLYPH_SKIP = String.fromCodePoint(0xF0156)
var GLYPH_OPEN = String.fromCodePoint(0xF0770)
var GLYPH_TRASH = String.fromCodePoint(0xF0A7A)
var GLYPH_KEEP = String.fromCodePoint(0xF0403)

var TABS = ["cleanup", "explore", "projects"]
var TAB_TITLES = { cleanup: "Clean up", explore: "Explore", projects: "Projects" }

function formatBytes(n) {
  n = Number(n) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  if (i === 0) return Math.round(n) + " B"
  if (i === 1) return Math.round(n) + " KB"
  return (n >= 100 ? n.toFixed(0) : n.toFixed(1)) + " " + units[i]
}

// "26G" / "740M" for the bar, where width matters.
function formatShort(n) {
  n = Number(n) || 0
  var gib = n / Math.pow(1024, 3)
  if (gib >= 100) return Math.round(gib) + "G"
  if (gib >= 1) return (gib >= 10 ? Math.round(gib) : gib.toFixed(1)) + "G"
  return Math.round(n / Math.pow(1024, 2)) + "M"
}

function estimateText(bytes, kind) {
  if (kind === "unknown") return "size unknown"
  return "~" + formatBytes(bytes)
}

function clampNumber(value, low, high, fallback) {
  var n = Number(value)
  if (value === undefined || value === null || value === "" || !isFinite(n)) return fallback
  return Math.max(low, Math.min(high, n))
}

function clampSettings(s) {
  s = s || {}
  var warn = clampNumber(s.warnFreeGB, 1, 2000, 20)
  var critical = clampNumber(s.criticalFreeGB, 0.5, 2000, 10)
  if (critical >= warn) critical = Math.max(0.5, warn / 2)
  var label = ["free", "percent", "none"].indexOf(s.barLabel) >= 0 ? s.barLabel : "free"
  return {
    warnFreeGB: warn,
    criticalFreeGB: critical,
    notifications: s.notifications !== false,
    pollMinutes: Math.round(clampNumber(s.pollMinutes, 1, 60, 5)),
    barLabel: label
  }
}

function usedFraction(status) {
  if (!status || !status.totalBytes) return 0
  return Math.max(0, Math.min(1, (status.totalBytes - status.freeBytes) / status.totalBytes))
}

function barText(status, mode) {
  if (!status) return ""
  if (mode === "percent") return Math.round(usedFraction(status) * 100) + "%"
  if (mode === "none") return ""
  return formatShort(status.freeBytes)
}

function barTooltip(status) {
  if (!status) return "Disk Keeper"
  var text = formatBytes(status.freeBytes) + " free of " + formatBytes(status.totalBytes) +
    " (" + Math.round(usedFraction(status) * 100) + "% used)"
  if (status.levelReason === "btrfs-metadata") text += "\nbtrfs metadata is nearly full"
  else if (status.level === "critical") text += "\nDisk almost full: click to clean up"
  else if (status.level === "warn") text += "\nRunning low: click to clean up"
  return text
}

function relativeTime(ts, now) {
  if (!ts) return "never"
  var s = Math.max(0, Math.round((now - ts * 1000) / 1000))
  if (s < 45) return "just now"
  if (s < 3600) return Math.round(s / 60) + " min ago"
  if (s < 86400) return Math.round(s / 3600) + " h ago"
  var d = Math.round(s / 86400)
  return d + (d === 1 ? " day ago" : " days ago")
}

function ageDays(ts, now) {
  if (!ts) return null
  return Math.floor((now - ts * 1000) / 86400000)
}

// ------------------------------------------------------------ categories

function visible(cat) {
  if (!cat || !cat.available) return false
  if (!cat.hiddenWhenEmpty) return true
  return (cat.bytes || 0) > 0 || (cat.items && cat.items.length > 0) || !!cat.note
}

function visibleCategories(scan) {
  if (!scan || !scan.categories) return []
  return scan.categories.filter(visible)
}

function categoryById(scan, id) {
  var cats = scan && scan.categories ? scan.categories : []
  for (var i = 0; i < cats.length; i++) if (cats[i].id === id) return cats[i]
  return null
}

function itemTarget(cat, item) { return cat.id + ":" + item.key }

function selectable(cat) {
  return !!cat && !cat.blocked && cat.available && (cat.itemized ? true : ((cat.bytes || 0) > 0 || cat.estimateKind === "unknown"))
}

// False when a category is shown only to explain something (nothing to pick).
function hasChoices(cat) {
  if (!selectable(cat)) return false
  if (!cat.itemized) return true
  if (cat.id === "snapshots") return true
  return cat.items.some(function(item) { return itemSelectable(cat, item) })
}

function itemSelectable(cat, item) {
  return selectable(cat) && cat.itemized && item.actionable && !item.blocked
}

// Selection is a plain object of target -> true. Whole categories use the
// category id; itemized ones one "id:key" per item.
function defaultSelection(scan) {
  var sel = {}
  visibleCategories(scan).forEach(function(cat) {
    if (!selectable(cat) || !cat.defaultSelected) return
    if (cat.itemized) {
      cat.items.forEach(function(item) {
        if (item.selected && itemSelectable(cat, item)) sel[itemTarget(cat, item)] = true
      })
    } else {
      sel[cat.id] = true
    }
  })
  return sel
}

function checkState(cat, sel) {
  if (!cat.itemized) return sel[cat.id] ? "all" : "none"
  var total = 0, picked = 0
  cat.items.forEach(function(item) {
    if (!itemSelectable(cat, item)) return
    total++
    if (sel[itemTarget(cat, item)]) picked++
  })
  if (picked === 0) return "none"
  return picked === total ? "all" : "some"
}

function checkGlyph(state) {
  return state === "all" ? GLYPH_CHECKED : (state === "some" ? GLYPH_PARTIAL : GLYPH_UNCHECKED)
}

function copySelection(sel) {
  var out = {}
  for (var k in sel) if (sel[k]) out[k] = true
  return out
}

function toggleCategory(cat, sel) {
  var out = copySelection(sel)
  if (!selectable(cat)) return out
  if (!cat.itemized) {
    if (out[cat.id]) delete out[cat.id]
    else out[cat.id] = true
    return out
  }
  var turnOn = checkState(cat, sel) !== "all"
  cat.items.forEach(function(item) {
    if (!itemSelectable(cat, item)) return
    var t = itemTarget(cat, item)
    if (turnOn) out[t] = true
    else delete out[t]
  })
  return out
}

function toggleItem(cat, item, sel) {
  var out = copySelection(sel)
  if (!itemSelectable(cat, item)) return out
  var t = itemTarget(cat, item)
  if (out[t]) delete out[t]
  else out[t] = true
  return out
}

function categorySelectedBytes(cat, sel) {
  if (!cat.itemized) return sel[cat.id] ? (cat.bytes || 0) : 0
  var sum = 0
  cat.items.forEach(function(item) { if (sel[itemTarget(cat, item)]) sum += item.bytes || 0 })
  return sum
}

function selectionSummary(scan, sel) {
  var bytes = 0, count = 0, root = false, unknown = false, extra = [], titles = []
  visibleCategories(scan).forEach(function(cat) {
    var state = checkState(cat, sel)
    if (state === "none") return
    count++
    bytes += categorySelectedBytes(cat, sel)
    if (cat.privilege === "root") root = true
    if (cat.estimateKind === "unknown") unknown = true
    if (cat.confirm === "extra") extra.push(cat.title)
    titles.push(cat.title)
  })
  return { bytes: bytes, count: count, needsRoot: root, unknown: unknown, extraConfirm: extra, titles: titles }
}

// Only targets that still exist in the scan, so a stale selection never
// sends something the user can no longer see.
function targetsFor(scan, sel) {
  var out = []
  visibleCategories(scan).forEach(function(cat) {
    if (!selectable(cat)) return
    if (!cat.itemized) {
      if (sel[cat.id]) out.push(cat.id)
      return
    }
    cat.items.forEach(function(item) {
      var t = itemTarget(cat, item)
      if (sel[t] && itemSelectable(cat, item)) out.push(t)
    })
  })
  return out
}

function confirmMessage(summary) {
  var lines = []
  var what = summary.count === 1 ? summary.titles[0] : summary.count + " categories"
  lines.push("Delete " + what + (summary.bytes > 0 ? ", about " + formatBytes(summary.bytes) : "") + "?")
  lines.push("This cannot be undone.")
  if (summary.needsRoot) lines.push("System items ask for your fingerprint or password.")
  return lines.join(" ")
}

function groupTitle(scan, id) {
  var groups = scan && scan.groups ? scan.groups : []
  for (var i = 0; i < groups.length; i++) if (groups[i].id === id) return groups[i]
  return { id: id, title: id, subtitle: "" }
}

// Flat list of rows for the Clean up tab: group headers (not cursor targets),
// categories, and the items of expanded categories.
function cleanupRows(scan, expanded) {
  var rows = []
  var lastGroup = ""
  visibleCategories(scan).forEach(function(cat) {
    if (cat.group !== lastGroup) {
      lastGroup = cat.group
      rows.push({ kind: "group", group: groupTitle(scan, cat.group), selectable: false })
    }
    rows.push({ kind: "category", cat: cat, selectable: true, expandable: cat.items.length > 0 || !!cat.note || !!cat.blocked })
    if (expanded[cat.id]) {
      if (cat.blocked) rows.push({ kind: "note", cat: cat, text: cat.blocked.detail, urgent: true, selectable: false })
      if (cat.note) rows.push({ kind: "note", cat: cat, text: cat.note, selectable: false })
      cat.items.slice(0, 60).forEach(function(item) {
        rows.push({ kind: "item", cat: cat, item: item, selectable: true })
      })
      if (cat.items.length > 60)
        rows.push({ kind: "note", cat: cat, text: (cat.items.length - 60) + " more not shown", selectable: false })
    }
  })
  return rows
}

function blockedText(blocked) {
  if (!blocked) return ""
  if (blocked.reason === "in-use") return "in use"
  if (blocked.reason === "kept") return "kept"
  if (blocked.reason === "app-running") return "app running"
  if (blocked.reason === "bad-name") return "unreadable name"
  if (blocked.reason === "helper-missing") return "needs setup"
  if (blocked.reason === "helper-outdated") return "update helper"
  if (blocked.reason === "inactive") return "switched off"
  if (blocked.reason === "stale") return "needs fix"
  if (blocked.reason === "reboot") return "restart needed"
  return blocked.reason
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

function rowKey(row) {
  if (!row) return ""
  if (row.kind === "category") return "c:" + row.cat.id
  if (row.kind === "item") return "i:" + row.cat.id + ":" + row.item.key
  if (row.kind === "project") return "p:" + row.project.path
  if (row.kind === "pitem") return "pi:" + row.item.key
  if (row.kind === "entry") return "e:" + row.entry.name
  if (row.kind === "up") return "up"
  return ""
}

function indexOfKey(rows, key) {
  for (var i = 0; i < rows.length; i++) if (rowKey(rows[i]) === key) return i
  return -1
}

// ------------------------------------------------------------ projects

function projectDefaultSelection(data) {
  var sel = {}
  if (!data || !data.projects) return sel
  data.projects.forEach(function(p) {
    p.items.forEach(function(item) { if (item.selected && item.eligible) sel["projects:" + item.key] = true })
  })
  return sel
}

function projectCheckState(project, sel) {
  var total = 0, picked = 0
  project.items.forEach(function(item) {
    if (!item.eligible) return
    total++
    if (sel["projects:" + item.key]) picked++
  })
  if (picked === 0) return "none"
  return picked === total ? "all" : "some"
}

function toggleProject(project, sel) {
  var out = copySelection(sel)
  var on = projectCheckState(project, sel) !== "all"
  project.items.forEach(function(item) {
    if (!item.eligible) return
    var t = "projects:" + item.key
    if (on) out[t] = true
    else delete out[t]
  })
  return out
}

function toggleProjectItem(item, sel) {
  var out = copySelection(sel)
  if (!item.eligible) return out
  var t = "projects:" + item.key
  if (out[t]) delete out[t]
  else out[t] = true
  return out
}

function projectRows(data, expanded) {
  var rows = []
  if (!data || !data.projects) return rows
  data.projects.forEach(function(p) {
    rows.push({ kind: "project", project: p, selectable: true })
    if (expanded[p.path]) p.items.forEach(function(item) { rows.push({ kind: "pitem", project: p, item: item, selectable: true }) })
  })
  return rows
}

function projectTargets(data, sel) {
  var out = []
  if (!data || !data.projects) return out
  data.projects.forEach(function(p) {
    p.items.forEach(function(item) { if (item.eligible && sel["projects:" + item.key]) out.push("projects:" + item.key) })
  })
  return out
}

function projectSelectionBytes(data, sel, exclusive) {
  var sum = 0
  if (!data || !data.projects) return 0
  data.projects.forEach(function(p) {
    p.items.forEach(function(item) {
      if (!sel["projects:" + item.key]) return
      sum += exclusive && item.exclusiveBytes !== null && item.exclusiveBytes !== undefined ? item.exclusiveBytes : item.bytes
    })
  })
  return sum
}

function reasonText(reason) {
  var map = {
    "tracked-by-git": "tracked by git",
    "not-ignored-by-git": "not in .gitignore",
    "no-git-proof": "not a git repo",
    "no-project-marker": "no project file",
    "kept": "kept",
    "bad-name": "unreadable name"
  }
  return map[reason] || reason || ""
}

// ------------------------------------------------------------ explore

function exploreRows(data) {
  var rows = []
  if (!data || !data.children) return rows
  if (data.path) rows.push({ kind: "up", selectable: true })
  data.children.forEach(function(entry) { rows.push({ kind: "entry", entry: entry, selectable: true }) })
  return rows
}

function entryGlyph(entry) {
  if (entry.type === "dir") return GLYPH_FOLDER
  if (entry.type === "link") return GLYPH_LINK
  return GLYPH_FILE
}

function breadcrumb(path) {
  if (!path) return ["~"]
  return ["~"].concat(path.split("/"))
}

// ------------------------------------------------------------ jobs

function jobProgress(job) {
  if (!job) return ""
  var done = (job.results || []).length
  var total = (job.targets || []).length
  if (job.state === "running") return (job.current ? job.current + " · " : "") + done + " of " + total
  return ""
}

function resultFor(job, target) {
  if (!job || !job.results) return null
  for (var i = job.results.length - 1; i >= 0; i--) if (job.results[i].target === target) return job.results[i]
  return null
}

function jobSummary(job) {
  if (!job || job.state !== "done") return ""
  var done = 0, skipped = 0, failed = 0
  ;(job.results || []).forEach(function(r) {
    if (r.status === "done") done++
    else if (r.status === "failed") failed++
    else skipped++
  })
  var text = job.dryRun ? "Dry run: would free ~" + formatBytes(job.estimateBytes) : "Freed " + formatBytes(job.measuredFreedBytes)
  var parts = []
  if (skipped) parts.push(skipped + " skipped")
  if (failed) parts.push(failed + " failed")
  if (job.auth === "cancelled") parts.push("system items cancelled")
  return text + (parts.length ? " · " + parts.join(", ") : "")
}

function resultText(r, dryRun) {
  if (!r) return ""
  if (r.status === "done") return dryRun ? "would remove" : GLYPH_DONE + " removed"
  if (r.status === "failed") return "failed"
  var map = { "in-use": "in use", "app-running": "app running", "auth-cancelled": "cancelled",
              "changed-since-scan": "changed", "not-a-candidate": "gone", "kept": "kept" }
  return map[r.reason] || "skipped"
}

// ------------------------------------------------------------ snapshots

// The scan cannot list snapshots without root, so once the user has
// authenticated the listing is merged in as the category's items.
function withSnapshots(scan, snapshots) {
  if (!scan || !scan.categories || !snapshots) return scan
  var out = Object.assign({}, scan)
  out.categories = scan.categories.map(function(cat) {
    if (cat.id !== "snapshots") return cat
    var copy = Object.assign({}, cat)
    copy.items = snapshots.map(function(s) {
      return {
        key: String(s.number), label: "#" + s.number + "  " + s.date, bytes: 0, mtime: 0, id: null,
        detail: (s.description || s.type) + (s.cleanup ? " · " + s.cleanup : "") + (s.protected ? " · always kept" : ""),
        actionable: !s.protected, blocked: s.protected ? { reason: "kept", detail: "newest, default or active" } : null,
        selected: false
      }
    })
    copy.note = copy.items.length ? "Space comes back gradually after deleting." : "No snapshots"
    return copy
  })
  return out
}

// Badge for a category row while a job runs or after it finished:
// { text, urgent } or null when the job did not touch the category.
function categoryResult(job, cat) {
  if (!job) return null
  var rs = (job.results || []).filter(function(r) { return r.target === cat.id || r.target.indexOf(cat.id + ":") === 0 })
  var asked = (job.targets || []).some(function(t) { return t === cat.id || t.indexOf(cat.id + ":") === 0 })
  if (!rs.length) return asked && job.state === "running" ? { text: "waiting…", urgent: false } : null
  var done = rs.filter(function(r) { return r.status === "done" }).length
  var failed = rs.filter(function(r) { return r.status === "failed" }).length
  var skipped = rs.length - done - failed
  if (failed) return { text: failed + " failed", urgent: true }
  if (!done) return { text: resultText(rs[0], job.dryRun), urgent: false }
  var text = job.dryRun ? "would remove" : GLYPH_DONE + " removed"
  if (skipped) text += " · " + skipped + " skipped"
  return { text: text, urgent: false }
}
