const { test } = require('node:test');
const assert = require('node:assert/strict');
const Schedule = require('../Schedule.js');

process.env.TZ = 'America/Toronto';

test('schedule targets the next boundary, including midnight and exact transition times', () => {
  const delay = time => Schedule.nextDelay(new Date(time), true, 18, 7);
  assert.equal(delay('2026-10-21T17:59:59.750-04:00'), 250);
  assert.equal(delay('2026-10-21T18:00:00-04:00'), 13 * 3600000);
  assert.equal(delay('2026-10-21T07:00:00-04:00'), 11 * 3600000);
  assert.equal(delay('2026-10-21T23:00:00-04:00'), 8 * 3600000);
  assert.equal(Schedule.nextDelay(new Date('2026-10-21T23:59:59.900-04:00'), true, 0, 7), 100);

  // Check the current period at either side of a boundary and in both hour orders.
  for (const [night, day, before, after] of [[18, 7, 'day', 'night'], [7, 18, 'night', 'day']]) {
    assert.equal(Schedule.period(new Date('2026-10-21T17:59:59.750-04:00'), night, day), before);
    assert.equal(Schedule.period(new Date('2026-10-21T18:00:00-04:00'), night, day), after);
    assert.equal(Schedule.period(new Date('2026-10-22T07:00:00-04:00'), night, day), before);
  }
  for (const hour of [0, 7, 18, 23]) {
    const now = new Date(2026, 9, 21, hour);
    assert.equal(Schedule.period(now, 7, 7), 'night');
    assert.equal(Schedule.nextDelay(now, true, 7, 7), 0);
    assert.equal(Schedule.nextDelay(now, false, 18, 7), 0);
  }
});

test('next-day deadlines use local calendar dates across daylight saving changes', () => {
  assert.equal(Schedule.nextDelay(new Date('2026-03-07T20:00:00-05:00'), true, 18, 7), 10 * 3600000);
  assert.equal(Schedule.nextDelay(new Date('2026-10-31T20:00:00-04:00'), true, 18, 7), 12 * 3600000);
});
