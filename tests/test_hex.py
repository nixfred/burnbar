"""hex: a shared Ollama box this machine only calls over HTTP.

Its tokens arrive through local-usage.jsonl (the calling wrapper writes one line
per request), so they count toward the local lane and the offload share exactly
once. The collector also breaks them out as `hex`, and, only when told a URL,
asks the box which model is warm. Nothing here may need ssh, and an unreachable
box must cost one short timeout, never a missing lane.
"""
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
NOW_MS = 1_789_300_000_000

PS_BODY = {"models": [{
    "name": "gpt-oss:120b", "model": "gpt-oss:120b", "size": 64354684763, "size_vram": 64354684763,
    "context_length": 32768, "expires_at": "2026-11-03T02:48:48.377264528Z"}]}


def record(**fields):
    return json.dumps(fields) + "\n"


class FakeHex(BaseHTTPRequestHandler):
    hits = []
    status = 200
    body = PS_BODY
    usage = None

    def do_GET(self):
        FakeHex.hits.append(self.path)
        if self.path.startswith("/_meter/usage"):
            if FakeHex.usage is None:
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            body = FakeHex.usage
        else:
            body = {"version": "9.9.9"} if self.path == "/api/version" else FakeHex.body
        raw = json.dumps(body).encode()
        self.send_response(FakeHex.status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_args):
        pass


class HexTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.state = self.home / "state"
        self.out = self.state / "omarchy" / "burnbar"
        self.out.mkdir(parents=True)
        self.ledger = self.out / "local-usage.jsonl"
        FakeHex.hits, FakeHex.status, FakeHex.body, FakeHex.usage = [], 200, PS_BODY, None
        self.server = HTTPServer(("127.0.0.1", 0), FakeHex)
        self.url = "http://127.0.0.1:%d" % self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def collect(self, *args, now=NOW_MS):
        env = dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.state),
                   XDG_CACHE_HOME=str(self.home / "cache"), GROK_HOME=str(self.home / ".grok"),
                   BURNBAR_NOW_MS=str(now), BURNBAR_NO_LOCAL="1", NO_PROXY="127.0.0.1", no_proxy="127.0.0.1")
        for name in ("BURNBAR_LOCAL_LEDGER", "BURNBAR_HEX_URL", "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY"):
            env.pop(name, None)
        subprocess.run([sys.executable, str(REPO / "bin" / "burnbar-collect"), "--window", "360", *args],
                       env=env, check=True, capture_output=True, timeout=30)
        return json.loads((self.out / "history.json").read_text())

    def write_ledger(self):
        self.ledger.write_text(
            record(ts=NOW_MS - 60_000, source="hex", model="chat", prompt=900, output=300)
            + record(ts=NOW_MS - 30_000, source="hex", model="code", prompt=120, output=80)
            + record(ts=NOW_MS - 20_000, source="hex", prompt=10, output=0)
            + record(ts=NOW_MS - 10_000, source="npu", model="nomic", prompt=50, output=0)
            + record(ts=NOW_MS - 8 * 3600_000, source="hex", model="chat", prompt=999, output=1)
            + record(ts=NOW_MS, source="hex", model="chat", prompt=-4, output=1))

    def test_ledger_lines_are_hex_and_also_local_exactly_once(self):
        self.write_ledger()
        data = self.collect()
        hx = data["hex"]
        self.assertEqual(hx["total"], 1410)
        self.assertEqual(hx["turns"], 3)
        self.assertEqual(hx["split"]["input"], 1030)
        self.assertEqual(hx["split"]["output"], 380)
        self.assertEqual(hx["byModel"], {"chat": 1200, "code": 200, "hex": 10})
        # They are inside the local lane (which is what feeds the offload share) once,
        # alongside the NPU line that is not hex.
        self.assertEqual(data["local"]["total"], 1410 + 50)
        self.assertEqual(data["offloadShare"], 1.0)
        # The only burn on this machine is local, so hex is the whole of it minus the NPU line.
        self.assertAlmostEqual(hx["share"], 1410 / 1460)
        self.assertTrue(all("hex" in b for b in data["buckets"]))

    def test_speed_comes_only_from_timed_requests(self):
        self.ledger.write_text(
            record(ts=NOW_MS - 60_000, source="hex", model="chat", prompt=10, output=300, ms=10_000)
            + record(ts=NOW_MS - 50_000, source="hex", model="code", prompt=10, output=100, ms=5_000)
            + record(ts=NOW_MS - 40_000, source="hex", model="chat", prompt=10, output=999)      # untimed
            + record(ts=NOW_MS - 30_000, source="hex", model="chat", prompt=10, output=50, ms="slow"))
        hx = self.collect()["hex"]
        self.assertEqual(hx["tokPerSec"], 26.7)          # (300 + 100) tokens / 15 s
        self.assertEqual(hx["turns"], 4)

    def test_without_a_url_nothing_touches_the_network(self):
        self.write_ledger()
        box = self.collect()["hex"]["box"]
        self.assertEqual(box, {"configured": False, "online": False, "error": "", "at": 0, "loaded": []})
        self.assertEqual(FakeHex.hits, [])
        self.assertFalse((self.out / "hex-probe.json").exists())

    def test_non_http_url_is_ignored(self):
        self.collect("--hex-url", "file:///etc/passwd")
        self.collect("--hex-url", "hex:11434")
        self.assertEqual(FakeHex.hits, [])
        self.assertFalse(self.collect("--hex-url", "ftp://x")["hex"]["box"]["configured"])

    def test_probe_reads_what_is_warm_and_is_cached_for_thirty_seconds(self):
        box = self.collect("--hex-url", self.url)["hex"]["box"]
        self.assertTrue(box["configured"])
        self.assertTrue(box["online"])
        self.assertEqual(box["error"], "")
        self.assertEqual(len(box["loaded"]), 1)
        warm = box["loaded"][0]
        self.assertEqual((warm["name"], warm["vramGb"], warm["context"]), ("gpt-oss:120b", 64.4, 32768))
        # Nanosecond timestamps (Ollama writes nine fractional digits) must still parse.
        self.assertGreater(warm["expiresAt"], 1_700_000_000_000)
        self.assertEqual(FakeHex.hits, ["/api/ps", "/api/tags", "/api/version", "/_meter/usage?window=360&buckets=24"])
        self.collect("--hex-url", self.url, now=NOW_MS + 29_000)
        self.assertEqual(len(FakeHex.hits), 4, "a second run inside the TTL must not ask again")
        self.collect("--hex-url", self.url, now=NOW_MS + 31_000)
        self.assertEqual(FakeHex.hits[4:], ["/api/ps", "/_meter/usage?window=360&buckets=24"], "the installed list is only re-read every 10 minutes")

    def test_the_url_never_reaches_history_json(self):
        self.collect("--hex-url", self.url)
        self.assertNotIn(self.url, (self.out / "history.json").read_text())
        self.assertNotIn("127.0.0.1", (self.out / "history.json").read_text())

    def test_unreachable_box_is_offline_with_a_reason_and_the_counts_survive(self):
        self.write_ledger()
        dead = "http://127.0.0.1:1"
        data = self.collect("--hex-url", dead)
        box = data["hex"]["box"]
        self.assertTrue(box["configured"])
        self.assertFalse(box["online"])
        self.assertNotEqual(box["error"], "")
        self.assertEqual(box["loaded"], [])
        self.assertEqual(data["hex"]["total"], 1410)

    def test_http_error_and_garbage_bodies_are_offline_not_a_crash(self):
        FakeHex.status = 500
        box = self.collect("--hex-url", self.url)["hex"]["box"]
        self.assertFalse(box["online"])
        self.assertIn("500", box["error"])
        FakeHex.status, FakeHex.body = 200, "not an object"
        box = self.collect("--hex-url", self.url, now=NOW_MS + 60_000)["hex"]["box"]
        self.assertTrue(box["online"])
        self.assertEqual(box["loaded"], [])

    def test_hostile_models_list_is_bounded_and_sanitised(self):
        rows = [{"name": "m%d" % i, "size_vram": True, "context_length": -1, "expires_at": "nope"} for i in range(20)]
        rows += [None, 7, {"name": ""}, {"name": "x" * 500, "size_vram": 1e99}]
        FakeHex.body = {"models": rows}
        loaded = self.collect("--hex-url", self.url)["hex"]["box"]["loaded"]
        self.assertLessEqual(len(loaded), 8)
        for row in loaded:
            self.assertLessEqual(len(row["name"]), 64)
            self.assertEqual((row["vramGb"], row["context"], row["expiresAt"]), (0, 0, 0))

    def test_fleet_samples_what_any_client_made_resident(self):
        def warm(*names):
            FakeHex.body = {"models": [{"name": n, "size_vram": 10e9, "context_length": 1} for n in names]}
        warm("a")
        self.collect("--hex-url", self.url, now=NOW_MS)
        warm("a", "b")
        self.collect("--hex-url", self.url, now=NOW_MS + 40_000)      # b appeared: a swap
        warm("b")
        self.collect("--hex-url", self.url, now=NOW_MS + 80_000)
        warm()
        data = self.collect("--hex-url", self.url, now=NOW_MS + 120_000)
        fleet = data["hex"]["fleet"]
        self.assertEqual(fleet["samples"], 4)
        self.assertEqual(fleet["swaps"], 1)
        self.assertEqual(fleet["lastSwapAt"], NOW_MS + 40_000)
        self.assertEqual(fleet["peakGb"], 20.0)
        self.assertEqual(fleet["busyPct"], 75)
        self.assertEqual(fleet["residentGb"], 0)
        self.assertEqual(fleet["warmMs"], {"a": 40_000, "b": 80_000})
        self.assertEqual(max(b["hexGb"] for b in data["buckets"]), 20.0)
        self.assertEqual((fleet["installed"], fleet["version"]), (1, "9.9.9"))   # the fake answers /api/tags with its one-model list
        self.assertNotIn("inv", data["hex"]["box"])

    def test_a_meter_on_the_box_gives_every_clients_tokens(self):
        FakeHex.usage = {"v": 1, "now": 1, "total": {"requests": 40, "errors": 2, "prompt": 9000, "output": 3000},
                         "tokPerSec": 31.26, "inflight": 1, "lastAt": NOW_MS - 5000,
                         "byModel": {"chat": {"requests": 30, "tokens": 9000}, "code": {"requests": 10, "tokens": 3000}},
                         "byClient": {"a@x.com": {"requests": 25, "tokens": 8000}, "100.64.0.9": {"requests": 15, "tokens": 4000}}}
        data = self.collect("--hex-url", self.url)["hex"]
        self.assertEqual((data["all"]["requests"], data["all"]["prompt"], data["all"]["output"]), (40, 9000, 3000))
        self.assertEqual(data["all"]["tokPerSec"], 31.3)
        self.assertEqual(list(data["all"]["byClient"]), ["a@x.com", "100.64.0.9"])
        self.assertEqual(data["all"]["byModel"]["code"], {"tokens": 3000, "requests": 10})
        self.assertNotIn("usage", data["box"])
        # this machine's own ledger is untouched by it
        self.assertEqual(data["total"], 0)

    def test_plain_ollama_has_no_meter_and_that_is_not_an_error(self):
        data = self.collect("--hex-url", self.url)["hex"]
        self.assertEqual(data["all"], {})
        self.assertTrue(data["box"]["online"])

    def test_hostile_meter_output_is_bounded(self):
        FakeHex.usage = {"v": 1, "total": {"requests": -5, "prompt": True, "output": 1e99},
                         "byClient": {("c%d" % i): {"tokens": i, "requests": "x"} for i in range(50)}, "tokPerSec": "fast"}
        all_ = self.collect("--hex-url", self.url)["hex"]["all"]
        self.assertEqual((all_["requests"], all_["prompt"], all_["output"], all_["tokPerSec"]), (0, 0, 0, 0))
        self.assertEqual(len(all_["byClient"]), 6)
        FakeHex.usage = {"v": 2, "total": {}}
        self.assertEqual(self.collect("--hex-url", self.url, now=NOW_MS + 60_000)["hex"]["all"], {})

    def test_a_gap_between_samples_is_not_warm_time(self):
        FakeHex.body = {"models": [{"name": "a", "size_vram": 1e9}]}
        self.collect("--hex-url", self.url, now=NOW_MS)
        data = self.collect("--hex-url", self.url, now=NOW_MS + 30 * 60_000)    # burnbar was not running
        self.assertEqual(data["hex"]["fleet"]["warmMs"], {})

    def test_no_hex_traffic_leaves_an_empty_block_not_a_missing_one(self):
        data = self.collect()
        self.assertEqual(data["hex"]["total"], 0)
        self.assertEqual(data["hex"]["turns"], 0)
        self.assertEqual(data["hex"]["byModel"], {})
        self.assertEqual(data["hex"]["share"], 0)


if __name__ == "__main__":
    unittest.main()
