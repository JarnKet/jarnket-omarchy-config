// Pure helpers for the Google Calendar half of the clock: settings, month
// keys, bucketing events into days, agenda labels and reminder timing.
// Qt-free like Model.js, so tests/js runs it under node.
//
// Events come from omacal's month files (backend/omacal/normalize.py): each
// carries `days`, the local "YYYY-MM-DD" keys it touches (the same keys as
// Model.dateKey), so nothing here has to do time-zone math on dates.

var STALE_MONTH_MINUTES = 15

function clampInt(value, low, high, fallback) {
  var n = Number(value)
  if (value === null || value === undefined || value === "" || !isFinite(n)) return fallback
  return Math.max(low, Math.min(high, Math.round(n)))
}

function clampBool(value, fallback) {
  if (value === undefined || value === null) return fallback
  if (value === "false") return false
  return !!value
}

function clampSettings(settings) {
  var s = settings || {}
  return {
    syncMinutes: clampInt(s.syncMinutes, 5, 60, 10),
    reminderMinutes: clampInt(s.reminderMinutes, 0, 120, 10),
    hideDeclined: clampBool(s.hideDeclined, true),
    showEventDots: clampBool(s.showEventDots, true)
  }
}

// Extra flags every omacal call that syncs has to carry.
function syncFlags(cfg) {
  return cfg && cfg.hideDeclined === false ? ["--show-declined"] : []
}

function pad2(n) {
  return n < 10 ? "0" + n : String(n)
}

// month0 is 0-based, as in Date and Model.monthGrid.
function monthKey(year, month0) {
  return year + "-" + pad2(Number(month0) + 1)
}

function shiftMonthKey(key, delta) {
  var parts = String(key).split("-")
  var index = Number(parts[0]) * 12 + Number(parts[1]) - 1 + Number(delta)
  return monthKey(Math.floor(index / 12), ((index % 12) + 12) % 12)
}

// What a plain `omacal sync` keeps fresh: last month to two months ahead.
function defaultWindow(currentKey) {
  return [-1, 0, 1, 2].map(function(d) { return shiftMonthKey(currentKey, d) })
}

function inWindow(key, window) {
  return (window || []).indexOf(key) !== -1
}

// A parsed month file, or null when the text is not one.
function parseMonth(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!data || data.kind !== "month" || !Array.isArray(data.events)) return null
  return data
}

function compareEvents(a, b) {
  if (!!a.allDay !== !!b.allDay) return a.allDay ? -1 : 1
  if (a.start !== b.start) return a.start - b.start
  return String(a.title).toLowerCase() < String(b.title).toLowerCase() ? -1 : 1
}

// { "2026-10-21": [events sorted for the agenda] } from several month files.
// The same event can sit in two of them (it spans the month edge, or the
// viewed month is also the current one), so each day keeps it once.
function dayIndex(months) {
  var index = {}
  var seen = {}
  for (var m = 0; m < (months || []).length; m++) {
    var data = months[m]
    if (!data || !Array.isArray(data.events)) continue
    for (var i = 0; i < data.events.length; i++) {
      var ev = data.events[i]
      if (!ev || !Array.isArray(ev.days)) continue
      for (var d = 0; d < ev.days.length; d++) {
        var day = ev.days[d]
        var id = day + "|" + ev.key
        if (seen[id]) continue
        seen[id] = true
        if (!index[day]) index[day] = []
        index[day].push(ev)
      }
    }
  }
  for (var k in index) index[k].sort(compareEvents)
  return index
}

function eventsOn(index, dayKey) {
  return (index && index[dayKey]) || []
}

// Up to `max` dots per day, one per event, in agenda order.
function dotColors(index, dayKey, max, fallback) {
  var list = eventsOn(index, dayKey)
  var out = []
  for (var i = 0; i < list.length && out.length < (max || 3); i++)
    out.push(list[i].color || fallback || "#ffffff")
  return out
}

function keyForMs(ms) {
  var d = new Date(ms)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

function hhmm(ms) {
  var d = new Date(ms)
  return pad2(d.getHours()) + ":" + pad2(d.getMinutes())
}

// "All day", "09:30 – 10:00", or for a timed event crossing midnight,
// "22:00 →" on its first day and "→ 01:00" on its last.
function timeLabel(ev, dayKey) {
  if (!ev || ev.allDay) return "All day"
  var startsHere = keyForMs(ev.start) === dayKey
  var endsHere = keyForMs(Math.max(ev.start, ev.end - 1)) === dayKey
  if (startsHere && endsHere) return hhmm(ev.start) + " – " + hhmm(ev.end)
  if (startsHere) return hhmm(ev.start) + " →"
  if (endsHere) return "→ " + hhmm(ev.end)
  return "All day"
}

function subtitle(ev, showAccount) {
  var parts = []
  if (ev && ev.location) parts.push(ev.location)
  if (ev && showAccount && ev.account) parts.push(ev.account)
  return parts.join(" · ")
}

// Timed events whose reminder time has come and that have not started yet,
// skipping keys already handed to `omacal notify` this session. The backend
// dedupes again across monitors and restarts.
function dueReminders(months, nowMs, leadMinutes, fired) {
  var out = []
  if (!(leadMinutes > 0)) return out
  var lead = leadMinutes * 60000
  var seen = {}
  for (var m = 0; m < (months || []).length; m++) {
    var data = months[m]
    if (!data || !Array.isArray(data.events)) continue
    for (var i = 0; i < data.events.length; i++) {
      var ev = data.events[i]
      if (!ev || ev.allDay || seen[ev.key] || (fired && fired[ev.key])) continue
      seen[ev.key] = true
      if (ev.start - lead <= nowMs && nowMs < ev.start) out.push(ev)
    }
  }
  return out
}

function agoLabel(ms, nowMs) {
  if (!ms) return "never"
  var minutes = Math.floor((nowMs - ms) / 60000)
  if (minutes < 1) return "just now"
  if (minutes < 60) return minutes + " min ago"
  if (minutes < 24 * 60) return Math.floor(minutes / 60) + " h ago"
  return hhmm(ms) + " " + keyForMs(ms)
}

// The one line under the agenda.
function statusLine(state, nowMs) {
  var s = state || {}
  if (s.message) return s.message
  if (s.pending) return "Waiting for sign-in in the browser…"
  if (!s.configured) return "Google Calendar is not set up"
  var accounts = s.accounts || []
  if (!accounts.length) return "No Google account connected"
  if (s.syncing) return "Syncing…"
  var head = accounts.length + (accounts.length === 1 ? " account" : " accounts")
  var attention = accounts.filter(function(a) { return a.state === "needsReauth" || a.state === "error" }).length
  if (attention) head = attention + " of " + accounts.length + " need attention"
  if (s.online === false) return "Offline · synced " + (s.lastSync ? hhmm(s.lastSync) : "never")
  return head + " · synced " + agoLabel(s.lastSync, nowMs)
}

function accountStateLabel(state) {
  if (state === "needsReauth") return "signed out"
  if (state === "offline") return "offline"
  if (state === "error") return "error"
  if (state === "new") return "not synced yet"
  return ""
}

function needsAttention(state) {
  return state === "needsReauth" || state === "error"
}

if (typeof module !== "undefined") {
  module.exports = {
    STALE_MONTH_MINUTES: STALE_MONTH_MINUTES,
    clampSettings: clampSettings,
    syncFlags: syncFlags,
    monthKey: monthKey,
    shiftMonthKey: shiftMonthKey,
    defaultWindow: defaultWindow,
    inWindow: inWindow,
    parseMonth: parseMonth,
    dayIndex: dayIndex,
    eventsOn: eventsOn,
    dotColors: dotColors,
    keyForMs: keyForMs,
    hhmm: hhmm,
    timeLabel: timeLabel,
    subtitle: subtitle,
    dueReminders: dueReminders,
    agoLabel: agoLabel,
    statusLine: statusLine,
    accountStateLabel: accountStateLabel,
    needsAttention: needsAttention
  }
}
