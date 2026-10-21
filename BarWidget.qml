import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Schedule.js" as Schedule

BarWidget {
  id: root
  moduleName: "keyboard-backlight"

  property int level: 0
  property int maximum: 2
  property string deviceName: ""
  property string lastSchedulePeriod: ""
  property bool sessionBlocked: true
  property var pendingAction: null
  property bool refreshPending: false
  property bool eventsFailed: false
  property bool actionFailed: false
  property bool guardRecoveryAttempted: false
  property bool outputEventsBlocked: false
  readonly property bool eventsBlocked: eventsFailed || outputEventsBlocked
  readonly property bool lightingBlocked: sessionBlocked || eventsBlocked
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

  function setMode(mode, allowRetry) {
    if (allowRetry) {
      actionFailed = false
      guardRecoveryAttempted = false
    }
    if (actionFailed) return
    var target = lightingBlocked ? "off" : mode
    var retry = allowRetry === true
    if (pendingAction && pendingAction.mode === target) retry = retry || pendingAction.retry
    pendingAction = { mode: target, retry: retry }
    flushMode()
  }

  function flushMode() {
    if (!pendingAction) return
    if (actionFailed && !pendingAction.retry) { pendingAction = null; return }
    if (actionProc.running) return
    if (pendingAction.retry) actionFailed = false
    actionProc.result = ""
    actionProc.command = [root.helper, "set", lightingBlocked ? "off" : pendingAction.mode]
    pendingAction = null
    actionProc.running = true
  }

  function updateSession(blocked) {
    blocked = blocked || eventsBlocked
    var wasBlocked = sessionBlocked
    sessionBlocked = blocked
    if (blocked) {
      lastSchedulePeriod = ""
      if (!wasBlocked) setMode("off", true)
      else if (level > 0 || pendingAction) setMode("off")
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
    pendingAction = null
    setMode("off", true)
    console.warn("Keyboard backlight event subscription stopped; automatic lighting disabled until reload")
  }

  function finishAction(exitCode, exitStatus) {
    if (exitCode !== 0 || exitStatus !== 0) {
      actionFailed = true
      refreshDelay.stop()
      scheduleTimer.stop()
      // A newer explicit request (including a fresh lock) gets its own one
      // attempt, even when the older in-flight command failed.
      if (pendingAction && pendingAction.retry) flushMode()
      else {
        pendingAction = null
        console.warn("Keyboard backlight write failed; waiting for a new lock, manual retry, or reload")
      }
      return
    }
    if (actionProc.result === "inhibited") {
      lastSchedulePeriod = ""
      sessionBlocked = true
      scheduleTimer.stop()
      // The guard already switched the hardware off. Discard stale requests,
      // then settle once; repeated guard failures must not form a retry loop.
      pendingAction = null
      if (!guardRecoveryAttempted && !eventsFailed) {
        guardRecoveryAttempted = true
        refreshDelay.start()
      } else refreshDelay.stop()
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
    if (line === "outputs-blocked") {
      outputEventsBlocked = true
      updateSession(true)
    } else if (line === "outputs-ready") {
      outputEventsBlocked = false
      guardRecoveryAttempted = false
      refresh()
    } else if (line === "clock") {
      guardRecoveryAttempted = false
      clockChanged()
    } else if (line === "change") {
      guardRecoveryAttempted = false
      refresh()
    }
  }

  function applySchedule(force) {
    if (lightingBlocked || !scheduleEnabled) {
      lastSchedulePeriod = ""
      return
    }
    var period = Schedule.period(new Date(), nightStartHour, dayStartHour)
    if (!force && period === lastSchedulePeriod) return
    lastSchedulePeriod = period
    setMode(period === "night" ? "low" : "off")
  }

  function armSchedule() {
    scheduleTimer.stop()
    if (lightingBlocked || actionFailed) return
    var delay = Schedule.nextDelay(new Date(), scheduleEnabled, nightStartHour, dayStartHour)
    if (delay <= 0) return
    scheduleTimer.interval = delay
    scheduleTimer.start()
  }

  function scheduleChanged() {
    guardRecoveryAttempted = false
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
      root.guardRecoveryAttempted = false
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
    property string result: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: actionProc.result = text.trim()
    }
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
