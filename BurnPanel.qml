import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Shapes
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Detail view for Burn Bar. The bar answers "is something burning right now";
// this is the cockpit: what, how much, how fast, how close to the wall, and
// what the GPU is doing about it, all in one glance, never a scroll.
//
// Two columns, hard split. Left is metered cloud spend in tokens; right is the
// Ollama box (nano, a Jetson on the tailnet) in watts, degrees and megabytes.
// Different money, different units, so they never share a column.
//
// Column widths are set explicitly from the content width, never through the
// layout engine's own preferred-size negotiation: a RowLayout whose children
// size themselves from the row's width is a binding loop, and the first
// version of this panel shipped with the left column bleeding under the right.
Panel {
  id: panel
  moduleName: "nixfred.burnbar"
  manageIpc: false

  required property var widget
  readonly property var svc: widget.svc

  // The panel shows the cockpit, or SETUP. One KeyboardPanel, two contents: a
  // second panel for the same owner would fight this one for focus.
  property string mode: "cockpit"

  // Everything the icon can show, with the current pick marked and each
  // subscription's own verdict beside it, so the menu doubles as a summary.
  function viewOptions() {
    void panel.tick
    var w = panel.widget, s = panel.svc
    var out = [{ id: "", label: "All lanes", accent: panel.foreground, note: "" }]
    if (s && s.claudePresent) out.push({ id: "claude", label: "Claude", accent: w.claudeHot, note: paceNote("claude") })
    if (s && s.codexPresent) out.push({ id: "codex", label: "Codex", accent: w.codexHot, note: paceNote("codex") })
    if (s && s.grokPresent) out.push({ id: "grok", label: "Grok", accent: w.grokHot, note: paceNote("grok") })
    if (s && s.kimiPresent) out.push({ id: "kimi", label: "Kimi", accent: w.kimiHot, note: paceNote("kimi") })
    if (s && s.hasComputeGpu) out.push({ id: "local", label: "Local GPU", accent: w.localHot, note: "" })
    var lanes = w.focusLanes || []
    // With nothing singled out every subscription IS showing, so every box is
    // ticked: a row of empty boxes under a ticked "All" reads as a contradiction.
    for (var i = 0; i < out.length; i++)
      out[i].current = lanes.length === 0 || lanes.indexOf(out[i].id) >= 0
    return out
  }

  // Where a sub stands, in the same words the cards use. It used to print a
  // multiplier ("2.0x over"); Fred asked whether 1.0x meant on target, which is
  // the whole case against multipliers. A rest time is something you can act on.
  function paceNote(id) {
    var live = panel.widget.liveFor(id, Date.now())
    if (!live) return ""
    if (live.spent) return "spent until it resets"
    if (live.over) return "rest it " + panel.widget.spanWords(live.comeBackMs)
    if (live.banked >= 0.01) return Math.round(live.banked * 100) + "% banked"
    return "on pace"
  }

  // Ticking a lane leaves the menu open: picking two of four should not cost
  // two round trips through a right click.
  function chooseView(id) { panel.widget.toggleLane(id) }

  // A boolean option as the widget reads it: defaults-on options are off only
  // when explicitly false, defaults-off options are on only when explicitly true.
  function optOn(name, fallback) {
    var v = panel.widget.setting(name, fallback)
    return fallback ? v !== false : v === true
  }
  function flip(name, fallback) {
    var change = {}
    change[name] = !optOn(name, fallback)
    panel.widget.persist(change)
  }

  readonly property color foreground: widget.bar ? widget.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color faint: Util.alpha(foreground, 0.10)
  readonly property string fontFamily: widget.bar ? widget.bar.fontFamily : Style.font.family

  // Identity for the About line. The manifest is the single source of truth
  // for all three, so bumping a version or moving the repo is one edit there.
  // Constants are a fallback for when the registry is not reachable.
  // The registry is the nice path, but a widget hosted by a REPLACEMENT bar
  // gets a service-less facade with no pluginRegistry hanging off it, and the
  // version then vanished from the About line with nothing to say why; the
  // repo and site only survived because they have literal fallbacks. The
  // manifest sits next to this file and is always readable, so read that and
  // treat the registry as a bonus rather than a requirement.
  property var manifestFromDisk: ({})
  readonly property var pluginManifest: {
    var reg = widget && widget.bar && widget.bar.shell ? widget.bar.shell.pluginRegistry : null
    var fromRegistry = reg && reg.installedPlugins
      ? (reg.installedPlugins[panel.moduleName] || null) : null
    return fromRegistry || manifestFromDisk
  }

  FileView {
    path: String(Qt.resolvedUrl("manifest.json")).replace(/^file:\/\//, "")
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { panel.manifestFromDisk = JSON.parse(text()) || ({}) }
      catch (e) { panel.manifestFromDisk = ({}) }
    }
    onLoadFailed: panel.manifestFromDisk = ({})
  }
  readonly property string pluginVersion: pluginManifest && pluginManifest.version
    ? String(pluginManifest.version) : ""
  readonly property string repoUrl: pluginManifest && pluginManifest.repository
    ? String(pluginManifest.repository) : "https://github.com/nixfred/burnbar"
  readonly property string homeUrl: pluginManifest && pluginManifest.homepage
    ? String(pluginManifest.homepage) : "https://nixfred.com"

  // Width is the remedy, never height: a panel that does not fit is clipped,
  // not scrolled, so the data simply disappears with nothing to say it has.
  // Five cloud cards with a quota bar each, rather than four without: the row
  // was already tight at 1360 and a bar needs width to read as a bar.
  // Width follows the cards. One subscription does not need 1500px and five do
  // not fit in it; fittedContentWidth() still clamps to the screen.
  readonly property int panelWidth: Style.space(Math.max(860, Math.min(2300, cardCount * 396 + 44)))
  readonly property int columnGap: Style.space(20)

  // Relative times ("3m ago", "evicts in 4m") go stale the moment they are
  // drawn; a 1s tick re-evaluates every binding that reads it.
  property int tick: 0
  Timer { interval: 1000; running: panel.opened; repeat: true; onTriggered: panel.tick++ }

  // ── entrance ──────────────────────────────────────────────────────────────
  // Everything grows into place on open: bars wipe left→right, numbers count
  // up, sections rise a few pixels as they fade in. Data-driven motion after
  // that: the live column breathes, bars ease to new values, a pulse flashes
  // the chart when the collector lands new burn.
  property real reveal: 0
  property int counterEpoch: 0
  property real chartFlash: 0

  NumberAnimation {
    id: revealAnim
    target: panel; property: "reveal"
    from: 0; to: 1; duration: 720; easing.type: Easing.OutCubic
  }
  SequentialAnimation {
    id: chartImpact
    NumberAnimation { target: panel; property: "chartFlash"; to: 1; duration: 80 }
    NumberAnimation { target: panel; property: "chartFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
  }
  Connections {
    target: panel.svc
    function onClaudePulseChanged() { if (panel.opened) chartImpact.restart() }
    function onCodexPulseChanged() { if (panel.opened) chartImpact.restart() }
    function onGrokPulseChanged() { if (panel.opened) chartImpact.restart() }
  }

  // Left→right stagger for a row of n bars.
  function wipe(i, n) {
    return Math.max(0, Math.min(1, panel.reveal * 1.5 - (i / Math.max(1, n)) * 0.5))
  }

  onOpenedChanged: {
    if (opened) {
      reveal = 0
      revealAnim.restart()
      counterEpoch++
      refreshLocalModels()
      if (widget) widget.refreshGuidance()
      fitCheck.restart()
    } else {
      squeeze = 0
      // Closing forgets the menu: the next left click is the cockpit again.
      mode = "cockpit"
    }
  }

  function switchPanel(direction) {
    if (widget.bar && typeof widget.bar.switchPanelFrom === "function")
      return widget.bar.switchPanelFrom(widget, direction)
    return false
  }

  // ── formatting ────────────────────────────────────────────────────────────
  function untilText(iso) {
    void panel.tick
    var t = Date.parse(String(iso || ""))
    if (!isFinite(t)) return "--"
    var ms = t - Date.now()
    if (ms <= 0) return "rolled over"
    var mins = Math.floor(ms / 60000)
    var days = Math.floor(mins / 1440)
    var hours = Math.floor((mins % 1440) / 60)
    if (days > 0) return days + "d " + hours + "h"
    if (hours > 0) return hours + "h " + (mins % 60) + "m"
    return mins + "m"
  }

  function agoText(ms) {
    void panel.tick
    var t = Number(ms) || 0
    if (t <= 0) return "never"
    var s = Math.max(0, (Date.now() - t) / 1000)
    if (s < 60) return Math.round(s) + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    return (s / 3600).toFixed(1) + "h ago"
  }

  function clockText(ms) {
    var t = Number(ms) || 0
    return t > 0 ? Qt.formatTime(new Date(t), "h:mm AP") : "--"
  }

  // The one word this row is really about. Ratios are for the sentence; the
  // headline has to be readable without translating anything.
  function paceVerdict(limit, unknown) {
    void panel.tick
    if (unknown || !limit || !limit.pace) return { word: "", color: panel.dim }
    var r = Number(limit.pace.ratio)
    if (!(r >= 0)) return { word: "", color: panel.dim }
    if (r > 1.5) return { word: "WAY OVER", color: Color.urgent }
    if (r > 1.05) return { word: "OVER", color: Qt.lighter(Color.urgent, 1.35) }
    if (r > 0.9) return { word: "AT PACE", color: panel.foreground }
    return { word: "ON TRACK", color: panel.widget.gaugeColor(0.2) }
  }

  // The budget sentence under a limit row. On budget means an even spend across
  // the window, so the pace ratio is used-over-elapsed: 1.0 is exactly on pace.
  // Everything here is withheld rather than guessed - a row with no measured
  // rate says nothing about "at this rate" instead of inventing one.
  function paceText(limit, unknown) {
    void panel.tick
    if (unknown || !limit || !limit.pace) return { text: "", urgent: false }
    var p = limit.pace
    var r = Number(p.ratio)
    if (!(r >= 0)) return { text: "", urgent: false }
    var over = r > 1.0
    // How far ahead or behind is the standing line's job now (banked, or a
    // way back), so this sentence is only what follows from it: how fast you
    // may go, where that ends, and when to stop today.
    var parts = []

    var a = Number(p.allowancePerHour)
    if (a >= 0) {
      // A window with nothing left must not be told it may spend 0.0%/h: at
      // that point the only thing that helps is the reset.
      if (a < 0.0005) parts.push("nothing left until it resets")
      else if (a >= 1) parts.push("the rest is yours to spend")
      else if (over) parts.push("slow to " + (a * 100).toFixed(1) + "%/h to make it")
      else parts.push("you can spend " + (a * 100).toFixed(1) + "%/h and still make it")
    }

    // "At this rate" is only worth saying when something is actually burning.
    // A measured rate of zero means idle, and "ends at 0%" is noise.
    if (Number(p.ratePerHour) > 0.00005) {
      if (Number(p.dryAt) > 0)
        parts.push("at this rate dry " + dayClockText(new Date(Number(p.dryAt)).toISOString()))
      else if (Number(p.projected) >= 0)
        parts.push("at this rate ends at " + Math.round(Number(p.projected) * 100) + "%")
    }

    // The rate says how fast; this says when to put it down so tomorrow still
    // has its own share of what is left.
    var stopIn = Number(p.stopInMs)
    if (stopIn > 0)
      parts.push("stop in " + spanText(stopIn) + " (" + clockText(Number(p.stopAtMs)) + ") to leave tomorrow whole")

    if (p.overDaily === true) {
      var rec = Number(p.recoverInMs)
      parts.push(rec > 0 ? "today's share is gone · square again in " + spanText(rec) + " if you stop"
                         : "today's share is gone")
    }
    return { text: parts.join("  ·  "), urgent: over }
  }

  // "2h 10m", "45m" - a duration a human can act on, never a decimal of hours.
  function spanText(ms) {
    var mins = Math.max(0, Math.round(Number(ms) / 60000))
    var h = Math.floor(mins / 60), m = mins % 60
    return h > 0 ? (m > 0 ? h + "h " + m + "m" : h + "h") : m + "m"
  }

  function dayClockText(iso) {
    var t = Date.parse(String(iso || ""))
    return isFinite(t) ? Qt.formatDateTime(new Date(t), "ddd h:mm AP") : "--"
  }

  function prettyModel(id) {
    return String(id || "")
      .replace("claude-", "")
      .replace(/-\d{8}$/, "")
      .replace(/-/g, " ")
  }

  function sortedModels(byModel) {
    var out = []
    for (var k in byModel) out.push({ id: k, tokens: Number(byModel[k] || 0) })
    out.sort(function(a, b) { return b.tokens - a.tokens })
    return out
  }

  function gb(mb) { return (Number(mb || 0) / 1024).toFixed(1) }

  // ── derived cloud metrics ─────────────────────────────────────────────────
  readonly property var buckets: svc ? svc.buckets : []
  readonly property real bucketMinutes: svc ? Math.max(0.25, svc.bucketMinutes) : 30
  readonly property real windowMinutes: svc ? svc.windowMinutes : 360

  // Rates come from the collector's exact trailing sums, tokens in the last
  // 5 and 60 minutes from timestamped points, and the exact window total.
  // No bucket arithmetic: two 30-minute buckets called "1 HOUR" covered 31 to
  // 61 minutes depending on the clock, and a one-minute denominator floor
  // read 90 tokens in a 30-second bucket as 90/min.
  function trailing5(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTrailing5
      : agent === "codex" ? svc.codexTrailing5
      : agent === "grok" ? svc.grokTrailing5
      : agent === "kimi" ? svc.kimiTrailing5
      : svc.localTokensTrailing5
  }
  function trailing60(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTrailing60
      : agent === "codex" ? svc.codexTrailing60
      : agent === "grok" ? svc.grokTrailing60
      : agent === "kimi" ? svc.kimiTrailing60
      : svc.localTokensTrailing60
  }
  function windowTotal(agent) {
    if (!svc) return 0
    return agent === "claude" ? svc.claudeTotal
      : agent === "codex" ? svc.codexTotal
      : agent === "grok" ? svc.grokTotal
      : agent === "kimi" ? svc.kimiTotal
      : svc.localTokensTotal
  }
  function rateNow(agent) { return trailing5(agent) / 5 }
  function rateHour(agent) { return trailing60(agent) / 60 }
  function rateWindow(agent) { return windowTotal(agent) / Math.max(1, windowMinutes) }
  readonly property bool localTokens: svc ? svc.localTokensAvailable : false
  readonly property bool showClaude: widget.showClaude
  readonly property bool showCodex: widget.showCodex
  readonly property bool showGrok: widget.showGrok
  readonly property bool showKimi: widget.showKimi
  // The lane needs burn to draw; a plan row only needs a plan. Kimi's tier
  // comes back from /me, so the subscription is known before a single token
  // has gone through it.
  // One builder for the note under a plan limit, so the standalone caption and
  // the line under an agent's rows can never disagree about whether a figure is
  // trustworthy. Empty text means the record is healthy and needs no comment.
  function limitNote(updatedAt, status, help, live, info) {
    void panel.tick
    if (!svc) return { text: "", urgent: false }
    var stale = svc.limitsStale(updatedAt, live)
    var aged = svc.limitsSnapshotAged(updatedAt, live)
    var quiet = !stale && !aged && status === ""
      && !(svc.limitsRefreshUnavailable && live)
    if (quiet) return { text: "", urgent: false }
    var parts = []
    if (status !== "") parts.push(status)
    // Only when a figure is actually withheld: the remedy is noise otherwise.
    if (status !== "" && String(help || "") !== "") parts.push(help)
    var t = Number(updatedAt) || 0
    if (t > 0) parts.push((aged ? "snapshot measured " : "measured ")
      + Qt.formatDateTime(new Date(t), "ddd h:mm AP") + (stale ? "  ·  stale" : ""))
    else parts.push("no measurement time")
    if (svc.limitsRefreshUnavailable && live)
      parts.push("omarchy-agent-usage-update not found, cannot refresh")
    return { text: parts.join("  ·  "),
             urgent: stale || (status !== "" && info !== true) }
  }

  readonly property bool showKimiPlan: showKimi || (svc ? svc.kimiPlanTier !== "" : false)
  readonly property bool showLocal: widget.showLocal
  // The box's name, as the user configured it: what the panel calls the
  // lane wherever it used to say "local". Always known, even offline.
  readonly property string boxName: svc ? svc.localHost : "localhost"
  readonly property string boxLabel: boxName.toUpperCase()
  readonly property real offload: svc ? svc.offloadShare : 0
  function topModel(byModel) {
    var rows = sortedModels(byModel)
    return rows.length ? rows[0].id : ""
  }
  // "30" for whole minutes, "8.3" for fractional buckets.
  function bucketLabel(minutes) {
    var m = Number(minutes) || 0
    return m === Math.round(m) ? String(Math.round(m)) : m.toFixed(1)
  }
  // At most this many rows in a list that can grow without bound. The panel
  // never scrolls; a 30-model install must not push the footer off screen.
  readonly property int maxRows: 6

  function splitTotal(split) {
    return Number(split.input || 0) + Number(split.cacheWrite || 0) + Number(split.output || 0)
  }
  // Cache reads as a share of everything the model took IN. Output is not
  // input: counting it in the denominator understated what the label claims.
  // It is a token share, not money: cache hits are billed too, at a lower rate.
  function cacheShare(split) {
    var taken = Number(split.input || 0) + Number(split.cacheWrite || 0)
    var read = Number(split.cacheRead || 0)
    return taken + read > 0 ? read / (taken + read) : 0
  }

  // ── local model control ───────────────────────────────────────────────────
  property var localOptions: []
  property string selectedModel: ""
  property bool localBusy: false
  property string localNote: ""

  readonly property bool localOnline: svc ? svc.localOnline : false
  readonly property bool localActive: svc ? svc.localActive : false
  readonly property color localState: !localOnline ? Color.urgent
    : localActive ? widget.localHot : widget.okGreen
  readonly property color powerColor: widget.emberAmber

  function plainText(value, limit) {
    return String(value || "").slice(0, limit).replace(/[<>&]/g, function(character) {
      return character === "<" ? "‹" : character === ">" ? "›" : "＆"
    }).replace(/[\u0000-\u001f\u007f]/g, " ")
  }

  function refreshLocalModels() {
    if (!panel.showLocal || listProc.running || !svc) return
    listProc.command = ["python3", svc.localControlPath, "--url", svc.ollamaUrl, "--host", svc.localHost, "list"]
    listProc.launched = false
    listProc.running = true
    listWatchdog.restart()
  }

  function refreshAll() {
    refreshLocalModels()
    if (svc) { svc.refreshLimits(); svc.collect(); svc.pollLocal() }
  }

  function runLocalAction(action) {
    if (localBusy || selectedModel === "" || !svc) return
    localBusy = true
    localNote = (action === "load" ? "Warming " : "Unloading ") + selectedModel + "…"
    actionProc.command = ["python3", svc.localControlPath, "--url", svc.ollamaUrl, "--host", svc.localHost, action, selectedModel]
    actionProc.launched = false
    actionProc.running = true
    actionWatchdog.restart()
  }

  function parseLocalModels(raw) {
    try {
      var data = JSON.parse(String(raw || ""))
      if (!Array.isArray(data.models)) throw new Error("Invalid model list")
      var options = []
      for (var i = 0; i < Math.min(data.models.length, 128); i++) {
        var m = data.models[i]
        var name = String(m.name || "").slice(0, 256)
        if (name === "") continue
        options.push({
          value: name,
          label: panel.plainText(name, 256) + (m.loaded ? "  • warm" : ""),
          description: [panel.plainText(m.parameters, 64), panel.plainText(m.quantization, 64),
                        m.size > 0 ? (Number(m.size) / 1073741824).toFixed(1) + " GB" : ""]
            .filter(Boolean).join(" · ")
        })
      }
      panel.localOptions = options
      // Reconcile the selection against every list, not just the first: a
      // model removed outside the panel stayed selected and actionable.
      var stillThere = false
      for (var k = 0; k < options.length; k++) if (options[k].value === panel.selectedModel) stillThere = true
      if (!stillThere) panel.selectedModel = options.length > 0 ? options[0].value : ""
    } catch (e) {
      panel.localNote = "Could not read installed models"
    }
  }

  // Quickshell emits no exited() for a command that could not start (no
  // python3): running just flips back to false. Each process tracks whether
  // it ever started so a failed launch still clears busy state and says why.
  Process {
    id: listProc
    property bool launched: false
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: panel.parseLocalModels(text) }
    onStarted: launched = true
    onRunningChanged: if (!running && !launched) { listWatchdog.stop(); panel.localNote = "python3 not found" }
    onExited: listWatchdog.stop()
  }
  Timer {
    id: listWatchdog
    interval: 15000
    repeat: false
    onTriggered: if (listProc.running) { listProc.signal(15); panel.localNote = "Model list timed out" }
  }

  Process {
    id: actionProc
    property bool launched: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var result = JSON.parse(String(text || ""))
          panel.localNote = panel.plainText(result.ok ? result.message : result.error, 384)
        } catch (e) { panel.localNote = "Ollama action failed" }
      }
    }
    onStarted: launched = true
    onRunningChanged: if (!running && !launched) { actionWatchdog.stop(); panel.localBusy = false; panel.localNote = "python3 not found" }
    onExited: {
      actionWatchdog.stop()
      panel.localBusy = false
      // Ollama reports a model as resident a beat after the call returns.
      settleTimer.restart()
    }
  }
  // Warming a model on the Jetson takes 35-60 s, plus the cache drop before
  // it; three minutes is the budget before the buttons are handed back.
  Timer {
    id: actionWatchdog
    interval: 180000
    repeat: false
    onTriggered: if (actionProc.running) { actionProc.signal(15); panel.localNote = "Ollama action timed out after 3 minutes" }
  }

  Timer {
    id: settleTimer
    interval: 500
    repeat: false
    onTriggered: {
      panel.refreshLocalModels()
      if (panel.svc) panel.svc.pollLocal()
    }
  }

  // ── reusable pieces ───────────────────────────────────────────────────────
  component Caption: Text {
    textFormat: Text.PlainText
    color: panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    elide: Text.ElideRight
  }
  // Dim like the rest of the footer, so it reads as provenance rather than a
  // control; underlined on hover so it is still discoverably clickable.
  component Link: Text {
    id: linkText
    property string url: ""
    textFormat: Text.PlainText
    color: linkArea.containsMouse ? panel.foreground : panel.dim
    font.family: panel.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkArea.containsMouse
    elide: Text.ElideRight
    MouseArea {
      id: linkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (linkText.url !== "") Quickshell.execDetached(["xdg-open", linkText.url])
    }
  }
  component Body: Text {
    textFormat: Text.PlainText
    color: panel.foreground
    font.family: panel.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }

  // A number that counts up to its target when the panel opens and eases to
  // every new value after that.
  component Counter: Text {
    id: counter
    property real target: 0
    property real shown: 0
    property var format: null
    textFormat: Text.PlainText
    font.family: panel.fontFamily
    text: format ? format(shown) : String(Math.round(shown))
    Behavior on shown {
      id: counterMotion
      NumberAnimation { duration: 800; easing.type: Easing.OutCubic }
    }
    onTargetChanged: shown = target
    Component.onCompleted: { counterMotion.enabled = false; shown = target; counterMotion.enabled = true }
    Connections {
      target: panel
      function onCounterEpochChanged() {
        counterMotion.enabled = false
        counter.shown = 0
        counterMotion.enabled = true
        counter.shown = counter.target
      }
    }
  }

  // Caption over a big number over a thin fill bar. The whole right column is
  // built from these, so every GPU metric reads the same way.
  component StatTile: Rectangle {
    id: tile
    property string caption: ""
    property real value: 0
    property var format: null
    property string unit: ""
    property string sub: ""
    // 0..1 fills the bar; negative hides it (for metrics with no ceiling).
    property real fraction: -1
    property color accent: panel.foreground

    Layout.fillWidth: true
    implicitHeight: Style.space(66)
    radius: Style.cornerRadius
    color: Util.alpha(tile.accent, 0.07)
    border.width: 1
    border.color: Util.alpha(tile.accent, 0.22)

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: 1
      Caption { text: tile.caption; font.bold: true; Layout.fillWidth: true }
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)
        Counter {
          target: tile.value
          format: tile.format
          color: tile.accent
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Caption { text: tile.unit; Layout.alignment: Qt.AlignBaseline; Layout.fillWidth: true }
      }
      Caption { text: tile.sub; Layout.fillWidth: true }
      Rectangle {
        Layout.fillWidth: true
        visible: tile.fraction >= 0
        implicitHeight: Style.space(3)
        radius: height / 2
        color: panel.faint
        Rectangle {
          height: parent.height
          radius: height / 2
          width: parent.width * Math.max(0, Math.min(1, tile.fraction)) * panel.reveal
          color: tile.accent
          Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // A row of thin bars from a ring of samples, newest on the right, the same
  // orientation as the cloud chart, so time reads one way across the panel.
  component Trace: ColumnLayout {
    id: trace
    property string caption: ""
    property string valueText: ""
    property var samples: []        // newest first
    property real max: 100
    property color accent: panel.foreground
    spacing: 3
    Layout.fillWidth: true

    RowLayout {
      Layout.fillWidth: true
      Caption { text: trace.caption; font.bold: true; Layout.fillWidth: true }
      Caption { text: trace.valueText; color: trace.accent; font.bold: true }
    }
    Item {
      id: traceArea
      Layout.fillWidth: true
      implicitHeight: Style.space(26)
      readonly property int n: trace.samples ? trace.samples.length : 0
      readonly property real slot: n > 0 ? width / n : width
      Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: panel.faint
      }
      Repeater {
        model: traceArea.n
        delegate: Rectangle {
          required property int index
          readonly property real v: Math.max(0, Math.min(1,
            Number(trace.samples[traceArea.n - 1 - index] || 0) / Math.max(1, trace.max)))
          x: index * traceArea.slot
          width: Math.max(1, traceArea.slot - 2)
          anchors.bottom: parent.bottom
          height: Math.max(2, traceArea.height * v * panel.wipe(index, traceArea.n))
          radius: 1
          color: trace.accent
          opacity: 0.35 + 0.65 * (index / Math.max(1, traceArea.n - 1))
          Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        }
      }
    }
  }

  // Thin horizontal gauge that wipes in on open and eases on change.
  // The budget bar: thick enough to read across the room, with a bright tick at
  // the point an even spend would have reached by now. Fill past the tick is
  // overspend, and it is meant to be obvious without reading anything.
  component BudgetGauge: Rectangle {
    id: bgauge
    property real fraction: 0
    property real elapsed: -1
    property color accent: panel.foreground
    Layout.fillWidth: true
    implicitHeight: Style.space(12)
    radius: height / 2
    color: panel.faint
    Rectangle {
      anchors.left: parent.left
      height: parent.height
      radius: height / 2
      width: parent.width * Math.max(0, Math.min(1, bgauge.fraction)) * panel.reveal
      color: bgauge.accent
      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    }
    Rectangle {
      visible: bgauge.elapsed >= 0 && bgauge.elapsed <= 1
      width: Math.max(2, Style.space(2))
      height: parent.height + Style.space(4)
      y: -Style.space(2)
      x: Math.round(parent.width * Math.max(0, Math.min(1, bgauge.elapsed))) - width / 2
      radius: width / 2
      color: panel.foreground
      Behavior on x { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    }
  }

  component Gauge: Rectangle {
    id: gauge
    property real fraction: 0
    property color accent: panel.foreground
    Layout.fillWidth: true
    implicitHeight: Style.space(5)
    radius: height / 2
    color: panel.faint
    Rectangle {
      anchors.left: parent.left
      height: parent.height
      radius: height / 2
      width: parent.width * Math.max(0, Math.min(1, gauge.fraction)) * panel.reveal
      color: gauge.accent
      Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
    }
  }

  // ══ 2.0: ONE CARD PER SUBSCRIPTION ════════════════════════════════════════
  // Fred, 2026-09-20: "You have separate sections for diff information. Each
  // sub should have a section that cleanly displays all the info about it in
  // one large card ... burn rate in a section and cache in another. I like
  // graphs. I like cool factor."  The 1.x cockpit was organised by KIND of
  // number (limits here, rates there, cache somewhere else), so answering "how
  // is Codex doing" meant reading four sections. 2.0 is organised by the thing
  // you pay for. A subscription that is not ticked in the right-click menu has
  // no card at all.
  readonly property string heroMode: widget.heroMode
  readonly property bool showSessionWindows: widget.showSessionWindows

  // ── the glow ──────────────────────────────────────────────────────────────
  // Fred, 2026-09-20: "I also want the subscriptions card to glow and the
  // reason for the glow is something the user can select within setup." One
  // reason at a time, on purpose: a glow that could mean four things says
  // nothing from across the room. Every reason answers with the same three
  // facts - how strong (0 is dark), what colour, whether it breathes - so a
  // card has one glow to draw and SETUP decides what it is about.
  readonly property string glowMode: widget.glowMode

  // ── fit ───────────────────────────────────────────────────────────────────
  // The cockpit never scrolls, and it must never CLIP either: clipping is worse,
  // because nothing tells you rows are missing. 2.1 added a guidance line to
  // every card and the footer fell off the bottom of a 1080p laptop. So the
  // panel measures the screen it opens on and tightens itself: shorter graphs,
  // closer rows, a one-line footer. `density` starts from the room available
  // and `squeeze` raises it if the real content still does not fit (a plan with
  // five quota windows, a long model list). It only ever tightens while open,
  // so it cannot oscillate, and it relaxes again on the next open.
  readonly property real roomUnits: kpanel.availableCardHeight > 0
    ? (kpanel.availableCardHeight - kpanel.verticalContentInset) / Math.max(0.5, Style.spaceReal(1)) : 9999
  property int squeeze: 0
  readonly property int density: Math.max(roomUnits >= 960 ? 0 : roomUnits >= 830 ? 1 : 2, squeeze)
  function tight(roomy, snug, packed) { return density === 0 ? roomy : density === 1 ? snug : packed }
  Timer {
    id: fitCheck
    interval: 150
    onTriggered: {
      if (!panel.opened || panel.mode !== "cockpit" || panel.squeeze >= 2) return
      var room = kpanel.availableCardHeight - kpanel.verticalContentInset
      if (room > 0 && content.implicitHeight > room) { panel.squeeze++; fitCheck.restart() }
    }
  }

  // ── guidance ──────────────────────────────────────────────────────────────
  // What to do, before any of the data. The arithmetic lives in the widget so
  // the chip on the bar, the tooltips and this panel can never disagree; the
  // panel only re-reads it each second so "banked" and "come back in" move in
  // real time while it is open.
  readonly property var guidance: widget.guidance
  readonly property bool guideShown: guidance.count >= 2
  readonly property string guideHeadline: { void panel.tick; return widget.guideHeadline() }
  readonly property string guideReason: { void panel.tick; return widget.guideReason(Date.now()) }
  readonly property color guideTone: guidance.pick !== "" ? widget.subColor(guidance.pick)
    : guidance.rest.length > 0 ? Qt.lighter(Color.urgent, 1.35) : widget.gaugeColor(0.2)
  // Everyone who is not the pick, in one breath: who is next, and when each
  // sub that needs a rest is back.
  readonly property string guideAside: {
    void panel.tick
    var g = guidance, parts = []
    if (g.pick === "") return ""
    if (g.next !== "") parts.push("then " + widget.subName(g.next))
    for (var i = 0; i < g.rest.length; i++)
      parts.push(widget.subName(g.rest[i].id) + " back " + Qt.formatDateTime(new Date(g.rest[i].comeBackAt), "ddd h:mm AP"))
    return parts.join("  ·  ")
  }
  readonly property var glowOptions: [
    { id: "pace",  label: "Over pace",    note: "faster than the plan allows" },
    { id: "burn",  label: "Burning now",  note: "tokens moved in the last 5 min" },
    { id: "spent", label: "Budget spent", note: "brighter as the window fills" },
    { id: "stop",  label: "Time to stop", note: "near today's share, or past it" },
    { id: "off",   label: "No glow",      note: "" }
  ]
  function glowLabel() {
    for (var i = 0; i < glowOptions.length; i++)
      if (glowOptions[i].id === glowMode) return glowOptions[i].label.toLowerCase()
    return ""
  }
  function glowFor(agent, limit, unknown) {
    void panel.tick
    var dark = { strength: 0, color: panel.foreground, breathe: false }
    var mode = panel.glowMode
    if (mode === "off") return dark
    if (mode === "burn") {
      // The only reason that needs no budget, so it also works for a
      // subscription whose quota nobody can measure.
      var now = rateNow(agent)
      if (!(now > 0)) return dark
      var usual = Math.max(1, rateHour(agent))
      return { strength: Math.min(1, 0.4 + 0.6 * Math.min(1, now / (usual * 2))),
               color: agentHot(agent), breathe: true }
    }
    // Everything below is about a budget. No measured budget, no glow: a card
    // must never light up over a number that was guessed.
    if (unknown || !limit) return dark
    var pct = Math.max(0, Math.min(1, Number(limit.percent) || 0))
    if (mode === "spent") {
      if (pct <= 0.02) return dark
      return { strength: Math.min(1, 0.15 + 0.85 * pct), color: widget.gaugeColor(pct), breathe: pct >= 0.9 }
    }
    var p = limit.pace
    if (!p) return dark
    var amber = Qt.lighter(Color.urgent, 1.35)
    if (mode === "stop") {
      if (p.overDaily === true) return { strength: 1, color: Color.urgent, breathe: true }
      var stopIn = Number(p.stopInMs)
      if (!(stopIn > 0) || stopIn > 3600000) return dark
      return { strength: 0.45 + 0.55 * (1 - stopIn / 3600000), color: amber, breathe: false }
    }
    // pace: the same four stages the badge on the bar climbs through.
    var stage = widget.paceStage(p.ratio, limit.percent)
    if (stage <= 0) return dark
    // Breathing means "you can still do something about this". A window that
    // is already spent out burns steady: there is nothing left to slow down.
    return { strength: [0, 0.5, 0.75, 1, 1][stage], color: stage >= 2 ? Color.urgent : amber, breathe: stage === 3 }
  }

  // Every per-agent figure the service carries is named <agent><Suffix>, so a
  // card asks by name instead of repeating a four-way ternary thirty times.
  function sv(agent, suffix, fallback) {
    var s = panel.svc
    if (!s) return fallback
    var v = s[agent + suffix]
    return (v === undefined || v === null) ? fallback : v
  }
  function agentName(a) {
    return a === "claude" ? "Claude" : a === "codex" ? "Codex" : a === "grok" ? "Grok" : "Kimi"
  }
  function agentHot(a) {
    var w = panel.widget
    return a === "claude" ? w.claudeHot : a === "codex" ? w.codexHot : a === "grok" ? w.grokHot : w.kimiHot
  }
  function agentWarm(a) {
    var w = panel.widget
    return a === "claude" ? w.claudeWarm : a === "codex" ? w.codexWarm : a === "grok" ? w.grokWarm : w.kimiWarm
  }
  function agentCold(a) {
    var w = panel.widget
    return a === "claude" ? w.claudeCold : a === "codex" ? w.codexCold : a === "grok" ? w.grokCold : w.kimiCold
  }
  function agentShown(a) {
    return a === "claude" ? showClaude : a === "codex" ? showCodex
      : a === "grok" ? showGrok : a === "kimi" ? showKimi : false
  }
  readonly property int cardCount: (showClaude ? 1 : 0) + (showCodex ? 1 : 0) + (showGrok ? 1 : 0)
    + (showKimi ? 1 : 0) + (showLocal ? 1 : 0)

  // The 5-hour window is opt-in: it resets before it can hurt, and the weekly
  // and monthly windows are the ones that actually end a working day.
  function isSessionWindow(label) { return /session|5-hour/i.test(String(label || "")) }
  function agentWindows(a) {
    var rows = sv(a, "Limits", []) || []
    var out = []
    for (var i = 0; i < rows.length; i++) {
      if (!panel.showSessionWindows && isSessionWindow(rows[i].label)) continue
      out.push(rows[i])
    }
    return out
  }
  // The window a card is ABOUT: the weekly one where there is one, otherwise
  // the monthly pool, otherwise whatever the provider offers first.
  function primaryWindow(a) {
    var rows = agentWindows(a)
    var i
    for (i = 0; i < rows.length; i++)
      if (/^weekly/i.test(String(rows[i].label || ""))) return rows[i]
    for (i = 0; i < rows.length; i++)
      if (/monthly \(total\)/i.test(String(rows[i].label || ""))) return rows[i]
    return rows.length > 0 ? rows[0] : null
  }
  function windowUnknown(a, limit) {
    void panel.tick
    if (!limit || !panel.svc) return true
    if (panel.svc.limitsStale(sv(a, "LimitsMeasuredAt", 0), sv(a, "LimitsLive", true))) return true
    if (panel.svc.limitExpired(limit)) return true
    return !(Number(limit.percent) >= 0)
  }
  function windowShort(label) {
    var t = String(label || "")
    if (/monthly/i.test(t)) return "monthly"
    if (/weekly/i.test(t)) return /fable/i.test(t) ? "Fable weekly" : "weekly"
    if (isSessionWindow(t)) return "5-hour"
    return t.toLowerCase()
  }

  // One setup option: a mark, a name, a note, and a click.
  component SetupRow: Rectangle {
    id: srow
    property string mark: "☐"
    property string label: ""
    property string note: ""
    property color tone: panel.foreground
    property bool on: false
    property bool noteUrgent: false
    signal activated()
    Layout.fillWidth: true
    implicitHeight: Style.space(30)
    radius: Style.space(4)
    color: srowHover.hovered ? Util.alpha(panel.foreground, 0.12)
      : srow.on ? Util.alpha(panel.foreground, 0.06) : "transparent"
    HoverHandler { id: srowHover }
    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)
      Body {
        text: srow.mark
        color: srow.on ? srow.tone : panel.dim
        Layout.preferredWidth: Style.space(14)
      }
      Body { text: srow.label; color: srow.tone; Layout.fillWidth: true }
      Caption { text: srow.note; color: srow.noteUrgent ? Color.urgent : panel.dim }
    }
    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: srow.activated()
    }
  }

  // A rounded verdict chip: the one word a card is really about.
  component Pill: Rectangle {
    id: pill
    property string text: ""
    property color tone: panel.foreground
    visible: text !== ""
    implicitWidth: pillText.implicitWidth + Style.space(14)
    implicitHeight: pillText.implicitHeight + Style.space(4)
    radius: height / 2
    color: Util.alpha(pill.tone, 0.16)
    border.width: 1
    border.color: Util.alpha(pill.tone, 0.55)
    Text {
      id: pillText
      anchors.centerIn: parent
      text: pill.text
      textFormat: Text.PlainText
      color: pill.tone
      font.family: panel.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // The budget burndown. x is the window from its start to its reset, y is the
  // plan from 0 to 100%, so an even spend is simply the diagonal and the whole
  // verdict is visible as geometry: the line above the diagonal is overspend,
  // the dashed continuation is where the present rate lands, and if that
  // continuation hits the ceiling before the right edge, that is the moment the
  // subscription runs dry.
  component Burndown: Item {
    id: bd
    property var series: []
    property real elapsed: -1
    property real percent: -1
    property real projected: -1
    property color tone: panel.foreground
    // The far end of the time axis in words: without it a first-time reader
    // sees a sparkline, not a window that runs out at a reset.
    property string endText: ""
    Layout.fillWidth: true
    implicitHeight: Style.space(panel.tight(108, 84, 62))

    function px(x) { return Math.max(0, Math.min(1, Number(x) || 0)) * bd.width }
    function py(y) { return bd.height - Math.max(0, Math.min(1, Number(y) || 0)) * bd.height }

    // What was actually sampled, always at least two points so a polyline has
    // something to draw.
    readonly property var linePoints: {
      var pts = []
      var s = bd.series || []
      for (var i = 0; i < s.length; i++) pts.push(Qt.point(px(s[i][0]), py(s[i][1])))
      if (pts.length === 0 && bd.elapsed >= 0 && bd.percent >= 0)
        pts.push(Qt.point(px(bd.elapsed), py(bd.percent)))
      if (pts.length === 1) pts.push(Qt.point(pts[0].x + 0.5, pts[0].y))
      return pts
    }
    // Before the first sample the path is unknown in shape but not at its end:
    // every window starts at zero. Drawn dim, so it reads as inferred.
    readonly property var inferredPoints: {
      var pts = [Qt.point(0, bd.height)]
      var first = bd.linePoints.length > 0 ? bd.linePoints[0] : Qt.point(0, bd.height)
      pts.push(Qt.point(first.x, first.y))
      return pts
    }
    readonly property var fillPoints: {
      var pts = [Qt.point(0, bd.height)]
      for (var i = 0; i < bd.linePoints.length; i++) pts.push(bd.linePoints[i])
      var last = bd.linePoints.length > 0 ? bd.linePoints[bd.linePoints.length - 1] : Qt.point(0, bd.height)
      pts.push(Qt.point(last.x, bd.height))
      pts.push(Qt.point(0, bd.height))
      return pts
    }
    // Where the present rate lands. Past 100% the line stops at the ceiling,
    // at the x where it crosses - the dry moment.
    readonly property bool hasProjection: bd.projected >= 0 && bd.elapsed >= 0 && bd.percent >= 0
      && bd.projected > bd.percent + 0.0005
    readonly property real dryX: bd.projected > 1
      ? bd.elapsed + (1 - bd.percent) * (1 - bd.elapsed) / Math.max(0.000001, bd.projected - bd.percent) : 1
    readonly property var projectionPoints: [
      Qt.point(px(bd.elapsed), py(bd.percent)),
      Qt.point(px(bd.hasProjection ? bd.dryX : bd.elapsed), py(bd.hasProjection ? Math.min(1, bd.projected) : bd.percent))
    ]

    // Frame and quarter lines, faint: a graph needs a floor, not a cage.
    Rectangle { anchors.fill: parent; radius: Style.space(4); color: Util.alpha(panel.foreground, 0.03) }
    Repeater {
      model: 3
      delegate: Rectangle {
        required property int index
        y: Math.round(bd.height * (index + 1) / 4)
        width: bd.width
        height: 1
        color: Util.alpha(panel.foreground, 0.06)
      }
    }

    // Wipes in from the left on open, like every other trace in the cockpit.
    Item {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * panel.reveal
      clip: true

      Shape {
        width: bd.width
        height: bd.height
        layer.enabled: true
        layer.samples: 4

        // Even pace: the diagonal.
        ShapePath {
          strokeColor: Util.alpha(panel.foreground, 0.38)
          strokeWidth: 1
          strokeStyle: ShapePath.DashLine
          dashPattern: [4, 4]
          fillColor: "transparent"
          startX: 0
          startY: bd.height
          PathLine { x: bd.width; y: 0 }
        }
        // Spent so far, filled down to the floor.
        ShapePath {
          strokeColor: "transparent"
          strokeWidth: 0
          fillGradient: LinearGradient {
            x1: 0; y1: 0; x2: 0; y2: bd.height
            GradientStop { position: 0.0; color: Util.alpha(bd.tone, 0.40) }
            GradientStop { position: 1.0; color: Util.alpha(bd.tone, 0.02) }
          }
          PathPolyline { path: bd.fillPoints }
        }
        // Start of window to first sample: inferred, so dim.
        ShapePath {
          strokeColor: Util.alpha(bd.tone, 0.35)
          strokeWidth: 1.5
          strokeStyle: ShapePath.DashLine
          dashPattern: [2, 3]
          fillColor: "transparent"
          PathPolyline { path: bd.inferredPoints }
        }
        // The glow under the line, then the line.
        ShapePath {
          strokeColor: Util.alpha(bd.tone, 0.22)
          strokeWidth: 7
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathPolyline { path: bd.linePoints }
        }
        ShapePath {
          strokeColor: bd.tone
          strokeWidth: 2
          fillColor: "transparent"
          capStyle: ShapePath.RoundCap
          joinStyle: ShapePath.RoundJoin
          PathPolyline { path: bd.linePoints }
        }
        // At this rate.
        ShapePath {
          strokeColor: bd.hasProjection ? Util.alpha(bd.tone, 0.85) : "transparent"
          strokeWidth: 1.5
          strokeStyle: ShapePath.DashLine
          dashPattern: [3, 3]
          fillColor: "transparent"
          PathPolyline { path: bd.projectionPoints }
        }
      }
    }

    // Now: a hairline, and a dot that breathes where you actually are.
    Rectangle {
      visible: bd.elapsed >= 0
      x: Math.round(bd.px(bd.elapsed))
      width: 1
      height: bd.height
      color: Util.alpha(panel.foreground, 0.25)
    }
    Rectangle {
      id: nowDot
      visible: bd.elapsed >= 0 && bd.percent >= 0
      width: Style.space(8)
      height: width
      radius: width / 2
      x: bd.px(bd.elapsed) - width / 2
      y: bd.py(bd.percent) - height / 2
      color: bd.tone
      border.width: 1
      border.color: panel.widget.whiteHot
      SequentialAnimation on scale {
        running: nowDot.visible && panel.opened
        loops: Animation.Infinite
        NumberAnimation { to: 1.35; duration: 900; easing.type: Easing.InOutQuad }
        NumberAnimation { to: 0.9; duration: 900; easing.type: Easing.InOutQuad }
      }
    }
    // The dry moment, when the present rate reaches the ceiling early.
    Rectangle {
      visible: bd.hasProjection && bd.projected > 1
      width: Style.space(7)
      height: width
      radius: width / 2
      x: bd.px(bd.dryX) - width / 2
      y: -height / 2 + 1
      color: Color.urgent
    }
    AxisEnds { endText: bd.endText }
  }

  // One subscription's burn over the window, as heat-ramped bars from a floor.
  component AxisEnds: Item {
    id: ax
    // Only the reset end is labelled. A start label sat in the bottom-left
    // corner, which is exactly where the line of a barely-touched plan runs.
    property string endText: ""
    anchors.fill: parent
    Caption {
      anchors.right: parent.right; anchors.bottom: parent.bottom
      anchors.rightMargin: Style.space(4); anchors.bottomMargin: 1
      text: ax.endText
      opacity: 0.7
    }
  }

  component BurnBars: Item {
    id: bb
    property string agent: "claude"
    Layout.fillWidth: true
    implicitHeight: Style.space(panel.tight(52, 40, 30))
    readonly property int n: panel.buckets.length
    readonly property real slot: n > 0 ? width / n : width
    readonly property real peak: Math.max(1, Number(panel.sv(bb.agent, "Peak", 1)))

    Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: panel.faint }
    Repeater {
      model: bb.n
      delegate: Item {
        id: bar
        required property int index
        readonly property real v: Number((panel.buckets[index] || ({}))[bb.agent] || 0)
        readonly property real level: Math.min(1, Math.pow(v / bb.peak, 0.6))
        readonly property bool live: index === bb.n - 1
        x: index * bb.slot
        width: bb.slot
        height: bb.height
        Rectangle {
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.max(2, bb.slot - 3)
          height: Math.max(bar.v > 0 ? 2 : 0, (bb.height - 2) * bar.level) * panel.wipe(bar.index, bb.n)
          radius: 2
          color: panel.widget.heat(bar.level, panel.agentCold(bb.agent), panel.agentWarm(bb.agent), panel.agentHot(bb.agent))
          opacity: 0.55 + 0.45 * (bar.index / Math.max(1, bb.n - 1))
          Behavior on height { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
        }
        // The live bucket breathes, as the live cell on the strip does.
        Rectangle {
          id: liveBox
          visible: bar.live
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.max(2, bb.slot - 3)
          height: bb.height
          radius: 2
          color: Util.alpha(panel.widget.whiteHot, panel.chartFlash * 0.25)
          border.width: 1
          border.color: panel.widget.whiteHot
          property real breathe: 0.1
          opacity: Math.min(1, breathe + panel.chartFlash)
          SequentialAnimation on breathe {
            running: bar.live && panel.opened
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 900; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.06; duration: 900; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
  }

  // A small labelled figure, three of which make a card's rate strip.
  component MiniStat: ColumnLayout {
    id: mini
    property string label: ""
    property real value: 0
    property color tone: panel.foreground
    spacing: 0
    Layout.fillWidth: true
    Counter {
      target: mini.value
      format: panel.widget.compact
      color: mini.tone
      font.pixelSize: Style.font.body
      font.bold: true
    }
    Caption { text: mini.label; font.bold: true }
  }

  // ── the card ──────────────────────────────────────────────────────────────
  // The glow itself: the card's own outline, blurred until it reads as light.
  // Only the outline is drawn, never a filled shape - the cards are nearly
  // transparent, and a filled halo behind one would flood it with colour. Half
  // the light falls outside the card and half inside, which is what a lit edge
  // does. `level` eases, so a card warms up and cools down instead of snapping.
  component CardGlow: Item {
    id: cg
    property color tone: panel.foreground
    property real strength: 0
    property bool breathe: false
    property real corner: Style.cornerRadius
    property real eased: strength
    property real breath: 1
    readonly property real level: eased * breath
    Behavior on eased { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }
    Behavior on tone { ColorAnimation { duration: 700 } }
    anchors.fill: parent
    z: -1
    visible: level > 0.01
    opacity: Math.min(1, level)

    // Breathing runs only while the panel is open and this card is lit: a
    // closed panel animating four blurs would be heat for nobody.
    SequentialAnimation {
      running: panel.opened && cg.breathe && cg.strength > 0
      loops: Animation.Infinite
      NumberAnimation { target: cg; property: "breath"; to: 0.5; duration: 1500; easing.type: Easing.InOutSine }
      NumberAnimation { target: cg; property: "breath"; to: 1; duration: 1500; easing.type: Easing.InOutSine }
      onStopped: cg.breath = 1
    }

    // The outline sits just OUTSIDE the card, so most of the light falls into
    // the gap between cards and the text inside stays on a clean background.
    Rectangle {
      id: cgEdge
      anchors.fill: parent
      anchors.margins: -border.width
      radius: cg.corner + border.width
      color: "transparent"
      border.width: Style.space(6)
      border.color: cg.tone
      visible: false
    }
    // Two passes of the same outline: a wide soft one for the halo, a tight
    // one for the hot rim. One blur alone is either a smear or a hairline.
    MultiEffect {
      source: cgEdge
      anchors.fill: cgEdge
      blurEnabled: true
      blur: 1
      blurMax: 64
      autoPaddingEnabled: true
      opacity: 0.8
    }
    MultiEffect {
      source: cgEdge
      anchors.fill: cgEdge
      blurEnabled: true
      blur: 1
      blurMax: 18
      autoPaddingEnabled: true
    }
  }

  component SubCard: Rectangle {
    id: card
    property string agent: "claude"

    readonly property color accent: panel.agentHot(agent)
    // No tick here: a fresh array every second made the Repeater below tear
    // down and rebuild every window row once a second. The rows read the tick
    // themselves for their countdowns.
    readonly property var windows: panel.agentWindows(agent)
    readonly property var primary: panel.primaryWindow(agent)
    readonly property bool primaryUnknown: panel.windowUnknown(agent, primary)
    readonly property var pace: primary && primary.pace && !primaryUnknown ? primary.pace : null
    readonly property var verdict: panel.paceVerdict(primary, primaryUnknown)
    readonly property var sentence: panel.paceText(primary, primaryUnknown)
    // Budget leads when there is a budget to lead with; a subscription whose
    // quota is unknown falls back to tokens rather than printing a dash at
    // display size.
    readonly property bool budgetHero: panel.heroMode === "budget" && primary !== null && !primaryUnknown
    readonly property real total: Number(panel.sv(agent, "Total", 0))
    // Nothing burned in the window: the budget half of the card still matters,
    // the burn half is rows of zeros and an empty graph. It collapses to a line.
    readonly property bool active: total > 0
    readonly property var split: panel.sv(agent, "Split", ({}))
    readonly property real splitSum: Math.max(1, panel.splitTotal(split))
    readonly property var models: panel.sortedModels(panel.sv(agent, "ByModel", ({})))
    readonly property string tier: agent === "kimi" ? String(panel.sv("kimi", "PlanTier", "")) : ""
    readonly property var glow: panel.glowFor(agent, primary, primaryUnknown)
    // Where this sub stands this second, and whether it is the one to use.
    readonly property var live: { void panel.tick; return panel.widget.liveFor(agent, Date.now()) }
    readonly property bool isPick: panel.guideShown && panel.guidance.pick === agent
    readonly property bool lit: visible && Number(glow.strength) > 0
    readonly property var trust: {
      void panel.tick
      return panel.limitNote(panel.sv(agent, "LimitsMeasuredAt", 0), String(panel.sv(agent, "LimitsStatus", "")),
        String(panel.sv(agent, "LimitsHelp", "")), panel.sv(agent, "LimitsLive", true),
        agent === "kimi" ? panel.sv("kimi", "LimitsInfo", false) : false)
    }

    visible: panel.agentShown(agent)
    Layout.fillWidth: visible
    Layout.fillHeight: true
    Layout.preferredWidth: visible ? 1 : 0
    Layout.minimumWidth: 0
    implicitHeight: visible ? body.implicitHeight + Style.space(26) : 0
    radius: Style.cornerRadius
    color: Util.alpha(card.accent, 0.055)
    border.width: 1
    border.color: card.lit ? Util.alpha(card.glow.color, 0.5 + 0.45 * Number(card.glow.strength))
      : Util.alpha(card.sentence.urgent ? Color.urgent : card.accent, card.sentence.urgent ? 0.6 : 0.32)
    opacity: panel.reveal
    transform: Translate { y: (1 - panel.reveal) * 12 }

    CardGlow {
      tone: card.glow.color
      strength: card.visible ? Number(card.glow.strength) : 0
      breathe: card.glow.breathe === true
      corner: card.radius
    }

    // A lit edge in the subscription's own colour: which card is which, from
    // across the room.
    Rectangle {
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width - Style.space(24)
      height: 2
      radius: 1
      color: card.accent
      opacity: 0.35 + 0.5 * Math.min(1, panel.rateNow(card.agent) / Math.max(1, panel.rateHour(card.agent) * 2 + 1))
    }

    ColumnLayout {
      id: body
      anchors.fill: parent
      anchors.margins: Style.space(panel.tight(13, 11, 10))
      spacing: Style.space(panel.tight(8, 6, 4))

      // ── name · tier · verdict ──────────────────────────────────────────
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Text {
          text: panel.agentName(card.agent).toUpperCase()
          textFormat: Text.PlainText
          color: card.accent
          font.family: panel.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Caption { text: card.tier !== "" ? card.tier + " plan" : ""; visible: card.tier !== "" }
        Item { Layout.fillWidth: true }
        Pill { text: card.verdict.word; tone: card.verdict.color }
      }

      // ── what to do about it ────────────────────────────────────────────
      // Banked when ahead, a way back when behind, never both. Fred: "how much
      // you have banked real time always if you are ahead, not shown if behind"
      // and "a timer that shows when you can come back". It reads the clock
      // every second, so a sub left alone visibly earns its budget back.
      Rectangle {
        id: standing
        visible: card.live !== null
        Layout.fillWidth: true
        implicitHeight: Style.space(panel.tight(32, 30, 28))
        radius: Style.space(6)
        readonly property bool behind: card.live !== null && (card.live.spent || card.live.over)
        // Tokens are leaving right now, so the clocks are held at the last
        // measurement instead of running on a percentage that is going stale.
        readonly property bool held: card.live !== null && panel.widget.subBurning(card.agent)
        readonly property bool rough: panel.widget.snapshotOutrun(card.agent)
        readonly property bool ahead: card.live !== null && !behind && card.live.banked >= 0.01
        readonly property color tone: behind ? (card.live.spent || card.live.behind > 0.05 ? Color.urgent : Qt.lighter(Color.urgent, 1.35))
          : ahead ? panel.widget.gaugeColor(0.2) : panel.foreground
        color: Util.alpha(tone, 0.10)
        border.width: 1
        border.color: Util.alpha(tone, card.isPick ? 0.9 : 0.3)
        RowLayout {
          anchors.fill: parent
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(8)
          spacing: Style.space(8)
          Text {
            textFormat: Text.PlainText
            color: standing.tone
            font.family: panel.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            text: !card.live ? ""
              : card.live.spent ? "BACK AT THE RESET"
              : standing.behind ? "COME BACK IN " + panel.widget.clockSpan(card.live.comeBackMs)
              : standing.ahead ? "BANKED " + (standing.rough ? "~" : "") + Math.round(card.live.banked * 100) + "%"
              : "ON PACE"
          }
          Caption {
            Layout.fillWidth: true
            text: !card.live ? ""
              : card.live.spent ? Qt.formatDateTime(new Date(card.live.comeBackAt), "ddd h:mm AP") + "  ·  in " + panel.widget.clockSpan(card.live.comeBackMs)
              // The come-back time assumes no further burn. Said out loud,
              // because read while still working it is wrong within minutes.
              // The condition leads, because it is what gets cut last on a
              // narrow card and it is the part that keeps the promise honest.
              : standing.behind ? "if you stop  ·  " + Qt.formatDateTime(new Date(card.live.comeBackAt), "ddd h:mm AP")
                  + "  ·  " + Math.max(1, Math.round(card.live.behind * 100)) + "% over"
              // Banked time climbs a second every second while the sub is left
              // alone, so it is printed as a clock: that is what "it slowly comes
              // back to budget" looks like.
              : standing.ahead ? panel.widget.clockSpan(card.live.bankedMs) + " in the bank"
                  + (standing.rough ? "  ·  used since it was measured" : standing.held ? "  ·  holds while you burn" : "")
              : "spend evenly and it lasts"
          }
          Pill { visible: card.isPick; text: panel.guidance.urgent ? "USE NOW" : "USE NEXT"; tone: card.accent }
        }
      }

      // ── the headline: budget or tokens, click to flip ──────────────────
      Item {
        Layout.fillWidth: true
        implicitHeight: heroRow.implicitHeight
        RowLayout {
          id: heroRow
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(10)
          Counter {
            target: card.budgetHero ? Number(card.primary.percent) * 100 : card.total
            format: card.budgetHero ? function(v) { return Math.round(v) + "%" } : panel.widget.compact
            color: card.budgetHero ? (card.verdict.word !== "" ? card.verdict.color : card.accent) : card.accent
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 0
            Caption {
              Layout.fillWidth: true
              font.bold: true
              color: panel.foreground
              text: card.budgetHero
                ? "of " + panel.windowShort(card.primary.label) + " budget spent"
                : "tokens  ·  last " + panel.widget.windowLabel(panel.windowMinutes)
            }
            Caption {
              Layout.fillWidth: true
              text: {
                void panel.tick
                if (card.budgetHero)
                  return panel.widget.compact(card.total) + " tokens  ·  resets in " + panel.untilText(card.primary.resetsAt)
                if (card.primary && !card.primaryUnknown)
                  return Math.round(Number(card.primary.percent) * 100) + "% of " + panel.windowShort(card.primary.label)
                    + "  ·  resets in " + panel.untilText(card.primary.resetsAt)
                return panel.sv(card.agent, "Turns", 0) + " turns  ·  " + panel.sv(card.agent, "Sessions", 0) + " sessions"
              }
            }
          }
          Caption {
            // A bare arrow was the whole affordance; it now names where it goes.
            text: "⇄ " + (panel.heroMode === "budget" ? "tokens" : "budget")
            color: heroFlip.containsMouse ? panel.foreground : panel.dim
          }
        }
        MouseArea {
          id: heroFlip
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: panel.widget.setHeroMode(panel.heroMode === "budget" ? "tokens" : "budget")
        }
      }

      // ── burndown: the verdict as geometry ──────────────────────────────
      RowLayout {
        Layout.fillWidth: true
        visible: card.primary !== null
        Caption {
          Layout.fillWidth: true
          font.bold: true
          text: card.primary ? "BURNDOWN  ·  " + String(card.primary.label).toUpperCase() : ""
        }
        Caption { text: "╌ even pace"; visible: card.pace !== null }
      }
      Burndown {
        visible: card.pace !== null
        series: card.pace ? (card.pace.series || []) : []
        elapsed: card.pace ? Number(card.pace.elapsed) : -1
        percent: card.primary && !card.primaryUnknown ? Number(card.primary.percent) : -1
        projected: card.pace && Number(card.pace.ratePerHour) > 0.00005 ? Number(card.pace.projected) : -1
        tone: card.verdict.word !== "" ? card.verdict.color : card.accent
        // A week reads best as a day and an hour, a month as a date.
        readonly property string axisFormat: card.pace && Number(card.pace.windowMs) > 8 * 86400000 ? "MMM d" : "ddd h AP"
        endText: card.pace && Number(card.pace.resetsMs) > 0
          ? "reset " + Qt.formatDateTime(new Date(Number(card.pace.resetsMs)), axisFormat) : ""
      }
      Body {
        visible: card.sentence.text !== ""
        Layout.fillWidth: true
        text: card.sentence.text
        color: card.sentence.urgent ? Color.urgent : panel.foreground
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
      }

      // ── every window this plan meters ──────────────────────────────────
      Repeater {
        model: card.windows
        delegate: ColumnLayout {
          id: win
          required property var modelData
          readonly property bool unknown: panel.windowUnknown(card.agent, modelData)
          readonly property var v: panel.paceVerdict(modelData, unknown)
          Layout.fillWidth: true
          spacing: 2
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Body { text: modelData.label; Layout.fillWidth: true }
            Caption {
              text: { void panel.tick; return win.unknown ? "awaiting refresh" : "resets " + panel.untilText(modelData.resetsAt) }
            }
            Body {
              text: win.unknown ? "--" : Math.round(Number(modelData.percent) * 100) + "%"
              color: win.unknown ? panel.dim : (win.v.word !== "" ? win.v.color : panel.foreground)
              font.bold: true
              Layout.preferredWidth: Style.space(38)
              horizontalAlignment: Text.AlignRight
            }
          }
          BudgetGauge {
            implicitHeight: Style.space(7)
            fraction: win.unknown ? 0 : Number(modelData.percent)
            elapsed: win.unknown || !modelData.pace ? -1 : Number(modelData.pace.elapsed)
            accent: win.unknown ? panel.dim : (win.v.word !== "" ? win.v.color : card.accent)
          }
        }
      }
      Caption {
        visible: card.trust.text !== ""
        Layout.fillWidth: true
        text: card.trust.text
        color: card.trust.urgent === true ? Color.urgent : panel.dim
        wrapMode: Text.WordWrap
        elide: Text.ElideNone
      }

      Caption {
        visible: !card.active
        Layout.fillWidth: true
        text: {
          void panel.tick
          var last = Number(panel.sv(card.agent, "LastAt", 0))
          return "no burn in the last " + panel.widget.windowLabel(panel.windowMinutes)
            + (last > 0 ? "  ·  last active " + panel.agoText(last) : "")
        }
      }

      // ── burn: how hard, and when ───────────────────────────────────────
      RowLayout {
        visible: card.active
        Layout.fillWidth: true
        Caption { Layout.fillWidth: true; font.bold: true; text: "BURN  ·  TOKENS / MIN" }
        Caption {
          text: "peak " + panel.widget.compact(panel.sv(card.agent, "Peak", 0)) + " at " + panel.clockText(panel.sv(card.agent, "PeakAt", 0))
        }
      }
      RowLayout {
        visible: card.active
        Layout.fillWidth: true
        spacing: Style.space(8)
        MiniStat { label: "/MIN NOW"; value: panel.rateNow(card.agent); tone: card.accent }
        MiniStat { label: "/MIN 1H"; value: panel.rateHour(card.agent) }
        MiniStat { label: "/MIN " + panel.widget.windowLabel(panel.windowMinutes).toUpperCase(); value: panel.rateWindow(card.agent) }
      }
      BurnBars { agent: card.agent; visible: card.active }

      // ── what burned, and how much came out of the cache ────────────────
      RowLayout {
        visible: card.active
        Layout.fillWidth: true
        Caption { Layout.fillWidth: true; font.bold: true; text: "TOKEN MIX" }
        Caption {
          text: "cache read " + panel.widget.compact(card.split.cacheRead || 0) + "  ·  "
            + Math.round(panel.cacheShare(card.split) * 100) + "% of input"
          color: card.accent
          font.bold: true
        }
      }
      Item {
        visible: card.active
        Layout.fillWidth: true
        implicitHeight: Style.space(8)
        Rectangle { anchors.fill: parent; radius: height / 2; color: panel.faint }
        Row {
          anchors.fill: parent
          Rectangle {
            height: parent.height
            width: parent.width * Number(card.split.input || 0) / card.splitSum * panel.reveal
            color: Util.alpha(card.accent, 0.45)
            Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
          }
          Rectangle {
            height: parent.height
            width: parent.width * Number(card.split.cacheWrite || 0) / card.splitSum * panel.reveal
            color: Util.alpha(card.accent, 0.75)
            Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
          }
          Rectangle {
            height: parent.height
            width: parent.width * Number(card.split.output || 0) / card.splitSum * panel.reveal
            color: card.accent
            Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
          }
        }
      }
      Caption {
        visible: card.active
        Layout.fillWidth: true
        text: "in " + panel.widget.compact(card.split.input || 0)
          + "  ·  cache-write " + panel.widget.compact(card.split.cacheWrite || 0)
          + "  ·  out " + panel.widget.compact(card.split.output || 0)
      }

      // ── which models did the burning ───────────────────────────────────
      Caption { visible: card.active && card.models.length > 0; font.bold: true; text: "BY MODEL" }
      Repeater {
        model: card.active ? card.models.slice(0, 4) : []
        delegate: RowLayout {
          required property var modelData
          readonly property real share: card.total > 0 ? modelData.tokens / card.total : 0
          Layout.fillWidth: true
          spacing: Style.space(6)
          Body { text: panel.prettyModel(modelData.id); Layout.preferredWidth: Style.space(92) }
          Gauge { fraction: share; accent: card.accent }
          Caption { text: Math.round(share * 100) + "%"; Layout.preferredWidth: Style.space(28); horizontalAlignment: Text.AlignRight }
          Body {
            text: panel.widget.compact(modelData.tokens)
            color: card.accent
            font.bold: true
            Layout.preferredWidth: Style.space(40)
            horizontalAlignment: Text.AlignRight
          }
        }
      }

      Item { Layout.fillHeight: true }

      Caption {
        visible: card.active
        Layout.fillWidth: true
        text: {
          void panel.tick
          return panel.sv(card.agent, "Turns", 0) + " turns  ·  " + panel.sv(card.agent, "Sessions", 0)
            + " sessions  ·  active " + panel.agoText(panel.sv(card.agent, "LastAt", 0))
        }
      }
    }
  }

  KeyboardPanel {
    id: kpanel
    anchorItem: panel.widget.anchorItem
    owner: panel.widget
    bar: panel.widget.bar
    open: panel.opened
    focusTarget: keyCatcher
    contentWidth: panel.mode === "setup"
      ? fittedContentWidth(Style.space(1040))
      : fittedContentWidth(panel.panelWidth)
    // Never a Flickable in here: the cap is the screen, and everything below
    // is sized to fit inside it.
    contentHeight: panel.mode === "setup"
      ? fittedContentHeight(setupContent.implicitHeight, Style.space(700))
      : fittedContentHeight(content.implicitHeight, Style.space(960))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: modelPicker.popupOpen
      onCloseRequested: panel.widget.close()

      // Fred, 2026-09-25: "sometimes that ESC goes to the terminal or herdr
      // under it." KeyboardPanel grabs the keyboard Exclusive for 75ms and then
      // settles on OnDemand, and Hyprland can hand an OnDemand layer's focus
      // back to the window beneath it while the panel is still up. A click
      // outside closes the panel before this runs, so while we are open any
      // focus loss is theft: prime Exclusive again and take the keys back.
      readonly property bool windowActive: Window.active
      onWindowActiveChanged: if (!windowActive) refocusTimer.restart()
      Timer {
        id: refocusTimer
        interval: 30
        onTriggered: {
          if (!panel.opened || keyCatcher.windowActive) return
          kpanel.focusPrimed = false
          kpanel.beginFocusPrime()
          keyCatcher.forceActiveFocus()
        }
      }
      onTabRequested: direction => panel.switchPanel(direction)
      onTextKey: function(text) {
        if (text === "r" || text === "R") panel.refreshAll()
      }

      // ── SETUP ───────────────────────────────────────────────────────────
      // Fred, 2026-09-20: "move the sub selection away from right click and add
      // it to SETUP button where all options are available across all
      // features." Every choice the plugin offers, in one place, three columns
      // wide so none of it scrolls. Each row writes straight through the bar,
      // so a change here is the same change the shell's own settings page
      // would make, and it survives a restart.
      ColumnLayout {
        id: setupContent
        visible: panel.mode === "setup"
        width: parent.width
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text {
            text: "SETUP"
            textFormat: Text.PlainText
            color: panel.foreground
            font.family: panel.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Caption { Layout.fillWidth: true; text: "everything Burn Bar can show, and how" }
          Button {
            text: "Back to the cockpit"
            onClicked: panel.mode = "cockpit"
          }
        }

        GridLayout {
          Layout.fillWidth: true
          columns: 3
          columnSpacing: Style.space(18)
          rowSpacing: Style.space(8)

          // ── column 1: what gets a card and a lane ──────────────────────
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 1
            spacing: Style.space(4)
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "SUBSCRIPTIONS  ·  TICK ANY"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            Repeater {
              model: panel.viewOptions()
              delegate: SetupRow {
                required property var modelData
                mark: modelData.current ? "☑" : "☐"
                on: modelData.current
                label: modelData.label
                note: modelData.note
                tone: modelData.accent
                noteUrgent: /^rest|^spent/.test(String(modelData.note))
                onActivated: panel.chooseView(modelData.id)
              }
            }
            Caption {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: "A ticked subscription gets a card in the cockpit and a lane on the bar. Unticked, it has neither."
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "WARNINGS"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            SetupRow {
              // The same refresh glyph the header button uses: the plain arrow is not
              // in the panel font and rendered as a stray hook.
              mark: "󰑐"
              label: "Warn me again"
              note: panel.widget.acknowledgedCount > 0
                ? panel.widget.acknowledgedCount + " dismissed" : "nothing dismissed"
              onActivated: panel.widget.clearPaceAck()
            }
          }

          // ── column 2: what the cards say ───────────────────────────────
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 1
            spacing: Style.space(4)
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "CARD HEADLINE"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            SetupRow {
              mark: panel.heroMode === "budget" ? "◉" : "○"
              on: panel.heroMode === "budget"
              label: "Budget"
              note: "how much is spent, and will it last"
              onActivated: panel.widget.setHeroMode("budget")
            }
            SetupRow {
              mark: panel.heroMode === "tokens" ? "◉" : "○"
              on: panel.heroMode === "tokens"
              label: "Tokens"
              note: "raw burn in the window"
              onActivated: panel.widget.setHeroMode("tokens")
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "CARD GLOW  ·  WHAT LIGHTS A CARD UP"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            Repeater {
              model: panel.glowOptions
              delegate: SetupRow {
                required property var modelData
                mark: panel.glowMode === modelData.id ? "◉" : "○"
                on: panel.glowMode === modelData.id
                label: modelData.label
                note: modelData.note
                onActivated: panel.widget.setGlowMode(modelData.id)
              }
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "BUDGET WINDOWS"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            SetupRow {
              mark: panel.showSessionWindows ? "☑" : "☐"
              on: panel.showSessionWindows
              label: "5-hour session windows"
              note: "off by default"
              onActivated: panel.widget.toggleSessionWindows()
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "HISTORY WINDOW"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Repeater {
                model: [180, 360, 720, 1440]
                delegate: Rectangle {
                  id: chip
                  required property int modelData
                  readonly property bool on: Math.round(panel.windowMinutes) === modelData
                  Layout.fillWidth: true
                  implicitHeight: Style.space(28)
                  radius: height / 2
                  color: chip.on ? Util.alpha(panel.foreground, 0.16) : chipHover.hovered ? Util.alpha(panel.foreground, 0.08) : "transparent"
                  border.width: 1
                  border.color: Util.alpha(panel.foreground, chip.on ? 0.55 : 0.2)
                  HoverHandler { id: chipHover }
                  Body {
                    anchors.centerIn: parent
                    text: panel.widget.windowLabel(chip.modelData)
                    font.bold: chip.on
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: panel.widget.persist({ windowMinutes: chip.modelData })
                  }
                }
              }
            }

          }

          // ── column 3: how the strip on the bar behaves ─────────────────
          ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 1
            spacing: Style.space(4)
            PanelSectionHeader {
              Layout.fillWidth: true
              text: "THE STRIP ON THE BAR"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }
            SetupRow {
              mark: panel.optOn("showGauges", true) ? "☑" : "☐"
              on: panel.optOn("showGauges", true)
              label: "Quota gauges"
              note: "a fuel gauge per subscription"
              onActivated: panel.flip("showGauges", true)
            }
            SetupRow {
              mark: panel.optOn("advice", true) ? "☑" : "☐"
              on: panel.optOn("advice", true)
              label: "Suggest a sub"
              note: "when nothing is over pace"
              onActivated: panel.flip("advice", true)
            }
            SetupRow {
              mark: panel.optOn("showLocal", true) ? "☑" : "☐"
              on: panel.optOn("showLocal", true)
              label: "Local GPU lane"
              note: "when this machine has one"
              onActivated: panel.flip("showLocal", true)
            }
            SetupRow {
              mark: panel.optOn("stretch", false) ? "☑" : "☐"
              on: panel.optOn("stretch", false)
              label: "Fill the room beside it"
              note: "off = a fixed size"
              onActivated: panel.flip("stretch", false)
            }
            SetupRow {
              mark: panel.optOn("emberFlicker", true) ? "☑" : "☐"
              on: panel.optOn("emberFlicker", true)
              label: "Ember flicker"
              note: "live cells breathe"
              onActivated: panel.flip("emberFlicker", true)
            }
            SetupRow {
              mark: panel.optOn("sparks", true) ? "☑" : "☐"
              on: panel.optOn("sparks", true)
              label: "Rising sparks"
              note: "on fresh burn"
              onActivated: panel.flip("sparks", true)
            }
            SetupRow {
              mark: panel.optOn("themeColors", true) ? "☑" : "☐"
              on: panel.optOn("themeColors", true)
              label: "Follow theme colours"
              note: "else the built-in ramp"
              onActivated: panel.flip("themeColors", true)
            }
            Caption {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              text: "Widths, refresh intervals and the Ollama address are numbers, and live with the rest of the bar's settings in the shell."
            }
          }
        }
      }

      ColumnLayout {
        id: content
        visible: panel.mode === "cockpit"
        width: parent.width
        spacing: Style.space(panel.tight(10, 7, 5))
        // The content grew (a window row appeared, a model list filled in):
        // check again that it still fits the screen.
        onImplicitHeightChanged: if (panel.opened) fitCheck.restart()

        // ── hero ─────────────────────────────────────────────────────────────
        PanelHero {
          Layout.fillWidth: true
          title: ""
          // "burned", not "billed": this figure deliberately leaves cache
          // reads out, and those are billed too, at a lower rate.
          meta: "frontier tokens burned · last " + panel.widget.windowLabel(panel.windowMinutes) + "  ·  "
            + ((panel.svc
              ? (panel.showClaude ? panel.svc.claudeTurns : 0)
                + (panel.showCodex ? panel.svc.codexTurns : 0)
                + (panel.showGrok ? panel.svc.grokTurns : 0)
                + (panel.showKimi ? panel.svc.kimiTurns : 0) : 0)) + " turns  ·  "
            + ((panel.svc
              ? (panel.showClaude ? panel.svc.claudeSessions : 0)
                + (panel.showCodex ? panel.svc.codexSessions : 0)
                + (panel.showGrok ? panel.svc.grokSessions : 0)
                + (panel.showKimi ? panel.svc.kimiSessions : 0) : 0)) + " sessions"
            + (panel.showLocal && panel.localTokens ? "  ·  " + Math.round(panel.offload * 100) + "% kept on " + panel.boxName : "")
          detail: panel.svc
            ? panel.widget.compact(
                (panel.showClaude ? panel.rateNow("claude") : 0)
                + (panel.showCodex ? panel.rateNow("codex") : 0)
                + (panel.showGrok ? panel.rateNow("grok") : 0)
                + (panel.showKimi ? panel.rateNow("kimi") : 0)) + "/min last 5m  ·  "
              + panel.widget.compact(
                (panel.showClaude ? panel.rateHour("claude") : 0)
                + (panel.showCodex ? panel.rateHour("codex") : 0)
                + (panel.showGrok ? panel.rateHour("grok") : 0)
                + (panel.showKimi ? panel.rateHour("kimi") : 0)) + "/min last hour  ·  "
              + "active " + panel.agoText(Math.max(
                panel.showClaude ? panel.svc.claudeLastAt : 0,
                panel.showCodex ? panel.svc.codexLastAt : 0,
                panel.showGrok ? panel.svc.grokLastAt : 0,
                panel.showKimi ? panel.svc.kimiLastAt : 0))
            : ""
          foreground: panel.widget.claudeHot
          fontFamily: panel.fontFamily
          iconComponent: Component {
            Item {
              implicitWidth: Style.space(112)
              implicitHeight: Style.space(34)
              RowLayout {
                anchors.fill: parent
                spacing: Style.space(6)
                Text {
                  text: "󰈸"
                  textFormat: Text.PlainText
                  color: panel.widget.claudeHot
                  font.family: panel.fontFamily
                  font.pixelSize: Style.font.display
                  // The flame flickers with live burn, like the bar.
                  opacity: 0.75 + 0.25 * Math.sin(panel.widget.emberPhase * 2)
                }
                Counter {
                  target: panel.svc
                    ? (panel.showClaude ? panel.svc.claudeTotal : 0)
                      + (panel.showCodex ? panel.svc.codexTotal : 0)
                      + (panel.showGrok ? panel.svc.grokTotal : 0)
                      + (panel.showKimi ? panel.svc.kimiTotal : 0) : 0
                  format: panel.widget.compact
                  color: panel.widget.claudeHot
                  font.pixelSize: Style.font.displayLarge
                  font.bold: true
                }
              }
            }
          }
          trailingControl: Component {
            RowLayout {
              spacing: Style.space(6)
              Button {
                text: "SETUP"
                onClicked: panel.mode = "setup"
              }
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh everything (R)"
                foreground: panel.foreground
                fontFamily: panel.fontFamily
                onClicked: panel.refreshAll()
              }
            }
          }
        }

        // ── the cards ───────────────────────────────────────────────────────
        // One per subscription that is ticked in the right-click menu, side by
        // side, equal width, and all of it on screen: width is the remedy here,
        // never a scrollbar. The model is a fixed list - a list rebuilt on every
        // tick would destroy and recreate the cards, and a recreated Counter
        // snaps straight to its target instead of counting up.
        // ── guidance: what to do, before any of the data ───────────────────
        // Only with two or more subscriptions: one sub leaves nothing to choose
        // between. Never the local GPU: this is about where you stand on your
        // plans, not about where work should run.
        Rectangle {
          id: guideBar
          visible: panel.guideShown && panel.guideHeadline !== ""
          Layout.fillWidth: true
          implicitHeight: visible ? Style.space(panel.tight(38, 34, 30)) : 0
          radius: Style.cornerRadius
          color: Util.alpha(panel.guideTone, 0.10)
          border.width: 1
          border.color: Util.alpha(panel.guideTone, 0.45)
          opacity: panel.reveal
          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(14)
            anchors.rightMargin: Style.space(14)
            spacing: Style.space(12)
            Text {
              textFormat: Text.PlainText
              text: (panel.guidance.pick !== "" ? "▶  " : "◷  ") + panel.guideHeadline.toUpperCase()
              color: panel.guideTone
              font.family: panel.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }
            Body {
              Layout.fillWidth: true
              text: panel.guideReason
              elide: Text.ElideRight
            }
            Caption {
              visible: text !== ""
              text: panel.guideAside
              elide: Text.ElideRight
              Layout.maximumWidth: guideBar.width * 0.42
            }
          }
        }

        RowLayout {
          id: cards
          Layout.fillWidth: true
          spacing: Style.space(14)

          Repeater {
            model: ["claude", "codex", "grok", "kimi"]
            delegate: SubCard {
              required property string modelData
              agent: modelData
            }
          }

          // The local GPU is a card like the rest. It has no plan to run out
          // of, so it leads with what it saved instead.
          Rectangle {
            id: localCard
            visible: panel.showLocal
            Layout.fillWidth: visible
            Layout.fillHeight: true
            Layout.preferredWidth: visible ? 1 : 0
            Layout.minimumWidth: 0
            implicitHeight: visible ? localBody.implicitHeight + Style.space(26) : 0
            radius: Style.cornerRadius
            color: Util.alpha(panel.widget.localHot, 0.055)
            border.width: 1
            border.color: Util.alpha(panel.localState, 0.32)
            opacity: panel.reveal
            transform: Translate { y: (1 - panel.reveal) * 12 }

            // No plan to run out of, so the only reason that applies here is
            // "burning now": the GPU card lights while the GPU is working.
            CardGlow {
              tone: panel.widget.localHot
              strength: localCard.visible && panel.glowMode === "burn" && panel.localActive ? 0.8 : 0
              breathe: true
              corner: localCard.radius
            }

            Rectangle {
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - Style.space(24)
              height: 2
              radius: 1
              color: panel.localState
              opacity: panel.localActive ? 0.85 : 0.35
            }

            ColumnLayout {
              id: localBody
              anchors.fill: parent
              anchors.margins: Style.space(13)
              spacing: Style.space(8)


            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              // Reactor glyph, same language as the bar.
              Item {
                implicitWidth: Style.space(26)
                implicitHeight: Style.space(26)
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * (0.8 + 0.3 * Math.min(1, (panel.svc ? panel.svc.localLoad : 0) / 100))
                  height: width; radius: width / 2
                  color: panel.localState; opacity: panel.localActive ? 0.30 : 0.14
                  Behavior on width { NumberAnimation { duration: 320 } }
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.58; height: width; radius: width / 2
                  color: panel.localState
                  Behavior on color { ColorAnimation { duration: 260 } }
                  SequentialAnimation on scale {
                    running: panel.localActive && panel.opened
                    loops: Animation.Infinite
                    NumberAnimation { to: 1.14; duration: 480; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0.94; duration: 480; easing.type: Easing.InOutSine }
                  }
                }
                Rectangle {
                  anchors.centerIn: parent
                  width: parent.width * 0.24; height: width; radius: width / 2
                  color: panel.widget.bar ? panel.widget.bar.background : Color.background
                }
              }
              ColumnLayout {
                Layout.fillWidth: true
                spacing: 0
                Caption {
                  Layout.fillWidth: true
                  text: panel.boxLabel + "  ·  " + (!panel.localOnline ? "OFFLINE" : panel.localActive ? "INFERENCING" : "IDLE")
                  color: panel.localState
                  font.bold: true
                }
                // Residency came over HTTP; the hardware line comes over ssh
                // and can be missing on its own. Say which, in red, rather
                // than showing a board full of zeros.
                Caption {
                  Layout.fillWidth: true
                  color: panel.svc && panel.localOnline && panel.svc.localTelemetryError !== "" ? Color.urgent : panel.dim
                  text: !panel.svc ? ""
                    : panel.localOnline && panel.svc.localTelemetryError !== ""
                      ? "no hardware telemetry  ·  " + panel.svc.localTelemetryError
                        + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                      : (panel.svc.localGpuName !== "" ? panel.svc.localGpuName : "no telemetry yet")
                        + "  ·  " + String(panel.svc.localBackend).toUpperCase()
                        + (panel.svc.localVersion !== "" ? "  ·  ollama " + panel.svc.localVersion : "")
                }
              }
            }

            // ── local tokens and the offload share ─────────────────────────
            // The headline of this column: how much burned here instead of at
            // a frontier model, in the same unit as the cloud tiles, and what
            // share of everything that burned that was.
            PanelSectionHeader {
              Layout.fillWidth: true
              text: panel.localTokens
                ? panel.boxLabel + " TOKENS  ·  " + Math.round(panel.offload * 100) + "% OFFLOADED FROM FRONTIER"
                : panel.boxLabel + " TOKENS  ·  NO RECORD"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
              elide: Text.ElideRight
            }
            Gauge {
              visible: panel.localTokens
              fraction: panel.offload
              accent: panel.widget.localHot
            }
            Caption {
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
              color: panel.localTokens ? panel.dim : Color.urgent
              text: {
                void panel.tick
                var s = panel.svc
                if (!s) return ""
                if (!panel.localTokens) return s.localTokensReason !== ""
                  ? s.localTokensReason
                  : "the Ollama journal is not readable from this account"
                var sp = s.localTokensSplit || {}
                var top = panel.topModel(s.localTokensByModel)
                return panel.widget.compact(s.localTokensTotal) + " tokens burned on " + panel.boxName + " · "
                  + s.localTokensTurns + " turns · prompt " + panel.widget.compact(sp.input || 0)
                  + " · generated " + panel.widget.compact(sp.output || 0)
                  + " · cached " + panel.widget.compact(sp.cacheRead || 0)
                  + (top !== "" ? " · mostly " + panel.plainText(top, 48) : "")
              }
            }

            // Jetson telemetry, two across so every tile has room for its
            // unit and sub-line. A metric the board does not expose reads as
            // 0 and the tile hides its bar rather than drawing a full or
            // empty one.
            GridLayout {
              Layout.fillWidth: true
              columns: 2
              columnSpacing: Style.space(6)
              rowSpacing: Style.space(6)

              StatTile {
                caption: "GPU LOAD"
                value: panel.svc ? panel.svc.localGpu : 0
                unit: "%"
                sub: "runner cpu " + (panel.svc ? Math.round(panel.svc.localCpu) : 0) + "%"
                fraction: panel.svc ? panel.svc.localGpu / 100 : 0
                accent: panel.localState
              }
              StatTile {
                // VDD_IN: the whole board at the barrel jack. The CPU/GPU/CV
                // rail is the part inference moves, so it rides underneath.
                caption: "POWER DRAW"
                value: panel.svc ? panel.svc.localPowerW : 0
                format: function(v) { return v > 0 ? v.toFixed(1) : "--" }
                unit: "W"
                sub: (panel.svc && panel.svc.localGpuRailW > 0 ? "cpu/gpu rail " + panel.svc.localGpuRailW.toFixed(1) + " W · " : "")
                  + (panel.svc && panel.svc.localPowerLimitW > 0
                    ? "limit " + Math.round(panel.svc.localPowerLimitW) + " W"
                    : "peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(1) : 0) + " W")
                fraction: panel.svc && panel.svc.localPowerLimitW > 0
                  ? panel.svc.localPowerW / panel.svc.localPowerLimitW
                  : (panel.svc && panel.svc.localPeakPowerW > 0 ? panel.svc.localPowerW / panel.svc.localPeakPowerW : -1)
                accent: panel.powerColor
              }
              StatTile {
                caption: "TEMPERATURE"
                value: panel.svc ? panel.svc.localTempC : 0
                format: function(v) { return v > 0 ? String(Math.round(v)) : "--" }
                unit: "°C"
                sub: panel.svc && panel.svc.localFanPct > 0 ? "fan " + Math.round(panel.svc.localFanPct) + "%"
                  : (!panel.svc || panel.svc.localTempC <= 0 ? "no sensor reading"
                    : panel.svc.localTempC >= 85 ? "throttle territory"
                    : panel.svc.localTempC >= 70 ? "warm" : "cool")
                fraction: panel.svc && panel.svc.localTempC > 0 ? panel.svc.localTempC / 95 : -1
                accent: panel.svc && panel.svc.localTempC >= 85 ? Color.urgent
                  : panel.svc && panel.svc.localTempC >= 70 ? panel.widget.gaugeWarn : panel.widget.localHot
              }
              StatTile {
                // Unified memory: the GPU and the OS draw from the same 8 GB.
                caption: "MEMORY  ·  UNIFIED"
                value: panel.svc ? panel.svc.localVramUsedMb / 1024 : 0
                format: function(v) { return panel.svc && panel.svc.localVramTotalMb > 0 ? v.toFixed(1) : "--" }
                unit: "/ " + (panel.svc ? panel.gb(panel.svc.localVramTotalMb) : "--") + " GB"
                sub: panel.svc && panel.svc.localVramTotalMb > 0
                  ? "models " + panel.gb(panel.svc.localVramModelsMb) + " GB · free "
                    + panel.gb(panel.svc.localVramTotalMb - panel.svc.localVramUsedMb) + " GB"
                  : ""
                fraction: panel.svc && panel.svc.localVramTotalMb > 0 ? panel.svc.localVramUsedMb / panel.svc.localVramTotalMb : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "GPU CLOCK"
                value: panel.svc ? panel.svc.localClockMhz : 0
                format: function(v) { return v > 0 ? String(Math.round(v)) : "--" }
                unit: "MHz"
                sub: panel.svc && panel.svc.localClockMaxMhz > 0
                  ? "ceiling " + Math.round(panel.svc.localClockMaxMhz) + " MHz" : ""
                fraction: panel.svc && panel.svc.localClockMaxMhz > 0 ? panel.svc.localClockMhz / panel.svc.localClockMaxMhz : -1
                accent: panel.widget.localHot
              }
              StatTile {
                caption: "WARM MODELS"
                value: panel.svc ? panel.svc.localModelCount : 0
                unit: panel.svc && panel.svc.localModelCount === 1 ? "model" : "models"
                sub: panel.svc && panel.svc.localSampledAt > 0
                  ? "sampled " + panel.agoText(panel.svc.localSampledAt)
                    + " · every " + (panel.svc.localRefreshMs / 1000).toFixed(1) + "s"
                  : "no sample yet"
                fraction: -1
                accent: panel.localState
              }
            }

            Trace {
              // The span the ring actually covers, from its own timestamps,
              // polls skip while a probe runs and refreshes add early samples.
              caption: "LOAD  ·  LAST " + Math.round((panel.svc ? panel.svc.localSpanMs : 0) / 1000) + "S"
              valueText: (panel.svc ? Math.round(panel.svc.localLoad) : 0) + "%  ·  peak " + (panel.svc ? Math.round(panel.svc.localPeakLoad) : 0) + "%"
              samples: panel.svc ? panel.svc.localHistory : []
              max: 100
              accent: panel.localState
            }
            Trace {
              caption: "POWER DRAW"
              valueText: (panel.svc ? panel.svc.localPowerW.toFixed(1) : "0") + " W  ·  peak " + (panel.svc ? panel.svc.localPeakPowerW.toFixed(1) : "0") + " W"
              samples: panel.svc ? panel.svc.localPowerHistory : []
              max: panel.svc && panel.svc.localPowerLimitW > 0 ? panel.svc.localPowerLimitW : Math.max(1, panel.svc ? panel.svc.localPeakPowerW : 1)
              accent: panel.powerColor
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              // "loaded", not "in memory": /api/ps lists CPU-resident models
              // too, and each row says how much GPU memory it actually holds.
              text: "RESIDENT MODELS  ·  " + (panel.svc ? panel.svc.localModelCount : 0) + " LOADED"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            Caption {
              visible: residentRepeater.count === 0
              text: panel.localOnline ? "nothing warm: pick a model below and load it" : (panel.svc ? panel.svc.localError : "")
              Layout.fillWidth: true
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }

            Repeater {
              id: residentRepeater
              readonly property var rows: panel.svc ? panel.svc.localModelDetails : []
              model: rows.slice(0, panel.maxRows)
              delegate: ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 1
                RowLayout {
                  Layout.fillWidth: true
                  Body { text: panel.plainText(modelData.name, 64); color: panel.widget.localHot; font.bold: true; Layout.fillWidth: true }
                  Caption {
                    // "evicts in 4m" is the number that matters: it is when the
                    // next request pays the load cost again.
                    text: modelData.expiresAt && Date.parse(String(modelData.expiresAt)) - Date.now() > 315360000000
                      ? "pinned" : "evicts in " + panel.untilText(modelData.expiresAt)
                  }
                }
                Caption {
                  Layout.fillWidth: true
                  text: [panel.plainText(modelData.parameters, 16), panel.plainText(modelData.quantization, 16),
                         panel.plainText(modelData.family, 16),
                         modelData.sizeVram > 0 ? (Number(modelData.sizeVram) / 1073741824).toFixed(1) + " GB gpu" : "",
                         modelData.contextLength > 0 ? panel.widget.compact(modelData.contextLength) + " ctx" : ""]
                    .filter(Boolean).join("  ·  ")
                }
              }
            }
            Caption {
              visible: residentRepeater.rows.length > panel.maxRows
              text: "+ " + (residentRepeater.rows.length - panel.maxRows) + " more resident"
              Layout.fillWidth: true
            }

            PanelSectionHeader {
              Layout.fillWidth: true
              text: "MODEL CONTROL  ·  " + panel.localOptions.length + " INSTALLED"
              foreground: panel.foreground
              fontFamily: panel.fontFamily
            }

            SearchableDropdown {
              id: modelPicker
              Layout.fillWidth: true
              label: "Installed Ollama model"
              placeholderText: "Choose a model…"
              fontFamily: panel.fontFamily
              options: panel.localOptions
              value: panel.selectedModel
              onChanged: function(value) { panel.selectedModel = value }
            }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)
              Button {
                text: panel.localBusy ? "Working…" : "Load & keep warm"
                enabled: !panel.localBusy && panel.localOnline && panel.selectedModel !== ""
                onClicked: panel.runLocalAction("load")
              }
              Button {
                text: "Unload"
                enabled: !panel.localBusy && panel.localOnline && panel.selectedModel !== ""
                onClicked: panel.runLocalAction("unload")
              }
              Item { Layout.fillWidth: true }
            }

            Caption {
              Layout.fillWidth: true
              visible: panel.localNote !== ""
              text: panel.localNote
              color: panel.localState
              wrapMode: Text.WordWrap
              elide: Text.ElideNone
            }

              Item { Layout.fillHeight: true }
            }
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: panel.foreground }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(12)
          Caption {
            Layout.fillWidth: true
            text: panel.svc && panel.svc.lastError !== "" ? panel.svc.lastError
              : "the dashed diagonal is an even spend: a line above it is over budget"
                + "  ·  click a headline to flip budget and tokens"
                + (panel.glowMode !== "off" ? "  ·  a card glows for: " + panel.glowLabel() + " (SETUP)" : "")
            color: panel.svc && panel.svc.lastError !== "" ? Color.urgent : panel.dim
          }
          Caption {
            text: "collected " + panel.agoText(panel.svc ? panel.svc.generatedAt : 0)
              + "  ·  R refresh  ·  Esc close"
              + (panel.density > 0 && panel.pluginVersion !== "" ? "  ·  Burn Bar v" + panel.pluginVersion : "")
          }
        }

        // About: version, source, site. Out of the way at the foot of the
        // panel, but always there; you should never have to open a file to
        // learn which Burn Bar you are looking at.
        RowLayout {
          // On a short screen this row folds into the one above it.
          visible: panel.density === 0
          Layout.fillWidth: true
          spacing: Style.space(6)
          Caption {
            text: "Burn Bar" + (panel.pluginVersion !== "" ? "  v" + panel.pluginVersion : "")
          }
          Caption { text: "·"; visible: panel.repoUrl !== "" }
          Link {
            visible: panel.repoUrl !== ""
            text: panel.repoUrl.replace(/^https?:\/\//, "")
            url: panel.repoUrl
          }
          Caption { text: "·"; visible: panel.homeUrl !== "" }
          Link {
            visible: panel.homeUrl !== ""
            text: panel.homeUrl.replace(/^https?:\/\//, "")
            url: panel.homeUrl
          }
          Item { Layout.fillWidth: true }
        }
      }
    }
  }
}
