import AppKit
import Foundation
import RelayClient

/// Where a server's session list comes from.
///
/// One per server. The registry merges them and never asks where a reading
/// came from beyond `server`; a source owns its own cadence, its own
/// connection and its own idea of liveness — `kill(pid, 0)` for the disk,
/// the server's `status` for a remote, which has no pid this Mac can signal.
///
/// Callbacks arrive on the main thread.
@MainActor
public protocol SessionSource: AnyObject {
    /// `nil` for this Mac. The local server is implicit and never named.
    var server: String? { get }
    /// Every live session this server has, replacing the last reading.
    var onChange: (([RelaySessionInfo]) -> Void)? { get set }
    var onStateChange: ((ServerState) -> Void)? { get set }
    var state: ServerState { get }

    func start()
    func stop()
    /// Read the list again now, out of cadence.
    func refresh()
}

/// `~/.relay-tty/sessions` on this Mac: today's directory and watcher, behind
/// the protocol. Always `.connected` — its sessions are files on this disk.
@MainActor
public final class DiskSessionSource: SessionSource {
    public let server: String? = nil
    public var onChange: (([RelaySessionInfo]) -> Void)?
    public var onStateChange: ((ServerState) -> Void)?
    public let state: ServerState = .connected

    private let pollInterval: TimeInterval
    private var watcher: RelaySessionWatcher?

    public init(pollInterval: TimeInterval) {
        self.pollInterval = pollInterval
    }

    public func start() {
        // The first reading is synchronous, so a registry has its sessions
        // the moment it exists — the sidebar and the picker read it at launch.
        onChange?(RelaySessionDirectory().live())
        watcher = RelaySessionWatcher(pollInterval: pollInterval) { [weak self] infos in
            MainActor.assumeIsolated { self?.onChange?(infos) }
        }
    }

    public func stop() { watcher = nil }

    public func refresh() { onChange?(RelaySessionDirectory().live()) }
}

/// A remote relay-tty server's sessions: `GET /api/sessions` plus
/// `/ws/events`, which says `"sessions-changed"` (text: fetch again) and
/// carries `SESSION_UPDATE` frames (binary: one session's metadata, patched
/// in place). Polled on `pollInterval` as the fallback, the way the disk is.
///
/// The credential rides as `Cookie: session=<token>` on every request, HTTP
/// and upgrade alike — through relaytty.com the upgrade is accepted without
/// it today (spike M7 §4), LAN-direct it is required, and sending it always
/// is the one rule that is right on both wires.
///
/// Errors are one line and name the server. A 401 is final: the token was
/// refused, the source stops and stays `.refused` until relaunch. Anything
/// else is `.reconnecting`, retried with backoff, and said once per
/// transition rather than once per attempt.
@MainActor
public final class RemoteSessionSource: NSObject, SessionSource {
    public let name: String
    public var server: String? { name }
    public var onChange: (([RelaySessionInfo]) -> Void)?
    public var onStateChange: ((ServerState) -> Void)?
    public private(set) var state: ServerState = .reconnecting {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    /// Why the server is not connected, in one line for Settings: `token
    /// refused — …` or `unreachable — <host>: <why>`. Nil while connected.
    /// Never carries the token.
    public private(set) var lastError: String?

    private let endpoint: RelayServer
    private let pollInterval: TimeInterval
    private let urlSession: URLSession
    private var events: URLSessionWebSocketTask?
    private var poll: Timer?
    private var eventsRetry: TimeInterval = 1
    private var eventsTimer: Timer?
    private var stopped = false
    private var started = false
    private var wakeObserver: NSObjectProtocol?
    /// The last list, by id, patched by `SESSION_UPDATE` between fetches.
    private var known: [String: RelaySessionInfo] = [:]
    private var fetching = false

    /// Counters for tests and the log.
    public private(set) var fetches = 0
    public private(set) var updatesApplied = 0

    public init(name: String, endpoint: RelayServer, pollInterval: TimeInterval = 5) {
        self.name = name
        self.endpoint = endpoint
        self.pollInterval = pollInterval
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        urlSession = URLSession(configuration: config)
        super.init()
    }

    public func start() {
        guard !started else { return }
        started = true
        refresh()
        connectEvents()
        poll = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // After a sleep the events socket is half-open and the list is stale;
        // ask now rather than at the next poll, and reopen the socket.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.refresh()
                self.events?.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    public func stop() {
        stopped = true
        poll?.invalidate(); poll = nil
        eventsTimer?.invalidate(); eventsTimer = nil
        events?.cancel(with: .goingAway, reason: nil); events = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    // MARK: - the list

    /// `wss://…/ws/events` (`ws://` for a plain-http base).
    var eventsURL: URL {
        var c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https" || c.scheme == "wss") ? "wss" : "ws"
        c.path = "/ws/events"
        return c.url!
    }

    var listURL: URL {
        var c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/api/sessions"
        // So an exit is a row that changes, not one that vanishes between
        // polls; the exited ones are dropped below, as the disk drops them.
        c.queryItems = [URLQueryItem(name: "includeExited", value: "1")]
        return c.url!
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = endpoint.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    public func refresh() {
        guard !stopped, state != .refused, !fetching else { return }
        fetching = true
        fetches += 1
        let task = urlSession.dataTask(with: request(listURL)) { [weak self] data, response, error in
            Task { @MainActor in self?.fetched(data, response, error) }
        }
        task.resume()
    }

    private func fetched(_ data: Data?, _ response: URLResponse?, _ error: Error?) {
        fetching = false
        guard !stopped else { return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            refuse(status)
            return
        }
        guard status == 200, let data else {
            let why = error.map { ($0 as NSError).localizedDescription } ?? "HTTP \(status)"
            unreachable(why)
            return
        }
        guard let list = Self.decodeList(data) else {
            unreachable("could not read the session list")
            return
        }
        if state != .connected {
            Log.warn("server \(name): connected, \(list.count) session\(list.count == 1 ? "" : "s")")
        }
        saidUnreachable = false
        lastError = nil
        state = .connected
        known = Dictionary(uniqueKeysWithValues: list.filter(\.isRunning).map { ($0.id, $0) })
        emit()
    }

    /// `{"sessions": [...]}`, one session at a time so one row the decoder
    /// cannot read costs that row and not the list.
    static func decodeList(_ data: Data) -> [RelaySessionInfo]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["sessions"] as? [[String: Any]]
        else { return nil }
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            guard let bytes = try? JSONSerialization.data(withJSONObject: row) else { return nil }
            return try? decoder.decode(RelaySessionInfo.self, from: bytes)
        }
    }

    /// A 401 is final for this source: it stops, and says so once. A new
    /// token makes a new source (Settings › Servers, paste), which is what
    /// lifts it. The list goes empty — a server that refuses us has no
    /// sessions we can speak for, and the sidebar shows its header with the
    /// state and no rows.
    private func refuse(_ status: Int) {
        Log.warn("server \(name): token refused (HTTP \(status)) — not retrying until the token is replaced")
        lastError = endpoint.token == nil
            ? "no token — paste the Auth URL from the server's startup output"
            : "token refused — paste the Auth URL from the server's startup output"
        state = .refused
        poll?.invalidate(); poll = nil
        eventsTimer?.invalidate(); eventsTimer = nil
        events?.cancel(with: .goingAway, reason: nil); events = nil
        if !known.isEmpty {
            known = [:]
            emit()
        }
    }

    /// Said once per outage: on the first failure, and again only after a
    /// success in between.
    private var saidUnreachable = false

    private func unreachable(_ why: String) {
        if !saidUnreachable {
            Log.warn("server \(name): unreachable — \(why); retrying every \(Int(pollInterval)) s")
            saidUnreachable = true
        }
        lastError = "unreachable — \(endpoint.baseURL.host ?? name): \(why)"
        state = .reconnecting
    }

    private func emit() {
        let list = known.values.sorted { ($0.lastActivity ?? $0.createdAt) > ($1.lastActivity ?? $1.createdAt) }
        onChange?(list)
    }

    // MARK: - /ws/events

    private func connectEvents() {
        guard !stopped, state != .refused, events == nil else { return }
        var request = request(eventsURL)
        request.timeoutInterval = 30
        let task = urlSession.webSocketTask(with: request)
        events = task
        task.resume()
        receiveEvents(task)
    }

    private func receiveEvents(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.events === task, !self.stopped else { return }
                switch result {
                case .success(let message):
                    self.eventsRetry = 1
                    switch message {
                    case .string(let text):
                        if text == "sessions-changed" { self.refresh() }
                    case .data(let data):
                        self.apply(update: data)
                    @unknown default:
                        break
                    }
                    self.receiveEvents(task)
                case .failure:
                    self.events = nil
                    let http = (task.response as? HTTPURLResponse)?.statusCode ?? 0
                    if http == 401 || http == 403 { self.refuse(http); return }
                    let delay = self.eventsRetry
                    self.eventsRetry = min(self.eventsRetry * 2, 10)
                    self.eventsTimer?.invalidate()
                    self.eventsTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.connectEvents() }
                    }
                }
            }
        }
    }

    /// A `SESSION_UPDATE` (0x15): the full session JSON. Broadcast for every
    /// session the server has, so this is the whole of the filtering — an
    /// update for a session the list has not seen is adopted, an exit drops
    /// the row, and a text frame is never protocol here.
    func apply(update data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 1, bytes[0] == WSMsg.sessionUpdate,
              let info = try? JSONDecoder().decode(RelaySessionInfo.self, from: Data(bytes[1...]))
        else { return }
        updatesApplied += 1
        if info.isRunning { known[info.id] = info } else { known.removeValue(forKey: info.id) }
        emit()
    }
}
