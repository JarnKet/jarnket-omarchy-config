function clampIndex(index, length) {
  if (length <= 0) return 0
  return Math.max(0, Math.min(length - 1, index))
}

function selectProfileIndex(index, delta, profiles) {
  var values = Array.isArray(profiles) ? profiles : []
  if (values.length === 0) return 0
  return clampIndex(index + delta, values.length)
}

function parseKeyValue(raw) {
  var next = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t")
    if (idx <= 0) continue
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim()
  }
  return next
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n")
  var list = []
  var active = ""
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    list.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  }
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪"
  if (name === "balanced") return "󰊚"
  if (name === "performance") return "󰓅"
  return "󰂄"
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {}
  var s = states || {}
  if (!(d && d.isPresent && !onBattery)) return false

  var fraction = batteryFraction(d)
  if (d.state === s.Discharging) return false
  if (d.state === s.PendingCharge) return true
  if (d.state === s.FullyCharged && fraction < 0.99) return true
  if (d.state !== s.Charging || fraction >= 0.99) return false

  return Number(d.changeRate || 0) <= 0.2 || Number(d.timeToFull || 0) >= 8 * 60 * 60
}

function batteryIcon(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
  var index = Math.max(0, Math.min(9, Math.floor(d.percentage * 10)))
  var threshold = chargeThresholdActive(d, onBattery, states)

  if (threshold) return defaultIcons[index]
  if (d.state === states.FullyCharged) return "󰂅"
  if (!onBattery) return chargingIcons[index]
  return defaultIcons[index]
}

function modeLabel(device, onBattery, states) {
  var d = device || {}
  if (!d.isPresent) return ""

  var percentage = d.isPresent ? d.percentage : 0
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold"
  if (onBattery) return "On battery"
  if (!onBattery && percentage >= 1) return "Fully charged"
  return "Charging"
}

function toNumber(value) {
  var n = parseFloat(value)
  return isFinite(n) ? n : 0
}

// Turns `battery-conservation --shell` key/value pairs into the panel's
// conservation + health state. Missing or bad values come back as 0 / "".
function parseCare(raw) {
  var kv = parseKeyValue(raw)
  return {
    loaded: Object.keys(kv).length > 0,
    supported: kv.supported === "yes",
    enabled: kv.enabled === "yes",
    start: Math.round(toNumber(kv.start)),
    end: Math.round(toNumber(kv.end)),
    health: toNumber(kv.health),
    fullWh: toNumber(kv.full_wh),
    designWh: toNumber(kv.design_wh),
    cycles: Math.round(toNumber(kv.cycles)),
    technology: kv.technology || "",
    model: kv.model || ""
  }
}

function healthCondition(health) {
  var h = toNumber(health)
  if (h <= 0) return ""
  if (h >= 80) return "Good"
  if (h >= 60) return "Fair"
  return "Worn"
}

function healthFraction(health) {
  return Math.max(0, Math.min(1, toNumber(health) / 100))
}

function healthPercentText(health) {
  var h = toNumber(health)
  return h > 0 ? Math.round(h) + "%" : "—"
}

function wearText(health) {
  var h = toNumber(health)
  if (h <= 0) return "—"
  return Math.max(0, Math.round(100 - h)) + "%"
}

function whText(value) {
  var n = toNumber(value)
  return n > 0 ? n.toFixed(1) + " Wh" : "—"
}

function careDescription(care) {
  var c = care || {}
  if (!(c.end > 0 && c.end < 100)) return "Keeps the battery below full to slow wear"
  if (c.start > 0 && c.start < c.end) return "Stops charging at " + c.end + "%, resumes below " + c.start + "%"
  return "Stops charging at " + c.end + "%"
}

// Rows the keyboard cursor visits, top to bottom. The profile row is always there.
function cursorRows(careVisible, hibernateVisible, delayVisible) {
  var rows = []
  if (careVisible) rows.push("care")
  if (hibernateVisible) rows.push("hibernate")
  if (delayVisible) rows.push("delay")
  rows.push("profile")
  return rows
}

// Up/down moves one row. A row that went away (the delay row once hibernation
// is off) falls back to the profile row.
function nextCursorRow(row, dy, rows) {
  var list = Array.isArray(rows) && rows.length > 0 ? rows : ["profile"]
  var idx = list.indexOf(row)
  if (idx < 0) return "profile"
  if (dy === 0) return row
  return list[clampIndex(idx + (dy < 0 ? -1 : 1), list.length)]
}

// ---------------------------------------------------------- hibernation

// The delays the root helper accepts, in the order the buttons show them.
function hibernateDelays() {
  return ["30min", "1h", "2h", "3h", "6h"]
}

function delayLabel(delay) {
  var m = /^(\d+)(min|h)$/.exec(String(delay || ""))
  return m ? m[1] + " " + m[2] : String(delay || "")
}

// Turns `hibernate-mode --shell` key/value pairs into the panel's state.
function parseHibernate(raw) {
  var kv = parseKeyValue(raw)
  return {
    loaded: Object.keys(kv).length > 0,
    supported: kv.supported === "yes",
    reason: kv.reason || "",
    enabled: kv.enabled === "yes",
    swapBytes: toNumber(kv.swap_bytes),
    delay: kv.delay || "",
    onAc: kv.on_ac !== "no",
    restart: kv.restart === "yes",
    freeGb: Math.round(toNumber(kv.free_gb)),
    needGb: Math.round(toNumber(kv.need_gb)),
    helper: kv.helper || "missing"
  }
}

// The delay to turn hibernation on with: the configured one when the helper
// accepts it, else 3 h.
function hibernateStartDelay(h) {
  var d = (h || {}).delay
  return hibernateDelays().indexOf(d) >= 0 ? d : "3h"
}

// Turning on makes a 16 GB swapfile unless one is already there.
function hibernateHasRoom(h) {
  var x = h || {}
  return x.enabled || x.swapBytes > 0 || !(x.needGb > 0) || x.freeGb >= x.needGb
}

// The state right after the helper succeeded, until the next read confirms it.
function hibernateAfter(h, action, delay) {
  var next = Object.assign({}, h || {})
  if (action === "on") { next.enabled = true; next.delay = delay }
  else if (action === "off") { next.enabled = false; next.restart = false }
  else if (action === "delay") next.delay = delay
  return next
}

function hibernateDescription(h, busy, error) {
  var x = h || {}
  if (error) return error
  if (busy === "on") return "Turning on: 16 GB swapfile and boot image, about a minute"
  if (busy === "off") return "Turning off: removing the swapfile and boot settings"
  if (busy === "delay") return "Saving the delay"
  if (!x.supported && !x.enabled) return x.reason || "Not available on this system"
  if (x.helper === "missing") return "One-time setup: click to install the helper (asks for your password)"
  if (x.helper === "outdated") return "The helper changed: click to reinstall it (asks for your password)"
  if (x.enabled) {
    if (x.restart) return "On after a restart: the boot entry changed"
    return "Lid closed: sleeps, then hibernates after " + delayLabel(x.delay) + (x.onAc ? "" : " on battery")
  }
  if (!hibernateHasRoom(x)) return "Needs " + x.needGb + " GB free on the disk (" + x.freeGb + " GB now)"
  return "Off: the lid only sleeps. Turning on uses 16 GB of disk"
}

if (typeof module !== "undefined") {
  module.exports = {
    clampIndex: clampIndex,
    selectProfileIndex: selectProfileIndex,
    parseKeyValue: parseKeyValue,
    parseProfiles: parseProfiles,
    profileIcon: profileIcon,
    batteryFraction: batteryFraction,
    chargeThresholdActive: chargeThresholdActive,
    batteryIcon: batteryIcon,
    modeLabel: modeLabel,
    parseCare: parseCare,
    healthCondition: healthCondition,
    healthFraction: healthFraction,
    healthPercentText: healthPercentText,
    wearText: wearText,
    whText: whText,
    careDescription: careDescription,
    cursorRows: cursorRows,
    nextCursorRow: nextCursorRow,
    hibernateDelays: hibernateDelays,
    delayLabel: delayLabel,
    parseHibernate: parseHibernate,
    hibernateStartDelay: hibernateStartDelay,
    hibernateHasRoom: hibernateHasRoom,
    hibernateAfter: hibernateAfter,
    hibernateDescription: hibernateDescription
  }
}
