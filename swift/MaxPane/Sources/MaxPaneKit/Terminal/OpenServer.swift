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
public final class OpenServer: @unchecked Sendable {
    /// What the CLI asked for.
    public enum Request: Sendable {
        /// A URL to open as a web lane. `sessionId` is empty when the caller was
        /// not itself a Relay session.
        case open(url: String, sessionId: String, cwd: String)
        /// A command to run in a new terminal lane. An empty `command` means the
        /// user's shell.
        case run(command: String, args: [String], sessionId: String, cwd: String)
        /// What is on the strip.
        case list
        /// `maxpane run @NAME COMMAND…`: the same, on a configured remote
        /// server. Its own case rather than a field on `run`, because a remote
        /// spawn answers later than this socket does: the reply says it has
        /// started asking, and the lane arrives when the server answers.
        case runOn(server: String, command: String, args: [String])
        /// `maxpane sessions`: every session the registry knows, local and on
        /// every server, attached or not.
        case listSessions
        /// `maxpane attach [SERVER:]ID`: put a running session on the strip,
        /// or go to the lane that already holds it.
        case attach(server: String?, id: String)
        /// `maxpane server add NAME URL`: a remote relay-tty server, from the
        /// auth URL it printed at startup. The token inside `url` goes to the
        /// Keychain and nowhere else; the app is the one that stores it, so
        /// the item is written under the app's own signature and read back
        /// without a panel.
        case addServer(name: String, url: String)
        /// `maxpane server ls`.
        case listServers
        /// `maxpane server color NAME COLOUR`: the colour a server is known
        /// by (ADR-0025). The colour arrives as typed; the handler says what
        /// the eight are when it is not one of them.
        case colourServer(name: String, colour: String)
        /// `maxpane mute [LANE|all]` and `maxpane unmute [LANE|all]`. `lane`
        /// is as `maxpane ls` prints it: a strip index, `left` or `right` for
        /// a dock, or `all`, which is also what leaving it out means — the
        /// owner drives this with the screen locked, and "whatever is making
        /// that noise" is the question then.
        case mute(lane: String, muted: Bool)
        /// `maxpane volume LANE 0-100`. Zero is mute.
        case volume(lane: String, percent: Int)
    }

    /// What goes back. `session` carries the id of a session just started;
    /// `lanes` carries `ls` output already formatted, because the app knows the
    /// strip order and the CLI does not.
    public struct Reply: Sendable {
        public let ok: Bool
        public var session: String = ""
        public var lanes: String = ""
        public var error: String = ""

        public init(ok: Bool, session: String = "", lanes: String = "", error: String = "") {
            self.ok = ok
            self.session = session
            self.lanes = lanes
            self.error = error
        }

        public static let handled = Reply(ok: true)
        public static func refused(_ why: String) -> Reply { Reply(ok: false, error: why) }
    }

    public static var socketPath: String { Profile.current.socketPath }

    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "maxpane.open-server")
    private let handler: @Sendable (Request) -> Reply

    /// `handler` answers each request. A refused `open` makes the shim fall back
    /// to the system browser, so refusing is a real answer rather than a failure.
    public init(handler: @escaping @Sendable (Request) -> Reply) throws {
        self.handler = handler
        try listen()
    }

    deinit { stop() }

    public func stop() {
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
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { [handler] in
            outcome.set(handler(request))
            done.signal()
        }
        // Spawning a session polls for its socket for up to 3 s, so this has to
        // outlast that. If the app is genuinely wedged, answer anyway rather
        // than hanging the user's terminal.
        _ = done.wait(timeout: .now() + 8)

        let reply = Self.encode(outcome.get())
        _ = reply.withCString { write(client, $0, strlen($0)) }
        _ = "\n".withCString { write(client, $0, 1) }
    }

    /// The shim's request line. Decoded with `JSONSerialization` rather than
    /// `Codable` because the shape is three strings and an op.
    public static func parse(_ line: String) -> Request? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String
        else { return nil }

        let sessionId = object["session"] as? String ?? ""
        let cwd = object["cwd"] as? String ?? ""

        switch op {
        case "open":
            guard let url = object["url"] as? String, !url.isEmpty else { return nil }
            // Only schemes a web pane can load. A `file://` or `javascript:`
            // arriving from a shell is not something to open silently.
            guard let scheme = URL(string: url)?.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return .open(url: url, sessionId: sessionId, cwd: cwd)

        case "run":
            if let server = object["server"] as? String, !server.isEmpty {
                return .runOn(
                    server: server,
                    command: object["command"] as? String ?? "",
                    args: object["args"] as? [String] ?? [])
            }
            return .run(
                command: object["command"] as? String ?? "",
                args: object["args"] as? [String] ?? [],
                sessionId: sessionId,
                cwd: cwd)

        case "ls":
            return .list

        case "sessions":
            return .listSessions

        case "attach":
            guard let id = object["id"] as? String, !id.isEmpty else { return nil }
            let server = (object["server"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .attach(server: server, id: id)

        case "server-add":
            guard let name = object["name"] as? String, !name.isEmpty,
                  let url = object["url"] as? String, !url.isEmpty
            else { return nil }
            return .addServer(name: name, url: url)

        case "server-ls":
            return .listServers

        case "server-color":
            guard let name = object["name"] as? String, !name.isEmpty,
                  let colour = object["color"] as? String, !colour.isEmpty
            else { return nil }
            return .colourServer(name: name, colour: colour)

        case "mute", "unmute":
            let lane = (object["lane"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "all"
            return .mute(lane: lane, muted: op == "mute")

        case "volume":
            guard let lane = object["lane"] as? String, !lane.isEmpty,
                  let percent = object["percent"] as? Int, (0...100).contains(percent)
            else { return nil }
            return .volume(lane: lane, percent: percent)

        default:
            return nil
        }
    }

    static func encode(_ reply: Reply) -> String {
        var parts = ["\"ok\":\(reply.ok)"]
        if !reply.session.isEmpty { parts.append("\"session\":\(json(reply.session))") }
        if !reply.lanes.isEmpty { parts.append("\"lanes\":\(json(reply.lanes))") }
        if !reply.error.isEmpty { parts.append("\"error\":\(json(reply.error))") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func json(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}

/// A `Bool` handed back from the main actor to the socket's own queue. The
/// semaphore orders the two accesses; the lock is what makes that legible to the
/// compiler.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value = OpenServer.Reply.refused("not handled")

    func set(_ v: OpenServer.Reply) {
        lock.lock()
        value = v
        lock.unlock()
    }

    func get() -> OpenServer.Reply {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
