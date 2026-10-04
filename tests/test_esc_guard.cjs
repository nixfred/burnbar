// Esc must close the open panel, not reach the window under it. The panel takes
// the keyboard back when it loses it, except while another client's layer
// holds it (slurp, hyprpicker, the Omarchy menu). Extracts the pure layer
// bookkeeping from BurnPanel.qml and replays Hyprland's raw events through it;
// it does not render QML.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const panel = fs.readFileSync('BurnPanel.qml', 'utf8');
const ctx = {};
vm.createContext(ctx);

function extract(name) {
  const start = panel.indexOf('function ' + name + '(');
  assert.ok(start >= 0, 'expected to find function ' + name);
  let depth = 0, i = panel.indexOf('{', start);
  assert.ok(i > 0, 'no body for ' + name);
  for (let j = i; j < panel.length; j++) {
    if (panel[j] === '{') depth++;
    else if (panel[j] === '}') { depth--; if (depth === 0) return panel.slice(start, j + 1); }
  }
  throw new Error('unbalanced braces in ' + name);
}
vm.runInContext(extract('layerEvent'), ctx);

const passiveSrc = panel.match(/passiveLayers: (\[[^\]]*\])/);
assert.ok(passiveSrc, 'expected the passiveLayers list');
const PASSIVE = JSON.parse(passiveSrc[1].replace(/\s+/g, ' '));

// Feed a sequence of [name, data] events with the panel open (or not); return
// the final layer set and every event that asked for the keyboard back.
function replay(events, opened = true) {
  let layers = {};
  const reprimes = [];
  for (const [name, data] of events) {
    const next = ctx.layerEvent(layers, name, data, opened, PASSIVE);
    layers = next.layers;
    if (next.reprime) reprimes.push(name + '>>' + data);
  }
  return { layers: JSON.parse(JSON.stringify(layers)), reprimes };
}

test('a layer that never takes the keyboard no longer pins the guard', () => {
  // vic, 2026-10-04: an edge strip or a hot corner maps while the panel is up,
  // then the keyboard goes back to the Orca window under it.
  const r = replay([
    ['openlayer', 'LAN Mouse Sharing'],
    ['activewindowv2', '561791cf6c20'],
  ]);
  assert.deepEqual(r.layers, {});
  assert.deepEqual(r.reprimes, ['activewindowv2>>561791cf6c20']);
});

test('slurp keeps the keyboard until it closes, then the panel takes it back', () => {
  // Hyprland refuses every window while slurp's Exclusive layer is up, so no
  // activewindowv2 arrives in between; the guard holds until closelayer.
  const open = replay([['openlayer', 'selection']]);
  assert.deepEqual(open.layers, { selection: 1 });
  assert.deepEqual(open.reprimes, []);
  const closed = replay([['openlayer', 'selection'], ['closelayer', 'selection']]);
  assert.deepEqual(closed.layers, {});
  assert.deepEqual(closed.reprimes, ['closelayer>>selection']);
});

test('focus going to nothing is not a window taking the keys', () => {
  const r = replay([['openlayer', 'hyprpicker'], ['activewindowv2', '']]);
  assert.deepEqual(r.layers, { hyprpicker: 1 });
  assert.deepEqual(r.reprimes, []);
});

test('nothing happens while the panel is closed', () => {
  const r = replay([
    ['openlayer', 'selection'],
    ['activewindowv2', '561791cf6c20'],
    ['closelayer', 'selection'],
  ], false);
  assert.deepEqual(r.layers, {});
  assert.deepEqual(r.reprimes, []);
});

test("the shell's own layers are never counted", () => {
  for (const ns of ['omarchy-keyboard-panel', 'omarchy-keyboard-panel-dismiss', 'omarchy-bar',
    'omarchy-osd', 'omarchy-notifications']) {
    const r = replay([['openlayer', ns]]);
    assert.deepEqual(r.layers, {}, ns);
  }
});

test('a layer that was up before the panel opened is ignored when it closes', () => {
  const r = replay([['closelayer', 'selection']]);
  assert.deepEqual(r.layers, {});
  assert.deepEqual(r.reprimes, []);
});

test('one namespace on two outputs needs both closes', () => {
  const one = replay([['openlayer', 'selection'], ['openlayer', 'selection'], ['closelayer', 'selection']]);
  assert.deepEqual(one.layers, { selection: 1 });
  assert.deepEqual(one.reprimes, []);
  const both = replay([['openlayer', 'selection'], ['openlayer', 'selection'],
    ['closelayer', 'selection'], ['closelayer', 'selection']]);
  assert.deepEqual(both.layers, {});
  assert.deepEqual(both.reprimes, ['closelayer>>selection']);
});

test('unrelated events leave the same layer object, so nothing rebinds', () => {
  const layers = { selection: 1 };
  for (const name of ['workspace', 'activewindow', 'focusedmon', 'openwindow']) {
    const next = ctx.layerEvent(layers, name, 'x', true, PASSIVE);
    assert.equal(next.layers, layers, name);
    assert.equal(next.reprime, false, name);
  }
});

test('the Hyprland handler goes through layerEvent', () => {
  const handler = panel.slice(panel.indexOf('function onRawEvent('));
  assert.match(handler.slice(0, 400), /keyCatcher\.layerEvent\(/);
});
