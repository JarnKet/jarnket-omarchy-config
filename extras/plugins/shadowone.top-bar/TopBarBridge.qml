import QtQuick
import Quickshell

// Top Bar bridge: an invisible, zero-width widget on the Omarchy bar.
//
// It is how the two bars talk. The Omarchy bar has no drag API, but every
// module slot exposes `dragSource`, `moduleName` and `region`, and its
// pointer MouseArea keeps tracking the cursor for the whole drag (the same
// contract Bar Folder relies on). The bridge watches those slots, reports
// drags to the Top Bar service so a widget can be dropped on the top bar, and
// answers where a widget dragged down from the top bar would land here.
//
// Its shell.json entry also holds the Top Bar layout, and sitting on the bar
// is what enables the plugin (and so the Top Bar service).
Item {
  id: bridge

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})

  readonly property string serviceId: "shadowone.top-bar"
  property var service: null
  property var slots: []
  property var watchedSlots: []
  property var dragSlot: null
  property string dragId: ""

  visible: false
  implicitWidth: 0
  implicitHeight: 0

  // ------------------------------------------------------------ service link

  function resolveService() {
    var next = null
    try {
      next = bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor(serviceId) : null
    } catch (e) {
      next = null
    }
    if (next === service) return
    if (service && typeof service.unregisterBridge === "function") {
      try { service.unregisterBridge(bridge) } catch (e) { }
    }
    service = next
    if (service && typeof service.registerBridge === "function") service.registerBridge(bridge)
  }

  Component.onDestruction: {
    if (dragSlot && service) {
      try { service.externalDragEnded(dragId, "", -1, -1) } catch (e) { }
    }
    if (service && typeof service.unregisterBridge === "function") {
      try { service.unregisterBridge(bridge) } catch (e) { }
    }
  }

  // The service can load after the bar, and is rebuilt when plugins reload.
  Timer {
    interval: 1500
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      bridge.resolveService()
      bridge.scanSlots()
    }
  }

  Connections {
    target: bridge.bar
    ignoreUnknownSignals: true
    function onLayoutConfigChanged() { rescanTimer.restart() }
  }

  // Slots rebuild after a layout change lands; look again once they have.
  Timer {
    id: rescanTimer
    interval: 300
    onTriggered: bridge.scanSlots()
  }

  // ------------------------------------------------------------------ slots

  function isModuleSlot(item) {
    return !!item && ("dragSource" in item) && ("moduleName" in item) && ("region" in item) && ("activeItem" in item)
  }

  function ownSlot() {
    for (var node = bridge.parent; node; node = node.parent)
      if (isModuleSlot(node)) return node
    return null
  }

  function scanSlots() {
    var own = ownSlot()
    if (!own) return
    var top = own
    while (top.parent) top = top.parent
    var found = []
    var queue = [top]
    for (var guard = 0; queue.length > 0 && guard < 6000; guard++) {
      var node = queue.shift()
      if (!node) continue
      if (isModuleSlot(node)) {
        found.push(node)
        continue
      }
      var kids = node.children
      if (kids) for (var i = 0; i < kids.length; i++) queue.push(kids[i])
    }
    slots = found
    for (var j = 0; j < found.length; j++) watchSlot(found[j])
  }

  function watchSlot(slot) {
    if (watchedSlots.indexOf(slot) !== -1) return
    watchedSlots = watchedSlots.filter(function(item) { return !!item && !!item.parent }).concat([slot])
    // The bar clears `dragSource` right before applying its own drop, which
    // may rebuild the slots, so the release is handled synchronously here.
    slot.dragSourceChanged.connect(function() {
      try {
        if (slot.dragSource === true) bridge.dragStarted(slot)
        else if (bridge.dragSlot === slot) bridge.dragFinished()
      } catch (e) {
      }
    })
  }

  function slotPointer(slot) {
    var kids = slot ? slot.children : null
    if (!kids) return null
    for (var i = 0; i < kids.length; i++)
      if (kids[i] && ("dragging" in kids[i]) && ("pressedX" in kids[i])) return kids[i]
    return null
  }

  function barWindow() {
    return bridge.QsWindow ? bridge.QsWindow.window : null
  }

  function screenName() {
    var window = barWindow()
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  function barPosition() {
    return bar ? String(bar.position || "top") : "top"
  }

  // Scene point in the bar window -> point in the screen's logical space.
  function toScreen(point) {
    var window = barWindow()
    var x = point.x
    var y = point.y
    if (window && window.screen) {
      if (barPosition() === "bottom") y += Math.max(0, window.screen.height - window.height)
      else if (barPosition() === "right") x += Math.max(0, window.screen.width - window.width)
    }
    return { x: x, y: y }
  }

  function pointerPoint(slot) {
    var pointer = slotPointer(slot)
    if (!pointer) return null
    return toScreen(pointer.mapToItem(null, pointer.mouseX, pointer.mouseY))
  }

  // --------------------------------------------- drags starting on this bar

  function dragStarted(slot) {
    if (slot === ownSlot() || slot.customType) return
    var id = String(slot.moduleName || "")
    if (!id || !service) return
    dragSlot = slot
    dragId = id
    var point = pointerPoint(slot)
    if (point) service.externalDragStarted(id, screenName(), point.x, point.y)
    sampler.start()
  }

  function dragFinished() {
    sampler.stop()
    var point = null
    try { point = pointerPoint(dragSlot) } catch (e) { }
    var id = dragId
    dragSlot = null
    dragId = ""
    if (service) service.externalDragEnded(id, screenName(), point ? point.x : -1, point ? point.y : -1)
  }

  Timer {
    id: sampler
    interval: 16
    repeat: true
    onTriggered: {
      if (!bridge.dragSlot || !bridge.service) {
        stop()
        return
      }
      var point = null
      try { point = bridge.pointerPoint(bridge.dragSlot) } catch (e) { }
      if (point) bridge.service.externalDragMoved(bridge.dragId, bridge.screenName(), point.x, point.y)
    }
  }

  // ------------------------------------------ drops arriving from the top bar

  // Where a widget released at screen point (x, y) would land on this bar:
  // the nearest slot edge, the way the Omarchy bar picks its own drop target.
  // Returns { region, name, after, rect } (rect in screen space) or null when
  // the point is not on this bar.
  function dropTargetAt(x, y, excludeId) {
    var window = barWindow()
    if (!window || !window.screen) return null
    var vertical = barPosition() === "left" || barPosition() === "right"
    var origin = toScreen({ x: 0, y: 0 })
    var tolerance = 12
    if (x < origin.x - tolerance || x > origin.x + window.width + tolerance
        || y < origin.y - tolerance || y > origin.y + window.height + tolerance) return null

    var own = ownSlot()
    var best = null
    var bestDistance = Infinity
    for (var i = 0; i < slots.length; i++) {
      var slot = slots[i]
      if (!slot || slot === own || !slot.visible || slot.width <= 0 || slot.height <= 0 || !slot.parent) continue
      if (String(slot.moduleName || "") === excludeId || slot.customType) continue
      var p = null
      try { p = toScreen(slot.mapToItem(null, 0, 0)) } catch (e) { continue }
      var axis = vertical ? y : x
      var start = vertical ? p.y : p.x
      var size = vertical ? slot.height : slot.width
      var before = Math.abs(axis - start)
      var afterDistance = Math.abs(axis - (start + size))
      var after = afterDistance < before
      var distance = after ? afterDistance : before
      if (distance >= bestDistance) continue
      bestDistance = distance
      var thickness = 3
      best = {
        region: String(slot.region || ""),
        name: String(slot.moduleName || ""),
        after: after,
        rect: vertical
          ? { x: p.x, y: p.y + (after ? slot.height : 0) - thickness / 2, width: slot.width, height: thickness }
          : { x: p.x + (after ? slot.width : 0) - thickness / 2, y: p.y, width: thickness, height: slot.height }
      }
    }
    return best
  }
}
