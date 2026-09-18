import Foundation

/// The local transport: pty-host's Unix socket, length-prefixed frames (§1).
///
/// This is `RelaySession.connect()` and `drain()` as they were before the
/// transport seam existed, moved and otherwise unchanged: blocking connect,
/// the first payload written before the socket is even made non-blocking,
/// one `DispatchSourceRead` on the session's queue draining to `EAGAIN`.
public final class UnixSocketTransport: RelayTransport {
    public let socketPath: String
    public let queue: DispatchQueue

    public var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?
    public var onClosed: ((RelayClose) -> Void)?
    public private(set) var tConnected: Double = 0
    public private(set) var tFirstSent: Double = 0

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var parser = FrameParser()
    private var readBuf = [UInt8](repeating: 0, count: 1 << 18)   // 256 KiB

    public enum ConnectError: Error { case socketFailed(Int32), connectFailed(Int32), pathTooLong }

    public init(socketPath: String, queue: DispatchQueue) {
        self.socketPath = socketPath
        self.queue = queue
    }

    public func open(firstPayload: [UInt8]) throws {
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
        tConnected = now()

        // The RESUME, within pty-host's 100 ms window, with no hop in between.
        _ = writeAll(s, lengthPrefixed(firstPayload))
        tFirstSent = now()

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

    public func send(_ payload: [UInt8]) {
        if fd >= 0 { _ = writeAll(fd, lengthPrefixed(payload)) }
    }

    public func close() {
        source?.cancel(); source = nil
    }

    private func drain() {
        while true {
            let n = readBuf.withUnsafeMutableBytes { rb in
                Darwin.read(fd, rb.baseAddress, rb.count)
            }
            if n > 0 {
                readBuf.withUnsafeBufferPointer { bp in
                    let slice = UnsafeBufferPointer(start: bp.baseAddress, count: n)
                    parser.feed(slice) { type, body in self.onPayload?(type, body) }
                }
                if n < readBuf.count { return }
            } else if n == 0 {
                close(); onClosed?(RelayClose(kind: .closed)); return
            } else {
                if errno == EAGAIN || errno == EINTR { return }
                let e = Int(errno)
                close(); onClosed?(RelayClose(kind: .failed(e))); return
            }
        }
    }
}
