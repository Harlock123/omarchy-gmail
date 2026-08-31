import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "lwatson.gmail"
  ipcTarget: "lwatson.gmail"
  manageIpc: false

  // "messages" while the cursor is on a row, "inbox" on the footer action.
  property string focusSection: "messages"
  property int messageIndex: 0
  property bool cursorActive: false
  // Drives relative timestamps without each row owning a timer.
  property double nowMs: Date.now()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property var messages: gmail.messages || []
  readonly property int messageCount: messages.length
  readonly property bool hideWhenEmpty: String(setting("hideWhenEmpty", false)) === "true"
  readonly property bool problem: gmail.hasLoadedOnce && !gmail.ok

  // Dim the envelope when there is nothing to read; flag it urgent when the
  // helper cannot talk to Gmail at all.
  readonly property color iconColor: problem ? urgent
    : (gmail.unread > 0 ? barForeground : Qt.darker(barForeground, 1.55))

  function ensureCursor() {
    if (messageCount === 0) {
      focusSection = "inbox"
      messageIndex = 0
      return
    }
    if (focusSection !== "messages" && focusSection !== "inbox") focusSection = "messages"
    if (messageIndex >= messageCount) messageIndex = messageCount - 1
    if (messageIndex < 0) messageIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return

    if (focusSection === "inbox") {
      if (dy < 0 && messageCount > 0) {
        focusSection = "messages"
        messageIndex = messageCount - 1
        scrollCursorIntoView()
      }
      return
    }

    if (dy > 0 && messageIndex === messageCount - 1) {
      focusSection = "inbox"
      return
    }
    messageIndex = Math.max(0, Math.min(messageCount - 1, messageIndex + dy))
    scrollCursorIntoView()
  }

  function selectedMessage() {
    if (messageCount === 0) return null
    return messages[Math.max(0, Math.min(messageIndex, messageCount - 1))]
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "inbox") {
      gmail.openInbox()
      root.close()
      return
    }
    openMessage(selectedMessage())
  }

  function openMessage(message) {
    if (!message) return
    gmail.openMessage(message)
    // Closing matches every other bar popup: the browser is taking focus.
    root.close()
  }

  function setMessageCursor(index) {
    cursorActive = true
    focusSection = "messages"
    messageIndex = index
    scrollCursorIntoView()
  }

  function setInboxCursor() {
    cursorActive = true
    focusSection = "inbox"
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "messages" && messageColumn
        && messageIndex >= 0 && messageIndex < messageColumn.children.length) {
      scrollItemIntoView(messageColumn.children[messageIndex])
    }
  }

  visible: !hideWhenEmpty || gmail.unread > 0 || problem
  implicitWidth: visible ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    gmail.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onMessageIndexChanged: scrollCursorIntoView()

  Service {
    id: gmail
    settings: root.settings
  }

  Connections {
    target: gmail
    function onMessagesChanged() { root.ensureCursor() }
  }

  Timer {
    // Keeps "12m" style labels honest while the dropdown sits open.
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { gmail.refresh(); return "ok" }
    function unread(): string { return String(gmail.unread) }
    function status(): string { return Model.summaryTooltip(gmail) }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: Style.bar.iconSlot + Style.space(7)
    opticalSize: Style.bar.iconCanvas + Style.space(4)
    tooltipText: Model.summaryTooltip(gmail)

    iconComponent: Component {
      Item {
        GmailIcon {
          anchors.centerIn: parent
          iconSize: Style.space(12)
          color: root.iconColor
          fontFamily: root.fontFamily
          badgeCount: root.problem ? 0 : gmail.unread
          badgeColor: root.accent
          badgeTextColor: Color.background
          opacity: gmail.loading && !gmail.hasLoadedOnce ? 0.5 : 1.0
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) gmail.refresh()
      else if (buttonCode === Qt.MiddleButton) gmail.openInbox()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    // The footer sits outside the scroll area, so its height has to be added
    // back in when asking for the panel's natural height.
    contentHeight: panel.fittedContentHeight(
      column.implicitHeight + footerSep.implicitHeight
        + footerRow.implicitHeight + Style.space(30),
      Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") gmail.refresh()
        else if (t === "g" || t === "G") { gmail.openInbox(); root.close() }
      }

      Item {
        anchors.fill: parent

        Flickable {
          id: panelFlick
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footerSep.top
          anchors.bottomMargin: Style.space(12)
          contentWidth: width
          contentHeight: column.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: column
            width: panelFlick.width
            spacing: Style.space(12)

            PanelHero {
              id: hero
              width: parent.width
              title: "Gmail"
              meta: gmail.account !== "" ? gmail.account : "Not configured"
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                GmailIcon {
                  iconSize: Style.font.display
                  color: root.foreground
                  fontFamily: root.fontFamily
                  badgeCount: 0
                }
              }
            }

            Text {
              visible: root.problem
              width: parent.width
              text: gmail.needsSetup
                ? "Run omarchy-gmail-setup in a terminal to connect your account."
                : gmail.error
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(10)

              PanelSectionHeader {
                text: gmail.unread > 0 ? "UNREAD · " + gmail.unread : "UNREAD"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                visible: root.messageCount === 0
                width: parent.width
                text: Model.emptyStateText(gmail)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
              }

              Column {
                id: messageColumn
                visible: root.messageCount > 0
                width: parent.width
                spacing: Style.space(6)

                Repeater {
                  model: root.messages
                  MessageRow {
                    required property var modelData
                    required property int index
                    width: messageColumn.width
                    message: modelData
                    rowIndex: index
                  }
                }
              }

              Text {
                // The badge counts the whole unread mailbox; the list is capped.
                visible: gmail.unread > root.messageCount && root.messageCount > 0
                width: parent.width
                text: "+ " + (gmail.unread - root.messageCount) + " more unread"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
              }
            }
          }
        }

        // Pinned so "Open Gmail" stays reachable no matter how long the list
        // is. Anchored rather than laid out: CursorSurface reports its height
        // through implicitHeight, which a ColumnLayout collapses to zero here.
        PanelSeparator {
          id: footerSep
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: footerRow.top
          anchors.bottomMargin: Style.space(12)
          foreground: root.foreground
        }

        InboxRow {
          id: footerRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: implicitHeight
        }

      }
    }
  }

  component MessageRow: CursorSurface {
    id: messageRow
    property var message: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.focusSection === "messages" && root.messageIndex === rowIndex
    foreground: root.foreground
    accent: root.accent

    implicitHeight: rowContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setMessageCursor(messageRow.rowIndex)
      onClicked: root.openMessage(messageRow.message)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      // Unread dot, doubling as the row's visual anchor.
      Rectangle {
        width: Style.space(6)
        height: width
        radius: width / 2
        color: root.accent
        Layout.alignment: Qt.AlignTop
        Layout.topMargin: Style.space(5)
      }

      ColumnLayout {
        id: rowContent
        Layout.fillWidth: true
        spacing: Style.space(2)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Text {
            Layout.fillWidth: true
            text: Model.senderLabel(messageRow.message)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            text: Model.timeAgo(messageRow.message ? messageRow.message.timestamp : 0, root.nowMs)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          Layout.fillWidth: true
          text: messageRow.message ? String(messageRow.message.subject || "") : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: messageRow.message ? String(messageRow.message.snippet || "") : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }
    }
  }

  component InboxRow: CursorSurface {
    id: inboxRow

    hasCursor: root.cursorActive && root.focusSection === "inbox"
    foreground: root.foreground
    accent: root.accent

    // Sized off a Text rather than a RowLayout: a Layout positioned with
    // left/right anchors does not report a usable implicitHeight, which
    // collapsed this row to zero height.
    implicitHeight: inboxLabel.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setInboxCursor()
      onClicked: { gmail.openInbox(); root.close() }
    }

    Text {
      id: inboxLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.right: inboxArrow.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Open Gmail"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: inboxArrow
      anchors.right: parent.right
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      text: gmail.loading ? "refreshing…" : "↗"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
