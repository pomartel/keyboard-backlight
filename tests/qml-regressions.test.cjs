const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const plugin = path.resolve(__dirname, '..');
const omarchy = '/usr/share/omarchy/shell';
const available = fs.existsSync(omarchy) && fs.existsSync('/usr/bin/quickshell');

function runWidget(status, action, watcher) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'backlight-qml-'));
  try {
    for (const name of ['Ui', 'Commons']) fs.symlinkSync(path.join(omarchy, name), path.join(root, name));
    const copy = path.join(root, 'plugin');
    fs.mkdirSync(path.join(copy, 'bin'), { recursive: true });
    for (const name of ['BarWidget.qml', 'Panel.qml']) fs.copyFileSync(path.join(plugin, name), path.join(copy, name));
    const log = path.join(root, 'actions');
    fs.writeFileSync(log, '');
    fs.writeFileSync(path.join(copy, 'bin/keyboard-backlight'),
      `#!/bin/bash\nif [[ $1 == status ]]; then ${status}; else echo "$2" >> '${log}'; ${action}; fi\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(copy, 'bin/watch-session'), `#!/bin/bash\n${watcher}\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(root, 'shell.qml'), `import QtQuick
import Quickshell
ShellRoot {
  Loader {
    id: widget
    source: "plugin/BarWidget.qml"
    onLoaded: item.settings = ({scheduleEnabled: true, nightStartHour: 0, dayStartHour: 23})
  }
  Timer {
    interval: 1200; running: true
    onTriggered: {
      console.log("RESULT " + JSON.stringify({blocked: widget.item.sessionBlocked,
        eventsFailed: widget.item.eventsFailed, actionFailed: widget.item.actionFailed}))
      Qt.quit()
    }
  }
}
`);
    const output = execFileSync('quickshell', ['--no-color', '-p', root], {
      env: { ...process.env, QT_QPA_PLATFORM: 'offscreen' }, encoding: 'utf8', timeout: 8000,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const match = output.match(/RESULT (\{[^\n]+\})/);
    assert.ok(match, output);
    return { ...JSON.parse(match[1]), actions: fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean) };
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

test('QML: late status after event-process exit never relights the keyboard', { skip: !available }, () => {
  const result = runWidget('sleep .3; echo "0 2 test false"', 'exit 0', 'echo change; sleep .05; exit 1');
  assert.deepEqual(result.actions, ['off']);
  assert.equal(result.blocked, true);
  assert.equal(result.eventsFailed, true);
});

test('QML: a denied off command is attempted once without a refresh retry loop', { skip: !available }, () => {
  const result = runWidget('echo "1 2 test true"', 'exit 1', 'echo change; exec sleep 10');
  assert.deepEqual(result.actions, ['off']);
  assert.equal(result.actionFailed, true);
});
