import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Ask Claude: a bar button (and SUPER+A) that opens a quick-ask card centred on
// the bar. bin/ask-claude runs `claude -p` on Sonnet with the Claude
// subscription the CLI is signed in to, or a local Ollama model when offline
// (or when the backend switch says so), and streams JSON lines back; follow-ups
// resume the same session until New chat, or until the card opens after half
// an hour of quiet.
Panel {
  id: root
  moduleName: "shadowone.ask-claude"
  ipcTarget: "shadowone.ask-claude"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string helper: home + "/.config/omarchy/plugins/shadowone.ask-claude/bin/ask-claude"
  readonly property string stateDir: home + "/.local/state/ask-claude"
  readonly property string configDir: home + "/.config/ask-claude"
  readonly property int staleAfterMs: 30 * 60 * 1000
  readonly property var backendModes: ["auto", "cloud", "local"]

  // auto | cloud | local, kept in ~/.config/ask-claude/backend (read by bin/ask-claude too)
  property string backendMode: "auto"
  property string localModel: ""
  // What answered the current conversation: cloud | local, and its label.
  property string backendKind: ""
  property string backendLabel: ""
  property string speedLabel: ""

  readonly property color fg: root.barForeground
  readonly property color dim: Qt.darker(fg, 1.6)
  readonly property bool busy: proc.running
  readonly property real maxConversationHeight: Math.max(Style.space(160),
    Math.min(Style.space(560), panel.availableCardHeight - Style.space(150)))

  property string sessionId: ""
  property double lastActivity: 0
  property var limits: ({})
  property var asked: []
  property int recallIndex: -1
  property string answerBuffer: ""
  property bool stopRequested: false
  property string lastAnswerText: ""

  readonly property string limitLabel: {
    var window = root.limits ? root.limits.five_hour : null
    if (!window || window.used === undefined || window.used === null) return ""
    return "5h limit " + Math.round(Number(window.used) * 100) + "% used"
  }

  readonly property string localLabel: root.localModel !== "" ? root.modelLabel(root.localModel) : "local model"

  readonly property string headerLabel: {
    if (root.backendKind === "local")
      return root.backendLabel + " · local" + (root.speedLabel !== "" ? "  ·  " + root.speedLabel : "")
    if (root.backendKind === "cloud")
      return "Sonnet 5.5" + (root.limitLabel !== "" ? "  ·  " + root.limitLabel : "")
    if (root.backendMode === "local") return root.localLabel + " · local"
    if (root.backendMode === "cloud") return "Sonnet 5.5" + (root.limitLabel !== "" ? "  ·  " + root.limitLabel : "")
    return "Auto: Sonnet 5.5, " + root.localLabel + " offline"
  }

  readonly property string backendGlyph: root.backendMode === "local" ? "󰌢"
    : (root.backendMode === "cloud" ? "󰅟" : "󰁪")

  readonly property string backendTip: (root.backendMode === "local" ? "Local only: " + root.localLabel
    : (root.backendMode === "cloud" ? "Claude only (needs internet)"
      : "Auto: Claude online, " + root.localLabel + " offline")) + "  (Ctrl+L to switch)"

  // q, a, note, status (streaming | done | stopped | error), err, via
  ListModel { id: turns }

  FileView {
    id: backendFile
    path: root.configDir + "/backend"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var mode = String(text()).trim()
      root.backendMode = root.backendModes.indexOf(mode) >= 0 ? mode : "auto"
    }
  }

  FileView {
    id: localModelFile
    path: root.configDir + "/local-model"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.localModel = String(text()).trim()
  }

  // gemma4:26b-a4b-it-qat -> Gemma 4 26B (same rule as bin/ask-claude).
  function modelLabel(name) {
    var parts = String(name).split(":")
    var base = parts[0].split("/").pop()
    var tag = parts.length > 1 ? parts[1] : ""
    var m = /^([A-Za-z-]+?)-?(\d[\d.]*)?$/.exec(base)
    var family = (m ? m[1] : base).replace(/-/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
    var version = m && m[2] ? m[2] : ""
    var size = tag !== "" && tag !== "latest" ? tag.split("-")[0].toUpperCase() : ""
    return [family, version, size].filter(function(p) { return p !== "" }).join(" ")
  }

  function setBackend(mode) {
    if (root.backendModes.indexOf(mode) < 0) return
    root.backendMode = mode
    backendFile.setText(mode + "\n")
  }

  function cycleBackend() {
    setBackend(root.backendModes[(root.backendModes.indexOf(root.backendMode) + 1) % root.backendModes.length])
  }

  function open() {
    if (!root.busy && turns.count > 0 && Date.now() - root.lastActivity > root.staleAfterMs) newChat()
    root.controller.show()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function newChat() {
    stop()
    turns.clear()
    root.sessionId = ""
    root.backendKind = ""
    root.backendLabel = ""
    root.speedLabel = ""
    root.answerBuffer = ""
    root.lastAnswerText = ""
    input.text = ""
  }

  function ask(text) {
    var question = String(text || "").trim()
    if (question === "" || root.busy) return
    turns.append({ q: question, a: "", note: "", status: "streaming", err: "", via: "" })
    root.asked = root.asked.concat([question]).slice(-50)
    root.recallIndex = -1
    root.answerBuffer = ""
    root.stopRequested = false
    root.lastActivity = Date.now()
    var command = [root.helper, "--json"]
    if (root.sessionId !== "") command.push("--session", root.sessionId)
    command.push("--", question)
    proc.command = command
    proc.running = true
    input.text = ""
    conversation.stickToBottom = true
  }

  function stop() {
    if (!root.busy) return
    root.stopRequested = true
    proc.running = false
  }

  function flushAnswer() {
    var i = turns.count - 1
    if (i < 0) return
    turns.setProperty(i, "a", root.answerBuffer)
    if (root.answerBuffer !== "") root.lastAnswerText = root.answerBuffer
  }

  function handleLine(line) {
    var event
    try { event = JSON.parse(line) } catch (error) { return }
    var i = turns.count - 1
    if (i < 0) return
    if (event.t === "session") {
      root.sessionId = event.id || root.sessionId
    } else if (event.t === "backend") {
      root.backendKind = event.kind || ""
      root.backendLabel = event.label || ""
      if (event.kind === "local") turns.setProperty(i, "via", root.backendLabel + " · local")
    } else if (event.t === "note") {
      turns.setProperty(i, "note", "󰍛  " + (event.d || ""))
    } else if (event.t === "text") {
      root.answerBuffer += event.d
      if (turns.get(i).note !== "") turns.setProperty(i, "note", "")
      if (!flushTimer.running) flushTimer.start()
    } else if (event.t === "tool") {
      var label = event.name === "WebSearch" ? "Searching the web: "
        : event.name === "WebFetch" ? "Reading: " : event.name + ": "
      turns.setProperty(i, "note", "󰖟  " + label + (event.detail || ""))
    } else if (event.t === "done") {
      root.sessionId = event.id || root.sessionId
      if (event.limits) root.limits = event.limits
      if (event.stats && event.stats.tps) {
        root.speedLabel = event.stats.tps + " tok/s"
        turns.setProperty(i, "via", (event.stats.label || root.backendLabel) + " · local · "
          + event.stats.tps + " tok/s · " + (event.ms / 1000).toFixed(1) + " s")
      }
      flushAnswer()
      turns.setProperty(i, "note", "")
      turns.setProperty(i, "status", "done")
    } else if (event.t === "error") {
      flushAnswer()
      turns.setProperty(i, "note", "")
      turns.setProperty(i, "err", event.message || "Something went wrong.")
      turns.setProperty(i, "status", "error")
    }
  }

  function finishTurn(exitCode) {
    flushTimer.stop()
    var i = turns.count - 1
    if (i < 0) return
    flushAnswer()
    turns.setProperty(i, "note", "")
    if (turns.get(i).status === "streaming") {
      if (root.stopRequested) {
        turns.setProperty(i, "status", "stopped")
      } else {
        turns.setProperty(i, "err", "ask-claude exited with status " + exitCode + ".")
        turns.setProperty(i, "status", "error")
      }
    }
    root.lastActivity = Date.now()
  }

  function copyLastAnswer() {
    root.copyText(root.lastAnswerText)
    if (root.lastAnswerText !== "") copyAnswerButton.confirm()
  }

  // Hand the conversation to the full Claude Code CLI in a terminal (cloud
  // conversations only; local ones live in ask-claude's own files).
  function continueInTerminal() {
    if (root.sessionId === "" || root.busy || root.backendKind === "local") return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--dir=" + root.stateDir,
                             "claude", "--resume", root.sessionId])
    root.close()
  }

  function recall(direction) {
    if (root.asked.length === 0) return
    var next = root.recallIndex === -1 ? (direction < 0 ? root.asked.length - 1 : -1)
      : root.recallIndex + direction
    if (next < 0 && root.recallIndex === -1) return
    if (next >= root.asked.length || next < 0) {
      root.recallIndex = -1
      input.text = ""
      return
    }
    root.recallIndex = next
    input.text = root.asked[next]
    input.cursorPosition = input.text.length
  }

  function scrollBy(fraction) {
    conversation.contentY = Math.max(0, Math.min(conversation.contentHeight - conversation.height,
      conversation.contentY + conversation.height * fraction))
    conversation.stickToBottom = conversation.atYEnd
  }

  // Split an answer into Markdown runs and fenced code blocks, so code gets its
  // own box and copy button. An unclosed fence (still streaming) counts as code.
  function segments(text) {
    var out = []
    var lines = String(text || "").split("\n")
    var buffer = []
    var inCode = false
    var indent = 0
    function push(kind) {
      var joined = buffer.join("\n")
      if (kind === "code" || joined.trim() !== "") out.push({ kind: kind, text: joined })
      buffer = []
    }
    for (var i = 0; i < lines.length; i++) {
      var fence = /^(\s*)(```|~~~)[\w+.-]*\s*$/.exec(lines[i])
      if (fence) {
        push(inCode ? "code" : "md")
        inCode = !inCode
        indent = fence[1].length
      } else if (inCode && indent > 0) {
        // Code inside a list item carries the fence's indentation.
        buffer.push(lines[i].replace(new RegExp("^ {0," + indent + "}"), ""))
      } else {
        buffer.push(lines[i])
      }
    }
    push(inCode ? "code" : "md")
    return out
  }

  // Keys pressed while an answer has focus (after selecting text in it).
  function answerKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.close()
      event.accepted = true
    } else if (event.text !== "" && !(event.modifiers & Qt.ControlModifier)) {
      input.forceActiveFocus()
      input.insert(input.cursorPosition, event.text)
      event.accepted = true
    }
  }

  function copyText(text) {
    if (text !== "") Quickshell.execDetached(["wl-copy", "--", text])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Timer {
    id: flushTimer
    interval: 50
    onTriggered: root.flushAnswer()
  }

  Process {
    id: proc
    stdout: SplitParser {
      onRead: function(line) { root.handleLine(line) }
    }
    onExited: function(exitCode) { root.finishTurn(exitCode) }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function ask(question: string): void { root.open(); root.ask(question) }
    function newChat(): void { root.newChat() }
    function setBackend(mode: string): void { root.setBackend(mode) }
    function backend(): string { return root.backendMode }
  }

  component HeaderButton: Rectangle {
    id: headerButton
    property string glyph: ""
    property string tip: ""
    property bool confirmed: false
    signal clicked()

    // Brief check mark after a copy.
    function confirm() {
      confirmed = true
      confirmTimer.restart()
    }

    Timer {
      id: confirmTimer
      interval: 1200
      onTriggered: headerButton.confirmed = false
    }

    width: Style.space(26)
    height: Style.space(26)
    radius: Math.min(4, Style.cornerRadius)
    color: headerArea.containsMouse && headerButton.enabled
      ? Style.hoverFillFor(root.fg, Commons.Color.accent) : "transparent"
    opacity: enabled ? 1 : 0.35

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: headerButton.confirmed ? "󰄬" : headerButton.glyph
      color: root.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    MouseArea {
      id: headerArea
      anchors.fill: parent
      hoverEnabled: true
      enabled: headerButton.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: headerButton.clicked()
    }

    PanelToolTip {
      visible: headerArea.containsMouse && headerButton.tip !== ""
      text: headerButton.tip
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰙴"
    active: root.busy
    activeColor: Commons.Color.accent
    tooltipText: root.opened ? "" : "Ask Claude  (Super+A)"
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        root.newChat()
        root.open()
      } else {
        root.toggle()
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: input
    contentWidth: panel.fittedContentWidth(Style.space(640))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      spacing: Style.space(12)

      Item {
        width: parent.width
        height: Math.max(titleRow.implicitHeight, actions.implicitHeight)

        Row {
          id: titleRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰙴"
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.heading
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Ask Claude"
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.headerLabel
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: actions
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          HeaderButton {
            glyph: root.backendGlyph
            tip: root.backendTip
            onClicked: root.cycleBackend()
          }

          HeaderButton {
            id: copyAnswerButton
            glyph: "󰆏"
            tip: "Copy answer  (Ctrl+Shift+C)"
            enabled: root.lastAnswerText !== ""
            onClicked: root.copyLastAnswer()
          }

          HeaderButton {
            glyph: "󰆍"
            tip: "Continue in Claude Code  (Ctrl+T)"
            enabled: root.sessionId !== "" && !root.busy && root.backendKind !== "local"
            onClicked: root.continueInTerminal()
          }

          HeaderButton {
            glyph: "󰐕"
            tip: "New chat  (Ctrl+N)"
            enabled: turns.count > 0
            onClicked: root.newChat()
          }
        }
      }

      Flickable {
        id: conversation
        property bool stickToBottom: true

        function scrollToEnd() { contentY = Math.max(0, contentHeight - height) }

        width: parent.width
        visible: turns.count > 0
        height: visible ? Math.min(turnColumn.implicitHeight, root.maxConversationHeight) : 0
        contentWidth: width
        contentHeight: turnColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onContentHeightChanged: if (stickToBottom) scrollToEnd()
        onHeightChanged: if (stickToBottom) scrollToEnd()
        onMovementEnded: stickToBottom = atYEnd

        ScrollBar.vertical: ScrollBar {
          policy: conversation.contentHeight > conversation.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        Column {
          id: turnColumn
          width: conversation.width - Style.space(10)
          spacing: Style.space(16)

          Repeater {
            model: turns

            delegate: Column {
              required property string q
              required property string a
              required property string note
              required property string status
              required property string err
              required property string via

              width: turnColumn.width
              spacing: Style.space(6)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "› " + q
                wrapMode: Text.Wrap
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.segments(a)

                delegate: Item {
                  id: segment
                  required property var modelData
                  readonly property bool isCode: modelData.kind === "code"

                  width: turnColumn.width
                  height: isCode ? codeBox.height : markdownText.height

                  TextEdit {
                    id: markdownText
                    visible: !segment.isCode
                    width: parent.width
                    readOnly: true
                    selectByMouse: true
                    textFormat: TextEdit.MarkdownText
                    text: segment.isCode ? "" : segment.modelData.text
                    wrapMode: TextEdit.Wrap
                    color: root.fg
                    selectionColor: Style.selectionFillFor(root.fg, Commons.Color.accent)
                    selectedTextColor: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.subtitle
                    onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                    Keys.onPressed: function(event) { root.answerKey(event) }

                    HoverHandler {
                      cursorShape: markdownText.hoveredLink !== "" ? Qt.PointingHandCursor : Qt.IBeamCursor
                    }
                  }

                  Rectangle {
                    id: codeBox
                    visible: segment.isCode
                    width: parent.width
                    height: visible ? Math.max(codeText.implicitHeight, codeCopy.height) + Style.space(16) : 0
                    radius: Math.min(4, Style.cornerRadius)
                    color: Style.hoverFillFor(root.fg, Commons.Color.accent)
                    border.width: 1
                    border.color: Qt.darker(root.fg, 3)

                    TextEdit {
                      id: codeText
                      anchors.left: parent.left
                      anchors.right: codeCopy.left
                      anchors.top: parent.top
                      anchors.margins: Style.space(8)
                      readOnly: true
                      selectByMouse: true
                      textFormat: TextEdit.PlainText
                      text: segment.isCode ? segment.modelData.text : ""
                      wrapMode: TextEdit.WrapAnywhere
                      color: root.fg
                      selectionColor: Style.selectionFillFor(root.fg, Commons.Color.accent)
                      selectedTextColor: root.fg
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      Keys.onPressed: function(event) { root.answerKey(event) }
                    }

                    HeaderButton {
                      id: codeCopy
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.space(4)
                      glyph: "󰆏"
                      tip: "Copy"
                      onClicked: {
                        root.copyText(segment.modelData.text)
                        codeCopy.confirm()
                      }
                    }
                  }
                }
              }

              Text {
                visible: status === "streaming" && (note !== "" || a === "")
                width: parent.width
                textFormat: Text.PlainText
                text: note !== "" ? note : "Thinking…"
                elide: Text.ElideRight
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                font.italic: true
              }

              Text {
                visible: status === "error"
                width: parent.width
                textFormat: Text.PlainText
                text: "✕  " + err
                wrapMode: Text.Wrap
                color: Commons.Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: status === "stopped"
                textFormat: Text.PlainText
                text: "Stopped."
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: via !== "" && status !== "streaming"
                width: parent.width
                textFormat: Text.PlainText
                text: "󰌢  " + via
                elide: Text.ElideRight
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }

      TextField {
        id: input
        width: parent.width
        foreground: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        placeholderText: root.busy ? "Answering…   Ctrl+. stops"
          : (turns.count > 0 ? "Ask a follow-up…" : "Ask anything…")

        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
          if (event.key === Qt.Key_Escape) {
            root.close()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.ask(input.text)
          } else if (event.key === Qt.Key_Up && !ctrl) {
            root.recall(-1)
          } else if (event.key === Qt.Key_Down && !ctrl) {
            root.recall(1)
          } else if (event.key === Qt.Key_PageUp) {
            root.scrollBy(-0.8)
          } else if (event.key === Qt.Key_PageDown) {
            root.scrollBy(0.8)
          } else if (ctrl && event.key === Qt.Key_N) {
            root.newChat()
          } else if (ctrl && event.key === Qt.Key_Period) {
            root.stop()
          } else if (ctrl && shift && event.key === Qt.Key_C) {
            root.copyLastAnswer()
          } else if (ctrl && event.key === Qt.Key_T) {
            root.continueInTerminal()
          } else if (ctrl && event.key === Qt.Key_L) {
            root.cycleBackend()
          } else {
            return
          }
          event.accepted = true
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Enter ask   ↑ previous   Ctrl+N new   Ctrl+L cloud/local   Ctrl+Shift+C copy   Ctrl+T Claude Code   Esc close"
        elide: Text.ElideRight
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
