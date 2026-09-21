import Foundation

public struct AttachTimings {
    public init() {}
    public var tStart: Double = 0          // just before socket()/connect()
    public var tConnected: Double = 0      // connect() returned
    public var tResumeSent: Double = 0     // RESUME written (must be < tStart + 100ms)
    public var tFirstFrame: Double = 0     // first inbound byte parsed
    public var tResize: Double = 0         // inbound RESIZE (always frame #1)
    public var tReplayFrame: Double = 0    // replay frame arrived (0 if none)
    public var tReplayDecoded: Double = 0  // gzip inflate done (0 if none)
    public var tSync: Double = 0           // SYNC -> handshake complete
    public var replayWireBytes: Int = 0
    public var replayPlainBytes: Int = 0
    public var replayWasGz = false
    public var replayWasDelta = false
}

public enum AttachMode { case resume(offset: Double, maxReplayBytes: Double?), observe }

public final class RelaySession {
    public let id: String
    public let socketPath: String
    public let queue: DispatchQueue
    /// The wire under the protocol. `UnixSocketTransport` unless the caller
    /// says otherwise; `handle` below never knows which.
    public let transport: RelayTransport

    /// Offset accounting (reference §3.4). DATA adds; replays add NOTHING; SYNC assigns.
    public private(set) var offset: Double = 0
    public private(set) var hostCols = 0
    public private(set) var hostRows = 0
    public private(set) var handshakeDone = false
    public private(set) var timings = AttachTimings()
    /// Why the transport stopped, once it has. `isFinal` means do not reconnect.
    public private(set) var closeReason: RelayClose?

    // Counters for the bench
    public private(set) var dataFrames = 0
    public private(set) var dataBytes = 0

    public var onData: ((ArraySlice<UInt8>) -> Void)?
    public var onReplay: ((/*plain*/ [UInt8], /*isDelta*/ Bool) -> Void)?
    public var onResize: ((Int, Int) -> Void)?
    public var onSync: ((Double) -> Void)?
    public var onHandshake: ((AttachTimings) -> Void)?
    public var onTitle: ((String) -> Void)?
    public var onSessionState: ((Bool) -> Void)?
    /// SESSION_METRICS (0x14): bytes/sec over 1, 5 and 15 minutes, plus the
    /// session's lifetime byte total. This is the live throughput the RelayTTY
    /// web app shows as "1.7KB/s".
    public var onMetrics: ((_ bps1: Double, _ bps5: Double, _ bps15: Double, _ total: Double) -> Void)?
    public var onClearScrollback: (() -> Void)?
    /// CLIPBOARD (0x16): text somebody wants on this client's clipboard.
    ///
    /// From pty-host it is an OSC 52 write, which pty-host lifts *out* of the
    /// output stream: the escape sequence itself never arrives as DATA. Over a
    /// WebSocket it is also what another client of the session sends when it
    /// copies (the server fans it out), and the two cannot be told apart. The
    /// session only delivers it; whether it may touch a clipboard is the
    /// app's decision (ADR-0028). Empty and over-long payloads are dropped
    /// here, at the size both relay-tty ends already enforce.
    public var onClipboard: ((String) -> Void)?
    public static let maxClipboardBytes = 1 << 20
    public var onExit: ((Int32) -> Void)?
    public var onClosed: (() -> Void)?
    public var onGzipError: ((Error) -> Void)?
    /// Every payload before `handle` sees it, for a bench that wants the ones
    /// `handle` ignores (`SESSION_UPDATE`, `PONG`). Not for the app.
    public var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?

    public init(id: String, socketPath: String? = nil, queue: DispatchQueue? = nil, transport: RelayTransport? = nil) {
        self.id = id
        self.socketPath = socketPath ?? RelayPaths.socket(for: id)
        let q = queue ?? DispatchQueue(label: "relay.session.\(id)")
        self.queue = q
        self.transport = transport ?? UnixSocketTransport(socketPath: self.socketPath, queue: q)
    }

    public typealias ConnectError = UnixSocketTransport.ConnectError

    /// Connect and send the first frame at once. The RESUME must be the first
    /// frame within 100 ms of connect (reference §3.2); the transport owes it
    /// to the wire before anything else happens.
    public func connect(mode: AttachMode = .resume(offset: 0, maxReplayBytes: nil)) throws {
        timings.tStart = now()
        let first: [UInt8]
        switch mode {
        case .resume(let off, let maxB):
            offset = off
            first = encodeResume(offset: off, maxReplayBytes: maxB)
        case .observe:
            first = encodePayload(WSMsg.observe)
        }
        transport.onPayload = { [weak self] type, body in
            guard let self else { return }
            if self.timings.tFirstFrame == 0 { self.timings.tFirstFrame = now() }
            self.onPayload?(type, body)
            self.handle(type, body)
        }
        transport.onClosed = { [weak self] reason in
            guard let self else { return }
            self.closeReason = reason
            self.onClosed?()
        }
        try transport.open(firstPayload: first)
        timings.tConnected = transport.tConnected
        timings.tResumeSent = transport.tFirstSent
    }

    public func send(_ payload: [UInt8]) { transport.send(payload) }
    public func sendInput(_ bytes: [UInt8]) { send(encodePayload(WSMsg.data, bytes)) }
    public func sendResize(cols: Int, rows: Int) { send(encodeResize(cols: cols, rows: rows)) }

    public func close() { transport.close() }

    private func handle(_ type: UInt8, _ body: ArraySlice<UInt8>) {
        switch type {
        case WSMsg.data:
            offset += Double(body.count)          // §3.4: DATA adds its length
            dataFrames += 1; dataBytes += body.count
            onData?(body)

        case WSMsg.bufferReplay:
            // §3.4: replays do NOT touch the offset. §3.5: isDelta read BEFORE any SYNC.
            let isDelta = offset > 0
            if timings.tReplayFrame == 0 { timings.tReplayFrame = now() }
            timings.replayWireBytes = body.count
            timings.replayPlainBytes = body.count
            timings.replayWasDelta = isDelta
            timings.tReplayDecoded = now()
            onReplay?(Array(body), isDelta)

        case WSMsg.bufferReplayGz:
            let isDelta = offset > 0              // captured synchronously, before inflate
            if timings.tReplayFrame == 0 { timings.tReplayFrame = now() }
            timings.replayWireBytes = body.count
            timings.replayWasGz = true
            timings.replayWasDelta = isDelta
            do {
                let plain = try gunzip(body)
                timings.replayPlainBytes = plain.count
                timings.tReplayDecoded = now()
                onReplay?(plain, isDelta)
            } catch { onGzipError?(error) }

        case WSMsg.sync:
            guard let v = beF64(body), !v.isNaN else { break }
            if v == 0 && offset > 0 { offset = 0 } else { offset = v }
            onSync?(v)
            if !handshakeDone {
                handshakeDone = true
                timings.tSync = now()
                onHandshake?(timings)
            }

        case WSMsg.resize:
            guard body.count >= 4 else { break }
            hostCols = beU16(body, 0); hostRows = beU16(body, 2)
            if timings.tResize == 0 { timings.tResize = now() }
            onResize?(hostCols, hostRows)

        case WSMsg.title:
            onTitle?(String(decoding: body, as: UTF8.self))

        case WSMsg.sessionState:
            onSessionState?(body.first == 1)

        case WSMsg.sessionMetrics:
            // [bps1 f64][bps5 f64][bps15 f64][totalBytes f64], big-endian.
            guard body.count >= 32 else { break }
            let i = body.startIndex
            guard let a = beF64(body[i..<(i + 8)]),
                  let b = beF64(body[(i + 8)..<(i + 16)]),
                  let c = beF64(body[(i + 16)..<(i + 24)]),
                  let d = beF64(body[(i + 24)..<(i + 32)])
            else { break }
            onMetrics?(a, b, c, d)

        case WSMsg.clearScrollback:
            offset = 0                            // §3.4 / gotcha 15; the next SYNC restores it
            onClearScrollback?()

        case WSMsg.clipboard:
            guard !body.isEmpty, body.count <= Self.maxClipboardBytes else { break }
            onClipboard?(String(decoding: body, as: UTF8.self))

        case WSMsg.exit:
            var v: Int32 = 0
            if body.count >= 4 { var i = body.startIndex
                for _ in 0..<4 { v = (v << 8) | Int32(body[i]); i += 1 } }
            onExit?(v)

        default:
            break                                  // NOTIFICATION/IMAGE/SPARKLINE/...
        }
    }
}

@inline(__always) public func now() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
}

@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var off = 0
    return bytes.withUnsafeBufferPointer { bp -> Bool in
        while off < bp.count {
            let n = Darwin.write(fd, bp.baseAddress! + off, bp.count - off)
            if n > 0 { off += n }
            else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            else { return false }
        }
        return true
    }
}
