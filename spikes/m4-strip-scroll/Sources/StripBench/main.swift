import AppKit
import QuartzCore
import Foundation
import IOKit.pwr_mgt
import CoreGraphics

let mainEntryEpoch = Date().timeIntervalSince1970
let procStartEpoch = processStartEpoch()

// MARK: - CLI

struct Options {
    var variant = "recycled"      // naive | recycled | collection
    var lanes = 150
    var screenIndex = 0
    var velocity: CGFloat = 6000  // pt/s
    var idleSeconds = 60.0
    var buffer = 2
    var out = "results.json"
    var fullscreen = true
    var fsMode = "borderless"   // borderless | native | none
    var forceDisplay = true
    var settle = 2.0
}

func parseArgs() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    while let k = a.first {
        a.removeFirst()
        func val() -> String { let v = a.first ?? ""; if !a.isEmpty { a.removeFirst() }; return v }
        switch k {
        case "--variant": o.variant = val()
        case "--lanes": o.lanes = Int(val()) ?? 150
        case "--screen": o.screenIndex = Int(val()) ?? 0
        case "--velocity": o.velocity = CGFloat(Double(val()) ?? 6000)
        case "--idle-seconds": o.idleSeconds = Double(val()) ?? 60
        case "--buffer": o.buffer = Int(val()) ?? 2
        case "--out": o.out = val()
        case "--settle": o.settle = Double(val()) ?? 2.0
        case "--fs-mode": o.fsMode = val()
        case "--force-display": o.forceDisplay = true
        case "--no-force-display": o.forceDisplay = false
        case "--no-fullscreen": o.fullscreen = false; o.fsMode = "none"
        default: break
        }
    }
    return o
}

let opts = parseArgs()

// Keep the panel awake for the whole run and declare user activity so a
// sleeping display actually lights up; a blanked display would make every
// frame-timing number meaningless.
var noSleepAssertion: IOPMAssertionID = 0
var userActivityAssertion: IOPMAssertionID = 0
func assertDisplayAwake() {
    IOPMAssertionCreateWithName("NoDisplaySleepAssertion" as CFString,
                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                "StripBench M4" as CFString, &noSleepAssertion)
    IOPMAssertionDeclareUserActivity("StripBench M4" as CFString,
                                     kIOPMUserActiveLocal, &userActivityAssertion)
}
func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }

/// True when the login window is covering the session, in which case the
/// window server does not composite our window and frame timing only
/// reflects main-thread work, not GPU compositing.
func screenIsLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Int) == 1
}

let logPath = opts.out + ".log"
func elog(_ m: String) {
    let line = "[bench +\(String(format: "%.2f", Date().timeIntervalSince1970 - mainEntryEpoch))s] " + m + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    if let d = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: logPath) { fh.seekToEndOfFile(); fh.write(d); try? fh.close() }
        else { try? d.write(to: URL(fileURLWithPath: logPath)) }
    }
}

// MARK: - Result model

struct ScreenInfo: Encodable {
    var index: Int
    var name: String
    var pointSize: [Double]
    var backingScale: Double
    var maximumFramesPerSecond: Int
    var minimumRefreshInterval: Double
    var maximumRefreshInterval: Double
}

struct FrameSample {
    var phase: String
    var ts: Double        // CADisplayLink vsync timestamp
    var dt: Double        // ms since previous callback
    var work: Double      // ms spent inside our callback
    var layoutCalls: Int  // LaneView.layout() calls attributed to this frame
    var live: Int         // attached lane views
}

struct PhaseResult: Encodable {
    var frames: Int
    var durationSeconds: Double
    var intervalMs: Stats
    var workMs: Stats
    var droppedFrames: Int
    var droppedPct: Double
    var severeDrops: Int          // dt > 2.5x budget
    var layoutCallsTotal: Int
    var layoutCallsPerFrameMean: Double
    var layoutCallsPerFrameMax: Int
    var peakLiveLaneViews: Int
    var scrollXStart: Double
    var scrollXEnd: Double
    var scrollXMax: Double
}

struct EventResult: Encodable {
    var kind: String
    var frameIndex: Int
    var atLaneIndex: Int
    var frameIntervalMs: Double
    var workMs: Double
    var maxIntervalNext10Ms: Double
    var layoutCallsThisFrame: Int
    var visibleHitch: Bool
}

struct RestoreResult: Encodable {
    var requested: Double
    var afterSet: Double
    var afterRebuildRestore: Double
    var exact: Bool
}

struct Results: Encodable {
    var variant: String
    var lanes: Int
    var recyclingBuffer: Int
    var velocityPtPerSec: Double
    var os: String
    var swift: String
    var screens: [ScreenInfo]
    var windowScreen: String
    var windowScreenMaxFPS: Int
    var displayLinkNominalIntervalMs: Double
    var frameBudgetMs: Double
    var fullscreenMode: String
    var windowCoversScreen: Bool
    var windowLevel: Int
    var fullscreen: Bool
    var appActive: Bool
    var windowVisibleOcclusion: Bool
    var requestedFrameRateHz: Double
    var framesWindowNotVisible: Int
    var framesDisplayAsleep: Int
    var framesScreenLocked: Int
    var screenLockedAtStart: Bool
    var screenLockedAtEnd: Bool
    var forceDisplayEachFrame: Bool
    var framesAppInactive: Int
    var totalMeasuredFrames: Int
    var laneWidthMeanPt: Double
    var laneWidthMinPt: Double
    var laneWidthMaxPt: Double
    var stripContentWidthPt: Double
    var viewportWidthPt: Double
    var viewportHeightPt: Double
    var ttiFromExecMs: Double
    var ttiFromMainEntryMs: Double
    var fullscreenTransitionMs: Double
    var rssAtRestBytes: UInt64
    var physFootprintAtRestBytes: UInt64
    var rssAfterScrollBytes: UInt64
    var physFootprintAfterScrollBytes: UInt64
    var laneViewsInstantiatedTotal: Int
    var laneConfiguresTotal: Int
    var collectionItemsInstantiated: Int
    var updateConstraintsTotal: Int
    var peakLiveLaneViews: Int
    var cleanScroll: PhaseResult
    var perturbScroll: PhaseResult
    var events: [EventResult]
    var idleCpuSamplesPctOfOneCore: [Double]
    var idleCpuMeanPct: Double
    var idleCpuMaxPct: Double
    var idleSeconds: Double
    var idleRssBytes: UInt64
    var restore: [RestoreResult]
}

// MARK: - Bench

final class Bench: NSObject {
    let window: NSWindow
    var strip: Strip
    let widths: [CGFloat]
    var link: CADisplayLink?

    enum Phase: String { case settle, clean, gap, perturb, idle, done }
    var phase: Phase = .settle
    var phaseStart: Double = 0
    var frames: [FrameSample] = []
    var lastTs: Double = 0
    var lastLayoutCount = 0
    var events: [EventResult] = []
    var peakLive = 0
    var framesNotVisible = 0
    var framesDisplayAsleep = 0
    var framesLocked = 0
    var lockedAtStart = false
    var framesAppInactive = 0
    var requestedFrameRate: Double = 0

    var frameBudget: Double = 1.0 / 60.0
    var nominalInterval: Double = 0

    var ttiFromExec: Double = 0
    var ttiFromMain: Double = 0
    var fsTransitionMs: Double = 0
    var rssAtRest: UInt64 = 0
    var footprintAtRest: UInt64 = 0
    var rssAfterScroll: UInt64 = 0
    var footprintAfterScroll: UInt64 = 0
    var idleSamples: [Double] = []
    var idleRss: UInt64 = 0
    var restoreResults: [RestoreResult] = []

    // scripted scroll state
    var scrollDirection: CGFloat = 1
    var scrollPos: CGFloat = 0
    var cleanLegsDone = 0
    var perturbInsertDone = false
    var perturbResizeDone = false
    var perturbStartX: CGFloat = 0

    init(window: NSWindow, strip: Strip, widths: [CGFloat]) {
        self.window = window
        self.strip = strip
        self.widths = widths
        super.init()
    }

    func startLink() {
        guard link == nil, let cv = window.contentView else { return }
        elog("starting display link")
        let l = cv.displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Float((window.screen ?? NSScreen.main!).maximumFramesPerSecond)
        l.preferredFrameRateRange = CAFrameRateRange(minimum: fps, maximum: fps, preferred: fps)
        requestedFrameRate = Double(fps)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stopLink() { link?.invalidate(); link = nil }

    func beginPhase(_ p: Phase) {
        elog("phase -> \(p.rawValue)")
        phase = p
        phaseStart = CACurrentMediaTime()
        lastTs = 0
    }

    @objc func tick(_ l: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        if nominalInterval == 0 {
            nominalInterval = l.duration > 0 ? l.duration : frameBudget
        }
        let ts = l.timestamp
        let dt = lastTs == 0 ? nominalInterval : (ts - lastTs)
        lastTs = ts
        let elapsed = t0 - phaseStart

        var eventThisFrame: (String, Int)? = nil

        switch phase {
        case .settle:
            if elapsed >= opts.settle {
                rssAtRest = residentBytes()
                footprintAtRest = physFootprintBytes()
                scrollPos = 0
                strip.setScrollX(0)
                scrollDirection = 1
                cleanLegsDone = 0
                frames.removeAll()
                Counters.laneLayoutCalls = 0
                lastLayoutCount = 0
                beginPhase(.clean)
            }
        case .clean:
            advanceScroll(dt: dt)
            if cleanLegsDone >= 2 {
                rssAfterScroll = residentBytes()
                footprintAfterScroll = physFootprintBytes()
                finishPhase(.clean)
                beginPhase(.gap)
                return
            }
        case .gap:
            if elapsed >= 1.0 {
                // start perturb pass around lane 60
                let startLane = min(60, strip.widths.count - 1)
                perturbStartX = (0..<startLane).reduce(CGFloat(0)) { $0 + strip.widths[$1] + LANE_GAP }
                scrollPos = perturbStartX
                strip.setScrollX(scrollPos)
                scrollDirection = 1
                frames.removeAll()
                Counters.laneLayoutCalls = 0
                lastLayoutCount = 0
                beginPhase(.perturb)
            }
        case .perturb:
            advanceScroll(dt: dt, clampLoop: false)
            if elapsed >= 3.0 && !perturbInsertDone {
                perturbInsertDone = true
                let idx = min(strip.laneIndex(atX: strip.scrollX) + 3, strip.widths.count - 1)
                strip.insertLane(at: idx, width: 640)
                eventThisFrame = ("insert-mid-strip", idx)
            } else if elapsed >= 7.0 && !perturbResizeDone {
                perturbResizeDone = true
                let idx = min(strip.laneIndex(atX: strip.scrollX) + 2, strip.widths.count - 1)
                let neww = min(CGFloat(900), strip.widths[idx] + 220)
                strip.resizeLane(at: idx, to: neww)
                eventThisFrame = ("resize-mid-scroll", idx)
            }
            if elapsed >= 11.0 {
                finishPhase(.perturb)
                stopLink()
                beginIdle()
                return
            }
        default:
            return
        }

        let layoutNow = Counters.laneLayoutCalls
        let layoutDelta = layoutNow - lastLayoutCount
        lastLayoutCount = layoutNow
        let live = strip.liveLaneViewCount
        peakLive = max(peakLive, live)
        if !window.occlusionState.contains(.visible) { framesNotVisible += 1 }
        if displayAsleep() { framesDisplayAsleep += 1 }
        if screenIsLocked() { framesLocked += 1 }
        if !NSApp.isActive { framesAppInactive += 1 }
        let work = (CACurrentMediaTime() - t0) * 1000.0
        frames.append(FrameSample(phase: phase.rawValue, ts: ts, dt: dt * 1000.0,
                                  work: work, layoutCalls: layoutDelta, live: live))

        if let (kind, lane) = eventThisFrame {
            eventLog.append((kind: kind, lane: lane, frameIdx: frames.count - 1,
                             dt: dt * 1000.0, work: work, layout: layoutDelta))
        }
    }

    private func advanceScroll(dt: Double, clampLoop: Bool = true) {
        let step = opts.velocity * CGFloat(dt)
        scrollPos += step * scrollDirection
        let maxX = strip.maxScrollX
        if clampLoop {
            if scrollPos >= maxX { scrollPos = maxX; scrollDirection = -1; cleanLegsDone += 1 }
            if scrollPos <= 0 && scrollDirection < 0 { scrollPos = 0; scrollDirection = 1; cleanLegsDone += 1 }
        } else {
            scrollPos = max(0, min(scrollPos, maxX))
        }
        strip.setScrollX(scrollPos)
        if opts.forceDisplay { window.contentView?.displayIfNeeded() }
    }

    var cleanResult: PhaseResult?
    var perturbResult: PhaseResult?

    private func finishPhase(_ p: Phase) {
        let f = frames
        let r = summarize(f)
        if p == .clean { cleanResult = r } else { perturbResult = r }
        if p == .perturb { materializeEvents(f) }
    }

    private func materializeEvents(_ f: [FrameSample]) {
        // Re-scan for both events using stored pendingEvent history
        for e in eventLog {
            let next = f.indices.contains(e.frameIdx + 1)
                ? Array(f[(e.frameIdx + 1)...min(e.frameIdx + 10, f.count - 1)]) : []
            let maxNext = next.map(\.dt).max() ?? 0
            let hitch = e.dt > frameBudget * 1000 * 1.5 || maxNext > frameBudget * 1000 * 1.5
            events.append(EventResult(kind: e.kind, frameIndex: e.frameIdx, atLaneIndex: e.lane,
                                      frameIntervalMs: e.dt, workMs: e.work,
                                      maxIntervalNext10Ms: maxNext,
                                      layoutCallsThisFrame: e.layout, visibleHitch: hitch))
        }
    }

    var eventLog: [(kind: String, lane: Int, frameIdx: Int, dt: Double, work: Double, layout: Int)] = []

    private func summarize(_ f: [FrameSample]) -> PhaseResult {
        // Drop the first frame of the phase (no previous timestamp).
        let s = f.count > 1 ? Array(f.dropFirst()) : f
        let dts = s.map(\.dt)
        let budgetMs = frameBudget * 1000
        let dropped = dts.filter { $0 > budgetMs * 1.5 }.count
        let severe = dts.filter { $0 > budgetMs * 2.5 }.count
        let layouts = s.map(\.layoutCalls)
        let dur = (s.last.map(\.ts) ?? 0) - (s.first.map(\.ts) ?? 0)
        return PhaseResult(
            frames: s.count,
            durationSeconds: dur,
            intervalMs: Stats(dts),
            workMs: Stats(s.map(\.work)),
            droppedFrames: dropped,
            droppedPct: s.isEmpty ? 0 : Double(dropped) / Double(s.count) * 100,
            severeDrops: severe,
            layoutCallsTotal: layouts.reduce(0, +),
            layoutCallsPerFrameMean: s.isEmpty ? 0 : Double(layouts.reduce(0, +)) / Double(s.count),
            layoutCallsPerFrameMax: layouts.max() ?? 0,
            peakLiveLaneViews: s.map(\.live).max() ?? 0,
            scrollXStart: 0, scrollXEnd: Double(strip.scrollX), scrollXMax: Double(strip.maxScrollX))
    }

    // MARK: idle

    var idleTimer: Timer?
    var idleLastCpu: Double = 0
    var idleLastWall: Double = 0

    func beginIdle() {
        elog("idle phase start")
        phase = .idle
        idleLastCpu = cpuSeconds()
        idleLastWall = CACurrentMediaTime()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { return }
            let c = cpuSeconds(), w = CACurrentMediaTime()
            let pct = (c - self.idleLastCpu) / (w - self.idleLastWall) * 100.0
            self.idleLastCpu = c; self.idleLastWall = w
            self.idleSamples.append(pct)
            if Double(self.idleSamples.count) >= opts.idleSeconds {
                t.invalidate()
                self.idleRss = residentBytes()
                self.runRestoreTest()
                self.finish()
            }
        }
        RunLoop.main.add(idleTimer!, forMode: .common)
    }

    // MARK: restore

    func runRestoreTest() {
        elog("restore test")
        let targets: [CGFloat] = [12345.0, 21734.25, strip.maxScrollX]
        for t in targets {
            strip.setScrollX(t)
            window.contentView?.layoutSubtreeIfNeeded()
            let afterSet = strip.scrollX
            // Tear down and rebuild the strip, then restore the saved offset.
            strip.teardown()
            window.contentView?.layoutSubtreeIfNeeded()
            strip.build(widths: widths)
            window.contentView?.layoutSubtreeIfNeeded()
            strip.setScrollX(afterSet)
            window.contentView?.layoutSubtreeIfNeeded()
            let restored = strip.scrollX
            restoreResults.append(RestoreResult(requested: Double(t), afterSet: Double(afterSet),
                                                afterRebuildRestore: Double(restored),
                                                exact: restored == afterSet))
        }
    }

    func finish() {
        elog("finish")
        let screens = NSScreen.screens.enumerated().map { (i, s) in
            ScreenInfo(index: i, name: s.localizedName,
                       pointSize: [Double(s.frame.width), Double(s.frame.height)],
                       backingScale: Double(s.backingScaleFactor),
                       maximumFramesPerSecond: s.maximumFramesPerSecond,
                       minimumRefreshInterval: s.minimumRefreshInterval,
                       maximumRefreshInterval: s.maximumRefreshInterval)
        }
        let ws = window.screen ?? NSScreen.main
        let ws2 = ws ?? NSScreen.screens[0]
        let clip = strip.scrollView.contentView.bounds
        let collectionItems = (strip as? CollectionStrip).map { _ in Counters.itemInstantiations } ?? 0
        let peakFromStrip = (strip as? RecycledStrip)?.peakLive ?? ((strip as? CollectionStrip)?.peakLive ?? peakLive)

        let r = Results(
            variant: opts.variant,
            lanes: opts.lanes,
            recyclingBuffer: opts.buffer,
            velocityPtPerSec: Double(opts.velocity),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            swift: "6.3.3",
            screens: screens,
            windowScreen: ws2.localizedName,
            windowScreenMaxFPS: ws2.maximumFramesPerSecond,
            displayLinkNominalIntervalMs: nominalInterval * 1000,
            frameBudgetMs: frameBudget * 1000,
            fullscreenMode: opts.fsMode,
            windowCoversScreen: window.frame == (window.screen ?? NSScreen.screens[0]).frame,
            windowLevel: window.level.rawValue,
            fullscreen: window.styleMask.contains(.fullScreen),
            appActive: NSApp.isActive,
            windowVisibleOcclusion: window.occlusionState.contains(.visible),
            requestedFrameRateHz: requestedFrameRate,
            framesWindowNotVisible: framesNotVisible,
            framesDisplayAsleep: framesDisplayAsleep,
            framesScreenLocked: framesLocked,
            screenLockedAtStart: lockedAtStart,
            screenLockedAtEnd: screenIsLocked(),
            forceDisplayEachFrame: opts.forceDisplay,
            framesAppInactive: framesAppInactive,
            totalMeasuredFrames: (cleanResult?.frames ?? 0) + (perturbResult?.frames ?? 0),
            laneWidthMeanPt: Double(widths.reduce(0,+)) / Double(widths.count),
            laneWidthMinPt: Double(widths.min() ?? 0),
            laneWidthMaxPt: Double(widths.max() ?? 0),
            stripContentWidthPt: Double(strip.contentWidth),
            viewportWidthPt: Double(clip.width),
            viewportHeightPt: Double(clip.height),
            ttiFromExecMs: ttiFromExec,
            ttiFromMainEntryMs: ttiFromMain,
            fullscreenTransitionMs: fsTransitionMs,
            rssAtRestBytes: rssAtRest,
            physFootprintAtRestBytes: footprintAtRest,
            rssAfterScrollBytes: rssAfterScroll,
            physFootprintAfterScrollBytes: footprintAfterScroll,
            laneViewsInstantiatedTotal: Counters.laneInstantiations,
            laneConfiguresTotal: Counters.laneConfigures,
            collectionItemsInstantiated: collectionItems,
            updateConstraintsTotal: Counters.laneUpdateConstraints,
            peakLiveLaneViews: max(peakLive, peakFromStrip),
            cleanScroll: cleanResult ?? summarize([]),
            perturbScroll: perturbResult ?? summarize([]),
            events: events,
            idleCpuSamplesPctOfOneCore: idleSamples,
            idleCpuMeanPct: idleSamples.isEmpty ? 0 : idleSamples.reduce(0,+)/Double(idleSamples.count),
            idleCpuMaxPct: idleSamples.max() ?? 0,
            idleSeconds: opts.idleSeconds,
            idleRssBytes: idleRss,
            restore: restoreResults)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(r) {
            try? data.write(to: URL(fileURLWithPath: opts.out))
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
        NSApp.terminate(nil)
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var bench: Bench!
    var window: NSWindow!
    var fsStart: Double = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        assertDisplayAwake()
        NSApp.setActivationPolicy(.regular)
        elog("display asleep at launch: \(displayAsleep())")

        let screens = NSScreen.screens
        let screen = screens.indices.contains(opts.screenIndex) ? screens[opts.screenIndex] : (NSScreen.main ?? screens[0])

        let borderless = (opts.fsMode == "borderless")
        window = NSWindow(contentRect: screen.frame,
                          styleMask: borderless ? [.borderless] : [.titled, .closable, .resizable],
                          backing: .buffered, defer: false, screen: screen)
        window.title = "M4 strip scroll · \(opts.variant)"
        window.collectionBehavior = [.fullScreenPrimary]
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = NSColor(white: 0.04, alpha: 1)

        let root = NSView(frame: screen.frame)
        root.wantsLayer = true
        window.contentView = root

        let widths = laneWidths(count: opts.lanes)
        let strip: Strip
        switch opts.variant {
        case "naive": strip = NaiveStrip()
        case "collection": strip = CollectionStrip()
        default: strip = RecycledStrip(buffer: opts.buffer)
        }
        let sv = strip.scrollView
        sv.frame = root.bounds
        sv.autoresizingMask = [.width, .height]
        root.addSubview(sv)
        root.layoutSubtreeIfNeeded()
        sv.layoutSubtreeIfNeeded()

        strip.build(widths: widths)
        root.layoutSubtreeIfNeeded()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.displayIfNeeded()

        elog("strip built, window shown")
        let ready = Date().timeIntervalSince1970
        bench = Bench(window: window, strip: strip, widths: widths)
        bench.ttiFromExec = (procStartEpoch.map { (ready - $0) * 1000 }) ?? -1
        bench.ttiFromMain = (ready - mainEntryEpoch) * 1000
        let fps = (window.screen ?? screen).maximumFramesPerSecond
        bench.frameBudget = 1.0 / Double(fps > 0 ? fps : 60)

        switch opts.fsMode {
        case "native":
            NotificationCenter.default.addObserver(self, selector: #selector(didEnterFS),
                                                   name: NSWindow.didEnterFullScreenNotification, object: window)
            fsStart = CACurrentMediaTime()
            // Watchdog: if the Spaces transition never completes, proceed anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if self.bench.link == nil && self.bench.phase == .settle {
                    elog("native fullscreen watchdog fired; proceeding windowed")
                    self.startBench()
                }
            }
            window.toggleFullScreen(nil)
        case "borderless":
            fsStart = CACurrentMediaTime()
            window.level = .floating
            window.setFrame(screen.frame, display: true)
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            bench.fsTransitionMs = (CACurrentMediaTime() - fsStart) * 1000
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startBench() }
        default:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.startBench() }
        }
    }

    @objc func didEnterFS() {
        elog("didEnterFullScreen")
        bench.fsTransitionMs = (CACurrentMediaTime() - fsStart) * 1000
        // Layout has changed size; let it settle one runloop turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startBench() }
    }

    var benchStarted = false
    func startBench() {
        if benchStarted { return }
        benchStarted = true
        elog("startBench; displayAsleep=\(displayAsleep()) appActive=\(NSApp.isActive) visible=\(window.occlusionState.contains(.visible)) screen=\(window.screen?.localizedName ?? "nil") fps=\((window.screen ?? NSScreen.main!).maximumFramesPerSecond)")
        window.contentView?.layoutSubtreeIfNeeded()
        if let r = bench.strip as? RecycledStrip { r.reconcile() }
        if let c = bench.strip as? CollectionStrip { c.layout.invalidateLayout(); c.collectionView.layoutSubtreeIfNeeded() }
        if let nStrip = bench.strip as? NaiveStrip { nStrip.resizeLane(at: 0, to: nStrip.widths[0]) }
        let fps = (window.screen ?? NSScreen.main!).maximumFramesPerSecond
        bench.frameBudget = 1.0 / Double(fps > 0 ? fps : 60)
        bench.lockedAtStart = screenIsLocked()
        elog("screen locked at bench start: \(bench.lockedAtStart)")
        bench.beginPhase(.settle)
        bench.startLink()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
