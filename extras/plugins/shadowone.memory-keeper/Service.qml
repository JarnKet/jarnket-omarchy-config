import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Talks to bin/memkeeper. A child of the bar widget rather than a service-kind
// plugin, so the widget can also live on the custom top bar.
//
// Idle cost: reading /proc/meminfo every 30 s, no process at all. Scans only run
// while the panel is open. Stopping sessions on a schedule is not done here: the
// memory-keeper.timer user unit does it, so it keeps working through shell reloads.
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false
  readonly property var cfg: Model.clampSettings(settings)

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string bin: pluginDir + "/bin/memkeeper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string configFilePath: (Quickshell.env("XDG_CONFIG_HOME") || (home + "/.config")) + "/memory-keeper/config.json"

  property var mem: null
  property var config: Model.clampConfig(null)
  readonly property string level: Model.barLevel(mem, config)

  property var scan: null
  property bool scanning: false
  property bool acting: false
  property string message: ""
  property bool messageUrgent: false

  function cli(args) { return ["/usr/bin/python3", "-IB", root.bin].concat(args) }

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

  // ------------------------------------------------------------ the bar's number

  FileView {
    id: meminfoFile
    path: "/proc/meminfo"
    printErrors: false
    onLoaded: {
      var m = Model.parseMeminfo(text())
      if (m) root.mem = m
    }
  }

  Timer {
    interval: root.panelOpen ? 5000 : 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: meminfoFile.reload()
  }

  FileView {
    id: configFile
    path: root.configFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.config = Model.clampConfig(root.parse(text()))
  }

  // ------------------------------------------------------------ the panel's data

  Timer {
    interval: 30000
    repeat: true
    running: root.panelOpen
    onTriggered: root.runScan()
  }

  function runScan() {
    if (scanProc.running) return
    scanning = true
    scanProc.command = ["ionice", "-c3", "nice", "-n19"].concat(cli(["scan", "--json"]))
    scanProc.running = true
  }

  Process {
    id: scanProc
    stdout: StdioCollector { id: scanOut; waitForEnd: true }
    onExited: function(code) {
      root.scanning = false
      var d = root.parse(scanOut.text)
      if (d && d.kind === "scan") root.scan = d
      else root.say("Could not read memory use (exit " + code + ")", true)
    }
  }

  // ------------------------------------------------------------ actions

  function act(args, done) {
    if (actionProc.running) return
    acting = true
    actionProc.done = done || null
    actionProc.command = cli(args)
    actionProc.running = true
  }

  Process {
    id: actionProc
    property var done: null
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    onExited: function(code) {
      root.acting = false
      if (actionProc.done) actionProc.done(root.parse(actionOut.text), code)
      root.runScan()
    }
  }

  function stopSession(sid) {
    act(["stop", sid, "--json"], function(d) { root.say(Model.stopResultText(d), !d || !d.ok) })
  }

  function stopIdle() {
    act(["stop-idle", "--json"], function(d) { root.say(Model.stopIdleResultText(d), !d || !d.ok) })
  }

  function resumeSession(sid) {
    act(["resume", sid, "--json"], function(d) {
      if (d && d.ok) root.say("Resuming " + d.name, false)
      else {
        if (d && d.command) root.copyText(d.command)
        root.say((d && d.error ? d.error : "Could not resume") + (d && d.command ? ". Command copied." : ""), true)
      }
    })
  }

  function setKeep(sid, on) {
    act(on ? ["keep", sid] : ["keep", sid, "--off"])
  }

  function setConfig(key, value) {
    act(["config", "set", key, String(value)])
  }

  function reclaim() {
    act(["reclaim", "--json"], function(d) { root.say(Model.reclaimResultText(d), !d || !d.ok) })
  }

  function stopLeftover(pid, start) {
    act(["stop-process", String(pid), String(start), "--json"], function(d) {
      if (d && d.ok) root.say("Stopped · freed about " + Model.formatBytes(d.freedBytes), false)
      else root.say(d && d.error ? d.error : "Could not stop it", true)
    })
  }

  function restartShell() {
    Quickshell.execDetached(["omarchy", "restart", "shell"])
  }

  function copyText(text) {
    Quickshell.execDetached(["wl-copy", "--", text])
  }
}
