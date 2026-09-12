import Foundation
import SwiftTerm
import RelayClient

// A SEQ-number tracker that detects frames dropped by the 256-frame broadcast
// channel (Lagged(n)) — pty-host drops them silently, so the only client-visible
// evidence is a gap in the stream.
final class SeqTracker {
    private var pending = [UInt8]()
    private(set) var first = -1
    private(set) var last = -1
    private(set) var count = 0
    private(set) var gaps = 0
    private(set) var gapLines = 0
    private(set) var dupes = 0
    var armed = false
    private let marker = Array("SEQ\u{1b}[0m ".utf8)

    func feed(_ d: ArraySlice<UInt8>) {
        guard armed else { return }
        pending.append(contentsOf: d)
        var i = 0
        let m = marker
        while i + m.count + 8 <= pending.count {
            if pending[i] == m[0] {
                var ok = true
                for k in 1..<m.count where pending[i + k] != m[k] { ok = false; break }
                if ok {
                    var v = 0, good = true
                    for k in 0..<8 {
                        let c = pending[i + m.count + k]
                        if c < 48 || c > 57 { good = false; break }
                        v = v * 10 + Int(c - 48)
                    }
                    if good { note(v); i += m.count + 8; continue }
                }
            }
            i += 1
        }
        if i > 0 { pending.removeFirst(i) }
        if pending.count > 4096 { pending.removeFirst(pending.count - 4096) }
    }

    private func note(_ v: Int) {
        count += 1
        if first < 0 { first = v; last = v; return }
        if v == last + 1 { last = v }
        else if v <= last { dupes += 1 }
        else { gaps += 1; gapLines += (v - last - 1); last = v }
    }
}

func runResize() throws {
    print("## Resize correctness (our own session, ruler fixture)\n")
    let id = try spawnOwn(fixtures + "/ruler.zsh", cols: 80, rows: 40)
    usleep(2_000_000)
    let (term, _) = headlessTerminal(cols: 80, rows: 40)
    let lock = NSLock()
    let s = RelaySession(id: id)
    var hostSize = (0, 0)
    var tSent = 0.0, tEcho = 0.0, tFirstByte = 0.0
    s.onResize = { c, r in
        lock.lock(); term.resize(cols: c, rows: r); hostSize = (c, r)
        if tSent > 0 && tEcho == 0 { tEcho = now() }
        lock.unlock()
    }
    s.onReplay = { p, isDelta in
        lock.lock(); if !isDelta { term.resetToInitialState() }; term.feed(buffer: p[...]); lock.unlock()
    }
    s.onData = { d in
        lock.lock(); term.feed(buffer: d)
        if tSent > 0 && tFirstByte == 0 { tFirstByte = now() }
        lock.unlock()
    }
    let sem = DispatchSemaphore(value: 0); s.onHandshake = { _ in sem.signal() }
    try s.connect()
    _ = sem.wait(timeout: .now() + 5)
    usleep(500_000)

    var echoMs = [Double](), redrawMs = [Double]()
    print("| target | host RESIZE echo | session JSON cols x rows | SwiftTerm grid | ruler line | app-reported SIZE | corruption |")
    print("|---|---|---|---|---|---|---|")

    // PRD lane range 420-900pt => roughly 40-100 cols at a normal terminal font.
    let targets = [(80, 40), (100, 50), (64, 50), (50, 50), (44, 30), (40, 24), (92, 60), (57, 45), (80, 40)]
    var allOK = true
    for (c, r) in targets {
        lock.lock(); tEcho = 0; tFirstByte = 0; tSent = now(); lock.unlock()
        s.sendResize(cols: c, rows: r)
        let ok = waitUntil(4.0) {
            lock.lock(); defer { lock.unlock() }
            guard hostSize == (c, r) else { return false }
            let l0 = term.getLine(row: 0)?.translateToString(trimRight: true) ?? ""
            return l0.hasPrefix("SIZE \(c)x\(r) ")
        }
        usleep(400_000)
        lock.lock()
        let rows = screenText(term)
        let grid = term.getDims()
        let reported = rows.first ?? ""
        // ruler line is row 1: chars 1..c-1 are (i % 10), last char '#'
        let ruler = term.getLine(row: 1)
        var rulerOK = true, badAt = -1
        if let rl = ruler {
            for i in 1..<c {
                let want = Character(String(i % 10))
                if term.getCharacter(col: i - 1, row: 1) != want { rulerOK = false; badAt = i - 1; break }
            }
            if rulerOK && term.getCharacter(col: c - 1, row: 1) != "#" { rulerOK = false; badAt = c - 1 }
            _ = rl
        } else { rulerOK = false }
        // bottom row: '=' repeated with 'E' at the last column
        var bottomOK = term.getCharacter(col: c - 1, row: r - 1) == "E"
        if bottomOK { for i in 0..<(c - 1) where term.getCharacter(col: i, row: r - 1) != "=" { bottomOK = false; break } }
        lock.unlock()
        let meta = RelaySessionMeta.read(id: id)
        lock.lock()
        if tEcho > 0 { echoMs.append((tEcho - tSent) * 1000) }
        if tFirstByte > 0 { redrawMs.append((tFirstByte - tSent) * 1000) }
        lock.unlock()
        let corrupt = (rulerOK && bottomOK) ? "none" : "RULER@\(badAt) bottom=\(bottomOK)"
        if !(rulerOK && bottomOK && ok) { allOK = false }
        print("| \(c)x\(r) | \(hostSize.0)x\(hostSize.1) | \(meta?.cols ?? -1)x\(meta?.rows ?? -1) | \(grid.cols)x\(grid.rows) | \(rulerOK ? "exact" : "MISMATCH") | \(reported) | \(corrupt) |")
    }
    print("\nverdict: \(allOK ? "all sizes cell-exact" : "MISMATCH FOUND")")
    print("\n" + Stats.header)
    print(Stats("RESIZE sent -> host RESIZE echoed back", echoMs).row)
    print(Stats("RESIZE sent -> first redraw byte from the app", redrawMs).row)

    // redundant resize is dropped by the host (main.rs:1913-1916) -> no redraw traffic
    let before = s.dataBytes
    for _ in 0..<20 { s.sendResize(cols: 80, rows: 40) }
    usleep(800_000)
    print("redundant RESIZE x20 at the size already in effect -> \(s.dataBytes - before) bytes of DATA generated")
    s.close(); cleanup()
}

func runConflict() throws {
    print("## The resize conflict: two clients, one PTY, last writer wins\n")
    for (label, command, cargs, cols, rows) in [
        ("ruler fixture", fixtures + "/ruler.zsh", [String](), 80, 40),
        ("htop (real full-screen TUI)", "/opt/homebrew/bin/htop", ["-d", "20"], 80, 40),
    ] {
        guard FileManager.default.isExecutableFile(atPath: command) else { print("\(label): not installed, skipped"); continue }
        let id = try spawnOwn(command, cargs, cols: cols, rows: rows)
        usleep(2_500_000)

        // Client A: a MaxPane-style narrow portrait lane.  Client B: a phone.
        let a = try attachAndWait(id)
        let b = try attachAndWait(id)
        // Client C: a passive observer that never resizes — stands in for "the other pane"
        let c = try attachAndWait(id)
        var cResizes = [(Int, Int)]()
        var cBytes = [Int]()
        let lk = NSLock()
        c.onResize = { cc, rr in lk.lock(); cResizes.append((cc, rr)); lk.unlock() }

        print("\n### \(label) — session \(id)")
        print("| flip | who | requested | host broadcast | DATA bytes to the innocent 3rd client |")
        print("|---|---|---|---|---|")
        var totals = [Int]()
        for i in 0..<8 {
            let narrow = (i % 2 == 0)
            let (tc, tr) = narrow ? (50, 50) : (100, 30)
            let before = c.dataBytes
            lk.lock(); cResizes.removeAll(); lk.unlock()
            if narrow { a.sendResize(cols: tc, rows: tr) } else { b.sendResize(cols: tc, rows: tr) }
            usleep(900_000)
            let delta = c.dataBytes - before
            totals.append(delta)
            lk.lock(); let seen = cResizes.map { "\($0.0)x\($0.1)" }.joined(separator: ","); lk.unlock()
            cBytes.append(delta)
            print("| \(i) | \(narrow ? "MaxPane lane" : "phone") | \(tc)x\(tr) | \(seen) | \(delta) |")
        }
        let avg = totals.isEmpty ? 0 : totals.reduce(0, +) / totals.count
        print("\nmean redraw traffic forced on every other attached client per flip: **\(avg) bytes**")
        let meta = RelaySessionMeta.read(id: id)
        print("live PTY winsize after the fight (last inbound RESIZE broadcast): **\(c.hostCols)x\(c.hostRows)** — the phone wrote last, so it owns the PTY for everyone")
        print("session JSON still says \(meta?.cols ?? -1)x\(meta?.rows ?? -1) — the metadata flush is on a 5 s timer, so NEVER read live size from the JSON")
        print("client A (the MaxPane lane) asked for 50x50 and is now being fed a \(a.hostCols)-column screen it has \(a.hostCols > 50 ? "no room for" : "room for")")

        // Mitigation: a client that attaches and never sends RESIZE.
        let d = try attachAndWait(id)
        var dSizes = [String]()
        d.onResize = { cc, rr in dSizes.append("\(cc)x\(rr)") }
        let dBefore = d.dataBytes
        b.sendResize(cols: 72, rows: 36)
        usleep(900_000)
        b.sendResize(cols: 100, rows: 30)
        usleep(900_000)
        print("mitigation check — a client that never sends RESIZE: learned host size \(dSizes) purely from inbound RESIZE frames, received \(d.dataBytes - dBefore) B of redraw, and caused 0 SIGWINCHs itself")
        d.close()
        a.close(); b.close(); c.close()
        RelaySpawn.kill(id: id); spawned.removeAll { $0 == id }
        usleep(300_000)
    }
    cleanup()
}

func runLoad(_ n: Int, rate: Int) throws {
    print("## \(n) concurrent sessions\n")
    var ids = [String]()
    for _ in 0..<n { ids.append(try spawnOwn("/bin/zsh", cols: 80, rows: 40)) }
    print("spawned \(n) zsh sessions; SwiftTerm scrollback = \(ProcessInfo.processInfo.environment["M2_SCROLLBACK"] ?? "500") lines/pane")
    usleep(3_000_000)

    var sessions = [RelaySession]()
    var terms = [Terminal]()
    var trackers = [SeqTracker]()
    var locks = [NSLock]()
    let baselineRSS = selfRSS(), baselineFP = selfFootprint()

    for id in ids {
        let (t, d) = headlessTerminal(cols: 80, rows: 40)
        withExtendedLifetime(d) {}
        delegates.append(d)
        let tr = SeqTracker(); let lk = NSLock()
        let s = RelaySession(id: id)
        s.onReplay = { p, isDelta in lk.lock(); if !isDelta { t.resetToInitialState() }; t.feed(buffer: p[...]); lk.unlock() }
        s.onData   = { dd in lk.lock(); t.feed(buffer: dd); tr.feed(dd); lk.unlock() }
        s.onResize = { c, r in lk.lock(); t.resize(cols: c, rows: r); lk.unlock() }
        let sem = DispatchSemaphore(value: 0); s.onHandshake = { _ in sem.signal() }
        try s.connect()
        _ = sem.wait(timeout: .now() + 10)
        sessions.append(s); terms.append(t); trackers.append(tr); locks.append(lk)
    }
    print("attached \(sessions.count) sessions; all handshakes complete")
    usleep(2_000_000)

    func phase(_ name: String, seconds: Double, before: () -> Void) -> (Double, UInt64, UInt64, Int) {
        before()
        usleep(2_000_000)                     // settle
        let c0 = selfCPUSeconds(), t0 = now()
        usleep(UInt32(seconds * 1e6))
        let cpu = (selfCPUSeconds() - c0) / (now() - t0) * 100
        let bytes = sessions.reduce(0) { $0 + $1.dataBytes }
        return (cpu, selfRSS(), selfFootprint(), bytes)
    }

    let (idleCPU, idleRSS, idleFP, idleBytes) = phase("idle", seconds: 20) {}
    print(String(format: "\n### idle (30 shells at a prompt, nothing running)\n- CPU: **%.2f%% of one core**\n- RSS: %@ (baseline before attach %@, delta %@)\n- phys_footprint: %@\n- DATA bytes received so far: %d",
                 idleCPU, mb(idleRSS), mb(baselineRSS), mb(idleRSS &- baselineRSS), mb(idleFP), idleBytes))
    _ = idleFP; _ = baselineFP

    for t in trackers { t.armed = true }
    let bytesBefore = sessions.reduce(0) { $0 + $1.dataBytes }
    let (loadCPU, loadRSS, loadFP, loadBytes) = phase("load", seconds: 30) {
        for s in sessions {
            s.sendInput(Array("exec perl \(fixtures)/gen.pl \(rate) 0\n".utf8))
        }
    }
    let thru = Double(loadBytes - bytesBefore) / 32.0
    print(String(format: "\n### under load (%d sessions x ~%d lines/s each)\n- CPU: **%.2f%% of one core**\n- RSS: %@\n- phys_footprint: %@\n- aggregate throughput: %.2f MB/s (%.0f bytes/s)",
                 n, rate, loadCPU, mb(loadRSS), mb(loadFP), thru / 1_048_576, thru))

    // stop the generators, let everything quiesce, then compare offsets
    for s in sessions { s.sendInput([0x03]) }
    usleep(3_000_000)
    for s in sessions { s.sendInput([0x03]) }
    usleep(4_000_000)

    var mismatches = 0, totalGaps = 0, totalGapLines = 0, totalDupes = 0, totalSeq = 0
    print("\n### correctness — client offset vs host total_written, and SEQ continuity")
    print("| session | client offset | host totalBytesWritten | delta | SEQ lines | gaps | lines lost | dupes |")
    print("|---|---|---|---|---|---|---|---|")
    for (i, s) in sessions.enumerated() {
        let meta = RelaySessionMeta.read(id: s.id)
        let host = meta?.totalBytesWritten ?? -1
        let d = s.offset - host
        if d != 0 { mismatches += 1 }
        let tr = trackers[i]
        totalGaps += tr.gaps; totalGapLines += tr.gapLines; totalDupes += tr.dupes; totalSeq += tr.count
        if i < 6 || d != 0 || tr.gaps > 0 {
            print("| \(s.id) | \(Int(s.offset)) | \(Int(host)) | \(Int(d)) | \(tr.count) | \(tr.gaps) | \(tr.gapLines) | \(tr.dupes) |")
        }
    }
    print("\n- sessions whose client offset != host total_written: **\(mismatches) / \(n)**")
    print("- total SEQ lines observed: \(totalSeq); sequence gaps (Lagged evidence): **\(totalGaps)** (\(totalGapLines) lines); duplicates: \(totalDupes)")

    for s in sessions { s.close() }
    cleanup()
}

var delegates = [NullTermDelegate]()

func runObserve(_ id: String) throws {
    print("## Read-only attach to a real, live session (\(id)) — no RESIZE, no input\n")
    guard let meta = RelaySessionMeta.read(id: id) else { print("no such session"); return }
    print("- command: \(meta.command) \(meta.args.joined(separator: " "))")
    print("- PTY size on disk: \(meta.cols)x\(meta.rows), title: \(meta.title ?? "-"), agentState: \(meta.agentState ?? "-")")
    let (term, d) = headlessTerminal(cols: meta.cols, rows: meta.rows)
    delegates.append(d)
    let lk = NSLock()
    let s = RelaySession(id: id)
    s.onResize = { c, r in lk.lock(); term.resize(cols: c, rows: r); lk.unlock() }
    s.onReplay = { p, isDelta in lk.lock(); if !isDelta { term.resetToInitialState() }; term.feed(buffer: p[...]); lk.unlock() }
    s.onData = { dd in lk.lock(); term.feed(buffer: dd); lk.unlock() }
    var captured = [UInt8]()
    s.onReplay = { p, isDelta in
        lk.lock(); if !isDelta { term.resetToInitialState() }
        term.feed(buffer: p[...]); captured.append(contentsOf: p); lk.unlock()
    }
    let sem = DispatchSemaphore(value: 0); s.onHandshake = { _ in sem.signal() }
    // READ ONLY: RESUME with a 256 KiB replay clamp. No RESIZE, no DATA, ever.
    try s.connect(mode: .resume(offset: 0, maxReplayBytes: 262_144))
    _ = sem.wait(timeout: .now() + 15)
    let t = s.timings
    print(String(format: "- handshake %.3f ms; inbound RESIZE says %dx%d; replay wire %d B -> plain %d B (gz=%@); inflate %.3f ms",
                 (t.tSync - t.tStart) * 1000, s.hostCols, s.hostRows,
                 t.replayWireBytes, t.replayPlainBytes, t.replayWasGz ? "yes" : "no",
                 (t.tReplayDecoded - t.tReplayFrame) * 1000))
    usleep(1_500_000)
    lk.lock()
    let rows = screenText(term)
    lk.unlock()
    let widths = rows.map { $0.count }
    print("- rendered \(rows.count) rows; longest line \(widths.max() ?? 0) cells; lines wider than 50 cells: \(widths.filter { $0 > 50 }.count)/\(rows.count)")
    let outPath = FileManager.default.currentDirectoryPath + "/out/observed-\(id).txt"
    try? rows.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("- screen dump: \(outPath)")
    let binPath = FileManager.default.currentDirectoryPath + "/out/capture-real.bin"
    lk.lock(); let cap = captured; lk.unlock()
    try? Data(cap).write(to: URL(fileURLWithPath: binPath))
    try? "\(s.hostCols)".write(toFile: FileManager.default.currentDirectoryPath + "/out/capture-real.cols",
                               atomically: true, encoding: .utf8)
    print("- raw replay bytes (\(cap.count) B) saved for the narrow-lane render test: \(binPath)")
    // scrollback proof (PRD 7.5 wants the last 200 lines)
    let sb = lastLines(term, 200)
    print("- SwiftTerm scrollback: pulled \(sb.count) lines, \(sb.reduce(0) { $0 + $1.count }) chars")
    s.close()
}

/// PRD §7.5: the last N lines of a pty pane's scrollback, from SwiftTerm's own buffer.
func lastLines(_ t: Terminal, _ n: Int) -> [String] {
    // Scroll-invariant indices count from the start of scrollback including
    // lines already trimmed off the top (Buffer.totalLinesTrimmed).
    var out = [String]()
    let lastAbs = t.buffer.totalLinesTrimmed + t.getTopVisibleRow() + t.rows - 1
    var row = lastAbs
    while out.count < n, row >= 0 {
        guard let l = t.getScrollInvariantLine(row: row) else { break }
        out.append(l.translateToString(trimRight: true))
        row -= 1
    }
    return out.reversed()
}

/// Proves the client never corrupts the byte stream: multi-byte UTF-8 sequences and
/// escape sequences are split across 64 KiB PTY reads and across socket reads, and the
/// gzip replay path adds another seam. The fixture writes the identical bytes to a file,
/// which is the ground truth.
func runUTF8() throws {
    print("## Byte-exactness across frame and UTF-8 boundaries\n")
    let truth = FileManager.default.currentDirectoryPath + "/out/utf8-truth.bin"
    try? FileManager.default.removeItem(atPath: truth)

    // (a) LIVE path: attach first, then let the generator run, capture DATA frames.
    let id = try spawnOwn(fixtures + "/utf8gen.pl", [truth, "6000"], cols: 100, rows: 40)
    var live = [UInt8]()
    let lk = NSLock()
    let s = RelaySession(id: id)
    s.onData = { d in lk.lock(); live.append(contentsOf: d); lk.unlock() }
    s.onReplay = { p, _ in lk.lock(); live.append(contentsOf: p); lk.unlock() }
    let sem = DispatchSemaphore(value: 0); s.onHandshake = { _ in sem.signal() }
    try s.connect()
    _ = sem.wait(timeout: .now() + 10)
    _ = waitUntil(60) {
        guard let a = try? FileManager.default.attributesOfItem(atPath: truth),
              let sz = a[.size] as? Int else { return false }
        return sz > 0 && (RelaySessionMeta.read(id: id)?.totalBytesWritten ?? 0) >= Double(sz)
    }
    usleep(1_500_000)
    var expect = [UInt8]((try? Data(contentsOf: URL(fileURLWithPath: truth))) ?? Data())
    // The PTY line discipline has ONLCR set, so every LF the program writes reaches the
    // client as CRLF. Apply the same translation to the ground truth.
    var crlf = [UInt8](); crlf.reserveCapacity(expect.count + 8192)
    for b in expect { if b == 0x0a { crlf.append(0x0d) }; crlf.append(b) }
    expect = crlf
    lk.lock(); let got = live; lk.unlock()
    print("- ground truth: \(expect.count) bytes (after ONLCR LF->CRLF); client received \(got.count) bytes over \(s.dataFrames) DATA frames")
    print("- live stream contains the ground truth verbatim: **\(contains(got, expect) ? "YES" : "NO")**")
    s.close()

    // (b) REPLAY path (this one is >4 KiB so it comes back gzipped).
    let r = try attachAndWait(id) { rs in
        rs.onReplay = { _, _ in }
    }
    var replayBytes = [UInt8]()
    let r2 = RelaySession(id: id)
    let sem2 = DispatchSemaphore(value: 0)
    r2.onReplay = { p, _ in replayBytes = p }
    r2.onHandshake = { _ in sem2.signal() }
    try r2.connect()
    _ = sem2.wait(timeout: .now() + 20)
    print("- replay: wire \(r2.timings.replayWireBytes) B -> inflated \(r2.timings.replayPlainBytes) B (gzip=\(r2.timings.replayWasGz))")
    print("- inflated replay contains the ground truth verbatim: **\(contains(replayBytes, expect) ? "YES" : "NO")**")

    // (c) the emulator's own view: are the wide/combining characters where they should be?
    let (term, d) = headlessTerminal(cols: 100, rows: 40)
    delegates.append(d)
    term.feed(buffer: replayBytes[...])
    let rows = screenText(term)
    let rows2 = (0..<term.rows).map { term.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" }
    _ = rows
    let lastLine = rows2.reversed().first { $0.hasPrefix("L0") } ?? ""
    print("- SwiftTerm renders the tail line as: `\(lastLine)`")
    // focused glyph check
    let (t2, d2) = headlessTerminal(cols: 40, rows: 4)
    delegates.append(d2)
    t2.feed(buffer: Array("A\u{1F600}B\u{65E5}C\u{0301}e\u{1F1FA}\u{1F1F8}D\r\n".utf8)[...])
    var cells = [String]()
    for c in 0..<14 {
        let ch = t2.getCharacter(col: c, row: 0)
        cells.append(ch.map { $0 == " " ? "_" : String($0) } ?? "?")
    }
    print("- per-cell decode of `A😀B日C\u{0301}e🇺🇸D`: \(cells.joined(separator: "|"))")
    print("- translateToString: `\(t2.getLine(row: 0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "")`")
    r.close(); r2.close()
    cleanup()
}

func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, hay.count >= needle.count else { return false }
    let n = needle.count
    let first = needle[0]
    var i = 0
    while i <= hay.count - n {
        if hay[i] == first {
            var ok = true
            var k = 1
            while k < n { if hay[i + k] != needle[k] { ok = false; break }; k += 1 }
            if ok { return true }
        }
        i += 1
    }
    return false
}

/// Deliberately stall a reader to prove the Lagged(n) hazard is real AND that the
/// detector used in `load` would catch it. Without this, "0 gaps" is unfalsifiable.
func runLagged() throws {
    print("## Lagged(n): the 256-frame broadcast channel, and whether we can see a drop\n")
    for (label, stallMs) in [("prompt reader (drain every readable event)", 0),
                             ("stalled reader (50 ms sleep per DATA frame)", 50)] {
        // endless flat-out generator, a fresh session per reader
        let id = try spawnOwn(fixtures + "/gen.pl", ["0", "0"], cols: 200, rows: 50)
        usleep(1_500_000)
        let tr = SeqTracker(); tr.armed = true
        let s = RelaySession(id: id)
        var frames = 0
        s.onReplay = { _, _ in }
        s.onData = { d in
            tr.feed(d); frames += 1
            if stallMs > 0 { usleep(UInt32(stallMs) * 1000) }
        }
        var closed = false
        s.onClosed = { closed = true }
        var syncAt = 0.0
        s.onSync = { v in if syncAt == 0 { syncAt = v } }
        let sem = DispatchSemaphore(value: 0); s.onHandshake = { _ in sem.signal() }
        try s.connect()
        _ = sem.wait(timeout: .now() + 15)
        usleep(15_000_000)
        // stop the generator and let the metadata flush catch up before comparing
        RelaySpawn.kill(id: id); spawned.removeAll { $0 == id }
        usleep(7_000_000)
        let host = RelaySessionMeta.read(id: id)?.totalBytesWritten ?? 0
        print("- **\(label)**: handshake SYNC=\(Int(syncAt)); \(frames) DATA frames / \(s.dataBytes) B in 15 s; \(tr.count) SEQ lines; SEQ gaps=\(tr.gaps) (\(tr.gapLines) lines); socket closed by host=\(closed); client offset=\(Int(s.offset)) vs host total_written=\(Int(host)) -> **behind by \(Int(host - s.offset)) B (\(String(format: "%.1f", (host - s.offset) / max(host,1) * 100))% of the session)**")
        s.close()
        usleep(500_000)
    }
    cleanup()
}
