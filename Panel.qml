import QtQuick
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "keyboard-backlight"
  manageIpc: false
  property var anchorItem: null
  property var hostWidget: null
  property int selectedIndex: 0
  property bool cursorActive: false
  readonly property var modes: [
    { label: "Off", icon: "󰹐", mode: "off", value: 0 },
    { label: "Low", icon: "󰌶", mode: "low", value: 1 },
    { label: "High", icon: "󰛨", mode: "high", value: hostWidget ? hostWidget.maximum : 2 }
  ]
  readonly property int currentLevel: hostWidget ? hostWidget.level : 0
  readonly property string currentLabel: currentLevel <= 0 ? "Off" : (hostWidget && currentLevel >= hostWidget.maximum ? "High" : "Low")

  function select(delta) { selectedIndex = (selectedIndex + delta + modes.length) % modes.length }
  function activate(index) {
    selectedIndex = index
    if (hostWidget) hostWidget.setMode(modes[index].mode)
  }
  function changeNightHour(delta) {
    if (hostWidget) hostWidget.setScheduleHour("nightStartHour", hostWidget.nightStartHour + delta)
  }
  function changeDayHour(delta) {
    if (hostWidget) hostWidget.setScheduleHour("dayStartHour", hostWidget.dayStartHour + delta)
  }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(hostWidget || root, direction)
    return false
  }
  onOpenedChanged: {
    if (opened) {
      if (hostWidget) hostWidget.refresh()
      selectedIndex = currentLevel <= 0 ? 0 : (hostWidget && currentLevel >= hostWidget.maximum ? 2 : 1)
      cursorActive = false
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.cursorActive = true; root.select(dx !== 0 ? dx : dy) }
      onActivateRequested: root.activate(root.selectedIndex)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        Row {
          width: parent.width
          spacing: Style.space(12)
          Text {
            text: root.currentLevel <= 0 ? "󰹐" : (root.hostWidget && root.currentLevel >= root.hostWidget.maximum ? "󰛨" : "󰌶")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
          }
          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)
            Text {
              text: "Keyboard backlight"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Text {
              text: "Current mode: " + root.currentLabel
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }
        PanelSectionHeader { text: "BRIGHTNESS"; foreground: root.bar.foreground; fontFamily: root.bar.fontFamily }

        Row {
          id: modeRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * 2) / 3
          Repeater {
            model: root.modes
            Button {
              required property var modelData
              required property int index
              width: modeRow.cellWidth
              iconText: modelData.icon
              iconSize: Style.font.title
              text: modelData.label
              fontSize: Style.font.bodySmall
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
              bordered: true
              active: root.currentLevel === modelData.value
              hasCursor: root.cursorActive && root.selectedIndex === index
              onClicked: root.activate(index)
              onHovered: function(h) {
                if (h) { root.cursorActive = true; root.selectedIndex = index }
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Button {
          width: parent.width
          iconText: "󰥔"
          text: hostWidget && hostWidget.scheduleEnabled ? "Automatic schedule enabled" : "Automatic schedule disabled"
          fontSize: Style.font.bodySmall
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          active: hostWidget && hostWidget.scheduleEnabled
          onClicked: if (hostWidget) hostWidget.setScheduleEnabled(!hostWidget.scheduleEnabled)
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          ScheduleTimeRow {
            label: "Low light starts"
            hour: hostWidget ? hostWidget.nightStartHour : 20
            onDecreaseRequested: root.changeNightHour(-1)
            onIncreaseRequested: root.changeNightHour(1)
          }

          ScheduleTimeRow {
            label: "Light turns off"
            hour: hostWidget ? hostWidget.dayStartHour : 7
            onDecreaseRequested: root.changeDayHour(-1)
            onIncreaseRequested: root.changeDayHour(1)
          }
        }
      }
    }
  }

  component ScheduleTimeRow: Row {
    id: scheduleRow
    property string label: ""
    property int hour: 0
    signal decreaseRequested()
    signal increaseRequested()

    width: parent.width
    spacing: Style.space(6)

    Text {
      width: Math.max(0, parent.width - decreaseButton.width - timeLabel.width - increaseButton.width - parent.spacing * 3)
      anchors.verticalCenter: parent.verticalCenter
      text: scheduleRow.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Button {
      id: decreaseButton
      width: Style.space(42)
      text: "−"
      fontSize: Style.font.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: scheduleRow.decreaseRequested()
    }

    Text {
      id: timeLabel
      width: Style.space(58)
      anchors.verticalCenter: parent.verticalCenter
      text: String(scheduleRow.hour).padStart(2, "0") + ":00"
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      horizontalAlignment: Text.AlignHCenter
    }

    Button {
      id: increaseButton
      width: Style.space(42)
      text: "+"
      fontSize: Style.font.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      bordered: true
      onClicked: scheduleRow.increaseRequested()
    }
  }
}
