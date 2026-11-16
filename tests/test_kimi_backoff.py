"""Kimi is asked for its quota and plan, not on every tick.

The collector runs every five seconds. Its Kimi refreshers only cached an
answer that carried something, so a plan whose /usages replies `{}` (nothing to
report) or a request that failed was asked for again on the very next tick:
a blocking call to api.kimi.com about 17,000 times a day, for a month, with the
cache file still dated the day the answers stopped. The attempt now leaves a
marker of its own and waits. The caches' measuredAt is the age of a figure and
is never refreshed by an attempt that produced none.
"""
import ast
import io
import json
import tempfile
import types
import unittest
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "bin" / "burnbar-collect").read_text()
NOW = 1_794_800_000_000


class FakeKimi:
    """Stands in for urllib.request: counts the requests that would have gone out."""
    def __init__(self):
        self.calls = []
        self.body = b"{}"
        self.error = None

    def urlopen(self, req, timeout=0):
        self.calls.append(req.full_url)
        if self.error:
            raise self.error
        return io.BytesIO(self.body)  # BytesIO is a context manager and has .read(n)

    def Request(self, url, headers=None):
        return types.SimpleNamespace(full_url=url, headers=headers or {})


def load(out_dir, fake):
    tree = ast.parse(SRC)
    want_fn = {"refresh_kimi_usage", "refresh_kimi_plan", "kimi_recently_tried", "kimi_note_try"}
    want_const = {"KIMI_USAGE_TTL_MS", "KIMI_PLAN_TTL_MS", "KIMI_RETRY_MS"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {"now_ms": NOW, "OUT_DIR": out_dir,
          "kimi_api_key": lambda: "test-key",
          "kimi_limits_from_usages": lambda raw: raw.get("rows", []),
          "clean_account": lambda v: str(v or "")}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<kimi>", "exec"), ns)
    # After the real imports, so the functions see the fake and not the network.
    ns["urllib"] = types.SimpleNamespace(
        request=types.SimpleNamespace(Request=fake.Request, urlopen=fake.urlopen),
        error=urllib.error)
    return ns


class KimiBackoffTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.out = Path(self.tmp.name)
        self.fake = FakeKimi()
        self.ns = load(self.out, self.fake)

    def ticks(self, fn, seconds, step=5):
        for s in range(0, seconds, step):
            self.ns["now_ms"] = NOW + s * 1000
            self.ns[fn]()

    # /usages ---------------------------------------------------------------
    def test_an_empty_answer_is_not_asked_again_every_tick(self):
        self.fake.body = b"{}"
        self.ticks("refresh_kimi_usage", 240)             # four minutes of ticks
        self.assertEqual(len(self.fake.calls), 1)
        self.assertFalse((self.out / "kimi-usage.json").exists(), "an empty answer caches nothing")

    def test_it_is_asked_again_once_the_wait_has_passed(self):
        self.ticks("refresh_kimi_usage", 240)
        self.ns["now_ms"] = NOW + self.ns["KIMI_RETRY_MS"] + 1000
        self.ns["refresh_kimi_usage"]()
        self.assertEqual(len(self.fake.calls), 2)

    def test_a_failed_request_waits_too(self):
        self.fake.error = urllib.error.URLError("unreachable")
        self.ticks("refresh_kimi_usage", 240)
        self.assertEqual(len(self.fake.calls), 1)

    def test_a_timeout_waits_too(self):
        self.fake.error = TimeoutError("slow")
        self.ticks("refresh_kimi_usage", 240)
        self.assertEqual(len(self.fake.calls), 1)

    def test_an_answer_with_quota_is_cached_and_clears_the_wait(self):
        self.fake.body = json.dumps({"rows": [{"label": "Session (5-hour)", "percent": 0.1,
                                               "resetsAt": "2026-11-17T00:00:00Z"}]}).encode()
        self.ns["refresh_kimi_usage"]()
        cached = json.loads((self.out / "kimi-usage.json").read_text())
        self.assertEqual(cached["measuredAt"], NOW)
        self.assertFalse((self.out / "kimi-usage.tried").exists())
        # Fresh for the TTL: no second request ...
        self.ns["now_ms"] = NOW + 60_000
        self.ns["refresh_kimi_usage"]()
        self.assertEqual(len(self.fake.calls), 1)
        # ... and a refresh when the TTL is up, not held back by the retry wait.
        self.ns["now_ms"] = NOW + self.ns["KIMI_USAGE_TTL_MS"] + 1000
        self.ns["refresh_kimi_usage"]()
        self.assertEqual(len(self.fake.calls), 2)

    def test_a_failed_ask_never_makes_an_old_figure_look_fresh(self):
        old = {"limits": [{"label": "Monthly (total)", "percent": 0.18}], "measuredAt": NOW - 99 * 86400_000}
        (self.out / "kimi-usage.json").write_text(json.dumps(old))
        self.fake.body = b"{}"
        self.ticks("refresh_kimi_usage", 60)
        self.assertEqual(json.loads((self.out / "kimi-usage.json").read_text()), old)

    def test_no_key_means_no_request_and_no_marker(self):
        self.ns["kimi_api_key"] = lambda: ""
        self.ticks("refresh_kimi_usage", 60)
        self.assertEqual(self.fake.calls, [])
        self.assertFalse((self.out / "kimi-usage.tried").exists())

    # /me -------------------------------------------------------------------
    def test_the_plan_lookup_backs_off_the_same_way(self):
        self.fake.error = urllib.error.URLError("unreachable")
        self.ticks("refresh_kimi_plan", 240)
        self.assertEqual(len(self.fake.calls), 1)

    def test_the_plan_is_cached_for_its_ttl_after_an_answer(self):
        self.fake.body = json.dumps({"user_level_name": "Free", "email": "a@example.com"}).encode()
        self.ticks("refresh_kimi_plan", 240)
        self.assertEqual(len(self.fake.calls), 1)
        self.assertEqual(json.loads((self.out / "kimi-plan.json").read_text())["tier"], "Free")

    def test_usage_and_plan_back_off_independently(self):
        """A quiet /usages must not hold back the plan lookup, or the reverse."""
        self.fake.body = b"{}"
        self.ns["refresh_kimi_usage"]()
        self.fake.body = json.dumps({"user_level_name": "Free"}).encode()
        self.ns["refresh_kimi_plan"]()
        self.assertEqual(len(self.fake.calls), 2)


if __name__ == "__main__":
    unittest.main()
