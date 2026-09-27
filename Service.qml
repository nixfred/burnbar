import QtQuick
import Quickshell
import Quickshell.Io

// Burn Bar service. Owns three jobs: run the cloud-agent collector (Claude, Codex, Grok) on a cadence,
// republish whatever history.json currently says, and poll the Ollama box
// (nano, a Jetson on the tailnet) for live inference load. All extraction
// logic lives in bin/; this file never parses a transcript and never talks
// HTTP or ssh itself.
Item {
  id: root

  property var settings: ({})

  property var buckets: []
  property real claudeTotal: 0
  property real codexTotal: 0
  property real claudePeak: 0
  property real codexPeak: 0
  property int claudeSessions: 0
  property int codexSessions: 0
  property var claudeLimits: []
  property var codexLimits: []
  // When each limits list was actually measured (not when its record was last
  // rewritten: Omarchy re-stamps a record with cached limits when its probe
  // fails), and what the record said about itself ("Sign-in expired"). A
  // percentage without its measurement time is how an 8-hour-old 0% got
  // presented as live.
  property real claudeLimitsMeasuredAt: 0
  property real codexLimitsMeasuredAt: 0
  // Live means Burn Bar re-probes the record itself, so age is meaningful. A
  // snapshot (Grok) is only rewritten when its app happens to log; age says
  // nothing there, and its billing window decides instead.
  property bool claudeLimitsLive: true
  property bool codexLimitsLive: true
  property string claudeLimitsStatus: ""
  // The remedy the usage record already knows ("Run `claude auth login`").
  // Shown beside the fault so a withheld row says what to do about it.
  property string claudeLimitsHelp: ""
  property string codexLimitsHelp: ""
  property string grokLimitsHelp: ""
  property string codexLimitsStatus: ""
  property var claudeByModel: ({})
  property var claudeSplit: ({})
  property var codexSplit: ({})
  property int claudeTurns: 0
  property int codexTurns: 0
  property real claudeFirstAt: 0
  property real claudeLastAt: 0
  property real codexFirstAt: 0
  property real codexLastAt: 0
  property real claudePeakAt: 0
  property real codexPeakAt: 0
  // Exact trailing sums from the collector, tokens in the last 5 and 60
  // minutes measured from timestamped points, not bucket approximations.
  property real claudeTrailing5: 0
  property real claudeTrailing60: 0
  property real codexTrailing5: 0
  property real codexTrailing60: 0
  property real grokTotal: 0
  property real grokPeak: 0
  property int grokSessions: 0
  property var grokLimits: []
  property real grokLimitsMeasuredAt: 0
  // Newest write to any Grok session file, even one too old to be scanned: the
  // only way to know whether Grok has been used since its quota snapshot.
  property real grokLastWriteAt: 0
  property bool grokLimitsLive: false
  property string grokLimitsStatus: ""
  property var grokByModel: ({})
  // Codex had a split and no by-model: every other subscription carries both,
  // and a 2.0 card draws the same sections for all of them.
  property var codexByModel: ({})
  property var grokSplit: ({})
  property int grokTurns: 0
  property real grokFirstAt: 0
  property real grokLastAt: 0
  property real grokPeakAt: 0
  property real grokTrailing5: 0
  property real grokTrailing60: 0

  // Kimi Code runs through Claude Code, so its turns arrive in Claude's own
  // transcripts and only the model id separates them. It has no quota to read:
  // planTier is the tier name Kimi does publish, and limits stays empty.
  property real kimiTotal: 0
  property real kimiPeak: 0
  property int kimiSessions: 0
  property var kimiLimits: []
  property real kimiLimitsMeasuredAt: 0
  property bool kimiLimitsLive: true
  property string kimiLimitsStatus: ""
  property string kimiLimitsHelp: ""
  property string kimiPlanTier: ""
  // A status that describes rather than warns: drawn dim, not urgent.
  property bool kimiLimitsInfo: false
  property var kimiByModel: ({})
  property var kimiSplit: ({})
  property int kimiTurns: 0
  property real kimiFirstAt: 0
  property real kimiLastAt: 0
  property real kimiPeakAt: 0
  property real kimiTrailing5: 0
  property real kimiTrailing60: 0
  // Zcode (Z.ai's coding agent) is burn-only: no plan meter is read, so the
  // limits fields stay at their empty values on purpose. limitsLive false is
  // what tells the panel these are not measurements that went stale.
  property real zcodeTotal: 0
  property real zcodePeak: 0
  property int zcodeSessions: 0
  property real zcodeLimitsMeasuredAt: 0
  property bool zcodeLimitsLive: false
  property var zcodeByModel: ({})
  property var zcodeSplit: ({})
  property int zcodeTurns: 0
  property real zcodeFirstAt: 0
  property real zcodeLastAt: 0
  property real zcodePeakAt: 0
  property real zcodeTrailing5: 0
  property real zcodeTrailing60: 0
  // Tokens burned on the Ollama box over the same exact window, read from
  // the ollama-meter journal there, and the share of all burn that stayed
  // off the frontier models. available=false carries the reason (ssh
  // failed, meter not installed) so the panel can say so instead of showing
  // a confident 0.
  property real localTokensTotal: 0
  property real localTokensTurns: 0
  property real localTokensPeak: 0
  property real localTokensPeakAt: 0
  property real localTokensLastAt: 0
  property real localTokensTrailing5: 0
  property real localTokensTrailing60: 0
  property var localTokensSplit: ({})
  property var localTokensByModel: ({})
  property bool localTokensAvailable: false
  property string localTokensReason: ""
  property real offloadShare: 0
  property real generatedAt: 0
  // real, not int: windowMinutes / bars is fractional for most settings
  // (100 / 12 = 8.33), and an int here silently rounded every rate.
  property real bucketMinutes: 15
  property bool ready: false
  property string lastError: ""
  // True once a collector run has actually failed, so the widget can show
  // a fault instead of an idle animation that looks healthy.
  property bool collectorBroken: false
  // Presence is "this machine uses this agent", not "tokens in the window".
  // The strip hides a lane whose agent is not installed here.
  property bool claudePresent: false
  property bool codexPresent: false
  property bool grokPresent: false
  property bool kimiPresent: false
  property bool zcodePresent: false
  // A compute GPU (NVIDIA, AMD, Jetson) on this machine. Intel iGPU is
  // not one. No GPU → no local lane, no ssh, no Ollama poll.
  // Named hasComputeGpu so it cannot collide with localGpu, the load %.
  property bool hasComputeGpu: false
  property bool hasComputeGpuChecked: false
  property string computeGpuReason: ""

  // Bumped every time a fresh sample lands with more burn than the last one.
  // The widget listens for this to fire its impact animation.
  property int claudePulse: 0
  property int codexPulse: 0
  property int grokPulse: 0
  property int kimiPulse: 0
  property int zcodePulse: 0
  property real lastClaudeLatest: 0
  property real lastCodexLatest: 0
  property real lastGrokLatest: 0
  property real lastKimiLatest: 0
  property real lastZcodeLatest: 0
  property real lastBucketT: 0

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/omarchy/burnbar"
  readonly property string historyPath: stateDir + "/history.json"
  // Resolved from this component's own location, not a hardcoded plugin id:
  // the directory name changes if the plugin is cloned or renamed.
  // A file URL is not a path: a '#' in the install directory stays '%23' in
  // the URL, and python3 would be handed a file that does not exist.
  function localPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }
  readonly property string collectorPath: localPath("bin/burnbar-collect")
  readonly property string localStatusPath: localPath("bin/burnbar-local-status")
  readonly property string localControlPath: localPath("bin/burnbar-local-control")

  // ── local intelligence (Ollama on nano) ────────────────────────────────────
  // Cloud burn is history reconstructed from transcripts; local load is a live
  // vital sign with no persistent record anywhere. So the service keeps its own
  // rolling ring of load samples; that ring IS the local half of the strip.
  property bool localOnline: false
  property bool localActive: false
  property real localLoad: 0
  property real localCpu: 0
  property real localGpu: 0
  property int localModelCount: 0
  property string localModel: ""
  property string localBackend: "none"
  property string localError: ""
  property var localModels: []
  property var localModelDetails: []
  property var localHistory: []
  // Power draw ring, same length and cadence as the load ring, so the panel can
  // trace watts over the same seconds the lane shows load.
  property var localPowerHistory: []
  // When each sample was taken. Polls are skipped while a probe runs and added
  // early by a manual refresh, so the ring's real span is whatever these say,
  // not cells × interval.
  property var localTimeHistory: []
  readonly property real localSpanMs: localTimeHistory.length > 1
    ? Number(localTimeHistory[0]) - Number(localTimeHistory[localTimeHistory.length - 1]) : 0
  property real localPeakLoad: 0
  property real localPeakPowerW: 0
  property int localPulse: 0
  property bool localReady: false
  property real localSampledAt: 0
  property string localVersion: ""
  property string localGpuName: ""
  property real localPowerW: 0
  property real localPowerLimitW: 0
  property real localTempC: 0
  property real localVramUsedMb: 0
  property real localVramTotalMb: 0
  property real localVramModelsMb: 0
  property real localClockMhz: 0
  property real localClockMaxMhz: 0
  property real localFanPct: 0
  // The CPU/GPU/CV rail alone, beside the whole-board draw in localPowerW.
  property real localGpuRailW: 0
  // The probe reaches the box twice, HTTP for residency, ssh for hardware,
  // and either can fail alone. Online with no hardware figures is a real
  // state, and this is its reason.
  property string localTelemetryError: ""
  property string localHostName: ""

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function boundedInt(name, fallback, low, high) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(low, Math.min(high, n))
  }

  readonly property int intervalSec: boundedInt("refreshIntervalSec", 5, 5, 600)
  // Plan limits come from records Omarchy's own collectors write. Nothing
  // else guarantees those records are fresh; the agents panel refreshes them
  // on its own schedule, and when it does not, a 0% written hours ago stays
  // 0%. So Burn Bar asks for them on its own clock.
  readonly property int limitsRefreshSec: boundedInt("limitsRefreshSec", 300, 60, 3600)
  // A record older than three refresh intervals (never under 15 min) is stale.
  readonly property int limitsStaleMs: Math.max(900, 3 * limitsRefreshSec) * 1000
  readonly property int windowMinutes: boundedInt("windowMinutes", 360, 30, 1440)
  // Must match BarWidget.cellCount exactly: the widget draws one cell per
  // bucket, so a mismatch makes the strip cover less time than it claims.
  // The strip asks for one bucket per cell it can actually draw at its
  // current width; 0 means nothing has asked yet, so honour the setting.
  property int requestedBuckets: 0
  readonly property int bucketCount: requestedBuckets > 0
    ? Math.max(6, Math.min(240, requestedBuckets))
    : boundedInt("bars", 12, 6, 240)
  onBucketCountChanged: collect()

  readonly property int localRefreshMs: boundedInt("localRefreshMs", 2500, 1000, 10000)
  // Where Ollama answers, the ssh alias of the box it runs on, and the
  // ollama-meter unit there whose journal carries one line per request.
  readonly property string ollamaUrl: String(setting("ollamaUrl", "http://127.0.0.1:11434") || "http://127.0.0.1:11434").slice(0, 256)
  readonly property string localHost: String(setting("localHost", "localhost") || "localhost").slice(0, 128)
  readonly property string meterUnit: String(setting("meterUnit", "ollama-meter") || "ollama-meter").slice(0, 64)
  // Same clamp as the manifest schema: load is capped at 100, so a threshold
  // above it would mean "never inferencing".
  readonly property int localThreshold: boundedInt("localThreshold", 8, 1, 50)
  // Local cells cover far less wall-clock than the cloud cells; that is on
  // purpose. Local load is a now-signal, not a budget.
  readonly property int localCells: boundedInt("localCells", 9, 4, 20)

  // Latest (right-most in time) bucket per agent, what "now" is burning.
  readonly property real claudeLatest: buckets.length ? Number(buckets[buckets.length - 1].claude || 0) : 0
  readonly property real codexLatest: buckets.length ? Number(buckets[buckets.length - 1].codex || 0) : 0
  readonly property real grokLatest: buckets.length ? Number(buckets[buckets.length - 1].grok || 0) : 0
  readonly property real kimiLatest: buckets.length ? Number(buckets[buckets.length - 1].kimi || 0) : 0
  readonly property real zcodeLatest: buckets.length ? Number(buckets[buckets.length - 1].zcode || 0) : 0

  // Re-evaluated every 30s so a record ages into "stale" and a window rolls
  // into "expired" without waiting for a new sample to arrive.
  property int limitsTick: 0
  Timer { interval: 30000; running: true; repeat: true; onTriggered: root.limitsTick++ }

  // A limit whose reset time has passed describes a window that is over. The
  // number may be right for that window; it says nothing about this one.
  function limitExpired(limit) {
    void root.limitsTick
    var t = Date.parse(String((limit && limit.resetsAt) || ""))
    return isFinite(t) && t <= Date.now()
  }
  // Age only condemns a figure Burn Bar itself keeps refreshing. A snapshot
  // (live === false) is never stale by age: Grok Bot logs its credits config
  // only at startup, so a 15-minute bound blanked Grok's weekly row for days
  // while the window it describes was still open. limitExpired() judges those.
  function limitsStale(updatedAt, live) {
    void root.limitsTick
    if (live === false) return false
    var t = Number(updatedAt) || 0
    return t <= 0 || Date.now() - t > root.limitsStaleMs
  }
  // True only for a snapshot whose figure is older than the staleness bound:
  // still shown, but the panel says when it was measured.
  function limitsSnapshotAged(updatedAt, live) {
    void root.limitsTick
    if (live !== false) return false
    var t = Number(updatedAt) || 0
    return t > 0 && Date.now() - t > root.limitsStaleMs
  }

  // -1 means "unknown": the record is stale, the matching window has rolled
  // over, the collector could not read the figure, or there is no window by
  // that name at all. A gauge must show nothing rather than a confident 0%,
  // and a session figure must never stand in for a weekly one.
  function limitPercent(limits, needle, measuredAt, live) {
    if (limitsStale(measuredAt, live)) return -1
    for (var i = 0; i < limits.length; i++) {
      var label = String(limits[i].label || "")
      if (label.toLowerCase().indexOf(needle) < 0) continue
      if (limitExpired(limits[i])) return -1
      var p = Number(limits[i].percent)
      return isFinite(p) && p >= 0 ? p : -1
    }
    return -1
  }

  // The pace block the collector attached to this row, or null when there is
  // nothing to say. Same withholding rules as limitPercent: a stale record or a
  // rolled-over window has no pace either, because pace is a claim about NOW.
  function limitPace(limits, needle, measuredAt, live) {
    if (limitsStale(measuredAt, live)) return null
    for (var i = 0; i < limits.length; i++) {
      var label = String(limits[i].label || "")
      if (label.toLowerCase().indexOf(needle) < 0) continue
      if (limitExpired(limits[i])) return null
      var pace = limits[i].pace
      return (pace && Number(pace.ratio) >= 0) ? pace : null
    }
    return null
  }

  // Weekly is the limit that actually bites on both plans.
  readonly property real claudeWeekly: limitPercent(claudeLimits, "weekly", claudeLimitsMeasuredAt, claudeLimitsLive)
  readonly property real codexWeekly: limitPercent(codexLimits, "weekly", codexLimitsMeasuredAt, codexLimitsLive)
  readonly property real grokWeekly: limitPercent(grokLimits, "weekly", grokLimitsMeasuredAt, grokLimitsLive)
  // Kimi meters by the month, not the week: "Monthly (total)" is its credit
  // pool, and the one worth putting on the strip gauge.
  readonly property real kimiMonthly: limitPercent(kimiLimits, "monthly (total)", kimiLimitsMeasuredAt, kimiLimitsLive)

  // The same four windows, as pace: how far over or under an even spend each
  // one is running. The gauges tint by this, so being over budget is visible
  // without opening anything.
  readonly property var claudeWeeklyPace: limitPace(claudeLimits, "weekly", claudeLimitsMeasuredAt, claudeLimitsLive)
  readonly property var codexWeeklyPace: limitPace(codexLimits, "weekly", codexLimitsMeasuredAt, codexLimitsLive)
  readonly property var grokWeeklyPace: limitPace(grokLimits, "weekly", grokLimitsMeasuredAt, grokLimitsLive)
  readonly property var kimiMonthlyPace: limitPace(kimiLimits, "monthly (total)", kimiLimitsMeasuredAt, kimiLimitsLive)

  // A collect() asked for while one is running is not dropped: the limits
  // refresh asks for one the moment it lands, and that ask must survive an
  // in-flight scan that read the old records.
  property bool collectPending: false
  property bool lastCollectOk: false
  function collect() {
    if (collector.running) { root.collectPending = true; return }
    root.collectPending = false
    collector.launched = false
    collector.command = root.hasComputeGpu
      ? ["python3", root.collectorPath,
        "--window", String(root.windowMinutes),
        "--buckets", String(root.bucketCount),
        "--meter-host", root.localHost,
        "--meter-unit", root.meterUnit]
      : ["python3", root.collectorPath,
        "--window", String(root.windowMinutes),
        "--buckets", String(root.bucketCount),
        "--no-local"]
    collector.running = true
    watchdog.restart()
  }

  Process {
    id: collector
    property bool launched: false
    onStarted: launched = true
    // Quickshell never emits exited() for a command that could not start (no
    // python3, say): running just flips back to false. Verified on 0.3.1.
    // Without this the strip's idle animation would call a missing runtime
    // healthy: the exact silent outage 1.1 claimed to have fixed.
    onRunningChanged: {
      if (running || launched) return
      watchdog.stop()
      root.lastError = "python3 not found: Burn Bar needs it to read agent usage"
      root.collectorBroken = true
    }
    stderr: SplitParser {
      onRead: data => { if (String(data).trim() !== "") root.lastError = String(data).slice(0, 240) }
    }
    onExited: function(code) {
      watchdog.stop()
      root.lastCollectOk = code === 0
      if (code !== 0) {
        root.lastError = root.lastError || ("collector exited " + code)
        root.collectorBroken = true
      }
      // The fault is cleared by apply(), once a snapshot has actually been
      // read and validated, not here, where a zero exit says nothing about
      // whether what it wrote can be parsed.
      historyFile.reload()
      if (root.collectPending) root.collect()
    }
  }

  // A wedged collector would otherwise freeze the strip forever, because
  // collect() refuses to start while one is already running.
  Timer {
    id: watchdog
    // Longer than the collector's own worst case (two 20 s journal reads, two
    // 10 s unit probes, two Kimi calls): at 30 s this killed a healthy run
    // whenever a remote meter host was slow, and published nothing.
    interval: 75000
    repeat: false
    onTriggered: {
      if (collector.running) {
        console.warn("burnbar: collector exceeded 75s, killing")
        collector.signal(15)
        root.lastError = "collector timed out"
        root.collectorBroken = true
      }
    }
  }

  FileView {
    id: historyFile
    path: root.historyPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.apply(text())
    onLoadFailed: root.ready = false
  }

  function fault(message) {
    root.lastError = message
    root.collectorBroken = true
  }

  function num(v) {
    var n = Number(v)
    return isFinite(n) ? n : 0
  }

  function apply(content) {
    var parsed
    try {
      parsed = JSON.parse(String(content || ""))
    } catch (e) {
      fault("Unreadable history file")
      return
    }
    // The whole snapshot is validated before a single property changes. A
    // bucket array containing null used to pass, clear the fault, and then
    // throw inside the first binding that read the newest bucket.
    if (!parsed || !Array.isArray(parsed.buckets) || parsed.buckets.length === 0) {
      fault("History file has no buckets")
      return
    }
    for (var i = 0; i < parsed.buckets.length; i++) {
      var bk = parsed.buckets[i]
      if (!bk || typeof bk !== "object" || !isFinite(Number(bk.t))
          || !isFinite(Number(bk.claude)) || !isFinite(Number(bk.codex))
          || (bk.grok !== undefined && bk.grok !== null && !isFinite(Number(bk.grok)))) {
        fault("History file has a malformed bucket")
        return
      }
    }
    var c = parsed.claude
    var x = parsed.codex
    var g = parsed.grok && typeof parsed.grok === "object" ? parsed.grok : ({})
    if (!c || typeof c !== "object" || !x || typeof x !== "object") {
      fault("History file is missing an agent")
      return
    }

    try {
      root.buckets = parsed.buckets
      root.generatedAt = num(parsed.generatedAt)
      root.bucketMinutes = num(parsed.bucketMinutes) > 0 ? num(parsed.bucketMinutes) : 15
      root.claudeTotal = num(c.total)
      root.codexTotal = num(x.total)
      root.claudePeak = num(c.peak)
      root.codexPeak = num(x.peak)
      root.claudeSessions = num(c.sessions)
      root.codexSessions = num(x.sessions)
      root.claudeLimits = Array.isArray(c.limits) ? c.limits : []
      root.codexLimits = Array.isArray(x.limits) ? x.limits : []
      root.claudeLimitsMeasuredAt = num(c.limitsMeasuredAt)
      root.codexLimitsMeasuredAt = num(x.limitsMeasuredAt)
      root.claudeLimitsLive = c.limitsLive !== false
      root.codexLimitsLive = x.limitsLive !== false
      root.claudeLimitsStatus = String(c.limitsStatus || "")
      root.claudeLimitsHelp = String(c.limitsHelp || "")
      root.codexLimitsStatus = String(x.limitsStatus || "")
      root.codexLimitsHelp = String(x.limitsHelp || "")
      root.claudeByModel = c.byModel && typeof c.byModel === "object" ? c.byModel : ({})
      root.claudeSplit = c.split && typeof c.split === "object" ? c.split : ({})
      root.codexSplit = x.split && typeof x.split === "object" ? x.split : ({})
      root.codexByModel = x.byModel && typeof x.byModel === "object" ? x.byModel : ({})
      root.claudeTurns = num(c.turns)
      root.codexTurns = num(x.turns)
      root.claudeFirstAt = num(c.firstAt)
      root.claudeLastAt = num(c.lastAt)
      root.codexFirstAt = num(x.firstAt)
      root.codexLastAt = num(x.lastAt)
      root.claudePeakAt = num(c.peakAt)
      root.codexPeakAt = num(x.peakAt)
      root.claudeTrailing5 = num(c.trailing ? c.trailing.m5 : 0)
      root.claudeTrailing60 = num(c.trailing ? c.trailing.m60 : 0)
      root.codexTrailing5 = num(x.trailing ? x.trailing.m5 : 0)
      root.codexTrailing60 = num(x.trailing ? x.trailing.m60 : 0)
      root.grokTotal = num(g.total)
      root.grokPeak = num(g.peak)
      root.grokSessions = num(g.sessions)
      root.grokLimits = Array.isArray(g.limits) ? g.limits : []
      root.grokLimitsMeasuredAt = num(g.limitsMeasuredAt)
      root.grokLastWriteAt = num(g.lastWriteAt)
      root.grokLimitsLive = g.limitsLive === true
      root.grokLimitsStatus = String(g.limitsStatus || "")
      root.grokLimitsHelp = String(g.limitsHelp || "")
      root.grokByModel = g.byModel && typeof g.byModel === "object" ? g.byModel : ({})
      root.grokSplit = g.split && typeof g.split === "object" ? g.split : ({})
      root.grokTurns = num(g.turns)
      root.grokFirstAt = num(g.firstAt)
      root.grokLastAt = num(g.lastAt)
      root.grokPeakAt = num(g.peakAt)
      root.grokTrailing5 = num(g.trailing ? g.trailing.m5 : 0)
      root.grokTrailing60 = num(g.trailing ? g.trailing.m60 : 0)
      var km = parsed.kimi && typeof parsed.kimi === "object" ? parsed.kimi : ({})
      root.kimiTotal = num(km.total)
      root.kimiPeak = num(km.peak)
      root.kimiSessions = num(km.sessions)
      root.kimiLimits = Array.isArray(km.limits) ? km.limits : []
      root.kimiLimitsMeasuredAt = num(km.limitsMeasuredAt)
      root.kimiLimitsLive = km.limitsLive !== false
      root.kimiLimitsStatus = String(km.limitsStatus || "")
      root.kimiLimitsHelp = String(km.limitsHelp || "")
      root.kimiPlanTier = String(km.planTier || "")
      root.kimiLimitsInfo = km.limitsInfo === true
      root.kimiByModel = km.byModel && typeof km.byModel === "object" ? km.byModel : ({})
      root.kimiSplit = km.split && typeof km.split === "object" ? km.split : ({})
      root.kimiTurns = num(km.turns)
      root.kimiFirstAt = num(km.firstAt)
      root.kimiLastAt = num(km.lastAt)
      root.kimiPeakAt = num(km.peakAt)
      root.kimiTrailing5 = num(km.trailing ? km.trailing.m5 : 0)
      root.kimiTrailing60 = num(km.trailing ? km.trailing.m60 : 0)
      var zc = parsed.zcode && typeof parsed.zcode === "object" ? parsed.zcode : ({})
      root.zcodeTotal = num(zc.total)
      root.zcodePeak = num(zc.peak)
      root.zcodeSessions = num(zc.sessions)
      root.zcodeLimitsMeasuredAt = num(zc.limitsMeasuredAt)
      root.zcodeLimitsLive = zc.limitsLive === true
      root.zcodeByModel = zc.byModel && typeof zc.byModel === "object" ? zc.byModel : ({})
      root.zcodeSplit = zc.split && typeof zc.split === "object" ? zc.split : ({})
      root.zcodeTurns = num(zc.turns)
      root.zcodeFirstAt = num(zc.firstAt)
      root.zcodeLastAt = num(zc.lastAt)
      root.zcodePeakAt = num(zc.peakAt)
      root.zcodeTrailing5 = num(zc.trailing ? zc.trailing.m5 : 0)
      root.zcodeTrailing60 = num(zc.trailing ? zc.trailing.m60 : 0)
      var l = parsed.local && typeof parsed.local === "object" ? parsed.local : null
      root.localTokensAvailable = !!l && l.available === true
      root.localTokensReason = l ? String(l.reason || "") : "collector predates local token counting"
      root.localTokensTotal = l ? num(l.total) : 0
      root.localTokensTurns = l ? num(l.turns) : 0
      root.localTokensPeak = l ? num(l.peak) : 0
      root.localTokensPeakAt = l ? num(l.peakAt) : 0
      root.localTokensLastAt = l ? num(l.lastAt) : 0
      root.localTokensTrailing5 = l && l.trailing ? num(l.trailing.m5) : 0
      root.localTokensTrailing60 = l && l.trailing ? num(l.trailing.m60) : 0
      root.localTokensSplit = l && l.split && typeof l.split === "object" ? l.split : ({})
      root.localTokensByModel = l && l.byModel && typeof l.byModel === "object" ? l.byModel : ({})
      root.offloadShare = Math.max(0, Math.min(1, num(parsed.offloadShare)))
      var presence = parsed.presence && typeof parsed.presence === "object" ? parsed.presence : null
      if (presence) {
        root.claudePresent = presence.claude === true
        root.codexPresent = presence.codex === true
        root.grokPresent = presence.grok === true
        // Absent in history written before Kimi existed: stay off rather than
        // inventing a lane this machine has never used.
        root.kimiPresent = presence.kimi === true
        root.zcodePresent = presence.zcode === true
      } else {
        // History written before presence existed: keep the old always-on lanes.
        root.claudePresent = true
        root.codexPresent = true
        root.grokPresent = true
        root.kimiPresent = false
        root.zcodePresent = false
      }
      if (!root.limitsEverTried && (root.claudePresent || root.codexPresent))
        root.refreshLimits()
    } catch (e) {
      fault("History file could not be applied")
      return
    }
    root.ready = true
    if (root.lastCollectOk) {
      root.lastError = ""
      root.collectorBroken = false
    }

    // Fire an impact pulse only when the live bucket actually grew, so a
    // no-op refresh does not make the widget twitch. On a bucket rollover the
    // live value resets toward zero, so compare against 0 for the new bucket
    // instead of the previous bucket's total, otherwise the first burn of
    // every bucket is silently swallowed.
    var latestT = root.buckets.length ? Number(root.buckets[root.buckets.length - 1].t || 0) : 0
    var rolled = latestT !== root.lastBucketT
    if (rolled) {
      root.lastClaudeLatest = 0
      root.lastCodexLatest = 0
      root.lastGrokLatest = 0
      root.lastKimiLatest = 0
      root.lastZcodeLatest = 0
      root.lastBucketT = latestT
    }
    if (root.claudeLatest > root.lastClaudeLatest) root.claudePulse++
    if (root.codexLatest > root.lastCodexLatest) root.codexPulse++
    if (root.grokLatest > root.lastGrokLatest) root.grokPulse++
    if (root.kimiLatest > root.lastKimiLatest) root.kimiPulse++
    if (root.zcodeLatest > root.lastZcodeLatest) root.zcodePulse++
    root.lastClaudeLatest = root.claudeLatest
    root.lastCodexLatest = root.codexLatest
    root.lastGrokLatest = root.grokLatest
    root.lastKimiLatest = root.kimiLatest
    root.lastZcodeLatest = root.zcodeLatest
  }

  Timer {
    interval: root.intervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.collect()
  }

  // ── plan-limit refresh ─────────────────────────────────────────────────────
  // burnbar-collect only copies limits out of the records that
  // omarchy-agent-usage-update maintains; this is what keeps those records
  // fresh. --limits-only reuses any transcript scan under 15 minutes old and
  // the Claude collector keeps a 15s probe cache, so repeated asks are cheap.
  // Claude and Codex via Omarchy collectors; Grok limits are parsed from
  // ~/.grok/logs/unified.jsonl inside burnbar-collect (no stock grok probe).
  property bool limitsRefreshUnavailable: false
  property bool limitsEverTried: false
  function refreshLimits() {
    if (limitsRefresher.running || limitsRefreshUnavailable) return
    var agents = []
    if (root.claudePresent) agents.push("claude")
    if (root.codexPresent) agents.push("codex")
    if (agents.length === 0) {
      if (root.ready) return
      agents.push("claude")
      agents.push("codex")
    }
    root.limitsEverTried = true
    limitsRefresher.launched = false
    limitsRefresher.command = ["bash", "-c",
      "setsid omarchy-agent-usage-update --limits-only " + agents.join(" ") + " & p=$!; "
      + "trap 'kill -TERM -- -$p 2>/dev/null; exit 143' TERM INT; wait $p"]
    limitsRefresher.running = true
    limitsWatchdog.restart()
  }

  Process {
    id: limitsRefresher
    property bool launched: false
    // The updater backgrounds one subshell per collector and waits on them, so
    // a SIGTERM to the updater alone would orphan the actual probes. setsid
    // gives the updater its own process group and the trap tears that whole
    // group down; a missing updater still surfaces as exit 127 through wait.
    onStarted: launched = true
    onRunningChanged: {
      if (running || launched) return
      // bash itself could not start. Nothing sane is left to try this session.
      limitsWatchdog.stop()
      root.limitsRefreshUnavailable = true
      console.warn("burnbar: could not start the plan-limit refresh; limits will not refresh")
    }
    stderr: SplitParser {
      onRead: data => { var s = String(data).trim(); if (s !== "") console.warn("burnbar: " + s) }
    }
    onExited: function(code) {
      limitsWatchdog.stop()
      if (code === 127) {
        // Not an Omarchy box, or its bin dir is off PATH. Stop asking; the
        // panel shows the record's age instead of a retry every cycle.
        root.limitsRefreshUnavailable = true
        console.warn("burnbar: omarchy-agent-usage-update not found; plan limits will not refresh")
        return
      }
      // Whatever it wrote, fold the records into history.json now rather
      // than on the next collector tick.
      root.collect()
    }
  }

  Timer {
    id: limitsWatchdog
    interval: 60000
    repeat: false
    onTriggered: {
      if (limitsRefresher.running) {
        console.warn("burnbar: usage-update exceeded 60s, killing")
        limitsRefresher.signal(15)
      }
    }
  }

  Timer {
    interval: root.limitsRefreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshLimits()
  }

  // ── local runner probe ─────────────────────────────────────────────────────
  // burnbar-local-status holds an ssh session open ~200ms sampling the box's
  // CPU ticks, so it must never be re-entered; the running guard is
  // load-bearing, not defensive. A GPU-less machine never starts it.
  function pollLocal() {
    if (!root.hasComputeGpu) return
    if (localProbe.running) return
    localProbe.launched = false
    localProbe.running = true
    localWatchdog.restart()
  }

  function discoverGpu() {
    if (gpuDiscover.running) return
    gpuDiscover.launched = false
    gpuDiscover.command = ["python3", root.localStatusPath, "--discover",
      "--url", root.ollamaUrl, "--host", root.localHost]
    gpuDiscover.running = true
  }

  function applyGpuDiscover(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") throw new Error("not an object")
    } catch (e) {
      root.hasComputeGpu = false
      root.hasComputeGpuChecked = true
      root.computeGpuReason = "Unreadable GPU discovery"
      return
    }
    root.hasComputeGpu = data.hasGpu === true
    root.computeGpuReason = String(data.reason || (root.hasComputeGpu ? "" : "no discrete GPU")).slice(0, 240)
    if (data.gpuName) root.localGpuName = String(data.gpuName).slice(0, 64)
    if (data.backend) root.localBackend = String(data.backend).slice(0, 32)
    root.hasComputeGpuChecked = true
    if (!root.hasComputeGpu) {
      root.clearLocalTelemetry(root.computeGpuReason)
      root.localReady = true
    } else {
      root.pollLocal()
      root.collect()
    }
  }

  Process {
    id: gpuDiscover
    property bool launched: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGpuDiscover(text)
    }
    onStarted: launched = true
    onRunningChanged: {
      if (running || launched) return
      root.hasComputeGpu = false
      root.hasComputeGpuChecked = true
      root.computeGpuReason = "python3 not found"
    }
    onExited: function(code) {
      if (code !== 0 && !root.hasComputeGpuChecked) {
        root.hasComputeGpu = false
        root.hasComputeGpuChecked = true
        root.computeGpuReason = "GPU discovery exited " + code
      }
    }
  }

  // A failed sample invalidates every current reading. Leaving yesterday's
  // 70% GPU and a resident model on screen under an OFFLINE header is a lie
  // with a footnote. The traces keep their history; the peaks are peaks.
  function clearLocalTelemetry(reason) {
    root.localOnline = false
    root.localActive = false
    root.localLoad = 0
    root.localCpu = 0
    root.localGpu = 0
    root.localModelCount = 0
    root.localModel = ""
    root.localBackend = "none"
    root.localModels = []
    root.localModelDetails = []
    root.localError = String(reason || "").slice(0, 240)
    root.localVersion = ""
    root.localGpuName = ""
    root.localPowerW = 0
    root.localPowerLimitW = 0
    root.localTempC = 0
    root.localVramUsedMb = 0
    root.localVramTotalMb = 0
    root.localVramModelsMb = 0
    root.localClockMhz = 0
    root.localClockMaxMhz = 0
    root.localFanPct = 0
    root.localGpuRailW = 0
    root.localTelemetryError = ""
    root.localHostName = ""
    root.localSampledAt = Date.now()
    root.pushLocalSample(0)
  }

  function applyLocal(raw) {
    var data
    try {
      data = JSON.parse(String(raw || ""))
      if (!data || typeof data !== "object") throw new Error("not an object")
    } catch (e) {
      root.clearLocalTelemetry("Unreadable local status")
      return
    }

    root.localOnline = data.online === true
    root.localLoad = Math.max(0, Math.min(100, Number(data.load || 0)))
    root.localCpu = Math.max(0, Math.min(100, Number(data.cpu || 0)))
    root.localGpu = Math.max(0, Math.min(100, Number(data.gpu || 0)))
    root.localModelCount = Number(data.modelCount || 0)
    // No resident model, no inference, whatever else is using the GPU.
    root.localActive = root.localOnline && root.localModelCount > 0
      && (data.active === true || root.localLoad >= root.localThreshold)
    root.localModel = String(data.model || "").slice(0, 128)
    root.localBackend = String(data.backend || "none").slice(0, 32)
    root.localModels = Array.isArray(data.models) ? data.models : []
    root.localModelDetails = Array.isArray(data.modelDetails) ? data.modelDetails : []
    root.localError = String(data.error || "").slice(0, 240)
    root.localVersion = String(data.version || "").slice(0, 32)
    root.localGpuName = String(data.gpuName || "").slice(0, 64)
    root.localPowerW = Math.max(0, Number(data.powerW || 0))
    root.localPowerLimitW = Math.max(0, Number(data.powerLimitW || 0))
    root.localTempC = Math.max(0, Number(data.tempC || 0))
    root.localVramUsedMb = Math.max(0, Number(data.vramUsedMb || 0))
    root.localVramTotalMb = Math.max(0, Number(data.vramTotalMb || 0))
    root.localVramModelsMb = Math.max(0, Number(data.vramModelsMb || 0))
    root.localClockMhz = Math.max(0, Number(data.clockMhz || 0))
    root.localClockMaxMhz = Math.max(0, Number(data.clockMaxMhz || 0))
    root.localFanPct = Math.max(0, Number(data.fanPct || 0))
    root.localGpuRailW = Math.max(0, Number(data.gpuRailW || 0))
    root.localTelemetryError = String(data.telemetryError || "").slice(0, 240)
    root.localHostName = String(data.host || "").slice(0, 128)
    if (data.hasGpu === false) {
      root.hasComputeGpu = false
      root.computeGpuReason = String(data.error || data.reason || "no discrete GPU").slice(0, 240)
    } else if (data.hasGpu === true) {
      root.hasComputeGpu = true
    }
    root.hasComputeGpuChecked = true
    root.localReady = true
    root.localSampledAt = Date.now()
    root.pushLocalSample(root.localOnline ? root.localLoad : 0)
  }

  // Newest sample lands at index 0; the widget draws local time flowing
  // rightward away from the core, mirroring how Codex reads.
  function pushLocalSample(value) {
    var ring = root.localHistory.slice(0, Math.max(0, root.localCells - 1))
    ring.unshift(Number(value) || 0)
    var previous = root.localHistory.length ? Number(root.localHistory[0]) : 0
    root.localHistory = ring
    var power = root.localPowerHistory.slice(0, Math.max(0, root.localCells - 1))
    power.unshift(root.localOnline ? root.localPowerW : 0)
    root.localPowerHistory = power
    var when = root.localTimeHistory.slice(0, Math.max(0, root.localCells - 1))
    when.unshift(Date.now())
    root.localTimeHistory = when
    root.localPeakLoad = Math.max(root.localPeakLoad, Number(value) || 0)
    root.localPeakPowerW = Math.max(root.localPeakPowerW, root.localPowerW)
    // A pulse means the runner just got busier, not merely that it is busy,
    // otherwise a steady 90% load would strobe the widget forever.
    if (value > previous + 2 && value >= root.localThreshold) root.localPulse++
  }

  Process {
    id: localProbe
    property bool launched: false
    command: ["python3", root.localStatusPath, "--threshold", String(root.localThreshold),
      "--url", root.ollamaUrl, "--host", root.localHost]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyLocal(text)
    }
    onStarted: launched = true
    onRunningChanged: {
      if (running || launched) return
      localWatchdog.stop()
      root.clearLocalTelemetry("python3 not found")
    }
    onExited: function(code) {
      localWatchdog.stop()
      if (code !== 0) root.clearLocalTelemetry("local probe exited " + code)
    }
  }

  // The probe's HTTP and ssh timeouts bound each blocking call, not the whole
  // run; a trickling endpoint could hold it open forever, and pollLocal()
  // refuses to start a second one. The probe normally takes ~1.3 s: one HTTP
  // call and one ssh round trip to the box.
  Timer {
    id: localWatchdog
    interval: 15000
    repeat: false
    onTriggered: {
      if (localProbe.running) {
        localProbe.signal(15)
        root.clearLocalTelemetry("local probe timed out")
      }
    }
  }

  Timer {
    interval: root.localRefreshMs
    running: root.hasComputeGpu
    repeat: true
    triggeredOnStart: true
    onTriggered: root.pollLocal()
  }

  // Retry discovery slowly so plugging in a GPU can light the lane
  // without a 2.5s poll on a box that has none.
  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.discoverGpu()
  }
}
