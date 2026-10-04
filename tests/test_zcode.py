"""Exercise Zcode identity and retention through the real collector/cache."""
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[1]


class ZcodeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root / 'home'
        self.rollout = self.home / '.zcode/cli/rollout/model-io-test.jsonl'
        self.rollout.parent.mkdir(parents=True)
        self.now = int(time.time() * 1000)
        self.env = dict(os.environ, HOME=str(self.home),
                        GROK_HOME=str(self.home / '.grok'),
                        XDG_STATE_HOME=str(self.root / 'state'),
                        XDG_CACHE_HOME=str(self.root / 'cache'),
                        BURNBAR_NOW_MS=str(self.now), BURNBAR_EXTRA_HOMES='')
        self.env.pop('KIMI_API_KEY', None)
        self.cache = self.root / 'state/omarchy/burnbar/scan-cache.json'

    def row(self, rid='request-1'):
        return {'requestId': rid,
                'completedAt': datetime.datetime.fromtimestamp(
                    self.now / 1000, datetime.timezone.utc).isoformat(),
                'model': {'modelId': 'glm-test'},
                'response': {'usage': {'inputTokens': 400, 'outputTokens': 150,
                                       'cacheReadTokens': 300, 'cacheWriteTokens': 50}}}

    def write(self, rows, path=None):
        (path or self.rollout).write_text(''.join(json.dumps(r) + '\n' for r in rows))

    def collect(self, now=None):
        env = dict(self.env, BURNBAR_NOW_MS=str(self.now if now is None else now))
        p = subprocess.run([sys.executable, str(REPO / 'bin/burnbar-collect'),
                            '--no-local', '--window', '360', '--print'],
                           env=env, capture_output=True, text=True, check=True, timeout=30)
        return json.loads(p.stdout), p.stderr

    def test_unusable_ids_never_count_and_warn_once_across_polls(self):
        missing = self.row()
        del missing['requestId']
        self.write([missing] + [self.row(rid) for rid in
                               [None, '', '  ', 42, True, [], {}, 'bad\nid']])
        for poll in range(3):
            d, err = self.collect()
            self.assertEqual((d['zcode']['total'], d['zcode']['turns']), (0, 0))
            self.assertEqual(err.count('unusable requestId'), 1 if poll == 0 else 0)
            self.assertEqual(json.loads(self.cache.read_text())['files'][str(self.rollout)]['points'], [])

    def test_long_ids_and_duplicates_survive_polls_append_rewrite_and_delete(self):
        a, b = self.row('x' * 64 + 'a'), self.row('x' * 64 + 'b')
        self.write([a, b, a])
        for _ in range(3):
            d, _ = self.collect()
            self.assertEqual((d['zcode']['total'], d['zcode']['turns']), (500, 2))
        with self.rollout.open('a') as f:
            f.write(json.dumps(b) + '\n')
        self.assertEqual(self.collect()[0]['zcode']['total'], 500)
        self.write([b])
        self.assertEqual(self.collect()[0]['zcode']['total'], 500)
        self.rollout.unlink()
        self.assertEqual(self.collect()[0]['zcode']['total'], 500)
        self.assertEqual(self.collect(self.now + 6 * 3600_000 + 1)[0]['zcode']['total'], 0)
        self.collect(self.now + 25 * 3600_000 + 1)
        self.assertNotIn(str(self.rollout), json.loads(self.cache.read_text())['files'])

    def test_legacy_cache_is_rescanned_and_deleted_legacy_entries_are_dropped(self):
        self.write([self.row('x' * 64 + 'a'), self.row('x' * 64 + 'b')])
        self.collect()
        cached = json.loads(self.cache.read_text())
        entry = cached['files'][str(self.rollout)]
        entry.pop('zcodeIdentityVersion', None)
        entry['points'] = [[self.now, 250, '', 'glm-test', [50, 50, 150, 300]],
                           [self.now, 250, 'x' * 64, 'glm-test', [50, 50, 150, 300]]]
        cached['files'][str(self.rollout.with_name('model-io-deleted.jsonl'))] = dict(entry)
        self.cache.write_text(json.dumps(cached))
        for _ in range(3):
            d, _ = self.collect()
            self.assertEqual((d['zcode']['total'], d['zcode']['turns']), (500, 2))
        self.assertNotIn(str(self.rollout.with_name('model-io-deleted.jsonl')),
                         json.loads(self.cache.read_text())['files'])

    def test_duplicates_across_files_and_bad_warm_cache_ids(self):
        self.write([self.row()])
        other = self.rollout.with_name('model-io-copy.jsonl')
        self.write([self.row()], other)
        self.assertEqual(self.collect()[0]['zcode']['total'], 250)
        cached = json.loads(self.cache.read_text())
        for entry in cached['files'].values():
            point = entry['points'][0]
            entry['points'] += [point[:2] + [rid] + point[3:]
                                for rid in ['', None, [], {}, 42]]
        self.cache.write_text(json.dumps(cached))
        other.unlink()
        for _ in range(3):
            self.assertEqual(self.collect()[0]['zcode']['total'], 250)
        for entry in json.loads(self.cache.read_text())['files'].values():
            self.assertEqual(len(entry['points']), 1)

    def test_extra_home_cannot_enable_any_cloud_lane(self):
        other = self.root / 'other'
        ts = self.row()['completedAt']
        fixtures = {
            '.claude/projects/p/session.jsonl': {
                'timestamp': ts, 'message': {'id': 'remote', 'model': 'claude-test',
                                             'usage': {'output_tokens': 700}}},
            '.codex/sessions/rollout-test.jsonl': {
                'timestamp': ts, 'payload': {'type': 'token_count', 'info': {
                    'total_token_usage': {'input_tokens': 100, 'output_tokens': 20}}}},
            '.grok/sessions/s/updates.jsonl': {'timestamp': self.now},
            '.zcode/cli/rollout/model-io-test.jsonl': self.row(),
        }
        for name, row in fixtures.items():
            path = other / name
            path.parent.mkdir(parents=True)
            self.write([row], path)
        for value in [str(other), '~burnbar_nonexistent_test_user']:
            self.env['BURNBAR_EXTRA_HOMES'] = value
            d, _ = self.collect()
            for agent in ['claude', 'codex', 'grok', 'zcode']:
                self.assertEqual(d[agent]['total'], 0, agent)
                self.assertFalse(d['presence'][agent], agent)

    def test_extra_home_is_ignored_even_with_cached_usage(self):
        mirror = self.root / 'other/.zcode/cli/rollout/model-io-mirror.jsonl'
        mirror.parent.mkdir(parents=True)
        self.write([self.row()], mirror)
        self.env['BURNBAR_EXTRA_HOMES'] = str(self.root / 'other')
        self.write([self.row('local')])
        self.collect()
        cached = json.loads(self.cache.read_text())
        cached['files'][str(mirror)] = cached['files'][str(self.rollout)]
        self.cache.write_text(json.dumps(cached))
        self.rollout.unlink()
        d, _ = self.collect()
        self.assertEqual(d['zcode']['total'], 250)
        self.assertNotIn(str(mirror), json.loads(self.cache.read_text())['files'])


if __name__ == '__main__':
    unittest.main()
