import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Disk Keeper: free space in the bar, and a panel to see and clean what
// fills the disk. All measuring and deleting happens in bin/diskkeeper; this
// file only shows its answers and sends back category:key targets.
Panel {
  id: root

  moduleName: "shadowone.disk-keeper"
  ipcTarget: ""
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  readonly property var cfg: Model.clampSettings(settings)
  readonly property var status: service.status
  readonly property string level: status ? status.level : "ok"
  readonly property var scan: Model.withSnapshots(service.scan, service.snapshots)

  property string tab: "cleanup"
  property var selection: ({})
  property bool selectionTouched: false
  property var expanded: ({})
  property var projectSelection: ({})
  property bool projectSelectionTouched: false
  property var projectExpanded: ({})
  property int cursor: -1
  property bool cursorActive: false
  property Item cursorItem: null
  property bool enterPressed: false
  property var pending: null
  property var lastJob: null
  property double now: Date.now()

  readonly property var rows: tab === "cleanup" ? Model.cleanupRows(scan, expanded)
    : (tab === "projects" ? Model.projectRows(service.projects, projectExpanded) : Model.exploreRows(service.currentExplore))
  readonly property var currentRow: cursor >= 0 && cursor < rows.length ? rows[cursor] : null
  readonly property var summary: Model.selectionSummary(scan, selection)
  readonly property var cleanTargets: Model.targetsFor(scan, selection)
  readonly property var projectTargets: Model.projectTargets(service.projects, projectSelection)

  implicitWidth: button.item ? button.item.implicitWidth : 0
  implicitHeight: button.item ? button.item.implicitHeight : barSize

  Service {
    id: service
    settings: root.settings
    onJobFinished: function(job) {
      root.lastJob = job
      root.selectionTouched = false
      root.projectSelectionTouched = false
      root.projectSelection = ({})
      var text = Model.jobSummary(job)
      if (job.notes && job.notes.length) text += ". " + job.notes[0]
      service.say(text, job.auth === "cancelled" || (job.results || []).some(function(r) { return r.status === "failed" }))
    }
    onProjectsChanged: if (!root.projectSelectionTouched) root.projectSelection = Model.projectDefaultSelection(service.projects)
  }

  // On the derived property, not service.scanChanged: a handler there can run
  // before this binding has picked up the new scan.
  onScanChanged: if (!selectionTouched) selection = Model.defaultSelection(scan)

  onRowsChanged: {
    if (cursor >= rows.length) cursor = Model.nextSelectable(rows, rows.length, -1)
    if (cursor < 0 || (rows[cursor] && !rows[cursor].selectable)) cursor = Model.firstSelectable(rows)
  }

  onOpenedChanged: {
    if (opened) {
      now = Date.now()
      service.refreshStatus(false)
      service.loadHistory()
      var s = service.scan
      if (!s || s.stale || now - s.ts * 1000 > 10 * 60 * 1000) service.runScan()
      enterTab(tab)
      Qt.callLater(function() { if (root.opened) root.setRevealSuppressed(true) })
    } else {
      pending = null
      setRevealSuppressed(false)
    }
  }

  Component.onDestruction: setRevealSuppressed(false)

  // `qs ipc call disk-keeper openTab explore` etc. With one bar per monitor only
  // one copy's handler is active; the others log a harmless warning.
  IpcHandler {
    target: "disk-keeper"

    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function openTab(tab: string): void {
      var name = Model.TABS.indexOf(tab) >= 0 ? tab : "cleanup"
      if (!root.opened) root.open()
      root.enterTab(name)
    }
    function rescan(): void { root.rescan() }
    function preview(): void { root.preview() }
    function scrollBy(px: int): void {
      listFlick.contentY = Math.max(0, Math.min(listFlick.contentHeight - listFlick.height, listFlick.contentY + px))
    }
    function state(): string {
      return JSON.stringify({ opened: root.opened, tab: root.tab, rows: root.rows.length, cursor: root.cursor,
                              targets: root.cleanTargets.length, projectTargets: root.projectTargets.length,
                              scanning: service.scanning, jobRunning: service.jobRunning, message: service.message })
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

  // ------------------------------------------------------------ tabs + cursor

  function enterTab(name) {
    tab = name
    cursorActive = false
    cursor = Model.firstSelectable(rows)
    listFlick.contentY = 0
    if (name === "projects" && !service.projects && !service.projectsLoading) service.loadProjects(false)
    if (name === "explore" && !service.currentExplore) service.explore(service.explorePath, false)
  }

  function cycleTab(direction) {
    var i = Model.TABS.indexOf(tab)
    enterTab(Model.TABS[(i + direction + Model.TABS.length) % Model.TABS.length])
  }

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

  function keepCursorOn(key) {
    Qt.callLater(function() {
      var i = Model.indexOfKey(root.rows, key)
      if (i >= 0) root.cursor = i
    })
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

  function toggleExpanded(cat) {
    var copy = Object.assign({}, expanded)
    if (copy[cat.id]) delete copy[cat.id]
    else {
      copy[cat.id] = true
      if (cat.id === "snapshots" && !service.snapshots && !cat.blocked) service.loadSnapshots()
    }
    expanded = copy
    keepCursorOn("c:" + cat.id)
  }

  function toggleProjectExpanded(project) {
    var copy = Object.assign({}, projectExpanded)
    if (copy[project.path]) delete copy[project.path]
    else copy[project.path] = true
    projectExpanded = copy
    keepCursorOn("p:" + project.path)
  }

  function toggleRow(row) {
    if (!row || service.jobRunning) return
    if (row.kind === "category") {
      selection = Model.toggleCategory(row.cat, selection)
      selectionTouched = true
    } else if (row.kind === "item") {
      selection = Model.toggleItem(row.cat, row.item, selection)
      selectionTouched = true
    } else if (row.kind === "project") {
      projectSelection = Model.toggleProject(row.project, projectSelection)
      projectSelectionTouched = true
    } else if (row.kind === "pitem") {
      projectSelection = Model.toggleProjectItem(row.item, projectSelection)
      projectSelectionTouched = true
    }
  }

  function activateRow(row, viaEnter) {
    if (!row) return
    if (row.kind === "category") {
      if (viaEnter && row.expandable) toggleExpanded(row.cat)
      else toggleRow(row)
    } else if (row.kind === "item" || row.kind === "pitem") {
      toggleRow(row)
    } else if (row.kind === "project") {
      if (viaEnter) toggleProjectExpanded(row.project)
      else toggleRow(row)
    } else if (row.kind === "entry") {
      if (row.entry.browsable) browse(row.entry.rel)
    } else if (row.kind === "up") {
      browse(service.currentExplore ? service.currentExplore.parent : "")
    }
  }

  function horizontal(dx) {
    var row = currentRow
    if (!row) return
    if (tab === "explore") {
      if (dx > 0 && row.kind === "entry" && row.entry.browsable) browse(row.entry.rel)
      else if (dx < 0 && service.currentExplore && service.currentExplore.path !== "") browse(service.currentExplore.parent)
      return
    }
    if (row.kind === "category" && row.expandable && (dx > 0) !== !!expanded[row.cat.id]) toggleExpanded(row.cat)
    else if (row.kind === "item" && dx < 0) toggleExpanded(row.cat)
    else if (row.kind === "project" && (dx > 0) !== !!projectExpanded[row.project.path]) toggleProjectExpanded(row.project)
    else if (row.kind === "pitem" && dx < 0) toggleProjectExpanded(row.project)
  }

  function browse(rel) {
    cursorActive = true
    cursor = 0
    listFlick.contentY = 0
    service.explore(rel || "", false)
  }

  function askClean() {
    if (service.jobRunning) return
    if (tab === "projects") {
      if (!projectTargets.length) return
      var bytes = Model.projectSelectionBytes(service.projects, projectSelection, service.projectsExclusive)
      pending = { kind: "projects", targets: projectTargets, confirmText: "Delete",
                  message: "Delete " + projectTargets.length + " build folder" + (projectTargets.length === 1 ? "" : "s") +
                    ", about " + Model.formatBytes(bytes) + "? Run install or build again to get them back." }
    } else if (tab === "cleanup") {
      if (!cleanTargets.length) return
      pending = { kind: "clean", targets: cleanTargets, confirmText: "Delete", message: Model.confirmMessage(summary) }
    }
    confirmDialog.selectedIndex = 0
  }

  // Dry run of the current Clean up selection: shows per-row results, deletes nothing.
  function preview() {
    if (service.jobRunning || tab !== "cleanup" || !cleanTargets.length) return
    lastJob = null
    service.startClean(cleanTargets, true)
  }

  function askTrash() {
    var row = currentRow
    if (tab !== "explore" || !row || row.kind !== "entry") return
    var e = row.entry
    if (!e.actionable) {
      service.say(e.protected ? "This folder is protected" : (e.kept ? "On your keep list" : "Cannot move this item"), true)
      return
    }
    var warn = e.confirm === "extra" ? " Apps keep their data and settings in hidden folders like this one." : ""
    pending = { kind: "trash", entries: [e], confirmText: "Trash",
                message: "Move \"" + e.name + "\" (" + Model.formatBytes(e.bytes) + ") to the Trash?" + warn }
    confirmDialog.selectedIndex = 0
  }

  function confirmPending() {
    var p = pending
    pending = null
    if (!p) return
    if (p.kind === "clean" && summary.extraConfirm.length) {
      pending = { kind: "clean-extra", targets: p.targets, confirmText: "Delete",
                  message: summary.extraConfirm.join(", ") + " can hold database files. Delete them too?" }
      confirmDialog.selectedIndex = 0
      return
    }
    if (p.kind === "clean" || p.kind === "clean-extra" || p.kind === "projects") {
      lastJob = null
      service.startClean(p.targets, false)
    } else if (p.kind === "trash") {
      service.trash(p.entries)
    }
  }

  function keepCurrent() {
    var row = currentRow
    if (tab !== "explore" || !row || row.kind !== "entry" || !row.entry.rel || row.entry.protected) return
    service.keep(row.entry.rel, !row.entry.kept)
  }

  function rescan() {
    if (tab === "cleanup") service.runScan()
    else if (tab === "projects") service.loadProjects(service.projectsExclusive)
    else service.explore(service.explorePath, true)
    service.refreshStatus(false)
  }

  function handleBarPress(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      service.refreshStatus(false)
      return
    }
    root.toggle()
  }

  // ------------------------------------------------------------ row presentation

  readonly property var shownJob: service.jobRunning ? service.job : lastJob

  function resultBadge(target) {
    var r = Model.resultFor(shownJob, target)
    return r ? Model.resultText(r, shownJob.dryRun) : ""
  }

  function rowProps(row) {
    var p = { check: "", icon: "", title: "", detail: "", badge: "", urgent: false, size: "", chevron: "",
              indent: 0, muted: false, fraction: -1 }
    if (row.kind === "category") {
      var cat = row.cat
      var choosable = Model.hasChoices(cat)
      p.check = cat.blocked ? Model.GLYPH_LOCK : Model.checkGlyph(Model.checkState(cat, selection))
      p.title = cat.title
      p.detail = !choosable && cat.note ? cat.note : cat.description
      p.size = Model.estimateText(cat.itemized ? cat.items.reduce(function(s, i) { return s + (i.blocked ? 0 : i.bytes) }, 0) : cat.bytes,
                                  cat.estimateKind)
      if (cat.id === "snapshots" && !service.snapshots) p.size = service.snapshotsLoading ? "listing…" : ""
      if (!choosable && !cat.blocked && cat.id !== "snapshots") p.size = ""
      var res = Model.categoryResult(shownJob, cat)
      p.badge = res ? res.text : Model.blockedText(cat.blocked)
      p.urgent = res ? res.urgent : (!!cat.blocked || cat.risk === "data")
      p.muted = !choosable
      p.chevron = row.expandable ? (expanded[cat.id] ? Model.GLYPH_EXPANDED : Model.GLYPH_COLLAPSED) : ""
    } else if (row.kind === "item") {
      var it = row.item
      p.indent = 1
      p.check = row.cat.itemized ? (Model.itemSelectable(row.cat, it)
        ? (selection[Model.itemTarget(row.cat, it)] ? Model.GLYPH_CHECKED : Model.GLYPH_UNCHECKED) : Model.GLYPH_LOCK) : ""
      p.title = it.label
      p.detail = it.blocked ? it.blocked.detail : it.detail
      p.size = it.bytes ? Model.formatBytes(it.bytes) : ""
      p.badge = resultBadge(Model.itemTarget(row.cat, it)) || Model.blockedText(it.blocked)
      p.muted = !!it.blocked
    } else if (row.kind === "project") {
      var pr = row.project
      var eligible = pr.items.filter(function(i) { return i.eligible }).length
      p.check = eligible ? Model.checkGlyph(Model.projectCheckState(pr, projectSelection)) : Model.GLYPH_LOCK
      p.title = pr.label
      var age = Model.ageDays(pr.lastTouched, now)
      p.detail = (age === null ? "" : (age === 0 ? "touched today" : "last touched " + age + (age === 1 ? " day" : " days") + " ago")) +
        (pr.running ? " · in use by " + pr.running : "")
      p.size = Model.formatBytes(pr.bytes)
      p.urgent = !!pr.running
      p.muted = !eligible
      p.chevron = projectExpanded[pr.path] ? Model.GLYPH_EXPANDED : Model.GLYPH_COLLAPSED
    } else if (row.kind === "pitem") {
      var pi = row.item
      p.indent = 1
      p.check = pi.eligible ? (projectSelection["projects:" + pi.key] ? Model.GLYPH_CHECKED : Model.GLYPH_UNCHECKED) : Model.GLYPH_LOCK
      p.title = pi.label
      p.detail = pi.eligible ? "" : Model.reasonText(pi.reason)
      var b = service.projectsExclusive && pi.exclusiveBytes !== null && pi.exclusiveBytes !== undefined ? pi.exclusiveBytes : pi.bytes
      p.size = Model.formatBytes(b)
      p.badge = resultBadge("projects:" + pi.key)
      p.muted = !pi.eligible
    } else if (row.kind === "entry") {
      var e = row.entry
      p.icon = Model.entryGlyph(e)
      p.title = e.name + (e.type === "dir" ? "/" : "")
      p.detail = e.protected ? (e.protected === "system-folder" ? "standard folder" : "protected") :
        (e.kept ? "on keep list" : (e.otherFs ? "other drive" : "modified " + Model.relativeTime(e.mtime, now)))
      p.size = Model.formatBytes(e.bytes)
      p.badge = e.protected ? Model.GLYPH_LOCK : (e.kept ? Model.GLYPH_KEEP : "")
      p.muted = !e.actionable && !e.browsable
      p.chevron = e.browsable ? Model.GLYPH_COLLAPSED : ""
      var total = service.currentExplore ? service.currentExplore.total : 0
      p.fraction = total > 0 ? e.bytes / total : 0
    } else if (row.kind === "up") {
      p.icon = Model.GLYPH_UP
      p.title = ".."
      p.detail = "Up to " + Model.breadcrumb(service.currentExplore ? service.currentExplore.parent : "").join("/")
    }
    return p
  }

  // ------------------------------------------------------------ bar button

  readonly property string barGlyph: level === "critical" ? String.fromCodePoint(0xF0026) : Model.GLYPH_DISK
  readonly property string barLabel: vertical ? "" : Model.barText(status, cfg.barLabel)

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
      tooltipText: Model.barTooltip(root.status)
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
      tooltipText: Model.barTooltip(root.status)
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
    contentWidth: panel.fittedContentWidth(Style.space(470))
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
        else root.cycleTab(direction)
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
        root.activateRow(root.currentRow, viaEnter)
      }
      onDeleteRequested: {
        if (root.pending) return
        if (root.tab === "explore") root.askTrash()
        else root.askClean()
      }
      onTextKey: function(text) {
        if (root.pending) return
        if (text === "r" || text === "R") root.rescan()
        else if (text === "c" || text === "C") root.askClean()
        else if (text === "d" || text === "D") root.preview()
        else if (text === "1") root.enterTab("cleanup")
        else if (text === "2") root.enterTab("explore")
        else if (text === "3") root.enterTab("projects")
        else if ((text === "o" || text === "O") && root.tab === "explore" && root.currentRow && root.currentRow.kind === "entry")
          service.openPath(root.currentRow.entry.rel, root.currentRow.entry.type === "dir")
        else if ((text === "p" || text === "P") && root.tab === "explore") root.keepCurrent()
        else if ((text === "m" || text === "M") && root.tab === "projects") service.loadProjects(true)
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
            text: "Disk Keeper"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            Layout.fillWidth: true
          }

          PanelActionButton {
            iconText: Model.GLYPH_REFRESH
            tooltipText: "Rescan (r)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !service.scanning && !service.jobRunning
            onClicked: root.rescan()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: root.status ? Model.formatBytes(root.status.freeBytes) + " free" : "…"
            color: root.level === "ok" ? root.foreground : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Text {
            textFormat: Text.PlainText
            text: root.status ? "of " + Model.formatBytes(root.status.totalBytes) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            Layout.alignment: Qt.AlignBottom
            Layout.bottomMargin: Style.space(4)
            Layout.fillWidth: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.status ? Math.round(Model.usedFraction(root.status) * 100) + "% used" : ""
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
            width: parent.width * Model.usedFraction(root.status)
            color: root.level === "ok" ? root.foreground : root.urgent
          }

          // Where the warning threshold sits on the bar.
          Rectangle {
            visible: !!root.status
            x: root.status ? parent.width * (1 - root.status.warnBytes / root.status.totalBytes) : 0
            width: Math.max(1, Style.space(1))
            height: parent.height
            color: root.urgent
          }
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: {
            var parts = []
            if (service.scanning) parts.push("Scanning…")
            else if (service.scan) parts.push("Scanned " + Model.relativeTime(service.scan.ts, root.now))
            if (service.history && service.history.monthFreedBytes > 0)
              parts.push("freed " + Model.formatBytes(service.history.monthFreedBytes) + " this month")
            if (root.status && root.status.levelReason === "btrfs-metadata") parts.push("btrfs metadata nearly full")
            return parts.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        // ---- tabs
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(16)

          Repeater {
            model: Model.TABS

            Item {
              required property string modelData
              required property int index
              readonly property bool current: root.tab === modelData
              implicitWidth: tabLabel.implicitWidth
              implicitHeight: tabLabel.implicitHeight + Style.space(6)

              Text {
                id: tabLabel
                textFormat: Text.PlainText
                text: Model.TAB_TITLES[parent.modelData]
                color: parent.current ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: parent.current
              }

              Rectangle {
                visible: parent.current
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Math.max(1, Style.space(2))
                color: root.foreground
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.enterTab(parent.modelData)
              }
            }
          }

          Item { Layout.fillWidth: true }

          Text {
            textFormat: Text.PlainText
            text: root.tab === "explore"
              ? (service.currentExplore ? (service.currentExplore.path ? service.currentExplore.display : "Home") + " · " +
                  Model.formatBytes(service.currentExplore.total) : "")
              : (root.tab === "projects" && service.projects
                ? service.projects.projects.length + " projects" : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideLeft
            Layout.maximumWidth: Style.space(220)
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        // ---- list
        Flickable {
          id: listFlick
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.preferredHeight: Math.min(listColumn.implicitHeight, Style.space(430))
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
              text: root.tab === "cleanup" ? (service.scanning ? "Measuring caches…" : (service.scanError || "Nothing to clean"))
                : (root.tab === "projects" ? (service.projectsLoading ? "Looking through projects…" : "No build folders found")
                  : (service.exploring ? "Measuring folders… (the home folder takes a few seconds)" : "Empty folder"))
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: root.rows

              Loader {
                id: rowLoader
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
          text: service.jobRunning ? "Cleaning… " + Model.jobProgress(service.job) : service.message
          color: service.messageUrgent && !service.jobRunning ? root.urgent : root.dim
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
            text: root.tab === "explore" ? "x trash · o open · p keep"
              : (root.tab === "projects" ? "space select · m measure precisely" : "space select · d preview")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            visible: root.tab !== "explore"
            text: {
              if (service.jobRunning) return "Cleaning…"
              if (root.tab === "projects") {
                var b = Model.projectSelectionBytes(service.projects, root.projectSelection, service.projectsExclusive)
                return root.projectTargets.length ? "Delete selected · ~" + Model.formatBytes(b) : "Nothing selected"
              }
              if (!root.cleanTargets.length) return "Nothing selected"
              return "Clean selected · " + (root.summary.bytes > 0 ? "~" + Model.formatBytes(root.summary.bytes) : "size unknown")
            }
            enabled: !service.jobRunning && (root.tab === "projects" ? root.projectTargets.length > 0 : root.cleanTargets.length > 0)
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.askClean()
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
        text: parent.row ? parent.row.group.title.toUpperCase() : ""
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        anchors.left: header.right
        anchors.baseline: header.baseline
        anchors.leftMargin: Style.space(8)
        textFormat: Text.PlainText
        text: parent.row ? parent.row.group.subtitle : ""
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
      readonly property bool copyable: !!row && !!row.cat && !!row.cat.blocked
        && (row.cat.blocked.reason === "helper-missing" || row.cat.blocked.reason === "helper-outdated")
      implicitHeight: noteText.implicitHeight + Style.space(6)

      Text {
        id: noteText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(8) + Style.space(20)
        anchors.rightMargin: Style.space(8)
        textFormat: Text.PlainText
        text: parent.row ? parent.row.text + (parent.copyable ? "  (click to copy)" : "") : ""
        color: parent.row && parent.row.urgent ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      MouseArea {
        anchors.fill: parent
        enabled: parent.copyable
        cursorShape: Qt.PointingHandCursor
        onClicked: {
          service.copyText(service.scan.helper.setupCommand)
          service.say("Copied. Paste it in a terminal, then rescan.", false)
        }
      }
    }
  }

  Component {
    id: listRow

    ListRow {
      id: lr
      readonly property var row: parent ? parent.modelData : null
      readonly property int rowIndex: parent ? parent.index : -1
      readonly property var props: row ? root.rowProps(row) : ({})

      hasCursor: root.cursorActive && root.cursor === rowIndex
      onHasCursorChanged: if (hasCursor) root.cursorItem = lr
      textColor: root.foreground
      urgentColor: root.urgent
      fontFamily: root.fontFamily
      checkGlyph: props.check || ""
      iconGlyph: props.icon || ""
      title: props.title || ""
      detail: props.detail || ""
      badge: props.badge || ""
      badgeUrgent: !!props.urgent
      size: props.size || ""
      chevron: props.chevron || ""
      indent: props.indent || 0
      muted: !!props.muted
      fraction: props.fraction === undefined ? -1 : props.fraction

      onHovered: root.setCursor(rowIndex)
      onCheckClicked: { root.setCursor(rowIndex); root.toggleRow(row) }
      onChevronClicked: {
        root.setCursor(rowIndex)
        if (row.kind === "category") root.toggleExpanded(row.cat)
        else if (row.kind === "project") root.toggleProjectExpanded(row.project)
        else root.activateRow(row, true)
      }
      onClicked: {
        root.setCursor(rowIndex)
        if (row.kind === "entry" || row.kind === "up") root.activateRow(row, true)
        else if ((row.kind === "category" && row.expandable) || row.kind === "project") root.activateRow(row, true)
        else root.toggleRow(row)
      }
    }
  }
}
