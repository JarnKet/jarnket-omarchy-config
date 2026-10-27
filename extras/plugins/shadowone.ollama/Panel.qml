import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Ollama: a bar button and panel for the local LLM server. It shows whether the
// server runs, which models are on disk and in memory (and how much of each sits
// on the GPU), downloads models, runs a short Lao speed test, and picks the model
// Ask Claude answers with offline. All the work happens in bin/ollamactl; this
// file shows its JSON and sends commands back.
Panel {
  id: root
  moduleName: "shadowone.ollama"
  ipcTarget: "shadowone.ollama"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string helper: home + "/.config/omarchy/plugins/shadowone.ollama/bin/ollamactl"
  readonly property var recommended: [
    { name: "gemma4:26b-a4b-it-qat", note: "everyday, Lao + English · 16 GB" },
    { name: "gemma4:e4b-it-qat", note: "light and fast · 6 GB" },
    { name: "qwen3.6:35b-a3b", note: "automation, tools, code · 23 GB" }
  ]

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var status: null
  property string message: ""
  property bool messageIsError: false
  property string testing: ""
  property string pendingDelete: ""
  property string expanded: ""
  property string working: ""
  property double now: Date.now()

  readonly property bool running: !!(status && status.running)
  readonly property bool serviceKnown: !!(status && status.service && status.service.unit)
  readonly property bool serviceActive: !!(status && status.service && status.service.active === "active")
  readonly property bool serviceEnabled: !!(status && status.service && status.service.enabled === "enabled")
  readonly property var models: status && status.models ? status.models : []
  readonly property var loaded: status && status.loaded ? status.loaded : []
  readonly property var pull: status && status.pull ? status.pull : ({})
  readonly property bool pulling: pull.state === "running"
  readonly property var tests: status && status.tests ? status.tests : ({})
  readonly property string askModel: status && status.askModel ? status.askModel : ""
  readonly property var memory: status && status.memory ? status.memory : ({})
  readonly property var missingRecommended: recommended.filter(function(r) {
    var busy = root.pulling && (r.name === root.pull.model || (root.pull.queue || []).indexOf(r.name) >= 0)
    return !root.hasModel(r.name) && !busy
  })

  // The model Ask Claude really runs: same order as pick_local_model in bin/ask-claude.
  readonly property string askEffective: {
    var order = [askModel, "gemma4:26b-a4b-it-qat", "gemma4:26b-a4b", "gemma4:e4b-it-qat", "gemma4:e4b"]
    for (var i = 0; i < order.length; i++)
      if (order[i] !== "" && hasModel(order[i])) return order[i]
    return models.length > 0 ? models[0].name : ""
  }

  // "Radeon 880M · Vulkan" for the hero pill; "CPU only" says the GPU was not found.
  readonly property string gpuLabel: {
    var gpu = status && status.gpu ? status.gpu : null
    if (!gpu || !gpu.library) return ""
    if (gpu.library.toLowerCase() === "cpu") return "CPU only"
    var name = String(gpu.name || "").replace(/^(AMD|NVIDIA|Intel\(R\)|Intel)\s+/, "")
      .replace(/\s*\(.*\)\s*$/, "").replace(/\s+Graphics$/, "")
    return [name, gpu.library].filter(function(p) { return p !== "" }).join(" · ")
  }

  readonly property string barTip: {
    if (!status) return "Ollama"
    if (!running) return "Ollama: stopped"
    var parts = []
    if (loaded.length > 0) parts.push(loaded.map(function(l) { return root.label(l.name) }).join(", ") + " in memory")
    else parts.push(models.length + " models, none loaded")
    if (pulling) parts.push("downloading " + root.label(pull.model) + " " + root.percent(pull) + "%")
    return "Ollama: " + parts.join(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------ helpers

  function label(name) {
    var parts = String(name || "").split(":")
    var base = parts[0].split("/").pop()
    var tag = parts.length > 1 ? parts[1] : ""
    var m = /^([A-Za-z-]+?)-?(\d[\d.]*)?$/.exec(base)
    var family = (m ? m[1] : base).replace(/-/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
    var version = m && m[2] ? m[2] : ""
    var size = tag !== "" && tag !== "latest" ? tag.split("-")[0].toUpperCase() : ""
    return [family, version, size].filter(function(p) { return p !== "" }).join(" ")
  }

  function gb(bytes) {
    var n = Number(bytes || 0) / 1e9
    return (n >= 10 ? n.toFixed(0) : n.toFixed(1)) + " GB"
  }

  // Memory in binary units, as `free -h` shows it (model sizes stay decimal, like ollama.com).
  function gib(bytes) {
    var n = Number(bytes || 0) / 1073741824
    return (n >= 10 ? n.toFixed(0) : n.toFixed(1)) + " GiB"
  }

  function kilo(n) {
    n = Number(n || 0)
    return n >= 1024 ? Math.round(n / 1024) + "K" : String(n)
  }

  function percent(p) {
    return p && p.total ? Math.floor(100 * p.completed / p.total) : 0
  }

  function hasModel(name) {
    return root.models.some(function(m) { return m.name === name })
  }

  function loadedEntry(name) {
    for (var i = 0; i < root.loaded.length; i++) if (root.loaded[i].name === name) return root.loaded[i]
    return null
  }

  function untilText(iso) {
    var t = Date.parse(iso)
    if (isNaN(t)) return ""
    var minutes = Math.round((t - root.now) / 60000)
    if (minutes > 60 * 24 * 365) return "stays loaded"
    if (minutes <= 0) return "unloading"
    return "unloads in " + minutes + " min"
  }

  function loadedMeta(entry) {
    var share = entry.size ? Math.round(100 * entry.vram / entry.size) : 0
    var parts = [gb(entry.size), share >= 100 ? "all on GPU" : (share > 0 ? share + "% GPU, rest CPU" : "CPU only")]
    if (entry.context) parts.push("context " + kilo(entry.context))
    var until = untilText(entry.expires)
    if (until !== "") parts.push(until)
    return parts.join(" · ")
  }

  function modelMeta(m) {
    var parts = [m.params, m.quant, gb(m.size)]
    if (m.context) parts.push("context " + kilo(m.context))
    return parts.filter(function(p) { return p }).join(" · ")
  }

  function capabilityText(m) {
    var names = { vision: "images", tools: "tools", thinking: "thinking", insert: "fill-in", embedding: "embeddings" }
    return (m.capabilities || []).filter(function(c) { return names[c] }).map(function(c) { return names[c] }).join(" · ")
  }

  function pullText() {
    var p = root.pull
    if (!p.total) return (p.status || "starting") + "…"
    var parts = [root.percent(p) + "%", gb(p.completed) + " of " + gb(p.total)]
    if (p.speed > 0) {
      parts.push((p.speed / 1e6).toFixed(1) + " MB/s")
      var left = (p.total - p.completed) / p.speed
      parts.push(left > 3600 ? (left / 3600).toFixed(1) + " h left" : Math.max(1, Math.round(left / 60)) + " min left")
    }
    return parts.join(" · ")
  }

  function testText(t) {
    if (!t) return ""
    if (t.error) return "Test failed: " + t.error
    var parts = [t.tps + " tok/s"]
    if (t.promptTps) parts.push("reads " + t.promptTps + " tok/s")
    if (t.loadS >= 0.5) parts.push("load " + t.loadS + " s")
    parts.push(t.gpu >= 100 ? "all on GPU" : t.gpu + "% GPU")
    return parts.join(" · ")
  }

  function say(text, isError) {
    root.message = text
    root.messageIsError = !!isError
    messageTimer.restart()
  }

  // ------------------------------------------------------------ actions

  function refresh() {
    if (statusProc.running) return
    statusProc.command = root.opened ? [root.helper, "status", "--full"] : [root.helper, "status"]
    statusProc.running = true
  }

  function run(args, doing) {
    if (actionProc.running) return
    root.working = doing || ""
    actionProc.command = [root.helper].concat(args)
    actionProc.running = true
  }

  function toggleService() {
    if (!root.serviceKnown) {
      say("No ollama.service user unit found (~/.config/systemd/user/ollama.service).", true)
      return
    }
    run(["service", root.serviceActive ? "stop" : "start"], root.serviceActive ? "Stopping Ollama…" : "Starting Ollama…")
  }

  function toggleAutostart() {
    if (root.serviceKnown) run(["service", root.serviceEnabled ? "disable" : "enable"], "")
  }

  function startPull(name) {
    name = String(name || "").trim()
    if (name === "") return
    if (!root.running) {
      say("Start Ollama first.", true)
      return
    }
    Quickshell.execDetached([root.helper, "pull", name])
    say(root.pulling ? "Queued " + name + "." : "Downloading " + name + "…", false)
    pullInput.text = ""
    kick.restart()
  }

  function toggleLoad(name) {
    if (root.loadedEntry(name)) run(["unload", name], "Unloading " + root.label(name) + "…")
    else run(["load", name], "Loading " + root.label(name) + " into memory…")
  }

  function testModel(name) {
    if (testProc.running) return
    root.testing = name
    root.expanded = name
    testProc.command = [root.helper, "test", name]
    testProc.running = true
  }

  function removeModel(name) {
    if (root.pendingDelete !== name) {
      root.pendingDelete = name
      deleteTimer.restart()
      return
    }
    root.pendingDelete = ""
    run(["rm", name], "Deleting " + root.label(name) + "…")
  }

  // ------------------------------------------------------------ processes

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.status = JSON.parse(text) } catch (error) {}
        root.now = Date.now()
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(actionOut.text || "").trim()
      var err = String(actionErr.text || "").trim()
      root.working = ""
      if (exitCode !== 0) root.say(err || out || "Command failed.", true)
      else if (out !== "") root.say(out.split("\n").pop(), false)
      kick.restart()
    }
  }

  Process {
    id: testProc
    stdout: StdioCollector { id: testOut; waitForEnd: true }
    onExited: function(exitCode) {
      var result = null
      try { result = JSON.parse(String(testOut.text || "").trim()) } catch (error) {}
      if (!result || result.error) root.say("Test failed: " + (result ? result.error : "no answer"), true)
      root.testing = ""
      kick.restart()
    }
  }

  Timer {
    id: kick
    interval: 400
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.opened ? (root.pulling ? 1500 : 4000) : (root.pulling ? 10000 : 30000)
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: messageTimer
    interval: 6000
    onTriggered: root.message = ""
  }

  Timer {
    id: deleteTimer
    interval: 4000
    onTriggered: root.pendingDelete = ""
  }

  onOpenedChanged: if (opened) {
    root.now = Date.now()
    root.refresh()
    if (panelFlick) panelFlick.contentY = 0
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function pull(name: string): string { root.startPull(name); return "ok" }
    function state(): string { return JSON.stringify(root.status) }
  }

  // ------------------------------------------------------------ bar button

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚩"
    active: root.loaded.length > 0 || root.pulling
    activeColor: root.accent
    opacity: root.running ? 1 : 0.55
    tooltipText: root.opened ? "" : root.barTip
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(460))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "s" || t === "S") root.toggleService()
        else if (t === "/") pullInput.forceActiveFocus()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width - Style.space(6)
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Ollama"
            meta: !root.status ? "Checking…"
              : !root.running ? (root.status.installed ? "Stopped" : "Not installed")
              : "v" + root.status.version + " · " + (root.loaded.length > 0
                  ? root.loaded.map(function(l) { return root.label(l.name) }).join(", ") + " in memory"
                  : "idle, nothing in memory")
            detail: root.gpuLabel
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.running ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰚩"
                color: root.running ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: serviceSwitch
                checked: root.running
                busy: actionProc.running && root.working.indexOf("Ollama") >= 0
                foreground: hero.foreground
                onToggled: root.toggleService()

                PanelToolTip {
                  visible: serviceSwitch.containsMouse
                  text: root.running ? "Stop Ollama (frees all model memory)" : "Start Ollama"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }

          Text {
            visible: text !== ""
            width: parent.width
            textFormat: Text.PlainText
            text: root.working !== "" ? root.working : root.message
            color: root.messageIsError && root.working === "" ? root.urgent : root.dim
            wrapMode: Text.Wrap
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            InfoPair {
              label: "RAM available"
              value: root.gib(root.memory.ramAvailable) + " of " + root.gib(root.memory.ramTotal)
            }
            InfoPair {
              visible: !!root.memory.gttTotal
              label: "GPU memory in use"
              value: root.gib((root.memory.gttUsed || 0) + (root.memory.vramUsed || 0)) + " of "
                + root.gib((root.memory.gttTotal || 0) + (root.memory.vramTotal || 0))
            }
            InfoPair {
              visible: root.running
              label: "Models on disk"
              value: root.models.length + " · " + root.gb(root.status ? root.status.diskUsed : 0)
                + " (" + root.gb(root.status ? root.status.diskFree : 0) + " free)"
            }
            InfoPair {
              label: "Ask Claude offline"
              value: !root.running || root.askEffective === root.askModel
                ? (root.askModel !== "" ? root.label(root.askModel) : "Gemma 4 (default)")
                : root.askEffective === "" ? "no model yet"
                : root.label(root.askEffective) + " for now"
            }

            Item {
              width: parent.width
              height: autostartSwitch.implicitHeight
              visible: root.serviceKnown

              InfoLabel {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Start at login"
              }

              ToggleSwitch {
                id: autostartSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.serviceEnabled
                cursorRing: false
                foreground: root.foreground
                onToggled: root.toggleAutostart()
              }
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.loaded.length > 0 }

          Column {
            visible: root.loaded.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "IN MEMORY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.loaded

              RowLayout {
                required property var modelData
                width: parent.width
                spacing: Style.space(8)

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.label(modelData.name) + "   " + modelData.name
                    color: root.foreground
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: root.loadedMeta(modelData)
                    color: root.dim
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                PanelActionButton {
                  iconText: "󰇪"
                  tooltipText: "Unload (free memory)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  enabled: !actionProc.running
                  onClicked: root.run(["unload", modelData.name], "Unloading " + root.label(modelData.name) + "…")
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.running }

          Column {
            visible: root.running
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MODELS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              visible: root.models.length === 0
              width: parent.width
              textFormat: Text.PlainText
              text: "No models yet. Download one below."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Repeater {
              model: root.models
              ModelRow {
                required property var modelData
                width: parent.width
                info: modelData
              }
            }
          }

          PanelSeparator { foreground: root.foreground; visible: root.running }

          Column {
            visible: root.running
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "DOWNLOAD"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Column {
              visible: root.pulling
              width: parent.width
              spacing: Style.space(4)

              RowLayout {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: "󰇚  " + root.pull.model
                  color: root.foreground
                  elide: Text.ElideRight
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                PanelActionButton {
                  iconText: "󰅙"
                  tooltipText: "Cancel (pulling again resumes)"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.run(["cancel"], "")
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.darker(root.foreground, 3.2)

                Rectangle {
                  width: parent.width * Math.min(1, root.percent(root.pull) / 100)
                  height: parent.height
                  radius: parent.radius
                  color: root.accent
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.pullText() + ((root.pull.queue || []).length > 0
                  ? "\nNext: " + root.pull.queue.join(", ") : "")
                color: root.dim
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              visible: !root.pulling && !!root.pull.error
              width: parent.width
              textFormat: Text.PlainText
              text: "✕  " + (root.pull.error || "")
              color: root.urgent
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.missingRecommended

              CursorSurface {
                id: suggestion
                required property var modelData
                width: parent.width
                implicitHeight: suggestionRow.implicitHeight + Style.space(10)
                foreground: root.foreground
                hasCursor: suggestionMouse.containsMouse

                MouseArea {
                  id: suggestionMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.startPull(suggestion.modelData.name)
                }

                RowLayout {
                  id: suggestionRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: "󰇚"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: suggestion.modelData.name + "   " + suggestion.modelData.note
                    color: root.foreground
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: pullInput
                Layout.fillWidth: true
                foreground: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                placeholderText: "Model name, e.g. llama3.2:3b"
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.startPull(pullInput.text)
                    event.accepted = true
                  } else if (event.key === Qt.Key_Escape) {
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }

              PanelActionButton {
                iconText: "󰇚"
                tooltipText: root.pulling ? "Add to the download queue" : "Download"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: pullInput.text.trim() !== ""
                onClicked: root.startPull(pullInput.text)
              }

              PanelActionButton {
                iconText: "󰏌"
                tooltipText: "Browse models on ollama.com"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: Qt.openUrlExternally("https://ollama.com/library")
              }
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "R refresh   S start/stop   / download   Esc close"
            color: root.dim
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component ModelRow: Column {
    id: row
    property var info: ({})
    readonly property string name: info.name || ""
    readonly property var entry: root.loadedEntry(name)
    readonly property var test: root.tests[name] || null
    readonly property bool isAsk: root.askModel === name
    readonly property bool open: root.expanded === name

    spacing: Style.space(4)

    CursorSurface {
      width: parent.width
      implicitHeight: rowLayout.implicitHeight + Style.space(10)
      foreground: root.foreground
      hasCursor: rowMouse.containsMouse

      MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.expanded = row.open ? "" : row.name
      }

      RowLayout {
        id: rowLayout
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(4)

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: (row.entry ? "● " : "") + root.label(row.name) + (row.isAsk ? "   ★ Ask Claude" : "")
            color: row.entry ? root.accent : root.foreground
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: row.name + " · " + root.modelMeta(row.info)
            color: root.dim
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelActionButton {
          iconText: row.entry ? "󰓛" : "󰐊"
          tooltipText: row.entry ? "Unload (free memory)" : "Load into memory"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !actionProc.running
          onClicked: root.toggleLoad(row.name)
        }

        PanelActionButton {
          iconText: "󰓅"
          tooltipText: "Speed test (short Lao answer)"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !testProc.running
          onClicked: root.testModel(row.name)
        }

        PanelActionButton {
          iconText: row.isAsk ? "󰓎" : "󰓒"
          tooltipText: row.isAsk ? "Ask Claude uses this offline" : "Use in Ask Claude offline"
          foreground: row.isAsk ? root.accent : root.foreground
          fontFamily: root.fontFamily
          enabled: !actionProc.running && !row.isAsk
          onClicked: root.run(["use", row.name], "")
        }

        PanelActionButton {
          iconText: root.pendingDelete === row.name ? "󰄬" : "󰆴"
          tooltipText: root.pendingDelete === row.name ? "Click again to delete " + row.name : "Delete"
          foreground: root.pendingDelete === row.name ? root.urgent : root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          enabled: !actionProc.running
          onClicked: root.removeModel(row.name)
        }
      }
    }

    Column {
      visible: row.open
      width: parent.width
      leftPadding: Style.space(8)
      spacing: Style.space(4)

      Text {
        width: parent.width - Style.space(8)
        textFormat: Text.PlainText
        text: [row.info.family ? "Family " + row.info.family : "",
               root.capabilityText(row.info) !== "" ? "Can do " + root.capabilityText(row.info) : "",
               row.info.digest ? "id " + row.info.digest : ""].filter(function(p) { return p !== "" }).join(" · ")
        color: root.dim
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: root.testing === row.name
        width: parent.width - Style.space(8)
        textFormat: Text.PlainText
        text: "Testing… loading a big model the first time can take a minute."
        color: root.dim
        font.italic: true
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: !!row.test && root.testing !== row.name
        width: parent.width - Style.space(8)
        textFormat: Text.PlainText
        text: "󰓅  " + root.testText(row.test)
        color: root.foreground
        wrapMode: Text.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      TextEdit {
        visible: !!row.test && !!row.test.text && root.testing !== row.name
        width: parent.width - Style.space(8)
        readOnly: true
        selectByMouse: true
        textFormat: TextEdit.PlainText
        text: row.test ? row.test.text || "" : ""
        color: root.dim
        wrapMode: TextEdit.Wrap
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }
    }
  }

  component InfoPair: Item {
    property string label: ""
    property string value: ""

    width: parent.width
    height: Math.max(pairLabel.implicitHeight, pairValue.implicitHeight)

    InfoLabel {
      id: pairLabel
      anchors.left: parent.left
      text: parent.label
    }

    Text {
      id: pairValue
      anchors.right: parent.right
      anchors.left: pairLabel.right
      anchors.leftMargin: Style.space(12)
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.value
      color: root.foreground
      elide: Text.ElideLeft
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
