// Spike M7 — one remote relay-tty session, measured.
//
// The transport under test is the app's own `RelayClient` (symlinked into
// this package), so a number here is a number for the app. Every command
// prints human lines to stderr and one JSON line to stdout, so a run can be
// read by a person and kept by a script.
//
//   RELAY_TOKEN=… m7 <command> (--base https://slug.relaytty.com | --unix /path/sock) --id ID [options]
//
// The token is read from the environment only and never printed.
import Foundation
import CryptoKit
import RelayClient
import CProcInfo

// MARK: - arguments

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: m7 <probe|echo|stream|replay|watch|paste|reconnect> (--base URL | --unix PATH) --id ID
              [--auth cookie|query|none] [--n N] [--gap S] [--seconds S] [--bytes N]
              [--trigger TEXT] [--out FILE] [--wait S] [--clamp BYTES]
    \n
    """.utf8))
    exit(2)
}

func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func optDouble(_ name: String, _ d: Double) -> Double { opt(name).flatMap(Double.init) ?? d }
func optInt(_ name: String, _ d: Int) -> Int { opt(name).flatMap(Int.init) ?? d }

let sessionId = opt("id") ?? "0368d543"
let authPlacement = RelayServer.TokenPlacement(rawValue: opt("auth") ?? "cookie") ?? .cookie
let token = ProcessInfo.processInfo.environment["RELAY_TOKEN"].flatMap { $0.isEmpty ? nil : $0 }
let queue = DispatchQueue(label: "m7")

enum Path { case unix(String), ws(RelayServer) }
let path: Path
if let unix = opt("unix") {
    path = .unix(unix)
} else if let base = opt("base"), let url = URL(string: base) {
    // `none` means send no credential at all, whatever the environment holds.
    path = .ws(RelayServer(baseURL: url, token: authPlacement == .none ? nil : token, placement: authPlacement))
} else {
    usage()
}

var lastWS: WebSocketTransport?
func makeTransport() -> RelayTransport {
    switch path {
    case .unix(let p): return UnixSocketTransport(socketPath: p, queue: queue)
    case .ws(let server):
        let t = WebSocketTransport(server: server, sessionId: sessionId, queue: queue)
        lastWS = t
        return t
    }
}
var pathLabel: String {
    switch path {
    case .unix(let p): return "unix:\(p)"
    case .ws(let s): return "\(s.webSocketURL(sessionId: sessionId).absoluteString) auth=\(s.placement.rawValue) token=\(s.token == nil ? "none" : "set")"
    }
}

// MARK: - helpers

let t0 = now()
func log(_ s: String) {
    FileHandle.standardError.write(Data((String(format: "%9.3f  ", now() - t0) + s + "\n").utf8))
}
func emit(_ obj: [String: Any]) {
    var o = obj
    o["command"] = command
    o["path"] = pathLabel
    o["session"] = sessionId
    let data = try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])
    FileHandle.standardOutput.write(data + Data([0x0a]))
}
func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    let rank = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[min(max(rank, 0), sorted.count - 1)]
}
func ms(_ s: Double) -> Double { (s * 1000 * 1000).rounded() / 1000 }
func footprintMB() -> Double { Double(cproc_footprint(getpid())) / 1_048_576 }
func hex(_ b: UInt8) -> String { String(format: "0x%02x", b) }

final class Box<T>: @unchecked Sendable { var v: T; init(_ v: T) { self.v = v } }
let lock = NSLock()
func locked<T>(_ f: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return f() }

/// Wait until `cond` or the deadline, on the main thread, polling.
@discardableResult
func wait(_ seconds: Double, _ cond: () -> Bool) -> Bool {
    let end = now() + seconds
    while now() < end { if cond() { return true }; usleep(2000) }
    return cond()
}

/// A session with the counters every command wants.
final class Probe: @unchecked Sendable {
    let session: RelaySession
    var frames: [(Double, UInt8, Int)] = []          // (t, type, len)
    var handshake: AttachTimings?
    var closed: RelayClose?
    var closedAt: Double = 0
    var replay: (plain: [UInt8], delta: Bool)?
    var syncs: [Double] = []
    var titles: [String] = []
    var states: [Bool] = []
    var exit: Int32?
    var dataHasher = SHA256()
    var dataBytes = 0
    var dataFrames = 0
    var firstData: Double = 0
    var lastData: Double = 0
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?

    init() {
        session = RelaySession(id: sessionId, queue: queue, transport: makeTransport())
        session.onPayload = { [unowned self] type, body in
            locked { self.frames.append((now(), type, body.count)) }
            self.onPayload?(type, body)
        }
        session.onData = { [unowned self] bytes in
            locked {
                self.dataHasher.update(data: Data(bytes))
                self.dataBytes += bytes.count; self.dataFrames += 1
                if self.firstData == 0 { self.firstData = now() }
                self.lastData = now()
            }
            self.onData?(bytes)
        }
        session.onReplay = { [unowned self] plain, delta in locked { self.replay = (plain, delta) } }
        session.onSync = { [unowned self] v in locked { self.syncs.append(v) } }
        session.onTitle = { [unowned self] t in locked { self.titles.append(t) } }
        session.onSessionState = { [unowned self] s in locked { self.states.append(s) } }
        session.onHandshake = { [unowned self] t in locked { self.handshake = t } }
        session.onExit = { [unowned self] c in locked { self.exit = c } }
        session.onClosed = { [unowned self] in locked { self.closed = self.session.closeReason; self.closedAt = now() } }
        session.onGzipError = { e in log("gzip error \(e)") }
    }

    var isDone: Bool { locked { handshake != nil } }
    var isClosed: Bool { locked { closed != nil } }
    func frameSummary() -> [String] {
        locked { frames.map { String(format: "+%.3f %@ %d", $0.0 - session.timings.tStart, hex($0.1), $0.2) } }
    }
    func summary() -> [String: Any] {
        locked {
            var o: [String: Any] = [
                "handshake": handshake != nil,
                "frames": frames.map { [hex($0.1), $0.2] },
                "syncs": syncs, "titles": titles, "sessionStates": states,
                "offset": session.offset, "cols": session.hostCols, "rows": session.hostRows,
                "dataBytes": dataBytes, "dataFrames": dataFrames,
                "footprintMB": footprintMB(),
            ]
            if let h = handshake {
                o["tConnectedMs"] = ms(session.transport.tConnected - h.tStart)
                o["tResumeSentMs"] = ms(h.tResumeSent - h.tStart)
                o["tFirstFrameMs"] = ms(h.tFirstFrame - h.tStart)
                o["tSyncMs"] = ms(h.tSync - h.tStart)
                o["replayWireBytes"] = h.replayWireBytes
                o["replayPlainBytes"] = h.replayPlainBytes
                o["replayGz"] = h.replayWasGz
                o["replayDelta"] = h.replayWasDelta
                if h.tReplayFrame > 0 { o["tReplayFrameMs"] = ms(h.tReplayFrame - h.tStart) }
            }
            if let c = closed { o["close"] = c.description; o["closeFinal"] = c.isFinal; o["closeCode"] = c.code }
            if let e = exit { o["exit"] = e }
            if let w = lastWS {
                o["ws"] = ["inboundPayloads": w.inboundPayloads, "inboundBytes": w.inboundBytes,
                           "textDropped": w.textFramesDropped, "pings": w.pingsSent, "pongs": w.pongsReceived,
                           "upgradeStatus": w.upgradeStatus]
            }
            return o
        }
    }
}

// MARK: - commands

switch command {

case "probe":
    // Connect, send RESUME, report every frame for `--wait` seconds and how
    // the connection ended. This is the auth measurement: with no credential,
    // a wrong one, and the right one, what comes back?
    let clamp = optDouble("clamp", 4096)
    let p = Probe()
    log("connect \(pathLabel)")
    do { try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: clamp)) } catch { log("connect failed: \(error)"); emit(["error": "\(error)"]); exit(1) }
    wait(optDouble("wait", 5)) { p.isClosed }
    for l in p.frameSummary() { log(l) }
    if let c = locked({ p.closed }) { log("closed: \(c)") } else { log("still open after wait") }
    var o = p.summary()
    o["outcome"] = p.isDone ? "handshake" : (p.isClosed ? "closed-before-handshake" : "no-frames")
    emit(o)
    p.session.close()

case "echo":
    // Keystroke → echo. The session runs `cat`: the tty echoes each byte
    // itself, so this is the transport and pty-host and nothing else.
    let n = optInt("n", 200), gap = optDouble("gap", 0.1)
    let p = Probe()
    let want = Box<UInt8?>(nil), got = Box<Double>(0)
    p.onData = { bytes in
        if let w = locked({ want.v }), bytes.contains(w) { locked { got.v = now(); want.v = nil } }
    }
    try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: 1024))
    guard wait(15, { p.isDone }) else { log("no handshake"); emit(["error": "no handshake"] ); exit(1) }
    usleep(300_000)
    var samples: [Double] = [], lost = 0
    let letters = Array("abcdefghijklmnopqrstuvwxyz".utf8)
    for i in 0..<n {
        let b = letters[i % letters.count]
        locked { want.v = b; got.v = 0 }
        let sent = now()
        p.session.sendInput([b])
        if wait(5, { locked { got.v } > 0 }) { samples.append(locked { got.v } - sent) } else { lost += 1; log("echo \(i) lost") }
        usleep(UInt32(gap * 1_000_000))
    }
    let s = samples.sorted()
    let out: [String: Any] = ["n": samples.count, "lost": lost,
        "minMs": ms(s.first ?? .nan), "p50Ms": ms(percentile(s, 0.5)), "p90Ms": ms(percentile(s, 0.9)),
        "p95Ms": ms(percentile(s, 0.95)), "p99Ms": ms(percentile(s, 0.99)), "maxMs": ms(s.last ?? .nan),
        "samplesMs": s.map(ms)]
    log("echo n=\(samples.count) lost=\(lost) p50=\(out["p50Ms"]!) p95=\(out["p95Ms"]!) max=\(out["maxMs"]!) ms")
    emit(out.merging(p.summary()) { a, _ in a })
    p.session.close()

case "stream":
    // Attach with the replay clamped to nothing, optionally type a trigger,
    // then hash every DATA byte for `--seconds`. Two of these on two paths
    // against one session are the byte-exactness measurement.
    let seconds = optDouble("seconds", 30)
    let p = Probe()
    try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: 1))
    guard wait(15, { p.isDone }) else { log("no handshake"); emit(["error": "no handshake"]); exit(1) }
    let startOffset = p.session.offset
    log("handshake offset=\(startOffset) replay=\(p.session.timings.replayPlainBytes)B")
    if let trig = opt("trigger") {
        usleep(200_000)
        p.session.sendInput(Array(trig.replacingOccurrences(of: "\\r", with: "\r").utf8))
        log("trigger sent")
    }
    wait(seconds) { p.isClosed }
    let (hash, bytes, frames, first, last) = locked { (p.dataHasher, p.dataBytes, p.dataFrames, p.firstData, p.lastData) }
    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    let dur = last - first
    log("data bytes=\(bytes) frames=\(frames) sha256=\(digest) offset=\(p.session.offset) span=\(ms(dur))ms")
    if let out = opt("out") { try? "\(digest) \(bytes)\n".write(toFile: out, atomically: true, encoding: .utf8) }
    emit(["startOffset": startOffset, "endOffset": p.session.offset, "dataSha256": digest, "dataBytes": bytes,
          "dataFrames": frames, "spanMs": ms(dur), "bytesPerSec": dur > 0 ? Double(bytes) / dur : 0]
          .merging(p.summary()) { a, _ in a })
    p.session.close()

case "replay":
    // A fresh attach with no clamp: the whole ring, as a full replay.
    let p = Probe()
    try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: nil))
    guard wait(60, { p.isDone }) else { log("no handshake"); emit(["error": "no handshake"]); exit(1) }
    usleep(200_000)
    let r = locked { p.replay }
    let plain = r?.plain ?? []
    let digest = sha256(plain)
    let lines = plain.reduce(0) { $0 + ($1 == 0x0a ? 1 : 0) }
    if let out = opt("out") { try Data(plain).write(to: URL(fileURLWithPath: out)) }
    let h = p.session.timings
    log("replay plain=\(plain.count)B wire=\(h.replayWireBytes)B gz=\(h.replayWasGz) delta=\(r?.delta ?? false) lines=\(lines) sha256=\(digest) sync=\(p.session.offset) in \(ms(h.tSync - h.tStart))ms")
    emit(["replaySha256": digest, "replayLines": lines].merging(p.summary()) { a, _ in a })
    p.session.close()

case "watch":
    // Every payload with its arrival time; SESSION_UPDATE decoded; OSC 7 found.
    let seconds = optDouble("seconds", 60)
    let p = Probe()
    let osc7 = Box<[(Double, String)]>([])
    func scanOSC7(_ bytes: ArraySlice<UInt8>, _ label: String) {
        let arr = Array(bytes)
        var i = 0
        while i + 3 < arr.count {
            if arr[i] == 0x1b, arr[i + 1] == 0x5d, arr[i + 2] == 0x37, arr[i + 3] == 0x3b {
                var j = i + 4; var s = ""
                while j < arr.count, arr[j] != 0x07, arr[j] != 0x1b { s.append(Character(UnicodeScalar(arr[j]))); j += 1 }
                let t = now() - p.session.timings.tStart
                locked { osc7.v.append((t, s)) }
                log("OSC 7 in \(label) at +\(ms(t))ms: \(s)")
                i = j
            }
            i += 1
        }
    }
    p.onPayload = { type, body in
        let t = now() - p.session.timings.tStart
        switch type {
        case WSMsg.sessionUpdate:
            var desc = ""
            if let j = try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] {
                desc = "id=\(j["id"] ?? "") agentState=\(j["agentState"] ?? "-") cwd=\(j["cwd"] ?? "-") title=\(j["title"] ?? "-") status=\(j["status"] ?? "-")"
            }
            log("SESSION_UPDATE +\(ms(t))ms \(body.count)B \(desc)")
        case WSMsg.data: scanOSC7(body, "DATA")
        case WSMsg.bufferReplay: scanOSC7(body, "BUFFER_REPLAY")
        case WSMsg.pong: break
        case WSMsg.title: log("TITLE +\(ms(t))ms \(String(decoding: body, as: UTF8.self))")
        case WSMsg.sessionState: log("SESSION_STATE +\(ms(t))ms \(body.first ?? 0)")
        default: log("frame \(hex(type)) +\(ms(t))ms \(body.count)B")
        }
    }
    p.session.onReplay = { plain, delta in locked { p.replay = (plain, delta) }; scanOSC7(plain[...], "replay(\(delta ? "delta" : "full"))") }
    let show = args.contains("--show")
    p.onData = { bytes in
        guard show else { return }
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\u{1b}", with: "␛").replacingOccurrences(of: "\r\n", with: "⏎")
        log("DATA \(bytes.count)B \(text.prefix(160))")
    }
    try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: nil))
    // `--type TEXT --after S`: one keystroke burst into the session, timed, so
    // an agent-state change can be provoked and its SESSION_UPDATE clocked.
    var typedAt: Double = 0
    if let text = opt("type") {
        let after = optDouble("after", 3)
        wait(after) { p.isClosed }
        let bytes = Array(text.replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\e", with: "\u{1b}").utf8)
        typedAt = now()
        p.session.sendInput(bytes)
        log("typed \(bytes.count)B at +\(ms(typedAt - p.session.timings.tStart))ms")
    }
    wait(seconds) { p.isClosed }
    emit(["osc7": locked { osc7.v.map { [ms($0.0), $0.1] } }, "typedAtMs": typedAt > 0 ? ms(typedAt - p.session.timings.tStart) : 0].merging(p.summary()) { a, _ in a })
    p.session.close()

case "paste":
    // One DATA payload of `--bytes`, as ⌘V would send it. The session at the
    // far end writes what it reads to a file; the box's sha256 is the check.
    let n = optInt("bytes", 4096)
    var payload = [UInt8]()
    var line = 0
    while payload.count < n {
        let s = String(format: "%06d:0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\n", line); line += 1
        payload.append(contentsOf: Array(s.utf8))
    }
    payload = Array(payload.prefix(n))
    let p = Probe()
    try p.session.connect(mode: .resume(offset: 0, maxReplayBytes: 1))
    guard wait(15, { p.isDone }) else { log("no handshake"); emit(["error": "no handshake"]); exit(1) }
    usleep(300_000)
    let sent = now()
    p.session.sendInput(payload)
    wait(optDouble("wait", 3)) { false }
    log("sent \(payload.count)B in one DATA payload sha256=\(sha256(payload)) echoedBytes=\(locked { p.dataBytes })")
    emit(["sentBytes": payload.count, "sentSha256": sha256(payload), "sentAtMs": ms(sent - t0)].merging(p.summary()) { a, _ in a })
    p.session.close()

case "reconnect":
    // The adapter's policy, in the open: connect, resume from the last
    // offset on every close, back off 0.5 s → 15 s, stop on a final close.
    // Run this while the network is taken away, and read what it logs.
    let seconds = optDouble("seconds", 300)
    var lastOffset: Double = 0
    var delay = 0.5
    var attempts = 0
    var events: [[String: Any]] = []
    var current: Probe?
    let end = now() + seconds
    while now() < end {
        attempts += 1
        let p = Probe()
        current = p
        let off = lastOffset
        let started = now()
        p.onData = { bytes in
            let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "⏎")
            log("DATA \(bytes.count)B offset→\(p.session.offset)  \(text.prefix(80))")
        }
        do {
            try p.session.connect(mode: .resume(offset: off, maxReplayBytes: off > 0 ? nil : 262_144))
        } catch {
            log("attempt \(attempts): connect threw \(error)"); events.append(["attempt": attempts, "error": "\(error)"])
            usleep(UInt32(delay * 1_000_000)); delay = min(delay * 2, 15); continue
        }
        log("attempt \(attempts): connecting from offset \(off)")
        if wait(30, { p.isDone || p.isClosed }), p.isDone {
            let h = p.session.timings
            let r = locked { p.replay }
            log("attempt \(attempts): handshake in \(ms(h.tSync - h.tStart))ms replay=\(h.replayPlainBytes)B delta=\(h.replayWasDelta) sync=\(p.session.offset) replayText=\(String(decoding: (r?.plain ?? []).suffix(120), as: UTF8.self).replacingOccurrences(of: "\r\n", with: "⏎"))")
            events.append(["attempt": attempts, "fromOffset": off, "handshakeMs": ms(h.tSync - h.tStart),
                           "replayBytes": h.replayPlainBytes, "delta": h.replayWasDelta, "sync": p.session.offset,
                           "atMs": ms(started - t0)])
            delay = 0.5
        }
        wait(end - now()) { p.isClosed }
        lastOffset = p.session.offset
        if let c = locked({ p.closed }) {
            let downAt = locked { p.closedAt }
            log("attempt \(attempts): closed after \(ms(downAt - started))ms — \(c) final=\(c.isFinal) lastOffset=\(lastOffset) pings=\(lastWS?.pingsSent ?? 0) pongs=\(lastWS?.pongsReceived ?? 0)")
            events.append(["attempt": attempts, "closed": c.description, "final": c.isFinal, "afterMs": ms(downAt - started),
                           "lastOffset": lastOffset, "atMs": ms(downAt - t0)])
            if c.isFinal { break }
        } else {
            break
        }
        log("attempt \(attempts): reconnect in \(delay)s")
        usleep(UInt32(delay * 1_000_000)); delay = min(delay * 2, 15)
    }
    current?.session.close()
    emit(["attempts": attempts, "events": events, "finalOffset": lastOffset])

default:
    usage()
}
exit(0)
