import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One line of the panel list: optional checkbox, icon, title + detail,
// a status badge, the size and an expand chevron. Keyboard and mouse share
// one highlight through CursorSurface's hasCursor.
CursorSurface {
  id: row

  property string checkGlyph: ""
  property string iconGlyph: ""
  property string title: ""
  property string detail: ""
  property string badge: ""
  property bool badgeUrgent: false
  property string size: ""
  property string chevron: ""
  property int indent: 0
  property bool muted: false
  property real fraction: -1
  property color textColor: Color.foreground
  property color urgentColor: Color.urgent
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(textColor, 1.55)

  signal clicked()
  signal checkClicked()
  signal chevronClicked()
  signal hovered()

  foreground: textColor
  implicitHeight: Math.max(Style.spacing.popupRowHeight, texts.implicitHeight + Style.space(10))

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: row.hovered()
    onClicked: row.clicked()
  }

  RowLayout {
    anchors.fill: parent
    anchors.leftMargin: Style.space(8) + row.indent * Style.space(20)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

    Text {
      visible: row.checkGlyph !== ""
      textFormat: Text.PlainText
      text: row.checkGlyph
      color: row.muted ? row.dim : row.textColor
      font.family: row.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignVCenter

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        cursorShape: Qt.PointingHandCursor
        onClicked: row.checkClicked()
      }
    }

    Text {
      visible: row.iconGlyph !== ""
      textFormat: Text.PlainText
      text: row.iconGlyph
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.icon
      Layout.alignment: Qt.AlignVCenter
    }

    ColumnLayout {
      id: texts
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: 0

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: row.title
        color: row.muted ? row.dim : row.textColor
        font.family: row.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideMiddle
      }

      Text {
        Layout.fillWidth: true
        visible: row.detail !== ""
        textFormat: Text.PlainText
        text: row.detail
        color: row.dim
        font.family: row.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Text {
      visible: row.badge !== ""
      textFormat: Text.PlainText
      text: row.badge
      color: row.badgeUrgent ? row.urgentColor : row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.caption
      Layout.alignment: Qt.AlignVCenter
    }

    Text {
      visible: row.size !== ""
      textFormat: Text.PlainText
      text: row.size
      color: row.muted ? row.dim : row.textColor
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      Layout.minimumWidth: Style.space(62)
      Layout.alignment: Qt.AlignVCenter
    }

    Text {
      textFormat: Text.PlainText
      text: row.chevron
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.iconSmall
      Layout.preferredWidth: Style.space(14)
      Layout.alignment: Qt.AlignVCenter

      MouseArea {
        anchors.fill: parent
        anchors.margins: -Style.space(4)
        enabled: row.chevron !== ""
        cursorShape: Qt.PointingHandCursor
        onClicked: row.chevronClicked()
      }
    }
  }

  // Share of the parent folder, Explore only.
  Rectangle {
    visible: row.fraction >= 0
    anchors.left: parent.left
    anchors.bottom: parent.bottom
    anchors.leftMargin: Style.space(8) + row.indent * Style.space(20)
    height: Math.max(1, Style.space(2))
    width: Math.max(0, (parent.width - anchors.leftMargin - Style.space(6)) * Math.min(1, row.fraction))
    color: Qt.rgba(row.textColor.r, row.textColor.g, row.textColor.b, 0.28)
  }
}
