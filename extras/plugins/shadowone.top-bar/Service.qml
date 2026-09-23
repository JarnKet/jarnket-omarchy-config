import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Top Bar: a second bar surface on the edge opposite the Omarchy bar.
//
// It renders third-party bar widgets straight from the shell's widget
// registry and hands each one the same PluginBarApi facade the Omarchy bar
// gives third-party widgets, so widgets, popups, tooltips and click routing
// behave as they do on the main bar.
//
// Its shell.json entry is the bridge widget (TopBarBridge.qml) on the Omarchy bar,
// managed by `omarchy-topbar` and by dragging:
//   { "id": "shadowone.top-bar",
//     "position": "auto",                       // auto | top | bottom
//     "layout": { "left": [...], "center": [...], "right": [...] },
//     "managed": ["<id>", ...] }                // ids this plugin enabled
//
// A widget renders here only while its plugin is enabled (omarchy-topbar adds
// it to `plugins`). Widgets that also sit on the Omarchy bar or in a Bar
// Folder are skipped, so no widget ever runs twice. First-party widgets are
// skipped because they expect the Omarchy bar itself as their host.
Item {
  id: root

  // Injected by the host shell.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null

  readonly property string pluginId: "shadowone.top-bar"
  readonly property string configPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"

  // ------------------------------------------------------------ config state

  property var fileConfig: null
  property var ownEntry: ({})
  property var leftIds: []
  property var centerIds: []
  property var rightIds: []
  property var settingsById: ({})
  property bool requestedTransparent: false

  readonly property bool hasWidgets: leftIds.length + centerIds.length + rightIds.length > 0
  readonly property var mainBarState: shell ? shell.bar : null
  readonly property string mainPosition: mainBarState ? String(mainBarState.position || "top") : "top"
  readonly property bool barHidden: mainBarState ? mainBarState.barHidden === true : false
  readonly property string position: {
    var requested = String(ownEntry.position || "auto")
    if (requested === "top" || requested === "bottom") return requested
    return mainPosition === "top" ? "bottom" : "top"
  }
  readonly property bool vertical: false
  readonly property int barSize: Style.bar.sizeHorizontal

  // ------------------------------------------------------------- appearance

  property string fontFamily: Style.font.family
  property color themeForeground: Color.bar.text
  property color themeContrastForeground: Color.background
  property color transparentForeground: Color.bar.text
  property bool useTransparentForeground: false
  property bool transparent: false
  property bool foregroundAnimationEnabled: true
  property color foreground: themeForeground
  property color barForeground: useTransparentForeground ? transparentForeground : themeForeground
  property color background: Color.bar.background
  property color urgent: Color.bar.active

  Behavior on barForeground { enabled: root.foregroundAnimationEnabled; ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on background { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on urgent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }

  // ------------------------------------------------------------ live objects

  property var moduleSlots: []
  property var clickTargets: []
  property var activePopout: null
  property var pluginBarApis: ({})
  property var hostShells: ({})
  property var pluginObjectOwners: []

  property var tooltipTarget: null
  property var pendingTooltipTarget: null
  property string tooltipText: ""
  property string pendingTooltipText: ""
  property bool tooltipShown: false
  property int tooltipRequest: 0

  // ================================================================= config

  FileView {
    id: shellJsonFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfig(text())
    onFileChanged: reload()
  }

  function sameJson(a, b) {
    return JSON.stringify(a) === JSON.stringify(b)
  }

  function entryId(entry) {
    if (typeof entry === "string") return Util.canonicalWidgetId(entry)
    if (Util.isPlainObject(entry) && entry.id) return Util.canonicalWidgetId(String(entry.id))
    return ""
  }

  function entrySettings(entry) {
    var copy = {}
    if (!Util.isPlainObject(entry)) return copy
    for (var key in entry) if (key !== "id") copy[key] = entry[key]
    return copy
  }

  // Ids the Omarchy bar already hosts, including widgets tucked into a
  // container widget such as Bar Folder (entries carrying a `widgets` list).
  function mainBarIds(config) {
    var ids = {}
    var layout = Util.isPlainObject(config.bar) && Util.isPlainObject(config.bar.layout) ? config.bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var i = 0; i < entries.length; i++) {
        var id = entryId(entries[i])
        if (id === pluginId) continue
        if (id) ids[id] = true
        var nested = Util.isPlainObject(entries[i]) ? entries[i].widgets : null
        if (Array.isArray(nested))
          for (var n = 0; n < nested.length; n++) if (nested[n]) ids[entryId(nested[n])] = true
      }
    }
    return ids
  }

  // This plugin's entry: the bridge widget on the Omarchy bar, or (from an
  // older version) an entry in `plugins`.
  function findOwnEntry(config) {
    var layout = Util.isPlainObject(config.bar) && Util.isPlainObject(config.bar.layout) ? config.bar.layout : {}
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var i = 0; i < entries.length; i++)
        if (entryId(entries[i]) === pluginId) return Util.isPlainObject(entries[i]) ? Util.cloneJson(entries[i]) : {}
    }
    var plugins = Array.isArray(config.plugins) ? config.plugins : []
    for (var p = 0; p < plugins.length; p++)
      if (plugins[p] && entryId(plugins[p]) === pluginId) return Util.cloneJson(plugins[p])
    return {}
  }

  function applyConfig(raw) {
    var config = null
    try {
      config = JSON.parse(String(raw || ""))
    } catch (e) {
      // A half-written file; keep the last good layout until the next write.
      return
    }
    if (!Util.isPlainObject(config)) return
    fileConfig = config

    var bar = Util.isPlainObject(config.bar) ? config.bar : {}
    if ((bar.transparent === true) !== requestedTransparent) setRequestedTransparency(bar.transparent === true)

    var entry = findOwnEntry(config)
    if (!sameJson(entry, ownEntry)) ownEntry = entry

    var hosted = mainBarIds(config)
    var layout = Util.normalizeLayout(entry.layout)
    var seen = {}
    var settings = {}
    var next = { left: [], center: [], right: [] }
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var entries = layout[sections[s]]
      for (var i = 0; i < entries.length; i++) {
        var id = entryId(entries[i])
        if (!id || seen[id]) continue
        seen[id] = true
        if (hosted[id]) {
          console.warn("Top Bar: " + id + " is already on the Omarchy bar; not showing it twice")
          continue
        }
        next[sections[s]].push(id)
        settings[id] = entrySettings(entries[i])
      }
    }

    if (!sameJson(settings, settingsById)) settingsById = settings
    // Repeaters rebuild every widget when handed a new array, so only swap
    // a section when its ids actually changed.
    if (!sameJson(next.left, leftIds)) leftIds = next.left
    if (!sameJson(next.center, centerIds)) centerIds = next.center
    if (!sameJson(next.right, rightIds)) rightIds = next.right
    syncAllPluginBarApiObjects()
  }

  function settingsFor(id) {
    var value = settingsById[id]
    return value ? Util.cloneJson(value) : {}
  }

  function sectionOf(id) {
    if (leftIds.indexOf(id) !== -1) return "left"
    if (centerIds.indexOf(id) !== -1) return "center"
    if (rightIds.indexOf(id) !== -1) return "right"
    return ""
  }

  function publicLayoutConfig() {
    function entries(ids) {
      return ids.map(function(id) {
        var entry = { id: id }
        var settings = root.settingsById[id] || {}
        for (var key in settings) entry[key] = settings[key]
        return entry
      })
    }
    return JSON.parse(JSON.stringify({ left: entries(leftIds), center: entries(centerIds), right: entries(rightIds) }))
  }

  // Inline settings a hosted widget persists land in its entry inside this
  // plugin's own shell.json entry, written through the shell like any other
  // plugin's settings.
  function persistWidgetSettings(widgetId, settings) {
    if (!shell || typeof shell.updateEntryInline !== "function" || !fileConfig) return false
    var entry = findOwnEntry(fileConfig)
    var layout = Util.normalizeLayout(entry.layout)
    var found = false
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout[sections[s]]
      for (var i = 0; i < list.length; i++) {
        if (entryId(list[i]) !== widgetId) continue
        var next = { id: widgetId }
        for (var key in settings) if (key !== "id") next[key] = settings[key]
        list[i] = next
        found = true
      }
    }
    if (!found) return false
    entry.layout = layout
    delete entry.id
    return shell.updateEntryInline(pluginId, entry)
  }

  // ============================================================ transparency

  function colorHex(colorValue) {
    var c = colorValue
    if (typeof c === "string") c = Qt.color(c)
    function hexChannel(value) {
      var s = Math.round(Util.clamp(value, 0, 1) * 255).toString(16)
      return s.length < 2 ? "0" + s : s
    }
    return "#" + hexChannel(c.r) + hexChannel(c.g) + hexChannel(c.b)
  }

  function setRequestedTransparency(value) {
    requestedTransparent = value === true
    if (!requestedTransparent) {
      foregroundAnimationEnabled = false
      useTransparentForeground = false
      transparent = false
      transparentForeground = themeForeground
      restoreForegroundAnimation()
      return
    }
    scheduleTransparentForegroundRefresh()
  }

  function restoreForegroundAnimation() {
    Qt.callLater(function() {
      Qt.callLater(function() { root.foregroundAnimationEnabled = true })
    })
  }

  function scheduleTransparentForegroundRefresh() {
    if (!requestedTransparent) {
      transparentForeground = themeForeground
      return
    }
    transparentForegroundTimer.restart()
  }

  onPositionChanged: scheduleTransparentForegroundRefresh()
  onThemeForegroundChanged: scheduleTransparentForegroundRefresh()
  onThemeContrastForegroundChanged: scheduleTransparentForegroundRefresh()

  Timer {
    id: transparentForegroundTimer
    interval: 120
    onTriggered: {
      if (!root.requestedTransparent || transparentForegroundProc.running) return
      // Samples the wallpaper under this bar's own edge.
      transparentForegroundProc.command = [
        "omarchy-bar-text-color",
        root.position,
        String(root.barSize),
        root.colorHex(root.themeForeground),
        root.colorHex(root.themeContrastForeground)
      ]
      transparentForegroundProc.running = true
    }
  }

  Process {
    id: transparentForegroundProc
    stdout: SplitParser {
      onRead: function(line) {
        var value = String(line || "").trim()
        if (!/^#[0-9A-Fa-f]{6}$/.test(value)) return
        root.foregroundAnimationEnabled = false
        root.transparentForeground = value
        if (root.requestedTransparent) {
          root.useTransparentForeground = true
          root.transparent = true
        }
        root.restoreForegroundAnimation()
      }
    }
  }

  // The wallpaper changes with the theme/background.
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current"
    watchChanges: true
    printErrors: false
    onFileChanged: root.scheduleTransparentForegroundRefresh()
  }

  // ========================================================= widget facades

  Component {
    id: pluginBarApiComponent
    PluginBarApi { }
  }

  // Scalar bar state, the shape PluginShellApi.bar has, describing this bar.
  Component {
    id: barStateComponent
    QtObject {
      property bool barHidden: root.barHidden
      property int barSize: root.barSize
      property string fontFamily: root.fontFamily
      property string position: root.position
    }
  }

  // The `bar.shell` a hosted widget sees. It carries the same scope a
  // third-party widget has on the Omarchy bar: its own id only. Panel calls
  // for that id reach this bar's instance; there is no service access.
  Component {
    id: hostShellComponent
    QtObject {
      required property string pluginId
      property var bar: null
      property var appLibrary: null
      property var barConfig: ({})
      property var idleConfig: ({})

      function serviceFor(id) { return null }
      function firstPartyServiceFor(id) { return null }
      function pluginShellForBarEntry(ownerId, moduleName) { return null }
      function summon(id, payloadJson) { return root.hostSummon(pluginId, id, payloadJson) }
      function hide(id) { return root.hostHide(pluginId, id) }
      function toggle(id, payloadJson) { return root.hostToggle(pluginId, id, payloadJson) }
      function isPluginOpen(id) { return root.hostIsOpen(pluginId, id) }
      function updateEntryInline(id, settings) {
        return Util.canonicalWidgetId(String(id || "")) === pluginId
          ? root.persistWidgetSettings(pluginId, settings || {}) : false
      }
      function mutateShellConfig(mutator) { return false }
    }
  }

  function hostShellFor(id) {
    if (hostShells[id]) return hostShells[id]
    var api = hostShellComponent.createObject(null, { pluginId: id })
    if (!api) return null
    api.bar = barStateComponent.createObject(api)
    api.barConfig = Qt.binding(function() {
      return root.fileConfig && Util.isPlainObject(root.fileConfig.bar)
        ? Util.cloneJson(root.fileConfig.bar) : ({})
    })
    var next = ({})
    for (var key in hostShells) next[key] = hostShells[key]
    next[id] = api
    hostShells = next
    return api
  }

  function bindPluginBarApi(api) {
    api.foreground = Qt.binding(function() { return root.foreground })
    api.barForeground = Qt.binding(function() { return root.barForeground })
    api.background = Qt.binding(function() { return root.background })
    api.urgent = Qt.binding(function() { return root.urgent })
    api.fontFamily = Qt.binding(function() { return root.fontFamily })
    api.position = Qt.binding(function() { return root.position })
    api.vertical = false
    api.barSize = Qt.binding(function() { return root.barSize })
    api.transparent = Qt.binding(function() { return root.transparent })
    api.foregroundAnimationEnabled = Qt.binding(function() { return root.foregroundAnimationEnabled })
    api.centerSectionRevealHeld = false
    syncPluginBarApiObjects(api)
  }

  function syncPluginBarApiObjects(api) {
    if (!api) return
    api.activePopout = pluginOwnsObject(api.pluginId, activePopout)
      ? activePopout : (activePopout ? api.foreignPopoutMarker : null)
    api.clickTargets = pluginClickTargets(api.pluginId)
    api.layoutConfig = publicLayoutConfig()
  }

  function syncAllPluginBarApiObjects() {
    for (var id in pluginBarApis) syncPluginBarApiObjects(pluginBarApis[id])
  }

  function pluginBarApiFor(id) {
    if (pluginBarApis[id]) return pluginBarApis[id]
    var api = pluginBarApiComponent.createObject(null, {
      pluginId: id,
      moduleName: id,
      shell: hostShellFor(id),
      _showTooltip: function(target, text) { root.showTooltip(target, text) },
      _hideTooltip: function(target) { root.hideTooltip(target) },
      _registerClickTarget: function(target) { root.registerPluginClickTarget(id, target) },
      _unregisterClickTarget: function(target) { root.unregisterPluginClickTarget(id, target) },
      _requestPopout: function(owner) { root.requestPluginPopout(id, owner) },
      _releasePopout: function(owner) { root.releasePluginPopout(id, owner) },
      _switchPanelFrom: function(owner, direction) { return root.switchPanelFrom(owner, direction) },
      _targetBelongsToWindow: function(target, window) { return root.targetBelongsToWindow(target, window) },
      _moduleWidgets: function(requestedId) {
        return String(requestedId || "") === id ? root.moduleWidgets(id) : []
      },
      _run: function(command) { root.run(command) },
      _setCenterHoverRevealSuppressed: function(value) { }
    })
    if (!api) return null
    bindPluginBarApi(api)
    var next = ({})
    for (var key in pluginBarApis) next[key] = pluginBarApis[key]
    next[id] = api
    pluginBarApis = next
    return api
  }

  // ------------------------------------------- object ownership (as Bar.qml)

  function pluginObjectRecord(target) {
    for (var i = 0; i < pluginObjectOwners.length; i++) {
      var record = pluginObjectOwners[i]
      if (record && record.target === target) return record
    }
    return null
  }

  function markPluginObject(pluginId, target, role) {
    var key = String(pluginId || "")
    if (!key || !target) return false
    var record = pluginObjectRecord(target)
    if (record && record.pluginId !== key) return false
    var next = []
    for (var i = 0; i < pluginObjectOwners.length; i++) {
      var existing = pluginObjectOwners[i]
      if (!existing || existing.target !== target) next.push(existing)
    }
    var updated = record || { target: target, pluginId: key, clickTarget: false, popout: false }
    updated[role] = true
    next.push(updated)
    pluginObjectOwners = next
    return true
  }

  function unmarkPluginObject(pluginId, target, role) {
    var key = String(pluginId || "")
    var next = []
    for (var i = 0; i < pluginObjectOwners.length; i++) {
      var record = pluginObjectOwners[i]
      if (!record || record.target !== target || record.pluginId !== key) {
        next.push(record)
        continue
      }
      record[role] = false
      if (record.clickTarget || record.popout) next.push(record)
    }
    pluginObjectOwners = next
  }

  function pluginOwnsObject(pluginId, target) {
    var record = target ? pluginObjectRecord(target) : null
    return !!record && record.pluginId === String(pluginId || "")
  }

  function pluginClickTargets(pluginId) {
    var out = []
    for (var i = 0; i < clickTargets.length; i++)
      if (pluginOwnsObject(pluginId, clickTargets[i])) out.push(clickTargets[i])
    return out
  }

  function registerPluginClickTarget(pluginId, target) {
    if (!markPluginObject(pluginId, target, "clickTarget")) return
    if (!target || clickTargets.indexOf(target) !== -1) return
    var next = clickTargets.slice()
    next.push(target)
    clickTargets = next
  }

  function unregisterPluginClickTarget(pluginId, target) {
    if (!pluginOwnsObject(pluginId, target)) return
    clickTargets = clickTargets.filter(function(item) { return item !== target })
    unmarkPluginObject(pluginId, target, "clickTarget")
  }

  function requestPluginPopout(pluginId, owner) {
    if (!markPluginObject(pluginId, owner, "popout")) return
    requestPopout(owner)
  }

  function releasePluginPopout(pluginId, owner) {
    if (!pluginOwnsObject(pluginId, owner)) return
    releasePopout(owner)
    unmarkPluginObject(pluginId, owner, "popout")
  }

  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  function releasePluginObjects(pluginId) {
    var owned = pluginObjectOwners.slice()
    for (var i = 0; i < owned.length; i++) {
      var record = owned[i]
      if (!record || record.pluginId !== pluginId) continue
      if (record.clickTarget) clickTargets = clickTargets.filter(function(item) { return item !== record.target })
      if (record.popout && activePopout === record.target) releasePopout(record.target)
    }
    pluginObjectOwners = pluginObjectOwners.filter(function(record) {
      return record && record.pluginId !== pluginId
    })
  }

  // Drop the facades of widgets that left the bar.
  function prunePluginBarApis() {
    var used = {}
    for (var i = 0; i < moduleSlots.length; i++) if (moduleSlots[i]) used[moduleSlots[i].moduleName] = true
    var nextApis = ({})
    for (var id in pluginBarApis) {
      if (used[id]) {
        nextApis[id] = pluginBarApis[id]
        continue
      }
      releasePluginObjects(id)
      if (pluginBarApis[id]) pluginBarApis[id].destroy()
    }
    pluginBarApis = nextApis
    var nextShells = ({})
    for (var sid in hostShells) {
      if (used[sid]) nextShells[sid] = hostShells[sid]
      else if (hostShells[sid]) hostShells[sid].destroy()
    }
    hostShells = nextShells
  }

  onActivePopoutChanged: syncAllPluginBarApiObjects()
  onClickTargetsChanged: syncAllPluginBarApiObjects()
  onModuleSlotsChanged: Qt.callLater(prunePluginBarApis)

  Component.onDestruction: {
    for (var id in pluginBarApis) {
      releasePluginObjects(id)
      if (pluginBarApis[id]) pluginBarApis[id].destroy()
    }
    for (var sid in hostShells) if (hostShells[sid]) hostShells[sid].destroy()
    pluginBarApis = ({})
    hostShells = ({})
  }

  // ================================================================= slots

  function registerSlot(slot) {
    if (!slot || moduleSlots.indexOf(slot) !== -1) return
    var next = moduleSlots.slice()
    next.push(slot)
    moduleSlots = next
  }

  function unregisterSlot(slot) {
    moduleSlots = moduleSlots.filter(function(item) { return item !== slot })
  }

  function targetWindow(target) {
    return target && target.QsWindow ? target.QsWindow.window : null
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && targetWindow(target) === window
  }

  function slotWindow(slot) {
    if (!slot) return null
    return targetWindow(slot.activeItem) || targetWindow(slot)
  }

  function slotScreenName(slot) {
    var window = slotWindow(slot)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function moduleWidgets(id) {
    var items = []
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (slot && slot.activeItem && slot.moduleName === id) items.push(slot.activeItem)
    }
    return items
  }

  function isPanelItem(item) {
    return !!item && typeof item.open === "function" && typeof item.close === "function" && item.opened !== undefined
  }

  // The instance on the monitor Hyprland has focused, else any visible one.
  function panelWidget(id) {
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var fallback = null
    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot.moduleName !== id || !isPanelItem(slot.activeItem)) continue
      if (slot.activeItem.opened === true) return slot.activeItem
      if (focused && slotScreenName(slot) === focused) return slot.activeItem
      if (!fallback) fallback = slot.activeItem
    }
    return fallback
  }

  function panelNavigationSlots(region, window) {
    var ids = region === "left" ? leftIds : (region === "center" ? centerIds : rightIds)
    var slots = []
    for (var i = 0; i < ids.length; i++) {
      for (var j = 0; j < moduleSlots.length; j++) {
        var slot = moduleSlots[j]
        if (!slot || slot.region !== region || slot.moduleName !== ids[i]) continue
        if (window && slotWindow(slot) !== window) continue
        var item = slot.activeItem
        if (!isPanelItem(item) || item.visible !== true || slot.visible !== true || slot.width <= 0) continue
        slots.push(slot)
        break
      }
    }
    return slots
  }

  function switchPanelFrom(owner, direction) {
    if (!owner) return false
    var current = null
    for (var i = 0; i < moduleSlots.length; i++) {
      if (moduleSlots[i] && moduleSlots[i].activeItem === owner) {
        current = moduleSlots[i]
        break
      }
    }
    if (!current) return false
    var slots = panelNavigationSlots(current.region, slotWindow(current))
    if (slots.length < 2) return false
    var index = slots.indexOf(current)
    if (index < 0) return false
    var nextSlot = slots[(index + (direction < 0 ? -1 : 1) + slots.length) % slots.length]
    if (!nextSlot || !nextSlot.activeItem || nextSlot.activeItem === owner) return false
    nextSlot.activeItem.open()
    return true
  }

  // ------------------------------------------------- host shell operations

  function owns(ownerId, requestedId) {
    return Util.canonicalWidgetId(String(requestedId || "")) === ownerId
  }

  function hostSummon(ownerId, requestedId, payloadJson) {
    if (!owns(ownerId, requestedId)) return false
    var item = panelWidget(ownerId)
    if (item) {
      item.open()
      return true
    }
    // No bar panel: the plugin's own panel or overlay, which the shell owns.
    var command = ["omarchy-shell", "-q", "shell", "summon", ownerId]
    if (payloadJson) command.push(String(payloadJson))
    Quickshell.execDetached(command)
    return true
  }

  function hostHide(ownerId, requestedId) {
    if (!owns(ownerId, requestedId)) return false
    var items = moduleWidgets(ownerId)
    var handled = false
    for (var i = 0; i < items.length; i++) {
      if (!isPanelItem(items[i])) continue
      handled = true
      if (items[i].opened === true) items[i].close()
    }
    if (!handled) Quickshell.execDetached(["omarchy-shell", "-q", "shell", "hide", ownerId])
    return true
  }

  function hostIsOpen(ownerId, requestedId) {
    if (!owns(ownerId, requestedId)) return false
    var items = moduleWidgets(ownerId)
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened === true) return true
    return false
  }

  function hostToggle(ownerId, requestedId, payloadJson) {
    if (!owns(ownerId, requestedId)) return false
    return hostIsOpen(ownerId, requestedId) ? hostHide(ownerId, requestedId) : hostSummon(ownerId, requestedId, payloadJson)
  }

  function run(command) {
    if (command) Util.execDetached(command)
  }

  // ----------------------------------------------------------- click routing

  function isWithin(item, ancestor) {
    for (var node = item; node; node = node.parent) if (node === ancestor) return true
    return false
  }

  function moduleTargetClickable(target) {
    return target
      && target.visible !== false
      && target.opacity !== 0
      && target.interactive !== false
      && target.pressable !== false
      && target.concealed !== true
      && typeof target.triggerPress === "function"
  }

  function moduleClickTargetAt(slot, localX, localY) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var target = clickTargets[i]
      if (!moduleTargetClickable(target) || !isWithin(target, slot)) continue
      var point = null
      try {
        point = slot.mapToItem(target, localX, localY)
      } catch (e) {
        continue
      }
      if (point.x >= 0 && point.x <= target.width && point.y >= 0 && point.y <= target.height) return target
    }
    if (moduleTargetClickable(slot.activeItem)) return slot.activeItem
    return null
  }

  // ================================================================ tooltips

  function targetTooltipHovered(target) {
    return !!target && target.visible !== false && target.opacity !== 0 && target.tooltipHovered === true
  }

  function clearTooltip() {
    tooltipTimer.stop()
    pendingTooltipTarget = null
    pendingTooltipText = ""
    tooltipTarget = null
    tooltipText = ""
    tooltipShown = false
  }

  function showTooltip(target, text) {
    clearTooltip()
    if (!targetTooltipHovered(target) || !text) {
      tooltipRequest += 1
      return
    }
    var request = tooltipRequest + 1
    tooltipRequest = request
    pendingTooltipTarget = target
    pendingTooltipText = text
    Qt.callLater(function() {
      if (request !== root.tooltipRequest) return
      if (!root.targetTooltipHovered(root.pendingTooltipTarget)) {
        root.clearTooltip()
        return
      }
      root.tooltipTarget = root.pendingTooltipTarget
      root.tooltipText = root.pendingTooltipText
      root.pendingTooltipTarget = null
      root.pendingTooltipText = ""
      tooltipTimer.restart()
    })
  }

  function hideTooltip(target) {
    if (tooltipTarget !== target && pendingTooltipTarget !== target) return
    tooltipRequest += 1
    clearTooltip()
  }

  Timer {
    id: tooltipTimer
    interval: 400
    onTriggered: {
      if (root.targetTooltipHovered(root.tooltipTarget)) root.tooltipShown = true
      else root.clearTooltip()
    }
  }

  Timer {
    interval: 100
    running: root.tooltipShown
    repeat: true
    onTriggered: if (!root.targetTooltipHovered(root.tooltipTarget)) root.hideTooltip(root.tooltipTarget)
  }

  // ============================================================ drag & drop
  //
  // Three drags, one set of drop rules:
  //   top bar -> top bar       reorder, across left / center / right
  //   top bar -> Omarchy bar   put the widget back where it is dropped
  //   Omarchy bar -> top bar   reported by the bridge widget (TopBarBridge.qml)
  // Every drop is applied by omarchy-topbar, which validates the widget and
  // writes shell.json atomically; the shell then reloads both bars.

  property var bridges: []

  // A drag that started on the top bar.
  property var dragSlot: null
  property string dragScreen: ""
  property real dragScreenX: 0
  property real dragScreenY: 0
  property real dragOffsetX: 0
  property real dragOffsetY: 0
  property url dragImageUrl: ""
  property var dragTarget: null

  // A drag that started on the Omarchy bar.
  property string extDragId: ""
  property string extDragScreen: ""
  property var extDragTarget: null
  property real extDragX: 0
  property var compat: ({})

  readonly property string dragSourceId: dragSlot ? String(dragSlot.moduleName || "") : extDragId
  readonly property string activeDragScreen: dragSlot ? dragScreen : extDragScreen
  readonly property var activeDropTarget: dragSlot ? dragTarget : extDragTarget
  // A widget dragged up from the Omarchy bar that cannot live here.
  readonly property bool activeDropRefused: !dragSlot && extDragId !== ""
    && compat[extDragId] !== undefined && compat[extDragId].ok === false
  // Why, in a few words, for the label on the top bar.
  readonly property string activeDropRefusal: {
    if (!activeDropRefused) return ""
    var reason = String(compat[extDragId].reason || "")
    if (reason.indexOf("built-in") !== -1) return "Built-in Omarchy widget — stays on the Omarchy bar"
    if (reason.indexOf("services") !== -1) return "Needs its Omarchy-bar service — can't move here"
    return "Can't move here — " + reason
  }
  readonly property string cliPath: decodeURIComponent(String(Qt.resolvedUrl("omarchy-topbar")).replace(/^file:\/\//, ""))

  function registerBridge(bridge) {
    if (!bridge || bridges.indexOf(bridge) !== -1) return
    bridges = bridges.filter(function(item) { return !!item }).concat([bridge])
  }

  function unregisterBridge(bridge) {
    bridges = bridges.filter(function(item) { return !!item && item !== bridge })
  }

  function bridgeFor(screenName) {
    for (var i = 0; i < bridges.length; i++) {
      try {
        if (bridges[i] && bridges[i].screenName() === screenName) return bridges[i]
      } catch (e) {
      }
    }
    return null
  }

  function screenByName(name) {
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) if (String(screens[i].name || "") === name) return screens[i]
    return null
  }

  // This bar's rectangle on a screen, in the screen's logical space. Sharing
  // an edge with the Omarchy bar stacks it inward of that bar.
  function topBarScreenRect(screenName) {
    var screen = screenByName(screenName)
    if (!screen) return null
    var stacked = position === mainPosition && !barHidden && mainBarState ? Math.max(0, mainBarState.barSize || 0) : 0
    var y = position === "top" ? stacked : screen.height - barSize - stacked
    return { x: 0, y: y, width: screen.width, height: barSize }
  }

  function overTopBar(screenName, y) {
    var rect = topBarScreenRect(screenName)
    var tolerance = 12
    return !!rect && y >= rect.y - tolerance && y <= rect.y + rect.height + tolerance
  }

  function slotScreenPoint(slot, x, y) {
    var point = slot.mapToItem(null, x, y)
    var rect = topBarScreenRect(slotScreenName(slot))
    return { x: point.x, y: point.y + (rect ? rect.y : 0) }
  }

  function sectionIds(region) {
    return region === "left" ? leftIds : (region === "center" ? centerIds : rightIds)
  }

  // Drop boxes for sections that would be empty without the dragged widget,
  // so an empty left, center or right can still take a drop.
  function emptyZones(screenName, sourceId) {
    var screen = screenByName(screenName)
    if (!screen) return []
    var width = Style.space(44)
    var pad = Style.space(8)
    var zones = []
    var regions = ["left", "center", "right"]
    for (var i = 0; i < regions.length; i++) {
      var others = sectionIds(regions[i]).filter(function(id) { return id !== sourceId })
      if (others.length > 0) continue
      var x = regions[i] === "left" ? pad : (regions[i] === "center" ? Math.round((screen.width - width) / 2) : screen.width - pad - width)
      zones.push({ region: regions[i], x: x, width: width })
    }
    return zones
  }

  // Nearest slot edge (or empty-section box) to screen x on this bar, the way
  // the Omarchy bar picks its own drop target. Rect is in bar-window space.
  function topDropTarget(screenName, x, sourceId) {
    var best = null
    var bestDistance = Infinity

    function consider(candidate, distance, after) {
      if (distance >= bestDistance) return
      bestDistance = distance
      best = { candidate: candidate, after: after }
    }

    for (var i = 0; i < moduleSlots.length; i++) {
      var slot = moduleSlots[i]
      if (!slot || slot.moduleName === sourceId || slotScreenName(slot) !== screenName) continue
      if (!slot.visible || slot.width <= 0 || slot.height <= 0) continue
      var p = null
      try { p = slot.mapToItem(null, 0, 0) } catch (e) { continue }
      var candidate = { region: slot.region, id: slot.moduleName, x: p.x, y: p.y, width: slot.width, height: slot.height }
      var before = Math.abs(x - p.x)
      var afterDistance = Math.abs(x - (p.x + slot.width))
      consider(candidate, Math.min(before, afterDistance), afterDistance < before)
    }

    var zones = emptyZones(screenName, sourceId)
    for (var z = 0; z < zones.length; z++) {
      var zone = zones[z]
      var inside = x >= zone.x && x <= zone.x + zone.width
      var distance = inside ? 0 : Math.min(Math.abs(x - zone.x), Math.abs(x - (zone.x + zone.width)))
      consider({ region: zone.region, zone: true, x: zone.x, width: zone.width }, distance, false)
    }

    if (!best) return null
    var c = best.candidate
    var ids = sectionIds(c.region).filter(function(id) { return id !== sourceId })
    var index = c.zone ? 0 : ids.indexOf(c.id) + (best.after ? 1 : 0)
    var thickness = Style.spacing.xs
    var rect = c.zone
      ? { x: c.x, y: Style.space(3), width: c.width, height: barSize - Style.space(6) }
      : { x: c.x + (best.after ? c.width : 0) - thickness / 2, y: c.y, width: thickness, height: c.height }
    // Dropping a widget back into its own gap changes nothing.
    var noop = sectionIds(c.region).indexOf(sourceId) === index
    return { kind: "top", region: c.region, index: index, zone: c.zone === true, rect: rect, noop: noop }
  }

  // ---------------------------------------------------- drags on the top bar

  function beginDrag(slot, offsetX, offsetY) {
    dragSlot = slot
    dragScreen = slotScreenName(slot)
    dragOffsetX = offsetX
    dragOffsetY = offsetY
    dragTarget = null
    dragImageUrl = ""
    if (slot.activeItem) hideTooltip(slot.activeItem)
    var item = slot.activeItem
    if (item && typeof item.grabToImage === "function") {
      item.grabToImage(function(result) {
        if (root.dragSlot === slot && result && result.url) root.dragImageUrl = result.url
      }, Qt.size(Math.max(1, Math.ceil(item.width)), Math.max(1, Math.ceil(item.height))))
    }
  }

  function updateDrag(x, y) {
    if (!dragSlot) return
    dragScreenX = x
    dragScreenY = y
    var id = String(dragSlot.moduleName || "")
    if (overTopBar(dragScreen, y)) {
      dragTarget = topDropTarget(dragScreen, x, id)
      return
    }
    var bridge = bridgeFor(dragScreen)
    var target = null
    try { target = bridge ? bridge.dropTargetAt(x, y, id) : null } catch (e) { target = null }
    dragTarget = target ? { kind: "main", region: target.region, name: target.name, after: target.after, rect: target.rect } : null
  }

  function clearDrag() {
    dragSlot = null
    dragScreen = ""
    dragTarget = null
    dragImageUrl = ""
  }

  function finishDrag() {
    var target = dragTarget
    var id = dragSlot ? String(dragSlot.moduleName || "") : ""
    clearDrag()
    if (!id || !target || target.noop) return
    if (target.kind === "top") runTopbar(["move", id, target.region, String(target.index)])
    else if (target.kind === "main") runTopbar(["remove", id, target.region, (target.after ? "after:" : "before:") + target.name])
  }

  // ------------------------------------------ drags from the Omarchy bar

  function externalDragStarted(id, screenName, x, y) {
    if (!id || id === pluginId) return
    extDragId = id
    extDragScreen = screenName
    ensureCompat(id)
    externalDragMoved(id, screenName, x, y)
  }

  function externalDragMoved(id, screenName, x, y) {
    if (id !== extDragId) return
    extDragX = x
    extDragTarget = overTopBar(screenName, y) ? topDropTarget(screenName, x, id) : null
  }

  function externalDragEnded(id, screenName, x, y) {
    var target = id === extDragId && x >= 0 && overTopBar(screenName, y) ? topDropTarget(screenName, x, id) : null
    extDragId = ""
    extDragScreen = ""
    extDragTarget = null
    if (!target) return
    var known = compat[id]
    if (known && known.ok === false) {
      notify(id + " stays on the Omarchy bar", known.reason)
      return
    }
    runTopbar(["add", id, target.region, String(target.index)])
  }

  // Whether a widget can live here, asked once per widget per session.
  property string compatPending: ""

  function ensureCompat(id) {
    if (compat[id] !== undefined) return
    if (compatProc.running) {
      compatPending = id
      return
    }
    compatProc.widgetId = id
    compatProc.command = [cliPath, "check", id]
    compatProc.running = true
  }

  Process {
    id: compatProc

    property string widgetId: ""

    stdout: StdioCollector { id: compatOut }
    onExited: function(exitCode) {
      var text = String(compatOut.text || "").trim()
      var dash = text.indexOf(" — ")
      var next = ({})
      for (var key in root.compat) next[key] = root.compat[key]
      next[widgetId] = { ok: exitCode === 0, reason: dash === -1 ? text : text.substring(dash + 3) }
      root.compat = next
      if (root.compatPending) {
        var pending = root.compatPending
        root.compatPending = ""
        Qt.callLater(function() { root.ensureCompat(pending) })
      }
    }
  }

  function notify(title, body) {
    Quickshell.execDetached(["notify-send", "-a", "Top Bar", String(title || ""), String(body || "")])
  }

  // Applies a drop. Failures (a widget that cannot move, a config the tool
  // refuses to touch) surface as a notification instead of vanishing.
  function runTopbar(args) {
    Quickshell.execDetached(["sh", "-c",
      "out=$(\"$@\" 2>&1) || notify-send -a 'Top Bar' 'Top Bar' \"$(printf '%s' \"$out\" | sed 's/^omarchy-topbar: //')\"",
      "sh", cliPath].concat(args))
  }

  // ===================================================================== IPC

  // omarchy-shell topbar toggle <widget-id>   (also open, close, list)
  IpcHandler {
    target: "topbar"

    function open(id: string): void { root.hostSummon(Util.canonicalWidgetId(id), id, "") }
    function close(id: string): void { root.hostHide(Util.canonicalWidgetId(id), id) }
    function toggle(id: string): void { root.hostToggle(Util.canonicalWidgetId(id), id, "") }
    function list(): string {
      return JSON.stringify({ position: root.position, bridges: root.bridges.length, left: root.leftIds, center: root.centerIds, right: root.rightIds })
    }
  }

  // ================================================================= windows

  Variants {
    model: Quickshell.screens

    delegate: Component {
      TopBarWindow {
        required property var modelData
        screen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens

    delegate: Component {
      DragGhostWindow {
        required property var modelData
        screen: modelData
      }
    }
  }

  component TopBarWindow: PanelWindow {
    id: barWindow

    readonly property string screenName: screen ? String(screen.name || "") : ""
    readonly property bool dragHere: root.activeDragScreen !== "" && root.activeDragScreen === screenName
    readonly property var dropTarget: dragHere && root.activeDropTarget && root.activeDropTarget.kind === "top"
      && !root.activeDropTarget.noop ? root.activeDropTarget : null
    readonly property var zones: dragHere ? root.emptyZones(screenName, root.dragSourceId) : []

    // Mapped while it has widgets, or while a widget is dragged toward it so
    // an empty top bar can still take a drop. Hiding the Omarchy bar parks
    // this one off its edge too, the way the Omarchy bar parks itself.
    visible: (root.hasWidgets || (dragHere && root.extDragId !== "")) && !remapGuard.remapping
    exclusionMode: root.barHidden || !root.hasWidgets ? ExclusionMode.Ignore : ExclusionMode.Auto

    ScreenMoveRemap {
      id: remapGuard
      window: barWindow
    }

    margins {
      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
    }

    anchors {
      top: root.position === "top"
      bottom: root.position === "bottom"
      left: true
      right: true
    }

    implicitHeight: root.barSize
    color: root.transparent ? "transparent" : root.background
    surfaceFormat.opaque: false
    // Same namespace as the Omarchy bar so Hyprland's bar layer rules apply.
    WlrLayershell.namespace: "omarchy-bar"
    WlrLayershell.layer: WlrLayer.Top

    Item {
      anchors.fill: parent

      Section {
        region: "center"
        ids: root.centerIds
        anchors.centerIn: parent
      }

      Section {
        region: "left"
        ids: root.leftIds
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      Section {
        region: "right"
        ids: root.rightIds
        anchors.right: parent.right
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
      }

      // Empty sections during a drag, so there is somewhere to drop.
      Repeater {
        model: barWindow.zones

        BorderSurface {
          required property var modelData
          readonly property bool targeted: !!barWindow.dropTarget && barWindow.dropTarget.zone
            && barWindow.dropTarget.region === modelData.region

          x: modelData.x
          y: Style.space(3)
          width: modelData.width
          height: root.barSize - Style.space(6)
          color: "transparent"
          borderSpec: Border.flat(root.activeDropRefused ? root.urgent : (targeted ? Color.accent : root.barForeground), 1)
          radius: Math.min(Style.cornerRadius, height / 2)
          opacity: targeted ? 0.95 : 0.35
        }
      }

      // Insertion mark between widgets.
      Rectangle {
        readonly property var rect: barWindow.dropTarget && !barWindow.dropTarget.zone && !root.activeDropRefused
          ? barWindow.dropTarget.rect : null

        visible: rect !== null
        x: rect ? Math.round(rect.x) : 0
        y: rect ? Math.round(rect.y) : 0
        width: rect ? rect.width : 0
        height: rect ? rect.height : 0
        color: Color.accent
        radius: Math.min(width, height) / 2
        z: 100
      }

      // A widget that cannot live here says so in words: theme colors alone
      // may not tell a refused drop from an accepted one.
      BorderSurface {
        readonly property var rect: barWindow.dropTarget && root.activeDropRefused ? barWindow.dropTarget.rect : null

        visible: rect !== null
        // Beside the pointer, clear of the dragged widget under it.
        x: rect ? Math.max(0, Math.min(Math.round(root.extDragX + Style.space(28)), parent.width - width)) : 0
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: refusedText.implicitWidth + Style.space(16)
        implicitHeight: root.barSize - Style.space(6)
        color: Color.tooltip.background
        borderSpec: Border.flat(root.urgent, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        z: 101

        Text {
          id: refusedText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.activeDropRefusal
          color: Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }

    PopupWindow {
      id: tooltipWindow

      visible: root.tooltipShown && root.tooltipTarget !== null && root.tooltipText !== ""
        && root.targetBelongsToWindow(root.tooltipTarget, barWindow)
      color: "transparent"
      implicitWidth: Math.ceil(tooltipBubble.implicitWidth)
      implicitHeight: Math.ceil(tooltipBubble.implicitHeight)

      anchor {
        id: tooltipAnchor
        window: barWindow
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          var target = root.tooltipTarget
          if (!root.targetBelongsToWindow(target, barWindow)) return
          var localX = target.width / 2 - tooltipWindow.implicitWidth / 2
          var localY = root.position === "bottom" ? -tooltipWindow.implicitHeight - 6 : target.height + 6
          var point = barWindow.contentItem.mapFromItem(target, localX, localY)
          tooltipAnchor.rect.x = Math.round(point.x)
          tooltipAnchor.rect.y = Math.round(point.y)
        }
      }

      BorderSurface {
        id: tooltipBubble
        implicitWidth: tooltipLabel.implicitWidth + 20
        implicitHeight: tooltipLabel.implicitHeight + 14
        color: Color.tooltip.background
        borderSpec: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, 1)
        radius: Style.cornerRadius

        Text {
          id: tooltipLabel
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: root.tooltipText
          color: Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }

  // The dragged widget following the pointer, plus the insertion mark when
  // it is over the Omarchy bar. Visual only: the empty input region keeps it
  // from stealing the drag's pointer grab.
  component DragGhostWindow: PanelWindow {
    id: ghostWindow

    readonly property string screenName: screen ? String(screen.name || "") : ""
    readonly property bool active: root.dragSlot !== null && root.dragScreen === screenName
    readonly property var sourceItem: root.dragSlot ? root.dragSlot.activeItem : null
    readonly property int ghostPadding: Style.space(1)

    visible: active && sourceItem !== null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-bar-drag-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      bottom: true
      left: true
      right: true
    }

    mask: Region {}

    Item {
      visible: ghostWindow.active && ghostWindow.sourceItem !== null
      x: Math.round(root.dragScreenX - root.dragOffsetX - ghostWindow.ghostPadding)
      y: Math.round(root.dragScreenY - root.dragOffsetY - ghostWindow.ghostPadding)
      width: (ghostWindow.sourceItem ? Math.ceil(ghostWindow.sourceItem.width) : 1) + ghostWindow.ghostPadding * 2
      height: (ghostWindow.sourceItem ? Math.ceil(ghostWindow.sourceItem.height) : 1) + ghostWindow.ghostPadding * 2

      BorderSurface {
        anchors.fill: parent
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        opacity: root.transparent ? 0.45 : 0.94
      }

      Image {
        anchors.fill: parent
        anchors.margins: ghostWindow.ghostPadding
        source: root.dragImageUrl
        fillMode: Image.Stretch
        smooth: true
        opacity: 0.84
      }
    }

    Rectangle {
      readonly property var rect: ghostWindow.active && root.dragTarget && root.dragTarget.kind === "main" ? root.dragTarget.rect : null

      visible: rect !== null
      x: rect ? Math.round(rect.x) : 0
      y: rect ? Math.round(rect.y) : 0
      width: rect ? rect.width : 0
      height: rect ? rect.height : 0
      color: Color.accent
      radius: Math.min(width, height) / 2
    }
  }

  component Section: Row {
    id: section

    required property string region
    required property var ids

    spacing: 0

    Repeater {
      model: section.ids

      ModuleSlot {
        required property var modelData
        moduleName: String(modelData)
        region: section.region
      }
    }
  }

  component ModuleSlot: Item {
    id: slot

    property string moduleName: ""
    property string region: ""

    // Re-read when the registry snapshot changes; Loader ignores an
    // unchanged component, so a refresh never rebuilds the widget.
    readonly property var registryComponent: {
      var widgets = root.barWidgetRegistry ? root.barWidgetRegistry.widgets : null
      var entry = widgets && moduleName ? widgets[moduleName] : null
      if (!entry || !entry.component) return null
      if (entry.metadata && entry.metadata.firstParty === true) return null
      return entry.component
    }
    readonly property var activeItem: loader.item
    readonly property string settingsKey: JSON.stringify(root.settingsById[moduleName] || {})
    readonly property bool dragSource: root.dragSlot === slot
    readonly property bool panelOpen: !!activeItem && root.activePopout === activeItem
    readonly property real panelIndicatorExtent: {
      var hint = activeItem && "openPanelIndicatorWidth" in activeItem ? activeItem.openPanelIndicatorWidth : undefined
      if (hint !== undefined && hint !== null && hint > 0) return Math.round(hint)
      return Math.max(Style.space(10), Math.round(slot.width * 0.55))
    }

    implicitWidth: activeItem && activeItem.visible ? activeItem.implicitWidth : 0
    implicitHeight: activeItem && activeItem.visible ? activeItem.implicitHeight : 0
    width: implicitWidth
    height: implicitHeight
    z: modulePointer.dragging ? 100 : 0

    Component.onCompleted: root.registerSlot(slot)
    Component.onDestruction: {
      if (root.dragSlot === slot) root.clearDrag()
      root.unregisterSlot(slot)
    }

    function injectProps() {
      var target = activeItem
      if (!target) return
      if ("bar" in target) target.bar = root.pluginBarApiFor(moduleName)
      if ("moduleName" in target) target.moduleName = moduleName
      if ("settings" in target) target.settings = root.settingsFor(moduleName)
    }

    onActiveItemChanged: Qt.callLater(injectProps)
    onSettingsKeyChanged: injectProps()

    BorderSurface {
      visible: slot.dragSource
      anchors.fill: parent
      anchors.margins: Style.space(1)
      color: root.transparent ? "transparent" : root.background
      borderSpec: Border.flat(root.barForeground, 1)
      radius: Math.min(Style.cornerRadius, height / 2)
      opacity: root.transparent ? 0.22 : 0.32
    }

    Loader {
      id: loader
      anchors.fill: parent
      active: slot.registryComponent !== null
      sourceComponent: slot.registryComponent
      opacity: slot.dragSource ? 0.22 : 1.0
      onLoaded: {
        slot.injectProps()
        // Twice, as the Omarchy bar does: root bindings can read `bar`
        // before the first assignment lands.
        Qt.callLater(slot.injectProps)
      }
    }

    // Accent mark on the edge facing the desktop while the widget's panel
    // is open, as on the Omarchy bar.
    Rectangle {
      readonly property int inset: Style.space(2)

      visible: opacity > 0
      opacity: slot.panelOpen && !slot.dragSource ? 0.9 : 0
      color: Color.accent
      radius: height / 2
      width: slot.panelIndicatorExtent
      height: Style.space(2)
      x: Math.round((parent.width - width) / 2)
      y: root.position === "top" ? parent.height - height - inset : inset
      z: 50

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
      }
    }

    // Left clicks route to the widget's registered click targets, and a left
    // drag past a few pixels picks the widget up, exactly like the Omarchy
    // bar's module slots. Other buttons and the wheel pass straight through.
    MouseArea {
      id: modulePointer

      property bool dragging: false
      property bool suppressClick: false
      property real pressedX: 0
      property real pressedY: 0
      readonly property real dragThreshold: Style.space(4)

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      enabled: slot.visible && slot.width > 0 && slot.height > 0
      propagateComposedEvents: true
      cursorShape: dragging ? Qt.ClosedHandCursor
        : (root.moduleClickTargetAt(slot, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor)

      onPressed: function(mouse) {
        dragging = false
        suppressClick = false
        pressedX = mouse.x
        pressedY = mouse.y
      }

      onPositionChanged: function(mouse) {
        if (!(mouse.buttons & Qt.LeftButton)) return
        if (!dragging) {
          var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
          if (distance < dragThreshold) return
          dragging = true
          root.beginDrag(slot, pressedX, pressedY)
        }
        var point = root.slotScreenPoint(slot, mouse.x, mouse.y)
        root.updateDrag(point.x, point.y)
      }

      onReleased: function(mouse) {
        if (!dragging) {
          mouse.accepted = false
          return
        }
        dragging = false
        suppressClick = true
        root.finishDrag()
        mouse.accepted = true
      }

      onCanceled: {
        if (dragging) root.clearDrag()
        dragging = false
        suppressClick = false
      }

      onClicked: function(mouse) {
        if (suppressClick) {
          suppressClick = false
          mouse.accepted = true
          return
        }
        var target = root.moduleClickTargetAt(slot, mouse.x, mouse.y)
        if (target) target.triggerPress(mouse.button)
        else mouse.accepted = false
      }
    }
  }
}
