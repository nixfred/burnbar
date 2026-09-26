# Changelog

## 2.2.0 (2026-09-25)

Thanks [@ianswope](https://github.com/ianswope) for this one (PR #2).

### Changed
- **The heartbeats no longer redraw the bar at the monitor's refresh rate.** The
  live-cell ring, the 90% quota beat, the over-pace chip and the local core's
  throb and strobe were each an `Animation.Infinite`, and a running Animation
  asks for a new frame on every vsync of every screen the bar is on: 120fps on a
  120Hz panel, for a ring that breathes once every 1.8s, and the live ring runs
  whenever any agent is burning. They now read one shared pulse clock at 10fps,
  or ride the ember timer's 20fps tick when the embers are already running. Each
  pulse holds a ticket while it is on screen and the clock only runs while
  someone holds one, so a quiet strip still costs nothing. Same periods, same
  ranges, same gating; a stopped beat now sits at rest through a binding instead
  of an `onRunningChanged` reset.
- Measured on a three-screen bar (3200x2000@120 plus two 1080p@75, Intel iGPU),
  shell CPU after a fresh restart, stock and patched interleaved: stock 45 to 57%
  of a core, patched 12 to 26%. A QML profile of the patched strip shows its
  JavaScript at 18ms in 30s; what remains is the shell's ordinary per-frame work.
- The rising sparks are untouched: they move, and would step visibly at 10fps.
  They already sit behind the `sparks` setting.

## 2.1.1 (2026-09-25)

### Fixed
- **Esc closes Burn Bar, not the terminal under it.** Fred: *"sometimes that
  ESC goes to the terminal or herdr under it."* The shell's keyboard panel grabs
  the keys for a moment and then lets Hyprland take them back on demand, so the
  window beneath could end up with the keyboard while the panel was still open.
  The panel now notices when it loses the keyboard while open and takes it back.

## 2.1.0 (2026-09-20)

Guidance. Burn Bar told you where you stood; now it tells you what to do.

### Added
- **Banked budget, live.** Fred: *"if you get ahead, how much you have banked,
  real time, always if you are ahead, not shown if behind."* Each card leads
  with `BANKED 49%` and a running clock, `3d 10:03:03 in the bank`: the share of
  the plan an even spend would have used by now and you did not. Leave a sub
  alone and the clock climbs a second every second.
- **A timer for coming back.** Fred: *"If I take some time off from the agent it
  should slowly come back to budget, right? Maybe a timer that shows when you
  can come back."* A sub that is behind shows `COME BACK IN 8:36:42`, then the
  wall-clock time, `if you stop`, and how far over it is. A spent plan says
  `BACK AT THE RESET` with its countdown.
- **Which sub to use next.** Fred: *"SUGGEST the right sub to go use. If they
  have 2 tell them which one is the right one. 4 same thing. If they only have
  one dont suggest it. Dont ever suggest local."* A banner above the cards names
  it and says why, then who is next and when each resting sub is back. It turns
  into "use it or lose it" when a reset is close with budget unspent, and into
  "keep using" when you are already on the right one. The strip shows the same
  pick as a chip whenever nothing is over pace, tooltips carry it, and SETUP's
  notes speak it too.
- **The rules behind the advice.** Two subscriptions or it says nothing. Never
  the local GPU. Only a sub that is ahead. A lane you unticked is left out. A
  5-hour session window that is full, or will be inside half an hour, blocks a
  sub. A snapshot (Grok) needs five times the margin, more once it has been
  used since, and says when it was measured. The clocks hold still while tokens
  are leaving. The pick does not flap.
- **The cockpit fits itself to the screen.** The guidance line pushed the footer
  off the bottom of a 1080p laptop, so the panel now measures the screen it
  opens on and tightens (shorter graphs, closer rows, a one-line footer), and
  tightens again if the real content still would not fit. It never scrolls and
  never clips.
- A reset label on every burndown, rate labels that cannot be read as totals
  (`/MIN NOW`), and a flip control that names where it goes.

### Changed
- **The badge on the bar speaks words, not multipliers.** `CLAUDE  REST 8H` and
  `SPENT` instead of `7.6x OVER`. A multiplier is data; a rest time is
  something you can act on.
- **One definition of "over".** Within 5% of an even spend is on pace
  everywhere: verdict, badge, glow and guidance.
- The pace sentence no longer repeats what the what-to-do line now says, and
  "stop in ..." appears only when today's share really would run out today.

### Fixed
Twenty-two defects found by an outside review of the whole plugin by Grok 4.6
and Kimi k3, each one verified against the code first. The full list, the two
findings that were rejected and why, and which guidance ideas came from the
reviewers are in [docs/review-2.1.md](docs/review-2.1.md). The ones you could
have seen:
- **The local GPU lane painted over Kimi's lane** whenever both were on.
- **A hidden lane still warned.** With Codex unticked the strip said `SPENT`
  about Codex. (Found in the screenshots for this release.)
- Every on-pace sub was told to "stop in 23h".
- A Codex-only machine drew its lane backwards.
- The header counted Kimi's tokens but not its turns, sessions or rates.
- Kimi's lane never flashed on new burn and had no tinted plate, and Kimi
  burning alone looked idle.
- Every quota row on every card was rebuilt once a second while the panel was
  open.
- A missing Grok usage figure published a confident 0%.
- A collector run against a slow remote meter host was killed at 30 seconds.

### Docs
- Fifteen new README graphics, all real captures of the plugin on one day of
  recorded usage, in `docs/img/`. A new store preview showing the 2.x strip.
- A sample tailnet address in the README, a collector comment and the tests is
  now a documentation address.

### Tests
- `tests/test_guidance.cjs`, 21 cases: banked only when ahead, a way back only
  when behind, spent while ahead of the clock, the 5% grace, one sub never
  suggested, a week and a month ranked on one scale, use it or lose it, urgency
  by the calendar, snapshots, blocked and unreadable subs, no flapping, and
  local never a candidate.
- `tests/test_grok_unknowns.py`, and two stop-time regressions in the pace
  tests.

## 2.0.0 (2026-09-20)

The cockpit is rebuilt around one idea: a subscription is one card, and the card
holds everything about it.

### Added
- **One card per subscription.** Fred: *"Each sub should have a section that
  cleanly displays all the info about it in one large card."* Budget, burndown,
  the plain-English pace sentence, every quota window, burn rate, token mix and
  the model breakdown now live together instead of being spread over separate
  sections. Cards sit side by side at equal width and the panel never scrolls. A
  subscription that is not ticked has no card, and one that burned nothing in
  the window folds its burn half down to a single line.
- **A burndown graph on every card.** The dashed diagonal is an even spend
  across the window. The solid line is what actually happened, from the
  collector's own samples, and a dashed projection carries the current rate
  forward to the reset or to the moment the plan runs dry. A line above the
  diagonal is over budget, at a glance.
- **The headline is yours to pick.** Budget (how much of the plan is spent, and
  will it last) or tokens (raw burn in the window). Click a headline to flip it,
  or set it in SETUP. Budget is the default, and a subscription whose quota
  cannot be measured falls back to tokens rather than printing a dash at
  display size.
- **Cards glow, and you choose why.** Fred: *"I also want the subscriptions card
  to glow and the reason for the glow is something the user can select within
  setup."* One reason at a time, because a glow that could mean four things says
  nothing from across the room: **over pace** (the default; amber, then red,
  breathing while there is still something to slow down, steady once the window
  is spent), **burning now** (the subscription's own colour while tokens are
  moving, which also lights the local GPU card), **budget spent** (brighter as
  the window fills), **time to stop** (within an hour of today's share, or past
  it), or **off**. The glow is the card's own outline blurred into light, drawn
  just outside the edge so the text inside stays on a clean background, and it
  only animates while the panel is open.
- **A SETUP page.** Fred: *"move the sub selection away from right click and add
  it to SETUP button where all options are available across all features."*
  Subscriptions, card headline, card glow, budget windows, history window,
  warnings and every toggle for the strip on the bar, three columns wide on one
  screen. Every row writes through the bar, so it is the same change the shell's
  own settings page would make and it survives a restart.

### Changed
- **5-hour session windows are off by default.** Fred: *"I really dont care
  about the 5hr window so make that optional to TURN ON."* The weekly and
  monthly windows are the ones that bite. Turn the session windows back on in
  SETUP.
- **Right-click only answers a warning now.** Choosing what is shown moved to
  SETUP with everything else.
- **With every subscription showing, every box is ticked.** A row of empty boxes
  under a ticked "All lanes" read as a contradiction. Unticking one from there
  now means everything except that one.
- No long dashes in anything the plugin says: tooltips, the fault line, the
  manifest and the collector's usage text.

### Tests
- The burndown series (normalised, ends on the present, never mixes windows, is
  thinned rather than shipped whole, and still draws with no samples).

## 1.27.0 (2026-09-20)

### Added
- **"Stop in 12h 8m (1:04 AM) to leave tomorrow whole."** Fred: *"tell you that
  you should stop for the day with this sub in $time to recover for the next
  day."* A rate per hour says how fast, not when to put it down. Each limit now
  works out the share of what is left that belongs to the next 24 hours, divides
  it by how fast the subscription is actually burning, and names the moment.
  When today's share is already gone it says so and, if it can, how long
  stopping takes to square it.

### Fixed
- **No rate could ever form for Claude.** Providers re-state the same reset with
  millisecond jitter: Claude's weekly moved across 56 distinct values inside one
  second, and samples were matched to a window by exact equality, so a sample
  almost never belonged to "this" window. A window is now identified to the
  minute, which also makes a dismissed warning stay dismissed. Stored samples
  were migrated in place.
- **A duplicate declaration made the widget vanish twice in one afternoon** (a
  second `onOpenedChanged`, then a second `clockText`). QML allows one handler
  per signal and one method per name; qmllint parses both happily and only the
  shell complains, by which point the bar is empty. `tests/test_qml_duplicates.py`
  now fails the build instead.

## 1.26.0 (2026-09-20)

### Added
- **The right-click menu is multi-select.** Fred: *"on right click multi
  selection possible."* Every lane is a tickbox and any combination can be on at
  once: Claude and Kimi without the rest, say. The menu stays open while you
  pick, ticking every lane or unticking the last one both mean "all of them"
  (an empty strip helps nobody), and a single-lane pick made before this still
  means what it said.

### Fixed
- **"1.0x over" contradicted itself.** 1.0x is exactly on target, so a ratio
  that rounds to 1.0 now reads "at pace" and only a real overspend carries a
  multiplier.

## 1.25.0 (2026-09-20)

### Fixed
- **Kimi had no lane, no rate row and no token mix, only plan rows.** Kimi Code
  rides inside Claude's transcripts, so presence was decided by finding a
  Kimi-model turn. A machine with Kimi configured but no Kimi turn today showed
  nothing, while its plan sat in the cockpit saying otherwise. Fred: *"It should
  default on install to all known lanes for that machine."* Presence now also
  counts a machine whose Kimi plan or quota came back from Kimi's own API, and
  the RATE grid and TOKEN MIX gained the Kimi rows they never had.
- **The tooltip claimed "0 tokens" while tokens were burning.** In the seconds
  after a shell restart, before the first `history.json` is parsed, every total
  is zero and the tooltip said so with confidence. It now says "collecting…"
  until the service has actually read something, the same way a stale quota is
  withheld rather than shown as 0%.

### Changed
- **The strip is a fixed size by default.** Fred: *"Remove its variable size. I
  like the size of it right now."* A widget that changes width with the bar's
  mood is hard to read and hard to find. Filling the room beside it is still
  available as a setting, it is simply off by default, and the default width is
  150.

## 1.24.0 (2026-09-20)

### Fixed
- **The over-budget chip was a curtain across the strip.** It was drawn inside
  the graph and, on a crowded bar, covered the lanes, gauges and history it was
  complaining about. Fred: *"looks like we lost ALL our original burn bar
  information."* The badge now sits BESIDE the strip as a sibling, and the graph
  starts after it, so the warning and the burn history share the widget instead
  of one hiding the other. It takes at most 42% of the strip and shortens its
  own label to fit: "CODEX 8.7x OVER", "CODEX OVER", "8.7x OVER", "8.7x".
- **The widget failed to load entirely** once the menu landed: BurnPanel already
  had an `onOpenedChanged`, and QML allows one handler per signal in a scope, so
  the second one made the whole type unavailable ("Property value set multiple
  times") and the bar drew nothing, with the only evidence in the shell's own
  log rather than the plugin's. The mode reset folded into the existing handler.

### Added
- **Right-click opens a menu rather than cycling.** Every view at once: all
  lanes, or any single subscription, with the current pick marked and each
  subscription's verdict beside it. Plus "Warn me again", which re-arms every
  dismissed warning without waiting to overspend further.

## 1.23.0 (2026-09-20)

### Added
- **A warning you have answered goes quiet until it gets worse.** Fred: *"once I
  click it it should fade away but still hit the next stage of usage."* Clicking
  the strip (or right-clicking it) acknowledges the warning it is showing: the
  chip fades out and stays gone until THAT subscription reaches a worse stage or
  its window rolls over. The stages only exist while a window is over pace:
  1 over, 2 way over (1.5x), 3 badly over (2.5x), 4 spent out early. Being
  nearly spent at the end of a window you spent evenly is not a warning.
  Acknowledgements are per subscription and live in
  `pace-ack.json`, so a shell restart does not re-open a question already
  answered.
- **Right-click changes what the icon shows.** It walks through every lane, then
  each subscription this machine actually uses (Claude, Codex, Grok, Kimi, the
  local GPU), then back to all of them. The choice persists through the bar the
  same way every other inline widget setting does.

### Fixed
- The pace block now carries `resetsMs`, the identity of the window instance.
  Acknowledgement needed it: `backOnPaceAt` moves every time the percentage
  does, so keying on it would have re-opened a warning seconds after it was
  answered.

## 1.22.0 (2026-09-20)

### Changed
- **Over budget now says so, in words, at a size you can read.** Fred: *"I need
  it to be more visible. it's small and hard to understand."* A one-pixel tick
  and a grey caption were not that.
  - **The strip carries a pulsing chip** naming the service and the verdict
    while any window is past an even spend: "CODEX 8.7x OVER", falling back to
    "CODEX OVER", then "8.7x OVER", then "8.7x", always taking the longest
    label that actually fits. The service and the word OVER outrank the exact
    multiplier, because they are the parts that need no translating. When
    nothing is over budget the chip does not exist.
  - **The cockpit rows speak plainly.** Each limit row now carries a bold
    verdict (ON TRACK, AT PACE, OVER, WAY OVER), a bar thick enough to read
    across the room with a bright tick at the point an even spend would have
    reached, and a full sentence: "100% spent, 11% of the window gone ·
    nothing left until it resets". The sentence wraps instead of eliding to
    "still ma…", and "at this rate" is omitted entirely when nothing is
    actually burning rather than reporting "ends at 0%".

## 1.21.0 (2026-09-20)

### Added
- **Budget pace: am I over, and will I make it to the reset?** Fred: *"tell me
  when I'm over budget ... if I will make it to my next reset if I keep
  consuming at the same rate ... when I get back into 'making it'."* On budget
  means an even spend across the window, so the pace ratio is used divided by
  elapsed: 1.0 is exactly on pace. Every limit row in the cockpit now carries a
  line under it, and the strip's quota gauges carry the same verdict as colour.
  - **The gauges tint by pace**, urgent past 1.25x and warmer between 1.0 and
    1.25x, with a thin tick at the point an even spend would have reached by
    now. The gap between that tick and the fill is the overspend, with no
    number to read.
  - **The cockpit line** says how far over or under, what may still be spent per
    hour and still make it, where the current rate lands by the reset, when the
    window runs dry if that is before the reset, and when it comes back on pace
    if the burning stops.
  - Nothing is invented. A row with no measurable rate says nothing about "at
    this rate"; a blown window says "nothing left until the reset" rather than
    offering 0.0%/h; and "back on pace" is withheld when it is simply the reset
    again, which is what it always is at 100%.

## 1.20.0 (2026-09-18)

### Added
- **Kimi card on the top row, and a quota bar on every cloud card.** Each cloud
  card carries its binding limit as a bar plus a percentage: weekly for Claude,
  Codex and Grok, monthly for Kimi, which is what Kimi meters. Localhost keeps
  the shorter card: it has no quota, and drawing one would say something
  untrue. A withheld figure draws a dim bar and an em dash, never a confident
  0%, so Grok's real 0% and an unknown still look different.
- The Kimi card gates on having a plan rather than on burn, the same correction
  v1.17.1 made to its PLAN LIMITS row. It reads 0 tokens and 1% monthly today.

### Changed
- Panel width 1360 → 1480. Four cards without bars already filled 1360.
  `fittedContentWidth` clamps to the screen, so a narrower display shrinks the
  row rather than overflowing.

## 1.19.0 (2026-09-18)

### Added
- **A maximum width measured per lane, in inches.** Fred: *"have a max space it
  can take ... per claude / codex / grok / local and can shrink if needed."* The
  strip now refuses to grow past an allowance for each visible lane (Claude,
  Codex, Grok and the local GPU), set with **Max per lane (0.1 in)**, default 10
  = one inch per lane. The allowance is physical, converted through the screen's
  own pixel density, so the strip covers the same span of desk on a 27" 4K as on
  a 49" ultrawide instead of ballooning with the pixel count. A monitor whose
  EDID reports an absurd density (outside 50..300 dpi) falls back to the logical
  density, and a density that cannot be read at all means no physical cap rather
  than a collapsed strip. `maxWidth` still applies as the absolute ceiling, the
  floor always wins over the cap, and the crowded-bar yield from 1.13.0 is
  unchanged: this sets how much it may take, not how little.
- **The strip publishes `stretchMinWidth` and `stretchMaxWidth`.** It has always
  read those two off a stretching neighbour; publishing its own is what lets the
  neighbour absorb the room this cap makes it refuse, instead of the gap sitting
  blank.

## 1.18.0 (2026-09-18)

### Fixed
- **Kimi's plan limits are live figures, not a tier badge.** The percentages come
  from `/usages`, not `/usage`, so Session (5-hour) and the rest are real.

## 1.17.1 (2026-09-18)

### Fixed
- **PLAN LIMITS listed Grok twice and never listed Kimi's plan.**

## 1.17.0 (2026-09-18)

### Added
- **Kimi3 gets its own lane, stat tile, rate row, token-mix row and buckets.**
  Kimi Code speaks the Anthropic API, so its burn had been billed to Claude.

## 1.16.0 (2026-09-18)

### Fixed
- **A withheld plan limit now says what to do about it.** The usage records carry
  two strings, not one, and the cockpit had shown neither when a limit was
  withheld.

## 1.15.0 (2026-09-18)

### Fixed
- **Grok's weekly limit read "-" for days.** Plan limits were judged stale after
  15 minutes, which is right for Claude and Codex because Burn Bar re-probes
  those records itself every 5 minutes. Nothing re-probes Grok: its figure is
  tailed from `~/.grok/logs/unified.jsonl`, and Grok Bot writes
  `billing: fetched credits config` only when it starts (44 lines in six days).
  So the row was blank within a quarter hour of Grok Bot launching and stayed
  blank, while the billing window it described was still open. Limits now carry
  `limitsLive`: a re-probed record is still condemned by age, a snapshot is
  judged by its own window (`resetsAt`) and shown with a dim
  "snapshot measured ..." caption instead of a red "stale" one. The strip gauge
  and the tooltip come back with it.

## 1.14.0 (2026-09-13)

### Fixed
- **Moving work to a faster local backend lowered the offload share.** The share
  counted only Ollama's journal. On gus the fast hooks moved to local-ai
  (TabbyAPI) and recall embeddings moved to the Intel NPU. Neither writes a
  journal line, so the gauge fell while more work ran locally. Those callers now
  append one line per request to `local-usage.jsonl` beside `history.json`. The
  collector adds those lines to the local lane, and by-model shows them as
  `local-ai:<model>` and `npu:<model>`. Ollama calls are never written there, so
  nothing is counted twice.

## 1.11.0 (2026-09-10)

### Changed
- **The cockpit fits the screen again, three columns, not two.** With the panel
  height cap patched out, a panel that outgrows the screen does not scroll, it
  clips: no scrollbar, no hint, the rows below the fold simply are not drawn. On
  a 1080p screen the single tall cloud stack was silently losing CLAUDE BY MODEL,
  the status line and the whole About row. The cloud side is now two short
  columns (chart plus PLAN LIMITS, then RATE, TOKEN MIX and the by-model bars)
  with the localhost GPU column third, and the panel widened from 880 to 1360.
  Width is the remedy, never height.

### Fixed
- **The About line lost its version under a replacement bar.** It read the
  version out of `pluginRegistry`, but a widget hosted by a replacement bar gets
  a service-less facade with no registry on it, so the version silently vanished
  while the repo and site survived only because they have literal fallbacks. The
  panel now reads the `manifest.json` sitting next to it and treats the registry
  as a bonus.

## 1.10.2 (2026-09-10)

### Fixed
- **Grok plan limits froze and never refreshed.** Grok has no stock Omarchy
  probe, so nothing ever rewrites `agents/usage/grok.json`; once that record
  exists it is pinned to whatever it said the day it appeared. The collector
  preferred it over the live `~/.grok/logs/unified.jsonl` whenever it merely
  had a non-empty `limits` array, so a six-day-old record with an already-reset
  window shadowed the log permanently and reported a confident `0%` with an
  empty status, which the panel had no reason to question.
- The two sources are now chosen between on evidence: a window that is still
  open beats one that has already reset, and between two of the same kind the
  more recently measured wins. A set whose window has reset now carries
  "Grok window has reset; run grok to refresh" instead of an empty status, so
  the panel says why the figure is withheld rather than just dimming it.

## 1.10.1 (2026-09-09)

### Fixed
- Transcript discovery skipped any session store symlinked in from another
  disk. `os.walk` does not follow directory symlinks by default, so every
  transcript under one contributed nothing and nothing was said about it.
  It now follows them, with a device/inode guard so a symlink cycle cannot
  walk forever. No store on this machine is symlinked, so no numbers change.

### Notes
- Found by auditing every input surface for that shape after the same class of
  bug turned up in Beatdeck. The rest came back clean, measured against what is
  actually on disk: Claude accepts 18081 of 18086 records carrying
  `message.usage`, the five drops being genuinely empty; Codex accepts 1540 of
  1561 `token_count` events, the 21 drops being the documented rate-limit
  repeats with an unchanged cumulative total; Grok keeps 13 of 62 prompts with
  a rise, the other 49 all older than the 25-hour prune cap against a 24-hour
  maximum window, the newest of them by 0.2 hours.
- Deliberately still ignored, each checked rather than assumed: Grok's
  `events.jsonl` carries only `first_token` timing and no counts,
  `~/.codex/history.jsonl` carries prompt text and no counts, and
  `fireworks.json` is a stub with `ready: false` and every total zero.

## 1.10.0 (2026-09-09)

### Added
- **The strip follows the Omarchy theme.** Each lane takes its hue from the
  active theme's `colors.toml` (Claude from `orange`, Codex `green`, Grok
  `magenta`, local `blue`, each with a fallback key), while keeping Burn Bar's
  own saturation and lightness. Taking the theme colour whole turns the strip
  pastel on the muted themes and it stops reading as heat; taking only the hue
  re-tints with the desktop and the embers keep their glow. Quota and
  temperature ramps map literally, since green/yellow/red mean the same thing
  in every theme. The palette is watched, so switching theme re-tints live.
- `themeColors` bar setting, default on. Off pins the built-in Claude orange,
  Codex teal, Grok rose and local violet on every theme.

### Changed
- PLAN LIMITS moved above RATE in the cockpit: how close you are to the wall is
  more urgent than how fast you are burning.

### Notes
- The shell's own `Color` singleton keeps only foreground, background, accent,
  urgent and muted, so the plugin reads `colors.toml` itself. Five of the
  installed themes ship no such file; those fall through to the built-in ramp.

## 1.9.0 (2026-09-07)

### Added
- **About line in the cockpit.** Version, source repo and nixfred.com at the
  foot of the panel. The manifest carries all three (`version`, `repository`,
  `homepage`) and the panel reads them, so there is one place to edit.
- **Cells follow the width.** `bars` is now the floor, not a fixed count: a
  stretched strip asks the collector for one bucket per cell it can draw at
  ~6px pitch, up to 240. On a 5120px screen that is 52 buckets and 7.5-minute
  resolution instead of twelve 33px blocks.
- The strip takes the gap when Now Playing yields it (nothing playing), rather
  than splitting evenly against a share the neighbour has disclaimed.

### Fixed
- **Every lane width was NaN when all three cloud agents were present.** The
  `graph.grokSep` property was shadowed by an Item with `id: grokSep`; a QML id
  outranks a same-named property, so `grokSepSpace` bound an Item into a real.
  That fed `inner`, `sideWidth` and every lane width. Qualified the binding and
  renamed the id; `tests/test_qml_id_shadowing.py` guards it.

### Changed
- `maxWidth` default 1200 → 2400. 1200 never bound a 1920px bar and stopped a
  5120px one 700px short of the gap.


### Added
- `burnbar-collect --help` prints the flags and exits without collecting.
  Asking for help used to run a full collection and print nothing.

### Fixed
- A state directory the collector cannot write is now one clear line on stderr
  and a non-zero exit, instead of a Python traceback in the service journal.

### Docs
- The Grok source bullet sat after the "Two clocks" paragraph rather than with
  the other sources; the list reads Claude, Codex, Grok, Limits again.

## 1.8.0 (2026-09-06)

### Added
- **Agent detection.** The strip and cockpit only show Claude, Codex and Grok
  when this machine has actually used them (transcripts on disk). A Grok-only
  box lights Grok. A quiet hour does not hide a lane that was used yesterday.
- **Compute-GPU detection.** NVIDIA, AMD and Jetson count. Intel integrated
  graphics does not. No GPU → no local lane, no local column in the cockpit,
  no ssh to a host named nano, no 2.5s poll. Discovery retries every 5 minutes
  so a GPU that appears later can still light the lane.
- Local NVIDIA telemetry via `nvidia-smi` when the Ollama box is this machine.

### Changed
- Default `ollamaUrl` is `http://127.0.0.1:11434` and `localHost` is
  `localhost`. Point them at `nano` if the Ollama box is a Jetson on the
  tailnet. Existing configs that already set those keys are unchanged.
- Plan-limit refresh only asks Omarchy for the cloud agents that are present.
- **Stretch shares the hole with Now Playing.** Beatdeck sizes itself as
  (gap minus our implicitWidth). Burn Bar now reports a fair half of that
  gap, measured from Beatdeck's left edge, so the two converge instead of
  one eating the other or painting through the temperature. The strip
  clips to its slot.

## 1.7.0 (2026-09-06)

### Added
- **Grok as a third cloud agent.** `burnbar-collect` reads
  `~/.grok/sessions/**/updates.jsonl` (Grok Build / CLI sessions beside Grok
  Bot) and estimates per-prompt burn as the rise in `_meta.totalTokens` within
  each `promptId`. Weekly credit limits come from the newest
  `billing: fetched credits config` line in `~/.grok/logs/unified.jsonl`, with
  a fallback to `~/.local/state/omarchy/agents/usage/grok.json` when present.
- Strip lane + hover tooltip for GROK (rose ramp), cockpit tile, rate row,
  token-mix row, and plan-limit gauges, Claude and Codex reporting unchanged.

### Notes
- Grok does not persist a full API token ledger the way Claude/Codex do; the
  heat is an estimate from context growth, not billed token counts. Empty Grok
  heat with a live weekly gauge is a normal state.


## 1.6.0 (2026-09-05)

### Added
- **The strip fills the room beside it.** The bar's sections do not negotiate
  for space: each row is pinned to its own edge and nothing hands out what is
  left between them, so the widget now measures the gap itself, the way the
  Now Playing deck (beatdeck) does on the left: where the neighbouring section
  begins, what the siblings in its own row still need, and it takes the rest.
  Loop-safe because no input depends on its own width: siblings in the same
  row are measured by `implicitWidth`, never by position, and the fixed edge
  is chosen from where the widget sits, left row or after the centre anchor
  grows rightward, right row or before the anchor grows leftward, an
  unanchored centre row widens until either end touches, and as the anchor
  itself it grows both ways bounded by the tighter side. Re-measured when
  slots are added or removed, when the bar resizes, on a 60 ms settle after
  each, and on a 500 ms safety tick for the geometry changes QML gives no
  signal for.
- Settings `stretch` (default on), `maxWidth` (default 1200) and `stretchGap`
  (default 14).

### Changed
- `width` is now the **minimum**: the narrowest the strip will go, and its
  fixed width with `stretch` off. Existing configurations keep their meaning
  as the floor; nothing gets narrower than before.

## 1.5.0 (2026-09-05)

The local lane moves off this machine. dex has no GPU and no Ollama; nano,
a Jetson Orin Nano Super on the tailnet, has both. Every call that used to
go to the local GPU now goes to nano: residency and model control over HTTP,
hardware telemetry and the token journal over ssh. The strip, the cockpit and
the numbers are the same instrument pointed at a different box.

### Added
- **`nano/ollama-meter.py`, a metering reverse proxy for the Ollama box.**
  Ollama 0.15 persists no per-request token counts anywhere: nothing in its
  journal (`OLLAMA_DEBUG=1` only adds the prompt-cache slot line), no metrics
  endpoint. Every response *does* carry `prompt_eval_count` and
  `eval_count`, so the meter sits on Ollama's public port, forwards
  everything byte for byte, streams relayed chunk by chunk, first token in
  0.37 s, and writes one journal line per request with the counts off the
  way out. `/api/generate`, `/api/chat`, `/api/embed`, `/api/embeddings` and
  the OpenAI-compatible `/v1/*` (from `usage`) are all read. Whatever asks
  is counted the same.
- **`nano/install.sh`** puts it there: the meter unit, a drop-in that moves
  Ollama to loopback `:11435` and sets `OLLAMA_NUM_PARALLEL=1`, and a sysctl
  reserving 1 GiB (`vm.min_free_kbytes`). Rollback is three commands in the
  header.
- Settings `ollamaUrl` (default `http://nano:11434`), `localHost` (the ssh
  alias, default `nano`) and `meterUnit` (default `ollama-meter`).
- **The lane is called by the box's name.** Wherever the strip and cockpit
  said LOCAL (the tile, the tooltip, the RATE and TOKEN MIX rows, the
  tokens header, the footer), they now say NANO (the `localHost` setting,
  upper-cased), so the instrument names the machine it is reading.
- The cockpit's local header names the box and, when residency answered but
  ssh did not, says "no hardware telemetry" with the reason in red, never a
  board full of zeros. POWER DRAW carries the CPU/GPU/CV rail under the
  whole-board figure.

### Changed
- **Telemetry comes from the Jetson's sysfs over ssh**, not `nvidia-smi`:
  on a Jetson `nvidia-smi` exists and answers `[N/A]` to every query, and
  `tegrastats` needs a second per sample. One shell snippet reads the nvgpu
  devfreq node (load, clock), the gpu thermal zone, the INA3221 rails
  (VDD_IN for the board, VDD_CPU_GPU_CV for inference), the fan PWM,
  `/proc/meminfo` for the unified memory, and the ollama processes' CPU
  ticks 200 ms apart. Backend reads `TEGRA`; VRAM is now MEMORY · UNIFIED;
  SM CLOCK is GPU CLOCK.
- **Local tokens come from the meter journal on nano**, read over ssh by
  cursor, one round trip per collector run. The runner-log state machine is
  gone; each meter line is self-contained. Cache reads are 0: Ollama does
  not report prompt-cache hits in its responses.
- **Load & keep warm drops nano's page cache first** (`ollama-prepare.sh`
  over ssh, passwordless sudo). The Jetson's GPU and its page cache share
  one pool; a load that needed a contiguous 1–2 GiB failed with cudaMalloc
  out-of-memory every time the cache had grown since boot. The sysctl
  reserve above is the standing fix; the drop is belt and braces for the
  button.
- `localRefreshMs` default 1500 → 2500, floor 500 → 1000: a poll is one HTTP
  call and one ssh round trip (~1.3 s), not a /proc read.
- Both scripts default to `http://nano:11434`; `OLLAMA_HOST` still
  overrides. `ollamaUnit` and `BURNBAR_OLLAMA_JOURNAL` are gone;
  `BURNBAR_METER_JOURNAL` is the test hook.

### Fixed
- ssh joined the remote argv with spaces and handed it to a shell, so
  `-g 'meter ts='` arrived as two arguments and journalctl refused the
  match. Every remote word is shell-quoted now.

### On nano itself
- Ollama listens on `127.0.0.1:11435`; `ollama-meter` on `0.0.0.0:11434`.
- `OLLAMA_NUM_PARALLEL` 5 → 1 in `ollama.service.d/zz-burnbar.conf`
  ("zz-" because an older `override.conf` there sets the same variables and
  drop-ins apply in name order).
- `vm.min_free_kbytes` 45056 → 1048576 in `/etc/sysctl.d/90-burnbar-ollama.conf`.
  Three model swaps in a row loaded without a cache drop afterwards; loads
  read a little more from disk in exchange (55–60 s cold vs 35 s).

## 1.4.0 (2026-09-05)

### Added
- **Local tokens and the offload share.** The cockpit now shows how many
  tokens burned on the local Ollama over the same exact window as the cloud
  figures, and what share of everything that burned stayed on this machine
  instead of going to a frontier model. Header: "… · 27% kept local". The
  LOCAL tile leads with local tokens (same unit as its neighbours), the
  offload share, turns and rate. The local column opens with a LOCAL TOKENS
  section: an offload gauge and a line with prompt / generated / cached
  counts and the model that did most of it. RATE and TOKEN MIX gain a Local
  row. The strip's local tooltip carries the total and the share.
- **Source: the Ollama unit's journal.** Ollama persists no per-request
  token counts anywhere and exposes no metrics endpoint (verified on
  0.32.15), but its runner logs every task, prompt size, cached prefix,
  evaluated prompt tokens, generated tokens, release, timestamped, whatever
  client asked. The collector reads that journal incrementally by cursor
  (`journalctl -u <unit> -o short-unix --after-cursor …`, server-side
  filtered): ~600 ms once per window, ~10 ms per run after. Model comes from
  the `general.name` line each load prints. Burn is evaluated prompt +
  generated; the cached prefix rides along as the cache read, the way cloud
  cache reads do. A cursor the journal can no longer seek to is detected and
  the window re-read.
- `ollamaUnit` setting (default `ollama`) for installs whose Ollama runs
  under another unit. If the journal is not readable from your account, or
  the unit does not exist, the panel says so in red instead of showing a
  confident 0; the last-known points are kept in the cache meanwhile.
- `BURNBAR_OLLAMA_JOURNAL` points the collector at a file for tests; the
  fixture uses real line shapes from Ollama 0.32.

### Changed
- Header reads "frontier tokens burned" to make clear the big number is
  cloud spend; local tokens live beside it, not inside it.
- Buckets carry a `local` series alongside `claude` and `codex`.

## 1.3.3 (2026-09-05)

Full-scope adversarial audit (Codex, gpt-6-astra, read-only, 24 minutes) over
1.3.2: every file, the tests, the docs, and a regression pass over the 1.3.2
fixes. 45 findings. Each was checked against the code, and the two that
mattered most were reproduced first: 13 repeated Codex token counts in 8 of
130 real rollouts on the development machine, and Ollama refusing to warm an
embedding model through `/api/generate`. Everything below is fixed unless
marked otherwise.

### Counting (bin/burnbar-collect, rewritten)
- **Codex could double-count a turn.** Every `token_count` event was treated
  as a turn, but a rate-limit refresh re-emits the same `last_token_usage`
  with an unchanged cumulative total. The collector now counts deltas of
  `total_token_usage` per file, carries the baseline across incremental tail
  reads, skips an unchanged snapshot, and falls back to the event's own
  usage on a counter reset or on an older format without totals.
- **Claude kept the first streamed revision.** A message is re-serialised as
  it streams with growing output; the first seen won and later revisions
  never updated the totals. The largest revision now wins.
- **Two clocks.** Totals, rates, turns, activity, split and by-model are now
  computed over the exact trailing window from timestamped points; the
  grid-aligned buckets only draw the strip and chart. "last 6h" used to mean
  330–360 minutes depending on the clock. Exact 5- and 60-minute sums travel
  as `trailing`, and the panel's rates divide them by exactly 5 and 60,
  "1 HOUR" no longer covers 31 to 61 minutes and the one-minute denominator
  floor is gone.
- **Every count is validated on its own.** Negative components, booleans,
  and numbers that only fit a float (`1e999`, which raised `OverflowError`
  past the previous guard and aborted both agents on every run) reject the
  record. Codex `cached_input_tokens` above `input_tokens` is malformed.
- **A record that only read cache is still a turn** and still feeds the
  cache-read line; it just adds nothing to the heat.
- **A longer rewrite is not an append.** 48 bytes just before the saved
  offset are remembered and must still match before a resume is trusted.
- **Cache entries are validated** and versioned; a malformed one is a cache
  miss for that file. A file whose cached replay throws is rescanned once.
- **Cached points are pruned** to the longest supported window plus an hour,
  so a session that runs for a week no longer rewrites its whole history
  every five seconds.
- **Writes use unique temp files and a per-directory lock.** Two collectors
  sharing a state dir used to race on `history.json.tmp`; now the second
  leaves quietly.
- `peakAt` is 0 when nothing peaked, so the panel shows `--`.
- `BURNBAR_NOW_MS` pins the clock for tests; the idempotency test no longer
  fails when it straddles a bucket boundary.

### Service.qml
- A snapshot is validated in full, every bucket, both agents, before any
  property changes; `{"buckets":[null]}` used to clear the fault and throw.
- `file://` URLs are decoded to paths; a `#` in the install directory broke
  every helper.
- The local ring keeps sample timestamps; the trace caption shows the span
  it actually covers instead of cells × interval.

### BarWidget.qml
- Cell counts come from the service's clamp, not a second one that disagreed
  on `bars: 0`; a configured width too narrow for its cells is raised so
  cells never overlap.
- A cloud fault no longer reddens the local lane or zeroes its energy.
- Idle flicker no longer restarts a 420 ms height animation on every cell
  five times a second; motion is a scale on top of an eased sample height.
- Shockwaves travel outward only: position has its own monotonic progress,
  flash is brightness alone.
- Quota heartbeat, live-cell ring and reactor loops are gated on their
  instrument actually being shown, and each restores its property when it
  stops: a quota that dropped under 90% mid-pulse was left dim.
- Window labels are exact ("1h40m", "30m"), never rounded to hours.

### BurnPanel.qml
- Tiles are three persistent instances; a fresh model array every tick was
  destroying and recreating them, so the count-up never showed.
- Rate columns: 5 MIN / 1 HOUR / exact window, from the trailing sums.
- Chart labels land on the bucket that starts each hour and show minutes
  when it does not start on the hour ("7:30 PM", not "7 PM").
- Claude-by-model and resident-model lists cap at six rows with a "+ N more"
  line, so a 30-model install cannot push the footer off screen.
- A model removed outside the panel is no longer left selected.
- "tokens billed" → "tokens burned" (cache reads are excluded, and they are
  billed); "saved N%" → "N% of all input" (a token share, not money);
  "N IN VRAM" → "N LOADED" (`/api/ps` lists CPU-resident models too).
- Remote Ollama (`OLLAMA_HOST` elsewhere) shows "no local hardware
  telemetry" instead of this machine's GPU.

### bin/burnbar-local-status
- One `[N/A]` no longer discards every GPU reading; devices are parsed one by
  one, the busiest wins, and name/power/memory are read for that device.
- A remote endpoint gets no `/proc` or GPU attribution at all.
- Runner CPU is per-PID; a runner exiting between samples read as 0%.
- A 400-digit integer in `/api/ps` no longer raises out of `main()`.
- URLs with a query or fragment are rejected instead of corrupted.

### bin/burnbar-local-control
- Embedding-only models are warmed through `/api/embed` (`/api/show`
  capabilities decide); generate refused them.
- A model name that would need truncating is refused, never shortened into
  a different model's name.

### Tests and docs
- Shell fixture isolates `XDG_CACHE_HOME` from the first run and pins the
  clock. Nine new collector fixtures, eleven new Python unit tests.
- README and SECURITY.md corrected: Burn Bar triggers Omarchy's collectors
  that contact Anthropic's usage endpoint; the scan cache holds model names,
  message ids and transcript paths; `burnbar-local-control list` runs on
  panel open; traces encode recency in brightness; unsupported GPU tiles
  show dashes rather than disappearing.

### Not changed
- Vertical bars (left/right) are not supported; the strip lays three lanes
  across the bar's length. Documented.
- The panel still never scrolls, by design; the row caps above are the
  overflow control.
- A game running while a model sits idle in VRAM still reads as local load;
  the runner cannot say more.

## 1.3.2 (2026-09-05)

Adversarial bug hunt (Codex, gpt-6-astra, read-only) over 1.3.1. Seventeen
findings, every one verified against the code or by execution before it was
fixed. In severity order:

### Fixed
- **A refreshed record could give an old Claude figure a fresh timestamp.**
  Omarchy's Claude collector re-stamps its record with *cached* limits when
  the probe fails or the sign-in has lapsed, so 1.3.1's staleness check,
  keyed on the record's `updatedAt`, would have called an eight-hour-old 0%
  fresh again the moment anything rewrote the file. The collector now reads
  `fetchedAtMs` from Omarchy's probe cache, which only a successful probe
  writes, and uses that as the measurement time (`limitsMeasuredAt`). A
  silent fallback (`retryAdvised`) surfaces as "last probe failed, showing
  last known".
- **Quickshell emits no `exited()` for a command that cannot start.** Verified
  on 0.3.1: a missing binary flips `running` back to false and nothing else.
  So the 1.1 promise that a missing `python3` shows a fault was never true,
  and 1.3.1's exit-127 guard on the limits refresh never fired. Every process
  now tracks whether it ever started and treats a start failure as a fault:
  the strip goes red for a missing runtime, the limits refresh gives up
  instead of retrying every cycle, and a model action hands the buttons back.
- **The limits watchdog only killed the wrapper.** `omarchy-agent-usage-update`
  backgrounds one subshell per collector and waits; a SIGTERM to it orphaned
  the probes. It now runs under `setsid` in its own process group and the
  wrapper's trap tears the whole group down.
- **A weekly figure was never substituted with a session one.** `limitPercent`
  fell back to the first limit when no label matched "weekly"; a record with
  only a session window read as an 80% weekly quota. No match is now unknown.
- **Percentages are normalised one by one.** `null` read as 0%, `"bad"` raised
  past the JSON guard and aborted both agents' collection, `"NaN"` wrote a
  file the widget could not parse, and a raw `-1` reached the panel as
  `-100%`. Anything that is not a finite 0..1 fraction is now -1 (unknown)
  in the collector, the panel treats -1 as unknown, and the writer refuses
  NaN.
- **One malformed transcript record no longer aborts collection.** Valid JSON
  with the wrong shape (`"input_tokens": "unknown"`, `"info": "bad"`) raised
  outside the JSON guard and did so again on every run. Extractors now treat
  the whole record as untrusted and skip it.
- **A successful refresh's re-collect was dropped** if a scan was already in
  flight (which had read the old records). Pending collects now coalesce and
  run once the current scan exits.
- **A zero exit no longer clears the fault before the file is validated.** An
  unparseable or shapeless history.json now sets the fault; the fault clears
  only after a snapshot has been applied.
- **A failed local sample invalidates every current reading.** The error path
  used to keep GPU load, VRAM, clocks, temperature, version and the resident
  model list on screen under an OFFLINE header.
- **Local processes have deadlines.** Probe 15s, model list 15s, model action
  3 minutes; each cleans up its own state when it fires.
- **Unrelated GPU work is not inference.** With no model resident the lane
  reads the runner's CPU only and never goes "active". A game beside an idle
  resident model still reads as load; the runner cannot say more.
- **A displayed tooltip now follows the data.** Hover text is a binding, so a
  tooltip left open through a rollover, a new sample or a collector failure
  updates under the pointer instead of keeping its first sentence.
- **`bucketMinutes` was an int.** `windowMinutes / bars` is fractional for
  most settings (100 / 12 = 8.33) and every rate silently used the rounded
  width. Now real; the panel floor is 15 seconds, not a minute.
- **"1 HOUR" covered 31 minutes.** Two 30-minute buckets including the partial
  newest one; the rate now takes enough buckets to cover a full trailing hour.
  Chart hour labels keep their fixed spacing.
- **An equal-length rewrite of a transcript was never rescanned.** The cache
  resumed at EOF when the size matched; equal size with a new mtime is now a
  rewrite.
- **`localThreshold` is clamped 1–50 like the manifest says.** A stray 101
  meant "never inferencing".
- **A missing temperature sensor no longer reads "cool".**

## 1.3.1 (2026-09-05)

### Fixed
- **Claude plan limits showed 0% for hours.** Burn Bar only ever copied the
  limits out of the records `omarchy-agent-usage-update` writes, and nothing
  in Burn Bar kept those records fresh. When the agents panel stopped
  refreshing them, an 8-hour-old record with every Claude limit at 0.0 was
  presented as live, with "resets in now" for a window that had rolled over
  hours earlier. Burn Bar now runs
  `omarchy-agent-usage-update --limits-only claude codex` on its own timer
  (`limitsRefreshSec`, default 300), on panel open, on `R`, and on middle
  click, with a 60s watchdog; the collector's own 15s probe cache keeps that
  cheap.
- **A number nobody can vouch for is withheld, not shown as 0%.** The
  collector now carries each usage record's own `updatedAt` and status text.
  A limit whose reset time has passed reads "window rolled over · awaiting
  refresh" with the percentage withheld; a record older than three refresh
  intervals is flagged stale under the PLAN LIMITS header with its timestamp,
  and any status the record carries ("Sign-in expired", "Waiting for auth")
  is shown there too. The weekly quota columns on the strip go empty and dim
  for an unknown value instead of drawing a green sliver, and their tooltip
  says "unknown · record from 4:12 PM".
- `untilText` no longer says "now" for a time in the past.

## 1.3.0 (2026-09-04)

### Added
- **Cockpit panel.** Two columns at 860px, fitted height, no scrolling, the
  whole instrument in one glance.
- Cloud: burn-over-time chart (Claude up, Codex down, heat-ramp coloured, hour
  labels, breathing live column), tokens-per-minute at three horizons, token
  mix (input / cache-write / output) with cache-read volume and the % the
  cache absorbed, plan limits with both countdown and wall-clock reset time,
  Claude spend by model with share bars, peak-at and last-activity per agent.
- Local: GPU name, backend and Ollama version; GPU load, power draw, temp,
  VRAM used/total with the models' share, SM clock, sample age; load and power
  traces; resident models with params, quant, family, VRAM, context and
  "evicts in" from `expires_at`.
- `burnbar-local-status` returns per-model detail, Ollama version and
  nvidia-smi telemetry (fields the board does not expose read as 0 and hide).
- `burnbar-collect` carries an input / cache-write / output / cache-read split
  per point, plus turns, first/last activity and peak time per agent.

## 1.2.0 (2026-09-04)

### Added
- **Local intelligence lane.** The `io.github.nixfred.local-intelligence` plugin
  is folded in: a reactor core plus a violet strip of live Ollama runner load,
  right of a hard rule. Widget grew 114 → 158, and local takes a quarter of the
  strip rather than a third, free local compute must not read at the same
  weight as metered cloud spend.
- Local model control in the detail panel: pick any installed model and warm it
  into memory or evict it, plus a LOCAL tile and live load bar.
- **Per-section identity and hover.** Each of the three sections carries a
  tinted plate and a baseline in its own hue (Claude orange, Codex teal, local
  violet). Hovering names the section and shows a tooltip for that agent alone,
  instead of one blended tooltip you had to mentally split.
- Sizzle, all of it data-driven: rising sparks whose speed follows total energy,
  an impact shockwave riding outward from the now line, a white-hot core
  filament on genuinely hot cells, an under-glow that brightens with total
  burn, and filament caps on the now line.

### Changed
- The three lanes are now one inline `ThermalLane` component instead of two
  copy-pasted Repeaters, so the visual language cannot drift between agents.
- Weekly quota gauges moved inside the cloud lanes to bookend them, making room
  for local on the outer right.

## 1.1.0 (2026-09-03)

### Changed
- **Collector ported from TypeScript/bun to Python 3 (stdlib only).** `bun` is
  not an Omarchy dependency, so on a stock install the plugin silently rendered
  nothing. Omarchy depends on `uwsm` and `kitty`, both of which depend on
  `python`, so `python3` is always present.
- Collector reads only the appended tail of a grown transcript instead of
  re-parsing the whole file. Warm run 1.4s → ~120ms.
- Widget narrowed to 114 (144px rendered) with 12 cells per agent.

### Fixed
- **Cell count and bucket count could disagree.** The widget drew 16 cells while
  the collector produced 24 buckets, so the strip covered four hours while the
  tooltip advertised six. Both now default to 12 with the same clamp.
- Collector path is resolved from the component's own directory instead of a
  hardcoded plugin id, so a cloned or renamed install still works.
- A failed or missing collector now shows a visible fault state and a tooltip
  reason. Previously the idle animation made a total outage look healthy.
- Added a 30s collector watchdog. A wedged run used to freeze the strip forever,
  because `collect()` refuses to start while one is already running.
- The impact pulse was swallowed on every bucket rollover, because the live
  value resets toward zero when the window advances.
- Ember flicker drops from 20fps to 5fps while idle.

## 1.0.0 (2026-09-03)

Initial release. Mirrored thermal heat map of Claude and Codex token burn with
weekly plan-quota gauges.
