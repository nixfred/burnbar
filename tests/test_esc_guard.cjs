// Esc contract, checked against the QML source because the compositor is not
// here. BurnPanel 2.3.1: the panel holds the keyboard Exclusive for the whole
// time it is open (Hyprland 0.56 hands an OnDemand layer's keys to the last
// window on any unmap), nothing re-primes in front of slurp, and the Esc close
// waits for the key release so the terminal underneath never gets a keyboard
// with Esc still held.
const fs = require("node:fs");
const path = require("node:path");
const assert = require("node:assert/strict");
const test = require("node:test");

const src = fs.readFileSync(path.join(__dirname, "..", "BurnPanel.qml"), "utf8");

test("the panel is Exclusive exactly while it is open", () => {
  assert.match(src, /WlrLayershell\.keyboardFocus:\s*panel\.opened\s*\?\s*WlrKeyboardFocus\.Exclusive\s*:\s*WlrKeyboardFocus\.None/);
});

test("nothing re-primes or counts other clients' layers any more", () => {
  for (const gone of ["refocusTimer", "foreignLayers", "beginFocusPrime", "focusPrimed", "layerEvent", "Quickshell.Hyprland"])
    assert.ok(!src.includes(gone), gone + " should be gone");
});

test("Esc closes on the release, with a bounded wait", () => {
  assert.match(src, /onCloseRequested:\s*\{[^}]*escHeld = true/);
  assert.match(src, /Keys\.onReleased:[\s\S]*Qt\.Key_Escape[\s\S]*releaseEsc\(\)/);
  assert.match(src, /Timer \{ id: escRelease; interval: 400; onTriggered: keyCatcher\.releaseEsc\(\) \}/);
  assert.match(src, /function releaseEsc\(\)[\s\S]*panel\.widget\.close\(\)/);
});
