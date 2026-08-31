import QtQuick
import QtQuick.Shapes
import qs.Commons

// Envelope drawn as vector art rather than a font glyph, so the widget does
// not depend on the user's font shipping a mail codepoint. The unread badge
// rides the top-right corner and is allowed to overhang the envelope.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property int badgeCount: 0
  property color badgeColor: Color.accent
  property color badgeTextColor: Color.background
  property string fontFamily: Style.font.family

  readonly property real envelopeWidth: iconSize * 1.3
  readonly property real envelopeHeight: iconSize * 0.95
  readonly property bool badgeVisible: badgeCount > 0
  readonly property string badgeText: badgeCount > 99 ? "99+" : String(badgeCount)

  implicitWidth: envelopeWidth
  implicitHeight: envelopeHeight

  Shape {
    id: envelope
    anchors.centerIn: parent
    width: root.envelopeWidth
    height: root.envelopeHeight
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    // Body outline.
    ShapePath {
      strokeColor: root.color
      strokeWidth: Math.max(1, root.iconSize * 0.095)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap

      startX: envelope.width * 0.04
      startY: envelope.height * 0.12
      PathLine { x: envelope.width * 0.96; y: envelope.height * 0.12 }
      PathLine { x: envelope.width * 0.96; y: envelope.height * 0.88 }
      PathLine { x: envelope.width * 0.04; y: envelope.height * 0.88 }
      PathLine { x: envelope.width * 0.04; y: envelope.height * 0.12 }
    }

    // Flap.
    ShapePath {
      strokeColor: root.color
      strokeWidth: Math.max(1, root.iconSize * 0.095)
      fillColor: "transparent"
      joinStyle: ShapePath.RoundJoin
      capStyle: ShapePath.RoundCap

      startX: envelope.width * 0.04
      startY: envelope.height * 0.12
      PathLine { x: envelope.width * 0.5; y: envelope.height * 0.58 }
      PathLine { x: envelope.width * 0.96; y: envelope.height * 0.12 }
    }
  }

  Rectangle {
    id: badge
    visible: root.badgeVisible
    color: root.badgeColor
    radius: height / 2

    readonly property real pillHeight: Math.max(9, Math.round(root.iconSize * 0.72))
    height: pillHeight
    width: Math.max(pillHeight, badgeLabel.implicitWidth + pillHeight * 0.55)

    anchors.right: envelope.right
    anchors.top: envelope.top
    anchors.rightMargin: -width * 0.42
    anchors.topMargin: -pillHeight * 0.38

    Text {
      id: badgeLabel
      anchors.centerIn: parent
      text: root.badgeText
      color: root.badgeTextColor
      font.family: root.fontFamily
      font.pixelSize: Math.max(7, Math.round(badge.pillHeight * 0.72))
      font.bold: true
      renderType: Text.NativeRendering
    }
  }
}
