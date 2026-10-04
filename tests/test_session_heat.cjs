// Claude's 5-hour window stays out of the way until it is the one that bites,
// then it is on the card and the strip. "Is it hot" is the whole decision, so
// it is tested against fixed clocks here: behind pace, running dry before the
// reset, 70% gone, and calm. Extracts the pure helpers from BarWidget.qml and
// runs them as plain JavaScript; it does not render QML.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const widget = fs.readFileSync('BarWidget.qml', 'utf8');
const ctx = {};
vm.createContext(ctx);
function extract(name) {
  const start = widget.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'expected to find function ' + name);
  let depth = 0, i = widget.indexOf('{', start);
  for (let j = i; j < widget.length; j++) {
    if (widget[j] === '{') depth++;
    else if (widget[j] === '}') { depth--; if (depth === 0) return widget.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces in ' + name);
}
for (const f of ['paceLive', 'spanShort', 'sessionHeat', 'sessionChipWords']) vm.runInContext(extract(f), ctx);

const MIN = 60e3, HOUR = 3600e3, DAY = 24 * HOUR, WEEK = 7 * DAY, SESSION = 5 * HOUR;
const NOW = 1_800_000_000_000;
// A 5-hour row `gone` of the way through with `used` spent, the way the
// collector hands it over: the provider's percent plus its pace block.
const session = (used, gone, extra = {}) => ({
  label: 'Session (5-hour)', percent: used,
  pace: Object.assign({ resetsMs: NOW + SESSION * (1 - gone), windowMs: SESSION, dryAt: 0 }, extra),
});
const week = (used, gone) => ctx.paceLive(used, NOW + WEEK * (1 - gone), WEEK, NOW);

test('calm: under pace and under 70% leaves the default view alone', () => {
  const h = ctx.sessionHeat(session(0.20, 0.50), week(0.40, 0.50), NOW);
  assert.equal(h.hot, false);
  assert.equal(h.reason, '');
  assert.equal(ctx.sessionChipWords(h, NOW).text, '');
});

test('behind pace: over its own even pace and further over than the week', () => {
  // 1h of 5 gone (20%) with 40% used: 2x pace, 20 points past the line.
  const h = ctx.sessionHeat(session(0.40, 0.20), week(0.50, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'pace');
  assert.equal(h.stage, 1);
  // Stop now and the even line catches up at 40% elapsed: one hour from now.
  assert.ok(Math.abs(h.comeBackMs - HOUR) < 1000, String(h.comeBackMs));
});

test('behind pace is not hot when the week is running even further over', () => {
  // Session 1.5x, week 2x: the week is the binding one, and it has its own chip.
  const h = ctx.sessionHeat(session(0.30, 0.20), week(0.60, 0.30), NOW);
  assert.equal(h.hot, false);
});

test('behind pace needs a real margin, not the first minutes of a window', () => {
  // 3% used 1% in: 3x the even pace but two points past the line.
  const h = ctx.sessionHeat(session(0.03, 0.01), week(0.10, 0.50), NOW);
  assert.equal(h.hot, false);
});

test('exhaustion before reset: the measured rate runs it dry early', () => {
  // On pace by the clock (50% at 55%), but the collector's rate says empty in
  // 40 minutes with 2h15m still to go.
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'dry');
  assert.equal(h.stage, 2);
  assert.equal(h.dryAt, NOW + 40 * MIN);
});

test('a dry moment after the reset is not exhaustion', () => {
  const h = ctx.sessionHeat(session(0.30, 0.55, { dryAt: NOW + 3 * HOUR }), week(0.30, 0.50), NOW);
  assert.equal(h.hot, false);
});

test('70 percent used is hot even when the clock says on pace', () => {
  const h = ctx.sessionHeat(session(0.70, 0.90), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'used');
  assert.equal(h.stage, 1);
  // And 69% at the same moment is calm.
  assert.equal(ctx.sessionHeat(session(0.69, 0.90), week(0.30, 0.50), NOW).hot, false);
});

test('90 percent climbs a stage, so an answered warning re-opens', () => {
  const h = ctx.sessionHeat(session(0.92, 0.95), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.stage, 3);
});

test('spent is the top stage, and comes back at its reset', () => {
  const h = ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'spent');
  assert.equal(h.stage, 4);
  assert.ok(Math.abs(h.leftMs - 2 * HOUR) < 1000);
});

test('a spent week is the wall: the 5-hour window says nothing', () => {
  const h = ctx.sessionHeat(session(0.95, 0.50), week(1.0, 0.80), NOW);
  assert.equal(h.hot, false);
});

test('no row, an unreadable percent, or a passed reset is calm, never a guess', () => {
  assert.equal(ctx.sessionHeat(null, null, NOW).hot, false);
  assert.equal(ctx.sessionHeat({ label: 'Session (5-hour)', percent: -1, pace: {} }, null, NOW).hot, false);
  assert.equal(ctx.sessionHeat(session(0.95, 1.2), null, NOW).hot, false);
});

test('no week to compare with still lets an over-pace 5-hour window be hot', () => {
  const h = ctx.sessionHeat(session(0.40, 0.20), null, NOW);
  assert.equal(h.reason, 'pace');
});

test('chip wording names the 5-hour window in every form, never just CLAUDE', () => {
  const cases = [
    ctx.sessionHeat(session(0.40, 0.20), week(0.50, 0.50), NOW),
    ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW),
    ctx.sessionHeat(session(0.82, 0.90), week(0.30, 0.50), NOW),
    ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW),
  ];
  for (const h of cases) {
    const w = ctx.sessionChipWords(h, NOW);
    assert.match(w.text, /^CLAUDE 5-HOUR  /, w.text);
    for (const form of [w.short, w.third, w.mult]) assert.match(form, /^5H\b/, form);
  }
});

test('chip wording says what to do for each reason', () => {
  const pace = ctx.sessionChipWords(ctx.sessionHeat(session(0.40, 0.20), week(0.50, 0.50), NOW), NOW);
  assert.equal(pace.text, 'CLAUDE 5-HOUR  REST 1H');
  assert.equal(pace.short, '5H REST 1H');
  const dry = ctx.sessionChipWords(ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW), NOW);
  assert.equal(dry.text, 'CLAUDE 5-HOUR  OUT IN 40M');
  assert.equal(dry.short, '5H OUT 40M');
  const used = ctx.sessionChipWords(ctx.sessionHeat(session(0.82, 0.90), week(0.30, 0.50), NOW), NOW);
  assert.equal(used.text, 'CLAUDE 5-HOUR  82% USED');
  assert.equal(used.third, '5H 82%');
  const spent = ctx.sessionChipWords(ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW), NOW);
  assert.equal(spent.text, 'CLAUDE 5-HOUR  SPENT, BACK 2H');
  assert.equal(spent.third, '5H SPENT');
});
