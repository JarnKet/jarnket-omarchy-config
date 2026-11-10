import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Ask Claude: a bar button (and SUPER+A) that opens a quick-ask card centred on
// the bar. bin/ask-claude runs `claude -p` on Sonnet with the Claude
// subscription the CLI is signed in to and streams JSON lines back; follow-ups
// resume the same session until New chat, or until the card opens after half
// an hour of quiet. Ctrl+H turns the input into a search over past Ask Claude
// conversations (only those: `ask-claude --history` reads Ask Claude's own
// Claude Code project); opening one loads it so follow-ups continue it.
Panel {
  id: root
  moduleName: "shadowone.ask-claude"
  ipcTarget: "shadowone.ask-claude"
  manageIpc: false

  readonly property string home: Quickshell.env("HOME")
  readonly property string helper: home + "/.config/omarchy/plugins/shadowone.ask-claude/bin/ask-claude"
  readonly property string stateDir: home + "/.local/state/ask-claude"
  readonly property int staleAfterMs: 30 * 60 * 1000

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

  // History mode: the input searches, the list replaces the conversation.
  property bool historyMode: false
  property var historyItems: []
  property int historyIndex: 0
  property bool historyLoaded: false
  property string chatDraft: ""

  readonly property string historyLabel: {
    if (!root.historyLoaded) return "History"
    var n = root.historyItems.length
    var count = n >= 300 ? "300+" : String(n)
    return input.text.trim() === "" ? "History  ·  " + count + (n === 1 ? " conversation" : " conversations")
      : "History  ·  " + count + " found"
  }

  readonly property string limitLabel: {
    var window = root.limits ? root.limits.five_hour : null
    if (!window || window.used === undefined || window.used === null) return ""
    return "5h limit " + Math.round(Number(window.used) * 100) + "% used"
  }

  // q, a, note, status (streaming | done | stopped | error), err
  ListModel { id: turns }

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
    root.historyMode = false
    root.chatDraft = ""
    turns.clear()
    root.sessionId = ""
    root.answerBuffer = ""
    root.lastAnswerText = ""
    input.text = ""
  }

  function openHistory(query) {
    if (root.busy) return
    if (!root.historyMode) {
      root.chatDraft = input.text
      root.historyMode = true
      root.historyLoaded = false
    }
    input.text = String(query || "")
    input.cursorPosition = input.text.length
    historyTimer.restart()
    input.forceActiveFocus()
  }

  function closeHistory() {
    if (!root.historyMode) return
    root.historyMode = false
    input.text = root.chatDraft
    input.cursorPosition = input.text.length
    root.chatDraft = ""
  }

  function moveHistory(step) {
    if (root.historyItems.length === 0) return
    root.historyIndex = Math.max(0, Math.min(root.historyItems.length - 1, root.historyIndex + step))
  }

  function openConversation(index) {
    var item = root.historyItems[index]
    if (item) resume(item.id)
  }

  // Load a past conversation; the next question continues its session.
  function resume(id) {
    if (root.busy || showProc.running || String(id || "") === "") return
    showProc.command = [root.helper, "--show", String(id), "--json"]
    showProc.running = true
  }

  function loadConversation(text) {
    var data
    try { data = JSON.parse(text) } catch (error) { return }
    if (!data || !data.turns || root.busy) return
    root.historyMode = false
    root.chatDraft = ""
    turns.clear()
    for (var i = 0; i < data.turns.length; i++) {
      var turn = data.turns[i]
      turns.append({ q: turn.q, a: turn.a, note: "", status: turn.err && turn.a === "" ? "error" : "done", err: turn.err || "" })
    }
    root.sessionId = data.id
    root.answerBuffer = ""
    root.lastAnswerText = data.turns.length > 0 ? data.turns[data.turns.length - 1].a : ""
    root.lastActivity = Date.now()
    input.text = ""
    conversation.stickToBottom = true
    conversation.scrollToEnd()
  }

  // "Today 14:05", "Yesterday 09:12", "25 Oct 16:10", "3 Mar 2025"
  function when(ms) {
    var date = new Date(ms)
    var now = new Date()
    var today = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime()
    var time = Qt.formatTime(date, "HH:mm")
    if (ms >= today) return "Today " + time
    if (ms >= today - 86400000) return "Yesterday " + time
    if (date.getFullYear() === now.getFullYear()) return Qt.formatDate(date, "d MMM") + " " + time
    return Qt.formatDate(date, "d MMM yyyy")
  }

  function ask(text) {
    var question = String(text || "").trim()
    if (question === "" || root.busy) return
    closeHistory()
    turns.append({ q: question, a: "", note: "", status: "streaming", err: "" })
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
    } else if (event.t === "text") {
      root.answerBuffer += event.d
      if (turns.get(i).note !== "") turns.setProperty(i, "note", "")
      if (!flushTimer.running) flushTimer.start()
    } else if (event.t === "tool") {
      var label = event.name === "WebSearch" ? "Searching the web: "
        : event.name === "WebFetch" ? "Reading: " : event.name + ": "
      turns.setProperty(i, "note", label + (event.detail || ""))
    } else if (event.t === "done") {
      root.sessionId = event.id || root.sessionId
      if (event.limits) root.limits = event.limits
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

  // Hand the conversation to the full Claude Code CLI in a terminal.
  function continueInTerminal() {
    if (root.sessionId === "" || root.busy) return
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

  // Search as you type, one helper run at a time.
  Timer {
    id: historyTimer
    interval: 120
    onTriggered: {
      if (historyProc.running) {
        restart()
        return
      }
      historyProc.command = [root.helper, "--history", "--json", "--", input.text]
      historyProc.running = true
    }
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var items = []
        try { items = JSON.parse(text) } catch (error) {}
        root.historyItems = Array.isArray(items) ? items : []
        root.historyIndex = 0
        root.historyLoaded = true
      }
    }
  }

  Process {
    id: showProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadConversation(text)
    }
  }

  onOpenedChanged: if (!root.opened) root.closeHistory()

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function ask(question: string): void { root.open(); root.ask(question) }
    function newChat(): void { root.newChat() }
    function history(query: string): void { root.open(); root.openHistory(query) }
    function resume(id: string): void { root.open(); root.resume(id) }
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
            text: root.historyMode ? root.historyLabel
              : "Sonnet 5.5" + (root.limitLabel !== "" ? "  ·  " + root.limitLabel : "")
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
            id: copyAnswerButton
            glyph: "󰆏"
            tip: "Copy answer  (Ctrl+Shift+C)"
            enabled: root.lastAnswerText !== "" && !root.historyMode
            onClicked: root.copyLastAnswer()
          }

          HeaderButton {
            glyph: "󰆍"
            tip: "Continue in Claude Code  (Ctrl+T)"
            enabled: root.sessionId !== "" && !root.busy && !root.historyMode
            onClicked: root.continueInTerminal()
          }

          HeaderButton {
            glyph: root.historyMode ? "󰁍" : "󰋚"
            tip: root.historyMode ? "Back to the chat  (Esc)" : "History  (Ctrl+H)"
            enabled: !root.busy
            onClicked: root.historyMode ? root.closeHistory() : root.openHistory("")
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
        visible: turns.count > 0 && !root.historyMode
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
                text: note !== "" ? "󰖟  " + note : "Thinking…"
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
            }
          }
        }
      }

      ListView {
        id: historyList
        width: parent.width
        visible: root.historyMode && root.historyItems.length > 0
        // At least 1 px so the first row gets made and contentHeight can grow from it.
        height: visible ? Math.min(Math.max(contentHeight, 1), root.maxConversationHeight) : 0
        model: root.historyItems
        currentIndex: root.historyIndex
        clip: true
        spacing: Style.space(2)
        boundsBehavior: Flickable.StopAtBounds
        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

        ScrollBar.vertical: ScrollBar {
          policy: historyList.contentHeight > historyList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        }

        delegate: CursorSurface {
          id: historyRow
          required property var modelData
          required property int index

          width: historyList.width - Style.space(10)
          height: rowText.implicitHeight + Style.space(10)
          foreground: root.fg
          hasCursor: index === root.historyIndex

          Column {
            id: rowText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(1)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: historyRow.modelData.title
              elide: Text.ElideRight
              color: root.fg
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              visible: historyRow.modelData.snippet !== ""
              textFormat: Text.PlainText
              text: historyRow.modelData.snippet
              elide: Text.ElideRight
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.italic: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.when(historyRow.modelData.updated) + "  ·  " + historyRow.modelData.count
                + (historyRow.modelData.count === 1 ? " question" : " questions")
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.historyIndex = historyRow.index
            onClicked: root.openConversation(historyRow.index)
          }
        }
      }

      Text {
        width: parent.width
        visible: root.historyMode && root.historyItems.length === 0
        textFormat: Text.PlainText
        text: !root.historyLoaded ? "Loading…"
          : input.text.trim() !== "" ? "Nothing in your Ask Claude history matches that."
          : "No conversations yet."
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }

      TextField {
        id: input
        width: parent.width
        foreground: root.fg
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        placeholderText: root.historyMode ? "Search past questions and answers…"
          : root.busy ? "Answering…   Ctrl+. stops"
          : (turns.count > 0 ? "Ask a follow-up…" : "Ask anything…")

        onTextChanged: if (root.historyMode) historyTimer.restart()

        Keys.onPressed: function(event) {
          var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
          var shift = (event.modifiers & Qt.ShiftModifier) !== 0
          if (root.historyMode) {
            if (event.key === Qt.Key_Escape || (ctrl && (event.key === Qt.Key_H || event.key === Qt.Key_R))) {
              root.closeHistory()
            } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.openConversation(root.historyIndex)
            } else if (event.key === Qt.Key_Up) {
              root.moveHistory(-1)
            } else if (event.key === Qt.Key_Down) {
              root.moveHistory(1)
            } else if (event.key === Qt.Key_PageUp) {
              root.moveHistory(-5)
            } else if (event.key === Qt.Key_PageDown) {
              root.moveHistory(5)
            } else if (ctrl && event.key === Qt.Key_N) {
              root.newChat()
            } else {
              return
            }
            event.accepted = true
            return
          }
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
          } else if (ctrl && (event.key === Qt.Key_H || event.key === Qt.Key_R)) {
            root.openHistory("")
          } else {
            return
          }
          event.accepted = true
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.historyMode ? "Type to search   ↑↓ choose   Enter open   Ctrl+N new   Esc back"
          : "Enter ask   ↑ previous   Ctrl+H history   Ctrl+N new   Ctrl+T Claude Code   Esc close"
        elide: Text.ElideRight
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }
  }
}
