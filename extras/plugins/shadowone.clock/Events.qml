import QtQuick
import Quickshell
import Quickshell.Io
import "EventsModel.js" as EventsModel

// Google Calendar for the clock: talks to omacal (bin/omacal, Python) and
// reads back what it caches in ~/.local/state/omacal. A child of the bar
// widget rather than of the popup, so reminders keep running while the
// calendar is closed.
//
// Idle cost: one short `omacal sync` process every syncMinutes (a no-op when
// another monitor's clock just synced), and a reminder check riding on the
// clock's existing minute tick. Nothing polls except while a browser
// sign-in is in flight (one status.json read a second).
Item {
  id: root

  property var settings: ({})
  readonly property var cfg: EventsModel.clampSettings(settings)

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string bin: pluginDir + "/bin/omacal"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omacal"
  readonly property string setupUrl: "https://console.cloud.google.com/auth/clients"

  property date today: new Date()
  readonly property string currentMonth: EventsModel.monthKey(today.getFullYear(), today.getMonth())
  readonly property string nextMonth: EventsModel.shiftMonthKey(currentMonth, 1)
  readonly property var syncWindow: EventsModel.defaultWindow(currentMonth)
  // The month the popup shows; the panel sets it.
  property string viewMonth: currentMonth

  property var status: null
  property var monthData: ({})
  readonly property var index: EventsModel.dayIndex([monthData[currentMonth], monthData[nextMonth], monthData[viewMonth]])

  readonly property bool configured: !!status && status.configured === true
  readonly property var accounts: status && Array.isArray(status.accounts) ? status.accounts : []
  readonly property bool pending: !!status && !!status.pending
  property bool syncing: false
  property string message: ""

  // Event keys already handed to `omacal notify` in this session.
  property var fired: ({})
  property var notifyQueue: []
  property var queuedSync: null
  property double signInStartedAt: 0
  property string confirmRemove: ""

  readonly property var summary: ({
    message: root.message,
    pending: root.pending,
    configured: root.configured,
    accounts: root.accounts,
    syncing: root.syncing,
    online: status ? status.online : true,
    lastSync: status ? status.lastSync : 0
  })

  function cli(args) { return ["/usr/bin/python3", "-IB", root.bin].concat(args) }

  function parse(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function say(text) {
    root.message = text
    messageTimer.restart()
  }

  Timer {
    id: messageTimer
    interval: 8000
    onTriggered: root.message = ""
  }

  // ------------------------------------------------------------ cache files

  function monthPath(key) { return root.stateDir + "/months/" + key + ".json" }

  function storeMonth(path, text) {
    var key = String(path).replace(/^.*\//, "").replace(/\.json$/, "")
    var next = {}
    var keep = [root.currentMonth, root.nextMonth, root.viewMonth]
    for (var k in root.monthData) if (keep.indexOf(k) !== -1) next[k] = root.monthData[k]
    next[key] = EventsModel.parseMonth(text)
    root.monthData = next
    if (key === root.currentMonth || key === root.nextMonth) root.checkReminders()
  }

  function reloadAll() {
    statusFile.reload()
    currentFile.reload()
    nextFile.reload()
    viewFile.reload()
  }

  FileView {
    id: statusFile
    path: root.stateDir + "/status.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.status = root.parse(text())
    onLoadFailed: root.status = null
    onFileChanged: reload()
  }

  FileView {
    id: currentFile
    path: root.monthPath(root.currentMonth)
    watchChanges: true
    printErrors: false
    onLoaded: root.storeMonth(path, text())
    onLoadFailed: root.storeMonth(path, "")
    onFileChanged: reload()
  }

  FileView {
    id: nextFile
    path: root.monthPath(root.nextMonth)
    watchChanges: true
    printErrors: false
    onLoaded: root.storeMonth(path, text())
    onLoadFailed: root.storeMonth(path, "")
    onFileChanged: reload()
  }

  FileView {
    id: viewFile
    path: root.monthPath(root.viewMonth)
    watchChanges: true
    printErrors: false
    onLoaded: root.storeMonth(path, text())
    onLoadFailed: root.storeMonth(path, "")
    onFileChanged: reload()
  }

  // ------------------------------------------------------------ sync

  function requestSync(args) {
    var full = ["sync", "--json"].concat(args || []).concat(EventsModel.syncFlags(root.cfg))
    if (syncProc.running) {
      root.queuedSync = full
      return
    }
    root.syncing = true
    syncProc.command = root.cli(full)
    syncProc.running = true
  }

  // Periodic: the --max-age makes it a no-op when another monitor's clock
  // (or the popup opening) synced moments ago.
  function syncScheduled() { requestSync(["--max-age", String(Math.max(1, root.cfg.syncMinutes - 1))]) }
  function syncIfStale() { requestSync(["--max-age", "2"]) }
  function syncNow() { requestSync([]) }

  // Months outside the window the periodic sync keeps fresh are fetched when
  // first looked at, and refreshed when looked at again after a while.
  function ensureMonth(key) {
    if (!root.configured || EventsModel.inWindow(key, root.syncWindow)) return
    requestSync(["--month", key, "--max-age", String(EventsModel.STALE_MONTH_MINUTES)])
  }

  Timer {
    interval: root.cfg.syncMinutes * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.syncScheduled()
  }

  Process {
    id: syncProc
    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    onExited: function(code) {
      root.syncing = false
      root.reloadAll()
      var d = root.parse(syncOut.text)
      if (code !== 0 && code !== 3 && code !== 6 && code !== 7 && !(d && d.kind === "sync"))
        root.say("Sync failed (exit " + code + ")")
      if (root.queuedSync) {
        var next = root.queuedSync
        root.queuedSync = null
        root.syncing = true
        syncProc.command = root.cli(next)
        syncProc.running = true
      }
    }
  }

  // ------------------------------------------------------------ accounts

  // Detached: the browser round trip can take minutes and must survive a
  // shell reload. Progress comes back through status.json.
  function addAccount(loginHint) {
    var args = ["add"].concat(EventsModel.syncFlags(root.cfg))
    if (loginHint) args = args.concat(["--login-hint", loginHint])
    root.signInStartedAt = Date.now()
    Quickshell.execDetached(root.cli(args))
    signInPoll.restart()
  }

  Timer {
    id: signInPoll
    interval: 1000
    repeat: true
    onTriggered: {
      statusFile.reload()
      var st = root.status
      var result = st && st.lastResult
      if (result && result.at >= root.signInStartedAt && !st.pending) {
        stop()
        root.say(result.message)
        root.reloadAll()
      } else if (Date.now() - root.signInStartedAt > 330000) {
        stop()
      }
    }
  }

  // Two clicks: the first arms, the second (within 4 s) removes.
  function removeAccount(email) {
    if (root.confirmRemove !== email) {
      root.confirmRemove = email
      confirmTimer.restart()
      return
    }
    root.confirmRemove = ""
    if (removeProc.running) return
    removeProc.command = root.cli(["remove", email, "--json"].concat(EventsModel.syncFlags(root.cfg)))
    removeProc.running = true
  }

  Timer {
    id: confirmTimer
    interval: 4000
    onTriggered: root.confirmRemove = ""
  }

  Process {
    id: removeProc
    stdout: StdioCollector { id: removeOut; waitForEnd: true }
    onExited: function(code) {
      var d = root.parse(removeOut.text)
      root.say(d && d.ok ? "Removed " + d.email : "Could not remove the account")
      root.reloadAll()
    }
  }

  // ------------------------------------------------------------ links

  function openUrl(url) {
    if (!/^https:\/\//.test(String(url || ""))) return
    if (!Qt.openUrlExternally(url)) Quickshell.execDetached(["xdg-open", url])
  }

  function openSetup() { openUrl(root.setupUrl) }

  // ------------------------------------------------------------ reminders

  // Called by the bar widget on every minute tick, and when a month file
  // (re)loads.
  function tick(date) {
    if (date) root.today = date
    root.checkReminders()
  }

  function checkReminders() {
    var due = EventsModel.dueReminders([root.monthData[root.currentMonth], root.monthData[root.nextMonth]],
                                       Date.now(), root.cfg.reminderMinutes, root.fired)
    if (!due.length) return
    var fired = Object.assign({}, root.fired)
    var queue = root.notifyQueue.slice()
    for (var i = 0; i < due.length; i++) {
      fired[due[i].key] = true
      queue.push(due[i].key)
    }
    root.fired = fired
    root.notifyQueue = queue
    root.drainNotify()
  }

  function drainNotify() {
    if (notifyProc.running || !root.notifyQueue.length) return
    var queue = root.notifyQueue.slice()
    var key = queue.shift()
    root.notifyQueue = queue
    notifyProc.command = root.cli(["notify", key, "--json"])
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    onExited: root.drainNotify()
  }
}
