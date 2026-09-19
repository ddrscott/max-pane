import Foundation
import RelayClient

/// Where a new session is to start: which server, and which directory there.
///
/// `server` is a `[[servers]]` name or `nil` for this Mac (ADR-0020). `cwd`
/// is a path *on that machine*; `nil` means the machine's own home — this
/// Mac's `homeDirectoryForCurrentUser` locally, and for a remote server
/// whatever it answers when `POST /api/sessions` is sent no `cwd` at all,
/// which is its `$HOME`. A remote place is never given this Mac's home,
/// because that directory does not exist over there.
struct SpawnPlace: Equatable, Sendable {
    var server: String?
    var cwd: String?

    static let local = SpawnPlace(server: nil, cwd: nil)

    var isRemote: Bool { server != nil }

    /// The one mark, where a directory would be written: `yorkshire:/home/s`
    /// for a remote place, the path (or nothing) for a local one.
    var label: String? {
        guard let server else { return cwd }
        return "\(server):\(cwd ?? "~")"
    }

    /// What a `Recent` remembers as its `cwd`: the path for a local run,
    /// `server:path` for a remote one — the same `host:path` form the ledger
    /// uses for a remote project root, so one rule reads both. Nothing is
    /// remembered for a remote run whose directory the server did not name.
    var remembered: String? {
        guard let server else { return cwd }
        guard let cwd else { return nil }
        return "\(server):\(cwd)"
    }

    /// The inverse of `remembered`. A local path is absolute, so a value that
    /// does not start with `/` and names a server before its first colon is a
    /// remote place; anything else is local. `servers` is what the file
    /// currently configures, so `foo:/x` for a server that is gone reads as
    /// a local path — and is then refused as a directory that does not
    /// exist, which is the right outcome for a memory nothing can act on.
    static func parse(remembered: String?, servers: [String]) -> SpawnPlace? {
        guard let remembered, !remembered.isEmpty else { return nil }
        if !remembered.hasPrefix("/"), let colon = remembered.firstIndex(of: ":") {
            let name = String(remembered[..<colon])
            if servers.contains(name) {
                let path = String(remembered[remembered.index(after: colon)...])
                return SpawnPlace(server: name, cwd: path.isEmpty ? nil : path)
            }
        }
        return SpawnPlace(server: nil, cwd: remembered)
    }

    /// What `@name` in ⌘O's field asks for.
    enum Choice: Equatable, Sendable {
        /// `@local`: this Mac, whatever lane is focused.
        case local
        /// `@name`: that server.
        case server(String)
    }

    /// The directory a ⌘O line runs in, and where.
    ///
    /// - An explicit `@name` wins over everything: that server, and a
    ///   remembered directory only if it was on that server (a path from
    ///   another machine is no help), else the focused lane's directory if
    ///   that lane is on the same server, else the server's home.
    /// - `@local` is this Mac: the remembered directory if it is local and
    ///   still exists, else the focused lane's directory if that lane is
    ///   local, else home.
    /// - Otherwise a remembered place wins when it can be used — a local
    ///   directory that still exists, or a server that is connected — and the
    ///   focused lane's place is the fallback, which for a remote lane means
    ///   that server in that lane's directory and for no lane means home.
    ///
    /// `exists` and `connected` are parameters so the rule can be proved
    /// without a filesystem or a server.
    static func resolve(
        choice: Choice?, remembered: SpawnPlace?, focused: SpawnPlace,
        exists: (String) -> Bool, connected: (String) -> Bool
    ) -> SpawnPlace {
        switch choice {
        case .server(let name):
            let cwd = remembered.flatMap { $0.server == name ? $0.cwd : nil }
                ?? (focused.server == name ? focused.cwd : nil)
            return SpawnPlace(server: name, cwd: cwd)
        case .local:
            if let remembered, remembered.server == nil, let cwd = remembered.cwd, exists(cwd) {
                return remembered
            }
            return focused.server == nil ? focused : .local
        case nil:
            if let remembered {
                if let server = remembered.server {
                    if connected(server) { return remembered }
                } else if let cwd = remembered.cwd, exists(cwd) {
                    return remembered
                }
            }
            return focused
        }
    }
}

/// A session that has just been started, wherever that was.
struct SpawnedSession: Equatable, Sendable {
    var key: SessionKey
    /// The directory it started in, as the machine that started it reports
    /// it — the effective one, so a remote spawn with no `cwd` comes back
    /// with the server's home. What the recents remember.
    var cwd: String
}

/// Starts sessions on one server. Two implementations: `LocalSpawner` forks
/// `relay-pty-host` on this Mac, `RemoteSpawner` asks a relay-tty server's
/// HTTP API to do the same over there. Both send the same wrapper (see
/// `LocalSpawner.buildArgs` for why it is `$SHELL -li -c '<line>; exit $?'`
/// and never `exec`), so an agent started on either machine has a foreground
/// process of its own and can be classified BLOCKED.
///
/// The three overloads are the three things a caller can be holding: argv
/// (`maxpane run`, ⌘T's bare shell), a line a human typed (⌘O, the editor
/// line for a ⌘-clicked path), or the `TypedCommand` that decides between
/// them. `cwd` is a path on the spawner's machine, or `nil` for its home.
///
/// `completion` is called on the main thread, exactly once. The local
/// spawner calls it before `spawn` returns, because it already has the id
/// (the socket is waited for synchronously, as it always was); the remote
/// one calls it when the server has answered, because a round trip through
/// a tunnel is not something to block the main thread on.
@MainActor
protocol SessionSpawning {
    /// `nil` for this Mac.
    var server: String? { get }

    func spawn(cwd: String?, command: String?, args: [String], cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    func spawn(cwd: String?, shellLine: String, cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
}

extension SessionSpawning {
    func spawn(cwd: String?, typed: TypedCommand, cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    {
        switch typed {
        case .program(let program, let args):
            spawn(cwd: cwd, command: program, args: args, cols: cols, rows: rows, completion: completion)
        case .shellLine(let line):
            spawn(cwd: cwd, shellLine: line, cols: cols, rows: rows, completion: completion)
        }
    }
}

extension LocalSpawner: SessionSpawning {
    var server: String? { nil }

    func spawn(cwd: String?, command: String?, args: [String], cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    {
        let dir = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        completion(Result {
            let id = try spawn(cwd: dir, command: command, args: args, cols: cols, rows: rows)
            return SpawnedSession(key: SessionKey(id: id), cwd: dir)
        })
    }

    func spawn(cwd: String?, shellLine: String, cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    {
        let dir = cwd ?? FileManager.default.homeDirectoryForCurrentUser.path
        completion(Result {
            let id = try spawn(cwd: dir, shellLine: shellLine, cols: cols, rows: rows)
            return SpawnedSession(key: SessionKey(id: id), cwd: dir)
        })
    }
}

/// `POST /api/sessions` on a remote relay-tty server, with the cookie.
///
/// The server forks `relay-pty-host` itself and answers 201 once the
/// session's socket accepts a connection (`pty-manager.ts`, `waitForSocket`),
/// so 201 *is* readiness and there is nothing here to poll. It is followed
/// by `GET /api/sessions/:id`, which reads the session file pty-host wrote
/// and starts the server's monitor on it — the on-disk metadata, and the
/// reason the list learns of the session at once rather than at the next
/// `sessions-changed`.
///
/// # The body
///
/// The server's own spawn wraps a command in `$SHELL -li -c 'exec …'`, and
/// `exec` is exactly what makes an agent the session leader and therefore
/// never BLOCKED (`LocalSpawner.buildArgs`). So the body never names the
/// program as `command`. It sends the wrapper itself:
///
///     {"command": "$SHELL", "args": ["-li", "-c", "<line>\nexit $?"], …}
///
/// The server resolves the literal `$SHELL` to the user's shell over there
/// (`api.ts`), sees a shell as the command and adds `--login`, and the
/// shell then reads `-li -c <line>` — the wrapper, with the login files
/// sourced, the same as the local argv. A bare shell (`command == nil`) is
/// `{"command": "$SHELL", "args": []}`, and gets `--login` from the server
/// as the local bare shell gets it from `buildArgs`. `cwd` is sent only
/// when there is one; omitted, the server starts the session in its home
/// and the 201 says which directory that was.
@MainActor
final class RemoteSpawner: SessionSpawning {
    enum SpawnError: LocalizedError {
        /// The server answered with something other than 201; `body` is its
        /// own error text, one line.
        case refused(server: String, status: Int, body: String)
        case unreachable(server: String, why: String)
        case badReply(server: String)

        var errorDescription: String? {
            switch self {
            case .refused(let server, let status, let body):
                return "\(server): could not start the session — HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
            case .unreachable(let server, let why):
                return "\(server): could not start the session — \(why)"
            case .badReply(let server):
                return "\(server): could not start the session — the server's answer had no session in it"
            }
        }
    }

    let name: String
    var server: String? { name }
    private let endpoint: RelayServer
    private let urlSession: URLSession

    init(name: String, endpoint: RelayServer) {
        self.name = name
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        // The server waits for the pty socket before answering; through a
        // tunnel that is a few hundred milliseconds. A minute is generous
        // and still an answer.
        config.timeoutIntervalForRequest = 60
        urlSession = URLSession(configuration: config)
    }

    // MARK: - the body

    /// The literal the server resolves to the user's shell over there.
    nonisolated static let shellPlaceholder = "$SHELL"

    /// The JSON for a program with arguments, or a bare shell when
    /// `command` is nil. A shell named outright (`zsh`) goes as the command
    /// with no wrapper, as `buildArgs` does locally, so it is the leader and
    /// its directory tag follows `cd`.
    nonisolated static func body(cwd: String?, command: String?, args: [String], cols: Int, rows: Int) -> [String: Any] {
        var out: [String: Any] = ["cols": cols, "rows": rows]
        if let cwd { out["cwd"] = cwd }
        if let command, !LocalSpawner.isShellCommand(command) {
            out["command"] = shellPlaceholder
            out["args"] = ["-li", "-c", LocalSpawner.shellWrapped(LocalSpawner.programLine(command, args: args))]
        } else {
            out["command"] = command ?? shellPlaceholder
            out["args"] = args
        }
        return out
    }

    /// The JSON for a line a human typed: one argv element, exactly as
    /// typed, with the newline terminator (`LocalSpawner.buildShellArgs`).
    nonisolated static func body(cwd: String?, shellLine line: String, cols: Int, rows: Int) -> [String: Any] {
        var out: [String: Any] = [
            "command": shellPlaceholder,
            "args": ["-li", "-c", LocalSpawner.shellWrapped(line, separator: "\n")],
            "cols": cols, "rows": rows,
        ]
        if let cwd { out["cwd"] = cwd }
        return out
    }

    // MARK: - the calls

    func spawn(cwd: String?, command: String?, args: [String], cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    {
        post(Self.body(cwd: cwd, command: command, args: args, cols: cols, rows: rows), completion: completion)
    }

    func spawn(cwd: String?, shellLine: String, cols: Int, rows: Int,
               completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void)
    {
        post(Self.body(cwd: cwd, shellLine: shellLine, cols: cols, rows: rows), completion: completion)
    }

    private func url(_ path: String) -> URL {
        var c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        c.path = path
        return c.url!
    }

    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token = endpoint.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func post(_ body: [String: Any], completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void) {
        var request = request(url("/api/sessions"), method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let name = name
        // `self` strongly, on purpose. Every caller makes a spawner for one
        // spawn and lets it go (`try spawner(at: place).spawn(…)`), so a weak
        // capture is nil by the time the server answers: the session starts
        // over there, the completion is never called, and no lane and no error
        // ever turn up. The request holds the spawner until it has answered.
        urlSession.dataTask(with: request) { [self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<(String, String), Error>
            if let error {
                result = .failure(SpawnError.unreachable(server: name, why: (error as NSError).localizedDescription))
            } else if status != 201 {
                result = .failure(SpawnError.refused(server: name, status: status, body: Self.errorLine(data)))
            } else if let session = Self.session(in: data), let id = session["id"] as? String {
                result = .success((id, session["cwd"] as? String ?? ""))
            } else {
                result = .failure(SpawnError.badReply(server: name))
            }
            Task { @MainActor in
                switch result {
                case .failure(let error):
                    completion(.failure(error))
                case .success(let (id, cwd)):
                    self.readBack(id: id, cwd: cwd, completion: completion)
                }
            }
        }.resume()
    }

    /// `GET /api/sessions/:id` after the 201. Its cwd is the one pty-host
    /// wrote; the 201's is the one the server asked for, and the two agree
    /// unless the directory was missing over there. A failure here is not a
    /// failure to spawn — the session exists — so it falls back to the
    /// 201's answer and says so in the log.
    private func readBack(id: String, cwd: String, completion: @escaping @MainActor (Result<SpawnedSession, Error>) -> Void) {
        let name = name
        urlSession.dataTask(with: request(url("/api/sessions/\(id)"))) { data, response, _ in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let onDisk = status == 200 ? Self.session(in: data)?["cwd"] as? String : nil
            Task { @MainActor in
                if onDisk == nil {
                    Log.warn("server \(name): session \(id) started, but GET /api/sessions/\(id) answered HTTP \(status); using the directory the server was asked for")
                }
                completion(.success(SpawnedSession(key: SessionKey(server: name, id: id), cwd: onDisk ?? cwd)))
            }
        }.resume()
    }

    /// `{"session": {…}}` — the 201 body and the GET body have the same shape.
    nonisolated static func session(in data: Data?) -> [String: Any]? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["session"] as? [String: Any]
    }

    /// The server's error, as one line: its `{"error": "…"}` when it sent
    /// one, else whatever text it sent, trimmed to a line.
    nonisolated static func errorLine(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? String {
            return error
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
