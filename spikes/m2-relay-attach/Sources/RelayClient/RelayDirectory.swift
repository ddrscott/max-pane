import Foundation

public enum RelayPaths {
    public static var home: String { NSHomeDirectory() }
    public static var root: String { home + "/.relay-tty" }
    public static var sessionsDir: String { root + "/sessions" }
    public static var socketsDir: String { root + "/sockets" }
    public static func sessionJSON(for id: String) -> String { sessionsDir + "/\(id).json" }
    public static func socket(for id: String) -> String { socketsDir + "/\(id).sock" }
}

/// Permissive decode — fields are absent (not null) when unset, numbers are f64 (§13.1, §13.21).
public struct RelaySessionMeta {
    public let id: String
    public let command: String
    public let args: [String]
    public let cwd: String
    public let status: String
    public let cols: Int
    public let rows: Int
    public let pid: Int32
    public let title: String?
    public let totalBytesWritten: Double
    public let agentState: String?

    public init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        command = json["command"] as? String ?? ""
        args = json["args"] as? [String] ?? []
        cwd = json["cwd"] as? String ?? RelayPaths.home
        status = json["status"] as? String ?? "running"
        cols = Int((json["cols"] as? NSNumber)?.doubleValue ?? 80)
        rows = Int((json["rows"] as? NSNumber)?.doubleValue ?? 24)
        pid = Int32((json["pid"] as? NSNumber)?.doubleValue ?? 0)
        title = json["title"] as? String
        totalBytesWritten = (json["totalBytesWritten"] as? NSNumber)?.doubleValue ?? 0
        agentState = json["agentState"] as? String
    }

    public static func read(id: String) -> RelaySessionMeta? {
        guard let d = FileManager.default.contents(atPath: RelayPaths.sessionJSON(for: id)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return RelaySessionMeta(json: o)
    }

    public static func list() -> [RelaySessionMeta] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: RelayPaths.sessionsDir)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasSuffix(".json.tmp") }
            .compactMap { read(id: String($0.dropLast(5))) }
    }
}

public enum RelaySpawn {
    static let shellNames: Set<String> = ["sh","bash","zsh","fish","ksh","tcsh","csh","dash"]

    public static func findPtyHost() -> String? {
        let fm = FileManager.default
        // realpath(which relay) -> .../relay-tty/dist/cli/index.js -> up 3 -> bin/relay-pty-host
        if let which = run("/usr/bin/env", ["which", "relay"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !which.isEmpty {
            let real = (try? fm.destinationOfSymbolicLink(atPath: which)).map {
                $0.hasPrefix("/") ? $0 : (which as NSString).deletingLastPathComponent + "/" + $0
            } ?? which
            var u = URL(fileURLWithPath: real).standardizedFileURL
            for _ in 0..<3 { u.deleteLastPathComponent() }
            let cand = u.appendingPathComponent("bin/relay-pty-host").path
            if fm.isExecutableFile(atPath: cand) { return cand }
        }
        for glob in ["/lib/node_modules/relay-tty/bin/relay-pty-host"] {
            let base = RelayPaths.home + "/.nvm/versions/node"
            for v in (try? fm.contentsOfDirectory(atPath: base))?.sorted().reversed() ?? [] {
                let p = base + "/" + v + glob
                if fm.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8)
    }

    public static func newId() -> String {
        var b = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytesShim(&b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    static func SecRandomCopyBytesShim(_ b: inout [UInt8]) -> Int32 {
        for i in 0..<b.count { b[i] = UInt8.random(in: 0...255) }
        return 0
    }

    public static func buildArgs(id: String, cols: Int, rows: Int, cwd: String,
                                 command: String, args: [String]) -> [String] {
        let base = (command as NSString).lastPathComponent
        if shellNames.contains(base) {
            return [id, "\(cols)", "\(rows)", cwd, command, "--login"] + args
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/sh"
        let esc = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let full = args.isEmpty ? "exec \(esc(command))"
                                : "exec \(esc(command)) " + args.map(esc).joined(separator: " ")
        return [id, "\(cols)", "\(rows)", cwd, shell, "-li", "-c", full]
    }

    public enum SpawnError: Error { case noBinary, timeout(String), exited(String) }

    /// Direct spawn (reference §8 path b). Returns the session id once the socket connects.
    @discardableResult
    public static func spawn(command: String, args: [String] = [], cwd: String = RelayPaths.home,
                             cols: Int = 80, rows: Int = 24) throws -> String {
        guard let bin = findPtyHost() else { throw SpawnError.noBinary }
        let id = newId()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = buildArgs(id: id, cols: cols, rows: rows, cwd: cwd, command: command, args: args)
        var env = ProcessInfo.processInfo.environment
        env["RELAY_SESSION_ID"] = id
        env["RELAY_ORIG_COMMAND"] = command
        env["RELAY_ORIG_ARGS"] = String(data: try! JSONSerialization.data(withJSONObject: args), encoding: .utf8)
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()

        // cli/spawn.ts:42-71 — connect() is the readiness test, not file existence.
        let deadline = Date().addingTimeInterval(3.0)
        var delay: UInt32 = 50_000
        while Date() < deadline {
            if !p.isRunning && p.terminationStatus != 0 {
                throw SpawnError.exited("pty-host exited \(p.terminationStatus) before socket ready")
            }
            if FileManager.default.fileExists(atPath: RelayPaths.socket(for: id)) {
                let s = RelaySession(id: id)
                if (try? s.connect(mode: .observe)) != nil { s.close(); return id }
            }
            usleep(delay); delay = min(delay * 2, 500_000)
        }
        throw SpawnError.timeout(id)
    }

    /// Kill a session we spawned. SIGTERM to pty-host (meta.pid is pty-host's own pid, §13.19).
    public static func kill(id: String) {
        if let m = RelaySessionMeta.read(id: id), m.pid > 0 { Darwin.kill(m.pid, SIGTERM) }
    }
}
