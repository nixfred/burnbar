"""Which account each subscription is signed in to.

Fred, 2026-10-13: "Some people run more than one subscription like me and I
want to see who im loggin in as." Every tool records its login in a file that
also holds the tokens that grant access to it. These tests pin both halves: the
label comes out, and nothing else does.
"""
import ast
import base64
import json
import os
import stat
import subprocess
import sys
import tempfile
import types
import unittest
import urllib.error
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = (REPO / "bin" / "burnbar-collect").read_text()

ACCESS = "ACCESS-TOKEN-SENTINEL-0123456789abcdef"
REFRESH = "REFRESH-TOKEN-SENTINEL-0123456789abcdef"
APIKEY = "sk-API-KEY-SENTINEL-0123456789abcdef"
SECRETS = (ACCESS, REFRESH, APIKEY)


def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")


def jwt(claims):
    return "eyJhbGciOiJub25lIn0." + b64(claims) + ".c2lnbmF0dXJl"


def load(home, state, now=1_000_000_000_000, urlopen=None):
    """The account readers from the collector, pointed at a scratch HOME."""
    tree = ast.parse(SRC)
    want_fn = {"clean_account", "read_json_object", "jwt_claims", "claude_account", "codex_account",
               "grok_account", "kimi_account", "safe_account", "refresh_kimi_plan",
               "kimi_recently_tried", "kimi_note_try"}
    want_const = {"ACCOUNT_MAX", "ACCOUNT_FILE_MAX", "KIMI_PLAN_TTL_MS", "KIMI_RETRY_MS"}
    body = [n for n in tree.body
            if isinstance(n, (ast.Import, ast.ImportFrom))
            or (isinstance(n, ast.FunctionDef) and n.name in want_fn)
            or (isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") in want_const)]
    ns = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), "<accounts>", "exec"), ns)
    ns.update(CLAUDE_ACCOUNT_FILE=home / ".claude.json", CODEX_AUTH_FILE=home / ".codex" / "auth.json",
              GROK_AUTH_FILE=home / ".grok" / "auth.json", OUT_DIR=state, now_ms=now,
              kimi_api_key=lambda: "kimi-key")
    if urlopen is not None:
        ns["urllib"] = types.SimpleNamespace(
            request=types.SimpleNamespace(Request=lambda url, headers=None: (url, headers), urlopen=urlopen),
            error=urllib.error)
    return ns


class Resp:
    def __init__(self, body):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, n=-1):
        return json.dumps(self.body).encode()


class Scratch(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.state = self.root / "state"
        (self.home / ".codex").mkdir(parents=True)
        (self.home / ".grok").mkdir(parents=True)
        self.state.mkdir()

    def put(self, rel, obj, raw=None):
        path = self.home / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(raw if raw is not None else json.dumps(obj))


class ClaudeTests(Scratch):
    def read(self):
        return load(self.home, self.state)["claude_account"]()

    def test_the_email_is_the_label(self):
        self.put(".claude.json", {"oauthAccount": {"emailAddress": "a@b.co", "displayName": "Ann"}})
        self.assertEqual(self.read(), ("a@b.co", ""))

    def test_the_default_personal_organisation_is_not_repeated(self):
        self.put(".claude.json", {"oauthAccount": {"emailAddress": "a@b.co",
                                                    "organizationName": "a@b.co's Organization"}})
        self.assertEqual(self.read(), ("a@b.co", ""))

    def test_a_real_organisation_is_the_detail(self):
        self.put(".claude.json", {"oauthAccount": {"emailAddress": "a@acme.io", "organizationName": "Acme Inc"}})
        self.assertEqual(self.read(), ("a@acme.io", "Acme Inc"))

    def test_the_name_stands_in_when_there_is_no_email(self):
        self.put(".claude.json", {"oauthAccount": {"displayName": "Ann"}})
        self.assertEqual(self.read(), ("Ann", ""))

    def test_signed_out_missing_and_broken_files_are_all_quiet(self):
        self.assertEqual(self.read(), ("", ""))                       # no file
        self.put(".claude.json", {"projects": {}})
        self.assertEqual(self.read(), ("", ""))                       # no oauthAccount
        self.put(".claude.json", {"oauthAccount": "nope"})
        self.assertEqual(self.read(), ("", ""))                       # wrong shape
        self.put(".claude.json", None, raw="{not json")
        self.assertEqual(self.read(), ("", ""))                       # corrupt
        self.put(".claude.json", None, raw="[1, 2]")
        self.assertEqual(self.read(), ("", ""))                       # not an object


class CodexTests(Scratch):
    def read(self):
        return load(self.home, self.state)["codex_account"]()

    def auth(self, claims, **extra):
        return dict({"auth_mode": "chatgpt", "OPENAI_API_KEY": None,
                     "tokens": {"id_token": jwt(claims), "access_token": ACCESS, "refresh_token": REFRESH,
                                "account_id": "acct"}}, **extra)

    def test_the_id_token_email_is_the_label(self):
        self.put(".codex/auth.json", self.auth({"email": "me@x.org", "name": "Me"}))
        self.assertEqual(self.read(), ("me@x.org", ""))

    def test_the_name_stands_in_when_the_token_has_no_email(self):
        self.put(".codex/auth.json", self.auth({"name": "Me Too"}))
        self.assertEqual(self.read(), ("Me Too", ""))

    def test_an_api_key_machine_says_so_instead_of_naming_an_account(self):
        self.put(".codex/auth.json", {"auth_mode": "apikey", "OPENAI_API_KEY": APIKEY})
        self.assertEqual(self.read(), ("API key", ""))

    def test_a_subscription_login_wins_over_a_stray_api_key(self):
        self.put(".codex/auth.json", self.auth({"email": "me@x.org"}, OPENAI_API_KEY=APIKEY))
        self.assertEqual(self.read(), ("me@x.org", ""))

    def test_garbage_tokens_are_quiet(self):
        for bad in (None, 7, "", "not.a.jwt", "a.%%%.c", "eyJ.eyJ.eyJ"):
            self.put(".codex/auth.json", {"tokens": {"id_token": bad}})
            self.assertEqual(self.read(), ("", ""), bad)
        self.put(".codex/auth.json", {"tokens": "nope"})
        self.assertEqual(self.read(), ("", ""))


class GrokTests(Scratch):
    def read(self):
        return load(self.home, self.state)["grok_account"]()

    def test_the_signed_in_email_is_the_label(self):
        self.put(".grok/auth.json", {"https://auth.x.ai::c1": {"email": "g@x.ai", "first_name": "G",
                                                                "create_time": "2026-10-13T15:00:00Z",
                                                                "refresh_token": REFRESH}})
        self.assertEqual(self.read(), ("g@x.ai", ""))

    def test_the_newest_login_wins_when_an_old_one_was_never_removed(self):
        self.put(".grok/auth.json", {
            "https://auth.x.ai::old": {"email": "old@x.ai", "create_time": "2026-09-01T00:00:00Z"},
            "https://auth.x.ai::new": {"email": "new@x.ai", "create_time": "2026-10-13T00:00:00Z"},
            "https://auth.x.ai::bad": "not an entry"})
        self.assertEqual(self.read(), ("new@x.ai", ""))

    def test_the_first_name_stands_in_and_nothing_else_does(self):
        self.put(".grok/auth.json", {"k": {"first_name": "Gee", "user_id": "u-123", "team_id": "t-9"}})
        self.assertEqual(self.read(), ("Gee", ""))
        self.put(".grok/auth.json", {"k": {"user_id": "u-123"}})
        self.assertEqual(self.read(), ("", ""))

    def test_missing_or_broken_is_quiet(self):
        self.assertEqual(self.read(), ("", ""))
        self.put(".grok/auth.json", None, raw="oops")
        self.assertEqual(self.read(), ("", ""))


class CleanTests(unittest.TestCase):
    def setUp(self):
        self.clean = load(Path("/nonexistent"), Path("/nonexistent"))["clean_account"]

    def test_one_printable_line(self):
        self.assertEqual(self.clean("  a@b.co \n"), "a@b.co")
        self.assertEqual(self.clean("a\x1b[31m@b.co"), "a[31m@b.co")

    def test_bidi_overrides_and_zero_width_marks_cannot_reorder_or_hide_the_label(self):
        self.assertEqual(self.clean("evil‮@moc.tset​"), "evil@moc.tset")

    def test_it_is_bounded_and_says_so(self):
        out = self.clean("x" * 500)
        self.assertEqual(len(out), 80)
        self.assertTrue(out.endswith("…"))

    def test_not_a_string_is_nothing(self):
        for v in (None, 5, ["a"], {"a": 1}, b"bytes"):
            self.assertEqual(self.clean(v), "")


class KimiTests(Scratch):
    ME = {"user_id": "u", "nickname": "Nick", "email": "k@x.ai", "user_level_name": "Max",
          "phone": {"number": "140****8305"}}

    def run_refresh(self, plan=None, me=None, fail=False, now=1_000_000_000_000):
        calls = []

        def urlopen(req, timeout=0):
            calls.append(req)
            if fail:
                raise urllib.error.URLError("down")
            return Resp(me if me is not None else self.ME)

        ns = load(self.home, self.state, now=now, urlopen=urlopen)
        if plan is not None:
            (self.state / "kimi-plan.json").write_text(json.dumps(plan))
        ns["refresh_kimi_plan"]()
        return ns, calls

    def saved(self):
        return json.loads((self.state / "kimi-plan.json").read_text())

    def test_me_names_the_key_owner_and_nothing_private_is_kept(self):
        ns, calls = self.run_refresh()
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.saved(), {"tier": "Max", "account": "k@x.ai", "measuredAt": 1_000_000_000_000})
        self.assertNotIn("8305", (self.state / "kimi-plan.json").read_text())
        self.assertEqual(ns["kimi_account"](), ("k@x.ai", ""))

    def test_the_nickname_stands_in_when_there_is_no_email(self):
        self.run_refresh(me={"nickname": "Nick", "user_level_name": "Max"})
        self.assertEqual(self.saved()["account"], "Nick")

    def test_a_record_from_before_accounts_existed_is_refreshed_once(self):
        now = 1_000_000_000_000
        ns, calls = self.run_refresh(plan={"tier": "Max", "measuredAt": now - 60_000}, now=now)
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.saved()["account"], "k@x.ai")

    def test_a_fresh_record_is_not_asked_for_again(self):
        now = 1_000_000_000_000
        ns, calls = self.run_refresh(plan={"tier": "Max", "account": "k@x.ai", "measuredAt": now - 60_000}, now=now)
        self.assertEqual(calls, [])

    def test_an_answer_with_no_account_is_remembered_so_it_is_not_asked_every_tick(self):
        now = 1_000_000_000_000
        self.run_refresh(me={"user_level_name": "Max"}, now=now)
        self.assertEqual(self.saved()["account"], "")
        ns, calls = self.run_refresh(me={"user_level_name": "Max"}, now=now + 60_000)
        self.assertEqual(calls, [])

    def test_a_dead_network_leaves_the_old_record_alone(self):
        old = {"tier": "Max", "measuredAt": 1}
        ns, calls = self.run_refresh(plan=old, fail=True)
        self.assertEqual(self.saved(), old)
        self.assertEqual(ns["kimi_account"](), ("", ""))

    def test_a_reply_that_is_not_an_object_is_quiet(self):
        self.run_refresh(me=["not", "an", "object"])
        self.assertFalse((self.state / "kimi-plan.json").exists())


class CollectorEndToEndTests(Scratch):
    """The real collector, a scratch HOME, and a hunt for anything secret."""

    def setUp(self):
        super().setUp()
        self.env = dict(os.environ, HOME=str(self.home), GROK_HOME=str(self.home / ".grok"),
                        XDG_STATE_HOME=str(self.state), XDG_CACHE_HOME=str(self.root / "cache"),
                        BURNBAR_NOW_MS="1790000000000", BURNBAR_EXTRA_HOMES="")
        self.env.pop("KIMI_API_KEY", None)

    def collect(self):
        p = subprocess.run([sys.executable, str(REPO / "bin" / "burnbar-collect"), "--no-local", "--print"],
                           env=self.env, capture_output=True, text=True, check=True, timeout=60)
        return json.loads(p.stdout), p

    def signed_in_everywhere(self):
        self.put(".claude.json", {"oauthAccount": {"emailAddress": "claude@one.io", "organizationName": "Acme"},
                                  "projects": {"/x": {"history": ["a" * 40] * 50}}})
        self.put(".codex/auth.json", {"auth_mode": "chatgpt", "OPENAI_API_KEY": None, "tokens": {
            "id_token": jwt({"email": "codex@two.io"}), "access_token": ACCESS, "refresh_token": REFRESH}})
        self.put(".grok/auth.json", {"https://auth.x.ai::c": {"email": "grok@three.io", "refresh_token": REFRESH,
                                                               "key": jwt({"sub": "s", "tier": 5}),
                                                               "create_time": "2026-10-13T00:00:00Z"}})

    def test_every_signed_in_tool_is_named(self):
        self.signed_in_everywhere()
        d, _ = self.collect()
        self.assertEqual((d["claude"]["accountLabel"], d["claude"]["accountDetail"]), ("claude@one.io", "Acme"))
        self.assertEqual(d["codex"]["accountLabel"], "codex@two.io")
        self.assertEqual(d["grok"]["accountLabel"], "grok@three.io")
        self.assertEqual((d["kimi"]["accountLabel"], d["zcode"]["accountLabel"]), ("", ""))

    def test_the_shape_is_the_same_when_nobody_is_signed_in(self):
        d, _ = self.collect()
        for agent in ("claude", "codex", "grok", "kimi", "zcode"):
            self.assertEqual((d[agent]["accountLabel"], d[agent]["accountDetail"]), ("", ""), agent)

    def test_no_secret_reaches_the_output_the_state_directory_or_stderr(self):
        self.signed_in_everywhere()
        d, p = self.collect()
        haystacks = [p.stdout, p.stderr]
        for f in (self.state / "omarchy" / "burnbar").glob("*"):
            if f.is_file():
                haystacks.append(f.read_text(errors="replace"))
        for text in haystacks:
            for secret in SECRETS:
                self.assertNotIn(secret, text)
            self.assertNotIn("eyJ", text)

    def test_the_history_file_that_now_holds_an_email_is_private_to_the_user(self):
        self.signed_in_everywhere()
        self.collect()
        mode = stat.S_IMODE((self.state / "omarchy" / "burnbar" / "history.json").stat().st_mode)
        self.assertEqual(mode & 0o077, 0, oct(mode))

    def test_a_hostile_display_name_arrives_as_plain_text(self):
        self.put(".claude.json", {"oauthAccount": {"displayName": "Ann‮\nDROP\x1b[2J"}})
        d, _ = self.collect()
        label = d["claude"]["accountLabel"]
        self.assertTrue(label.isprintable(), repr(label))
        self.assertNotIn("\n", label)

    def test_a_corrupt_login_file_never_costs_the_collection(self):
        self.put(".claude.json", None, raw="{broken")
        self.put(".codex/auth.json", None, raw="\x00\x01")
        d, _ = self.collect()
        self.assertEqual(d["claude"]["accountLabel"], "")
        self.assertIn("total", d["claude"])


if __name__ == "__main__":
    unittest.main()
