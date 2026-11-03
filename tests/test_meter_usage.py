"""The ollama-meter usage endpoint: one picture of every client of a shared box.

Runs the real meter in front of a fake Ollama, sends requests as different
clients, and reads /_meter/usage back. Records survive a restart, the endpoint is
answered by the meter and never forwarded, and the journal line burnbar's other
readers parse is unchanged.
"""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

METER = Path(__file__).resolve().parents[1] / "nano" / "ollama-meter.py"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeOllama(BaseHTTPRequestHandler):
    hits = []
    fail = False

    def do_GET(self):
        FakeOllama.hits.append(self.path)
        self.reply(200, {"models": []})

    def do_POST(self):
        FakeOllama.hits.append(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        req = json.loads(self.rfile.read(length) or b"{}")
        if FakeOllama.fail:
            return self.reply(500, {"error": "boom"})
        out = {"model": req.get("model"), "prompt_eval_count": 100, "eval_count": 40}
        if req.get("embed"):
            out = {"model": req.get("model"), "prompt_eval_count": 7}
        self.reply(200, out)

    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def log_message(self, *_a):
        pass


class MeterUsageTests(unittest.TestCase):
    def setUp(self):
        FakeOllama.hits, FakeOllama.fail = [], False
        self.tmp = tempfile.TemporaryDirectory()
        self.file = str(Path(self.tmp.name) / "usage.jsonl")
        self.up = HTTPServer(("127.0.0.1", 0), FakeOllama)
        threading.Thread(target=self.up.serve_forever, daemon=True).start()
        self.proc = None
        self.start()

    def start(self):
        self.port = free_port()
        env = dict(os.environ, METER_LISTEN="127.0.0.1:%d" % self.port,
                   METER_UPSTREAM="127.0.0.1:%d" % self.up.server_address[1],
                   METER_USAGE_FILE=self.file, PYTHONUNBUFFERED="1")
        self.proc = subprocess.Popen([sys.executable, str(METER)], env=env, stdout=subprocess.PIPE, text=True)
        self.proc.stdout.readline()          # "listening on ..."

    def stop(self):
        self.proc.terminate()
        self.proc.wait(5)

    def tearDown(self):
        self.stop()
        self.up.shutdown()
        self.up.server_close()
        self.tmp.cleanup()

    def post(self, model, client=None, path="/api/generate", **extra):
        headers = {"Content-Type": "application/json"}
        if client:
            headers["X-Forwarded-For"] = client
        req = urllib.request.Request("http://127.0.0.1:%d%s" % (self.port, path),
                                     data=json.dumps(dict(model=model, **extra)).encode(), headers=headers)
        try:
            urllib.request.urlopen(req, timeout=10).read()
        except urllib.error.HTTPError:
            pass

    def usage(self, query=""):
        with urllib.request.urlopen("http://127.0.0.1:%d/_meter/usage%s" % (self.port, query), timeout=10) as r:
            return json.loads(r.read())

    def test_every_client_is_counted_and_named(self):
        self.post("chat", client="100.64.0.1")
        self.post("chat", client="100.64.0.1")
        self.post("code", client="fred@example.com, 10.0.0.9")
        self.post("embed", client="100.64.0.2", path="/api/embed", embed=True)
        data = self.usage("?window=60&buckets=6")
        self.assertEqual(data["v"], 1)
        self.assertEqual(data["total"]["requests"], 4)
        self.assertEqual(data["total"]["prompt"], 307)
        self.assertEqual(data["total"]["output"], 120)
        self.assertEqual(data["byModel"]["chat"], {"requests": 2, "tokens": 280})
        self.assertEqual(data["byClient"]["100.64.0.1"], {"requests": 2, "tokens": 280})
        self.assertEqual(data["byClient"]["fred@example.com"]["requests"], 1)     # first X-Forwarded-For entry
        self.assertEqual(sum(b["requests"] for b in data["buckets"]), 4)
        self.assertEqual(len(data["buckets"]), 6)
        self.assertEqual(data["inflight"], 0)
        self.assertGreater(data["lastAt"], 0)

    def test_the_endpoint_is_answered_by_the_meter_not_forwarded(self):
        self.usage()
        self.assertEqual(FakeOllama.hits, [])
        self.post("chat", client="c")
        self.assertEqual(FakeOllama.hits, ["/api/generate"])

    def test_failures_are_errors_and_add_no_tokens(self):
        FakeOllama.fail = True
        self.post("chat", client="c")
        data = self.usage()
        self.assertEqual((data["total"]["requests"], data["total"]["errors"], data["total"]["output"]), (1, 1, 0))
        self.assertEqual(data["byModel"], {})

    def test_records_survive_a_restart(self):
        self.post("chat", client="c")
        self.stop()
        self.start()
        self.assertEqual(self.usage()["total"]["requests"], 1)

    def test_window_and_bucket_arguments_are_clamped_and_junk_is_ignored(self):
        self.post("chat", client="c")
        data = self.usage("?window=abc&buckets=-5")
        self.assertEqual(data["windowMin"], 1440)
        self.assertEqual(len(self.usage("?buckets=99999")["buckets"]), 240)
        self.assertEqual(self.usage("?window=0")["windowMin"], 1)

    def test_the_journal_line_is_unchanged(self):
        self.post("chat", client="c")
        line = ""
        for _ in range(20):                       # the meter logs after the response is relayed
            line = self.proc.stdout.readline()
            if line.startswith("meter "):
                break
        self.assertRegex(line, r"^meter ts=\d+ path=/api/generate model=chat status=200 prompt=100 eval=40 ms=\d+ client=127\.0\.0\.1$")


if __name__ == "__main__":
    unittest.main()
