import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Burn Bar: one live thermal instrument for every model this machine runs.
//
//   CLAUDE ◄── time ──┤ now ├── time ──► CODEX  │  GROK ──►  ║  GPU ──► seconds
//
// Lanes appear only for agents this machine actually uses. Claude burns on
// the left and Codex on the right, both with their newest bucket against the
// shared centre line, so the divider is always "now". Grok (Grok Build / CLI
// under ~/.grok) rides after Codex when it is present, or takes a side of
// the pair when Codex is not. Local intelligence, Ollama on a compute GPU,
// stays bolted on the right behind a hard rule, and is omitted entirely when
// no NVIDIA / AMD / Jetson GPU is detected. Intel iGPU does not count.
//
// This is a heat map first: COLOUR carries the magnitude, on a per-agent ramp
// that runs cold ember → agent identity → amber → white-hot. Height is only a
// secondary swell (72%→100%) so the strip has a living profile instead of
// reading as a flat gradient bar. Cells are centred vertically, which makes it
// a glowing core rather than bars standing on a floor.
//
// Motion is data, never decoration:
//   · ember flicker      scales with a cell's own heat, cold coals sit still
//   · impact shockwave   fires outward from the now line when new burn lands
//   · rising sparks      density and speed follow total energy across all three
//   · idle drift         a slow travelling swell, so calm never looks broken
//   · fault              hard red, no idle animation, so an outage cannot hide
BarWidget {
  id: root
  moduleName: "nixfred.burnbar"

  property var anchorItem: button

  readonly property var svc: bar && bar.shell ? bar.shell.serviceFor(moduleName) : null
  readonly property bool ready: svc ? svc.ready : false
  readonly property var buckets: svc ? svc.buckets : []

  function boundedInt(name, fallback, low, high) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(low, Math.min(high, n))
  }
  // One clamp, the service's, so the strip can never draw a different
  // number of cells than the collector made buckets (bars: 0 used to read as
  // 12 here and 6 there). The fallback only matters before the service binds.
  // `bars` is the FLOOR for granularity, not the whole story. A strip
  // stretched across an ultrawide has room for far more, finer cells, and a
  // lane of twelve 33px blocks reads as a bar chart rather than a heat map.
  readonly property int baseBars: boundedInt("bars", 12, 6, 240)
  // `bars` is what the strip asks for, not what it insists on. On a crowded bar
  // it sheds cells down to this before it asks any neighbour for room: a
  // shorter window is a smaller loss than a lane that will not fit. The strip
  // is the glance; the cockpit still holds the whole window either way.
  readonly property int minBars: 6
  readonly property int cellCount: svc ? svc.bucketCount : baseBars
  // One cell plus its gap. Below this the lane smears; above it, it blocks up.
  readonly property real cellPitch: Math.max(2, Style.spaceReal(6))
  // Quantised to 4 so a pixel of drift does not re-run the collector. Reads
  // lane width, never cellCount, so this cannot feed back into itself.
  readonly property int adaptiveCells: {
    var lane = graph ? graph.sideWidth : 0
    if (!isFinite(lane) || lane <= 0) return baseBars
    var want = Math.round(Math.round(lane / cellPitch) / 4) * 4
    return Math.max(minBars, Math.min(240, want))
  }
  onAdaptiveCellsChanged: pushBuckets()
  function pushBuckets() {
    if (svc && svc.requestedBuckets !== undefined && svc.requestedBuckets !== adaptiveCells)
      svc.requestedBuckets = adaptiveCells
  }
  readonly property int localCells: svc ? svc.localCells : boundedInt("localCells", 9, 4, 20)
  // Presence comes from the collector. Until the first snapshot lands the
  // strip stays empty rather than inventing Claude/Codex/Grok lanes that
  // this machine may not use.
  readonly property bool showClaude: (svc ? svc.claudePresent : false) && focusOk("claude")
  readonly property bool showCodex: (svc ? svc.codexPresent : false) && focusOk("codex")
  readonly property bool showGrok: (svc ? svc.grokPresent : false) && focusOk("grok")
  readonly property int cloudAgents: (showClaude ? 1 : 0) + (showCodex ? 1 : 0) + (showGrok ? 1 : 0) + (showKimi ? 1 : 0)
  readonly property bool grokExtra: showGrok && showClaude && showCodex
  readonly property bool grokAsRight: showGrok && showClaude && !showCodex
  readonly property bool grokAsLeft: showGrok && !showClaude && showCodex
  // Kimi Code has no transcript store of its own: it rides in Claude's, and the
  // model id is the only thing that separates them. The lane stays hidden until
  // a Kimi-model turn actually appears, so a machine that has never run it sees
  // no change at all. It sits beside Grok as a second narrow band.
  readonly property bool showKimi: (svc ? svc.kimiPresent : false) && focusOk("kimi")
  readonly property bool kimiExtra: showKimi && showClaude && showCodex
  // The narrowest strip that still gives every cell a whole pixel and a gap.
  // A configured width below it is raised rather than honoured: overlapping
  // cells are a heat map of nothing.
  readonly property int minWidthForCells: {
    var n = Math.max(1, cloudAgents)
    // minBars, not cellCount: cellCount is derived from the width this number
    // helps decide, and reading it here would close the loop. It is minBars
    // rather than baseBars because this is the floor, the narrowest the strip
    // can be drawn, not the width it would like. Using baseBars held 136px on a
    // crowded bar and refused to yield the last 26 of them, which is the whole
    // complaint: it should shed cells before it hoards width.
    var cloudNeed = (2 * n * minBars + 3 + (showGauges ? 6 * n : 0) + (showLocal ? 4 : 0)) / (showLocal ? 0.75 : 1)
    var localNeed = showLocal ? (2 * localCells + 6) * 4 : 0
    return Math.max(110, Math.ceil(Math.max(cloudNeed, localNeed)) + 6)
  }
  // What the strip would LIKE: `bars` cells at a readable pitch plus the
  // furniture. minWidthForCells is what it can survive on. The gap between the
  // two is the space it is willing to hand back when the bar is busy.
  readonly property int comfortWidth: {
    var n = Math.max(1, cloudAgents)
    var cloudNeed = (2 * n * baseBars + 3 + (showGauges ? 6 * n : 0) + (showLocal ? 4 : 0)) / (showLocal ? 0.75 : 1)
    var localNeed = showLocal ? (2 * localCells + 6) * 4 : 0
    return Math.max(minWidthForCells, Math.ceil(Math.max(cloudNeed, localNeed)) + 6)
  }
  readonly property int configuredWidth: Math.max(minWidthForCells, boundedInt("width", 150, 110, 400))
  readonly property bool showGauges: setting("showGauges", true) !== false
  // Local settings stay in the plugin schema so a GPU box can be pointed at,
  // but the lane itself only appears when a compute GPU was actually found.
  readonly property bool showLocal: setting("showLocal", true) !== false && (svc ? svc.hasComputeGpu : false) && focusOk("local")
  readonly property bool emberFlicker: setting("emberFlicker", true) !== false
  readonly property bool sparks: setting("sparks", true) !== false

  // ── elastic width ─────────────────────────────────────────────────────────
  // The bar's sections do not negotiate: each is a Row pinned to its own edge
  // (or, for the centre, hung off the anchor module) and nothing hands out the
  // room left between them. So the strip claims it by hand, the way beatdeck
  // does on the left: measure where the neighbouring section begins, subtract
  // what the siblings in our own row still need, and take the rest. `width` is
  // the floor: the narrowest the strip will go, and its fixed size with the
  // fill turned off, and `maxWidth` the ceiling.
  //
  // Loop-safe because no input depends on our own width. Which edge of ours
  // is fixed depends on where the widget sits:
  //   · left row, or centre row after the anchor    → our LEFT edge is pinned
  //     by the siblings before us; we grow rightward to the next section.
  //   · right row, or centre row before the anchor  → our RIGHT edge is pinned
  //     (the row hangs from the right); we grow leftward.
  //   · centre row with no anchor                   → the whole row is centred;
  //     it can grow until either end meets a neighbouring section.
  //   · we are the anchor                           → we sit on the centre line
  //     and grow both ways, bounded by the tighter side.
  // Siblings in our own row are measured by implicitWidth, never by position:
  // their x moves when we grow, the space they need does not.
  // Fred, 2026-09-20: "Remove its variable size. I like the size of it right
  // now. Use that going forward." A strip that changes width with the bar's
  // mood is hard to read and hard to find; it is a fixed instrument now.
  // Filling the room is still available, it is simply no longer the default.
  readonly property bool stretch: setting("stretch", false) === true
  readonly property int maxWidth: Math.max(configuredWidth, boundedInt("maxWidth", 2400, 110, 4000))
  readonly property int stretchGap: boundedInt("stretchGap", 14, 0, 200)

  // Fred, 2026-09-18: "have a max space it can take ... per claude / codex /
  // grok / local and can shrink if needed." The ceiling is a PHYSICAL allowance
  // per visible lane, so the strip covers the same span of desk on a 27" 4K and
  // on a 49" ultrawide instead of ballooning with the pixel count. Tenths of an
  // inch because plugin settings carry integers. `maxWidth` still applies as the
  // absolute ceiling, and the floor always wins: a cap must never squeeze the
  // strip below what its least detailed layout needs.
  readonly property int maxPerLaneTenths: boundedInt("maxPerLane", 10, 2, 40)
  readonly property int laneCount: Math.max(1, cloudAgents + (showLocal ? 1 : 0))

  // Style units -> device pixels, sampled over 100 so rounding cannot land on 0.
  readonly property real styleScale: Math.max(0.01, Style.spaceReal(100) / 100)

  // What a stretching neighbour needs to know about us: the floor we will not
  // go under, and the ceiling we will not grow past. Burn Bar has always read
  // these two off Beatdeck; publishing them is what lets the partner take the
  // room this cap makes us refuse instead of leaving the gap blank.
  readonly property int stretchMinWidth: minWidthForCells
  readonly property int stretchMaxWidth: {
    var cap = laneCapPx(laneCount, maxPerLaneTenths, pixelsPerInch())
    if (!isFinite(cap)) return maxWidth
    return Math.max(minWidthForCells, Math.min(maxWidth, Math.round(cap / styleScale)))
  }

  // Device pixels. Seeded at the preferred width; measureStretch then
  // replaces it with a fair share of the hole to the centre section.
  readonly property real preferredWidth: Style.spaceReal(configuredWidth)
  property real stretchedWidth: preferredWidth
  readonly property real stripWidth: stretch && !vertical
    ? Math.max(0, stretchedWidth)
    : preferredWidth

  implicitWidth: vertical ? barSize : stripWidth
  implicitHeight: vertical ? Style.spaceReal(configuredWidth) : barSize
  // Bloom/glow is drawn larger than the slot; clip so it cannot paint
  // through the temperature and clock in the next section.
  clip: true

  function sameModule(a, b) {
    var x = String(a || ""), y = String(b || "")
    if (bar && typeof bar.canonicalWidgetId === "function") {
      x = String(bar.canonicalWidgetId(x) || x)
      y = String(bar.canonicalWidgetId(y) || y)
    }
    return x !== "" && x === y
  }

  function slotStretches(item) {
    // Now Playing (beatdeck) exposes `stretch` and `stretchedWidth`. Either
    // means it is filling the same hole we are; we split with it.
    if (!item || item === root) return false
    if (item.vertical === true) return false
    if (item.stretch === false) return false
    if (item.stretch === true) return true
    return typeof item.stretchedWidth === "number"
  }

  // What a partner will actually take. Beatdeck publishes `stretchMaxWidth`
  // and drops it to its minimum when nothing is playing; treating that as a
  // fair half would leave the gap it gave up sitting empty.
  function slotCap(item) {
    var n = Number(item && item.stretchMaxWidth)
    return isFinite(n) && n > 0 ? Style.spaceReal(n) : Infinity
  }

  function slotMinWidth(item) {
    var n = Number(item && item.stretchMinWidth)
    if (isFinite(n) && n > 0) return n
    n = Number(item && item.configuredWidth)
    if (isFinite(n) && n > 0) return n
    return 96
  }

  // Device pixels per inch for the screen this instance is on. EDID lies: a
  // monitor that reports no physical size at all lands at an absurd density, so
  // anything outside 50..300 dpi is refused and the logical density is used.
  function pixelsPerInch() {
    var w = QsWindow.window
    var s = w && w.screen ? w.screen : null
    var dpi = s && Number(s.physicalPixelDensity) > 0 ? Number(s.physicalPixelDensity) * 25.4 : 0
    if (!(dpi >= 50 && dpi <= 300)) {
      var r = s && Number(s.devicePixelRatio) > 0 ? Number(s.devicePixelRatio) : 1
      dpi = 96 * r
    }
    return dpi
  }

  // The ceiling in device pixels: one allowance per visible lane. Infinity when
  // the density is unusable, which means "no physical cap", not "zero width".
  function laneCapPx(lanes, tenths, dpi) {
    var n = Math.max(1, Math.floor(Number(lanes) || 0))
    var t = Math.max(1, Number(tenths) || 0)
    var d = Number(dpi)
    if (!isFinite(d) || d <= 0) return Infinity
    return n * (t / 10) * d
  }

  function measureStretch() {
    if (!stretch || vertical || !bar || !Array.isArray(bar.moduleSlots)) return

    var maximum = Style.spaceReal(maxWidth)
    // The per-lane physical cap, never below the floor: the strip may shrink to
    // what it needs, but a cap that starved it would be worse than no cap.
    var laneCap = laneCapPx(laneCount, maxPerLaneTenths, pixelsPerInch())
    if (isFinite(laneCap)) maximum = Math.max(Style.spaceReal(minWidthForCells), Math.min(maximum, laneCap))
    var gap = Style.spaceReal(stretchGap)
    var ourMin = Math.max(80, minWidthForCells)
    var origin
    try {
      origin = mapToItem(null, 0, 0)
    } catch (e) {
      return
    }
    if (!origin) return

    // Centre bound is screen x, not implicitWidth: weather has painted at
    // 68px with an implicitWidth of 0. Hidden indicators sit on the same x.
    var centreLeft = -1
    var trailing = 0
    var partnerX = -1
    var partnerMin = 0
    var partnerCap = Infinity
    var nPartners = 0

    for (var i = 0; i < bar.moduleSlots.length; i++) {
      var slot = bar.moduleSlots[i]
      if (!slot || !slot.activeItem) continue
      if (slot.activeItem === root) continue

      var point
      try {
        point = slot.mapToItem(null, 0, 0)
      } catch (e2) {
        continue
      }
      if (!point) continue

      if (slot.region === "center") {
        if (point.x + 1 < origin.x) continue
        if (centreLeft < 0 || point.x < centreLeft) centreLeft = point.x
      } else if (slot.region === "left") {
        if (point.x > origin.x && slot.activeItem.visible)
          trailing += Math.max(0, Number(slot.implicitWidth) || 0)
        else if (point.x < origin.x) {
          var name = String(slot.moduleName || "")
          var peer = slotStretches(slot.activeItem)
            || name.indexOf("beatdeck") >= 0
            || name.indexOf("nowplaying") >= 0
            || name.indexOf("now-playing") >= 0
          if (!peer) continue
          // Immediate predecessor that also fills: share from ITS left
          // edge (stable) not from our x (which it controls).
          if (point.x >= partnerX) {
            nPartners = 1
            partnerX = point.x
            partnerMin = slotMinWidth(slot.activeItem)
            partnerCap = slotCap(slot.activeItem)
          }
        }
      }
    }

    var boundary = centreLeft
    if (boundary < 0) {
      var barPoint
      try {
        barPoint = bar.mapToItem(null, 0, 0)
      } catch (e3) {
        return
      }
      if (!barPoint) return
      boundary = barPoint.x + bar.width
    }

    var holeStart = partnerX >= 0 ? partnerX : origin.x
    var hole = boundary - holeStart - trailing - gap
    var next
    if (partnerX >= 0 && nPartners > 0) {
      // Split the hole with the preceding stretcher (Now Playing).
      // Beatdeck sizes itself as (hole - our implicitWidth), so reporting
      // the fair share here is what makes the two converge instead of
      // one eating the other. Independent of our current x/width.
      var n = nPartners + 1
      var extra = hole - ourMin - partnerMin
      if (extra < 0)
        next = hole * ourMin / Math.max(1, ourMin + partnerMin)
      else if (hole < Style.spaceReal(comfortWidth) + partnerMin) {
        // Crowded: the gap cannot seat this strip comfortably AND the partner,
        // so stop bidding for it. Drop to the floor and let the neighbour have
        // the rest. Splitting the leftover down the middle is only fair when
        // there is enough of it to make both of us usable; below that it is
        // just hoarding, and a shorter window costs less than a cramped bar.
        next = ourMin
      } else {
        next = ourMin + extra / n
        // The partner has capped itself under its share; it is yielding.
        // Take the room it will not use rather than leaving it blank.
        if (partnerCap < Infinity && partnerCap < hole - next)
          next = hole - partnerCap
      }
      next = Math.min(next, hole - partnerMin)
    } else {
      next = hole
    }
    next = Math.round(Math.max(0, Math.min(maximum, next)))
    // First-frame mapToItem can report the bar origin (x≈0, bound≈0) before
    // slots exist; applying that would collapse the strip to 0px.
    if (boundary < origin.x + 24 && partnerX < 0) return
    if (next < 40 && stretchedWidth > 80) return
    if (Math.abs(next - stretchedWidth) >= 1) stretchedWidth = next
  }

  onStretchChanged: measureStretch()
  onConfiguredWidthChanged: measureStretch()
  onMaxWidthChanged: measureStretch()
  onStretchGapChanged: measureStretch()
  onXChanged: measureStretch()
  onBarChanged: measureStretch()
  Component.onCompleted: { measureStretch(); pushBuckets() }

  Connections {
    target: root.bar
    ignoreUnknownSignals: true
    // A plugin added to or removed from any section reassigns moduleSlots.
    function onModuleSlotsChanged() { settleTimer.restart() }
    function onWidthChanged() { settleTimer.restart() }
    function onBarConfigChanged() { settleTimer.restart() }
  }

  // Slots register before they have been laid out, so measure once the frame
  // has settled rather than on the register itself.
  Timer {
    id: settleTimer
    interval: 60
    repeat: false
    onTriggered: root.measureStretch()
  }

  // Safety net for the geometry changes QML gives no signal for: a
  // neighbour's label growing, the tray gaining an icon, a font or scale
  // change mid-session. Cheap next to the ember animation already running.
  Timer {
    interval: 500
    running: root.stretch && !root.vertical && root.visible
    repeat: true
    onTriggered: root.measureStretch()
  }

  // ── zones ─────────────────────────────────────────────────────────────────
  // The widget is three instruments in one slot, so each gets a tinted plate
  // and a coloured baseline in its own identity hue. Hovering a zone names it
  // and reports only that agent; a single blended tooltip made you do the
  // arithmetic of working out which number belonged to which lane.
  readonly property int zoneNone: -1
  readonly property int zoneClaude: 0
  readonly property int zoneCodex: 1
  readonly property int zoneGrok: 2
  readonly property int zoneLocal: 3
  readonly property int zoneKimi: 4

  property int hoverZone: zoneNone
  // The bar only offers a tooltip to a target that reports itself hovered, and
  // our own overlay takes the hover away from WidgetButton's MouseArea, so
  // this widget becomes the tooltip target in its place.
  readonly property bool tooltipHovered: zoneHover.containsMouse && visible

  function zoneAccent(zone) {
    if (zone === zoneCodex) return codexHot
    if (zone === zoneKimi) return kimiHot
    if (zone === zoneGrok) return grokHot
    if (zone === zoneLocal) return showLocal && !localOnline ? urgent : localHot
    return claudeHot
  }

  // A weekly figure the service could not vouch for reads as unknown, with
  // the age of the record behind it, never as a confident 0%.
  function quotaText(percent, updatedAt) {
    if (percent < 0) {
      var t = Number(updatedAt) || 0
      return t > 0 ? "unknown  ·  measured " + Qt.formatTime(new Date(t), "h:mm AP") : "unknown"
    }
    return Math.round(percent * 100) + "%"
  }

  // "6h", "1h40m", "30m", never a window rounded to the nearest hour.
  function windowLabel(minutes) {
    var m = Math.round(Number(minutes) || 0)
    var h = Math.floor(m / 60), r = m % 60
    return h > 0 ? (r > 0 ? h + "h" + r + "m" : h + "h") : m + "m"
  }

  // Guidance under the numbers: where this sub stands, and whether it is the
  // one to reach for. The same words the cockpit uses.
  function adviceLines(id) {
    // Bare: the quota line above this one already says when a snapshot was taken.
    var st = standingText(id, Date.now(), true)
    var g = guidance
    var mark = g && g.count >= 2 && g.pick === id ? "\n▶ the one to use " + (g.urgent ? "now" : "next") : ""
    return (st !== "" ? "\n" + st : "") + mark
  }

  function zoneTooltip(zone) {
    if (!svc) return "Burn Bar: starting up"
    // Before the first history.json is parsed every total is zero, and a
    // confident "0 tokens" while burning is a lie. The plugin withholds
    // unknown quotas for the same reason; a tooltip is no different. This is
    // the state Fred caught seconds after a shell restart, 2026-09-20.
    if (!svc.ready) return "Burn Bar: collecting…"
    if (broken && zone !== zoneLocal)
      return "CLOUD FAULT: " + (svc.lastError || "collector failed")
    var span = windowLabel(svc.windowMinutes || 360)
    if (zone === zoneClaude)
      return "CLAUDE  ·  " + compact(svc.claudeTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.claudeLatest) + " this bucket  ·  " + svc.claudeSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.claudeWeekly, svc.claudeLimitsMeasuredAt)
        + adviceLines("claude")
    if (zone === zoneCodex)
      return "CODEX  ·  " + compact(svc.codexTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.codexLatest) + " this bucket  ·  " + svc.codexSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.codexWeekly, svc.codexLimitsMeasuredAt)
        + adviceLines("codex")
    if (zone === zoneKimi)
      return "KIMI  ·  " + compact(svc.kimiTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.kimiLatest) + " this bucket  ·  " + svc.kimiSessions + " sessions"
        + "\n" + (svc.kimiPlanTier !== "" ? svc.kimiPlanTier + " plan" : "plan unknown")
        + "  ·  monthly quota " + quotaText(svc.kimiMonthly, svc.kimiLimitsMeasuredAt)
        + adviceLines("kimi")
    if (zone === zoneGrok)
      return "GROK  ·  " + compact(svc.grokTotal) + " tokens / last " + span
        + "\nnow " + compact(svc.grokLatest) + " this bucket  ·  " + svc.grokSessions + " sessions"
        + "\nweekly quota " + quotaText(svc.grokWeekly, svc.grokLimitsMeasuredAt)
        + (svc.grokWeekly >= 0 && asOfText("grok") !== "" ? "  ·  " + asOfText("grok") : "")
        + (svc.grokLimitsStatus !== "" ? "\n" + svc.grokLimitsStatus : "")
        + adviceLines("grok")
    if (zone === zoneLocal)
      return svc.localHost.toUpperCase() + "  ·  " + (!svc.localOnline
          ? "Ollama offline" + (svc.localError !== "" ? "\n" + svc.localError : "")
          : (svc.localActive ? "inferencing " : "idle ") + Math.round(svc.localLoad) + "%"
            + "  ·  " + String(svc.localBackend).toUpperCase()
            + "\n" + (svc.localModel !== "" ? svc.localModel : "no model resident")
            + "\n" + svc.localModelCount + " model(s) warm")
        + (svc.localTokensAvailable
            ? "\n" + compact(svc.localTokensTotal) + " tokens / last " + span
              + "  ·  " + Math.round(svc.offloadShare * 100) + "% offloaded from frontier"
            : "")
    return ""
  }

  // Bound, not computed once at zone entry: a tooltip left open while the
  // quota rolls over, a fresh sample lands, or the collector fails has to
  // change under the pointer. showTooltip re-checks tooltipHovered on this
  // widget, so a stale request from a pointer that has already left resolves
  // to nothing.
  readonly property string hoverText: hoverZone === zoneNone ? "" : zoneTooltip(hoverZone)
  onHoverTextChanged: if (hoverZone !== zoneNone && bar) bar.showTooltip(root, hoverText)

  function updateZone(x) {
    var zone = graph.zoneAt(x - graph.x)
    if (zone === hoverZone) return
    hoverZone = zone
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Settings the widget changes itself (which lane the icon shows) go back
  // through the bar, the same way every other inline widget setting does. A
  // third-party bar may hand out a facade with no updateEntryInline, so the
  // change still applies in memory and simply does not outlive the session.
  function persist(values) {
    var entry = { id: moduleName }
    for (var existing in settings) if (existing !== "id") entry[existing] = settings[existing]
    for (var key in values) entry[key] = values[key]
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(moduleName, entry)
  }

  // What the icon is showing: an empty list is every lane, otherwise exactly
  // the subscriptions ticked in the right-click menu. Fred, 2026-09-20: "on
  // right click multi selection possible" - one lane was never the only useful
  // answer; Claude AND Kimi without the rest is.
  readonly property var focusLanes: {
    var raw = String(setting("lanes", "") || "").trim()
    if (raw === "") {
      // A single-lane pick from before multi-select still means what it said.
      var old = String(setting("focus", "") || "").trim()
      return old === "" ? [] : [old]
    }
    var out = []
    var parts = raw.split(",")
    for (var i = 0; i < parts.length; i++) {
      var id = parts[i].trim()
      if (id !== "" && out.indexOf(id) < 0) out.push(id)
    }
    return out
  }
  function focusOk(id) { return focusLanes.length === 0 || focusLanes.indexOf(id) >= 0 }

  // The cockpit's two view choices live with the lanes, because the same right
  // click menu sets all three. "budget" leads each card with how much of the
  // plan is gone and whether it will last; "tokens" leads with raw burn.
  readonly property string heroMode: String(setting("hero", "budget")) === "tokens" ? "tokens" : "budget"
  function setHeroMode(mode) { persist({ hero: mode === "tokens" ? "tokens" : "budget" }) }
  // Fred, 2026-09-20: "I really don't care about the 5hr window so make that
  // optional to TURN ON but not on by default."
  readonly property bool showSessionWindows: setting("showSession", false) === true
  function toggleSessionWindows() { persist({ showSession: !showSessionWindows }) }

  // What a card's glow MEANS, chosen in SETUP. One reason at a time on purpose:
  // a glow that could mean four things says nothing from across the room.
  readonly property var glowReasons: ["pace", "burn", "spent", "stop", "off"]
  readonly property string glowMode: glowReasons.indexOf(String(setting("glow", "pace"))) >= 0
    ? String(setting("glow", "pace")) : "pace"
  function setGlowMode(mode) { persist({ glow: glowReasons.indexOf(mode) >= 0 ? mode : "pace" }) }

  // Tick or untick one lane. Ticking every lane, or unticking the last one,
  // both mean "all of them": an empty strip helps nobody.
  function toggleLane(id) {
    if (String(id || "") === "") { persist({ lanes: "", focus: "" }); return }
    // "All" is every box ticked, so unticking one from there means everything
    // EXCEPT that one - which is what a row of ticked checkboxes promises.
    var all = knownLanes()
    var next = focusLanes.length === 0 ? all.slice() : focusLanes.slice()
    var at = next.indexOf(id)
    if (at >= 0) next.splice(at, 1)
    else next.push(id)
    if (next.length === 0 || next.length >= all.length) persist({ lanes: "", focus: "" })
    else persist({ lanes: next.join(","), focus: "" })
  }

  // Every lane this machine knows about, in strip order.
  function knownLanes() {
    var out = []
    if (svc && svc.claudePresent) out.push("claude")
    if (svc && svc.codexPresent) out.push("codex")
    if (svc && svc.grokPresent) out.push("grok")
    if (svc && svc.kimiPresent) out.push("kimi")
    if (svc && svc.hasComputeGpu) out.push("local")
    return out
  }

  // What the right-click menu offers to re-arm, and what it says it will.
  readonly property int acknowledgedCount: {
    var n = 0
    for (var k in (paceAck || ({}))) n++
    return n
  }

  // Put every answered warning back on the table, without having to overspend
  // further to earn it.
  function clearPaceAck() {
    paceAck = ({})
    try { paceAckFile.setText("{}") } catch (e) { /* a warning is not worth a crash */ }
  }

  function syncServiceSettings() { if (svc) svc.settings = settings || ({}) }
  onSvcChanged: syncServiceSettings()
  onSettingsChanged: syncServiceSettings()

  // ── theme palette ─────────────────────────────────────────────────────────
  // The shell's Color singleton keeps only five roles (foreground, background,
  // accent, urgent, muted) and discards the rest of the theme, so read
  // colors.toml directly for the named hues the heat ramps need. Five of the
  // installed themes ship no colors.toml at all; those fall through to the
  // built-in ramp below, which is why every stop keeps a literal base.
  readonly property bool themeColors: setting("themeColors", true) !== false
  readonly property string themePalettePath:
    (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state")
      + "/omarchy/current/theme/colors.toml"
  property var themePalette: ({})

  function parsePalette(raw) {
    var out = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([A-Za-z0-9_]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (m) out[m[1]] = m[2]
    }
    return out
  }

  // 0..1, or -1 for a grey with no hue to borrow.
  function hexHue(hex) {
    var r = parseInt(hex.substr(1, 2), 16) / 255
    var g = parseInt(hex.substr(3, 2), 16) / 255
    var b = parseInt(hex.substr(5, 2), 16) / 255
    var mx = Math.max(r, g, b), mn = Math.min(r, g, b), d = mx - mn
    if (d === 0) return -1
    var h
    if (mx === r) h = ((g - b) / d) % 6
    else if (mx === g) h = (b - r) / d + 2
    else h = (r - g) / d + 4
    h /= 6
    return h < 0 ? h + 1 : h
  }

  // Hue from the theme, saturation and lightness from our own ramp. Taking the
  // theme colour whole turns the strip pastel on the muted themes and it stops
  // reading as heat; taking only the hue re-tints with the desktop while the
  // embers keep their glow.
  function themed(base, key, fallbackKey) {
    if (!themeColors) return base
    var hex = themePalette[key] || (fallbackKey ? themePalette[fallbackKey] : "")
    if (!hex) return base
    var h = hexHue(hex)
    if (h < 0) return base
    return Qt.hsla(h, base.hslSaturation, base.hslLightness, 1)
  }

  FileView {
    path: root.themePalettePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themePalette = root.parsePalette(text())
    onLoadFailed: root.themePalette = ({})
  }

  // ── heat ramps ────────────────────────────────────────────────────────────
  // Cloud + local converge on the same amber/white at the top end, because
  // hot is hot. Identity lives in the cold and mid stops: Claude orange,
  // Codex teal, Grok rose, local violet, separable at 3px in every theme.
  // Each stop keeps its literal as the base the theme hue is applied to.
  readonly property color baseClaudeCold: "#4A2113"
  readonly property color baseClaudeWarm: "#C4542A"
  readonly property color baseClaudeHot:  "#FF8A4B"
  readonly property color claudeCold: themed(baseClaudeCold, "orange", "yellow")
  readonly property color claudeWarm: themed(baseClaudeWarm, "orange", "yellow")
  readonly property color claudeHot:  themed(baseClaudeHot,  "orange", "yellow")

  readonly property color baseCodexCold: "#0C3E33"
  readonly property color baseCodexWarm: "#12977A"
  readonly property color baseCodexHot:  "#2BE8B0"
  readonly property color codexCold: themed(baseCodexCold, "green", "cyan")
  readonly property color codexWarm: themed(baseCodexWarm, "green", "cyan")
  readonly property color codexHot:  themed(baseCodexHot,  "green", "cyan")

  readonly property color baseGrokCold: "#3F1428"
  readonly property color baseGrokWarm: "#C43B7A"
  readonly property color baseGrokHot:  "#FF6BB4"
  readonly property color grokCold: themed(baseGrokCold, "magenta", "red")
  readonly property color grokWarm: themed(baseGrokWarm, "magenta", "red")
  readonly property color grokHot:  themed(baseGrokHot,  "magenta", "red")

  readonly property color baseKimiCold: "#0B2E3F"
  readonly property color baseKimiWarm: "#1E7FA8"
  readonly property color baseKimiHot:  "#4FD6FF"
  readonly property color kimiCold: themed(baseKimiCold, "cyan", "blue")
  readonly property color kimiWarm: themed(baseKimiWarm, "cyan", "blue")
  readonly property color kimiHot:  themed(baseKimiHot,  "cyan", "blue")

  readonly property color baseLocalCold: "#241046"
  readonly property color baseLocalWarm: "#7A3BE0"
  readonly property color baseLocalHot:  "#C79BFF"
  readonly property color localCold: themed(baseLocalCold, "blue", "accent")
  readonly property color localWarm: themed(baseLocalWarm, "blue", "accent")
  readonly property color localHot:  themed(baseLocalHot,  "blue", "accent")

  readonly property color baseEmberAmber: "#FFC46B"
  readonly property color emberAmber: themed(baseEmberAmber, "yellow", "orange")
  // The convergence point is deliberately near-white; its saturation is low
  // enough that borrowing a hue would not be visible, so it stays literal.
  readonly property color whiteHot: "#FFF6EC"

  // Quota and temperature ramps read literally: green/yellow/red mean the same
  // thing in every theme, and there is no identity to preserve.
  readonly property color gaugeGood: themeColors && themePalette["green"]
    ? themePalette["green"] : "#22c55e"
  readonly property color gaugeWarn: themeColors && themePalette["yellow"]
    ? themePalette["yellow"] : "#facc15"
  readonly property color okGreen: themeColors && themePalette["green"]
    ? themePalette["green"] : "#35f28b"

  readonly property color urgent: Color.urgent

  function mix(a, b, t) {
    var u = Math.max(0, Math.min(1, t))
    return Qt.rgba(a.r + (b.r - a.r) * u,
                   a.g + (b.g - a.g) * u,
                   a.b + (b.b - a.b) * u,
                   a.a + (b.a - a.a) * u)
  }

  // cold → warm → hot → amber → white. Four segments, deliberately uneven: most
  // of the resolution sits in the low-mid where day-to-day burn actually lives.
  // `faulted` is per lane: a dead cloud collector reddens the cloud lanes and
  // nothing else. Local telemetry has its own probe and its own truth.
  function heat(level, cold, warm, hot, faulted) {
    if (faulted === undefined ? root.broken : faulted) return Qt.rgba(urgent.r, urgent.g, urgent.b, 1)
    var l = Math.max(0, Math.min(1, level))
    if (l < 0.30) return mix(cold, warm, l / 0.30)
    if (l < 0.62) return mix(warm, hot, (l - 0.30) / 0.32)
    if (l < 0.86) return mix(hot, emberAmber, (l - 0.62) / 0.24)
    return mix(emberAmber, whiteHot, (l - 0.86) / 0.14)
  }

  // ── scale ─────────────────────────────────────────────────────────────────
  // A power curve, not a log one. Log flatters idleness: a 1k-token blip would
  // read half as hot as a 1M-token burst and the strip would look busy when it
  // is not. ^0.45 keeps small burns visible without lying about magnitude.
  readonly property real scaleFloor: 150000
  readonly property real claudeRef: Math.max(svc ? svc.claudePeak : 0, scaleFloor)
  readonly property real codexRef: Math.max(svc ? svc.codexPeak : 0, scaleFloor)
  readonly property real grokRef: Math.max(svc ? svc.grokPeak : 0, scaleFloor)
  readonly property real kimiRef: Math.max(svc ? svc.kimiPeak : 0, scaleFloor)

  function norm(tokens, reference) {
    if (!(tokens > 0)) return 0
    return Math.min(1, Math.pow(tokens / Math.max(1, reference), 0.45))
  }

  // Claude reads oldest→newest left to right, ending at the divider.
  function claudeLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].claude || 0) : 0, root.claudeRef)
  }

  // Codex mirrors it: newest sits against the divider and time runs rightward.
  function codexLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    // Mirrored only when it HAS a partner. Alone, the lane is drawn newest-last
    // (see newestLast on codexLane), so the cells must be filled that way too:
    // a Codex-only machine showed its history backwards.
    var idx = root.cloudAgents === 1 ? b.length - root.cellCount + i : b.length - 1 - i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].codex || 0) : 0, root.codexRef)
  }

  // Grok rides after Codex: oldest→newest left to right, same token scale.
  function grokLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].grok || 0) : 0, root.grokRef)
  }

  // Kimi rides after Grok on the same token scale.
  function kimiLevel(i) {
    var b = root.buckets
    if (!b || !b.length) return 0
    var idx = b.length - root.cellCount + i
    return root.norm(idx >= 0 && idx < b.length ? Number(b[idx].kimi || 0) : 0, root.kimiRef)
  }

  // Local is already a percentage, so it needs no reference peak, but it does
  // need the same gamma, or a 40% GPU would read cooler than a small token blip
  // sitting right next to it.
  function localLevel(i) {
    var h = svc ? svc.localHistory : []
    if (!h || !h.length) return 0
    var v = i < h.length ? Number(h[i] || 0) : 0
    if (!(v > 0)) return 0
    return Math.min(1, Math.pow(v / 100, 0.55))
  }

  function compact(n) {
    var v = Number(n) || 0
    if (v >= 1e9) return (v / 1e9).toFixed(1) + "B"
    if (v >= 1e6) return (v / 1e6).toFixed(1) + "M"
    if (v >= 1e3) return (v / 1e3).toFixed(0) + "k"
    return String(Math.round(v))
  }

  // Escalation stages, and they only exist while a window is over pace: being
  // nearly spent at the END of a window you spent evenly is not news. A warning
  // you have already seen and clicked away is not news either, but the NEXT
  // stage is - which is the whole point of numbering them.
  //   1 over pace   2 way over (1.5x)   3 badly over (2.5x)   4 spent out early
  function paceStage(ratio, percent) {
    var r = Number(ratio), p = Number(percent)
    // Within 5% of an even spend is on pace everywhere: the panel already
    // refused to print a multiplier there while the badge said "1.0x OVER".
    if (!(r > 1.05)) return 0
    // 99.5% rounds to "100%" everywhere it is printed, so it is spent here too:
    // a headline saying 100% over a badge still breathing "slow down" disagrees.
    if (p >= 0.995) return 4
    if (r > 2.5) return 3
    if (r > 1.5) return 2
    return 1
  }

  // What has been clicked away: { key: { resets, stage } }. Kept on disk so a
  // shell restart does not re-open a warning Fred already answered.
  property var paceAck: ({})
  readonly property string paceAckPath: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state") + "/omarchy/burnbar/pace-ack.json"

  FileView {
    id: paceAckFile
    path: root.paceAckPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var parsed = JSON.parse(text())
        root.paceAck = (parsed && typeof parsed === "object") ? parsed : ({})
      } catch (e) { root.paceAck = ({}) }
    }
    onLoadFailed: root.paceAck = ({})
  }

  // Clicking the strip answers the warning it is showing: it fades, and stays
  // gone until this window reaches a WORSE stage or its window rolls over.
  function acknowledgePace() {
    var w = root.worstPace
    if (!w || w.stage <= 0 || w.key === "") return
    var next = {}
    for (var k in root.paceAck) next[k] = root.paceAck[k]
    next[w.key] = { resets: w.resets, stage: w.stage }
    root.paceAck = next
    try { paceAckFile.setText(JSON.stringify(next)) } catch (e) { /* a warning is not worth a crash */ }
  }

  // The worst window on this machine, when one is past its even-spend pace.
  // Empty when everything is on track, which is the point: the chip below only
  // exists while it has something to say.
  readonly property var worstPace: {
    var none = { text: "", short: "", third: "", mult: "", color: urgent, ratio: 0, stage: 0, key: "", resets: 0 }
    if (!svc) return none
    void svc.limitsTick   // the rest time counts down even when no new sample lands
    var rows = [["CLAUDE", svc.claudeWeeklyPace, "claude|weekly", Math.min(1, svc.claudeWeekly)],
                ["CODEX", svc.codexWeeklyPace, "codex|weekly", Math.min(1, svc.codexWeekly)],
                ["GROK", svc.grokWeeklyPace, "grok|weekly", Math.min(1, svc.grokWeekly)],
                ["KIMI", svc.kimiMonthlyPace, "kimi|monthly", svc.kimiMonthly]]
    var best = none
    for (var i = 0; i < rows.length; i++) {
      var pace = rows[i][1]
      if (!pace) continue
      // A lane the user unticked has no card and no cells, so it gets no badge
      // either: with Codex hidden the strip still said "SPENT" about Codex.
      if (!focusOk(rows[i][2].split("|")[0])) continue
      var r = Number(pace.ratio)
      if (!(r > 1.05) || r <= best.ratio) continue
      var stage = paceStage(r, rows[i][3])
      var key = rows[i][2]
      // The window instance, not a moving target: backOnPaceAt shifts with every
      // percentage change and would re-open a warning that was already answered.
      var resets = Number(pace.resetsMs) || 0
      // Answered already, and nothing has got worse since: stay quiet.
      var seen = root.paceAck ? root.paceAck[key] : null
      if (seen && Number(seen.stage) >= stage && Number(seen.resets) === resets) continue
      var mult = (r >= 10 ? Math.round(r) : r.toFixed(1)) + "x"
      // What to DO, not how bad: "7.6x OVER" made Fred ask whether 1.0x meant
      // on target. A multiplier is data; "rest it 7 hours" is guidance. The
      // colour and the pulse still carry the severity.
      var live = liveFor(key.split("|")[0], Date.now())
      var word = !live ? mult + " OVER" : live.spent ? "SPENT" : "REST " + spanShort(live.comeBackMs)
      best = { text: rows[i][0] + "  " + word,
               short: word, third: !live || live.spent ? word : spanShort(live.comeBackMs), mult: mult,
               stage: stage, key: key, resets: resets,
               color: r > 1.5 ? urgent : Qt.lighter(urgent, 1.35), ratio: r }
    }
    return best
  }

  function gaugeColor(percent) {
    if (percent >= 0.9) return urgent
    if (percent >= 0.75) return gaugeWarn
    return gaugeGood
  }

  // ── guidance ───────────────────────────────────────────────────────────────
  // Fred, 2026-09-20: "We dont want data, we want guidance to the user about
  // what to do AND the data." Three questions, answered in plain words:
  //   · am I ahead, and by how much?   (banked: shown only when ahead)
  //   · if I am behind, when can I come back?   (a countdown, never a ratio)
  //   · with more than one subscription, which one should I reach for next?
  // Budget means an even spend across the window, so everything here falls out
  // of two numbers: how much of the plan is used, and how much of the clock.

  // Where one window stands RIGHT NOW. The collector's percentage only moves
  // when a provider reports, but the clock never stops: a subscription left
  // alone gets further ahead every second, so elapsed is worked out from the
  // reset and the present, not read from the last collector run. Pure.
  function paceLive(percent, resetsMs, windowMs, nowMs) {
    var p = Number(percent), reset = Number(resetsMs), span = Number(windowMs), now = Number(nowMs)
    if (!(p >= 0) || !(reset > 0) || !(span > 0) || !(now > 0) || now >= reset) return null
    p = Math.min(1, p)
    var left = reset - now
    var e = Math.max(0, Math.min(1, 1 - left / span))
    var out = { used: p, elapsed: e, leftMs: left, windowMs: span, resetsMs: reset,
                banked: 0, bankedMs: 0, behind: 0, over: false, comeBackAt: 0, comeBackMs: 0,
                room: 0, spent: p >= 0.995 }
    if (out.spent) {
      // Decided FIRST. A plan can be spent while still "ahead" of the clock (the
      // last hour of a week at 99.6%), and leaving the come-back time unset there
      // printed a date in 1970. Spent only ever comes back at its reset.
      out.behind = Math.max(0, p - e)
      out.over = true
      out.comeBackAt = reset
      out.comeBackMs = left
    } else if (e > p) {
      // The share of the plan an even spend would have used by now and did not.
      out.banked = e - p
      out.bankedMs = out.banked * span
    } else if (p > e) {
      out.behind = p - e
      // "Over" is the same judgement the verdict pill makes: more than 5% past
      // an even spend, and by at least a whole percent of the plan. Inside that
      // grace a sub is on pace, not told to go away.
      out.over = out.behind > 0.01 && (e <= 0 || p / e > 1.05)
      // Stop now and the even-spend line catches up when elapsed reaches used.
      out.comeBackAt = Math.min(reset, reset - span * (1 - p))
      out.comeBackMs = Math.max(0, out.comeBackAt - now)
    }
    // What is left of the plan over what is left of the clock. 1 is exactly on
    // pace, 2 means the rest of the window can take twice an even spend. The
    // same figure for a week and for a month, so they can be compared, and it
    // climbs on its own as a reset nears with budget unspent.
    out.room = e < 1 ? (1 - p) / (1 - e) : 0
    return out
  }

  // Which subscription to reach for next. rows: [{ id, live, fresh, blocked }]
  // where live is paceLive(), fresh says the figure can be vouched for, and
  // blocked says a short session window is full. Pure, so it is tested.
  //   · one subscription: nothing to choose between, so nothing is said.
  //   · only a sub that is AHEAD is ever suggested; the most room wins, which
  //     turns into earliest-deadline-first as a reset nears with budget unspent.
  //   · the last answer sticks until another beats it clearly, so the advice
  //     does not flap between two near-equal subs on every refresh.
  function guidePick(rows, previousId) {
    var MIN_BANK = 0.02, STICK = 1.15
    // "Use it or lose it" is about the calendar, not the window: 15% of a month
    // is four and a half days, and crying wolf that early gets the chip ignored.
    var LOSE_IT_MS = 72 * 3600000, LOSE_IT_SHARE = 0.15, LOSE_IT_LEFT = 0.10
    var out = { count: 0, pick: "", next: "", urgent: false, room: 0, rest: [], ahead: 0 }
    var list = rows || []
    var ok = [], i
    for (i = 0; i < list.length; i++) {
      var r = list[i]
      if (!r || !r.id) continue
      out.count++
      if (!r.live || !r.fresh) continue
      if (r.live.over || r.live.spent)
        out.rest.push({ id: r.id, comeBackAt: r.live.comeBackAt, spent: r.live.spent, behind: r.live.behind })
      // A snapshot may have been outrun by use nobody measured, so it has to
      // be further ahead before it is worth acting on. And the sub already
      // being suggested keeps the job down to half the bar, so advice does not
      // blink on and off around the threshold.
      var need = r.minBank > 0 ? r.minBank : MIN_BANK
      if (r.id === previousId) need = need * 0.5
      if (r.live.spent || r.blocked || !(r.live.banked >= need)) continue
      ok.push(r)
    }
    out.ahead = ok.length
    out.rest.sort(function(a, b) { return a.comeBackAt - b.comeBackAt })
    if (out.count < 2 || ok.length === 0) return out
    ok.sort(function(a, b) {
      if (b.live.room !== a.live.room) return b.live.room - a.live.room
      if (b.live.banked !== a.live.banked) return b.live.banked - a.live.banked
      return a.live.leftMs - b.live.leftMs
    })
    if (previousId && previousId !== ok[0].id) {
      for (i = 1; i < ok.length; i++) {
        if (ok[i].id !== previousId) continue
        // The challenger has to be clearly better, not better by a rounding.
        if (ok[0].live.room < ok[i].live.room * STICK) ok.unshift(ok.splice(i, 1)[0])
        break
      }
    }
    out.pick = ok[0].id
    out.room = ok[0].live.room
    out.urgent = ok[0].live.leftMs <= Math.min(LOSE_IT_MS, ok[0].live.windowMs * LOSE_IT_SHARE)
      && (1 - ok[0].live.used) >= LOSE_IT_LEFT
    out.next = ok.length > 1 ? ok[1].id : ""
    return out
  }

  // A running clock for the card: "3d 09:12:45", "7:13:22", "13:22". Banked time
  // climbs one second per second while a sub is left alone and a come-back time
  // counts down, and seeing it move is the point. Pure.
  function clockSpan(ms) {
    var total = Math.max(0, Math.floor(Number(ms) / 1000))
    if (!(total >= 0)) return "0:00"
    var d = Math.floor(total / 86400), h = Math.floor((total % 86400) / 3600)
    var m = Math.floor((total % 3600) / 60), sec = total % 60
    var two = function(n) { return (n < 10 ? "0" : "") + n }
    if (d > 0) return d + "d " + two(h) + ":" + two(m) + ":" + two(sec)
    if (h > 0) return h + ":" + two(m) + ":" + two(sec)
    return m + ":" + two(sec)
  }
  // The largest unit only, for the chip on the bar: "7H", "2D", "45M". Pure.
  function spanShort(ms) {
    var mins = Math.max(1, Math.round(Number(ms) / 60000))
    if (!(mins >= 1)) return "1M"
    if (mins >= 1440) return Math.round(mins / 1440) + "D"
    if (mins >= 60) return Math.round(mins / 60) + "H"
    return mins + "M"
  }

  // "3d 10h", "6h 40m", "45m": a span a person can plan around. Two units at
  // most, because "3d 10h 22m" is a stopwatch, not advice. Pure.
  function spanWords(ms) {
    var mins = Math.max(0, Math.round(Number(ms) / 60000))
    if (!(mins >= 1)) return "under a minute"
    var d = Math.floor(mins / 1440), h = Math.floor((mins % 1440) / 60), m = mins % 60
    if (d > 0) return h > 0 ? d + "d " + h + "h" : d + "d"
    if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
    return m + "m"
  }

  function subName(id) {
    return id === "claude" ? "Claude" : id === "codex" ? "Codex" : id === "grok" ? "Grok" : id === "kimi" ? "Kimi" : ""
  }
  function subColor(id) {
    return id === "claude" ? claudeHot : id === "codex" ? codexHot : id === "grok" ? grokHot : kimiHot
  }
  function subLimits(id) {
    if (!svc) return []
    return (id === "claude" ? svc.claudeLimits : id === "codex" ? svc.codexLimits
      : id === "grok" ? svc.grokLimits : id === "kimi" ? svc.kimiLimits : []) || []
  }
  function subMeta(id) {
    if (!svc) return { measuredAt: 0, live: true, lastAt: 0, present: false }
    return id === "claude" ? { measuredAt: svc.claudeLimitsMeasuredAt, live: svc.claudeLimitsLive, lastAt: svc.claudeLastAt, present: svc.claudePresent }
      : id === "codex" ? { measuredAt: svc.codexLimitsMeasuredAt, live: svc.codexLimitsLive, lastAt: svc.codexLastAt, present: svc.codexPresent }
      : id === "grok" ? { measuredAt: svc.grokLimitsMeasuredAt, live: svc.grokLimitsLive, lastAt: svc.grokLastAt, present: svc.grokPresent }
      : { measuredAt: svc.kimiLimitsMeasuredAt, live: svc.kimiLimitsLive, lastAt: svc.kimiLastAt, present: svc.kimiPresent }
  }
  function isSessionLabel(label) { return /session|5-hour/i.test(String(label || "")) }

  // The window a subscription is judged by: the weekly one where there is one,
  // otherwise the monthly pool, otherwise the first that is not a short session
  // window. A 5-hour window is never the budget: it refills before lunch.
  function primaryLimit(id) {
    var rows = subLimits(id), i
    for (i = 0; i < rows.length; i++)
      if (/^weekly/i.test(String(rows[i].label || ""))) return rows[i]
    for (i = 0; i < rows.length; i++)
      if (/monthly \(total\)/i.test(String(rows[i].label || ""))) return rows[i]
    for (i = 0; i < rows.length; i++)
      if (!isSessionLabel(rows[i].label)) return rows[i]
    return null
  }
  // Can this figure be stood behind at all? Same withholding rules as the
  // gauges: a stale record, a rolled-over window or an unreadable percentage
  // has no pace, and so no advice.
  function limitUsable(id, limit) {
    if (!svc || !limit) return false
    var meta = subMeta(id)
    if (svc.limitsStale(meta.measuredAt, meta.live)) return false
    if (svc.limitExpired(limit)) return false
    return Number(limit.percent) >= 0
  }
  // A snapshot (Grok logs its credits only when Grok starts) cannot be
  // re-measured, so it is never treated as exact: it needs five times the margin
  // before it is suggested, and the advice says when it was taken. If Grok has
  // been used since, the percentage can only have gone up by an amount nobody
  // measured, and the words say that too. lastWriteAt sees use that is older
  // than the history window, which lastAt cannot.
  function isSnapshot(id) { return subMeta(id).live === false }
  function snapshotOutrun(id) {
    var meta = subMeta(id)
    if (meta.live !== false) return false
    var seen = Math.max(Number(meta.lastAt) || 0, id === "grok" && svc ? Number(svc.grokLastWriteAt) || 0 : 0)
    return seen > Number(meta.measuredAt) + 600000
  }
  function asOfText(id) {
    if (!isSnapshot(id)) return ""
    var t = Number(subMeta(id).measuredAt) || 0
    if (!(t > 0)) return ""
    return "as of " + Qt.formatDateTime(new Date(t), "ddd h:mm AP") + (snapshotOutrun(id) ? ", used since" : "")
  }
  // A short session window that is nearly full blocks a sub right now even when
  // its week is wide open. The 5-hour rows are hidden by default; they still
  // count here, because sending someone into a wall is not guidance.
  function sessionBlock(id) {
    var rows = subLimits(id)
    for (var i = 0; i < rows.length; i++) {
      if (!isSessionLabel(rows[i].label) || !limitUsable(id, rows[i])) continue
      var full = Number(rows[i].percent)
      var rate = rows[i].pace ? Number(rows[i].pace.ratePerHour) : 0
      // Full, or filling fast enough to be full inside half an hour: sending
      // someone to a sub that locks them out in ten minutes is not guidance.
      if (full >= 0.9 || (rate > 0 && (1 - full) / rate < 0.5))
        return Date.parse(String(rows[i].resetsAt || "")) || 1
    }
    return 0
  }
  function subBurning(id) {
    if (!svc) return false
    return (id === "claude" ? svc.claudeTrailing5 : id === "codex" ? svc.codexTrailing5
      : id === "grok" ? svc.grokTrailing5 : id === "kimi" ? svc.kimiTrailing5 : 0) > 0
  }
  // The moment a percentage is true FOR. A provider's figure only moves when it
  // is re-measured, so running the clock past that moment while tokens are
  // leaving would let "banked" climb between probes and then jump back down.
  //   · resting: the present. Nothing is being spent, the figure still holds,
  //     and banked time really does grow a second every second.
  //   · burning: the last measurement. The clocks hold still until it is
  //     re-measured, and the words say "if you stop".
  //   · a snapshot that has been used since: the snapshot's own moment, which
  //     is exactly what "as of Sat 9:20 PM" claims.
  function standingAt(id, nowMs) {
    var now = Number(nowMs) || Date.now()
    var measured = Number(subMeta(id).measuredAt) || 0
    if (measured > 0 && measured < now && (subBurning(id) || snapshotOutrun(id))) return measured
    return now
  }
  function liveFor(id, nowMs) {
    var limit = primaryLimit(id)
    if (!limitUsable(id, limit) || !limit.pace) return null
    var reset = Number(limit.pace.resetsMs) || Date.parse(String(limit.resetsAt || ""))
    return paceLive(limit.percent, reset, limit.pace.windowMs, standingAt(id, nowMs))
  }
  function windowWord(limit) {
    var label = String((limit && limit.label) || "")
    return /week/i.test(label) ? "week" : /month/i.test(label) ? "month" : /session|5-hour/i.test(label) ? "session" : "window"
  }

  // The advice itself. Local is never a candidate: it is not a subscription,
  // and this is about where you stand on your plans, not where work should run.
  // Hidden lanes are left out too: a sub the user unticked is one they do not
  // want to hear about.
  property var guidance: ({ count: 0, pick: "", next: "", urgent: false, room: 0, rest: [], ahead: 0 })
  function refreshGuidance() {
    var ids = ["claude", "codex", "grok", "kimi"], rows = [], now = Date.now()
    for (var i = 0; i < ids.length; i++) {
      var id = ids[i]
      if (!subMeta(id).present || !focusOk(id)) continue
      // A snapshot cannot be re-measured, so it has to be further ahead before it
      // is worth acting on, and further still once it has been used since.
      rows.push({ id: id, live: liveFor(id, now), fresh: true, blocked: sessionBlock(id) > 0,
                  minBank: !isSnapshot(id) ? 0 : snapshotOutrun(id) ? 0.25 : 0.10 })
    }
    guidance = guidePick(rows, guidance ? guidance.pick : "")
  }
  Timer { interval: 30000; running: true; repeat: true; triggeredOnStart: true; onTriggered: root.refreshGuidance() }
  Connections {
    target: root.svc
    ignoreUnknownSignals: true
    function onGeneratedAtChanged() { root.refreshGuidance() }
  }
  onFocusLanesChanged: refreshGuidance()

  // Headline and reason, shared by the cockpit banner and the tooltips so the
  // bar and the panel can never give different advice.
  function guideHeadline() {
    var g = guidance
    if (!g || g.count < 2) return ""
    // Already on the right one: say so, rather than telling them to switch to
    // what they are using.
    if (g.pick !== "" && pickBurning()) return "Keep using " + subName(g.pick)
    if (g.pick !== "") return "Use " + subName(g.pick) + (g.urgent ? " now" : " next")
    if (g.rest.length > 0) return "Nothing has spare budget"
    return "Everything is on pace"
  }
  function pickBurning() { return guidance && guidance.pick !== "" && subBurning(guidance.pick) }
  function guideReason(nowMs) {
    var g = guidance
    if (!g || g.count < 2) return ""
    var now = Number(nowMs) || Date.now()
    if (g.pick !== "") {
      var live = liveFor(g.pick, now)
      if (!live) return ""
      var word = windowWord(primaryLimit(g.pick))
      var pct = Math.round(live.banked * 100) + "%"
      if (g.urgent)
        return "use it or lose it: it resets in " + spanWords(live.leftMs) + " with "
          + Math.round((1 - live.used) * 100) + "% of its " + word + " unspent"
      var asOf = asOfText(g.pick)
      return pct + " of its " + word + " is banked, about " + spanWords(live.bankedMs)
        + " ahead  ·  resets in " + spanWords(live.leftMs)
        + (asOf !== "" ? "  ·  " + asOf : "")
    }
    if (g.rest.length > 0) {
      var first = g.rest[0]
      return "first back on pace: " + subName(first.id) + ", "
        + (first.spent ? "at its reset " : "") + Qt.formatDateTime(new Date(first.comeBackAt), "ddd h:mm AP")
        + " (in " + spanWords(first.comeBackAt - now) + ")"
    }
    return "use whichever you like: spend evenly and every plan makes it"
  }
  // One line for one subscription: banked when ahead, a way back when behind.
  // Never both, and never "banked" on a sub that is behind.
  function standingText(id, nowMs, bare) {
    var now = Number(nowMs) || Date.now()
    var live = liveFor(id, now)
    if (!live) return ""
    if (live.spent) return "spent  ·  back at the reset in " + spanWords(live.comeBackMs)
    if (live.over)
      return "come back in " + spanWords(live.comeBackMs) + " if you stop now ("
        + Qt.formatDateTime(new Date(live.comeBackAt), "ddd h:mm AP") + ")"
    if (live.banked >= 0.01)
      return Math.round(live.banked * 100) + "% banked, about " + spanWords(live.bankedMs) + " ahead"
        + (bare !== true && asOfText(id) !== "" ? "  ·  " + asOfText(id) : "")
    return "on pace"
  }

  // The chip on the strip when there is no warning to show: the sub to use.
  readonly property bool showAdvice: setting("advice", true) !== false
  function toggleAdvice() { persist({ advice: !showAdvice }) }
  readonly property var adviceChip: {
    var none = { text: "", short: "", third: "", mult: "", color: urgent, advice: true }
    var g = guidance
    if (!showAdvice || !g || g.count < 2 || g.pick === "" || pickBurning()) return none
    var name = subName(g.pick).toUpperCase()
    return { text: "USE " + name, short: name, third: name, mult: name.charAt(0),
             color: subColor(g.pick), advice: true }
  }
  // A warning outranks advice: what to stop comes before what to start.
  readonly property var stripChip: worstPace.text !== "" ? worstPace : adviceChip

  // ── state ─────────────────────────────────────────────────────────────────
  readonly property bool broken: svc ? svc.collectorBroken : false
  readonly property bool localOnline: svc ? svc.localOnline : false
  readonly property bool localActive: svc ? svc.localActive : false
  readonly property real localLoad: svc ? svc.localLoad : 0

  // Nothing burning is a real and common state, and a dead-flat widget reads as
  // broken. A slow travelling swell keeps the strip alive without inventing
  // data. A fault must never animate like a calm idle strip; that is how a
  // total outage hides in plain sight.
  readonly property bool idle: !broken && (!ready
    || ((!showClaude || (svc ? svc.claudeLatest : 0) <= 0)
        && (!showCodex || (svc ? svc.codexLatest : 0) <= 0)
        && (!showGrok || (svc ? svc.grokLatest : 0) <= 0)
        && (!showKimi || (svc ? svc.kimiLatest : 0) <= 0)))

  // One number for "how hard is this machine working right now", across all
  // three agents. Drives every global effect: under-glow, sparks, frame rate.
  readonly property real energy: Math.max(
      root.broken || !root.showClaude ? 0 : root.claudeLevel(root.cellCount - 1),
      root.broken || !root.showCodex ? 0 : root.codexLevel(0),
      root.broken || !root.showGrok ? 0 : root.grokLevel(root.cellCount - 1),
      root.broken || !root.showKimi ? 0 : root.kimiLevel(root.cellCount - 1),
      root.showLocal && root.localOnline ? root.localLevel(0) : 0)

  readonly property color energyColor: root.broken ? urgent
    : root.mix(root.mix(root.mix(root.claudeHot, root.codexHot, 0.5), root.grokHot, 0.35),
               root.localHot, root.showLocal && root.localActive ? 0.45 : 0.12)

  // ── ember motion ──────────────────────────────────────────────────────────
  // Driven by a 20fps timer rather than a frame-rate NumberAnimation: with up to
  // 80 cells each re-deriving colour from the phase, 60fps would be three times
  // the property churn for flicker nobody can see.
  // Two phases, both wrapped at exactly 2π, and EVERY consumer reads them at a
  // whole-number harmonic (×1, ×2, ×3). That is what makes the wrap invisible:
  // sin(k·(φ+2π)) === sin(k·φ) only when k is an integer. Reading the same phase
  // at ×1.7 or ×0.35 puts a hard discontinuity in the shimmer every time it
  // wraps, which is exactly the visual restart this replaced, the strip
  // appeared to loop every 1.65s because that is how long the wrap took.
  property real emberPhase: 0
  // Idle drift needs a period measured in tens of seconds, not one second, so it
  // gets its own slow phase instead of a fractional harmonic of the fast one.
  property real driftPhase: 0

  Timer {
    id: emberClock
    // 20fps while something is burning, 5fps when nothing is: the idle swell is
    // a slow drift and does not need frame-accurate updates on battery.
    readonly property bool resting: root.idle && !root.localActive
    interval: resting ? 200 : 50
    running: root.emberFlicker && root.visible && !root.broken
    repeat: true
    onTriggered: {
      // Steps are scaled by interval so neither phase changes speed when the
      // frame rate drops: only the smoothness changes.
      root.emberPhase = (root.emberPhase + (resting ? 0.56 : 0.14)) % (Math.PI * 2)
      root.driftPhase = (root.driftPhase + (resting ? 0.050 : 0.0125)) % (Math.PI * 2)
      // Already repainting at 20fps, so the pulses ride this tick instead of
      // adding frames of their own in between.
      if (!resting && root.pulseDemand > 0) root.pulseMs += interval
    }
  }

  // ── pulse clock ───────────────────────────────────────────────────────────
  // The heartbeats (live cell, quota at 90%, the over-pace chip, the local
  // core) were each an Animation.Infinite, and a running Animation asks for a
  // new frame on every vsync of every screen the bar is on: 120fps on a 120Hz
  // panel, for a ring that breathes once every 1.8s. Measured on a three-screen
  // bar, the live ring alone held the shell at ~50% of a core against ~18%
  // without it. They now read one shared clock at 10fps (20fps while the
  // embers are already running), which a breath that slow cannot tell apart.
  // Each pulse holds a ticket while it is on screen and the clock only runs
  // while someone holds one, so a quiet strip still costs nothing.
  property int pulseDemand: 0
  // Monotonic milliseconds rather than a wrapped phase: every pulse has its own
  // period, and taking the modulo per consumer keeps each one seamless.
  property real pulseMs: 0

  Timer {
    interval: 100
    running: root.pulseDemand > 0 && root.visible && !(emberClock.running && !emberClock.resting)
    repeat: true
    onTriggered: root.pulseMs += interval
  }

  // Eased from `from` to `to` and back over periodMs, starting at `from`. The
  // cosine is the smooth ease the InOutQuad pairs approximated.
  function pulse(periodMs, from, to) {
    var t = (root.pulseMs % periodMs) / periodMs
    return from + (to - from) * (0.5 - 0.5 * Math.cos(2 * Math.PI * t))
  }

  component PulseTicket: QtObject {
    property bool active: false
    property bool held: false
    function sync() {
      if (active === held) return
      root.pulseDemand += active ? 1 : -1
      held = active
    }
    onActiveChanged: sync()
    Component.onCompleted: sync()
    Component.onDestruction: if (held) root.pulseDemand -= 1
  }

  property real claudeFlash: 0
  property real codexFlash: 0
  property real grokFlash: 0
  property real kimiFlash: 0
  property real localFlash: 0
  // Wave position gets its own monotonic 0→1. The flash value (up in 90 ms,
  // down over 700) is brightness only; driving position from it sent the
  // band racing outward and then drifting back toward the divider as it faded.
  property real claudeWave: 0
  property real codexWave: 0
  property real grokWave: 0

  ParallelAnimation {
    id: claudeImpact
    NumberAnimation { target: root; property: "claudeWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "claudeFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "claudeFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
  }
  ParallelAnimation {
    id: codexImpact
    NumberAnimation { target: root; property: "codexWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "codexFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "codexFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
  }
  ParallelAnimation {
    id: grokImpact
    NumberAnimation { target: root; property: "grokWave"; from: 0; to: 1; duration: 790; easing.type: Easing.OutCubic }
    SequentialAnimation {
      NumberAnimation { target: root; property: "grokFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
      NumberAnimation { target: root; property: "grokFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
    }
  }
  // Kimi lands burn like everyone else. It had a flash property and nothing
  // that ever drove it, so its lane never reacted to new tokens.
  SequentialAnimation {
    id: kimiImpact
    NumberAnimation { target: root; property: "kimiFlash"; to: 1; duration: 90; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "kimiFlash"; to: 0; duration: 700; easing.type: Easing.OutCubic }
  }
  SequentialAnimation {
    id: localImpact
    NumberAnimation { target: root; property: "localFlash"; to: 1; duration: 80; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "localFlash"; to: 0; duration: 620; easing.type: Easing.OutCubic }
  }

  Connections {
    target: root.svc
    function onClaudePulseChanged() { claudeImpact.restart() }
    function onCodexPulseChanged() { codexImpact.restart() }
    function onGrokPulseChanged() { grokImpact.restart() }
    function onKimiPulseChanged() { kimiImpact.restart() }
    function onLocalPulseChanged() { localImpact.restart() }
  }

  // ── one lane of thermal cells ─────────────────────────────────────────────
  // An inline component so Claude, Codex and Local are literally the same
  // instrument with different inputs, when the visual language changes it
  // changes in one place, which is how the three lanes stay readable as one
  // widget instead of drifting into three dialects.
  component ThermalLane: Item {
    id: lane

    property int count: 12
    property color cold: "#000000"
    property color warm: "#888888"
    property color hot: "#ffffff"
    // function(index) → 0..1. Reading svc state inside it keeps the binding
    // live; QML tracks property reads through the call.
    property var levelAt: null
    // true when index 0 is the OLDEST sample (Claude); false when index 0 is
    // the newest (Codex, Local).
    property bool newestLast: true
    property real flash: 0
    property real phaseSign: 1
    // Which instrument's fault this lane shows. Cloud lanes follow the
    // collector; the local lane never does.
    property bool faulted: root.broken

    readonly property real slot: width / Math.max(1, count)
    readonly property real cellWidth: Math.max(1, slot - Style.spaceReal(1))

    Repeater {
      model: lane.count
      delegate: Item {
        id: cell
        required property int index

        readonly property real level: lane.levelAt ? lane.levelAt(index) : 0
        // 1 = newest. Everything visual leans on this: recency is what makes
        // the lane read as a comet tail pointing at now.
        readonly property real recency: lane.count <= 1 ? 1
          : (lane.newestLast ? index / (lane.count - 1) : 1 - index / (lane.count - 1))
        readonly property bool live: lane.newestLast ? index === lane.count - 1 : index === 0

        // Hot cells flicker harder: cold coals sit still, a live fire does not.
        // ×2 and ×3 against the same phase: two harmonics that beat against each
        // other into something that never repeats obviously, and both survive
        // the 2π wrap untouched. The per-cell offset is what stops the lane
        // pulsing as one block.
        readonly property real flicker: root.emberFlicker
          ? Math.sin(root.emberPhase * 2 + index * 0.8 * lane.phaseSign) * 0.06 * level
            + Math.sin(root.emberPhase * 3 - index * 0.4 * lane.phaseSign) * 0.035 * level
          : 0
        readonly property real idleSwell: root.idle && !root.broken
          ? 0.06 + Math.sin(root.driftPhase + index * 0.42 * lane.phaseSign) * 0.05 : 0

        // Motion (flicker, idle drift, impact) rides on top of the sample.
        // Colour reads the sum. Height reads the sample through an eased
        // Behavior and the motion through a plain scale, so a 5 Hz flicker
        // step never restarts a 420 ms height animation on every cell, which
        // is what kept two rectangles per cell animating continuously while
        // the strip was supposedly idle.
        readonly property real motion: flicker + lane.flash * recency * recency * 0.25 + idleSwell
        readonly property real heatLevel: Math.max(0, level + motion)
        readonly property color tint: root.heat(heatLevel, lane.cold, lane.warm, lane.hot, lane.faulted)

        width: lane.cellWidth
        height: lane.height
        x: index * lane.slot
        anchors.verticalCenter: parent.verticalCenter

        // Height is the secondary channel: a 72%→100% swell that gives the lane
        // a profile without stealing the story from colour.
        readonly property real cellHeight:
          lane.height * (0.72 + 0.28 * Math.min(1, cell.level))
        readonly property real motionScale: Math.max(0.6, Math.min(1.3, 1 + 0.28 * cell.motion))

        // Bloom: a wider, softer ghost behind the cell. A cheap fake glow that
        // costs one rectangle instead of a blur pass.
        Rectangle {
          id: bloom
          anchors.centerIn: parent
          width: parent.width + Style.spaceReal(3)
          height: cell.cellHeight + Style.spaceReal(3)
          radius: Style.spaceReal(2)
          color: cell.tint
          border.width: 0
          opacity: Math.pow(cell.level, 1.6) * 0.42 * (0.4 + 0.6 * cell.recency)
            + lane.flash * cell.recency * cell.recency * 0.45
          transform: Scale { origin.x: bloom.width / 2; origin.y: bloom.height / 2; yScale: cell.motionScale }
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        Rectangle {
          id: body
          anchors.centerIn: parent
          width: parent.width
          height: cell.cellHeight
          radius: Style.spaceReal(1)
          color: cell.tint
          // Age fades toward the outer edge.
          opacity: 0.58 + 0.42 * cell.recency
          // Rectangle.border.width defaults to 1, not 0. Left implicit it
          // outlines every cell and the lane reads as a hollow comb.
          border.width: 0
          transform: Scale { origin.x: body.width / 2; origin.y: body.height / 2; yScale: cell.motionScale }
          Behavior on height { NumberAnimation { duration: 420; easing.type: Easing.OutCubic } }
        }

        // Hot core: a thin white-hot filament that only appears once a cell is
        // genuinely hot, so the top of the scale has somewhere left to go.
        Rectangle {
          anchors.centerIn: parent
          width: Math.max(1, parent.width * 0.42)
          height: cell.cellHeight * 0.42
          radius: width / 2
          color: root.whiteHot
          border.width: 0
          opacity: Math.max(0, cell.heatLevel - 0.55) * 1.5
        }

        // The live cell breathes continuously between samples so the lane never
        // looks frozen at collector granularity. It rides on its own overlay so
        // it can never leak a border onto the fill.
        Rectangle {
          id: liveRing
          visible: cell.live && !root.idle && !lane.faulted && root.visible
          anchors.centerIn: parent
          width: parent.width
          height: cell.cellHeight
          radius: Style.spaceReal(1)
          color: "transparent"
          border.color: root.whiteHot
          border.width: Style.spaceReal(1)
          // Visibility first, so a hidden ring never subscribes to the clock.
          opacity: visible ? root.pulse(1800, 0, 0.55) : 0
          readonly property PulseTicket ticket: PulseTicket { active: liveRing.visible }
        }
      }
    }
  }

  // ── a quota column ────────────────────────────────────────────────────────
  component QuotaGauge: Item {
    id: gauge
    property real percent: 0
    property color accent: "#ffffff"
    // Pace: how far over an even spend this window runs, and how far through
    // the window we are. -1 in either means "no claim" - a snapshot row, or
    // the first moments of a window where any spend divides by nearly zero.
    property real ratio: -1
    property real elapsed: -1
    readonly property bool overPace: ratio > 1.0
    // Over budget is a colour, not a number to read: urgent past 1.25x, warmer
    // between 1.0 and 1.25x, and the ordinary quota colour when under pace.
    readonly property color paceColor: ratio > 1.25 ? Color.urgent
      : ratio > 1.0 ? Qt.lighter(Color.urgent, 1.35)
      : root.gaugeColor(gauge.percent)
    // Negative means the service would not vouch for the number: the record
    // is stale or its window rolled over. An unknown gauge is an empty,
    // dimmer track, not a green sliver that reads as "0% used".
    readonly property bool unknown: percent < 0

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Util.alpha(gauge.accent, gauge.unknown ? 0.06 : 0.14)
      border.width: 0
      Behavior on color { ColorAnimation { duration: 400 } }
    }
    Rectangle {
      id: fill
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      radius: width / 2
      height: gauge.unknown || !(gauge.percent > 0) ? 0 : Math.max(1, parent.height * Math.min(1, gauge.percent))
      visible: !gauge.unknown
      color: gauge.paceColor
      border.width: 0
      Behavior on height { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 400 } }

      // Quota nearly gone gets its own heartbeat; you should not have to read
      // a number to learn you are about to be cut off. Gated on the gauge
      // actually being on screen, and the fill sits at full whenever the beat
      // is off so a quota that drops under 90% mid-pulse is not left dim.
      readonly property bool beating: !gauge.unknown && gauge.percent >= 0.9 && gauge.visible && root.visible
      opacity: beating ? root.pulse(1400, 1.0, 0.35) : 1
      readonly property PulseTicket ticket: PulseTicket { active: fill.beating }
    }

    // Where an even spend would have you by now. The gap between this tick and
    // the fill IS the overspend, which is the whole point: no number to read.
    Rectangle {
      visible: !gauge.unknown && gauge.elapsed >= 0 && gauge.elapsed <= 1
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      height: 1
      y: Math.round(parent.height * (1 - Math.min(1, Math.max(0, gauge.elapsed)))) - 1
      color: Util.alpha(gauge.accent, 0.85)
      Behavior on y { NumberAnimation { duration: 900; easing.type: Easing.OutCubic } }
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.stripWidth
    active: false
    useActiveColor: false
    // Tooltips are driven per zone from the hover overlay below, which owns the
    // pointer; leaving text here as well would race two tooltips for one slot.
    tooltipText: ""

    // ── under-glow ──────────────────────────────────────────────────────────
    // The whole widget sits on a bed of light that brightens with total energy.
    // It is the only element that spans all three lanes, and it is what makes a
    // busy machine visible from across the room without reading a single cell.
    Rectangle {
      anchors.centerIn: parent
      width: graph.width + Style.spaceReal(10)
      height: Math.max(Style.spaceReal(6), graph.height * 0.5)
      radius: height / 2
      color: root.energyColor
      border.width: 0
      opacity: 0.05 + 0.20 * Math.pow(root.energy, 1.4)
        + 0.12 * Math.max(root.claudeFlash, Math.max(root.codexFlash, Math.max(root.grokFlash, root.localFlash)))
      Behavior on opacity { NumberAnimation { duration: 300 } }
    }

    // ── over budget, in words, on top of everything ─────────────────────
    // While a window is past an even spend the strip says which service and
    // by how much, BESIDE the cells rather than over them: the history is the
    // reason the plugin exists and a warning must not be a curtain across it. Clicking the strip answers
    // it: the chip fades out and stays gone until that window reaches a WORSE
    // stage (1.5x, 2.5x, spent out) or its window rolls over. The holder owns
    // the fade so it cannot fight the pulse, which lives on the pill.
    Item {
      id: overChip
      z: 50
      anchors.left: parent.left
      anchors.leftMargin: Style.spaceReal(2)
      anchors.verticalCenter: parent.verticalCenter

      readonly property bool showing: root.stripChip.text !== ""
      readonly property real pad: Style.spaceReal(7)
      readonly property real maxWidth: Math.max(Style.spaceReal(52), root.stripWidth * 0.42)
      readonly property string label: measureFull.implicitWidth + pad <= maxWidth ? root.stripChip.text
        : measureShort.implicitWidth + pad <= maxWidth ? root.stripChip.short
        : measureThird.implicitWidth + pad <= maxWidth ? root.stripChip.third
        : root.stripChip.mult

      height: Math.max(Style.spaceReal(10), Math.min(parent.height - Style.spaceReal(3), Style.spaceReal(13)))
      width: Math.min(maxWidth, chipText.implicitWidth + pad)
      opacity: showing ? 1 : 0
      visible: opacity > 0.01
      // Answered warnings fade rather than blink out: the eye should see it
      // go, so a click feels like it did something.
      Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.OutCubic } }

      Rectangle {
        id: pill
        anchors.fill: parent
        radius: height / 2
        color: root.stripChip.color
        border.width: 0

        // Only a warning pulses. Advice sits still: it is an offer, not an alarm.
        readonly property bool beating: overChip.visible && root.visible && root.stripChip.advice !== true
        opacity: beating ? root.pulse(1800, 1.0, 0.55) : 1
        readonly property PulseTicket ticket: PulseTicket { active: pill.beating }
      }

      Text {
        id: chipText
        anchors.centerIn: parent
        text: overChip.label
        color: "#11141a"
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // Never drawn: they exist so the chip can ask how wide each candidate
      // label would be before choosing one.
      Text {
        id: measureFull
        visible: false
        text: root.stripChip.text
        font.family: chipText.font.family
        font.pixelSize: chipText.font.pixelSize
        font.bold: true
      }
      Text {
        id: measureShort
        visible: false
        text: root.stripChip.short
        font.family: chipText.font.family
        font.pixelSize: chipText.font.pixelSize
        font.bold: true
      }
      Text {
        id: measureThird
        visible: false
        text: root.stripChip.third
        font.family: chipText.font.family
        font.pixelSize: chipText.font.pixelSize
        font.bold: true
      }
    }

    Item {
      id: graph
      // The strip starts after the warning badge, never under it.
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3) + (overChip.visible ? overChip.width + Style.spaceReal(4) : 0)
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - Style.space(6) - (overChip.visible ? overChip.width + Style.spaceReal(4) : 0)
      height: Math.max(Style.space(12), Math.round(parent.height * 0.62))

      readonly property int gaugeWidth: root.showGauges ? Style.space(3) : 0
      readonly property int gaugeGap: root.showGauges ? Style.space(3) : 0
      readonly property int dividerWidth: Style.space(3)
      // The local lane gets a quarter of the strip, never a third. It is a
      // supporting instrument: the cloud agents are what costs money.
      readonly property real localWidth: root.showLocal ? Math.round(width * 0.25) : 0
      readonly property int ruleWidth: root.showLocal ? Style.space(4) : 0
      readonly property int grokSep: Style.space(2)
      readonly property bool showDivider: (root.showClaude && root.showCodex) || root.grokAsRight
      readonly property int gaugeCount: root.showGauges ? root.cloudAgents : 0
      readonly property real gaugesSpace: gaugeCount * (gaugeWidth + gaugeGap)
      readonly property real dividerSpace: showDivider ? dividerWidth : 0
      // `graph.grokSep`, qualified: the separator Item below is `id: grokSep`,
      // and an id outranks a property of the same name in scope resolution.
      // Unqualified, this bound an Item into a real and made the whole chain
      // below (inner → sideWidth → every lane width) NaN.
      readonly property real grokSepSpace: root.grokExtra ? graph.grokSep : 0
      readonly property real kimiSepSpace: root.kimiExtra ? graph.grokSep : 0
      readonly property real inner: Math.max(1, width - localWidth - ruleWidth
        - gaugesSpace - dividerSpace - grokSepSpace - kimiSepSpace)
      readonly property real extraGrokW: root.grokExtra
        ? Math.max(Style.space(10), Math.round(inner * 0.16)) : 0
      // Kimi takes the same narrow band as Grok. Every term here is 0 while the
      // lane is hidden, so a strip without Kimi lays out exactly as before.
      readonly property real extraKimiW: root.kimiExtra
        ? Math.max(Style.space(10), Math.round(inner * 0.16)) : 0
      readonly property real pairInner: Math.max(1, inner - extraGrokW - extraKimiW)
      readonly property real sideWidth: root.cloudAgents <= 1 ? pairInner
        : Math.max(1, pairInner / 2)
      readonly property real claudeLaneWidth: !root.showClaude ? 0
        : root.cloudAgents === 1 ? pairInner : sideWidth
      readonly property real codexLaneWidth: !root.showCodex ? 0
        : root.cloudAgents === 1 ? pairInner : sideWidth
      readonly property real grokLaneWidth: !root.showGrok ? 0
        : root.cloudAgents === 1 ? pairInner
        : root.grokExtra ? extraGrokW
        : sideWidth
      readonly property real kimiLaneWidth: !root.showKimi ? 0
        : root.cloudAgents === 1 ? pairInner
        : root.kimiExtra ? extraKimiW
        : sideWidth

      // Zone spans, used for both the tinted plates and hit-testing. Derived
      // from the same numbers that lay the lanes out, so a plate can never
      // drift out from under the instrument it is naming.
      readonly property real claudeGaugeSpace: root.showGauges && root.showClaude ? gaugeWidth + gaugeGap : 0
      readonly property real codexGaugeSpace: root.showGauges && root.showCodex ? gaugeGap + gaugeWidth : 0
      readonly property real grokGaugeSpace: root.showGauges && root.showGrok ? gaugeGap + gaugeWidth : 0
      readonly property real kimiGaugeSpace: root.showGauges && root.showKimi ? gaugeGap + gaugeWidth : 0
      readonly property real claudeZoneWidth:
        claudeGaugeSpace + claudeLaneWidth + (showDivider ? dividerWidth / 2 : 0)
      readonly property real codexZoneWidth:
        (showDivider ? dividerWidth / 2 : 0) + codexLaneWidth + codexGaugeSpace
      readonly property real grokZoneStart: claudeZoneWidth + codexZoneWidth
      readonly property real grokZoneWidth:
        grokSepSpace + grokLaneWidth + grokGaugeSpace
      readonly property real kimiZoneStart: grokZoneStart + grokZoneWidth
      readonly property real kimiZoneWidth:
        kimiSepSpace + kimiLaneWidth + kimiGaugeSpace + ruleWidth / 2
      readonly property real localZoneStart: kimiZoneStart + kimiZoneWidth
      readonly property real localZoneWidth: Math.max(0, width - localZoneStart)

      function zoneAt(x) {
        if (root.showClaude && x < claudeZoneWidth) return root.zoneClaude
        if (root.showCodex && x < grokZoneStart) return root.zoneCodex
        if (root.showGrok && x < kimiZoneStart) return root.zoneGrok
        if (root.showKimi && (!root.showLocal || x < localZoneStart)) return root.zoneKimi
        if (root.showLocal) return root.zoneLocal
        if (root.showKimi) return root.zoneKimi
        if (root.showGrok) return root.zoneGrok
        if (root.showCodex) return root.zoneCodex
        return root.showClaude ? root.zoneClaude : root.zoneNone
      }

      // Tinted plates: the cheapest possible answer to "where does Claude end
      // and Codex begin". Always faintly on, so the three sections are legible
      // at a glance; brighter under the pointer, so hovering confirms which one
      // the tooltip is talking about.
      Repeater {
        model: [
          { zone: root.zoneClaude, from: 0, span: graph.claudeZoneWidth, on: root.showClaude },
          { zone: root.zoneCodex, from: graph.claudeZoneWidth, span: graph.codexZoneWidth, on: root.showCodex },
          { zone: root.zoneGrok, from: graph.grokZoneStart, span: graph.grokZoneWidth, on: root.showGrok },
          { zone: root.zoneKimi, from: graph.kimiZoneStart, span: graph.kimiZoneWidth, on: root.showKimi },
          { zone: root.zoneLocal, from: graph.localZoneStart, span: graph.localZoneWidth, on: root.showLocal }
        ]
        delegate: Item {
          required property var modelData
          visible: modelData.on && modelData.span > 0
          x: modelData.from
          width: modelData.span
          height: graph.height + Style.spaceReal(4)
          anchors.verticalCenter: parent.verticalCenter

          readonly property bool hovered: root.hoverZone === modelData.zone
          readonly property color accent: root.zoneAccent(modelData.zone)

          Rectangle {
            anchors.fill: parent
            radius: Style.spaceReal(3)
            color: parent.accent
            border.width: 0
            opacity: parent.hovered ? 0.16 : 0.055
            Behavior on opacity { NumberAnimation { duration: 160 } }
          }

          // Identity baseline. Three different colours sitting on the same
          // floor is what turns one strip into three labelled sections.
          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - Style.spaceReal(3)
            height: Style.spaceReal(1.5)
            radius: height / 2
            color: parent.accent
            border.width: 0
            opacity: parent.hovered ? 1.0 : 0.45
            Behavior on opacity { NumberAnimation { duration: 160 } }
          }
        }
      }

      // Claude weekly fuel gauge, far left, outermost.
      QuotaGauge {
        id: claudeGauge
        visible: root.showGauges && root.showClaude
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.claudeWeekly) : -1
        ratio: root.svc && root.svc.claudeWeeklyPace ? Number(root.svc.claudeWeeklyPace.ratio) : -1
        elapsed: root.svc && root.svc.claudeWeeklyPace ? Number(root.svc.claudeWeeklyPace.elapsed) : -1
        accent: root.claudeHot
      }

      ThermalLane {
        id: claudeLane
        visible: root.showClaude
        width: graph.claudeLaneWidth
        height: parent.height
        anchors.left: claudeGauge.right
        anchors.leftMargin: claudeGauge.visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.claudeCold; warm: root.claudeWarm; hot: root.claudeHot
        newestLast: true
        flash: root.claudeFlash
        phaseSign: 1
        levelAt: function(i) { return root.claudeLevel(i) }
      }

      // ── the now line ────────────────────────────────────────────────────────
      Item {
        id: divider
        visible: graph.showDivider
        width: graph.showDivider ? graph.dividerWidth : 0
        height: parent.height
        anchors.left: claudeLane.right
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(1.5)
          height: parent.height + Style.spaceReal(3)
          radius: width / 2
          color: root.bar ? root.bar.barForeground : Color.foreground
          border.width: 0
          opacity: 0.38 + 0.55 * Math.max(root.claudeFlash, root.codexFlash)
        }

        // Filament caps: two bright points that mark the exact instant of now.
        Repeater {
          model: 2
          delegate: Rectangle {
            required property int index
            width: Style.spaceReal(2.5)
            height: width
            radius: width / 2
            anchors.horizontalCenter: parent.horizontalCenter
            y: index === 0 ? -Style.spaceReal(2) : parent.height - height + Style.spaceReal(2)
            color: root.energyColor
            border.width: 0
            opacity: 0.35 + 0.5 * root.energy
            scale: 1 + 0.6 * Math.max(root.claudeFlash, root.codexFlash)
          }
        }

        // Impact rings: one flick outward per side when new burn lands.
        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(3) + root.claudeFlash * Style.spaceReal(10)
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.spaceReal(1)
          border.color: root.claudeHot
          opacity: root.claudeFlash * 0.85
        }
        Rectangle {
          anchors.centerIn: parent
          width: Style.spaceReal(3) + root.codexFlash * Style.spaceReal(10)
          height: width
          radius: width / 2
          color: "transparent"
          border.width: Style.spaceReal(1)
          border.color: root.codexHot
          opacity: root.codexFlash * 0.85
        }
      }

      ThermalLane {
        id: codexLane
        visible: root.showCodex
        width: graph.codexLaneWidth
        height: parent.height
        anchors.left: divider.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.codexCold; warm: root.codexWarm; hot: root.codexHot
        newestLast: root.cloudAgents === 1
        flash: root.codexFlash
        phaseSign: -1
        levelAt: function(i) { return root.codexLevel(i) }
      }

      // Shockwaves: a bright band that rides outward from the now line along
      // each lane when that agent lands new burn. This is the movement you see
      // from the corner of your eye; it means tokens just left the building.
      Rectangle {
        id: claudeWave
        visible: root.claudeFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.claudeHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: claudeLane.x + claudeLane.width * (1 - root.claudeWave) - width / 2
        opacity: root.claudeFlash * 0.55
      }
      Rectangle {
        id: codexWave
        visible: root.codexFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.codexHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: codexLane.x + codexLane.width * root.codexWave - width / 2
        opacity: root.codexFlash * 0.55
      }

      // Codex weekly fuel gauge, the right bookend of the mirrored pair.
      QuotaGauge {
        id: codexGauge
        visible: root.showGauges && root.showCodex
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: codexLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.codexWeekly) : -1
        ratio: root.svc && root.svc.codexWeeklyPace ? Number(root.svc.codexWeeklyPace.ratio) : -1
        elapsed: root.svc && root.svc.codexWeeklyPace ? Number(root.svc.codexWeeklyPace.elapsed) : -1
        accent: root.codexHot
      }

      // Soft sep before Grok so the mirrored Claude/Codex instrument stays whole.
      Item {
        id: grokSeparator
        visible: root.grokExtra
        width: root.grokExtra ? graph.grokSep : 0
        height: parent.height
        anchors.left: codexGauge.right
        anchors.verticalCenter: parent.verticalCenter
        Rectangle {
          anchors.centerIn: parent
          width: 1
          height: parent.height * 0.7
          color: root.grokHot
          border.width: 0
          opacity: 0.28
        }
      }

      ThermalLane {
        id: grokLane
        visible: root.showGrok
        width: graph.grokLaneWidth
        height: parent.height
        anchors.left: grokSeparator.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.grokCold; warm: root.grokWarm; hot: root.grokHot
        newestLast: true
        flash: root.grokFlash
        phaseSign: 1
        levelAt: function(i) { return root.grokLevel(i) }
      }

      Item {
        id: kimiSeparator
        visible: root.kimiExtra
        width: root.kimiExtra ? graph.grokSep : 0
        height: parent.height
        anchors.left: root.showGauges && root.showGrok ? grokGauge.right : grokLane.right
        anchors.verticalCenter: parent.verticalCenter
      }

      ThermalLane {
        id: kimiLane
        visible: root.showKimi
        width: graph.kimiLaneWidth
        height: parent.height
        anchors.left: kimiSeparator.right
        anchors.verticalCenter: parent.verticalCenter
        count: root.cellCount
        cold: root.kimiCold; warm: root.kimiWarm; hot: root.kimiHot
        newestLast: true
        flash: root.kimiFlash
        phaseSign: 1
        levelAt: function(i) { return root.kimiLevel(i) }
      }

      QuotaGauge {
        id: kimiGauge
        visible: root.showGauges && root.showKimi
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: kimiLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        // The monthly credit pool is the one that runs out; the 5-hour window
        // refills on its own. -1 when it has not been read, never a false 0%.
        percent: root.svc ? root.svc.kimiMonthly : -1
        ratio: root.svc && root.svc.kimiMonthlyPace ? Number(root.svc.kimiMonthlyPace.ratio) : -1
        elapsed: root.svc && root.svc.kimiMonthlyPace ? Number(root.svc.kimiMonthlyPace.elapsed) : -1
        accent: root.kimiHot
      }

      Rectangle {
        id: grokWave
        visible: root.grokFlash > 0.01
        width: Style.spaceReal(3)
        height: graph.height
        radius: width / 2
        color: root.grokHot
        border.width: 0
        anchors.verticalCenter: parent.verticalCenter
        x: grokLane.x + grokLane.width * root.grokWave - width / 2
        opacity: root.grokFlash * 0.55
      }

      QuotaGauge {
        id: grokGauge
        visible: root.showGauges && root.showGrok
        width: visible ? graph.gaugeWidth : 0
        height: parent.height
        anchors.left: grokLane.right
        anchors.leftMargin: visible ? graph.gaugeGap : 0
        anchors.verticalCenter: parent.verticalCenter
        percent: root.svc ? Math.min(1, root.svc.grokWeekly) : -1
        ratio: root.svc && root.svc.grokWeeklyPace ? Number(root.svc.grokWeeklyPace.ratio) : -1
        elapsed: root.svc && root.svc.grokWeeklyPace ? Number(root.svc.grokWeeklyPace.elapsed) : -1
        accent: root.grokHot
      }

      // ── the hard rule ───────────────────────────────────────────────────────
      // Everything left of this line is metered cloud spend in tokens per
      // bucket. Everything right of it is free local compute in percent per
      // second. Different money, different clock, different scale, so they get
      // a wall between them rather than a gap you might read as a pause.
      Item {
        id: localRule
        visible: root.showLocal
        width: graph.ruleWidth
        height: parent.height
        // After the LAST cloud lane. Kimi is laid out after Grok, so anchoring
        // here to Grok alone painted the local lane over Kimi's cells whenever
        // both were on, while the tooltip still named Kimi.
        anchors.left: root.showKimi ? (root.showGauges ? kimiGauge.right : kimiLane.right)
          : (root.showGauges ? grokGauge.right : grokLane.right)
        anchors.verticalCenter: parent.verticalCenter

        Rectangle {
          anchors.centerIn: parent
          width: 1
          height: parent.height + Style.spaceReal(4)
          color: root.bar ? root.bar.barForeground : Color.foreground
          border.width: 0
          opacity: 0.22
        }
      }

      // ── local intelligence lane ─────────────────────────────────────────────
      Item {
        id: localZone
        visible: root.showLocal
        width: graph.localWidth
        height: parent.height
        anchors.left: localRule.right
        anchors.verticalCenter: parent.verticalCenter

        readonly property color state: !root.localOnline ? root.urgent
          : root.localActive ? root.localHot : root.okGreen
        readonly property real core: Math.max(Style.spaceReal(4),
          Math.min(width * 0.34, parent.height * 0.62))

        // Reactor core: the one glyph in the widget, and the only thing that
        // can say "offline" out loud. Red ring means Ollama is not answering;
        // green means it is warm and waiting; violet means it is thinking.
        Item {
          id: reactor
          width: localZone.core
          height: width
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter

          // Halo: pushed out by inference load, so the core visibly inflates
          // when a local model is chewing.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * (1.05 + 0.45 * Math.min(1, root.localLoad / 100))
            height: width
            radius: width / 2
            color: localZone.state
            border.width: 0
            opacity: root.localActive ? 0.30 : 0.14
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 240 } }
          }

          Rectangle {
            id: coreDot
            anchors.centerIn: parent
            width: parent.width * 0.66
            height: width
            radius: width / 2
            color: localZone.state
            border.width: 0
            Behavior on color { ColorAnimation { duration: 260 } }

            // Both beats are gated on the lane actually being shown, and each
            // property sits at rest whenever its beat is off.
            readonly property bool throbbing: root.localActive && root.visible && root.showLocal
            scale: throbbing ? root.pulse(960, 0.94, 1.16) : 1
            readonly property PulseTicket throbTicket: PulseTicket { active: coreDot.throbbing }
            // Offline is a fault, and faults strobe rather than breathe.
            readonly property bool strobing: !root.localOnline && root.visible && root.showLocal
            opacity: strobing ? root.pulse(1240, 1.0, 0.25) : 1
            readonly property PulseTicket strobeTicket: PulseTicket { active: coreDot.strobing }
          }

          // Hollow centre, so the core reads as a reactor and not a dot.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * 0.28
            height: width
            radius: width / 2
            color: root.bar ? root.bar.background : Color.background
            border.width: 0
            opacity: 0.9
          }

          // Ignition ring on a load surge.
          Rectangle {
            anchors.centerIn: parent
            width: parent.width * (0.7 + root.localFlash * 1.5)
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Style.spaceReal(1)
            border.color: root.localHot
            opacity: root.localFlash * 0.9
          }
        }

        ThermalLane {
          id: localLane
          anchors.left: reactor.right
          anchors.leftMargin: Style.spaceReal(2)
          anchors.right: parent.right
          height: parent.height
          anchors.verticalCenter: parent.verticalCenter
          count: root.localCells
          cold: root.localCold; warm: root.localWarm; hot: root.localHot
          newestLast: false
          flash: root.localFlash
          phaseSign: -1
          faulted: false
          // Offline drops the lane to nothing rather than freezing the last
          // reading, which would be a lie that looks like data.
          levelAt: function(i) { return root.localOnline ? root.localLevel(i) : 0 }
        }
      }

      // ── sparks ──────────────────────────────────────────────────────────────
      // Embers lifting off the strip. Count is fixed; visibility, speed and
      // brightness all ride on total energy, so an idle machine emits nothing
      // and a hammered one throws a column of them. GPU-side animations, so
      // this costs no property churn on the QML side.
      Repeater {
        model: root.sparks ? 7 : 0
        delegate: Rectangle {
          id: spark
          required property int index

          readonly property real seed: (index * 0.37) % 1
          width: Style.spaceReal(1)
          height: width
          radius: width / 2
          color: index % 3 === 0 ? root.whiteHot : root.energyColor
          border.width: 0
          x: graph.width * (0.10 + 0.80 * seed)
          visible: root.energy > 0.12 && !root.broken
          opacity: 0

          SequentialAnimation {
            running: spark.visible && root.visible
            loops: Animation.Infinite
            PauseAnimation { duration: Math.round(120 + spark.seed * 1600) }
            ParallelAnimation {
              NumberAnimation {
                target: spark; property: "y"
                from: graph.height * 0.62; to: -graph.height * 0.30
                // Each spark rises at its own rate. Identical durations made all
                // seven re-sync into one visible pulse, which read as a loop.
                duration: Math.round((1300 + spark.seed * 1400) - 600 * root.energy)
                easing.type: Easing.OutQuad
              }
              SequentialAnimation {
                NumberAnimation {
                  target: spark; property: "opacity"; to: 0.30 + 0.55 * root.energy
                  duration: 160
                }
                NumberAnimation { target: spark; property: "opacity"; to: 0; duration: 900 }
              }
            }
          }
        }
      }
    }

    // ── zone hover ──────────────────────────────────────────────────────────
    // Buttons only ever carry one tooltip, and this widget is three
    // instruments, so the pointer is read here and the bar's tooltip is driven
    // by hand with whatever lane the cursor is actually over. Clicks are not
    // accepted, so they fall straight through to the button underneath.
    MouseArea {
      id: zoneHover
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
      onPositionChanged: root.updateZone(mouseX)
      onEntered: root.updateZone(mouseX)
      onExited: {
        root.hoverZone = root.zoneNone
        if (root.bar) root.bar.hideTooltip(root)
      }
    }

    onPressed: function(code) {
      // The button hides its own tooltip on press, but ours is registered
      // against the widget, so it has to be dismissed by hand or it hangs over
      // the panel that just opened. Clearing the zone re-arms the next hover.
      if (root.bar) root.bar.hideTooltip(root)
      root.hoverZone = root.zoneNone
      if (code === Qt.MiddleButton) { if (root.svc) { root.svc.refreshLimits(); root.svc.collect(); root.svc.pollLocal() } }
      else if (code === Qt.RightButton) {
        // Right click answers the warning and nothing else. Choosing what the
        // strip shows moved to SETUP in the cockpit (Fred, 2026-09-20), where
        // every option lives together instead of hiding behind a button most
        // people never press.
        root.acknowledgePace()
      }
      else {
        // The click that opens the cockpit is also the answer to whatever the
        // strip was warning about: you looked, so it stops shouting until the
        // next stage.
        root.acknowledgePace()
        root.toggleCockpit()
      }
    }
  }

  readonly property bool opened: panel.opened
  function open() { panel.controller.show(); if (svc) { svc.refreshLimits(); svc.collect(); svc.pollLocal() } }
  function close() { panel.controller.hide() }
  function toggle() { opened ? close() : open() }
  // Left click is always the cockpit, even if SETUP was the last thing open.
  function toggleCockpit() {
    if (opened && panel.mode === "cockpit") { close(); return }
    panel.mode = "cockpit"
    if (!opened) open()
  }
  // SETUP is a page of the cockpit, reached from its own button.
  function openSetup() {
    panel.mode = "setup"
    if (!opened) open()
  }
  function closeForPopoutSwitch() { close() }
  readonly property bool popoutSwitchClosing: false

  BurnPanel {
    id: panel
    widget: root
  }
}
