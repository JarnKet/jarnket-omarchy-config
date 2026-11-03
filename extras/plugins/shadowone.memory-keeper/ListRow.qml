import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui

// One line of the panel list: icon, title + detail, size, then its actions as
// small text buttons. Keyboard and mouse share one highlight through
// CursorSurface's hasCursor.
CursorSurface {
  id: row

  property string iconGlyph: ""
  property string title: ""
  property string detail: ""
  property string size: ""
  property string chevron: ""
  property bool muted: false
  property var actions: []
  property color textColor: Color.foreground
  property string fontFamily: Style.font.family

  readonly property color dim: Qt.darker(textColor, 1.55)

  signal clicked()
  signal hovered()
  signal actionClicked(string id)

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
    anchors.leftMargin: Style.space(8)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

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
      visible: row.size !== ""
      textFormat: Text.PlainText
      text: row.size
      color: row.muted ? row.dim : row.textColor
      font.family: row.fontFamily
      font.pixelSize: Style.font.bodySmall
      horizontalAlignment: Text.AlignRight
      Layout.minimumWidth: Style.space(56)
      Layout.alignment: Qt.AlignVCenter
    }

    Repeater {
      model: row.actions

      Rectangle {
        required property var modelData
        visible: !modelData.hidden
        implicitWidth: actionLabel.implicitWidth + Style.space(12)
        implicitHeight: actionLabel.implicitHeight + Style.space(4)
        Layout.alignment: Qt.AlignVCenter
        color: actionMouse.containsMouse ? Qt.rgba(row.textColor.r, row.textColor.g, row.textColor.b, 0.16) : "transparent"
        border.width: Math.max(1, Style.space(1))
        border.color: Qt.rgba(row.textColor.r, row.textColor.g, row.textColor.b, 0.28)

        Text {
          id: actionLabel
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: parent.modelData.label
          color: row.textColor
          font.family: row.fontFamily
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: actionMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: row.hovered()
          onClicked: row.actionClicked(parent.modelData.id)
        }
      }
    }

    Text {
      visible: row.chevron !== ""
      textFormat: Text.PlainText
      text: row.chevron
      color: row.dim
      font.family: row.fontFamily
      font.pixelSize: Style.font.iconSmall
      Layout.alignment: Qt.AlignVCenter
    }
  }
}
