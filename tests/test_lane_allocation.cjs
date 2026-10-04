// Evaluate the actual QML bindings for every visible subset. No live renderer.
const { test } = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const qml = fs.readFileSync('BarWidget.qml', 'utf8');
const agents = ['Claude', 'Codex', 'Grok', 'Kimi', 'Zcode'];
function bindings(source, ctx) {
  for (const match of source.matchAll(/readonly property (?:real|int|bool) (\w+): ([\s\S]*?)(?=\n\s*(?:readonly property|\/\/)|$)/g)) {
    ctx[match[1]] = vm.runInNewContext(match[2], ctx);
  }
}
function layout(mask, width, local, gauges) {
  const root = { showLocal: local, showGauges: gauges };
  agents.forEach((a, i) => root['show' + a] = Boolean(mask & (1 << i)));
  for (const name of ['cloudAgents', 'grokExtra', 'grokAsRight', 'grokAsLeft', 'kimiExtra', 'zcodeExtra']) {
    const expr = qml.match(new RegExp('readonly property (?:int|bool) ' + name + ': ([^\\n]+)'))[1];
    root[name] = vm.runInNewContext(expr, root);
  }
  const ctx = { root, width, Style: { space: n => n } };
  ctx.graph = ctx;
  bindings(qml.slice(qml.indexOf('      readonly property int gaugeWidth:'),
                     qml.indexOf('      // Zone spans')), ctx);
  return ctx;
}

test('every nonempty cloud subset fits with local and gauges toggled', () => {
  for (let mask = 1; mask < 32; mask++) {
    for (const width of [110, 150, 300, 600]) {
      for (const local of [false, true]) for (const gauges of [false, true]) {
        const ctx = layout(mask, width, local, gauges);
        let sum = 0;
        agents.forEach((a, i) => {
          const w = ctx[a.toLowerCase() + 'LaneWidth'];
          assert.ok(Number.isFinite(w), a);
          assert.ok(mask & (1 << i) ? w > 0 : w === 0, a);
          sum += w;
        });
        assert.ok(Math.abs(sum - ctx.inner) < 1e-8,
                  `mask=${mask}, width=${width}, local=${local}, gauges=${gauges}: ${sum} != ${ctx.inner}`);
        const occupied = sum + ctx.localWidth + ctx.ruleWidth + ctx.gaugesSpace
          + ctx.dividerSpace + ctx.grokSepSpace + ctx.kimiSepSpace + ctx.zcodeSepSpace;
        assert.ok(Math.abs(occupied - width) < 1e-8);
      }
    }
  }
});

test('Codex + Kimi + Zcode shares a 300px strip in thirds', () => {
  const c = layout(2 | 8 | 16, 300, false, false);
  assert.equal(c.codexLaneWidth, 100);
  assert.equal(c.kimiLaneWidth, 100);
  assert.equal(c.zcodeLaneWidth, 100);
});

test('Claude/Codex pair keeps narrow added lanes', () => {
  const c = layout(31, 300, false, false);
  assert.equal(c.claudeLaneWidth, c.codexLaneWidth);
  assert.ok(c.grokLaneWidth < c.claudeLaneWidth);
  assert.equal(c.grokLaneWidth, c.kimiLaneWidth);
  assert.equal(c.kimiLaneWidth, c.zcodeLaneWidth);
});
