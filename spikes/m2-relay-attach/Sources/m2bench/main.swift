import Foundation
import SwiftTerm
import RelayClient

let fixtures = FileManager.default.currentDirectoryPath + "/fixtures"
let argv = Array(CommandLine.arguments.dropFirst())
let cmd = argv.first ?? "help"

var spawned: [String] = []
func cleanup() {
    for id in spawned { RelaySpawn.kill(id: id) }
    if !spawned.isEmpty { FileHandle.standardError.write("cleaned up \(spawned.count) spawned sessions\n".data(using: .utf8)!) }
    spawned.removeAll()
}
func onSignal(_ s: Int32) { cleanup(); exit(128 + s) }
signal(SIGINT) { s in onSignal(s) }
signal(SIGTERM) { s in onSignal(s) }

@discardableResult
func spawnOwn(_ command: String, _ a: [String] = [], cols: Int = 80, rows: Int = 24) throws -> String {
    let id = try RelaySpawn.spawn(command: command, args: a,
                                  cwd: NSTemporaryDirectory(), cols: cols, rows: rows)
    spawned.append(id)
    return id
}

/// Attach and block until SYNC. Returns the session (still open) and its timings.
func attachAndWait(_ id: String, offset: Double = 0, timeout: Double = 10,
                   configure: ((RelaySession) -> Void)? = nil) throws -> RelaySession {
    let s = RelaySession(id: id)
    let sem = DispatchSemaphore(value: 0)
    s.onHandshake = { _ in sem.signal() }
    configure?(s)
    try s.connect(mode: .resume(offset: offset, maxReplayBytes: nil))
    if sem.wait(timeout: .now() + timeout) == .timedOut {
        FileHandle.standardError.write("handshake timeout on \(id)\n".data(using: .utf8)!)
    }
    return s
}

func headlessTerminal(cols: Int, rows: Int) -> (Terminal, NullTermDelegate) {
    let d = NullTermDelegate()
    var opts = TerminalOptions.default
    opts.cols = cols; opts.rows = rows; opts.scrollback = 5000
    return (Terminal(delegate: d, options: opts), d)
}

func screenText(_ t: Terminal) -> [String] {
    (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
}

// ---------------------------------------------------------------------------

switch cmd {

// ── 0. smoke ───────────────────────────────────────────────────────────────
case "smoke":
    let id = try spawnOwn("/bin/zsh")
    let s = try attachAndWait(id) { s in
        s.onResize = { c, r in print("  <- RESIZE \(c)x\(r)") }
        s.onReplay = { p, d in print("  <- REPLAY \(p.count)B isDelta=\(d)") }
        s.onSync   = { print("  <- SYNC \($0)") }
        s.onTitle  = { print("  <- TITLE \($0)") }
        s.onSessionState = { print("  <- SESSION_STATE active=\($0)") }
    }
    let t = s.timings
    print(String(format: "  resume sent +%.3fms after connect() start (deadline 100ms)",
                 (t.tResumeSent - t.tStart) * 1000))
    print(String(format: "  handshake (connect->SYNC) %.3fms", (t.tSync - t.tStart) * 1000))
    s.close(); cleanup()

// ── 2. attach latency ──────────────────────────────────────────────────────
case "attach":
    let n = Int(argv.count > 1 ? argv[1] : "25") ?? 25
    let targetMB = Double(argv.count > 2 ? argv[2] : "5") ?? 5

    print("## Attach latency\n")
    // (a) small session: a shell that has printed a prompt only
    let smallID = try spawnOwn("/bin/zsh", cols: 80, rows: 24)
    usleep(1_500_000)
    // (b) big-scrollback session: ~targetMB of output, then idle
    let bigID = try spawnOwn(fixtures + "/gen.pl", ["0", "85000"], cols: 80, rows: 24)
    print("small=\(smallID) big=\(bigID); filling scrollback to \(targetMB) MB ...")
    var lastSeen = -1.0, stable = 0
    let filled = waitUntil(180) {
        let v = RelaySessionMeta.read(id: bigID)?.totalBytesWritten ?? 0
        if v >= targetMB * 1_048_576 { if v == lastSeen { stable += 1 } else { stable = 0 } }
        lastSeen = v
        return stable >= 3
    }
    let bigBytes = RelaySessionMeta.read(id: bigID)?.totalBytesWritten ?? 0
    print(String(format: "  big session totalBytesWritten = %.0f (%.2f MB) filled=%@",
                 bigBytes, bigBytes / 1_048_576, filled ? "yes" : "TIMEOUT"))
    usleep(1_000_000)

    for (label, id) in [("small", smallID), ("big", bigID)] {
        // Pass 1: protocol only — the replay is received and inflated but NOT fed to an
        // emulator, so connect->SYNC is the pure wire+decode cost.
        var pureSync = [Double]()
        for _ in 0..<n {
            let s = RelaySession(id: id)
            let sem = DispatchSemaphore(value: 0)
            s.onReplay = { _, _ in }
            s.onHandshake = { _ in sem.signal() }
            try s.connect()
            _ = sem.wait(timeout: .now() + 30)
            pureSync.append((s.timings.tSync - s.timings.tStart) * 1000)
            s.close(); usleep(40_000)
        }
        var toSync = [Double](), toReplay = [Double](), toDecoded = [Double]()
        var toFed = [Double](), inflate = [Double](), feedOnly = [Double]()
        var wire = 0, plain = 0, gz = false
        for _ in 0..<n {
            let (term, _) = headlessTerminal(cols: 80, rows: 24)
            var tFed = 0.0, tFeedStart = 0.0
            let s = RelaySession(id: id)
            let sem = DispatchSemaphore(value: 0)
            s.onReplay = { p, isDelta in
                if !isDelta { term.resetToInitialState() }
                tFeedStart = now()
                term.feed(buffer: p[...])
                tFed = now()
            }
            s.onHandshake = { _ in sem.signal() }
            try s.connect()
            _ = sem.wait(timeout: .now() + 30)
            let t = s.timings
            toSync.append((t.tSync - t.tStart) * 1000)
            if t.tReplayFrame > 0 {
                toReplay.append((t.tReplayFrame - t.tStart) * 1000)
                toDecoded.append((t.tReplayDecoded - t.tStart) * 1000)
                inflate.append((t.tReplayDecoded - t.tReplayFrame) * 1000)
                toFed.append((tFed - t.tStart) * 1000)
                feedOnly.append((tFed - tFeedStart) * 1000)
                wire = t.replayWireBytes; plain = t.replayPlainBytes; gz = t.replayWasGz
            }
            s.close()
            usleep(60_000)
        }
        print("\n### \(label) session (\(id)) — replay wire=\(wire)B plain=\(plain)B gz=\(gz)")
        print(Stats.header)
        print(Stats("connect -> SYNC, protocol only (no emulator)", pureSync).row)
        print(Stats("connect -> SYNC, replay fed inline", toSync).row)
        if !toReplay.isEmpty {
            print(Stats("connect -> replay frame", toReplay).row)
            print(Stats("gzip inflate", inflate).row)
            print(Stats("connect -> replay decoded", toDecoded).row)
            print(Stats("SwiftTerm feed (parse only)", feedOnly).row)
            print(Stats("connect -> replay parsed into Terminal", toFed).row)
        }
    }

    // delta reattach: connect at the current offset -> caught up, no replay frame
    let live = try attachAndWait(bigID)
    let off = live.offset
    live.close()
    var deltaSync = [Double]()
    for _ in 0..<n {
        let s = RelaySession(id: bigID)
        let sem = DispatchSemaphore(value: 0)
        s.onHandshake = { _ in sem.signal() }
        try s.connect(mode: .resume(offset: off, maxReplayBytes: nil))
        _ = sem.wait(timeout: .now() + 10)
        deltaSync.append((s.timings.tSync - s.timings.tStart) * 1000)
        s.close(); usleep(30_000)
    }
    print("\n### delta reattach at offset \(off) (caught up: no replay frame at all)")
    print(Stats.header)
    print(Stats("connect -> SYNC", deltaSync).row)
    cleanup()

// ── 3. echo round-trip ─────────────────────────────────────────────────────
case "echo":
    let n = Int(argv.count > 1 ? argv[1] : "150") ?? 150
    print("## Input -> echo round trip\n")
    for (label, command, cargs) in [("zsh (interactive shell, ZLE)", "/bin/zsh", [String]()),
                                    ("cat (bare PTY echo floor)", "/bin/cat", [])] {
        let id = try spawnOwn(command, cargs, cols: 80, rows: 24)
        usleep(2_000_000)
        let s = try attachAndWait(id)
        let lock = NSLock()
        var sentAt = 0.0, waiting = false, hit = 0.0
        let sem = DispatchSemaphore(value: 0)
        s.onData = { d in
            lock.lock(); defer { lock.unlock() }
            guard waiting else { return }
            if d.contains(UInt8(ascii: "a")) { hit = now(); waiting = false; sem.signal() }
        }
        var rtt = [Double](), misses = 0
        for i in 0..<(n + 10) {
            lock.lock(); waiting = true; sentAt = now(); lock.unlock()
            s.sendInput([UInt8(ascii: "a")])
            if sem.wait(timeout: .now() + 1.0) == .timedOut {
                lock.lock(); waiting = false; lock.unlock(); misses += 1
            } else if i >= 10 {                      // discard 10 warm-ups
                rtt.append((hit - sentAt) * 1000)
            }
            // erase it again so the line never grows
            s.sendInput([0x7f])
            usleep(15_000)
        }
        print("\n### \(label) — session \(id), misses=\(misses)")
        print(Stats.header)
        print(Stats("keystroke -> echoed byte", rtt).row)
        s.close()
        RelaySpawn.kill(id: id); spawned.removeAll { $0 == id }
    }
    cleanup()

case "resize":
    try runResize()

case "conflict":
    try runConflict()

case "load":
    try runLoad(Int(argv.count > 1 ? argv[1] : "30") ?? 30,
                rate: Int(argv.count > 2 ? argv[2] : "200") ?? 200)

case "observe":
    try runObserve(argv.count > 1 ? argv[1] : "")

default:
    print("usage: m2bench <smoke|attach|echo|resize|conflict|load|observe>")
}
