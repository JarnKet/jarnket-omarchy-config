import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Memory Keeper: available memory in the bar, and a panel with Claude sessions,
// what holds memory, and leftovers. All measuring and stopping happens in
// bin/memkeeper; this file only shows its answers and passes back ids it got
// from it. Stopping on a schedule is the memory-keeper.timer user unit's job.
Panel {
  id: root

  moduleName: "shadowone.memory-keeper"
  ipcTarget: ""
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property var mem: service.mem
  readonly property var scan: service.scan
  readonly property string level: scan && scan.level !== "ok" ? scan.level : service.level

  property bool settingsOpen: false
  property int cursor: -1
  property bool cursorActive: false
  property Item cursorItem: null
  property bool enterPressed: false
  property var pending: null
  property double now: Date.now()

  readonly property var rows: Model.buildRows(scan, settingsOpen)
  readonly property var currentRow: cursor >= 0 && cursor < rows.length ? rows[cursor] : null
  readonly property var candidates: Model.idleCandidates(scan)

  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : barSize

  Service {
    id: service
    settings: root.settings
    panelOpen: root.opened
  }

  onRowsChanged: {
    if (cursor >= rows.length) cursor = Model.nextSelectable(rows, rows.length, -1)
    if (cursor < 0 || (rows[cursor] && !rows[cursor].selectable)) cursor = Model.firstSelectable(rows)
  }

  onOpenedChanged: {
    if (opened) {
      now = Date.now()
      cursorActive = false
      service.runScan()
      Qt.callLater(function() { if (root.opened) root.setRevealSuppressed(true) })
    } else {
      pending = null
      setRevealSuppressed(false)
    }
  }

  Component.onDestruction: setRevealSuppressed(false)

  // With one bar per monitor only one copy's handler is active; the others log
  // a harmless warning.
  IpcHandler {
    target: "memory-keeper"

    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function rescan(): void { service.runScan() }
    function reclaim(): void { service.reclaim() }
    function state(): string {
      return JSON.stringify({ opened: root.opened, rows: root.rows.length, cursor: root.cursor, level: root.level,
                              scanning: service.scanning, acting: service.acting, message: service.message })
    }
  }

  // The property is read-only on the plugin bar API; only the setter works.
  function setRevealSuppressed(value) {
    if (bar && typeof bar.setCenterHoverRevealSuppressed === "function") bar.setCenterHoverRevealSuppressed(value)
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.now = Date.now()
  }

  // ------------------------------------------------------------ cursor

  function setCursor(index) {
    if (index < 0 || index >= rows.length || !rows[index].selectable) return
    cursorActive = true
    cursor = index
  }

  function moveCursor(dy) {
    if (!cursorActive) {
      cursorActive = true
      if (cursor < 0) cursor = Model.firstSelectable(rows)
      scrollIntoView()
      return
    }
    cursor = Model.nextSelectable(rows, cursor, dy > 0 ? 1 : -1)
    scrollIntoView()
  }

  function scrollIntoView() {
    Qt.callLater(function() {
      var item = root.cursorItem
      if (!item || !listFlick) return
      var margin = Style.space(6)
      var top = item.mapToItem(listFlick.contentItem, 0, 0).y
      var bottom = top + item.height
      var maxY = Math.max(0, listFlick.contentHeight - listFlick.height)
      if (top < listFlick.contentY + margin) listFlick.contentY = Math.max(0, top - margin)
      else if (bottom > listFlick.contentY + listFlick.height - margin)
        listFlick.contentY = Math.min(maxY, bottom + margin - listFlick.height)
    })
  }

  // ------------------------------------------------------------ actions

  function rowActions(row) {
    return row ? Model.rowView(row, scan, settingsOpen, now).actions : []
  }

  function runAction(row, id) {
    if (!row || service.acting) return
    if (id === "toggle-auto") service.setConfig("auto", !scan.config.auto)
    else if (id === "toggle-settings") settingsOpen = !settingsOpen
    else if (id === "dec" || id === "inc") {
      var step = id === "inc" ? row.def.step : -row.def.step
      service.setConfig(row.def.key, scan.config[row.def.key] + step)
    } else if (id === "stop") {
      if (Model.stopNeedsConfirm(row.session)) ask({ kind: "stop", id: row.session.sessionId, confirmText: "Stop", message: Model.stopConfirmText(row.session) })
      else service.stopSession(row.session.sessionId)
    } else if (id === "keep") service.setKeep(row.session.sessionId, !row.session.keep)
    else if (id === "resume") service.resumeSession(row.entry.sessionId)
    else if (id === "copy") {
      service.copyText(row.entry.inputText)
      service.say("Copied", false)
    } else if (id === "stop-leftover") {
      ask({ kind: "leftover", pid: row.leftover.pid, start: row.leftover.start, confirmText: "Stop",
            message: "Stop " + row.leftover.label + "? It may be a dev server you still use.\n" + row.leftover.cwd })
    } else if (id === "restart-shell") {
      ask({ kind: "restart", confirmText: "Restart", message: "Restart the Omarchy shell? The bar reloads; your windows and terminals are not touched." })
    }
  }

  function ask(p) {
    pending = p
    confirmDialog.selectedIndex = 0
  }

  function askStopIdle() {
    if (!candidates.length || service.acting) return
    ask({ kind: "stop-idle", confirmText: "Stop", message: Model.idleConfirmText(candidates) })
  }

  function confirmPending() {
    var p = pending
    pending = null
    if (!p) return
    if (p.kind === "stop") service.stopSession(p.id)
    else if (p.kind === "stop-idle") service.stopIdle()
    else if (p.kind === "leftover") service.stopLeftover(p.pid, p.start)
    else if (p.kind === "restart") service.restartShell()
  }

  function horizontal(dx) {
    var row = currentRow
    if (!row) return
    if (row.kind === "setting") runAction(row, dx > 0 ? "inc" : "dec")
    else if (row.kind === "settings" && (dx > 0) !== settingsOpen) settingsOpen = dx > 0
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      service.runScan()
      return
    }
    root.toggle()
  }

  // ------------------------------------------------------------ bar button

  readonly property string barGlyph: level === "critical" ? Model.GLYPH_ALERT : Model.GLYPH_MEMORY
  readonly property string barLabel: vertical ? "" : Model.barText(mem, service.cfg.barLabel)

  Loader {
    id: button
    anchors.fill: parent
    sourceComponent: root.barLabel === "" ? iconButton : labelledButton
  }

  Component {
    id: iconButton

    BarIconButton {
      anchors.fill: parent
      bar: root.bar
      text: root.barGlyph
      tooltipText: Model.barTooltip(root.mem, root.level)
      active: root.level !== "ok"
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
    }
  }

  Component {
    id: labelledButton

    WidgetButton {
      anchors.fill: parent
      bar: root.bar
      text: root.barGlyph + "  " + root.barLabel
      tooltipText: Model.barTooltip(root.mem, root.level)
      active: root.level !== "ok"
      onPressed: function(buttonCode) { root.handleBarPress(buttonCode) }
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
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(layout.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onCloseRequested: {
        if (root.pending) root.pending = null
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.pending) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
      }
      onMoveRequested: function(dx, dy) {
        if (root.pending) {
          if (dx !== 0) confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (dy !== 0) root.moveCursor(dy)
        else root.horizontal(dx)
      }
      onReturnRequested: root.enterPressed = true
      onActivateRequested: {
        var viaEnter = root.enterPressed
        root.enterPressed = false
        if (root.pending) {
          if (!viaEnter) return
          if (confirmDialog.selectedIndex === 1) root.confirmPending()
          else root.pending = null
          return
        }
        if (!root.cursorActive) {
          root.moveCursor(1)
          return
        }
        var actions = root.rowActions(root.currentRow)
        if (actions.length) root.runAction(root.currentRow, actions[0].id)
      }
      onTextKey: function(text) {
        if (root.pending) return
        var row = root.currentRow
        if (text === "r" || text === "R") service.runScan()
        else if (text === "f" || text === "F") service.reclaim()
        else if (text === "s" || text === "S") root.askStopIdle()
        else if ((text === "k" || text === "K") && row && row.kind === "session") root.runAction(row, "keep")
        else if ((text === "c" || text === "C") && row && row.kind === "stopped" && row.entry.inputText) root.runAction(row, "copy")
      }

      ColumnLayout {
        id: layout
        // Filling the card lets the list shrink when the screen is too short
        // for the natural height, instead of pushing the footer out.
        anchors.fill: parent
        spacing: Style.space(8)

        // ---- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            text: "Memory Keeper"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            Layout.fillWidth: true
          }

          PanelActionButton {
            iconText: Model.GLYPH_REFRESH
            tooltipText: "Refresh (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !service.scanning
            onClicked: service.runScan()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: root.mem ? Model.formatBytes(root.mem.availableBytes) + " available" : "…"
            color: root.level === "ok" ? root.foreground : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Text {
            textFormat: Text.PlainText
            text: root.mem ? "of " + Model.formatBytes(root.mem.totalBytes) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: Style.space(4)
            Layout.fillWidth: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.mem ? Math.round(Model.usedFraction(root.mem) * 100) + "% used" : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: Style.space(4)
          }
        }

        Rectangle {
          Layout.fillWidth: true
          implicitHeight: Style.space(6)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Model.usedFraction(root.mem)
            color: root.level === "ok" ? root.foreground : root.urgent
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: {
            var parts = []
            var why = Model.levelText(root.scan)
            if (why) parts.push(why)
            if (root.mem) parts.push("swap " + Model.formatBytes(root.mem.swapUsedBytes))
            if (root.scan) parts.push("stalled " + root.scan.mem.psiSome.toFixed(1) + "%")
            if (root.scan && root.scan.stoppedThisMonth > 0)
              parts.push("stopped " + root.scan.stoppedThisMonth + " this month, freed " + Model.formatBytes(root.scan.freedThisMonth))
            return parts.join(" · ")
          }
          color: root.level === "ok" ? root.dim : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---- list
        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: Math.min(listColumn.implicitHeight, Style.space(470))
          Layout.minimumHeight: Math.min(listColumn.implicitHeight, Style.space(110))
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(1)

            Text {
              visible: root.rows.length === 0
              width: parent.width
              topPadding: Style.space(18)
              bottomPadding: Style.space(18)
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: "Measuring…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.rows

              Loader {
                required property var modelData
                required property int index
                width: listColumn.width
                sourceComponent: modelData.kind === "group" ? groupRow : (modelData.kind === "note" ? noteRow : listRow)
              }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---- footer
        Text {
          Layout.fillWidth: true
          visible: text !== ""
          textFormat: Text.PlainText
          text: service.acting ? "Working…" : service.message
          color: service.messageUrgent && !service.acting ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: "enter action · k keep · ←→ setting"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            text: "Free cold cache"
            enabled: !service.acting
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: service.reclaim()
          }

          Button {
            text: root.candidates.length ? "Stop idle · " + root.candidates.length : "Stop idle"
            enabled: !service.acting && root.candidates.length > 0
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.askStopIdle()
          }
        }
      }

      ConfirmDialog {
        id: confirmDialog
        anchors.fill: parent
        opened: root.pending !== null
        message: root.pending ? root.pending.message : ""
        confirmText: root.pending ? root.pending.confirmText : "Confirm"
        fontFamily: root.fontFamily
        onCanceled: root.pending = null
        onConfirmed: root.confirmPending()
      }
    }
  }

  Component {
    id: groupRow

    Item {
      readonly property var row: parent ? parent.modelData : null
      implicitHeight: header.implicitHeight + Style.space(10)

      PanelSectionHeader {
        id: header
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(8)
        anchors.bottomMargin: Style.space(2)
        text: parent.row ? parent.row.title.toUpperCase() : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        anchors.left: header.right
        anchors.baseline: header.baseline
        anchors.leftMargin: Style.space(8)
        textFormat: Text.PlainText
        text: parent.row ? parent.row.subtitle : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: noteRow

    Item {
      readonly property var row: parent ? parent.modelData : null
      implicitHeight: noteText.implicitHeight + Style.space(6)

      Text {
        id: noteText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8)
        textFormat: Text.PlainText
        text: parent.row ? parent.row.text : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Component {
    id: listRow

    ListRow {
      id: lr
      readonly property var row: parent ? parent.modelData : null
      readonly property int rowIndex: parent ? parent.index : -1
      readonly property var view: row ? Model.rowView(row, root.scan, root.settingsOpen, root.now) : ({})

      hasCursor: root.cursorActive && root.cursor === rowIndex
      onHasCursorChanged: if (hasCursor) root.cursorItem = lr
      textColor: root.foreground
      fontFamily: root.fontFamily
      iconGlyph: view.icon || ""
      title: view.title || ""
      detail: view.detail || ""
      size: view.size || ""
      chevron: view.chevron || ""
      muted: !!view.muted
      actions: view.actions || []

      onHovered: root.setCursor(rowIndex)
      onClicked: {
        root.setCursor(rowIndex)
        if (row.kind === "settings") root.runAction(row, "toggle-settings")
      }
      onActionClicked: function(id) {
        root.setCursor(rowIndex)
        root.runAction(row, id)
      }
    }
  }
}
