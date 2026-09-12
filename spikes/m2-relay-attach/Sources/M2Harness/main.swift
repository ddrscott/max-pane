import AppKit
import SwiftTerm
import RelayClient

// ---------------------------------------------------------------------------
// M2 harness: a real windowed AppKit app hosting SwiftTerm TerminalViews.
// Measures render-completion latency, per-view memory, lane fit, and produces
// PNG screenshots of the narrow-portrait-lane rendering options.
// ---------------------------------------------------------------------------

let fixtures = FileManager.default.currentDirectoryPath + "/fixtures"
let outDir = FileManager.default.currentDirectoryPath + "/out"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

var log = ""
func emit(_ s: String) { print(s); log += s + "\n" }
func flushLog(_ name: String) { try? log.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8) }

func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}
func rss() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}
func mbs(_ b: UInt64) -> String { String(format: "%.2f MB", Double(b) / 1_048_576.0) }

func pct(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    return s[min(s.count - 1, max(0, Int((q * Double(s.count - 1)).rounded())))]
}
func statRow(_ name: String, _ xs: [Double]) -> String {
    String(format: "| %@ | %d | %.2f | %.2f | %.2f | %.2f | %.2f |", name, xs.count,
           xs.min() ?? 0, xs.reduce(0,+) / Double(max(1, xs.count)),
           pct(xs, 0.5), pct(xs, 0.95), xs.max() ?? 0)
}
let statHeader = "| metric | n | min | mean | p50 | p95 | max |\n|---|---|---|---|---|---|---|"

/// SwiftTerm's `draw(_:)` is `public`, not `open`, so it cannot be overridden from
/// outside the module. Render completion is therefore observed through AppKit's own
/// dirty flag: the view goes needsDisplay=true when SwiftTerm's throttled
/// updateDisplay() lands on the main thread, and back to false once AppKit has run
/// the display pass that calls draw(). We poll that transition on the main thread
/// between run-loop turns (~0.2-1 ms granularity; a 120 Hz frame is 8.3 ms).
typealias TimedTerminalView = TerminalView

extension TerminalView {
    /// Cell size derived from the public getOptimalFrameSize(); the constant
    /// scroller reservation cancels in the difference.
    func cellSize() -> (width: CGFloat, height: CGFloat) {
        let t = getTerminal()
        let (c0, r0) = (t.cols, t.rows)
        t.resize(cols: 100, rows: 20); let a = getOptimalFrameSize()
        t.resize(cols: 200, rows: 40); let b = getOptimalFrameSize()
        t.resize(cols: c0, rows: r0)
        return ((b.width - a.width) / 100.0, (b.height - a.height) / 20.0)
    }
}

final class HarnessDelegate: NSObject, NSApplicationDelegate, TerminalViewDelegate {
    func scrolled(source: TerminalView, position: Double) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

let appDelegate = HarnessDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = appDelegate

var spawned = [String]()
func cleanup() { for id in spawned { RelaySpawn.kill(id: id) }; spawned.removeAll() }

let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1400, height: 900),
                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
window.title = "M2 harness"
let root = NSView(frame: window.contentLayoutRect)
window.contentView = root
window.orderFrontRegardless()

func png(_ view: NSView, _ name: String) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    if let d = rep.representation(using: .png, properties: [:]) {
        try? d.write(to: URL(fileURLWithPath: outDir + "/" + name))
    }
}

func makeView(_ frame: NSRect, font: NSFont, scrollback: Int = 500) -> TimedTerminalView {
    var o = TerminalOptions.default
    o.scrollback = scrollback
    let v = TimedTerminalView(frame: frame, font: font, options: o)
    v.terminalDelegate = appDelegate
    // Real sessions are themed dark and emit light foreground SGR; render on black.
    v.nativeBackgroundColor = NSColor.black
    v.nativeForegroundColor = NSColor(white: 0.85, alpha: 1)
    return v
}

/// A genuine idle wait: blocks in the run loop instead of spinning, so the CPU
/// measured is the app's, not the measurement loop's.
func idleWait(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { RunLoop.current.run(mode: .default, before: end) }
}

func pump(_ seconds: Double) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let e = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.002),
                                 inMode: .default, dequeue: true) { app.sendEvent(e) }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "all"

func run() {
    emit("# M2 harness (windowed AppKit + SwiftTerm TerminalView)\n")
    if mode == "cpu" { runCPUOnly(); flushLog("harness-cpu.md"); exit(0) }

    // ---- 1. per-TerminalView memory -------------------------------------
    emit("## Per-TerminalView memory cost\n")
    let mono = NSFont(name: "Menlo", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    var keep = [TimedTerminalView]()
    emit("30 TerminalViews at 80x45, each fed 3000 lines of output, never parented.\n")
    emit("| scrollback (lines) | phys_footprint delta | per view | RSS delta |")
    emit("|---|---|---|---|")
    let batch = 30
    for sb in [200, 500, 2000, 5000] {
        keep.removeAll(); pump(0.6)
        let base = footprint(), baseRSS = rss()
        for i in 0..<batch {
            let v = makeView(NSRect(x: 0, y: 0, width: 560, height: 760), font: mono, scrollback: sb)
            v.getTerminal().resize(cols: 80, rows: 45)
            var bytes = [UInt8]()
            for l in 0..<3000 { bytes.append(contentsOf: Array("line \(l) of pane \(i) \(String(repeating: "x", count: 60))\r\n".utf8)) }
            v.feed(byteArray: bytes[...])
            keep.append(v)
        }
        pump(0.8)
        let after = footprint(), afterRSS = rss()
        emit(String(format: "| %d | %@ | **%.2f MB** | %@ |", sb, mbs(after &- base),
                    Double(after &- base) / Double(batch) / 1_048_576.0, mbs(afterRSS &- baseRSS)))
    }

    // parent 8 of them so we also measure the parented/rendered cost
    let before2 = footprint()
    for (i, v) in keep.prefix(8).enumerated() {
        v.frame = NSRect(x: CGFloat(i) * 170, y: 0, width: 165, height: 760)
        root.addSubview(v)
    }
    pump(1.0)
    emit("- parenting 8 of them into a live window added \(mbs(footprint() &- before2))")
    for v in keep.prefix(8) { v.removeFromSuperview() }

    // ---- 2. scrollback extraction (PRD 7.5) ------------------------------
    emit("\n## Scrollback access for the search index (PRD §7.5: last 200 lines)\n")
    let probe = keep[0]
    let t0 = now()
    let lines = lastLines(probe.getTerminal(), 200)
    let dt = (now() - t0) * 1000
    emit("- `translateToString` path: \(lines.count) lines in **\(String(format: "%.3f ms", dt))**")
    let t1 = now()
    let lines2 = lastLinesPerCell(probe.getTerminal(), 200)
    let dt2 = (now() - t1) * 1000
    emit("- per-cell `getCharacter(col:row:)` path: \(lines2.count) lines in **\(String(format: "%.3f ms", dt2))**")
    emit("- last line: `\(lines.last ?? "")`")
    emit("- first of the 200: `\(lines.first ?? "")`")
    emit("- API used: `Terminal.buffer.totalLinesTrimmed` + `Terminal.getScrollInvariantLine(row:)` + `BufferLine.translateToString(trimRight:)` — all public")
    // astral-plane correctness of the two extraction paths
    let (probeT, _) = (probe.getTerminal(), 0)
    probeT.feed(buffer: Array("\r\nEMOJI A\u{1F600}B \u{1F1FA}\u{1F1F8} \u{65E5}\u{672C}\r\n".utf8)[...])
    let viaTranslate = lastLines(probeT, 3).first(where: { $0.hasPrefix("EMOJI") }) ?? "(not found)"
    let viaCells = lastLinesPerCell(probeT, 3).first(where: { $0.hasPrefix("EMOJI") }) ?? "(not found)"
    emit("- `translateToString` renders `EMOJI A😀B 🇺🇸 日本` as: `\(viaTranslate)`")
    emit("- per-cell `getCharacter` renders it as: `\(viaCells)`")
    keep.removeAll()
    pump(0.5)

    // ---- 3. lane fit: how many columns fit in a PRD lane ------------------
    emit("\n## Lane fit — columns per lane width (PRD §8: LANE_MIN 420pt, LANE_MAX 900pt)\n")
    emit("| font | size | cell w x h (pt) | cols @420pt | cols @600pt | cols @900pt | rows @900pt tall |")
    emit("|---|---|---|---|---|---|---|")
    for name in ["Menlo", "SF Mono", "JetBrains Mono", "Monaco"] {
        for size in [9.0, 10.0, 11.0, 12.0, 13.0, 14.0] as [CGFloat] {
            guard let f = NSFont(name: name, size: size) else { continue }
            let v = makeView(NSRect(x: 0, y: 0, width: 420, height: 900), font: f)
            let cell = v.cellSize()
            let c420 = Int(420.0 / cell.width), c600 = Int(600.0 / cell.width), c900 = Int(900.0 / cell.width)
            emit(String(format: "| %@ | %.0f | %.2f x %.2f | %d | %d | %d | %d |",
                        name, size, cell.width, cell.height, c420, c600, c900, Int(900.0 / cell.height)))
        }
    }

    // ---- 4. attach -> rendered latency, against a real session ------------
    emit("\n## connect() -> first pixels in TerminalView\n")
    do {
        let small = try RelaySpawn.spawn(command: "/bin/zsh", cwd: NSTemporaryDirectory(), cols: 80, rows: 40)
        spawned.append(small)
        let big = try RelaySpawn.spawn(command: fixtures + "/gen.pl", args: ["0", "85000"],
                                       cwd: NSTemporaryDirectory(), cols: 80, rows: 40)
        spawned.append(big)
        pump(2.0)
        var stable = 0, lastV = -1.0
        for _ in 0..<900 {
            let v = RelaySessionMeta.read(id: big)?.totalBytesWritten ?? 0
            if v >= 5 * 1_048_576 { if v == lastV { stable += 1 } else { stable = 0 } }
            lastV = v
            if stable >= 3 { break }
            pump(0.2)
        }
        emit("- big session totalBytesWritten = \(Int(lastV)) (\(String(format: "%.2f MB", lastV / 1_048_576)))")

        for (label, id) in [("small (prompt only)", small), ("big (\(String(format: "%.1f", lastV / 1_048_576)) MB scrollback)", big)] {
            var toDraw = [Double](), toFed = [Double](), paint = [Double]()
            for _ in 0..<25 {
                let v = makeView(NSRect(x: 0, y: 0, width: 620, height: 800), font: mono)
                v.getTerminal().resize(cols: 80, rows: 40)
                root.addSubview(v)
                pump(0.2)
                v.displayIfNeeded()
                var drawnAt = 0.0, fedAt = 0.0
                let s = RelaySession(id: id)
                s.onReplay = { p, isDelta in
                    if !isDelta { v.getTerminal().resetToInitialState() }
                    v.feed(byteArray: p[...])
                    fedAt = now()
                }
                try s.connect()
                let deadline = Date().addingTimeInterval(10)
                while fedAt == 0 && Date() < deadline {
                    if let e = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) { app.sendEvent(e) }
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.0005))
                }
                // Force the paint synchronously on the main thread. SwiftTerm's own path
                // defers this to the next run-loop display pass (<= one 8.3 ms frame at
                // 120 Hz); display() does the same drawing work, just now.
                if fedAt > 0 {
                    v.display()
                    drawnAt = now()
                    paint.append((drawnAt - fedAt) * 1000)
                }
                let st = s.timings
                if drawnAt > 0 {
                    toDraw.append((drawnAt - st.tStart) * 1000)
                    toFed.append((fedAt - st.tStart) * 1000)
                }
                s.close(); v.removeFromSuperview()
                pump(0.05)
            }
            emit("\n### \(label)")
            emit(statHeader)
            emit(statRow("connect -> replay fed (ms)", toFed))
            emit(statRow("paint the 80x40 grid (ms)", paint))
            emit(statRow("connect -> pixels on screen (ms)", toDraw))
        }

        // ---- 4b. 20 live panes parented in a real window --------------------
        emit("\n## 20 live terminal panes, parented and rendering (PRD §10.1: idle CPU < 2%)\n")
        var liveViews = [TimedTerminalView]()
        var liveSessions = [RelaySession]()
        let preRSS = rss(), preFP = footprint()
        func cpuBase(_ seconds: Double) -> Double {
            var u0 = rusage(); getrusage(RUSAGE_SELF, &u0); let t0 = now()
            idleWait(seconds)
            var u1 = rusage(); getrusage(RUSAGE_SELF, &u1)
            let d = (Double(u1.ru_utime.tv_sec - u0.ru_utime.tv_sec) + Double(u1.ru_utime.tv_usec - u0.ru_utime.tv_usec) / 1e6)
                  + (Double(u1.ru_stime.tv_sec - u0.ru_stime.tv_sec) + Double(u1.ru_stime.tv_usec - u0.ru_stime.tv_usec) / 1e6)
            return d / (now() - t0) * 100
        }
        emit("- baseline: empty window, 0 panes: **\(String(format: "%.2f%%", cpuBase(10))) of one core**")
        for i in 0..<20 {
            let sid = try RelaySpawn.spawn(command: "/bin/zsh", cwd: NSTemporaryDirectory(), cols: 80, rows: 45)
            spawned.append(sid)
            let v = makeView(NSRect(x: CGFloat(i % 8) * 172, y: CGFloat(i / 8) * 300, width: 168, height: 295), font: mono)
            v.getTerminal().resize(cols: 80, rows: 45)
            root.addSubview(v)
            let sess = RelaySession(id: sid)
            sess.onReplay = { p, isDelta in
                if !isDelta { v.getTerminal().resetToInitialState() }
                v.feed(byteArray: p[...])
            }
            sess.onData = { d in v.feed(byteArray: d) }
            sess.onResize = { c, r in DispatchQueue.main.async { v.getTerminal().resize(cols: c, rows: r) } }
            try sess.connect()
            liveViews.append(v); liveSessions.append(sess)
            pump(0.1)
        }
        pump(3.0)
        func cpuOver(_ seconds: Double) -> Double {
            var u0 = rusage(); getrusage(RUSAGE_SELF, &u0); let t0 = now()
            idleWait(seconds)
            var u1 = rusage(); getrusage(RUSAGE_SELF, &u1)
            let d = (Double(u1.ru_utime.tv_sec - u0.ru_utime.tv_sec) + Double(u1.ru_utime.tv_usec - u0.ru_utime.tv_usec) / 1e6)
                  + (Double(u1.ru_stime.tv_sec - u0.ru_stime.tv_sec) + Double(u1.ru_stime.tv_usec - u0.ru_stime.tv_usec) / 1e6)
            return d / (now() - t0) * 100
        }
        let idle20 = cpuOver(15)
        emit("- 20 panes attached, parented, visible, shells at a prompt: **\(String(format: "%.2f%%", idle20)) of one core**")
        emit("- RSS \(mbs(preRSS)) -> \(mbs(rss())), phys_footprint \(mbs(preFP)) -> \(mbs(footprint()))")
        for s2 in liveSessions.prefix(3) {
            s2.sendInput(Array("perl \(fixtures)/gen.pl 20 0\n".utf8))
        }
        pump(2.0)
        let busy3 = cpuOver(15)
        emit("- with 3 of the 20 emitting 20 lines/s (a realistic agent working): **\(String(format: "%.2f%%", busy3)) of one core**")
        for s2 in liveSessions.prefix(3) { s2.sendInput([0x03]) }
        pump(1.0)
        for s2 in liveSessions { s2.sendInput(Array("perl \(fixtures)/gen.pl 500 0\n".utf8)) }
        pump(2.0)
        let busyAll = cpuOver(15)
        emit("- with all 20 emitting 500 lines/s (worst case, nothing like real use): **\(String(format: "%.2f%%", busyAll)) of one core**, RSS \(mbs(rss()))")
        for s2 in liveSessions { s2.close() }
        for v in liveViews { v.removeFromSuperview() }
        liveViews.removeAll(); liveSessions.removeAll()
        cleanup()
        pump(1.0)

        // ---- 5. narrow-lane rendering options -----------------------------
        emit("\n## Narrow portrait lane: a wide host screen inside a 420pt column\n")
        // Use real captured content if the observe step produced it, else the ruler.
        var content = [UInt8]()
        var hostCols = 80
        let capture = outDir + "/capture-real.bin"
        if let d = FileManager.default.contents(atPath: capture) { content = [UInt8](d) }
        if let cs = try? String(contentsOfFile: outDir + "/capture-real.cols", encoding: .utf8),
           let v = Int(cs.trimmingCharacters(in: .whitespacesAndNewlines)) { hostCols = v }
        if content.isEmpty {
            for i in 0..<40 {
                content.append(contentsOf: Array("\u{1b}[36m●\u{1b}[0m row \(i) — a Claude Code style line that runs to about seventy-six columns wide \r\n".utf8))
            }
        }
        emit("Content: a real, live Claude Code session captured read-only (\(hostCols) columns, \(content.count) B of replay).\n")
        let laneW: CGFloat = 420, laneH: CGFloat = 860
        struct Opt { let name: String; let font: CGFloat; let hscroll: Bool }
        let opts = [Opt(name: "A-clip-12pt", font: 12, hscroll: false),
                    Opt(name: "B-hscroll-12pt", font: 12, hscroll: true),
                    Opt(name: "C-shrink-to-fit", font: 0, hscroll: false),
                    Opt(name: "D-900pt-lane-12pt", font: 12, hscroll: false)]
        emit("| option | font pt | cell w | cols visible in a 420pt lane | host cols | fits? |")
        emit("|---|---|---|---|---|---|")
        for o in opts {
            let lw: CGFloat = o.name.hasPrefix("D") ? 900 : laneW
            var size = o.font
            if size == 0 {
                size = 12
                while size > 4 {
                    let f = NSFont(name: "Menlo", size: size)!
                    let probe = makeView(NSRect(x: 0, y: 0, width: lw, height: laneH), font: f)
                    if probe.cellSize().width * CGFloat(hostCols) <= lw { break }
                    size -= 0.25
                }
            }
            let f = NSFont(name: "Menlo", size: size)!
            let probe = makeView(NSRect(x: 0, y: 0, width: lw, height: laneH), font: f)
            let cell = probe.cellSize()
            let fullW = cell.width * CGFloat(hostCols) + 4
            let v = makeView(NSRect(x: 0, y: 0, width: o.hscroll ? fullW : lw, height: laneH), font: f)
            let visible = Int(lw / cell.width)
            v.getTerminal().resize(cols: hostCols, rows: Int(laneH / cell.height))
            v.feed(byteArray: content[...])
            let clip = NSView(frame: NSRect(x: 0, y: 0, width: lw, height: laneH))
            clip.addSubview(v)
            root.addSubview(clip)
            pump(0.6)
            png(clip, "lane-\(o.name).png")
            emit(String(format: "| %@ | %.2f | %.2f | %d | %d | %@ |", o.name, size, cell.width,
                        visible, hostCols,
                        visible >= hostCols ? "yes" : "no — \(hostCols - visible) columns off the right edge"))
            clip.removeFromSuperview()
        }
        emit("\nScreenshots in out/: lane-A-clip-12pt.png, lane-B-hscroll-12pt.png, lane-C-shrink-to-fit.png, lane-D-900pt-lane-12pt.png")
    } catch {
        emit("ERROR: \(error)")
    }

    cleanup()
    flushLog("harness.md")
    exit(0)
}

/// Same walk, but reading each cell through Terminal.getCharacter(col:row:), which
/// resolves the side-table payload that holds astral-plane scalars.
/// Isolated CPU measurement: 20 real sessions attached to 20 parented, visible
/// TerminalViews, with the run loop actually idle (no spin).
func runCPUOnly() {
    emit("## 20 live terminal panes — CPU (PRD §10.1: idle CPU < 2% of one core)\n")
    let mono = NSFont(name: "Menlo", size: 12)!
    func cpuOver(_ seconds: Double) -> Double {
        var u0 = rusage(); getrusage(RUSAGE_SELF, &u0); let t0 = now()
        idleWait(seconds)
        var u1 = rusage(); getrusage(RUSAGE_SELF, &u1)
        let d = (Double(u1.ru_utime.tv_sec - u0.ru_utime.tv_sec) + Double(u1.ru_utime.tv_usec - u0.ru_utime.tv_usec) / 1e6)
              + (Double(u1.ru_stime.tv_sec - u0.ru_stime.tv_sec) + Double(u1.ru_stime.tv_usec - u0.ru_stime.tv_usec) / 1e6)
        return d / (now() - t0) * 100
    }
    emit("| condition | CPU (% of one core) | RSS |")
    emit("|---|---|---|")
    emit(String(format: "| empty window, 0 panes (baseline) | %.2f | %@ |", cpuOver(10), mbs(rss())))

    var views = [TimedTerminalView]()
    var sessions = [RelaySession]()
    do {
        for i in 0..<20 {
            let sid = try RelaySpawn.spawn(command: "/bin/zsh", cwd: NSTemporaryDirectory(), cols: 80, rows: 45)
            spawned.append(sid)
            let v = makeView(NSRect(x: CGFloat(i % 8) * 172, y: CGFloat(i / 8) * 300, width: 168, height: 295), font: mono)
            v.getTerminal().resize(cols: 80, rows: 45)
            root.addSubview(v)
            let sess = RelaySession(id: sid)
            sess.onReplay = { p, isDelta in
                if !isDelta { v.getTerminal().resetToInitialState() }
                v.feed(byteArray: p[...])
            }
            sess.onData = { d in v.feed(byteArray: d) }
            sess.onResize = { c, r in DispatchQueue.main.async { v.getTerminal().resize(cols: c, rows: r) } }
            try sess.connect()
            views.append(v); sessions.append(sess)
            pump(0.1)
        }
    } catch { emit("spawn failed: \(error)"); cleanup(); return }
    pump(3.0)
    emit(String(format: "| 20 panes attached + parented + visible, shells idle at a prompt | **%.2f** | %@ |", cpuOver(20), mbs(rss())))

    for v in views { v.removeFromSuperview() }
    pump(1.0)
    emit(String(format: "| the same 20 attached but unparented (off-screen lane) | %.2f | %@ |", cpuOver(15), mbs(rss())))
    for v in views { root.addSubview(v) }
    pump(1.0)

    for s2 in sessions.prefix(3) { s2.sendInput(Array("perl \(fixtures)/gen.pl 20 0\n".utf8)) }
    pump(2.0)
    emit(String(format: "| 3 of the 20 emitting 20 lines/s (a working agent) | %.2f | %@ |", cpuOver(15), mbs(rss())))
    for s2 in sessions.prefix(3) { s2.sendInput([0x03]) }
    pump(2.0)
    for s2 in sessions { s2.sendInput(Array("perl \(fixtures)/gen.pl 200 0\n".utf8)) }
    pump(2.0)
    emit(String(format: "| all 20 emitting 200 lines/s (worst case) | %.2f | %@ |", cpuOver(15), mbs(rss())))
    for s2 in sessions { s2.close() }
    cleanup()
}

func lastLinesPerCell(_ t: Terminal, _ n: Int) -> [String] {
    var out = [String]()
    var row = t.buffer.totalLinesTrimmed + t.getTopVisibleRow() + t.rows - 1
    let bottom = row
    while out.count < n, row >= 0 {
        guard let l = t.getScrollInvariantLine(row: row) else { break }
        var sbuf = ""
        for c in 0..<min(l.count, t.cols) {
            let cd = l[c]
            if cd.width == 0 { continue }
            sbuf.append(t.getCharacter(for: cd))
        }
        while sbuf.hasSuffix(" ") { sbuf.removeLast() }
        out.append(sbuf)
        row -= 1
    }
    _ = bottom
    return out.reversed()
}

func lastLines(_ t: Terminal, _ n: Int) -> [String] {
    var out = [String]()
    var row = t.buffer.totalLinesTrimmed + t.getTopVisibleRow() + t.rows - 1
    while out.count < n, row >= 0 {
        guard let l = t.getScrollInvariantLine(row: row) else { break }
        out.append(l.translateToString(trimRight: true))
        row -= 1
    }
    return out.reversed()
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { run() }
app.run()
