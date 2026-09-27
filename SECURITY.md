# Security and privacy

Burn Bar is an unsandboxed Omarchy shell plugin. Installing it means trusting
the QML and Python in this repository with the permissions of your graphical
desktop session. Review the source and the commit you intend to install.

## Read this part

**Burn Bar reads your AI coding transcripts.** To count tokens it opens every
file under:

- `~/.claude/projects/**/*.jsonl`: your complete Claude Code conversations
- `~/.grok/sessions/**/updates.jsonl` and `~/.grok/logs/unified.jsonl`, Grok Build/CLI session updates and billing snapshots
- `~/.codex/sessions/**/rollout-*.jsonl`: your complete Codex sessions

These files contain your prompts, the assistant's replies, and the contents of
files you worked on. There is no way to count per-turn tokens without reading
them, because the token counts are interleaved with the conversation. If you
are not comfortable with a bar widget opening those files, do not install this.

When `BURNBAR_EXTRA_HOMES` is set, the collector additionally opens the same
transcripts under every `$HOME`-shaped root it names, typically rsync mirrors
of these very files from your other machines. Burn Bar never fetches them
itself and never writes to them; whatever put them there did.

**Burn Bar also logs in to another machine, but only when a compute GPU
exists and `localHost` is not this machine.** Intel integrated graphics does
not count. On a GPU-less laptop there is no ssh, no Ollama poll, and no
local lane. When the Ollama box is another host (a Jetson named `nano`, for
example) it gets there by running `ssh` as you, non-interactively
(`BatchMode=yes`), every poll. On that box it reads sysfs and `/proc`, reads
the `ollama-meter` journal, and, when you press **Load & keep warm**, runs
`sudo -n /usr/local/bin/ollama-prepare.sh` to drop the page cache. If your
account there cannot sudo without a password the load simply skips that
step. Nothing is written on that box by the widget; `nano/install.sh` is the
one thing that installs anything, and it is run by hand.

**The meter on that box sees every Ollama request.** `nano/ollama-meter.py`
is a reverse proxy on Ollama's public port. It forwards bodies unchanged and
keeps only the tail of each response long enough to read two integers off
it; what it writes to the journal is the path, the model name, the HTTP
status, the two token counts, the latency and the client address. Never the
prompt, never the reply. The journal line is the whole record.

## What it does with them

1. `bin/burnbar-collect` (Python 3, standard library only) reads each line and
   keeps: a timestamp, token counts split into input, cache write, output and
   cache read, the model name, and, for Claude, the opaque `message.id`
   used to deduplicate streamed records.
2. No prompt text, reply text, or file content from inside a conversation is
   extracted, stored, or displayed. The scan cache does key on the absolute
   transcript path, and Claude's transcript paths include the project
   directory name (see "Files it writes").
3. Results are bucketed by time and written to
   `~/.local/state/omarchy/burnbar/history.json`.
4. `Service.qml` watches that file; `BarWidget.qml` and `BurnPanel.qml` render it.

## What leaves your machine

Burn Bar has no telemetry, no update check, and no remote endpoint of its
own. Three things do generate network traffic, and you should know all three:

1. **Omarchy's usage collectors, which Burn Bar triggers.** Every
   `limitsRefreshSec` seconds (default 300), on panel open and on refresh,
   Burn Bar runs `omarchy-agent-usage-update --limits-only claude codex`.
   That is Omarchy's own command, the same one the stock agents panel runs.
   Its Claude collector contacts **Anthropic's OAuth usage endpoint** with the
   sign-in Claude Code already saved on this machine; its Codex collector asks
   the Codex app-server over a local pipe (which may itself talk to OpenAI).
   Burn Bar never reads, holds or sends either credential. If you do not want
   this traffic, do not install Burn Bar; there is no setting that disables
   it, because without it the plan limits it shows would be hours stale.
2. **The Ollama box**, only when a compute GPU was detected. HTTP to
   `ollamaUrl` (default `http://127.0.0.1:11434`) and, if `localHost` is
   another machine, ssh to that host. Both go wherever your settings and
   your ssh config point.
   The calls are:

   | Script | Channel | Purpose |
   |---|---|---|
   | `bin/burnbar-local-status` | `GET /api/ps`, `GET /api/version` | Which models are resident, their size and `expires_at`; the Ollama version |
   | `bin/burnbar-local-status` | ssh, one `sh -c` snippet | GPU load and clock, temperature, power rails, fan, memory from sysfs and `/proc`; ollama CPU ticks 200 ms apart |
   | `bin/burnbar-collect` | ssh `journalctl -u ollama-meter … --show-cursor -g 'meter ts='` | The meter's lines since the last cursor; on a cold read that finds nothing, `systemctl show -p LoadState` to tell a quiet meter from a missing one |
   | `bin/burnbar-local-control list` | `GET /api/tags`, `GET /api/ps` | Installed and resident model lists, on panel open, refresh, and after each action |
   | `bin/burnbar-local-control load` | ssh `sudo -n /usr/local/bin/ollama-prepare.sh`, then `POST /api/show`, then `POST /api/generate` or `POST /api/embed` | Drop the box's page cache; capabilities; warm the model you picked (`keep_alive: -1`); no prompt is sent |
   | `bin/burnbar-local-control unload` | `POST /api/generate` | Evict the model you picked (`keep_alive: 0`) |

3. Nothing else.

The Ollama URL is validated (http/https with a host, no query or fragment)
before use, responses are capped at 1 MiB, model counts and string fields are
bounded, a model name that would need truncating is refused, and non-finite
JSON numbers are rejected. The ssh host is one printable word that cannot
start with `-`, passed after `--`, and every remote word is shell-quoted. If
Ollama is unreachable the lane reads OFFLINE; if only ssh fails the hardware
figures are withheld with the reason; the next poll simply runs on the next
timer tick.

## Files it writes

| Path | Contents |
|---|---|
| `~/.local/state/omarchy/burnbar/history.json` | Bucketed token totals, per-agent splits, model names, and plan-limit percentages |
| `~/.local/state/omarchy/burnbar/scan-cache.json` | Per transcript file: size, mtime, byte offset, a 48-byte fingerprint of the bytes before that offset, the extracted numeric points (timestamp, counts, model name, Claude `message.id`), and for Codex the last cumulative counter. For the meter journal: the last cursor and the points |
| `~/.local/state/omarchy/burnbar/collect.lock` | Empty; held while a collector runs so two never race |

`scan-cache.json` keys on absolute transcript paths, which include your project
directory names. It is written with your account's default permissions under
your own state directory and is never transmitted.

Burn Bar writes nothing inside its own plugin directory, and modifies no
Omarchy, Hyprland, or application configuration on this machine.

On the Ollama box, `nano/install.sh`, run by hand, once, installs
`/usr/local/lib/burnbar/ollama-meter.py`, `/etc/systemd/system/ollama-meter.service`,
`/etc/systemd/system/ollama.service.d/zz-burnbar.conf` (Ollama to
`127.0.0.1:11435`, `OLLAMA_NUM_PARALLEL=1`) and
`/etc/sysctl.d/90-burnbar-ollama.conf` (`vm.min_free_kbytes = 1048576`),
then restarts Ollama. The rollback is in the script's header.

## Processes it runs

Three scripts of its own, all `python3`, all as your user, all from the
plugin's own `bin/` directory, plus one Omarchy command:

- `omarchy-agent-usage-update --limits-only claude codex`, every
  `limitsRefreshSec` seconds (default 300), on panel open, and on refresh.
  This is Omarchy's own collector, not Burn Bar's. It is what the stock agents
  panel runs, and it is the only thing that produces the plan-limit records
  Burn Bar reads. Its Claude collector contacts Anthropic's OAuth usage
  endpoint with the sign-in Claude Code already saved, and its Codex collector
  asks the Codex app-server over a local pipe. Burn Bar never reads, holds or
  sends either credential itself; if the command is not present the limits
  simply show their age. It is launched through `bash -c` under `setsid` so
  that the 60-second watchdog can terminate the whole process group, not just
  the wrapper. Burn Bar also reads (never writes) the collector's probe cache
  at `~/.cache/omarchy/agent-usage/claude-limits.json` for the time of the
  last successful measurement.

Burn Bar's own scripts:

- `burnbar-collect` on the refresh timer. It takes no input from the network
  and no input from the widget beyond two integers (window length and bucket
  count) clamped to fixed ranges, the ssh host (128 characters, after `--`)
  and the meter unit name (64 characters, shell-quoted into the remote
  command). It runs `ssh` to the box for `journalctl` and, on a cold read
  that finds nothing, `systemctl show` to tell a quiet meter from a missing
  one. A run that exceeds 30 seconds is killed by a watchdog.
- `burnbar-local-status` on the local poll timer: two HTTP calls and one
  `ssh` running a fixed `sh -c` snippet that only reads files. A run over 15
  seconds is killed.
- `burnbar-local-control list` when the cockpit opens, on refresh, and after
  each action; `load` or `unload` only when you press **Load & keep warm** or
  **Unload**, with the model name you chose from the list it returned. A
  load first runs `ssh <host> sudo -n /usr/local/bin/ollama-prepare.sh`; a
  refusal is reported and the load goes ahead. A list over 15 seconds or an
  action over 3 minutes is killed.

## Reporting

Open an issue at https://github.com/nixfred/burnbar/issues. For anything you
believe is sensitive, say so in the issue without including the sensitive
detail and a private channel will be arranged.
