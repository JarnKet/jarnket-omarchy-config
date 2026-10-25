import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Appears while plugin updates are waiting, like Omarchy's own update icon.
// ~/.local/bin/plugin-updates (run every 6 h by plugin-updates.timer) writes
// the status file; watching it costs nothing between checks.
BarWidget {
  id: root
  moduleName: "shadowone.plugin-updates"

  readonly property string home: Quickshell.env("HOME")
  property var pending: []

  function parse(text) {
    var ids = []
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 2 && (fields[1] === "behind" || fields[1] === "diverged"))
        ids.push(fields[0])
    }
    pending = ids
  }

  function review() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
                             root.home + "/.local/bin/plugin-updates review"])
  }

  visible: pending.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: root.home + "/.local/state/plugin-updates/status.tsv"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.parse(text())
    onLoadFailed: root.pending = []
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰐱"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: (root.pending.length === 1 ? "1 plugin update" : root.pending.length + " plugin updates")
      + " waiting - click to review"
    onPressed: root.review()
  }
}
