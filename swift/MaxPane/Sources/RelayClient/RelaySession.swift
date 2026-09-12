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

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var parser = FrameParser()
    private var readBuf = [UInt8](repeating: 0, count: 1 << 18)   // 256 KiB

    /// Offset accounting (reference §3.4). DATA adds; replays add NOTHING; SYNC assigns.
    public private(set) var offset: Double = 0
    public private(set) var hostCols = 0
    public private(set) var hostRows = 0
    public private(set) var handshakeDone = false
    public private(set) var timings = AttachTimings()

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
    public var onClearScrollback: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onClosed: (() -> Void)?
    public var onGzipError: ((Error) -> Void)?

    public init(id: String, socketPath: String? = nil, queue: DispatchQueue? = nil) {
        self.id = id
        self.socketPath = socketPath ?? RelayPaths.socket(for: id)
        self.queue = queue ?? DispatchQueue(label: "relay.session.\(id)")
    }

    public enum ConnectError: Error { case socketFailed(Int32), connectFailed(Int32), pathTooLong }

    /// Blocking connect + IMMEDIATE first frame. The RESUME must be the first frame within
    /// 100 ms of connect (reference §3.2) — sent here with no await in between.
    public func connect(mode: AttachMode = .resume(offset: 0, maxReplayBytes: nil)) throws {
        timings.tStart = now()
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        if s < 0 { throw ConnectError.socketFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(s); throw ConnectError.pathTooLong
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.baseAddress!.copyMemory(from: pathBytes, byteCount: pathBytes.count)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                Darwin.connect(s, sp, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { let e = errno; Darwin.close(s); throw ConnectError.connectFailed(e) }
        timings.tConnected = now()

        let frame: [UInt8]
        switch mode {
        case .resume(let off, let maxB):
            offset = off
            frame = encodeResume(offset: off, maxReplayBytes: maxB)
        case .observe:
            frame = encodeFrame(WSMsg.observe)
        }
        _ = writeAll(s, frame)
        timings.tResumeSent = now()

        fd = s
        var flags = fcntl(s, F_GETFL, 0); flags |= O_NONBLOCK; _ = fcntl(s, F_SETFL, flags)
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fd >= 0 { Darwin.close(self.fd); self.fd = -1 }
        }
        source = src
        src.resume()
    }

    public func send(_ frame: [UInt8]) { if fd >= 0 { _ = writeAll(fd, frame) } }
    public func sendInput(_ bytes: [UInt8]) { send(encodeFrame(WSMsg.data, bytes)) }
    public func sendResize(cols: Int, rows: Int) { send(encodeResize(cols: cols, rows: rows)) }

    public func close() {
        source?.cancel(); source = nil
    }

    private func drain() {
        while true {
            let n = readBuf.withUnsafeMutableBytes { rb in
                Darwin.read(fd, rb.baseAddress, rb.count)
            }
            if n > 0 {
                if timings.tFirstFrame == 0 { timings.tFirstFrame = now() }
                readBuf.withUnsafeBufferPointer { bp in
                    let slice = UnsafeBufferPointer(start: bp.baseAddress, count: n)
                    parser.feed(slice) { type, body in self.handle(type, body) }
                }
                if n < readBuf.count { return }
            } else if n == 0 {
                close(); onClosed?(); return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                close(); onClosed?(); return
            }
        }
    }

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

        case WSMsg.clearScrollback:
            offset = 0                            // §3.4 / gotcha 15; the next SYNC restores it
            onClearScrollback?()

        case WSMsg.exit:
            var v: Int32 = 0
            if body.count >= 4 { var i = body.startIndex
                for _ in 0..<4 { v = (v << 8) | Int32(body[i]); i += 1 } }
            onExit?(v)

        default:
            break                                  // NOTIFICATION/METRICS/CLIPBOARD/IMAGE/...
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
