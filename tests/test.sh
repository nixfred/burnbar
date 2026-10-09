#!/usr/bin/env bash
# Burn Bar test suite. Mirrors the shape used by other Omarchy plugins: validate
# the manifest, assert the contract the shell relies on, then exercise the
# collector against a synthetic fixture so the test never depends on whatever
# transcripts happen to be on the machine.

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok  $*"; }

echo "== manifest =="
omarchy plugin validate "$repo_dir"
ok "omarchy plugin validate"

jq -e '
  .schemaVersion == 1 and
  .id == "nixfred.burnbar" and
  (.kinds | index("service")) != null and
  (.kinds | index("bar-widget")) != null and
  .entryPoints.service == "Service.qml" and
  .entryPoints.barWidget == "BarWidget.qml" and
  .barWidget.allowMultiple == false and
  .barWidget.defaultSection == "center" and
  .barWidget.defaults.showLocal == true and
  (.barWidget.schema | map(.key) | index("localThreshold")) != null and
  (.barWidget.schema | map(.key) | index("ollamaUrl")) != null and
  (.barWidget.schema | map(.key) | index("localHost")) != null and
  (.barWidget.schema | map(.key) | index("meterUnit")) != null and
  (.barWidget.schema | map(.key) | index("ollamaUnit")) == null
' manifest.json >/dev/null || fail "manifest contract"
ok "manifest contract"

# The widget draws exactly one cell per bucket and aligns to the newest bucket.
# It reads the count from the service; the only thing that can drift is the
# fallback clamp each file carries for the moment before they bind, so both
# clamps must be byte-identical and agree with the manifest's default and
# range. (bars: 0 used to be 12 in the widget and 6 in the service.)
clamp() { grep -oP "boundedInt\(\"$1\", [0-9, ]+\)" "$2" | head -1 || true; }
man_bars=$(jq -r '.barWidget.defaults.bars' manifest.json)
man_bars_min=$(jq -r '.barWidget.schema[] | select(.key=="bars") | .min' manifest.json)
man_bars_max=$(jq -r '.barWidget.schema[] | select(.key=="bars") | .max' manifest.json)
qml_clamp=$(clamp bars BarWidget.qml); svc_clamp=$(clamp bars Service.qml)
[ -n "$qml_clamp" ] && [ "$qml_clamp" = "$svc_clamp" ] || fail "bars clamp differs: widget '$qml_clamp' vs service '$svc_clamp'"
[ "$svc_clamp" = "boundedInt(\"bars\", $man_bars, $man_bars_min, $man_bars_max)" ] || fail "bars clamp '$svc_clamp' != manifest ($man_bars, $man_bars_min..$man_bars_max)"
grep -q 'svc ? svc.bucketCount' BarWidget.qml || fail "widget must take its cell count from the service"
ok "cell count == bucket count ($man_bars, clamp $man_bars_min..$man_bars_max)"

# Same trap on the local lane: the widget draws localCells cells, the service
# keeps a ring localCells long. Drift and the oldest sample is drawn as zero.
man_local=$(jq -r '.barWidget.defaults.localCells' manifest.json)
man_local_min=$(jq -r '.barWidget.schema[] | select(.key=="localCells") | .min' manifest.json)
man_local_max=$(jq -r '.barWidget.schema[] | select(.key=="localCells") | .max' manifest.json)
qml_lclamp=$(clamp localCells BarWidget.qml); svc_lclamp=$(clamp localCells Service.qml)
[ -n "$qml_lclamp" ] && [ "$qml_lclamp" = "$svc_lclamp" ] || fail "localCells clamp differs: widget '$qml_lclamp' vs service '$svc_lclamp'"
[ "$svc_lclamp" = "boundedInt(\"localCells\", $man_local, $man_local_min, $man_local_max)" ] || fail "localCells clamp '$svc_lclamp' != manifest"
grep -q 'svc ? svc.localCells' BarWidget.qml || fail "widget must take its local cell count from the service"
ok "local cell count == local ring length ($man_local, clamp $man_local_min..$man_local_max)"

echo "== runtime dependency =="
command -v python3 >/dev/null || fail "python3 missing"
python3 - <<'PY' || exit 1
import sys
assert sys.version_info >= (3, 8), "python 3.8+ required"
PY
ok "python3 present"
# stdlib only: a marketplace plugin must not need pip
for script in bin/burnbar-collect bin/burnbar-local-status bin/burnbar-local-control nano/ollama-meter.py; do
  ! grep -qE '^\s*import\s+(requests|yaml|numpy)' "$script" || fail "third-party import in $script"
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$script" || fail "$script does not parse"
done
ok "all four scripts are stdlib-only and parse"

# A QML id outranks a same-named property in scope resolution, so an
# unqualified reference silently binds the Item instead of the number. That is
# how `grokSepSpace` became NaN and collapsed every lane width to nothing.
python3 tests/test_qml_id_shadowing.py || fail "QML id/property shadowing"
ok "no unqualified reference to a name that is both an id and a property"

# The theme palette parser and the hue transfer, against synthetic input.
command -v node >/dev/null && {
  node tests/test_theme_palette.cjs >/dev/null 2>&1 || fail "theme palette tests"
node tests/test_lane_cap.cjs >/dev/null 2>&1 \
  || fail "lane cap tests"
ok "the strip's ceiling is one physical allowance per visible lane, floor wins"
node tests/test_lane_allocation.cjs >/dev/null 2>&1 \
  || fail "lane allocation tests"
ok "all visible cloud-lane subsets fit the strip"
node tests/test_guidance.cjs >/dev/null 2>&1 \
  || fail "guidance tests"
ok "guidance: banked only when ahead, a way back when behind, a pick only with a choice, never local"
node tests/test_esc_guard.cjs >/dev/null 2>&1 \
  || fail "Esc guard tests"
ok "Esc: the panel is Exclusive while open, nothing re-primes, and the close waits for the release"
node tests/test_session_heat.cjs >/dev/null 2>&1 \
  || fail "5-hour window tests"
ok "5-hour window: hot only when it bites, and the chip says 5-HOUR"
  ok "theme palette parses, hues are in range, every lane has a fallback key"
}

python3 -m unittest discover -s tests -p 'test_zcode.py' -q \
  || fail "Zcode identity and retention"
ok "Zcode identity, warm cache, local-only roots and retention"

# --help is a question, not a run: it must describe the flags and exit without
# creating a state directory or touching history.json.
help_state="$(mktemp -d)"
help_out=$(XDG_STATE_HOME="$help_state" XDG_CACHE_HOME="$help_state/cache" \
  python3 bin/burnbar-collect --help) || fail "--help exited non-zero"
for flag in --window --buckets --no-local --meter-host --meter-unit --print; do
  grep -q -- "$flag" <<<"$help_out" || fail "--help does not document $flag"
done
[ -z "$(find "$help_state" -type f 2>/dev/null)" ] || fail "--help collected instead of just printing"
rm -rf "$help_state"
ok "--help documents every flag and collects nothing"

# A widget subprocess that cannot reach its state directory must say so in one
# line and exit non-zero, never dump a traceback into the service journal.
ro_state="$(mktemp -d)"; chmod 500 "$ro_state"
set +e
ro_err=$(XDG_STATE_HOME="$ro_state" XDG_CACHE_HOME="$ro_state/cache" \
  python3 bin/burnbar-collect --no-local 2>&1 >/dev/null); ro_rc=$?
set -e
chmod 700 "$ro_state"; rm -rf "$ro_state"
[ "$ro_rc" -ne 0 ] || fail "unwritable state dir exited 0"
grep -q "^burnbar-collect: cannot" <<<"$ro_err" || fail "no clean message: $ro_err"
! grep -q "Traceback" <<<"$ro_err" || fail "traceback leaked to the journal: $ro_err"
ok "an unwritable state directory is one clear line, not a traceback"

echo "== local intelligence unit tests =="
python3 tests/test_amd_telemetry.py -q
ok "AMD telemetry"
python3 -m unittest discover -s tests -p 'test_local_scripts.py' -q >/dev/null \
  || fail "local script unit tests"
ok "ollama url/json/ssh/tegra/meter hardening tests"

# Discovery must not lose a store that is symlinked in from another disk, and
# must survive a symlink cycle without walking forever.
python3 -m unittest discover -s tests -p 'test_walk_symlinks.py' -q >/dev/null \
  || fail "walk symlink tests"
ok "transcript discovery follows symlinked stores and survives a cycle"

# A withheld plan limit must carry the remedy the record already knows, and
# limits_for must keep its three-value shape: pick_limits and the Grok log
# source both unpack three, and widening it broke the Grok path once.
python3 -m unittest discover -s tests -p 'test_limits_help.py' -q >/dev/null \
  || fail "limits help tests"
ok "a withheld limit carries its remedy, and the limits tuple shape holds"

# Kimi's quota parser: /usages (plural) is the endpoint, and the request window
# must win the five-hour row rather than printing beside its credit ratio.
python3 -m unittest discover -s tests -p 'test_kimi_usages.py' -q >/dev/null \
  || fail "kimi usages tests"
ok "kimi /usages parses to real percentages, one row per window"
python3 -m unittest discover -s tests -p 'test_kimi_split.py' -q >/dev/null \
  || fail "kimi split tests"
ok "a Kimi turn is not billed to Claude"

# Grok has no stock probe, so its record freezes while its log keeps moving.
# Picking between two sources has to go on evidence, not on argument order.
# A duplicate name at a QML root scope makes the whole type unavailable, and the
# bar simply goes empty. qmllint parses it happily; only the shell complains.
python3 -m unittest discover -s tests -p 'test_qml_duplicates.py' -q >/dev/null \
  || fail "QML duplicate declaration tests"
ok "no QML file declares a function, handler or property twice at its root"

# Budget pace: on-pace is used% == elapsed%, and every unknown stays unknown.
python3 -m unittest discover -s tests -p 'test_pace_math.py' -q >/dev/null \
  || fail "pace math tests"
ok "pace: ratio, allowance, projection, dry time and back-on-pace arithmetic"

python3 -m unittest discover -s tests -p 'test_grok_unknowns.py' -q >/dev/null \
  || fail "grok unknown-versus-zero tests"
ok "a Grok figure that is absent reads as unknown, never as zero"

python3 -m unittest discover -s tests -p 'test_limits_selection.py' -q >/dev/null \
  || fail "limit source selection tests"
ok "plan limits prefer an open window over a reset one, then the newer measurement"

# The dedicated meter is optional. On a host without it, Ollama's own journal
# is the ledger, and a busy GPU must never report zero tokens.
python3 -m unittest discover -s tests -p 'test_ollama_journal.py' -q >/dev/null \
  || fail "ollama journal tests"
ok "local tokens parse from ollama's own journal; prompt is never counted as generated"

# A GPU in this machine must be read directly. Wrapping a local command in ssh
# needs a trusted host key for localhost, and without one the lane found the
# card and then reported zero tokens.
python3 -m unittest discover -s tests -p 'test_local_host_no_ssh.py' -q >/dev/null \
  || fail "local host ssh bypass tests"
ok "a meter host that is this machine runs directly, and never reaches DNS"

# A warm read must return to the journal its kept points came from. Defaulting
# back to the meter unit froze the lane at its first cold read: still
# "available", still reporting the same token count hours later.
python3 -m unittest discover -s tests -p 'test_journal_source_sticks.py' -q >/dev/null \
  || fail "journal source stickiness tests"
ok "a cached ollama source keeps reading ollama, not the absent meter unit"

# A crowded bar must get space back. The floor is what the strip needs at its
# least detailed, and it stops bidding for a gap that cannot seat it anyway.
python3 -m unittest discover -s tests -p 'test_crowded_bar_yield.py' -q >/dev/null \
  || fail "crowded bar yield tests"
ok "the strip sheds cells and drops to its floor instead of splitting a tight gap"

# local-ai and an NPU embedder never write Ollama's journal. Their callers append
# to local-usage.jsonl, and those points must reach the local lane and the share.
python3 -m unittest discover -s tests -p 'test_local_ledger.py' -q >/dev/null \
  || fail "local usage ledger tests"
ok "local-ai and NPU ledger lines count as offloaded; junk and half lines are skipped"

# GPU discovery is a JSON object with a boolean hasGpu. Intel iGPU must not
# count; the unit tests cover that. This just proves the flag exists.
discover=$(python3 bin/burnbar-local-status --discover --host localhost)
echo "$discover" | jq -e 'has("hasGpu") and ((.hasGpu == true) or (.hasGpu == false))' >/dev/null \
  || fail "GPU discover did not report hasGpu: $discover"
ok "GPU discover reports hasGpu"

# The local probe must degrade to a clean offline JSON object rather than
# crashing when nothing is listening; that path is what draws the red core.
# A GPU-less localhost never ssh's; a GPU box whose Ollama is down still
# returns online=false.
offline=$(python3 bin/burnbar-local-status --threshold 8 --url http://127.0.0.1:1 --host localhost)
echo "$offline" | jq -e '.online == false and .load == 0' >/dev/null \
  || fail "offline probe did not report a clean offline object"
ok "local probe degrades to offline JSON"

echo "== collector against a fixture =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
# The caller's real cache must never leak into the fixture, and the clock is
# pinned one minute past the next 30-minute grid line: two runs then compare
# byte for byte across a bucket boundary, and the window arithmetic below is
# deterministic. Fixture records stamped "now" are 1–31 minutes old to it.
export XDG_CACHE_HOME="$tmp/cache"
real_now=$(date +%s)
pinned=$(( ( (real_now / 1800) + 1 ) * 1800 + 60 ))
export BURNBAR_NOW_MS=$(( pinned * 1000 ))
# Local tokens come from the ollama-meter journal on the Ollama box, over
# ssh; the fixture must never reach for it. An empty file means "journal
# readable, nothing in it".
: > "$tmp/journal-empty.txt"
export BURNBAR_METER_JOURNAL="$tmp/journal-empty.txt"
fake_home="$tmp/home"
mkdir -p "$fake_home/.claude/projects/p" "$fake_home/.codex/sessions/2026/09/03"
mkdir -p "$fake_home/.grok/sessions/s1" "$fake_home/.grok/logs"

now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
# Claude: the SAME message.id three times, as the streaming writer emits it.
# Correct handling counts 1000 tokens once, not three times.
for _ in 1 2 3; do
  printf '{"timestamp":"%s","message":{"id":"msg_dupe","model":"claude-test","usage":{"input_tokens":400,"cache_creation_input_tokens":100,"output_tokens":500,"cache_read_input_tokens":999999}}}\n' \
    "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
done
# Codex: one turn worth 300 billable (500 in - 300 cached + 100 out).
printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":300,"cache_write_input_tokens":0,"output_tokens":100}}}}\n' \
  "$now_iso" > "$fake_home/.codex/sessions/2026/09/03/rollout-x.jsonl"
# Grok: totalTokens rises 1000 → 2500 within one promptId → burn 1500.
printf '%s\n' \
  '{"timestamp":'"$BURNBAR_NOW_MS"',"method":"session/update","params":{"_meta":{"totalTokens":1000,"promptId":"p1","turnStartMs":'"$BURNBAR_NOW_MS"'}}}' \
  '{"timestamp":'"$BURNBAR_NOW_MS"',"method":"session/update","params":{"_meta":{"totalTokens":2500,"promptId":"p1","turnStartMs":'"$BURNBAR_NOW_MS"'}}}' \
  > "$fake_home/.grok/sessions/s1/updates.jsonl"
printf '{"ts":"%s","msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":42,"currentPeriod":{"end":"2099-01-01T00:00:00+00:00"}}}}\n' \
  "$now_iso" > "$fake_home/.grok/logs/unified.jsonl"

HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
out="$tmp/state/omarchy/burnbar/history.json"
[ -f "$out" ] || fail "no history.json written"
ok "history.json written"

jq -e '.bucketCount == 12 and (.buckets | length) == 12' "$out" >/dev/null \
  || fail "bucket count mismatch"
ok "12 buckets emitted"

ct=$(jq -r '.claude.total' "$out")
[ "$ct" = "1000" ] || fail "claude total $ct != 1000 (message.id dedupe broken, or cache reads counted)"
ok "claude dedupe by message.id + cache reads excluded"

xt=$(jq -r '.codex.total' "$out")
[ "$xt" = "300" ] || fail "codex total $xt != 300"
ok "codex per-turn delta math"

gt=$(jq -r '.grok.total' "$out")
[ "$gt" = "1500" ] || fail "grok total $gt != 1500 (totalTokens delta)"
jq -e '.grok.limits[0].percent == 0.42 and (.buckets | map(has("grok")) | all)' "$out" >/dev/null \
  || fail "grok limits/buckets missing"
ok "grok totalTokens delta + billing limits"

jq -e '.presence.claude == true and .presence.codex == true and .presence.grok == true' "$out" >/dev/null \
  || fail "presence flags missing or false with transcripts on disk: $(jq -c '.presence' "$out")"

# Claude and Codex records are re-probed by Burn Bar, so age condemns them.
# Grok is a snapshot tailed from Grok Bot's log, which writes it only at startup;
# it must be marked so the panel judges it by its billing window instead of age.
jq -e '.claude.limitsLive == true and .codex.limitsLive == true and .grok.limitsLive == false' "$out" >/dev/null \
  || fail "limitsLive must be true for the re-probed records and false for the Grok snapshot"
ok "limits are marked live (Claude, Codex) vs snapshot (Grok)"
ok "presence detects Claude, Codex and Grok from transcripts"

# Second run must be byte-identical: the incremental cache must not double-count
# points it replays from a file whose mtime is unchanged.
cp "$out" "$tmp/first.json"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
jq -S 'del(.generatedAt)' "$tmp/first.json" > "$tmp/a.json"
jq -S 'del(.generatedAt)' "$out" > "$tmp/b.json"
diff -q "$tmp/a.json" "$tmp/b.json" >/dev/null || fail "cached re-run changed totals"
ok "incremental cache is idempotent"

# Appending must be picked up via the tail read, not ignored.
printf '{"timestamp":"%s","message":{"id":"msg_new","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":250}}}\n' \
  "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
ct2=$(jq -r '.claude.total' "$out")
[ "$ct2" = "1250" ] || fail "append not picked up: $ct2 != 1250"
ok "tail read picks up appended records"

# Plan limits are copied out of Omarchy's usage records together with the
# record's own timestamp and status text, so the widget can refuse to present
# a stale 0% as live. This record is eight hours old and says the sign-in
# expired; the Codex record does not exist at all.
mkdir -p "$tmp/state/omarchy/agents/usage"
old_iso=$(date -u -d '8 hours ago' +%Y-%m-%dT%H:%M:%S+00:00)
future_iso=$(date -u -d '2 hours' +%Y-%m-%dT%H:%M:%S+00:00)
printf '{"limits":[{"label":"Weekly (7-day)","percent":0.42,"resetsAt":"%s"}],"updatedAt":"%s","usageStatusText":"Sign-in expired"}\n' \
  "$future_iso" "$old_iso" > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.claude.limits[0].percent == 0.42 and .claude.limits[0].resetsAt != "" and .claude.limitsStatus == "Sign-in expired"' "$out" >/dev/null \
  || fail "limits or status not carried from the usage record"
at=$(jq -r '.claude.limitsMeasuredAt' "$out")
age_h=$(( ( $(date +%s) * 1000 - at ) / 3600000 ))
{ [ "$age_h" -ge 7 ] && [ "$age_h" -le 9 ]; } || fail "limitsMeasuredAt is not the record's own timestamp (age ${age_h}h)"
jq -e '.codex.limits == [] and .codex.limitsMeasuredAt == 0 and .codex.limitsStatus == ""' "$out" >/dev/null \
  || fail "a missing usage record should read as no limits, never updated"
ok "plan limits carry the record's own timestamp and status"

# Omarchy's Claude collector re-stamps its record with *cached* limits when
# the probe fails, so updatedAt can be fresh while the figure is hours old.
# The probe cache next to it carries fetchedAtMs from the last successful
# probe; that is the measurement time. Here the record says "now", the probe
# cache says eight hours ago, and the record is a silent-fallback one.
mkdir -p "$tmp/cache/omarchy/agent-usage"
now_plain=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
old_ms=$(( ( $(date +%s) - 8 * 3600 ) * 1000 ))
printf '{"fetchedAtMs":%s,"limits":[]}\n' "$old_ms" > "$tmp/cache/omarchy/agent-usage/claude-limits.json"
printf '{"limits":[{"label":"Weekly (7-day)","percent":0.0,"resetsAt":"%s"}],"updatedAt":"%s","usageStatusText":"","retryAdvised":true}\n' \
  "$future_iso" "$now_plain" > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.limitsMeasuredAt' "$out")" = "$old_ms" ] \
  || fail "a re-stamped fallback record must carry the probe's own fetchedAtMs"
[ "$(jq -r '.claude.limitsStatus' "$out")" = "last probe failed, showing last known" ] \
  || fail "retryAdvised on a silent fallback should surface as status"
ok "measurement time comes from the probe cache, not the record stamp"

# Every percentage is normalised on its own: null, junk, NaN, negative and
# percent-scaled values become -1 (unknown) and the run still succeeds and
# still writes valid JSON. Before, "bad" aborted both agents' collection and
# "NaN" wrote a file the widget could not parse.
rm -f "$tmp/cache/omarchy/agent-usage/claude-limits.json"
printf '{"limits":[{"label":"a","percent":null,"resetsAt":"%s"},{"label":"b","percent":"bad","resetsAt":"%s"},{"label":"c","percent":"NaN","resetsAt":"%s"},{"label":"d","percent":-1,"resetsAt":"%s"},{"label":"e","percent":66,"resetsAt":"%s"},{"label":"Weekly (7-day)","percent":0.42,"resetsAt":"%s"}],"updatedAt":"%s"}\n' \
  "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$now_plain" \
  > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "junk percentages aborted the collector"
jq -e '[.claude.limits[].percent] == [-1, -1, -1, -1, -1, 0.42]' "$out" >/dev/null \
  || fail "percent normalisation wrong: $(jq -c '[.claude.limits[].percent]' "$out")"
ok "junk percentages become -1, never 0, never a crash, never NaN on disk"

# A syntactically valid record with the wrong shape must be skipped, not
# abort the run, and the totals must be exactly what the good records say.
printf '{"timestamp":"%s","message":{"id":"msg_junk","model":"claude-test","usage":{"input_tokens":"unknown","output_tokens":[]}}}\n' \
  "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","payload":{"type":"token_count","info":"bad"}}\n' \
  "$now_iso" >> "$fake_home/.codex/sessions/2026/09/03/rollout-x.jsonl"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "a malformed record aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "1250" ] || fail "malformed Claude record changed the total"
[ "$(jq -r '.codex.total' "$out")" = "300" ] || fail "malformed Codex record changed the total"
ok "malformed records are skipped, not fatal"

# A transcript rewritten to different content of the same length, with a
# newer mtime, must be rescanned: the old cache resumed at EOF and kept the
# stale points forever.
same="$fake_home/.claude/projects/p/same.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_same1","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100}}}\n' "$now_iso" > "$same"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "1350" ] || fail "same-length fixture setup: $(jq -r '.claude.total' "$out")"
printf '{"timestamp":"%s","message":{"id":"msg_same2","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":700}}}\n' "$now_iso" > "$same"
touch -m -d "@$(( $(date +%s) + 5 ))" "$same"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "1950" ] || fail "equal-size rewrite kept stale points: $(jq -r '.claude.total' "$out")"
ok "equal-size rewrite with a new mtime is rescanned"

# ── 1.3.3 audit fixtures ─────────────────────────────────────────────────────
# Codex's counter is cumulative. A rate-limit refresh re-emits the same
# last_token_usage with an unchanged total, and counting last_token_usage
# counted it twice. Three events: a turn, the same snapshot again, a second
# turn: 300 + 0 + 250.
cx2="$fake_home/.codex/sessions/2026/09/03/rollout-y.jsonl"
tc() { printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":0,"output_tokens":%s},"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":0,"output_tokens":%s}}}}\n' "$now_iso" "$@"; }
{ tc 500 300 100 500 300 100; tc 500 300 100 500 300 100; tc 200 0 50 700 300 150; } > "$cx2"
before_total=$(jq -r '.codex.total' "$out"); before_turns=$(jq -r '.codex.turns' "$out")
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.codex.total' "$out")" = "$(( before_total + 550 ))" ] \
  || fail "codex cumulative delta wrong: $(jq -r '.codex.total' "$out"), expected $(( before_total + 550 ))"
[ "$(jq -r '.codex.turns' "$out")" = "$(( before_turns + 2 ))" ] || fail "a repeated codex snapshot was counted as a turn"
ok "codex counts cumulative deltas: a repeated snapshot is not a second turn"

# The baseline survives an incremental tail read: a fourth event appended to
# the same file lands as its delta alone (800-300+170 minus 700-300+150 = 120).
tc 100 0 20 800 300 170 >> "$cx2"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.codex.total' "$out")" = "$(( before_total + 670 ))" ] \
  || fail "codex baseline lost across a tail read: $(jq -r '.codex.total' "$out")"
ok "codex cumulative baseline survives an incremental tail read"

# Negative, overflowing (1e999 parses as a float infinity) and boolean counts
# are rejected as records; a record that only read cache is still a turn and
# still feeds the cache-read line, it just adds nothing to the heat.
cl_before=$(jq -r '.claude.total' "$out"); cr_before=$(jq -r '.claude.split.cacheRead' "$out"); turns_before=$(jq -r '.claude.turns' "$out")
printf '{"timestamp":"%s","message":{"id":"msg_neg","model":"claude-test","usage":{"input_tokens":-50,"output_tokens":100}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_over","model":"claude-test","usage":{"input_tokens":1e999,"output_tokens":1}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_bool","model":"claude-test","usage":{"input_tokens":true,"output_tokens":1}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_cacheonly","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0,"cache_read_input_tokens":1000}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "audit records aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "$cl_before" ] || fail "a negative, overflowing or boolean count changed the total"
[ "$(jq -r '.claude.split.cacheRead' "$out")" = "$(( cr_before + 1000 ))" ] || fail "cache-read-only record lost from the split"
[ "$(jq -r '.claude.turns' "$out")" = "$(( turns_before + 1 ))" ] || fail "cache-read-only record not counted as a turn"
ok "negative, overflowing and boolean counts are rejected; a cache-read-only turn is kept"

# Streaming re-serialises a message with growing output. The final revision
# is the one that counts, not the first seen.
rev="$fake_home/.claude/projects/p/rev.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_rev","model":"claude-test","usage":{"input_tokens":100,"output_tokens":1}}}\n' "$now_iso" > "$rev"
printf '{"timestamp":"%s","message":{"id":"msg_rev","model":"claude-test","usage":{"input_tokens":100,"output_tokens":100}}}\n' "$now_iso" >> "$rev"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before + 200 ))" ] \
  || fail "claude dedupe kept the preliminary revision: $(jq -r '.claude.total' "$out")"
ok "claude dedupe keeps the final streamed revision, not the first"

# A rewrite that happens to be LONGER than the cached file is not an append.
# The bytes just before the saved offset no longer match, so it is rescanned.
grow="$fake_home/.claude/projects/p/grow.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_g1","model":"claude-test","usage":{"input_tokens":0,"output_tokens":100}}}\n' "$now_iso" > "$grow"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
cl_before=$(jq -r '.claude.total' "$out")
printf '{"timestamp":"%s","message":{"id":"msg_grow_two","model":"claude-test","usage":{"input_tokens":0,"output_tokens":900}}}\n' "$now_iso" > "$grow"
touch -m -d "@$(( real_now + 7 ))" "$grow"
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before - 100 + 900 ))" ] \
  || fail "a longer rewrite was resumed as an append: $(jq -r '.claude.total' "$out")"
ok "a longer rewrite fails the tail fingerprint and is rescanned"

# A malformed cache entry is a cache miss for that file, never a crash that
# repeats on every run.
cache="$tmp/state/omarchy/burnbar/scan-cache.json"
jq --arg k "$fake_home/.claude/projects/p/s.jsonl" '.files[$k].points = [["bad"]]' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "a malformed cache entry aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "$cl_before" ] || fail "a malformed cache entry changed the total: $(jq -r '.claude.total' "$out")"
ok "a malformed cache entry is a cache miss, not a crash"

# Two clocks. The strip's grid holds BUCKETS-1 whole buckets plus the partial
# newest one, so at one minute past a grid line it reaches back 331 minutes;
# the window is 360. A 345-minute-old record must be in the total and in no
# bucket.
old_ts=$(date -u -d "@$(( pinned - 345 * 60 ))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"timestamp":"%s","message":{"id":"msg_old","model":"claude-test","usage":{"input_tokens":0,"output_tokens":4000}}}\n' "$old_ts" > "$fake_home/.claude/projects/p/old.jsonl"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before + 4000 ))" ] \
  || fail "a 345-minute-old record fell out of a 360-minute window: $(jq -r '.claude.total' "$out")"
bsum=$(jq -r '[.buckets[].claude] | add' "$out")
[ "$bsum" = "$cl_before" ] || fail "grid buckets should exclude the pre-grid record (bucket sum $bsum, expected $cl_before)"
jq -e '.claude.trailing.m60 >= 0 and .claude.trailing.m5 >= 0 and .claude.trailing.m5 <= .claude.trailing.m60' "$out" >/dev/null \
  || fail "trailing sums missing or inconsistent"
ok "window totals are exact while the strip's grid stays aligned"

# No activity means no peak time: the panel shows "--", not the window start.
jq -e '(.codex.peak > 0 and .codex.peakAt > 0) or (.codex.peak == 0 and .codex.peakAt == 0)' "$out" >/dev/null \
  || fail "peakAt disagrees with peak"
ok "peakAt is 0 when nothing peaked"

# ── local tokens from the ollama-meter journal ───────────────────────────────
# Real line shapes from journalctl -o short-unix on nano. Three requests on
# one model, one on another: 33+53, 31+3 and an embed with prompt only, then
# a failed load (status 500, no counts) that must not count, and a line with
# -1 for a count the response never carried.
j="$tmp/journal.txt"
t0=$(( pinned - 600 ))
cat > "$j" <<EOF
$t0.000000 nano python3[9143]: ollama-meter listening on 0.0.0.0:11434, upstream 127.0.0.1:11435
$(( t0 + 1 )).804220 nano python3[9143]: meter ts=$(( t0 + 1 ))803 path=/api/generate model=llama3.2:3b status=200 prompt=33 eval=53 ms=2744 client=100.64.0.2
$(( t0 + 2 )).175497 nano python3[9143]: meter ts=$(( t0 + 2 ))175 path=/api/chat model=llama3.2:3b status=200 prompt=31 eval=3 ms=352 client=10.0.0.147
$(( t0 + 8 )).080384 nano python3[9143]: meter ts=$(( t0 + 8 ))080 path=/api/embed model=nomic-embed-text status=200 prompt=4 eval=-1 ms=5028 client=10.0.0.147
$(( t0 + 40 )).358225 nano python3[9143]: meter ts=$(( t0 + 40 ))358 path=/api/generate model=qwen2.5:3b status=500 prompt=-1 eval=-1 ms=30259 client=100.64.0.2
$(( t0 + 41 )).000000 nano python3[9143]: meter ts=$(( t0 + 41 ))000 path=/api/generate model=qwen2.5:3b status=200 prompt=-1 eval=-1 ms=10 client=100.64.0.2
EOF
BURNBAR_METER_JOURNAL="$j" HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.local.available == true and .local.total == 124 and .local.turns == 3
  and .local.split.input == 68 and .local.split.output == 56 and .local.split.cacheRead == 0 and .local.split.cacheWrite == 0
  and .local.byModel["llama3.2:3b"] == 120 and .local.byModel["nomic-embed-text"] == 4
  and .local.host == "localhost" and .local.unit == "ollama-meter"' "$out" >/dev/null \
  || fail "meter journal parse wrong: $(jq -c '.local | {available, total, turns, split, byModel}' "$out")"
ct=$(jq -r '.claude.total' "$out"); xt=$(jq -r '.codex.total' "$out"); gt=$(jq -r '.grok.total' "$out")
want=$(python3 -c "print(round(124 / (124 + $ct + $xt + $gt), 6))")
got=$(jq -r '.offloadShare | . * 1000000 | round / 1000000' "$out")
[ "$got" = "$want" ] || fail "offload share $got != $want"
jq -e '[.buckets[].local] | add == 124' "$out" >/dev/null || fail "local tokens missing from the buckets"
ok "local tokens parsed from the meter journal; failed requests skipped; offload share = local / all burn"

# An unreadable journal is reported with its reason. The last-known points
# stay in the cache (the panel hides the numbers while available is false),
# so the total is not asserted here.
BURNBAR_METER_JOURNAL="$tmp/does-not-exist.txt" HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.local.available == false and (.local.reason | length) > 0' "$out" >/dev/null \
  || fail "unreadable journal not reported: $(jq -c '.local | {available, reason, total}' "$out")"
ok "an unreadable journal reads as unavailable with a reason"

# --no-local must not ssh and must mark local unavailable, even when a
# journal override is sitting there.
BURNBAR_METER_JOURNAL="$j" HOME="$fake_home" GROK_HOME="$fake_home/.grok" \
  python3 bin/burnbar-collect --window 360 --buckets 12 --no-local
jq -e '.local.available == false and (.local.reason | test("GPU"))' "$out" >/dev/null \
  || fail "--no-local still counted local tokens: $(jq -c '.local | {available, reason, total}' "$out")"
ok "--no-local skips the meter and reports no GPU"

# ── zcode: one line per completed model request ──────────────────────────────
# ~/.zcode/cli/rollout/model-io-sess_*.jsonl. Per-request usage (no cumulative
# counter, no streamed revisions), so what the line says is what the lane
# counts. zcode's inputTokens is a bundle (input + cache write + cache read),
# so the heat is fresh input + cache write + output, cache reads carried in
# the split but excluded, model attributed from the line itself.
mkdir -p "$fake_home/.zcode/cli/rollout"
zlocal="$fake_home/.zcode/cli/rollout/model-io-sess_local.jsonl"
printf '{"completedAt":"%s","requestId":"req_z1","attempt":1,"model":{"modelId":"glm-5.3"},"response":{"usage":{"inputTokens":400,"outputTokens":150,"totalTokens":550,"cacheReadTokens":300,"cacheWriteTokens":50}}}\n' \
  "$now_iso" > "$zlocal"
zc="$fake_home/.zcode/cli/rollout/model-io-sess_fixture.jsonl"
printf '{"completedAt":"%s","requestId":"req_z2","attempt":1,"model":{"modelId":"qwen3.8-27b"},"response":{"usage":{"inputTokens":100,"outputTokens":20,"totalTokens":120}}}\n' \
  "$now_iso" > "$zc"
# Records whose usage is not counts are skipped, not fatal: a string, a bool,
# a negative, a float that is not whole, 1e999 and a count over the cap.
printf '{"completedAt":"%s","requestId":"req_b1","response":{"usage":{"inputTokens":"unknown","outputTokens":1}}}\n' "$now_iso" > "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
printf '{"completedAt":"%s","requestId":"req_b2","response":{"usage":{"inputTokens":true,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
printf '{"completedAt":"%s","requestId":"req_b3","response":{"usage":{"inputTokens":-50,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
printf '{"completedAt":"%s","requestId":"req_b4","response":{"usage":{"inputTokens":12.7,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
printf '{"completedAt":"%s","requestId":"req_b5","response":{"usage":{"inputTokens":1e999,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
printf '{"completedAt":"%s","requestId":"req_b6","response":{"usage":{"inputTokens":1000000000000000,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
# A bundle smaller than its own cache part is not arithmetic anyone wrote.
printf '{"completedAt":"%s","requestId":"req_b7","response":{"usage":{"inputTokens":100,"cacheReadTokens":300,"outputTokens":1}}}\n' "$now_iso" >> "$fake_home/.zcode/cli/rollout/model-io-bad.jsonl"
# The same requestId twice counts once.
printf '{"completedAt":"%s","requestId":"req_z2","attempt":1,"model":{"modelId":"qwen3.8-27b"},"response":{"usage":{"inputTokens":100,"outputTokens":20,"totalTokens":120}}}\n' \
  "$now_iso" >> "$zc"
BURNBAR_METER_JOURNAL="$tmp/journal-empty.txt" \
  HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.zcode.total == 370 and .zcode.turns == 2 and .zcode.sessions == 2
  and .zcode.byModel["glm-5.3"] == 250 and .zcode.byModel["qwen3.8-27b"] == 120
  and .zcode.split.input == 150 and .zcode.split.cacheWrite == 50
  and .zcode.split.output == 170 and .zcode.split.cacheRead == 300
  and .presence.zcode == true' "$out" >/dev/null \
  || fail "zcode lane wrong: $(jq -c '.zcode' "$out")"
ok "zcode unbundles inputTokens: cache reads stay out of the heat, junk is skipped, a request id counts once"

# The rollout store is a ring: a file is truncated to a reset line or deleted
# outright while its requests are still inside the window. What was counted
# must survive both, which is what the request-id union with the scan cache
# is for.
printf '{"completedAt":"%s","requestId":"req_z4","attempt":1,"model":{"modelId":"glm-5.3"},"response":{"usage":{"inputTokens":10,"outputTokens":5,"totalTokens":15}}}\n' \
  "$now_iso" > "$zc"
BURNBAR_METER_JOURNAL="$tmp/journal-empty.txt" \
  HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.zcode.total' "$out")" = "385" ] \
  || fail "a truncated rollout lost its earlier requests: $(jq -r '.zcode.total' "$out") != 385"
ok "a truncated rollout keeps the requests it already counted"

rm -f "$zc"
BURNBAR_METER_JOURNAL="$tmp/journal-empty.txt" \
  HOME="$fake_home" GROK_HOME="$fake_home/.grok" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.zcode.total' "$out")" = "385" ] && [ "$(jq -r '.presence.zcode' "$out")" = "true" ] \
  || fail "a deleted rollout lost its requests or its presence: total $(jq -r '.zcode.total' "$out"), presence $(jq -r '.presence.zcode' "$out")"
ok "a deleted rollout retains its requests inside the window"

# Advance past the six-hour display window, then the 25-hour cache horizon.
# Use a copied state dir so later fixtures retain the original pinned clock.
expiry_state="$tmp/expiry-state"
cp -a "$XDG_STATE_HOME" "$expiry_state"
BURNBAR_NOW_MS=$(( BURNBAR_NOW_MS + 6 * 3600 * 1000 + 1 )) \
  XDG_STATE_HOME="$expiry_state" HOME="$fake_home" GROK_HOME="$fake_home/.grok" \
  python3 bin/burnbar-collect --no-local --window 360 --buckets 12
jq -e '.zcode.total == 0 and .zcode.turns == 0' \
  "$expiry_state/omarchy/burnbar/history.json" >/dev/null \
  || fail "deleted rollout still contributes after the window"
BURNBAR_NOW_MS=$(( BURNBAR_NOW_MS + 25 * 3600 * 1000 + 1 )) \
  XDG_STATE_HOME="$expiry_state" HOME="$fake_home" GROK_HOME="$fake_home/.grok" \
  python3 bin/burnbar-collect --no-local --window 360 --buckets 12
jq -e --arg file "$zc" '.files | has($file) | not' \
  "$expiry_state/omarchy/burnbar/scan-cache.json" >/dev/null \
  || fail "deleted rollout still cached after the retention horizon"
ok "a deleted rollout ages out of both the display window and cache retention"

# A machine that only has Grok must not claim Claude or Codex are present.
grok_only="$tmp/grok-only"
mkdir -p "$grok_only/.grok/sessions/s1" "$grok_only/.grok/logs"
printf '%s\n' \
  '{"timestamp":'"$BURNBAR_NOW_MS"',"method":"session/update","params":{"_meta":{"totalTokens":1000,"promptId":"p1","turnStartMs":'"$BURNBAR_NOW_MS"'}}}' \
  '{"timestamp":'"$BURNBAR_NOW_MS"',"method":"session/update","params":{"_meta":{"totalTokens":2500,"promptId":"p1","turnStartMs":'"$BURNBAR_NOW_MS"'}}}' \
  > "$grok_only/.grok/sessions/s1/updates.jsonl"
rm -rf "$tmp/state/omarchy/burnbar"
HOME="$grok_only" GROK_HOME="$grok_only/.grok" BURNBAR_METER_JOURNAL="$tmp/journal-empty.txt" \
  python3 bin/burnbar-collect --window 360 --buckets 12 --no-local
jq -e '.presence.claude == false and .presence.codex == false and .presence.grok == true
  and .grok.total == 1500 and .claude.total == 0 and .codex.total == 0' "$out" >/dev/null \
  || fail "grok-only machine was not detected: $(jq -c '{presence, claude:(.claude.total), codex:(.codex.total), grok:(.grok.total)}' "$out")"
ok "a Grok-only machine lights only the Grok lane"

echo
echo "ALL TESTS PASSED"
