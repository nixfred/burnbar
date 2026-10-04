"""Budget pace: am I over, and will I make it to the reset?

On budget means even pace across the window. These are the pure pieces of that
arithmetic, pulled out of the collector and run against fixed clocks, because
the interesting cases (a blown window, the first minute of a window, a reset
inside the rate samples) are exactly the ones that are awkward to reproduce by
waiting for real usage to happen.
"""
import ast
import datetime
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
HOUR = 3600_000
DAY = 86400_000
NOW = 1_789_900_000_000  # 2026-09-20 in UTC


def load(now_ms=NOW):
    """The pace helpers, with the module-level clock and sample store faked."""
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want_fn = {"window_ms_for", "recent_rate_per_hour", "pace_for", "parse_iso_ms",
               "local_midnight_ms", "norm_percent", "window_id", "burndown_series", "gift_reset_at"}
    want_const = {"RATE_WINDOW_MS", "RATE_WINDOW_SHARE", "RATE_MIN_SPAN_MS", "DAILY_MIN_WINDOW_MS",
                  "SAMPLE_MAX_AGE_MS", "FUTURE_SLACK_MS", "MALFORMED", "SERIES_MAX_POINTS",
                  "GIFT_MIN_DROP", "GIFT_ID_SLACK_MS"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign)
                and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"now_ms": now_ms, "PACE": {"samples": {}, "next": []}}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<pace>", "exec"), ns)
    return ns


def iso(ms):
    return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).isoformat()


class WindowLengthTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()

    def test_the_label_carries_the_length_when_the_provider_states_it(self):
        self.assertEqual(self.ns["window_ms_for"]("Session (5-hour)", NOW, 0), 5 * HOUR)
        self.assertEqual(self.ns["window_ms_for"]("Weekly (7-day)", NOW, 0), 7 * DAY)

    def test_a_month_is_the_calendar_month_before_the_reset_not_thirty_days(self):
        # Reset on 1 March 2027: the window that ends there began 1 February,
        # which is 28 days, not 30.
        march = int(datetime.datetime(2027, 3, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)
        self.assertEqual(self.ns["window_ms_for"]("Monthly (total)", march, 0), 28 * DAY)
        # And a leap February is 29.
        leap = int(datetime.datetime(2028, 3, 1, tzinfo=datetime.timezone.utc).timestamp() * 1000)
        self.assertEqual(self.ns["window_ms_for"]("Monthly (total)", leap, 0), 29 * DAY)

    def test_an_unlabelled_window_is_measured_from_the_previous_reset(self):
        self.assertEqual(self.ns["window_ms_for"]("Quota", NOW + DAY, NOW - 2 * DAY), 3 * DAY)

    def test_an_unlabelled_window_with_no_history_is_unknown_not_a_guess(self):
        self.assertEqual(self.ns["window_ms_for"]("Quota", NOW + DAY, 0), 0)


class RateTests(unittest.TestCase):
    def setUp(self):
        self.ns = load()

    def rate(self, points):
        return self.ns["recent_rate_per_hour"]([(t, p, 1) for t, p in points])

    def test_a_straight_line_is_its_slope_per_hour(self):
        r = self.rate([(NOW - 2 * HOUR, 0.10), (NOW - HOUR, 0.20), (NOW, 0.30)])
        self.assertAlmostEqual(r, 0.10, places=6)

    def test_one_sample_cannot_be_a_rate(self):
        self.assertIsNone(self.rate([(NOW, 0.4)]))

    def test_two_ticks_seconds_apart_cannot_be_a_rate(self):
        self.assertIsNone(self.rate([(NOW - 5_000, 0.40), (NOW, 0.41)]))

    def test_a_percentage_that_went_down_is_a_reset_not_a_negative_burn(self):
        self.assertIsNone(self.rate([(NOW - 2 * HOUR, 0.90), (NOW, 0.05)]))

    def test_samples_older_than_the_rate_window_are_not_part_of_the_rate(self):
        # The old point would halve the slope if it counted.
        r = self.rate([(NOW - 20 * HOUR, 0.0), (NOW - HOUR, 0.50), (NOW, 0.60)])
        self.assertAlmostEqual(r, 0.10, places=6)


class WindowIdTests(unittest.TestCase):
    """The jitter that stopped every rate from forming, 2026-09-20."""

    def test_the_same_window_stated_with_jitter_is_one_window(self):
        ns = load()
        base = NOW + 6 * DAY
        ids = {ns["window_id"](base + ms) for ms in (0, 53, 407, 828, 950)}
        self.assertEqual(len(ids), 1)

    def test_windows_a_minute_apart_stay_different(self):
        ns = load()
        base = NOW + 6 * DAY
        self.assertNotEqual(ns["window_id"](base), ns["window_id"](base + 60_000))


class ReviewFixTests(unittest.TestCase):
    """Defects an outside review (Grok 4.6 and Kimi k3, 2026-09-20) found and
    this file now holds shut."""

    def week(self, used, gone, rate_points=None):
        ns = load()
        resets = ns["window_id"](NOW + int(7 * DAY * (1 - gone)))
        if rate_points:
            ns["PACE"]["samples"]["claude|Weekly (7-day)"] = [(t, p, resets) for t, p in rate_points]
        row = {"label": "Weekly (7-day)", "percent": used, "resetsAt": iso(resets)}
        return ns["pace_for"](row, "claude|Weekly (7-day)", True)

    def test_an_on_pace_sub_is_not_told_to_stop_in_a_day(self):
        # Burning at exactly an even pace, today's share lasts about 24 hours.
        # "Stop in 23h" is not advice; only a stop that lands inside the day is.
        even = (1.0 / 7) / 24                      # share of the plan per hour
        p = self.week(0.50, 0.50, [(NOW - 2 * HOUR, 0.50 - 2 * even), (NOW, 0.50)])
        self.assertEqual(p["stopInMs"], -1)

    def test_a_fast_burn_still_gets_its_stop_time(self):
        p = self.week(0.30, 0.50, [(NOW - 2 * HOUR, 0.20), (NOW, 0.30)])   # 5%/h
        self.assertGreater(p["stopInMs"], 0)
        self.assertLess(p["stopInMs"], 24 * HOUR)


class GiftResetTests(unittest.TestCase):
    """Fred, 2026-10-01: a provider wipes the meter mid-week and the reset date
    stays where it was. The plan then has to last from the gift to the reset."""

    KEY = "claude|Weekly (7-day)"

    def pace(self, points, used, left=2 * DAY):
        ns = load()
        resets = ns["window_id"](NOW + left)
        ns["PACE"]["samples"][self.KEY] = [(t, p, resets) for t, p in points]
        row = {"label": "Weekly (7-day)", "percent": used, "resetsAt": iso(resets)}
        return ns["pace_for"](row, self.KEY, True), resets

    def test_a_wiped_meter_rebases_the_window_on_the_gift(self):
        gift = NOW - 3 * HOUR
        p, resets = self.pace([(NOW - DAY, 0.50), (gift - 5 * 60_000, 0.53), (gift, 0.0), (NOW - HOUR, 0.06)], 0.11)
        self.assertEqual(p["giftAt"], gift)
        self.assertEqual(p["windowMs"], resets - gift)
        self.assertEqual(p["fullWindowMs"], 7 * DAY)
        # 3 hours into a 51 hour budget is about 6% of the clock, not 71%.
        self.assertLess(p["elapsed"], 0.07)
        self.assertGreater(p["ratio"], 1.0)
        # The line starts at the gift: nothing from before it is drawn.
        self.assertTrue(all(y <= 0.11 + 1e-9 for _, y in p["series"]))

    def test_the_drop_is_seen_on_the_very_run_it_happens(self):
        p, _ = self.pace([(NOW - DAY, 0.50), (NOW - 5 * 60_000, 0.53)], 0.0)
        self.assertEqual(p["giftAt"], NOW)

    def test_a_restated_percent_is_not_a_gift(self):
        p, _ = self.pace([(NOW - DAY, 0.40), (NOW - HOUR, 0.41), (NOW - 30 * 60_000, 0.40)], 0.42)
        self.assertEqual(p["giftAt"], 0)
        self.assertEqual(p["windowMs"], 7 * DAY)

    def test_a_normal_rollover_is_not_a_gift(self):
        # Last week's 82% carries last week's reset, so it is another window.
        ns = load()
        resets = ns["window_id"](NOW + 6 * DAY)
        ns["PACE"]["samples"][self.KEY] = [(NOW - 2 * DAY, 0.82, resets - 7 * DAY), (NOW - DAY, 0.0, resets)]
        row = {"label": "Weekly (7-day)", "percent": 0.05, "resetsAt": iso(resets)}
        p = ns["pace_for"](row, self.KEY, True)
        self.assertEqual(p["giftAt"], 0)

    def test_today_is_counted_from_the_gift_not_from_midnight(self):
        # Midnight's 40% belongs to the plan that was wiped.
        gift = NOW - 2 * HOUR
        p, _ = self.pace([(NOW - 3 * DAY, 0.40), (gift - 60_000, 0.53), (gift, 0.0)], 0.11, left=3 * DAY)
        self.assertAlmostEqual(p["todayUsed"], 0.11)
        self.assertGreater(p["todayAllowance"], 0.3)


class BurndownSeriesTests(unittest.TestCase):
    """The line a 2.0 card draws: x is the window elapsed, y the plan spent."""

    def test_the_series_is_normalised_and_ends_on_the_present(self):
        ns = load()
        resets = ns["window_id"](NOW + 3 * DAY)
        window = 7 * DAY
        start = resets - window
        pts = [(start + DAY, 0.10, resets), (start + 2 * DAY, 0.25, resets)]
        s = ns["burndown_series"](pts, resets, window, 0.40)
        self.assertEqual(len(s), 3)
        self.assertAlmostEqual(s[0][0], 1 / 7, places=3)
        self.assertAlmostEqual(s[0][1], 0.10, places=5)
        # The last point is now, at the percentage the card's headline shows.
        self.assertAlmostEqual(s[-1][0], (NOW - start) / window, places=3)
        self.assertAlmostEqual(s[-1][1], 0.40, places=5)
        for x, y in s:
            self.assertTrue(0 <= x <= 1 and 0 <= y <= 1)

    def test_another_windows_samples_never_leak_into_this_line(self):
        ns = load()
        resets = ns["window_id"](NOW + 3 * DAY)
        older = resets - 7 * DAY
        pts = [(NOW - DAY, 0.90, older), (NOW - HOUR, 0.20, resets)]
        s = ns["burndown_series"](pts, resets, 7 * DAY, 0.22)
        self.assertEqual([round(p[1], 2) for p in s], [0.20, 0.22])

    def test_a_long_window_is_thinned_not_shipped_whole(self):
        ns = load()
        resets = ns["window_id"](NOW + DAY)
        window = 7 * DAY
        start = resets - window
        pts = [(start + i * 60_000 * 5, i / 2000.0, resets) for i in range(1, 1500)]
        s = ns["burndown_series"](pts, resets, window, 0.76)
        self.assertLessEqual(len(s), ns["SERIES_MAX_POINTS"])
        self.assertAlmostEqual(s[-1][1], 0.76, places=5)

    def test_no_samples_is_still_a_point_the_card_can_draw(self):
        ns = load()
        resets = ns["window_id"](NOW + 3 * DAY)
        s = ns["burndown_series"]([], resets, 7 * DAY, 0.05)
        self.assertEqual(len(s), 1)
        self.assertAlmostEqual(s[0][1], 0.05, places=5)


class PaceTests(unittest.TestCase):
    def row(self, pct, resets_ms, label="Weekly (7-day)"):
        return {"label": label, "percent": pct, "resetsAt": iso(resets_ms)}

    def test_on_pace_is_one(self):
        ns = load()
        # Half the week gone, half the allowance spent.
        p = ns["pace_for"](self.row(0.5, NOW + 3.5 * DAY), "claude|w", True)
        self.assertAlmostEqual(p["ratio"], 1.0, places=3)
        self.assertAlmostEqual(p["elapsed"], 0.5, places=3)

    def test_a_blown_window_reports_no_allowance_and_recovers_only_at_the_reset(self):
        ns = load()
        # Rounded, because a window is identified to the minute: providers
        # re-state the same reset with millisecond jitter.
        resets = ns["window_id"](NOW + 6 * DAY)
        p = ns["pace_for"](self.row(1.0, resets), "codex|w", True)
        self.assertGreater(p["ratio"], 1.0)
        self.assertEqual(p["allowancePerHour"], 0.0)
        # Nothing but time fixes 100%: back on pace exactly at the reset.
        self.assertEqual(p["backOnPaceAt"], resets)

    def test_half_spent_early_comes_back_on_pace_midway_through_the_window(self):
        ns = load()
        resets = ns["window_id"](NOW + 6 * DAY)
        p = ns["pace_for"](self.row(0.5, resets), "claude|w", True)
        self.assertGreater(p["ratio"], 1.0)
        # reset - L*(1-p) = reset - 3.5 days
        self.assertEqual(p["backOnPaceAt"], int(resets - 3.5 * DAY))

    def test_the_first_moments_of_a_window_hold_the_ratio_rather_than_divide_by_zero(self):
        ns = load()
        p = ns["pace_for"](self.row(0.01, NOW + 7 * DAY - 60_000), "claude|w", True)
        self.assertEqual(p["ratio"], -1)          # withheld, not infinite
        self.assertGreaterEqual(p["elapsed"], 0)  # but elapsed is still known

    def test_a_window_already_past_its_reset_carries_no_pace(self):
        ns = load()
        p = ns["pace_for"](self.row(0.4, NOW - HOUR), "claude|w", True)
        self.assertEqual(p["windowMs"], 0)
        self.assertEqual(p["ratio"], -1)

    def test_a_missing_percentage_carries_no_pace(self):
        ns = load()
        p = ns["pace_for"]({"label": "Weekly (7-day)", "percent": -1,
                            "resetsAt": iso(NOW + DAY)}, "claude|w", True)
        self.assertEqual(p["ratio"], -1)
        self.assertEqual(p["allowancePerHour"], -1)

    def test_a_snapshot_row_gets_a_ratio_but_never_a_rate(self):
        # Grok logs its figure once per launch: enough for "are you over",
        # never enough for "at this rate".
        ns = load()
        ns["PACE"]["samples"]["grok|w"] = [(NOW - 2 * HOUR, 0.10, 1), (NOW, 0.30, 1)]
        p = ns["pace_for"](self.row(0.30, NOW + 3.5 * DAY), "grok|w", False)
        self.assertGreater(p["ratio"], 0)
        self.assertEqual(p["ratePerHour"], -1)
        self.assertEqual(p["projected"], -1)

    def test_at_this_rate_projects_past_the_reset_and_names_the_dry_moment(self):
        ns = load()
        # Samples belong to a window by its rounded id, which is what lets a
        # rate form at all: keyed on the raw value, Claude's jitter put 56
        # different windows inside one second and no two samples ever matched.
        resets = ns["window_id"](NOW + 10 * HOUR)
        # 40% gone and burning 10 points an hour: 6 hours of headroom, 10 to go.
        ns["PACE"]["samples"]["claude|w"] = [
            (NOW - 2 * HOUR, 0.20, resets), (NOW - HOUR, 0.30, resets), (NOW, 0.40, resets)]
        p = ns["pace_for"](self.row(0.40, resets), "claude|w", True)
        self.assertAlmostEqual(p["ratePerHour"], 0.10, places=6)
        # 2 places, not 3: rounding the reset down to its minute shortens the
        # window by up to 60s, which moves the projection in the third decimal.
        self.assertAlmostEqual(p["projected"], 1.40, places=2)
        self.assertAlmostEqual((p["dryAt"] - NOW) / HOUR, 6.0, places=3)

    def test_a_rate_that_still_lands_inside_the_window_names_no_dry_moment(self):
        ns = load()
        resets = ns["window_id"](NOW + 10 * HOUR)
        ns["PACE"]["samples"]["claude|w"] = [
            (NOW - 2 * HOUR, 0.10, resets), (NOW, 0.12, resets)]
        p = ns["pace_for"](self.row(0.12, resets), "claude|w", True)
        self.assertLess(p["projected"], 1.0)
        self.assertEqual(p["dryAt"], 0)

    def test_a_five_hour_window_has_no_daily_budget(self):
        ns = load()
        p = ns["pace_for"](self.row(0.5, NOW + HOUR, "Session (5-hour)"), "claude|s", True)
        self.assertEqual(p["todayUsed"], -1)
        self.assertEqual(p["todayAllowance"], -1)
        self.assertFalse(p["overDaily"])

    def test_a_five_hour_window_gets_the_same_pace_and_dry_moment_as_the_week(self):
        # The 5-hour chip reads this block; there is no second pace for it.
        ns = load()
        resets = ns["window_id"](NOW + 2 * HOUR)
        # 3 hours into 5, 65% gone and burning 30 points an hour: dry in 70 min,
        # 50 min before the reset.
        ns["PACE"]["samples"]["claude|Session (5-hour)"] = [
            (NOW - HOUR, 0.35, resets), (NOW - HOUR / 2, 0.50, resets), (NOW, 0.65, resets)]
        p = ns["pace_for"](self.row(0.65, resets, "Session (5-hour)"), "claude|Session (5-hour)", True)
        self.assertEqual(p["windowMs"], 5 * HOUR)
        self.assertGreater(p["ratio"], 1.05)
        self.assertAlmostEqual(p["ratePerHour"], 0.30, places=6)
        self.assertAlmostEqual((p["dryAt"] - NOW) / HOUR, 7 / 6, places=3)
        self.assertLess(p["dryAt"], resets)

    def test_a_burst_on_a_five_hour_window_names_the_dry_moment_inside_fifteen_minutes(self):
        # 2026-10-03: the window nearly ran dry mid-work after a quiet spell. A
        # two-hour fit read the burst as a trickle; a tenth of the window does
        # not. 2.5h in at 50%, idle the previous 2h, then 80 points an hour.
        ns = load()
        key = "claude|Session (5-hour)"
        resets = ns["window_id"](NOW + 2.5 * HOUR)
        step = 5 * 60_000
        samples = [(NOW - k * step, 0.50, resets) for k in range(24, -1, -1)]
        first_dry = None
        for k in range(1, 7):
            at = NOW + k * step
            pct = 0.50 + 0.80 * (k * step / HOUR)
            samples.append((at, pct, resets))
            ns["now_ms"] = at
            ns["PACE"]["samples"][key] = list(samples)
            p = ns["pace_for"](self.row(pct, resets, "Session (5-hour)"), key, True)
            if p["dryAt"] > 0:
                first_dry = (at, p["dryAt"])
                break
        self.assertIsNotNone(first_dry, "no dry moment inside the burst")
        at, dry = first_dry
        self.assertLessEqual(at - NOW, 15 * 60_000)
        self.assertGreater(dry, at)
        self.assertLess(dry, resets)

    def test_a_week_keeps_the_two_hour_rate_fit(self):
        # Three hours of samples: flat for the first hour, then 2 points an
        # hour. A two-hour fit sees only the climb; anything longer would
        # drag the slope down, anything shorter is a different fit.
        ns = load()
        resets = ns["window_id"](NOW + 3 * DAY)
        step = 5 * 60_000
        pts = []
        for k in range(36, -1, -1):
            t = NOW - k * step
            pct = 0.30 if t <= NOW - 2 * HOUR else 0.30 + 0.02 * ((t - (NOW - 2 * HOUR)) / HOUR)
            pts.append((t, pct, resets))
        ns["PACE"]["samples"]["claude|w"] = pts
        p = ns["pace_for"](self.row(pts[-1][1], resets, "Weekly (7-day)"), "claude|w", True)
        self.assertEqual(p["windowMs"], 7 * DAY)
        self.assertAlmostEqual(p["ratePerHour"], 0.02, places=6)
        self.assertAlmostEqual(p["ratePerHour"], ns["recent_rate_per_hour"](pts), places=9)


if __name__ == "__main__":
    unittest.main()
