import Foundation

/// Listens for `maxpane-open`, the `BROWSER` shim from PRD §7.1.
///
/// A terminal pane runs with `BROWSER=maxpane-open`. When something in that
/// terminal opens a URL, the shim connects here and says which Relay session it
/// came from — `RELAY_SESSION_ID`, which pty-host sets in every session it
/// starts. That is enough to put the web lane immediately right of the right
/// terminal, tagged with that terminal's project, without the shim and the app
/// having to agree on anything else.
///
/// One line of JSON per request, one line of reply. Requests are accepted only
/// over a Unix socket in the user's own Application Support directory, so the
/// only thing that can reach it is something already running as the user.
final class OpenServer {
    struct Request {
        let url: String
        /// Empty when the URL came from somewhere that is not a Relay session.
        let sessionId: String
        let cwd: String
    }

    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["MAXPANE_SOCKET"] { return override }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaxPane", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("open.sock").path
    }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "maxpane.open-server")
    private let handler: (Request) -> Bool

    /// `handler` returns whether the URL was accepted; the shim falls back to
    /// the system browser when it was not.
    init(handler: @escaping (Request) -> Bool) throws {
        self.handler = handler
        try listen()
    }

    deinit { stop() }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { close(fd); fd = -1 }
        try? FileManager.default.removeItem(atPath: Self.socketPath)
    }

    private func listen() throws {
        let path = Self.socketPath
        // A socket left behind by a crash would otherwise make bind() fail with
        // EADDRINUSE forever.
        try? FileManager.default.removeItem(atPath: path)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                _ = strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else {
            close(fd); fd = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }
        // Owner only. Nothing else on the machine should be able to open lanes.
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            close(fd); fd = -1
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
        }

        let s = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        s.setEventHandler { [weak self] in self?.acceptOne() }
        s.resume()
        source = s
    }

    private func acceptOne() {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }

        // The shim sends one short line and waits. A cap keeps a hung or hostile
        // writer from growing this buffer without bound.
        var buffer = [UInt8](repeating: 0, count: 8192)
        var collected: [UInt8] = []
        while collected.count < 8192 {
            let n = read(client, &buffer, buffer.count)
            if n <= 0 { break }
            collected.append(contentsOf: buffer[0..<n])
            if collected.contains(UInt8(ascii: "\n")) { break }
        }
        guard let line = String(bytes: collected, encoding: .utf8),
              let request = Self.parse(line)
        else {
            _ = #"{"ok":false,"error":"bad request"}"#.withCString { write(client, $0, strlen($0)) }
            _ = "\n".withCString { write(client, $0, 1) }
            return
        }

        // The handler touches the ledger and the view hierarchy, so it runs on
        // the main actor; the shim is waiting on the reply, so we wait for it.
        var accepted = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [handler] in
            accepted = handler(request)
            done.signal()
        }
        // If the app is wedged, answer anyway so the shim can fall back rather
        // than hanging the user's terminal.
        _ = done.wait(timeout: .now() + 2)

        let reply = accepted ? #"{"ok":true}"# : #"{"ok":false,"error":"not handled"}"#
        _ = reply.withCString { write(client, $0, strlen($0)) }
        _ = "\n".withCString { write(client, $0, 1) }
    }

    /// The shim's request line. Decoded with `JSONSerialization` rather than
    /// `Codable` because the shape is three strings and an op.
    static func parse(_ line: String) -> Request? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["op"] as? String == "open",
              let url = object["url"] as? String,
              !url.isEmpty
        else { return nil }
        // Only schemes a web pane can actually load. A `file://` or `javascript:`
        // arriving from a shell is not something to open silently.
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return Request(
            url: url,
            sessionId: object["session"] as? String ?? "",
            cwd: object["cwd"] as? String ?? "")
    }
}
