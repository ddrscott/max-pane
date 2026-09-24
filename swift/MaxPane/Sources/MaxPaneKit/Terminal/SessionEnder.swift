import Foundation
import RelayClient

/// End Session (⌃⌘W): the session is killed, for every client, and the
/// pane that showed it closes. ⌘W and ⇧⌘W detach and leave the session
/// running for the sidebar to offer again; this is the one that ends it.
///
/// What "end" means is what relay-tty's own *stop session* means, in both
/// of its forms (`cli/sessions.ts` `stopSession`; `server/api.ts`
/// `DELETE /api/sessions/:id` → `ptyManager.kill`): **`SIGTERM` to
/// pty-host's own pid**, read from the session file. pty-host's handler
/// `SIGTERM`s the session leader, writes `status: "exited"`, removes the
/// socket and exits (`main.rs`, the SIGTERM task); closing the PTY master
/// hangs up whatever the shell had left. Not `SIGNAL` (0x25) on the wire:
/// that reaches the *foreground process group* — `relay kill`, Ctrl-C from
/// afar — and a shell whose program it killed is back at its prompt with
/// the session very much alive. Not `DETACH` either, for the same reason.
///
/// Locally the signal is sent from here, as the CLI does when no server
/// answers; the app never needs a relay server for a local session and
/// does not start needing one for this. Remotely it is the endpoint,
/// with the cookie: the server signals its own pty-host and drops the
/// session from its store. Owner only — a 403 is a guest's token.
@MainActor
protocol SessionEnding: AnyObject {
    /// Kill the session. `completion` is called once, on the main actor,
    /// with nothing or with why not; the pane is closed only on nothing.
    func end(sessionId: String, completion: @escaping @MainActor (Error?) -> Void)
}

enum SessionEndError: LocalizedError, Equatable {
    /// No session file, or one with no pid in it yet.
    case noPid(sessionId: String)
    /// `kill(2)` said no: `errno`'s text.
    case signalFailed(sessionId: String, why: String)
    case refused(server: String, status: Int, body: String)
    case unreachable(server: String, why: String)

    var errorDescription: String? {
        switch self {
        case .noPid(let id):
            return "could not end \(id) — its session file names no process"
        case .signalFailed(let id, let why):
            return "could not end \(id) — \(why)"
        case .refused(let server, let status, let body):
            return "\(server): could not end the session — HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
        case .unreachable(let server, let why):
            return "\(server): could not end the session — \(why)"
        }
    }
}

/// A session on this Mac: `SIGTERM` to the pid in `~/.relay-tty/sessions/
/// <id>.json`, which is pty-host's own (relay-integration.md §6, `pid`).
///
/// A pid that is already gone (`ESRCH`) is success: the session ended
/// before we got to it, and the pane should close the same way.
@MainActor
final class LocalSessionEnder: SessionEnding {
    private let pidOf: (String) -> Int32?

    /// `pidOf` answers from the session directory unless a test hands in
    /// its own, so the signal can be proved on a process the test owns.
    init(pidOf: @escaping (String) -> Int32? = { RelaySessionDirectory().session($0)?.pid }) {
        self.pidOf = pidOf
    }

    func end(sessionId: String, completion: @escaping @MainActor (Error?) -> Void) {
        completion(Self.terminate(sessionId: sessionId, pid: pidOf(sessionId)))
    }

    /// The signal itself, as a pure step: nil for sent (or already gone).
    nonisolated static func terminate(sessionId: String, pid: Int32?) -> SessionEndError? {
        guard let pid, pid > 0 else { return .noPid(sessionId: sessionId) }
        if kill(pid, SIGTERM) == 0 { return nil }
        if errno == ESRCH { return nil }
        return .signalFailed(sessionId: sessionId, why: String(cString: strerror(errno)))
    }
}

/// A session on a named server: `DELETE {base}/api/sessions/:id` with the
/// cookie, the request relay-tty's own TUI makes for *stop session*.
@MainActor
final class RemoteSessionEnder: SessionEnding {
    let name: String
    private let endpoint: RelayServer
    private let urlSession: URLSession

    init(name: String, endpoint: RelayServer) {
        self.name = name
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config)
    }

    func end(sessionId: String, completion: @escaping @MainActor (Error?) -> Void) {
        var components = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/sessions/\(sessionId)"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        if let token = endpoint.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        let name = name
        // `self` strongly, as `RemoteSpawner.post` does and for the same
        // reason: the caller makes an ender for one request and lets go.
        urlSession.dataTask(with: request) { [self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let failure: SessionEndError?
            if let error {
                failure = .unreachable(server: name, why: (error as NSError).localizedDescription)
            } else if status == 200 {
                failure = nil
            } else {
                failure = .refused(server: name, status: status, body: RemoteSpawner.errorLine(data))
            }
            Task { @MainActor in completion(failure) }
        }.resume()
    }
}

/// What the sheet says, as a value the tests can read.
struct EndSessionSheet: Equatable {
    var title: String
    var detail: String
    static let action = "End Session"

    /// `name` is what the header calls the session (its title, or its
    /// command line), `command` the program, `server` nil for this Mac.
    init(name: String, command: String, server: String?) {
        let what = (command.isEmpty || command == name) ? name : "\(name) — \(command)"
        title = "End this session?"
        detail = "\(what.isEmpty ? "The session" : what), on \(server ?? "this Mac"), "
            + "will be killed and its pane will close. Every client attached to it, "
            + "the Relay web client on your phone included, loses it too."
    }
}
