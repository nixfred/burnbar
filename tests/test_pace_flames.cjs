// The pace flames: where a subscription stands against an even spend, as one of
// three colours, with a margin that closes as the reset nears, and one flame per
// state. Extracts the pure helpers from BarWidget.qml and runs them as plain
// JavaScript against fixed clocks; it does not render QML.
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
for (const f of ['paceLive', 'paceMargin', 'paceFlameState', 'flameGroups']) vm.runInContext(extract(f), ctx);

const HOUR = 3600e3, WEEK = 7 * 24 * HOUR;
const NOW = 1_800_000_000_000;
// A weekly window `gone` of the way through with `used` of the plan spent.
const week = (used, gone) => ctx.paceLive(used, NOW + WEEK * (1 - gone), WEEK, NOW);
const state = (used, gone) => ctx.paceFlameState(week(used, gone));

test('the margin is fifteen points at the reset and closes to nothing at the rollover', () => {
  assert.equal(ctx.paceMargin(0), 0.15);
  assert.ok(Math.abs(ctx.paceMargin(0.5) - 0.075) < 1e-12);
  assert.equal(ctx.paceMargin(1), 0);
});

test('on the diagonal is a steady burn', () => {
  assert.equal(state(0.30, 0.30), 'steady');
  assert.equal(state(0.00, 0.00), 'steady');
});

test('above the margin is on fire, below it gone cold', () => {
  // Parker's live Claude week on 2026-10-14: 69% used with 29% gone.
  assert.equal(state(0.69, 0.293), 'fire');
  // Codex the same morning: 46% used with 16% gone.
  assert.equal(state(0.46, 0.161), 'fire');
  assert.equal(state(0.10, 0.50), 'cold');
});

test('one long session just after the reset stays on pace', () => {
  // Ten hours in, 13% used: seven points ahead, inside a margin of fourteen.
  assert.equal(state(0.13, 0.06), 'steady');
});

test('the same distance from the line is judged harder as the reset nears', () => {
  // Ten points under: on pace in the first half of the week, cold near the end.
  assert.equal(state(0.20, 0.30), 'steady');
  assert.equal(state(0.80, 0.90), 'cold');
  // Ten points over: on pace early, on fire late.
  assert.equal(state(0.40, 0.30), 'steady');
  assert.equal(state(0.95, 0.85), 'fire');
});

test('a spent plan is on fire even when the clock is nearly out', () => {
  assert.equal(state(1.0, 0.999), 'fire');
});

test('no reading is unknown, never a guess', () => {
  assert.equal(ctx.paceFlameState(null), 'unknown');
});

test('one flame per state, hot to cold, as big as its hardest burn', () => {
  const groups = ctx.flameGroups([
    { id: 'grok', state: 'cold', burn: 0 },
    { id: 'claude', state: 'fire', burn: 0.3 },
    { id: 'codex', state: 'fire', burn: 0.8 },
    { id: 'kimi', state: 'unknown', burn: 0.5 },
  ], '');
  assert.deepEqual(Array.from(groups, g => g.state), ['fire', 'cold', 'unknown']);
  assert.equal(groups[0].burn, 0.8);
  assert.deepEqual(Array.from(groups[0].ids), ['claude', 'codex']);
});

test('subscriptions that agree share one flame, so the box only appears when they differ', () => {
  const groups = ctx.flameGroups([
    { id: 'claude', state: 'fire', burn: 0.45 },
    { id: 'codex', state: 'fire', burn: 0.2 },
  ], '');
  assert.equal(groups.length, 1);
});

test('only the flame holding the named subscription pulses', () => {
  const groups = ctx.flameGroups([
    { id: 'claude', state: 'fire', burn: 0.6 },
    { id: 'codex', state: 'cold', burn: 0 },
  ], 'claude');
  assert.deepEqual(Array.from(groups, g => g.pulse), [true, false]);
  assert.ok(ctx.flameGroups([{ id: 'claude', state: 'fire', burn: 0 }], '').every(g => !g.pulse));
});

test('burn is clamped to the drawable range', () => {
  const [g] = ctx.flameGroups([{ id: 'claude', state: 'steady', burn: 7 }], '');
  assert.equal(g.burn, 1);
});

vm.runInContext(extract('burnNow'), ctx);

test('the burn does not drop to nothing on the half hour', () => {
  // A busy previous bucket, an empty new one, one minute into it.
  assert.ok(Math.abs(ctx.burnNow(0, 0.8, 1 / 30) - 0.8 * (29 / 30)) < 1e-12);
  // Half way through, the previous bucket counts for half.
  assert.equal(ctx.burnNow(0.1, 0.8, 0.5), 0.4);
  // A hotter current bucket always wins.
  assert.equal(ctx.burnNow(0.9, 0.8, 0.1), 0.9);
  // At the end of the bucket only the current one is left.
  assert.equal(ctx.burnNow(0.2, 0.8, 1), 0.2);
  // An unknown position in the bucket counts as its end, never as its start.
  assert.equal(ctx.burnNow(0.2, 0.8, NaN), 0.8);
});
