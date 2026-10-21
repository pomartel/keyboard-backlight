const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');

const plugin = path.resolve(__dirname, '..');
process.env.TZ = 'America/Toronto';

test('helper blocks locked, blank, and unknown sessions, including queued writes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keyboard-backlight-'));
  try {
    fs.mkdirSync(path.join(dir, 'leds', 'test::kbd_backlight'), { recursive: true });
    const helper = path.join(dir, 'helper');
    // Redirect only sysfs discovery; execute the real helper with mocked tools.
    fs.writeFileSync(helper, fs.readFileSync(path.join(plugin, 'bin/keyboard-backlight'), 'utf8')
      .replace('/sys/class/leds/', `${dir}/leds/`));
    const commands = {
      'omarchy-shell': 'printf "%s\\n" "$TEST_LOCK"; exit "${TEST_LOCK_ERROR:-0}"',
      hyprctl: 'printf "%s\\n" "$TEST_MONITORS"; exit "${TEST_MONITOR_ERROR:-0}"',
      brightnessctl: 'case "$3" in get) echo 2;; max) echo 2;; set) echo "$4" > "$TEST_WRITE";; esac',
    };
    for (const [name, body] of Object.entries(commands)) {
      fs.writeFileSync(path.join(dir, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
    }
    const awake = JSON.stringify([{ dpmsStatus: true, disabled: false }]);
    const cases = [
      { lock: 'false', monitors: awake, blocked: false },
      { lock: 'true', monitors: awake, blocked: true },
      { lock: 'false', monitors: '[{"dpmsStatus":false}]', blocked: true },
      { lock: 'false', monitors: '[{"dpmsStatus":false},{"dpmsStatus":true}]', blocked: false },
      { lock: 'false', monitors: '[{"dpmsStatus":true,"disabled":true}]', blocked: true },
      { lock: 'false', monitors: '[]', blocked: true },
      { lock: 'false', monitors: 'invalid', blocked: true },
      { lock: 'unknown', monitors: awake, blocked: true },
      { lock: 'false', monitors: awake, lockError: '1', blocked: true },
      { lock: 'false', monitors: awake, monitorError: '1', blocked: true },
    ];
    for (const c of cases) {
      const env = { ...process.env, PATH: `${dir}:${process.env.PATH}`,
        TEST_LOCK: c.lock, TEST_MONITORS: c.monitors, TEST_LOCK_ERROR: c.lockError || '0',
        TEST_MONITOR_ERROR: c.monitorError || '0', TEST_WRITE: path.join(dir, 'write') };
      const run = (...args) => execFileSync('bash', [helper, ...args], { env, encoding: 'utf8' });
      assert.equal(run('status').trim(), `2 2 test::kbd_backlight ${c.blocked}`);
      for (const [mode, target] of [['low', 1], ['high', 2], ['off', 0]]) {
        run('set', mode);
        assert.equal(fs.readFileSync(env.TEST_WRITE, 'utf8').trim(), String(c.blocked ? 0 : target));
      }
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

function widget() {
  const source = fs.readFileSync(path.join(plugin, 'BarWidget.qml'), 'utf8');
  const ctx = vm.createContext({ sessionBlocked: false, lastSchedulePeriod: 'night',
    pendingMode: '', refreshPending: false, statusProc: { running: false },
    level: 1, scheduleEnabled: true, helper: '/helper',
    actionProc: { running: false, command: [] }, nightStartHour: 18, dayStartHour: 7,
    scheduleTimer: { running: false, interval: 0,
      stop() { this.running = false; }, start() { this.running = true; } } });
  ctx.root = ctx;
  for (const name of ['refresh', 'setMode', 'flushMode', 'updateSession', 'schedulePeriod',
    'applySchedule', 'nextScheduleDelay', 'armSchedule', 'scheduleChanged']) {
    const match = source.match(new RegExp(`  function ${name}\\([^]*?\\n  }`));
    assert.ok(match, name);
    vm.runInContext(match[0], ctx);
  }
  ctx.schedulePeriod = () => 'night';
  return ctx;
}

test('lock overrides an in-flight action; unlocking reapplies the same period', () => {
  const w = widget();
  w.actionProc.running = true;
  w.updateSession(true);
  assert.equal(w.pendingMode, 'off');
  assert.equal(w.lastSchedulePeriod, '');
  w.applySchedule(true);
  assert.equal(w.pendingMode, 'off');
  w.actionProc.running = false;
  w.flushMode();
  assert.equal(w.actionProc.command[2], 'off');
  w.actionProc.running = false;
  w.level = 0;
  w.updateSession(false);
  assert.equal(w.actionProc.command[2], 'low');
  assert.equal(w.lastSchedulePeriod, 'night');
});

test('wake uses the current period and preserves manual changes while active', () => {
  const w = widget();
  w.updateSession(false);
  assert.equal(w.actionProc.running, false);
  w.updateSession(true);
  w.actionProc.running = false;
  w.schedulePeriod = () => 'day';
  w.updateSession(false);
  assert.equal(w.actionProc.command[2], 'off');
  assert.equal(w.lastSchedulePeriod, 'day');
});

test('disabled schedule still enforces off, without restoring brightness on wake', () => {
  const w = widget();
  w.scheduleEnabled = false;
  w.updateSession(true);
  assert.equal(w.actionProc.command[2], 'off');
  w.actionProc.running = false;
  w.updateSession(false);
  assert.equal(w.actionProc.running, false);
});

test('an event arriving during a state read queues another snapshot', () => {
  const w = widget();
  w.refresh();
  assert.equal(w.statusProc.running, true);
  assert.equal(w.refreshPending, false);
  w.refresh();
  assert.equal(w.refreshPending, true);
  w.statusProc.running = false;
  w.refresh();
  assert.equal(w.refreshPending, false);
  assert.equal(w.statusProc.running, true);
});

test('schedule targets the next boundary, including midnight and exact transition times', () => {
  const w = widget();
  const delay = time => w.nextScheduleDelay(new Date(time));
  assert.equal(delay('2026-10-21T17:59:59.750-04:00'), 250);
  assert.equal(delay('2026-10-21T18:00:00-04:00'), 13 * 3600000);
  assert.equal(delay('2026-10-21T07:00:00-04:00'), 11 * 3600000);
  assert.equal(delay('2026-10-21T23:00:00-04:00'), 8 * 3600000);
  w.nightStartHour = 0;
  assert.equal(delay('2026-10-21T23:59:59.900-04:00'), 100);
});

test('next-day deadlines use local calendar dates across daylight saving changes', () => {
  const w = widget();
  assert.equal(w.nextScheduleDelay(new Date('2026-03-07T20:00:00-05:00')), 10 * 3600000);
  assert.equal(w.nextScheduleDelay(new Date('2026-10-31T20:00:00-04:00')), 12 * 3600000);
});

test('locking stops the timer; wake and settings changes recalculate the deadline', () => {
  const w = widget();
  w.armSchedule();
  assert.equal(w.scheduleTimer.running, true);
  w.updateSession(true);
  assert.equal(w.scheduleTimer.running, false);
  w.actionProc.running = false;
  w.updateSession(false);
  assert.equal(w.scheduleTimer.running, true);
  const before = w.scheduleTimer.interval;
  w.dayStartHour = 8;
  w.nightStartHour = 19;
  w.scheduleChanged();
  assert.equal(w.scheduleTimer.running, true);
  assert.notEqual(w.scheduleTimer.interval, before);
  w.scheduleEnabled = false;
  w.scheduleChanged();
  assert.equal(w.scheduleTimer.running, false);
  w.scheduleEnabled = true;
  w.dayStartHour = w.nightStartHour;
  w.scheduleChanged();
  assert.equal(w.scheduleTimer.running, false);
});

test('native lock listener ignores authentication chatter and unrelated logs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keyboard-backlight-native-'));
  try {
    const source = `
      #define main watcher_main
      #include ${JSON.stringify(path.join(plugin, 'src/watch-session.c'))}
      #undef main
      #include <assert.h>
      int main(void) {
        assert(lock_event("qml: omarchy lock 2026-10-21T12:00:00Z lock-requested"));
        assert(lock_event("qml: omarchy lock now session-locked=false"));
        assert(lock_event("qml: omarchy lock now secure=true"));
        assert(lock_event("qml: omarchy lock now unlocked"));
        assert(!lock_event("qml: omarchy lock now fingerprint-match"));
        assert(!lock_event("qml: omarchy lock now password-failed"));
        assert(!lock_event("other plugin: secure=true"));
        return 0;
      }
    `;
    const binary = path.join(dir, 'test');
    execFileSync('cc', ['-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror',
      '-x', 'c', '-', '-lwayland-client', '-lsystemd', '-o', binary], { input: source });
    execFileSync(binary);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
