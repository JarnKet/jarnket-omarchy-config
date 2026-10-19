import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Talks to the diskkeeper CLI. A child of the bar widget rather than a
// service-kind plugin, so the widget can also live on the custom top bar.
//
// Idle cost: one short `diskkeeper status` process every pollMinutes.
// Scans only run when the panel opens or after a clean. Clean jobs are
// detached so a shell reload cannot kill them half way; their progress is
// read back from ~/.local/state/diskkeeper/jobs/current.json.
Item {
  id: root

  property var settings: ({})
  readonly property var cfg: Model.clampSettings(settings)

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string bin: pluginDir + "/bin/diskkeeper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/diskkeeper"

  property var status: null
  property var scan: null
  property bool scanning: false
  property string scanError: ""

  property var projects: null
  property bool projectsLoading: false
  property bool projectsExclusive: false

  property var exploreCache: ({})
  property string explorePath: ""
  property bool exploring: false
  readonly property var currentExplore: exploreCache[explorePath] || null

  property var job: null
  property string activeJob: ""
  property bool jobRunning: false
  property double jobStartedAt: 0

  property var history: null
  property var snapshots: null
  property bool snapshotsLoading: false
  property string message: ""
  property bool messageUrgent: false

  signal jobFinished(var job)

  function cli(args) { return ["/usr/bin/python3", "-IB", root.bin].concat(args) }
  function background(args) { return ["ionice", "-c3", "nice", "-n19"].concat(cli(args)) }

  function parse(text) {
    try { return JSON.parse(String(text || "")) } catch (e) { return null }
  }

  function say(text, urgent) {
    message = text
    messageUrgent = !!urgent
    messageTimer.restart()
  }

  Timer {
    id: messageTimer
    interval: 8000
    onTriggered: { root.message = ""; root.messageUrgent = false }
  }

  // ------------------------------------------------------------ status

  Timer {
    interval: root.cfg.pollMinutes * 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus(true)
  }

  function refreshStatus(notify) {
    if (statusProc.running) return
    var args = ["status", "--json", "--warn-gb", String(cfg.warnFreeGB), "--critical-gb", String(cfg.criticalFreeGB)]
    if (notify && cfg.notifications) args.push("--notify")
    statusProc.command = cli(args)
    statusProc.running = true
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parse(text)
        if (d && d.kind === "status") root.status = d
      }
    }
  }

  // ------------------------------------------------------------ scan

  FileView {
    id: scanFile
    path: root.stateDir + "/scan.json"
    printErrors: false
    onLoaded: {
      var d = root.parse(text())
      if (d && d.kind === "scan" && !root.scan) root.scan = d
    }
  }

  function runScan() {
    if (scanProc.running) return
    scanning = true
    scanError = ""
    scanProc.command = background(["scan", "--json"])
    scanProc.running = true
  }

  Process {
    id: scanProc
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: function(code) {
      root.scanning = false
      var d = root.parse(scanOut.text)
      if (d && d.kind === "scan") root.scan = d
      else root.scanError = "Scan failed (exit " + code + ")"
    }
  }

  // ------------------------------------------------------------ projects

  function loadProjects(exclusive) {
    if (projectsProc.running) return
    projectsLoading = true
    projectsExclusive = !!exclusive
    projectsProc.command = background(exclusive ? ["projects", "--json", "--exclusive"] : ["projects", "--json"])
    projectsProc.running = true
  }

  Process {
    id: projectsProc
    stdout: StdioCollector { id: projectsOut; waitForEnd: true }
    onExited: function(code) {
      root.projectsLoading = false
      var d = root.parse(projectsOut.text)
      if (d && d.kind === "projects") root.projects = d
      else root.say("Could not list projects", true)
    }
  }

  // ------------------------------------------------------------ explore

  function explore(rel, force) {
    rel = rel || ""
    explorePath = rel
    if (!force && exploreCache[rel]) return
    if (exploreProc.running) {
      exploreProc.pending = rel
      exploreProc.hasPending = true
      return
    }
    exploring = true
    exploreProc.requested = rel
    exploreProc.command = background(["explore", "--json", "--path", rel])
    exploreProc.running = true
  }

  // Drop cached listings of rel and every folder above it: their sizes changed.
  function forgetExplore(rel) {
    var copy = {}
    for (var k in exploreCache) {
      var above = k === "" || rel === k || rel.indexOf(k + "/") === 0
      if (!above) copy[k] = exploreCache[k]
    }
    exploreCache = copy
  }

  Process {
    id: exploreProc
    property string requested: ""
    property string pending: ""
    property bool hasPending: false
    stdout: StdioCollector { id: exploreOut; waitForEnd: true }
    onExited: function(code) {
      root.exploring = false
      var d = root.parse(exploreOut.text)
      if (d && d.kind === "explore" && !d.error) {
        var copy = Object.assign({}, root.exploreCache)
        copy[exploreProc.requested] = d
        root.exploreCache = copy
      } else if (exploreProc.requested === root.explorePath) {
        root.say("Cannot open this folder", true)
      }
      if (exploreProc.hasPending) {
        exploreProc.hasPending = false
        root.explore(exploreProc.pending, false)
      }
    }
  }

  function trash(entries) {
    if (trashProc.running || !entries.length) return
    trashProc.rels = entries.map(function(e) { return e.rel })
    trashProc.command = cli(["trash", "--json"].concat(trashProc.rels))
    trashProc.running = true
  }

  Process {
    id: trashProc
    property var rels: []
    stdout: StdioCollector { id: trashOut; waitForEnd: true }
    onExited: function(code) {
      var d = root.parse(trashOut.text)
      var done = d && d.results ? d.results.filter(function(r) { return r.status === "done" }).length : 0
      var failed = d && d.results ? d.results.filter(function(r) { return r.status !== "done" }) : []
      if (done) root.say("Moved " + done + " item" + (done === 1 ? "" : "s") + " to the Trash. Empty the Trash to free the space.", false)
      if (failed.length) root.say("Not moved: " + failed.map(function(r) { return r.rel.split("/").pop() + " (" + r.reason + ")" }).join(", "), true)
      trashProc.rels.forEach(function(rel) { root.forgetExplore(rel) })
      root.explore(root.explorePath, true)
    }
  }

  function keep(rel, add) {
    if (keepProc.running) return
    keepProc.rel = rel
    keepProc.command = cli(["keep", "--json", add ? "add" : "remove", rel])
    keepProc.running = true
  }

  Process {
    id: keepProc
    property string rel: ""
    stdout: StdioCollector { id: keepOut; waitForEnd: true }
    onExited: function(code) {
      var d = root.parse(keepOut.text)
      if (d && d.ok) root.say("Keep list: " + d.entry, false)
      root.forgetExplore(keepProc.rel)
      root.explore(root.explorePath, true)
    }
  }

  function openPath(rel, isDir) {
    var abs = rel ? root.home + "/" + rel : root.home
    var dir = isDir ? abs : abs.replace(/\/[^\/]*$/, "")
    Quickshell.execDetached(["xdg-open", dir])
  }

  function copyText(text) {
    Quickshell.execDetached(["wl-copy", "--", text])
  }

  // ------------------------------------------------------------ snapshots (asks for authentication)

  function loadSnapshots() {
    if (snapshotsProc.running) return
    snapshotsLoading = true
    snapshotsProc.command = cli(["snapshots", "--json"])
    snapshotsProc.running = true
  }

  Process {
    id: snapshotsProc
    stdout: StdioCollector { id: snapshotsOut; waitForEnd: true }
    onExited: function(code) {
      root.snapshotsLoading = false
      var d = root.parse(snapshotsOut.text)
      if (d && d.auth === "ok") root.snapshots = d.snapshots
      else if (d && d.auth === "cancelled") root.say("Authentication cancelled", false)
      else root.say(d && d.message ? d.message : "Could not list snapshots", true)
    }
  }

  // ------------------------------------------------------------ history

  function loadHistory() {
    if (historyProc.running) return
    historyProc.command = cli(["history", "--json", "--limit", "50"])
    historyProc.running = true
  }

  Process {
    id: historyProc
    stdout: StdioCollector { id: historyOut; waitForEnd: true }
    onExited: function(code) {
      var d = root.parse(historyOut.text)
      if (d && d.kind === "history") root.history = d
    }
  }

  // ------------------------------------------------------------ clean jobs

  function makeJobId() {
    var d = new Date()
    function pad(n) { return (n < 10 ? "0" : "") + n }
    return d.getFullYear() + pad(d.getMonth() + 1) + pad(d.getDate()) + "-" + pad(d.getHours()) + pad(d.getMinutes()) +
      pad(d.getSeconds()) + "-" + Math.floor(Math.random() * 65536).toString(16)
  }

  function startClean(targets, dryRun) {
    if (jobRunning || !targets || targets.length === 0) return ""
    var id = makeJobId()
    activeJob = id
    jobRunning = true
    jobStartedAt = Date.now()
    job = { job: id, state: "running", targets: targets, results: [], dryRun: !!dryRun }
    var args = ["clean", "--json", "--job", id]
    if (dryRun) args.push("--dry-run")
    Quickshell.execDetached(cli(args.concat(targets)))
    jobPoll.start()
    return id
  }

  Timer {
    id: jobPoll
    interval: 600
    repeat: true
    property int ticks: 0
    onTriggered: {
      ticks++
      jobFile.reload()
      // Every ~10 s ask the CLI whether the job still holds its lock, so a
      // crashed job does not leave the panel spinning forever.
      if (ticks % 16 === 0 && !jobCheck.running) {
        jobCheck.command = root.cli(["job", "--json"])
        jobCheck.running = true
      }
    }
  }

  FileView {
    id: jobFile
    path: root.stateDir + "/jobs/current.json"
    printErrors: false
    onLoaded: root.readJob(text())
  }

  function readJob(text) {
    var d = parse(text)
    if (!d || !jobRunning) return
    if (d.job !== activeJob) {
      if (Date.now() - jobStartedAt > 20000) stopJob("Another clean job is running", true)
      return
    }
    job = d
    if (d.state === "done") finishJob(d)
  }

  function finishJob(d) {
    jobRunning = false
    jobPoll.stop()
    activeJob = ""
    job = d
    jobFinished(d)
    if (d.dryRun) return
    refreshStatus(false)
    runScan()
    loadHistory()
    var touched = (d.targets || []).some(function(t) { return t.indexOf("projects:") === 0 })
    if (touched || projects) loadProjects(false)
    if (touched) exploreCache = ({})
  }

  function stopJob(text, urgent) {
    jobRunning = false
    jobPoll.stop()
    activeJob = ""
    if (text) say(text, urgent)
  }

  Process {
    id: jobCheck
    stdout: StdioCollector { id: jobCheckOut; waitForEnd: true }
    onExited: function(code) {
      var d = root.parse(jobCheckOut.text)
      if (!d) return
      if (!root.jobRunning && d.state === "running" && d.active) {
        // A job started before a shell reload: follow it.
        root.activeJob = d.job
        root.jobRunning = true
        root.jobStartedAt = Date.now()
        root.job = d
        jobPoll.start()
      } else if (root.jobRunning && d.job === root.activeJob && d.state === "interrupted") {
        root.stopJob("The clean job stopped unexpectedly", true)
        root.runScan()
      } else if (root.jobRunning && d.job === root.activeJob && d.state === "done") {
        root.finishJob(d)
      }
    }
  }

  Component.onCompleted: {
    jobCheck.command = cli(["job", "--json"])
    jobCheck.running = true
  }
}
