// Claude's 5-hour window stays out of the way until it is the one that bites,
// then it is on the card and the strip. "Is it hot" is the whole decision, so
// it is tested against fixed clocks here: running dry before the reset, spent,
// and every loud-looking state that is still calm (70% gone, over pace) because
// the window can carry it to its reset. Extracts the pure helpers from
// BarWidget.qml and runs them as plain JavaScript; it does not render QML.
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
for (const f of ['paceLive', 'spanShort', 'clockSpan', 'spanWords', 'sessionHeat', 'sessionOutranks', 'sessionChipWords', 'sessionRowWords']) vm.runInContext(extract(f), ctx);

const MIN = 60e3, HOUR = 3600e3, DAY = 24 * HOUR, WEEK = 7 * DAY, SESSION = 5 * HOUR;
const NOW = 1_800_000_000_000;
// A 5-hour row `gone` of the way through with `used` spent, the way the
// collector hands it over: the provider's percent plus its pace block.
const session = (used, gone, extra = {}) => ({
  label: 'Session (5-hour)', percent: used,
  pace: Object.assign({ resetsMs: NOW + SESSION * (1 - gone), windowMs: SESSION, dryAt: 0 }, extra),
});
const week = (used, gone) => ctx.paceLive(used, NOW + WEEK * (1 - gone), WEEK, NOW);

test('calm: under pace with no dry projection leaves the default view alone', () => {
  const h = ctx.sessionHeat(session(0.20, 0.50), week(0.40, 0.50), NOW);
  assert.equal(h.hot, false);
  assert.equal(h.reason, '');
  assert.equal(ctx.sessionChipWords(h, NOW).text, '');
});

test('running dry before the reset is hot, even when the clock says on pace', () => {
  // On pace by the clock (50% at 55%), but the collector's rate says empty in
  // 40 minutes with 2h15m still to go.
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'dry');
  assert.equal(h.stage, 1);
  assert.equal(h.dryAt, NOW + 40 * MIN);
  assert.equal(h.resetsMs, session(0.50, 0.55).pace.resetsMs);
});

test('a dry moment after the reset, or none at all, is not exhaustion', () => {
  assert.equal(ctx.sessionHeat(session(0.30, 0.55, { dryAt: NOW + 3 * HOUR }), week(0.30, 0.50), NOW).hot, false);
  assert.equal(ctx.sessionHeat(session(0.30, 0.55), week(0.30, 0.50), NOW).hot, false);
});

test('70 percent gone with 15 minutes left and no dry projection is calm', () => {
  // 30% of the window is still there and the reset arrives first: not news.
  assert.equal(ctx.sessionHeat(session(0.70, 0.95), week(0.30, 0.50), NOW).hot, false);
  assert.equal(ctx.sessionHeat(session(0.92, 0.95), week(0.30, 0.50), NOW).hot, false);
});

test('over its own even pace with no dry projection is calm', () => {
  // 1h of 5 gone (20%) with 40% used: 2x pace, but the rate has not been
  // measured as running it dry before the reset.
  assert.equal(ctx.sessionHeat(session(0.40, 0.20), week(0.50, 0.50), NOW).hot, false);
  assert.equal(ctx.sessionHeat(session(0.40, 0.20), null, NOW).hot, false);
});

test('over pace AND running dry before the reset is hot, one stage up', () => {
  const h = ctx.sessionHeat(session(0.60, 0.20, { dryAt: NOW + 2 * HOUR }), week(0.50, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'dry');
  assert.equal(h.stage, 2);
});

test('spent is the top stage, and comes back at its reset', () => {
  const h = ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW);
  assert.equal(h.hot, true);
  assert.equal(h.reason, 'spent');
  assert.equal(h.stage, 4);
  assert.equal(h.spent, true);
  assert.equal(h.resetsMs, session(1.0, 0.60).pace.resetsMs);
});

test('a spent window has no run-out moment left to show', () => {
  // At 100% the collector still projects past the ceiling and writes a dry
  // moment a minute ahead; the card must not say "runs out" about a window
  // that already has.
  for (const used of [1.0, 0.996]) {
    const h = ctx.sessionHeat(session(used, 0.60, { dryAt: NOW + MIN }), week(0.30, 0.50), NOW);
    assert.equal(h.reason, 'spent');
    assert.equal(h.dryAt, 0);
    assert.equal(ctx.sessionChipWords(h, NOW).text, 'CLAUDE 5-HOUR  SPENT, BACK 2H');
  }
});

test('a spent week is the wall: the 5-hour window says nothing', () => {
  const h = ctx.sessionHeat(session(0.95, 0.50, { dryAt: NOW + 10 * MIN }), week(1.0, 0.80), NOW);
  assert.equal(h.hot, false);
});

test('no row, an unreadable percent, or a passed reset is calm, never a guess', () => {
  assert.equal(ctx.sessionHeat(null, null, NOW).hot, false);
  assert.equal(ctx.sessionHeat({ label: 'Session (5-hour)', percent: -1, pace: {} }, null, NOW).hot, false);
  assert.equal(ctx.sessionHeat(session(0.95, 1.2, { dryAt: NOW + 10 * MIN }), null, NOW).hot, false);
});

test('a week that is spent or way over keeps the chip over a hot 5-hour window', () => {
  const hot = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(ctx.sessionOutranks(4, hot), false, 'SPENT week');
  assert.equal(ctx.sessionOutranks(3, hot), false, 'badly over week');
  assert.equal(ctx.sessionOutranks(2, hot), false, 'WAY OVER week');
});

test('a hot 5-hour window outranks a week that is merely over pace, or none', () => {
  const hot = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(ctx.sessionOutranks(1, hot), true);
  assert.equal(ctx.sessionOutranks(0, hot), true);
  assert.equal(ctx.sessionOutranks(undefined, hot), true);
});

test('a calm 5-hour window never takes the chip, whatever the week is doing', () => {
  const calm = ctx.sessionHeat(session(0.40, 0.20), week(0.50, 0.50), NOW);
  for (const stage of [0, 1, 2, 4]) assert.equal(ctx.sessionOutranks(stage, calm), false);
  assert.equal(ctx.sessionOutranks(0, null), false);
});

test('chip wording names the 5-hour window in every form, never just CLAUDE', () => {
  const cases = [
    ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW),
    ctx.sessionHeat(session(0.60, 0.20, { dryAt: NOW + 2 * HOUR }), week(0.50, 0.50), NOW),
    ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW),
  ];
  for (const h of cases) {
    for (const at of [NOW, NOW + 3 * HOUR]) {
      const w = ctx.sessionChipWords(h, at);
      assert.match(w.text, /^CLAUDE 5-HOUR  /, w.text);
      for (const form of [w.short, w.third, w.mult]) assert.match(form, /^5H\b/, form);
    }
  }
});

test('chip wording says what to do for each reason', () => {
  const dry = ctx.sessionChipWords(ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW), NOW);
  assert.equal(dry.text, 'CLAUDE 5-HOUR  OUT IN 40M');
  assert.equal(dry.short, '5H OUT 40M');
  assert.equal(dry.third, '5H 50%');
  const spent = ctx.sessionChipWords(ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW), NOW);
  assert.equal(spent.text, 'CLAUDE 5-HOUR  SPENT, BACK 2H');
  assert.equal(spent.third, '5H SPENT');
});

test('the chip counts down from the present, not from the moment it was measured', () => {
  // Measured at NOW while burning; the strip is drawn 25 minutes later.
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(ctx.sessionChipWords(h, NOW + 25 * MIN).text, 'CLAUDE 5-HOUR  OUT IN 15M');
  const spent = ctx.sessionHeat(session(1.0, 0.60), week(0.30, 0.50), NOW);
  assert.equal(ctx.sessionChipWords(spent, NOW + 90 * MIN).text, 'CLAUDE 5-HOUR  SPENT, BACK 30M');
});

test('once the dry moment has passed the chip says so instead of sticking at 1M', () => {
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  const w = ctx.sessionChipWords(h, NOW + 41 * MIN);
  assert.equal(w.text, 'CLAUDE 5-HOUR  RUNNING OUT');
  assert.equal(w.short, '5H OUT NOW');
  assert.equal(ctx.sessionChipWords(h, NOW + 40 * MIN).text, 'CLAUDE 5-HOUR  RUNNING OUT');
});

// The card's row: a stand-in clock that names the moment, so the forms can be
// read exactly. Minutes after NOW.
const clock = (ms) => 'T+' + Math.round((ms - NOW) / MIN) + 'm';

test('the card row leads with the run-out time in every form, longest first', () => {
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.deepEqual(Array.from(ctx.sessionRowWords(h, NOW, clock)), [
    'out T+40m  ·  resets T+135m  ·  in 2:15:00',
    'out T+40m  ·  resets in 2:15:00',
    'out T+40m  ·  resets in 2h 15m',
    'out T+40m',
  ]);
});

test('a narrower card row drops the reset clock, then the seconds, never the run-out', () => {
  const h = ctx.sessionHeat(session(0.60, 0.20, { dryAt: NOW + 2 * HOUR }), week(0.50, 0.50), NOW);
  const forms = Array.from(ctx.sessionRowWords(h, NOW, clock));
  for (const f of forms) assert.ok(f.startsWith('out T+120m'), f);
  for (let i = 1; i < forms.length; i++) assert.ok(forms[i].length < forms[i - 1].length, forms[i]);
  assert.match(forms[0], /resets T\+240m/);
  assert.doesNotMatch(forms[1], /T\+240m/);
});

test('a spent card row has no run-out, only the way back', () => {
  const h = ctx.sessionHeat(session(1.0, 0.60, { dryAt: NOW + MIN }), week(0.30, 0.50), NOW);
  assert.deepEqual(Array.from(ctx.sessionRowWords(h, NOW, clock)), [
    'resets T+120m  ·  in 2:00:00',
    'resets in 2:00:00',
    'resets in 2h',
  ]);
});

test('the card row counts down from the present, and a calm window has none', () => {
  const h = ctx.sessionHeat(session(0.50, 0.55, { dryAt: NOW + 40 * MIN }), week(0.30, 0.50), NOW);
  assert.equal(ctx.sessionRowWords(h, NOW + 25 * MIN, clock)[1], 'out T+40m  ·  resets in 1:50:00');
  assert.equal(ctx.sessionRowWords(ctx.sessionHeat(session(0.20, 0.50), week(0.40, 0.50), NOW), NOW, clock).length, 0);
});
