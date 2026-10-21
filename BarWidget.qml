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
  property bool refreshPending: false
  property bool eventsFailed: false
  property bool actionFailed: false
  readonly property string levelIcon: level <= 0 ? "󰹐" : (level >= maximum ? "󰛨" : "󰌶")
  readonly property bool scheduleEnabled: setting("scheduleEnabled", false) === true
  readonly property int nightStartHour: Number(setting("nightStartHour", 20))
  readonly property int dayStartHour: Number(setting("dayStartHour", 7))
  readonly property string helper: Qt.resolvedUrl("bin/keyboard-backlight").toString().replace(/^file:\/\//, "")
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function refresh() {
    if (statusProc.running) refreshPending = true
    else {
      refreshPending = false
      statusProc.running = true
    }
  }

  function setMode(mode, manual) {
    if (manual) actionFailed = false
    if (actionFailed) return
    pendingMode = sessionBlocked || eventsFailed ? "off" : mode
    flushMode()
  }

  function flushMode() {
    if (actionFailed) { pendingMode = ""; return }
    if (actionProc.running || pendingMode === "") return
    actionProc.command = [root.helper, "set", sessionBlocked || eventsFailed ? "off" : pendingMode]
    pendingMode = ""
    actionProc.running = true
  }

  function updateSession(blocked) {
    blocked = blocked || eventsFailed
    var wasBlocked = sessionBlocked
    sessionBlocked = blocked
    if (blocked) {
      lastSchedulePeriod = ""
      if (!wasBlocked || level > 0 || pendingMode !== "") setMode("off")
    } else {
      // An event at the deadline must apply an overdue transition before
      // stopping the old timer and arming tomorrow's deadline.
      applySchedule(wasBlocked)
    }
    armSchedule()
  }

  function cycle() {
    if (level <= 0) setMode("low", true)
    else if (level >= maximum) setMode("off", true)
    else setMode("high", true)
  }

  function failEvents() {
    if (eventsFailed) return
    eventsFailed = true
    sessionBlocked = true
    refreshPending = false
    lastSchedulePeriod = ""
    scheduleTimer.stop()
    pendingMode = ""
    setMode("off")
    console.warn("Keyboard backlight event subscription stopped; automatic lighting disabled until reload")
  }

  function finishAction(exitCode, exitStatus) {
    if (exitCode !== 0 || exitStatus !== 0) {
      actionFailed = true
      pendingMode = ""
      refreshDelay.stop()
      scheduleTimer.stop()
      console.warn("Keyboard backlight write failed; automatic writes disabled until manual retry or reload")
      return
    }
    flushMode()
    refreshDelay.start()
  }

  function clockChanged() {
    Date.timeZoneUpdated()
    if (eventsFailed) return
    applySchedule(false)
    armSchedule()
  }

  function handleEvent(line) {
    if (eventsFailed) return
    if (line === "clock") clockChanged()
    else if (line === "change") refresh()
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
    if (sessionBlocked || eventsFailed) {
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

  function nextScheduleDelay(now) {
    // Equal hours mean permanent night mode, so there is no next transition.
    if (!scheduleEnabled || nightStartHour === dayStartHour) return 0
    var next = Infinity
    var hours = [nightStartHour, dayStartHour]
    for (var i = 0; i < hours.length; i++) {
      var boundary = new Date(now.getTime())
      boundary.setHours(hours[i], 0, 0, 0)
      if (boundary.getTime() <= now.getTime()) {
        boundary = new Date(now.getTime())
        boundary.setDate(boundary.getDate() + 1)
        boundary.setHours(hours[i], 0, 0, 0)
      }
      next = Math.min(next, boundary.getTime() - now.getTime())
    }
    return next
  }

  function armSchedule() {
    scheduleTimer.stop()
    if (sessionBlocked || eventsFailed || actionFailed) return
    var delay = nextScheduleDelay(new Date())
    if (delay <= 0) return
    scheduleTimer.interval = delay
    scheduleTimer.start()
  }

  function scheduleChanged() {
    lastSchedulePeriod = ""
    applySchedule(true)
    armSchedule()
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
  }

  function setScheduleHour(key, value) {
    var normalized = ((Number(value) % 24) + 24) % 24
    var update = {}
    update[key] = normalized
    persistSettings(update)
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

  // Keep event subscriptions and scheduling alive while the icon is hidden.
  visible: level > 0
  implicitWidth: level > 0 ? button.implicitWidth : 0
  implicitHeight: level > 0 ? button.implicitHeight : 0
  onBarChanged: injectPanel()
  onScheduleEnabledChanged: Qt.callLater(root.scheduleChanged)
  onNightStartHourChanged: Qt.callLater(root.scheduleChanged)
  onDayStartHourChanged: Qt.callLater(root.scheduleChanged)
  Component.onCompleted: Qt.callLater(root.scheduleChanged)

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  Timer {
    id: scheduleTimer
    repeat: false
    onTriggered: {
      root.applySchedule(false)
      root.armSchedule()
    }
  }

  Process {
    id: eventProc
    command: [Qt.resolvedUrl("bin/watch-session").toString().replace(/^file:\/\//, "")]
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.handleEvent(line) }
    }
    onExited: root.failEvents()
  }

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
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: actionProc
    onExited: function(exitCode, exitStatus) { root.finishAction(exitCode, exitStatus) }
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
