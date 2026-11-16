"""limit-samples.jsonl: one line per window per five minutes, read whole.

The pace maths keeps a history of every plan percentage in this file, and the
collector reads ALL of it and rewrites ALL of it on every tick (every five
seconds). So its size is the collector's CPU. In November 2026 it reached 40 MB
and 2.4 CPU-seconds a run (about half a core, round the clock), because Grok's
percentage had more than six decimals: the file stores six, the check compared
the stored figure with the raw one, called every tick "a change", and wrote 770
lines an hour for one window instead of 12. These tests pin the repairs: the
comparison, the self-heal of a file the old code poisoned, and not rewriting a
file that did not change.
"""
import ast
import datetime
import json
import os
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "bin" / "burnbar-collect").read_text()

SEC = 1000
MIN = 60 * SEC
DAY = 86400 * SEC
NOW = 1_794_800_000_000  # 2026-11-16 in UTC
FUTURE = (NOW + 5 * DAY) // MIN * MIN   # a window that has not reset yet (the collector stores resets to the minute)


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat()


def load(path):
    """The real sample functions, with the clock, the file and pace_for faked."""
    tree = ast.parse(SRC)
    want_fn = {"with_pace", "thin_samples", "load_samples", "save_samples",
               "write_atomic", "window_id", "parse_iso_ms"}
    want_const = {"SAMPLE_MAX_AGE_MS", "SAMPLE_MIN_GAP_MS", "FUTURE_SLACK_MS", "MALFORMED",
                  "SAMPLES_DIRTY"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"now_ms": NOW, "SAMPLES_FILE": path, "PACE": {"samples": {}, "next": []},
          "pace_for": lambda *a, **k: {}}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<samples>", "exec"), ns)
    return ns


def tick(ns, at, percent, resets=FUTURE, label="Weekly (7-day)", agent="grok"):
    """One collector run at time `at`: load, record, save, exactly as the script does."""
    ns["now_ms"] = at
    ns["PACE"]["samples"] = ns["load_samples"]()
    ns["PACE"]["next"] = []
    ns["with_pace"]({"limits": [{"label": label, "percent": percent, "resetsAt": iso(resets)}]}, agent)
    ns["save_samples"]()


def lines(path):
    return path.read_text().splitlines() if path.exists() else []


class LimitSamplesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "limit-samples.jsonl"
        self.ns = load(self.path)

    # The bug itself ---------------------------------------------------------
    def test_a_percentage_with_many_decimals_is_still_one_line_per_gap(self):
        """Grok's 93.2864123...% stored as 0.932864 must not look changed forever."""
        pct = 0.9328641234567
        for i in range(120):                       # ten minutes of five-second ticks
            tick(self.ns, NOW + i * 5 * SEC, pct)
        n = len(lines(self.path))
        self.assertLessEqual(n, 3, "10 min of ticks wrote %d lines; the gap is 5 min" % n)
        self.assertGreaterEqual(n, 2, "a new line is due once the five-minute gap has passed")

    def test_a_real_change_is_recorded_at_once(self):
        tick(self.ns, NOW, 0.5)
        tick(self.ns, NOW + 5 * SEC, 0.5)
        self.assertEqual(len(lines(self.path)), 1)
        tick(self.ns, NOW + 10 * SEC, 0.51)         # one point up, ten seconds later
        self.assertEqual(len(lines(self.path)), 2)

    def test_a_new_window_is_recorded_at_once(self):
        tick(self.ns, NOW, 0.5)
        tick(self.ns, NOW + 5 * SEC, 0.5, resets=FUTURE + 7 * DAY)
        self.assertEqual(len(lines(self.path)), 2)

    def test_a_window_that_has_already_reset_is_not_sampled(self):
        """Kimi's cached figures sat on a past reset for a month and kept adding lines."""
        tick(self.ns, NOW, 0.18, resets=NOW - DAY, label="Monthly (total)", agent="kimi")
        self.assertEqual(lines(self.path), [])

    # A file the old code poisoned heals itself ------------------------------
    def poisoned(self, n=2000):
        rows = [{"ts": NOW - (n - i) * 5 * SEC, "key": "grok|Weekly (7-day)",
                 "pct": 0.932864, "resets": FUTURE} for i in range(n)]
        # ... and a real change and a reset in the middle, which must survive.
        rows.append({"ts": NOW - 4 * SEC, "key": "grok|Weekly (7-day)", "pct": 0.94, "resets": FUTURE})
        rows.append({"ts": NOW - 2 * SEC, "key": "grok|Weekly (7-day)", "pct": 0.01,
                     "resets": FUTURE + 7 * DAY})
        self.path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        return len(rows)

    def test_a_poisoned_file_shrinks_to_the_intended_cadence(self):
        total = self.poisoned()
        self.ns["now_ms"] = NOW
        got = self.ns["load_samples"]()["grok|Weekly (7-day)"]
        self.assertTrue(self.ns["SAMPLES_DIRTY"], "the load should say the file needs rewriting")
        span_min = 2000 * 5 / 60
        self.assertLessEqual(len(got), span_min / 5 + 6, "kept %d of %d" % (len(got), total))
        pcts = [p for _, p, _ in got]
        self.assertIn(0.94, pcts, "a change inside the burst is information and stays")
        self.assertIn(0.01, pcts, "so does a window rollover")

    def test_the_heal_is_written_once_and_then_the_file_is_left_alone(self):
        self.poisoned()
        tick(self.ns, NOW, 0.01, resets=FUTURE + 7 * DAY)   # first run after the fix
        healed = len(lines(self.path))
        self.assertLess(healed, 100)
        before = self.path.read_bytes()
        ino = self.path.stat().st_ino
        tick(self.ns, NOW + 5 * SEC, 0.01, resets=FUTURE + 7 * DAY)   # next tick: nothing new
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.path.stat().st_ino, ino, "an unchanged file must not be rewritten")

    # Common case: nothing to write ------------------------------------------
    def test_a_healthy_file_is_not_thinned_or_marked_dirty(self):
        rows = [{"ts": NOW - (100 - i) * 5 * MIN, "key": "claude|Weekly (7-day)",
                 "pct": round(0.01 * (i % 50), 6), "resets": FUTURE} for i in range(100)]
        self.path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
        self.ns["now_ms"] = NOW
        got = self.ns["load_samples"]()["claude|Weekly (7-day)"]
        self.assertEqual(len(got), 100)
        self.assertFalse(self.ns["SAMPLES_DIRTY"])

    def test_a_quiet_tick_writes_nothing(self):
        tick(self.ns, NOW, 0.5)
        before, ino = self.path.read_bytes(), self.path.stat().st_ino
        tick(self.ns, NOW + 5 * SEC, 0.5)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(self.path.stat().st_ino, ino)

    def test_a_new_sample_is_appended_not_rewritten(self):
        tick(self.ns, NOW, 0.5)
        ino = self.path.stat().st_ino
        tick(self.ns, NOW + 10 * SEC, 0.6)
        self.assertEqual(len(lines(self.path)), 2)
        self.assertEqual(self.path.stat().st_ino, ino, "appending keeps the same file")

    def test_the_first_file_is_created_private_like_every_state_file(self):
        self.assertFalse(self.path.exists())
        tick(self.ns, NOW, 0.5)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_a_malformed_line_is_dropped_and_the_file_rewritten_clean(self):
        good = json.dumps({"ts": NOW - MIN, "key": "claude|Weekly (7-day)", "pct": 0.3, "resets": FUTURE})
        self.path.write_text(good + "\nthis is not json\n" + good.replace("0.3", "0.31") + "\n")
        tick(self.ns, NOW, 0.31, agent="claude")    # the same key as the rows above
        self.assertEqual(len(lines(self.path)), 2)
        for line in lines(self.path):
            json.loads(line)


if __name__ == "__main__":
    unittest.main()
