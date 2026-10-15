"""Grok Bot app: the desktop app's own usage cache is a Grok limits source.

Ian, 2026-10-15: "I'm using grok bot but the usage doesn't show." Grok Bot
0.70.2 never writes ~/.grok/logs, so the billing-log reader found nothing and
the card said "Grok billing data unavailable" while the app itself had the
week's figure cached under ~/.config/Grok Bot/sand-client-persistence.
"""
import ast
import base64
import json
import re
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
KEY = "sand.client.slice.account.google-oauth2%7Cuser_X.weekly-usage.cache"


def load(store):
    tree = ast.parse((REPO / "bin" / "burnbar-collect").read_text())
    want_fn = {"grok_app_usage", "grok_limits_from_app", "grok_tier_from_app", "norm_percent"}
    want_const = {"MALFORMED"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<grok-app>", "exec"), ns)
    ns["GROK_APP_STORE"] = Path(store)
    return ns


def blob_name(key):
    return base64.b32encode(key.encode()).decode().rstrip("=").lower() + ".blob"


def write(store, key, usage, read_at=1792065157262):
    doc = {"schemaVersion": 2, "value": {"kind": "present", "reading": {"usage": usage, "readAtMs": read_at}}}
    (Path(store) / blob_name(key)).write_text(json.dumps(doc))


class GrokAppUsage(unittest.TestCase):
    def test_reads_weekly_percent_reset_and_plan(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, KEY, {"percentUsed": 3.149992, "nextResetMs": 1792525514809,
                           "grokPlanLabel": "Grok Bot Plan"})
            ns = load(d)
            limits, measured, status = ns["grok_limits_from_app"]()
            self.assertEqual(measured, 1792065157262)
            self.assertEqual(status, "")
            self.assertAlmostEqual(limits[0]["percent"], 0.03149992)
            self.assertTrue(limits[0]["resetsAt"].startswith("2026-10-20T19:45:14"))
            tier = ns["grok_tier_from_app"]()
            self.assertEqual((tier["label"], tier["short"]), ("Grok Bot Plan", "Grok Bot"))

    def test_missing_percent_is_unknown_not_zero(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, KEY, {"nextResetMs": 1792525514809})
            limits, _, _ = load(d)["grok_limits_from_app"]()
            self.assertEqual(limits[0]["percent"], -1.0)

    def test_other_slices_and_junk_are_ignored(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, "sand.client.slice.ui-layout", {"percentUsed": 99})
            (Path(d) / blob_name(KEY)).write_text("{not json")
            (Path(d) / "!!!.blob").write_text("{}")
            ns = load(d)
            self.assertEqual(ns["grok_limits_from_app"](), ([], 0, ""))
            self.assertEqual(ns["grok_tier_from_app"](), {})

    def test_no_store_is_quiet(self):
        ns = load("/nonexistent/grok-bot-store")
        self.assertEqual(ns["grok_limits_from_app"](), ([], 0, ""))

    def test_newest_account_reading_wins(self):
        with tempfile.TemporaryDirectory() as d:
            write(d, KEY, {"percentUsed": 10}, read_at=1000)
            write(d, KEY.replace("user_X", "user_Y"), {"percentUsed": 20}, read_at=2000)
            limits, measured, _ = load(d)["grok_limits_from_app"]()
            self.assertEqual((measured, limits[0]["percent"]), (2000, 0.2))


if __name__ == "__main__":
    unittest.main()
