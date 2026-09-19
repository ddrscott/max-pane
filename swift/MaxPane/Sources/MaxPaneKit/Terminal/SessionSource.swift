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
/// refused, the source stops and stays `.refused` until the token is
/// replaced. Anything else is `.reconnecting` — `.unreachable` once it has
/// gone on past `unreachableAfter` — retried on the poll, and said once per
/// transition rather than once per attempt.
///
/// **How fast a dead server is noticed, and why it does not flap**
/// (ADR-0023). The tunnel's usual death is silent: the TCP stays up and
/// nothing answers. So the list request gives up after `requestTimeout`
/// (4 s: a healthy answer through relaytty.com is well under one), and a
/// failure while connected is not believed at once — it is strike one, and
/// the request is sent again half a second later; strike two is the verdict.
/// With the default 5 s poll that is ≤ 5 + 4 + 0.5 + 4 = 13.5 s from death to
/// `.reconnecting`, and one slow or dropped response costs nothing but the
/// retry. Two other things make it check now rather than at the next poll:
/// a protocol ping on `/ws/events` every `pingInterval` that gets no pong
/// within `pongTimeout` (which also counts as strike one — it is the same
/// evidence as a timed-out request), and a lane on this server losing its
/// wire (`SessionRegistry.laneLostWire`). Recovery is the first list that
/// arrives, on the same poll.
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
    /// How long one `GET /api/sessions` may take before it is a failure.
    let requestTimeout: TimeInterval
    /// The `/ws/events` protocol ping, and how long its pong may take.
    let pingInterval: TimeInterval
    let pongTimeout: TimeInterval
    /// How long `.reconnecting` goes on before it is called `.unreachable`.
    let unreachableAfter: TimeInterval
    /// Failures in a row since the last list that arrived. One is a retry;
    /// two is the verdict.
    private var strikes = 0
    /// When this outage began — the first verdict, or `start()` for a server
    /// that has not answered yet.
    private var offlineSince: Date?
    private var pinger: Timer?
    /// The one retry after a first failure, half a second later.
    private var retry: Timer?
    /// The ping whose pong is awaited; nil when none is.
    private var pingAwaited: UUID?
    /// The server's host, for the chip's tooltip and the error line.
    public var host: String { endpoint.baseURL.host ?? name }
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

    public init(
        name: String, endpoint: RelayServer, pollInterval: TimeInterval = 5,
        requestTimeout: TimeInterval = 4, pingInterval: TimeInterval = 5, pongTimeout: TimeInterval = 4,
        unreachableAfter: TimeInterval = 60
    ) {
        self.name = name
        self.endpoint = endpoint
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.unreachableAfter = unreachableAfter
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        urlSession = URLSession(configuration: config)
        super.init()
    }

    public func start() {
        guard !started else { return }
        started = true
        offlineSince = Date()
        refresh()
        connectEvents()
        pinger = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pingEvents() }
        }
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
        pinger?.invalidate(); pinger = nil
        retry?.invalidate(); retry = nil
        pingAwaited = nil
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
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
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
        strikes = 0
        offlineSince = nil
        // The list before the state. The registry restamps this server's
        // sessions the moment the state changes, and coming back it must
        // find the fresh list there, not the one from before the outage —
        // a stale BLOCKED shown for one turn is a Dock bounce for nothing.
        known = Dictionary(list.filter(\.isRunning).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        emit()
        state = .connected
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
        pinger?.invalidate(); pinger = nil
        retry?.invalidate(); retry = nil
        pingAwaited = nil
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
        strikes += 1
        // One failure while connected is not a verdict: a response can be
        // slow or dropped once without the server being gone, and a sidebar
        // that flips to RECONNECTING and back is worse than one that is a
        // few seconds late. Ask again now; the second failure is believed.
        if state == .connected, strikes < 2 {
            Log.debug("server \(name): no answer (\(why)); asking once more before believing it")
            // A beat first: a request that failed instantly (the network
            // not up yet after a wake) would fail instantly again, and two
            // failures a millisecond apart are one failure.
            retry?.invalidate()
            retry = Timer.scheduledTimer(withTimeInterval: min(0.5, requestTimeout / 8), repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
            return
        }
        if !saidUnreachable {
            Log.warn("server \(name): unreachable — \(why); retrying every \(Int(pollInterval)) s")
            saidUnreachable = true
        }
        lastError = "unreachable — \(host): \(why)"
        let began = offlineSince ?? Date()
        offlineSince = began
        state = Date().timeIntervalSince(began) >= unreachableAfter ? .unreachable : .reconnecting
    }

    // MARK: - the /ws/events ping

    /// A protocol ping on the events socket. A pong that does not come
    /// within `pongTimeout` is the same evidence as a list request that
    /// timed out — strike one — and the list is asked for now, which is the
    /// retry. Through a tunnel the edge may answer pings for a server that
    /// is frozen behind it; then this proves nothing and the poll is what
    /// notices, which is why it is a helper and not the detector.
    private func pingEvents() {
        guard !stopped, state == .connected, let events, pingAwaited == nil else { return }
        let id = UUID()
        pingAwaited = id
        events.sendPing { [weak self] error in
            Task { @MainActor in
                guard let self, self.pingAwaited == id else { return }
                self.pingAwaited = nil
                if error != nil { self.pongMissed() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: pongTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.pingAwaited == id else { return }
                self.pingAwaited = nil
                self.pongMissed()
            }
        }
    }

    private func pongMissed() {
        guard !stopped, state == .connected else { return }
        Log.debug("server \(name): no pong on /ws/events within \(Int(pongTimeout)) s; checking now")
        strikes = max(strikes, 1)
        // The socket is no use either way; the failure path reopens it.
        events?.cancel(with: .goingAway, reason: nil)
        refresh()
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
                    self.pingAwaited = nil
                    // The socket dropping is a reason to ask whether the
                    // server is still there, now rather than at the poll.
                    if self.state == .connected { self.refresh() }
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
