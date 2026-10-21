import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "keyboard-backlight"

  property int level: 0
  property int maximum: 2
  property string deviceName: ""
  property string lastSchedulePeriod: ""
  property bool sessionBlocked: true
  property string pendingMode: ""
  readonly property string levelIcon: level <= 0 ? "󰹐" : (level >= maximum ? "󰛨" : "󰌶")
  readonly property bool scheduleEnabled: setting("scheduleEnabled", false) === true
  readonly property int nightStartHour: Number(setting("nightStartHour", 20))
  readonly property int dayStartHour: Number(setting("dayStartHour", 7))
  readonly property string helper: Qt.resolvedUrl("bin/keyboard-backlight").toString().replace(/^file:\/\//, "")
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function setMode(mode) {
    pendingMode = sessionBlocked ? "off" : mode
    flushMode()
  }

  function flushMode() {
    if (actionProc.running || pendingMode === "") return
    actionProc.command = [root.helper, "set", sessionBlocked ? "off" : pendingMode]
    pendingMode = ""
    actionProc.running = true
  }

  function updateSession(blocked) {
    var wasBlocked = sessionBlocked
    sessionBlocked = blocked
    if (blocked) {
      lastSchedulePeriod = ""
      if (!wasBlocked || level > 0 || pendingMode !== "") setMode("off")
    } else if (wasBlocked) {
      applySchedule(true)
    }
  }

  function cycle() {
    if (level <= 0) setMode("low")
    else if (level >= maximum) setMode("off")
    else setMode("high")
  }

  function schedulePeriod() {
    var hour = new Date().getHours()
    var night = nightStartHour
    var day = dayStartHour
    if (night === day) return "night"
    if (night > day) return (hour >= night || hour < day) ? "night" : "day"
    return (hour >= night && hour < day) ? "night" : "day"
  }

  function applySchedule(force) {
    if (sessionBlocked) {
      lastSchedulePeriod = ""
      return
    }
    if (!scheduleEnabled) {
      lastSchedulePeriod = ""
      return
    }
    var period = schedulePeriod()
    if (!force && period === lastSchedulePeriod) return
    lastSchedulePeriod = period
    setMode(period === "night" ? "low" : "off")
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setScheduleEnabled(value) {
    persistSettings({ scheduleEnabled: value })
    lastSchedulePeriod = ""
    if (value) Qt.callLater(function() { root.applySchedule(true) })
  }

  function setScheduleHour(key, value) {
    var normalized = ((Number(value) % 24) + 24) % 24
    var update = {}
    update[key] = normalized
    persistSettings(update)
    lastSchedulePeriod = ""
    if (scheduleEnabled) Qt.callLater(function() { root.applySchedule(true) })
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.anchorItem = button
    target.hostWidget = root
  }

  // Keep polling and scheduling alive while the icon is hidden.
  visible: level > 0
  implicitWidth: level > 0 ? button.implicitWidth : 0
  implicitHeight: level > 0 ? button.implicitHeight : 0
  onBarChanged: injectPanel()
  onScheduleEnabledChanged: if (!scheduleEnabled) lastSchedulePeriod = ""
  Component.onCompleted: {
    refresh()
    scheduleDelay.start()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  Timer { interval: 1000; running: true; repeat: true; onTriggered: root.refresh() }
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.applySchedule(false) }
  Timer { id: scheduleDelay; interval: 1000; repeat: false; onTriggered: root.applySchedule(true) }

  Process {
    id: statusProc
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var values = text.trim().split(/\s+/)
        if (values.length === 4 && (values[3] === "true" || values[3] === "false")) {
          root.level = Number(values[0]) || 0
          root.maximum = Number(values[1]) || 2
          root.deviceName = values[2]
          root.updateSession(values[3] === "true")
        } else root.updateSession(true)
      }
    }
    onExited: function(exitCode, exitStatus) {
      if (exitCode !== 0 || exitStatus !== 0) root.updateSession(true)
    }
  }

  Process {
    id: actionProc
    onExited: {
      root.flushMode()
      refreshDelay.start()
    }
  }
  Timer { id: refreshDelay; interval: 150; repeat: false; onTriggered: root.refresh() }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.levelIcon
    useActiveColor: false
    tooltipText: ""
    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycle()
      else root.toggle()
    }
  }
}
