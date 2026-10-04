// Guidance is the part of Burn Bar that tells you what to DO, so it is the part
// that must never be wrong: banked only when ahead, a way back only when
// behind, a suggestion only when there is a real choice, and never the local
// GPU. Extracts the pure helpers from BarWidget.qml and runs them as plain
// JavaScript; it does not render QML.
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
for (const f of ['paceLive', 'guidePick', 'guideBlocked', 'sessionHeat', 'spanWords', 'clockSpan', 'spanShort']) vm.runInContext(extract(f), ctx);

const HOUR = 3600e3, DAY = 24 * HOUR, WEEK = 7 * DAY, MONTH = 30 * DAY;
const NOW = 1_800_000_000_000;
// A window that is `gone` of the way through, with `used` of the plan spent.
const win = (used, gone, span = WEEK) => ctx.paceLive(used, NOW + span * (1 - gone), span, NOW);
const near = (a, b, eps = 1e-9) => assert.ok(Math.abs(a - b) < eps, a + ' vs ' + b);

test('ahead: banked is elapsed minus used, in plan share and in time', () => {
  const w = win(0.02, 0.51);
  near(w.banked, 0.49);
  near(w.bankedMs, 0.49 * WEEK, 1);
  assert.equal(w.behind, 0);
  assert.equal(w.comeBackAt, 0);
  near(w.room, 0.98 / 0.49);
});

test('behind: no banked figure at all, and a moment to come back', () => {
  const w = win(0.09, 0.05);
  assert.equal(w.banked, 0);
  assert.equal(w.bankedMs, 0);
  near(w.behind, 0.04);
  // Even pace catches up when elapsed reaches 9%: 4% of a week from now.
  near(w.comeBackMs, 0.04 * WEEK, 1);
  assert.ok(w.comeBackAt > NOW && w.comeBackAt < w.resetsMs);
});

test('time off brings a sub back: banked grows while the percentage sits still', () => {
  const reset = NOW + 5 * DAY;
  const before = ctx.paceLive(0.3, reset, WEEK, NOW);            // 28.6% gone: behind
  const later = ctx.paceLive(0.3, reset, WEEK, NOW + 2 * DAY);   // 57% gone: ahead
  assert.ok(before.behind > 0 && before.banked === 0);
  assert.ok(later.banked > 0.25 && later.behind === 0);
  // And the promised come-back moment is exactly when it flips.
  const flip = ctx.paceLive(0.3, reset, WEEK, before.comeBackAt + 1000);
  assert.ok(flip.behind === 0);
});

test('spent out comes back at the reset, never before', () => {
  const w = win(1.0, 0.13);
  assert.equal(w.spent, true);
  assert.equal(w.comeBackAt, w.resetsMs);
  assert.equal(w.room, 0);
});

test('spent while AHEAD of the clock still comes back at the reset, not in 1970', () => {
  // k3 caught this the day it was written: 99.6% used in the last hour of a week
  // is "ahead" (elapsed 99.9%), so the come-back time was never set and the
  // card printed new Date(0).
  const w = win(0.996, 0.999);
  assert.equal(w.spent, true);
  assert.equal(w.banked, 0);
  assert.equal(w.comeBackAt, w.resetsMs);
  assert.ok(w.comeBackMs > 0);
  const even = win(0.997, 0.997);             // used == elapsed exactly
  assert.equal(even.comeBackAt, even.resetsMs);
});

test('inside 5% of an even spend is on pace, not told to go away', () => {
  const close = win(0.50, 0.48);              // 1.04x: behind by 2%, but within grace
  assert.ok(close.behind > 0.019);
  assert.equal(close.over, false);
  const over = win(0.09, 0.05);               // 1.8x
  assert.equal(over.over, true);
  const sliver = win(0.004, 0.001);           // 4x, but under 1% of the plan
  assert.equal(sliver.over, false);
});

test('nothing is claimed about a window that cannot be read', () => {
  for (const bad of [[-1, NOW + DAY, WEEK], [NaN, NOW + DAY, WEEK], [0.5, 0, WEEK], [0.5, NOW + DAY, 0],
                     [0.5, NOW - 1, WEEK], [undefined, undefined, undefined]])
    assert.equal(ctx.paceLive(bad[0], bad[1], bad[2], NOW), null, JSON.stringify(bad));
});

const row = (id, used, gone, opts = {}) =>
  Object.assign({ id, live: win(used, gone, opts.span || WEEK), fresh: true, blocked: false }, opts.flags || {});

test('one subscription is never suggested: there is nothing to choose between', () => {
  const g = ctx.guidePick([row('kimi', 0.05, 0.6, { span: MONTH })], '');
  assert.equal(g.count, 1);
  assert.equal(g.pick, '');
});

test('with two, the one with room is the right one', () => {
  const g = ctx.guidePick([row('claude', 0.09, 0.05), row('grok', 0.02, 0.51)], '');
  assert.equal(g.pick, 'grok');
  assert.equal(g.next, '');
  assert.deepEqual(Array.from(g.rest, r => r.id), ['claude']);
});

test('with four, a week and a month are ranked on the same scale', () => {
  const g = ctx.guidePick([
    row('claude', 0.09, 0.05),                       // behind
    row('codex', 1.0, 0.13),                         // spent
    row('grok', 0.02, 0.51),                         // room ~2.0
    row('kimi', 0.05, 0.16, { span: MONTH }),        // room ~1.13
  ], '');
  assert.equal(g.pick, 'grok');
  assert.equal(g.next, 'kimi');
  assert.equal(g.ahead, 2);
  // Whoever is back first leads the rest list: Claude long before Codex.
  assert.deepEqual(Array.from(g.rest, r => r.id), ['claude', 'codex']);
});

test('use it or lose it: a reset close by with budget unspent wins, and says so', () => {
  const g = ctx.guidePick([row('grok', 0.02, 0.51), row('codex', 0.60, 0.95)], '');
  assert.equal(g.pick, 'codex');       // 40% of a week about to expire
  assert.equal(g.urgent, true);
});

test('urgent is about the calendar: a month with four days left is not an alarm', () => {
  const fourDays = 1 - (4 * DAY) / MONTH;
  const g = ctx.guidePick([row('kimi', 0.30, fourDays, { span: MONTH }), row('claude', 0.9, 0.5)], '');
  assert.equal(g.pick, 'kimi');
  assert.equal(g.urgent, false);
  const twoDays = 1 - (2 * DAY) / MONTH;
  assert.equal(ctx.guidePick([row('kimi', 0.30, twoDays, { span: MONTH }), row('claude', 0.9, 0.5)], '').urgent, true);
  // Nearly nothing left is not worth a siren either.
  assert.equal(ctx.guidePick([row('grok', 0.93, 0.97), row('claude', 0.9, 0.5)], '').urgent, false);
});

test('a snapshot has to be further ahead before it is suggested', () => {
  const snap = (bank, min) => Object.assign(row('grok', 0.5 - bank, 0.5), { minBank: min });
  assert.equal(ctx.guidePick([snap(0.06, 0.10), row('claude', 0.9, 0.5)], '').pick, '');
  assert.equal(ctx.guidePick([snap(0.12, 0.10), row('claude', 0.9, 0.5)], '').pick, 'grok');
  assert.equal(ctx.guidePick([snap(0.12, 0.25), row('claude', 0.9, 0.5)], '').pick, '');   // used since
});

test('the sub being suggested keeps the job down to half the threshold', () => {
  const thin = row('kimi', 0.485, 0.50, { span: MONTH });     // 1.5% banked
  assert.equal(ctx.guidePick([thin, row('claude', 0.9, 0.5)], '').pick, '');
  assert.equal(ctx.guidePick([thin, row('claude', 0.9, 0.5)], 'kimi').pick, 'kimi');
});

test('a sub is not suggested when it cannot be vouched for, is blocked, or is spent', () => {
  const stale = ctx.guidePick([row('claude', 0.5, 0.5), row('grok', 0.02, 0.6, { flags: { fresh: false } })], '');
  assert.equal(stale.pick, '');
  const blocked = ctx.guidePick([row('claude', 0.1, 0.6, { flags: { blocked: true } }), row('codex', 0.7, 0.5)], '');
  assert.equal(blocked.pick, '');
  const unknown = ctx.guidePick([{ id: 'claude', live: null, fresh: true, blocked: false }, row('kimi', 0.05, 0.4, { span: MONTH })], '');
  assert.equal(unknown.pick, 'kimi');  // two subs on the machine, one readable and ahead
});

test('everyone behind: no suggestion, and the first one back is named', () => {
  const g = ctx.guidePick([row('claude', 0.30, 0.10), row('codex', 0.20, 0.15)], '');
  assert.equal(g.pick, '');
  assert.equal(g.rest[0].id, 'codex');
});

test('a hair of banked budget is not advice', () => {
  const g = ctx.guidePick([row('claude', 0.49, 0.50), row('codex', 0.30, 0.31)], '');
  assert.equal(g.pick, '');
});

test('the advice does not flap between two near-equal subs', () => {
  const a = row('grok', 0.20, 0.60), b = row('kimi', 0.19, 0.60, { span: MONTH });
  assert.equal(ctx.guidePick([a, b], '').pick, 'kimi');        // marginally more room
  assert.equal(ctx.guidePick([a, b], 'grok').pick, 'grok');    // but not clearly better: stay
  const clear = row('kimi', 0.02, 0.60, { span: MONTH });
  assert.equal(ctx.guidePick([a, clear], 'grok').pick, 'kimi'); // clearly better: move
});

test('local is never a candidate, because it is never offered as one', () => {
  const build = widget.slice(widget.indexOf('function refreshGuidance('));
  const ids = build.slice(0, build.indexOf('guidance = guidePick'));
  assert.match(ids, /\["claude", "codex", "grok", "kimi"\]/);
  assert.doesNotMatch(ids, /"local"/);
});

test('the card clocks run, and the chip stays short', () => {
  assert.equal(ctx.clockSpan(3 * DAY + 9 * HOUR + 12 * 60e3 + 45e3), '3d 09:12:45');
  assert.equal(ctx.clockSpan(7 * HOUR + 13 * 60e3 + 22e3), '7:13:22');
  assert.equal(ctx.clockSpan(13 * 60e3 + 5e3), '13:05');
  assert.equal(ctx.clockSpan(-5), '0:00');
  assert.equal(ctx.clockSpan(NaN), '0:00');
  assert.equal(ctx.spanShort(7 * HOUR + 13 * 60e3), '7H');
  assert.equal(ctx.spanShort(2 * DAY + 3 * HOUR), '2D');
  assert.equal(ctx.spanShort(45 * 60e3), '45M');
  assert.equal(ctx.spanShort(5e3), '1M');
});

test('spans read like advice, not like a stopwatch', () => {
  assert.equal(ctx.spanWords(3 * DAY + 10 * HOUR + 22 * 60e3), '3d 10h');
  assert.equal(ctx.spanWords(6 * HOUR + 40 * 60e3), '6h 40m');
  assert.equal(ctx.spanWords(45 * 60e3), '45m');
  assert.equal(ctx.spanWords(2 * DAY), '2d');
  assert.equal(ctx.spanWords(20e3), 'under a minute');
  assert.equal(ctx.spanWords(NaN), 'under a minute');
});

test('a hot 5-hour window keeps Claude out of the advice, so the strip never warns and recommends at once', () => {
  // Claude's week is 20% banked and Codex's 5%, so Claude would be the pick.
  // But Claude's 5-hour window is 60% gone with 2.5h left and the measured
  // rate runs it dry in 80 minutes, before its reset: it is hot, and the
  // cockpit must not say "Keep using Claude" under a RUNNING DRY row.
  const SESSION = 5 * HOUR, MIN = 60e3;
  const claudeWeek = win(0.30, 0.50), codexWeek = win(0.45, 0.50);
  const session = (dryAt) => ({ label: 'Session (5-hour)', percent: 0.60,
    pace: { resetsMs: NOW + SESSION * 0.5, windowMs: SESSION, dryAt } });
  const hot = ctx.sessionHeat(session(NOW + 80 * MIN), claudeWeek, NOW);
  assert.equal(hot.hot, true);
  // Nothing else blocks it: 60% is under the 90% line and 80 minutes is well
  // past the half-hour that sessionBlock watches.
  const rows = (heat) => [
    { id: 'claude', live: claudeWeek, fresh: true, blocked: ctx.guideBlocked('claude', false, heat) },
    { id: 'codex', live: codexWeek, fresh: true, blocked: ctx.guideBlocked('codex', false, heat) },
  ];
  const g = ctx.guidePick(rows(hot), '');
  assert.notEqual(g.pick, 'claude');
  assert.equal(g.pick, 'codex');
  // Even when Claude was the standing pick, it is dropped.
  assert.equal(ctx.guidePick(rows(hot), 'claude').pick, 'codex');
  // Calm, the same numbers pick Claude: the heat is the whole difference.
  const calm = ctx.sessionHeat(session(0), claudeWeek, NOW);
  assert.equal(calm.hot, false);
  assert.equal(ctx.guidePick(rows(calm), '').pick, 'claude');
  // Only Claude's window is watched here; a full window still blocks anyone.
  assert.equal(ctx.guideBlocked('codex', false, hot), false);
  assert.equal(ctx.guideBlocked('codex', true, calm), true);
  assert.equal(ctx.guideBlocked('claude', false, null), false);
});
