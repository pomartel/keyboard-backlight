const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const plugin = path.resolve(__dirname, '..');
const omarchy = '/usr/share/omarchy/shell';
const available = fs.existsSync(omarchy) && fs.existsSync('/usr/bin/quickshell');

function runWidget(status, action, watcher, setup) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'backlight-qml-'));
  try {
    for (const name of ['Ui', 'Commons']) fs.symlinkSync(path.join(omarchy, name), path.join(root, name));
    const copy = path.join(root, 'plugin');
    fs.mkdirSync(path.join(copy, 'bin'), { recursive: true });
    for (const name of ['BarWidget.qml', 'Panel.qml']) fs.copyFileSync(path.join(plugin, name), path.join(copy, name));
    const log = path.join(root, 'actions');
    fs.writeFileSync(log, '');
    const options = setup ? setup(root, log) : {};
    fs.writeFileSync(path.join(copy, 'bin/keyboard-backlight'),
      options.helper || `#!/bin/bash\nif [[ $1 == status ]]; then ${status}; else echo "$2" >> '${log}'; ${action}; fi\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(copy, 'bin/watch-session'), `#!/bin/bash\n${options.watcher || watcher}\n`, { mode: 0o755 });
    fs.writeFileSync(path.join(root, 'shell.qml'), `import QtQuick
import Quickshell
ShellRoot {
  Loader {
    id: widget
    source: "plugin/BarWidget.qml"
    onLoaded: item.settings = ({scheduleEnabled: true, nightStartHour: 0, dayStartHour: 0})
  }
  Timer {
    interval: ${options.duration || 1200}; running: true
    onTriggered: {
      console.log("RESULT " + JSON.stringify({blocked: widget.item.sessionBlocked,
        eventsFailed: widget.item.eventsFailed, actionFailed: widget.item.actionFailed,
        level: widget.item.level, period: widget.item.lastSchedulePeriod}))
      Qt.quit()
    }
  }
}
`);
    const output = execFileSync('quickshell', ['--no-color', '-p', root], {
      env: { ...process.env, ...options.env, QT_QPA_PLATFORM: 'offscreen' }, encoding: 'utf8', timeout: 8000,
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

for (const delay of [0, 0.5]) {
  test(`QML: lock after a write error still attempts off once (write delay ${delay}s)`, { skip: !available }, () => {
    const result = runWidget('', '', '', (root, log) => {
      const locked = path.join(root, 'locked');
      return {
        helper: `#!/bin/bash
if [[ $1 == status ]]; then
  if [[ -e '${locked}' ]]; then echo '2 2 test true'; else echo '2 2 test false'; fi
else
  echo "$2" >> '${log}'
  if [[ $2 == low ]]; then sleep ${delay}; fi
  exit 1
fi
`,
        watcher: `echo change; sleep .3; touch '${locked}'; echo change; exec sleep 10`,
      };
    });
    assert.deepEqual(result.actions, ['low', 'off']);
    assert.equal(result.blocked, true);
    assert.equal(result.actionFailed, true);
  });
}

function guardedHelper(root, log, persistent) {
  const leds = path.join(root, 'leds');
  fs.mkdirSync(path.join(leds, 'test::kbd_backlight'), { recursive: true });
  const state = path.join(root, 'state');
  const calls = path.join(root, 'calls');
  const mocks = path.join(root, 'tools');
  fs.mkdirSync(mocks);
  fs.writeFileSync(state, '0');
  fs.writeFileSync(calls, '0');
  const commands = {
    brightnessctl: `case "$3" in get) cat '${state}';; max) echo 2;; set) echo "$4" > '${state}'; echo "$4" >> '${log}';; esac`,
    'omarchy-shell': `n=$(cat '${calls}'); n=$((n+1)); echo "$n" > '${calls}'
if ${persistent ? '((n % 2 == 0))' : '((n == 2))'}; then exit 1; fi
echo false`,
    hyprctl: `echo '[{"disabled":false,"dpmsStatus":true}]'`,
  };
  for (const [name, body] of Object.entries(commands)) {
    fs.writeFileSync(path.join(mocks, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  }
  return {
    helper: fs.readFileSync(path.join(plugin, 'bin/keyboard-backlight'), 'utf8').replace('/sys/class/leds/', `${leds}/`),
    env: { PATH: `${mocks}:${process.env.PATH}` }, duration: 1800,
  };
}

test('QML: a transient guard failure is followed by the scheduled low level', { skip: !available }, () => {
  const result = runWidget('', '', 'echo change; exec sleep 10', (root, log) => guardedHelper(root, log, false));
  assert.deepEqual(result.actions, ['0', '1']);
  assert.equal(result.level, 1);
  assert.equal(result.period, 'night');
  assert.equal(result.blocked, false);
});

test('QML: recurring guard failures do not form an automatic retry loop', { skip: !available }, () => {
  const result = runWidget('', '', 'echo change; exec sleep 10', (root, log) => guardedHelper(root, log, true));
  assert.deepEqual(result.actions, ['0', '0']);
  assert.equal(result.blocked, true);
  assert.equal(result.actionFailed, false);
});
