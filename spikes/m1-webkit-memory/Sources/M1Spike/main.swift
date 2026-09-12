import AppKit
import WebKit
import Foundation
import CProcInfo

// ============================================================================
// M1 spike: 100 WKWebViews in one WKProcessPool, 5 parented / 95 unparented.
// Measures: RSS + phys_footprint (app + every WebKit helper), WebContent
// process count, idle CPU, re-parent latency, and whether unparenting actually
// suspends rendering.
//
// Everything printed on a line starting with "M1 " is human-readable log;
// the machine-readable report is written to out/report-<mode>.json.
// ============================================================================

let ARGS = CommandLine.arguments
func argValue(_ name: String, _ def: String) -> String {
    if let i = ARGS.firstIndex(of: "--\(name)"), i + 1 < ARGS.count { return ARGS[i + 1] }
    return def
}
func argInt(_ name: String, _ def: Int) -> Int { Int(argValue(name, "\(def)")) ?? def }

let MODE        = argValue("mode", "fixtures")      // fixtures | real
let VIEW_COUNT  = argInt("views", 100)
let PARENTED    = argInt("parented", 5)
let IDLE_SECS   = argInt("idle-secs", 60)
let TRIALS      = argInt("trials", 25)
let LANE_W: CGFloat = CGFloat(argInt("lane-width", 560))
let LANE_H: CGFloat = CGFloat(argInt("lane-height", 1000))
let OUT_DIR     = argValue("out", FileManager.default.currentDirectoryPath + "/out")
let STAGES      = ([25, 50].filter { $0 < VIEW_COUNT } + [VIEW_COUNT])

let LOG_PATH = argValue("log", "")
var logHandle: FileHandle? = {
    guard !LOG_PATH.isEmpty else { return nil }
    FileManager.default.createFile(atPath: LOG_PATH, contents: nil)
    return FileHandle(forWritingAtPath: LOG_PATH)
}()
func log(_ s: String) {
    let t = String(format: "%8.2f", ProcessInfo.processInfo.systemUptime - startUptime)
    let line = "M1 [\(t)s] \(s)"
    print(line)
    fflush(stdout)
    if let h = logHandle, let d = (line + "\n").data(using: .utf8) { h.write(d) }
}
let startUptime = ProcessInfo.processInfo.systemUptime

// --- display / session state -------------------------------------------------
// Every visibility-dependent measurement in this spike (rAF rate, first-frame
// latency, idle CPU of a visible view) is meaningless if the display is asleep
// or the screen is locked: macOS then marks every window occluded and WebKit
// suspends rendering app-wide. Record it, and optionally refuse to start.
func displayAsleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Int) == 1
}
func sessionState() -> String { "display_asleep=\(displayAsleep()) screen_locked=\(screenLocked())" }

// ---------------------------------------------------------------------------
// Instrument user script. Injected into an ISOLATED content world so page CSP
// cannot block it and so it cannot collide with page globals. It is DORMANT
// until native calls __m1.start() -- otherwise every one of the 100 views would
// be running a rAF loop and the idle-CPU number would be meaningless.
// ---------------------------------------------------------------------------
let INSTRUMENT_JS = """
(function () {
  var M = { raf: 0, tick: 0, running: false, markT: 0, firstRafAfterMark: 0, lastRafWall: 0 };
  M.start = function () {
    if (M.running) return 'already';
    M.running = true;
    function loop() {
      if (!M.running) return;
      M.raf++;
      M.lastRafWall = Date.now();
      if (M.markT && !M.firstRafAfterMark) { M.firstRafAfterMark = Date.now(); }
      requestAnimationFrame(loop);
    }
    requestAnimationFrame(loop);
    M.timer = setInterval(function () { M.tick++; }, 100);
    return 'started';
  };
  M.stop = function () { M.running = false; if (M.timer) clearInterval(M.timer); return 'stopped'; };
  M.mark = function () { M.markT = Date.now(); M.firstRafAfterMark = 0; return M.markT; };
  M.read = function () {
    return JSON.stringify({ raf: M.raf, tick: M.tick, now: Date.now(),
                            markT: M.markT, firstRaf: M.firstRafAfterMark,
                            lastRafWall: M.lastRafWall, running: M.running,
                            hidden: document.hidden, vis: document.visibilityState });
  };
  window.__m1 = M;
})();
"""

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------
final class Spike: NSObject, NSApplicationDelegate, WKNavigationDelegate {

    let pool = WKProcessPool()
    var stores: [WKWebsiteDataStore] = []
    var storeKind = "unknown"
    var views: [WKWebView] = []
    var urls: [URL] = []
    var window: NSWindow!
    var container: NSView!

    var baselinePids: Set<Int32> = []
    var snapshots: [MemSnapshot] = []
    var loadState: [Int: String] = [:]     // index -> "ok" | "fail: ..."
    var pendingLoads = 0
    var settleCallback: (() -> Void)?
    var report: [String: Any] = [:]

    // ---------- lifecycle ----------
    func applicationDidFinishLaunching(_ n: Notification) {
        log("session at launch: \(sessionState())")
        baselinePids = ProcMetrics.baselineWebKitPids()
        log("baseline WebKit helper pids already on the machine: \(baselinePids.sorted())")

        urls = MODE == "real" ? URLSets.realURLs(count: VIEW_COUNT) : URLSets.fixtures(count: VIEW_COUNT)

        makeStores()
        makeWindow()

        report["meta"] = [
            "mode": MODE, "views": VIEW_COUNT, "parented": PARENTED,
            "lane_w": Double(LANE_W), "lane_h": Double(LANE_H),
            "idle_secs": IDLE_SECS, "trials": TRIALS,
            "store_kind": storeKind, "store_count": stores.count,
            "baseline_webkit_pids": baselinePids.count,
            "pid": Int(getpid()),
            "date": ISO8601DateFormatter().string(from: Date()),
            "display_asleep_at_start": displayAsleep(),
            "screen_locked_at_start": screenLocked(),
        ]
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in self.noteVis() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.runStages(0) }
    }

    func makeStores() {
        // §9 asks for a small fixed number of WKWebsiteDataStores assigned by
        // project root. We use PERSISTENT, identifier-scoped stores
        // (macOS 14+) because that is what the real app needs (logins/cookies
        // must survive quit) and because persistent stores keep their HTTP
        // cache on disk -- a non-persistent store holds it in RAM, which would
        // flatter/inflate the memory number in the wrong direction.
        let ids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111101")!,
            UUID(uuidString: "11111111-1111-1111-1111-111111111102")!,
            UUID(uuidString: "11111111-1111-1111-1111-111111111103")!,
        ]
        for id in ids {
            let s = WKWebsiteDataStore(forIdentifier: id)
            stores.append(s)
        }
        storeKind = "persistent(forIdentifier:)"
        log("created \(stores.count) WKWebsiteDataStore (\(storeKind)) + 1 WKProcessPool")
    }

    func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1200, height: Int(LANE_H) > 1040 ? 1040 : Int(LANE_H)),
                          styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Max Pane — M1 spike (\(MODE))"
        // The strip: a very wide container inside the window. Lanes past the
        // window's right edge are parented-but-clipped, exactly like the real
        // app's RELEASE_DISTANCE band.
        container = NSView(frame: NSRect(x: 0, y: 0, width: LANE_W * CGFloat(VIEW_COUNT + 2), height: LANE_H))
        let scroll = NSScrollView(frame: window.contentLayoutRect)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasHorizontalScroller = true
        scroll.documentView = container
        window.contentView?.addSubview(scroll)
        // The real app is a frontmost fullscreen window. If this spike's window
        // is occluded by the terminal, AppKit reports .occluded and WebKit
        // suspends EVERYTHING -- including the views we mean to use as the
        // "parented and visible" control. Float it and keep it front.
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            if !self.window.occlusionState.contains(.visible) {
                self.window.orderFrontRegardless()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func visDiag() -> String {
        let occ = window.occlusionState.contains(.visible) ? "visible" : "OCCLUDED"
        return "window: isVisible=\(window.isVisible) occlusion=\(occ) isKey=\(window.isKeyWindow) NSApp.isActive=\(NSApp.isActive) screen=\(window.screen != nil) \(sessionState())"
    }
    var everOccluded = false
    var everVisible = false
    func noteVis() {
        if window.occlusionState.contains(.visible) { everVisible = true } else { everOccluded = true }
    }

    func laneFrame(_ slot: Int) -> NSRect {
        NSRect(x: CGFloat(slot) * LANE_W, y: 0, width: LANE_W, height: LANE_H)
    }

    func makeWebView(_ i: Int) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.processPool = pool
        cfg.websiteDataStore = stores[i % stores.count]
        let us = WKUserScript(source: INSTRUMENT_JS,
                              injectionTime: .atDocumentStart,
                              forMainFrameOnly: true,
                              in: .defaultClient)
        cfg.userContentController.addUserScript(us)
        let v = WKWebView(frame: laneFrame(i), configuration: cfg)
        v.navigationDelegate = self
        v.autoresizingMask = []
        return v
    }

    // ---------- load settling ----------
    func webView(_ w: WKWebView, didFinish nav: WKNavigation!) { finish(w, "ok") }
    func webView(_ w: WKWebView, didFail nav: WKNavigation!, withError e: Error) { finish(w, "fail: \(e.localizedDescription)") }
    func webView(_ w: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) { finish(w, "provfail: \(e.localizedDescription)") }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { finish(w, "crashed") }

    func finish(_ w: WKWebView, _ status: String) {
        guard let idx = views.firstIndex(of: w) else { return }
        if loadState[idx] != nil { return }
        loadState[idx] = status
        pendingLoads -= 1
        if pendingLoads <= 0, let cb = settleCallback { settleCallback = nil; cb() }
    }

    func waitForSettle(timeout: Double, _ done: @escaping () -> Void) {
        var fired = false
        let go = { if !fired { fired = true; done() } }
        settleCallback = go
        if pendingLoads <= 0 { settleCallback = nil; go(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            if !fired { log("settle TIMEOUT with \(self.pendingLoads) loads outstanding"); self.settleCallback = nil; go() }
        }
    }

    // ---------- stage: create N views parented, load, measure ----------
    func runStages(_ si: Int) {
        guard si < STAGES.count else { return unparentPhase() }
        let target = STAGES[si]
        log("stage: growing to \(target) parented web views")
        pendingLoads = 0
        while views.count < target {
            let i = views.count
            let v = makeWebView(i)
            views.append(v)
            container.addSubview(v)
            pendingLoads += 1
            v.load(URLRequest(url: urls[i]))
        }
        waitForSettle(timeout: 180) {
            // let layout/paint/JS quiesce before reading memory
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                let snap = MemSnapshot.take("parented_\(target)", baseline: self.baselinePids)
                self.snapshots.append(snap)
                log("  \(target) views parented: total footprint \(String(format: "%.0f", Double(snap.totalFootprint)/1048576)) MB, "
                    + "RSS \(String(format: "%.0f", Double(snap.totalResident)/1048576)) MB, "
                    + "WebContent procs: \(snap.count("WebContent"))")
                self.runStages(si + 1)
            }
        }
    }

    // ---------- unparent 95 ----------
    func unparentPhase() {
        log("unparenting all but \(PARENTED) views (removeFromSuperview, objects retained)")
        for (i, v) in views.enumerated() where i >= PARENTED { v.removeFromSuperview() }
        for (i, v) in views.enumerated() where i < PARENTED { v.frame = laneFrame(i) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            let snap = MemSnapshot.take("parented_\(PARENTED)_unparented_\(self.views.count - PARENTED)",
                                        baseline: self.baselinePids)
            self.snapshots.append(snap)
            log("  after unparent: total footprint \(String(format: "%.0f", Double(snap.totalFootprint)/1048576)) MB, "
                + "RSS \(String(format: "%.0f", Double(snap.totalResident)/1048576)) MB, "
                + "WebContent procs: \(snap.count("WebContent"))")
            self.quiesceAnimPages()
        }
    }

    /// Stop the page-world canvas animations on the anim fixtures so that the
    /// first idle window measures a quiescent mix. They get restarted for the
    /// suspension test.
    func quiesceAnimPages() {
        let anim = URLSets.animIndices.filter { $0 < views.count }
        var left = anim.count
        if left == 0 { return idlePhase(label: "idle_quiescent", next: { self.idleAnimated() }) }
        for i in anim {
            views[i].evaluateJavaScript("window.__anim && window.__anim.stop()", in: nil, in: .page) { _ in
                left -= 1
                if left == 0 {
                    log("paused page-world animations on \(anim.count) anim fixtures")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.idlePhase(label: "idle_quiescent", next: { self.idleAnimated() })
                    }
                }
            }
        }
    }

    func idleAnimated() {
        let anim = URLSets.animIndices.filter { $0 < views.count }
        var left = anim.count
        if left == 0 { return suspensionPhase() }
        for i in anim {
            views[i].evaluateJavaScript("window.__anim && window.__anim.start()", in: nil, in: .page) { _ in
                left -= 1
                if left == 0 {
                    log("restarted page-world animations on \(anim.count) anim fixtures (1 parented+visible, \(anim.count-1) unparented)")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.idlePhase(label: "idle_with_animating_pages", next: { self.suspensionPhase() })
                    }
                }
            }
        }
    }

    // ---------- idle CPU ----------
    func idlePhase(label: String, next: @escaping () -> Void) {
        log(visDiag())
        log("idle CPU sampling (\(label)) for \(IDLE_SECS)s — do not touch the machine")
        let interval = 5.0
        let n = max(1, Int(Double(IDLE_SECS) / interval))
        var samples: [(t: Double, cpu: UInt64)] = []
        func tick(_ k: Int) {
            let snap = MemSnapshot.take("idle", baseline: self.baselinePids)
            samples.append((ProcessInfo.processInfo.systemUptime, snap.totalCpuNs))
            if k >= n {
                var pcts: [Double] = []
                for j in 1..<samples.count {
                    let dt = samples[j].t - samples[j-1].t
                    let dc = Double(samples[j].cpu &- samples[j-1].cpu) / 1e9
                    pcts.append(dc / dt * 100.0)
                }
                let mean = pcts.reduce(0,+) / Double(max(1,pcts.count))
                let mx = pcts.max() ?? 0
                let mn = pcts.min() ?? 0
                log("  \(label): mean \(String(format: "%.2f", mean))% of one core, "
                    + "max \(String(format: "%.2f", mx))%, min \(String(format: "%.2f", mn))% over \(pcts.count) x \(Int(interval))s windows")
                self.report[label] = [
                    "window_secs": interval, "windows": pcts.count,
                    "mean_pct_one_core": mean, "max_pct_one_core": mx, "min_pct_one_core": mn,
                    "per_window_pct": pcts,
                ]
                next()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { tick(k + 1) }
        }
        tick(0)
    }

    // ---------- does unparenting suspend rendering? ----------
    struct Reading { var raf: Int; var tick: Int; var now: Double; var hidden: Bool; var vis: String }

    func read(_ i: Int, _ cb: @escaping (Reading?) -> Void) {
        views[i].evaluateJavaScript("window.__m1.read()", in: nil, in: .defaultClient) { r in
            guard case .success(let v) = r, let s = v as? String,
                  let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return cb(nil) }
            cb(Reading(raf: o["raf"] as? Int ?? -1, tick: o["tick"] as? Int ?? -1,
                       now: o["now"] as? Double ?? 0,
                       hidden: o["hidden"] as? Bool ?? false,
                       vis: o["vis"] as? String ?? "?"))
        }
    }

    func startInstrument(_ i: Int, _ cb: @escaping () -> Void) {
        views[i].evaluateJavaScript("window.__m1.start()", in: nil, in: .defaultClient) { _ in cb() }
    }

    var suspensionResults: [[String: Any]] = []

    func suspensionPhase() {
        // view 1  = anim fixture, PARENTED and visible  -> control
        // view 5  = anim fixture, UNPARENTED            -> subject
        // view 50 = anim fixture, UNPARENTED            -> subject 2 (reparented later)
        let avail = URLSets.animIndices.filter { $0 < views.count }.sorted()
        guard avail.count >= 2 else { log("not enough anim fixtures for suspension test"); return restoreLayoutThenLatency() }
        let control = avail[0], subject = avail[1], subject2 = avail.count > 2 ? avail[2] : avail[1]
        log(visDiag())
        log("suspension test: control=view\(control) (parented+visible), subject=view\(subject) (unparented), subject2=view\(subject2) (unparented)")
        startInstrument(control) { self.startInstrument(subject) { self.startInstrument(subject2) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.suspensionWindow(control, subject, subject2) }
        }}}
    }

    func suspensionWindow(_ control: Int, _ subject: Int, _ subject2: Int) {
        let ids = [control, subject, subject2]
        var t0: [Int: Reading] = [:]
        let g = DispatchGroup()
        for i in ids { g.enter(); read(i) { r in t0[i] = r; g.leave() } }
        g.notify(queue: .main) {
            let waitSecs = 15.0
            log("  measuring rAF/timer counters over \(Int(waitSecs))s while view\(subject)/view\(subject2) are unparented…")
            DispatchQueue.main.asyncAfter(deadline: .now() + waitSecs) {
                var t1: [Int: Reading] = [:]
                let g2 = DispatchGroup()
                for i in ids { g2.enter(); self.read(i) { r in t1[i] = r; g2.leave() } }
                g2.notify(queue: .main) {
                    for i in ids {
                        guard let a = t0[i], let b = t1[i] else { continue }
                        let dt = (b.now - a.now) / 1000.0
                        let rafPS = Double(b.raf - a.raf) / max(dt, 0.001)
                        let tickPS = Double(b.tick - a.tick) / max(dt, 0.001)
                        let role = i == control ? "control(parented,visible)" : "subject(unparented)"
                        log("    view\(i) \(role): rAF +\(b.raf - a.raf) over \(String(format: "%.1f", dt))s = "
                            + "\(String(format: "%.2f", rafPS)) fps | setInterval(100ms) ticks +\(b.tick - a.tick) = "
                            + "\(String(format: "%.2f", tickPS))/s | document.visibilityState=\(b.vis)")
                        self.suspensionResults.append([
                            "view": i, "role": role, "phase": "unparented_window",
                            "raf_delta": b.raf - a.raf, "tick_delta": b.tick - a.tick,
                            "seconds": dt, "raf_fps": rafPS, "ticks_per_sec": tickPS,
                            "visibility_state": b.vis, "document_hidden": b.hidden,
                        ])
                    }
                    self.suspensionReparent(control, subject)
                }
            }
        }
    }

    func suspensionReparent(_ control: Int, _ subject: Int) {
        // Re-parent the subject into the visible slot 0, and unparent the
        // control, then measure both again. This tests the TRANSITION in both
        // directions on the same two views.
        log("  swapping: view\(subject) -> visible slot 0 ; view\(control) -> unparented")
        views[0].removeFromSuperview()
        views[control].removeFromSuperview()
        views[subject].frame = laneFrame(0)
        container.addSubview(views[subject])
        window.makeFirstResponder(views[subject])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            var t0: [Int: Reading] = [:]
            let g = DispatchGroup()
            for i in [control, subject] { g.enter(); self.read(i) { r in t0[i] = r; g.leave() } }
            g.notify(queue: .main) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                    var t1: [Int: Reading] = [:]
                    let g2 = DispatchGroup()
                    for i in [control, subject] { g2.enter(); self.read(i) { r in t1[i] = r; g2.leave() } }
                    g2.notify(queue: .main) {
                        for i in [control, subject] {
                            guard let a = t0[i], let b = t1[i] else { continue }
                            let dt = (b.now - a.now) / 1000.0
                            let rafPS = Double(b.raf - a.raf) / max(dt, 0.001)
                            let role = i == subject ? "was-unparented, NOW PARENTED+VISIBLE" : "was-parented, NOW UNPARENTED"
                            log("    view\(i) \(role): rAF +\(b.raf - a.raf) over \(String(format: "%.1f", dt))s = \(String(format: "%.2f", rafPS)) fps"
                                + " | ticks +\(b.tick - a.tick) | visibilityState=\(b.vis)")
                            self.suspensionResults.append([
                                "view": i, "role": role, "phase": "after_swap",
                                "raf_delta": b.raf - a.raf, "tick_delta": b.tick - a.tick,
                                "seconds": dt, "raf_fps": rafPS,
                                "visibility_state": b.vis, "document_hidden": b.hidden,
                            ])
                        }
                        self.report["suspension"] = self.suspensionResults
                        self.restoreLayoutThenLatency()
                    }
                }
            }
        }
    }

    func restoreLayoutThenLatency() {
        for i in URLSets.animIndices where i < views.count { views[i].removeFromSuperview() }
        for i in 0..<PARENTED {
            views[i].frame = laneFrame(i)
            if views[i].superview == nil { container.addSubview(views[i]) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.latencyPhase() }
    }

    // ---------- re-parent latency ----------
    var latency: [[String: Any]] = []
    var displayLinkHits: [Double] = []
    var link: CADisplayLink?
    var linkArmT0: Double?
    var linkResult: Double?

    @objc func onDisplayLink(_ l: CADisplayLink) {
        if let t0 = linkArmT0, linkResult == nil {
            linkResult = (CACurrentMediaTime() - t0) * 1000.0
        }
    }

    func latencyPhase() {
        log("re-parent latency: \(TRIALS) trials, hot slot 0 (visible)")
        if link == nil {
            link = container.displayLink(target: self, selector: #selector(onDisplayLink(_:)))
            link?.add(to: .main, forMode: .common)
        }
        trial(0, occupant: 0)
    }

    func trial(_ k: Int, occupant: Int) {
        guard k < TRIALS else {
            link?.invalidate(); link = nil
            summariseLatency()
            return
        }
        let incoming = PARENTED + (k % (views.count - PARENTED))
        // Arm the incoming view's in-page clock so the "first frame" timestamp
        // is taken by the web process itself, with no IPC in the measured span.
        views[incoming].evaluateJavaScript("window.__m1.start(); window.__m1.mark()", in: nil, in: .defaultClient) { _ in
            DispatchQueue.main.async {
                let wall0 = Date().timeIntervalSince1970 * 1000.0
                let t0 = CACurrentMediaTime()
                self.linkArmT0 = t0
                self.linkResult = nil
                var commitMs: Double = -1
                CATransaction.begin()
                CATransaction.setCompletionBlock { commitMs = (CACurrentMediaTime() - t0) * 1000.0 }
                self.views[occupant].removeFromSuperview()
                self.views[incoming].frame = self.laneFrame(0)
                self.container.addSubview(self.views[incoming])
                CATransaction.commit()
                let addReturnMs = (CACurrentMediaTime() - t0) * 1000.0

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    self.views[incoming].evaluateJavaScript("window.__m1.read()", in: nil, in: .defaultClient) { r in
                        var firstFrameMs = -1.0
                        if case .success(let v) = r, let s = v as? String, let d = s.data(using: .utf8),
                           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           let fr = o["firstRaf"] as? Double, fr > 0 {
                            firstFrameMs = fr - wall0
                        }
                        self.latency.append([
                            "trial": k, "incoming_view": incoming, "outgoing_view": occupant,
                            "addsubview_return_ms": addReturnMs,
                            "catransaction_commit_ms": commitMs,
                            "displaylink_ms": self.linkResult ?? -1,
                            "first_web_frame_ms": firstFrameMs,
                        ])
                        self.views[incoming].evaluateJavaScript("window.__m1.stop()", in: nil, in: .defaultClient) { _ in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                self.trial(k + 1, occupant: incoming)
                            }
                        }
                    }
                }
            }
        }
    }

    func stats(_ xs: [Double]) -> [String: Double] {
        let s = xs.filter { $0 >= 0 }.sorted()
        guard !s.isEmpty else { return ["n": 0] }
        func pct(_ p: Double) -> Double { s[min(s.count - 1, max(0, Int((p / 100.0) * Double(s.count - 1) + 0.5)))] }
        return ["n": Double(s.count), "min": s.first!, "median": pct(50), "p95": pct(95),
                "max": s.last!, "mean": s.reduce(0,+) / Double(s.count)]
    }

    func summariseLatency() {
        let keys = ["addsubview_return_ms", "catransaction_commit_ms", "displaylink_ms", "first_web_frame_ms"]
        var summary: [String: Any] = [:]
        for k in keys {
            let xs = latency.compactMap { $0[k] as? Double }
            let st = stats(xs)
            summary[k] = st
            log("  \(k): n=\(Int(st["n"] ?? 0)) min=\(String(format: "%.1f", st["min"] ?? -1)) "
                + "median=\(String(format: "%.1f", st["median"] ?? -1)) "
                + "p95=\(String(format: "%.1f", st["p95"] ?? -1)) "
                + "max=\(String(format: "%.1f", st["max"] ?? -1)) ms")
        }
        report["latency_summary"] = summary
        report["latency_trials"] = latency
        finalPhase()
    }

    // ---------- finish ----------
    func finalPhase() {
        let snap = MemSnapshot.take("final", baseline: baselinePids)
        snapshots.append(snap)
        report["snapshots"] = snapshots.map { $0.json }
        report["window_diag"] = visDiag()
        report["window_ever_visible"] = everVisible
        report["window_ever_occluded"] = everOccluded
        report["display_asleep_at_end"] = displayAsleep()
        report["screen_locked_at_end"] = screenLocked()
        report["valid_for_visibility_measurements"] = everVisible && !screenLocked()
        report["load_state"] = loadState.map { ["index": $0.key, "url": urls[$0.key].absoluteString, "status": $0.value] }
        report["load_ok"] = loadState.values.filter { $0 == "ok" }.count
        report["load_failed"] = loadState.values.filter { $0 != "ok" }.count
        report["urls"] = urls.map { $0.absoluteString }

        // Per-WebContent-process detail from the final snapshot, so the report
        // can show the distribution, not just the sum.
        report["final_webcontent_footprints_mb"] = snap.helpers.filter { $0.kind == "WebContent" }
            .map { Double($0.physFootprint) / 1048576.0 }.sorted()

        try? FileManager.default.createDirectory(atPath: OUT_DIR, withIntermediateDirectories: true)
        let path = "\(OUT_DIR)/report-\(MODE).json"
        if let d = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: path))
            log("wrote \(path)")
        }
        log("loads: \(report["load_ok"] ?? 0) ok, \(report["load_failed"] ?? 0) failed")
        log("DONE")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
    }
}

if ARGS.contains("--require-unlocked") {
    let deadline = Date().addingTimeInterval(Double(argInt("wait-unlock-secs", 0)))
    while screenLocked() || displayAsleep() {
        if Date() >= deadline {
            FileHandle.standardError.write("M1 ABORT: \(sessionState()) — visibility-dependent measurements would be invalid.\n".data(using: .utf8)!)
            if !LOG_PATH.isEmpty { log("ABORT: \(sessionState())") }
            exit(75)  // EX_TEMPFAIL
        }
        Thread.sleep(forTimeInterval: 5)
    }
}

let app = NSApplication.shared
let delegate = Spike()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
