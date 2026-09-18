import Foundation

/// Where a remote relay-tty server is and how to prove who we are to it.
public struct RelayServer: Sendable, Equatable {
    /// How the token travels on the WebSocket upgrade. `verifyWsAuth` reads
    /// only the `Cookie:` header today (§9); `query` exists so the spike can
    /// show what `?token=` does — the shape `/ws/share` already takes.
    public enum TokenPlacement: String, Sendable { case cookie, query, none }

    /// `https://<slug>.relaytty.com` or `http://host:port`; no path.
    public let baseURL: URL
    /// The `session` JWT the server printed at startup, or nil for no credential.
    public let token: String?
    public let placement: TokenPlacement

    public init(baseURL: URL, token: String?, placement: TokenPlacement = .cookie) {
        self.baseURL = baseURL; self.token = token; self.placement = placement
    }

    /// `wss://…/ws/sessions/<id>` (`ws://` for a plain-http base).
    public func webSocketURL(sessionId: String) -> URL {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https" || c.scheme == "wss") ? "wss" : "ws"
        c.path = "/ws/sessions/\(sessionId)"
        if placement == .query, let token { c.queryItems = [URLQueryItem(name: "token", value: token)] }
        return c.url!
    }
}

/// The remote transport: relay-tty's `/ws/sessions/:id` over
/// `URLSessionWebSocketTask`.
///
/// One binary message is one payload, no length prefix either way (§1); text
/// frames are never protocol and are counted and dropped; an application
/// `PING` (0x20) goes out every `pingInterval`, and no inbound frame of any
/// kind for `zombieAfter` closes the connection as a zombie (§5, the reference
/// client's 10 s / 45 s). Close codes 4001 and 1008 are the server refusing
/// the credential and are reported final (§9); everything else is retryable.
///
/// The first payload is queued on the task before the upgrade completes, so
/// it is the first thing on the wire once it does: through a tunnel the
/// server's 100 ms `RESUME` window starts when the *bridge* opens its pty
/// socket, not when we see the 101, so there is nothing to wait for.
public final class WebSocketTransport: NSObject, RelayTransport, URLSessionWebSocketDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    public let server: RelayServer
    public let sessionId: String
    public let queue: DispatchQueue
    public let pingInterval: TimeInterval
    public let zombieAfter: TimeInterval

    public var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?
    public var onClosed: ((RelayClose) -> Void)?
    public private(set) var tConnected: Double = 0
    public private(set) var tFirstSent: Double = 0

    /// Counters the spike reads. `textFramesDropped` should stay 0 on a
    /// session socket; `/ws/events` is where text lives.
    public private(set) var inboundPayloads = 0
    public private(set) var inboundBytes = 0
    public private(set) var textFramesDropped = 0
    public private(set) var pingsSent = 0
    public private(set) var pongsReceived = 0
    public private(set) var lastInbound: Double = 0
    /// The HTTP status of the upgrade response when the server answered with
    /// one instead of a 101; 0 when the upgrade succeeded or never got a reply.
    public private(set) var upgradeStatus = 0

    private var urlSession: URLSession!
    private var task: URLSessionWebSocketTask?
    private var pinger: DispatchSourceTimer?
    private var closed = false

    public init(server: RelayServer, sessionId: String, queue: DispatchQueue,
                pingInterval: TimeInterval = 10, zombieAfter: TimeInterval = 45) {
        self.server = server
        self.sessionId = sessionId
        self.queue = queue
        self.pingInterval = pingInterval
        self.zombieAfter = zombieAfter
        super.init()
        let config = URLSessionConfiguration.ephemeral
        // The credential is ours to place, not the jar's.
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        let dq = OperationQueue()
        dq.maxConcurrentOperationCount = 1
        dq.underlyingQueue = queue
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: dq)
    }

    public func open(firstPayload: [UInt8]) throws {
        var request = URLRequest(url: server.webSocketURL(sessionId: sessionId))
        if server.placement == .cookie, let token = server.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        request.timeoutInterval = 30
        let t = urlSession.webSocketTask(with: request)
        t.maximumMessageSize = 64 << 20        // a 10 MiB ring, gzipped or not
        task = t
        lastInbound = now()
        t.resume()
        // Queued behind the upgrade; first on the wire after it.
        t.send(.data(Data(firstPayload))) { [weak self] error in
            if let error { self?.finish(RelayClose(kind: .failed((error as NSError).code), reason: error.localizedDescription)) }
        }
        tFirstSent = now()
        receiveNext()
        startPinger()
    }

    public func send(_ payload: [UInt8]) {
        task?.send(.data(Data(payload))) { [weak self] error in
            if let error { self?.finish(RelayClose(kind: .failed((error as NSError).code), reason: error.localizedDescription)) }
        }
    }

    public func close() {
        pinger?.cancel(); pinger = nil
        task?.cancel(with: .normalClosure, reason: nil)
        finish(RelayClose(kind: .closed))
    }

    /// The reference client's `reconnectNow()` hook (§5): a `PING` now, so a
    /// half-open connection after a wake is found in one round trip rather
    /// than at the next tick.
    public func pingNow() { sendPing() }

    // MARK: - inbound

    private func receiveNext() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let message):
                self.lastInbound = now()
                switch message {
                case .data(let data):
                    guard !data.isEmpty else { break }       // a bare frame carries nothing
                    self.inboundPayloads += 1
                    self.inboundBytes += data.count
                    let bytes = [UInt8](data)
                    if bytes[0] == WSMsg.pong { self.pongsReceived += 1 }
                    self.onPayload?(bytes[0], bytes[1...])
                case .string:
                    self.textFramesDropped += 1             // never session protocol (§1)
                @unknown default:
                    break
                }
                self.receiveNext()
            case .failure(let error):
                // A server close frame surfaces here first, before the
                // delegate's `didCloseWith`, as a plain error; the task has
                // the code by then. A cancel we asked for arrives here too.
                if let byCode = self.closeFromTask() { self.finish(byCode); return }
                let e = error as NSError
                self.finish(RelayClose(kind: .failed(e.code), reason: e.localizedDescription))
            }
        }
    }

    // MARK: - heartbeat

    private func startPinger() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pingInterval, repeating: pingInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.tick() }
        pinger = t
        t.resume()
    }

    private func tick() {
        guard !closed else { return }
        if now() - lastInbound > zombieAfter {
            pinger?.cancel(); pinger = nil
            task?.cancel(with: .goingAway, reason: nil)
            finish(RelayClose(kind: .zombie))
            return
        }
        sendPing()
    }

    private func sendPing() {
        guard !closed else { return }
        pingsSent += 1
        task?.send(.data(Data([WSMsg.ping]))) { _ in }
    }

    // MARK: - lifecycle

    private func finish(_ close: RelayClose) {
        guard !closed else { return }
        closed = true
        pinger?.cancel(); pinger = nil
        task?.cancel()
        onClosed?(close)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        tConnected = now()
        lastInbound = now()
    }

    /// The close the server sent, if it sent one. 4001 and 1008 are "stop
    /// reconnecting" (§9, gotcha 30); `CloseCode` has no case for 4001, but
    /// the raw value comes through the ObjC enum untouched.
    private func closeFromTask() -> RelayClose? {
        guard let task, task.closeCode.rawValue != 0 else { return nil }
        return Self.close(code: task.closeCode.rawValue, reason: task.closeReason)
    }

    static func close(code: Int, reason: Data?) -> RelayClose {
        let text = reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let kind: RelayClose.Kind = (code == 4001 || code == 1008) ? .authRefused : .closed
        return RelayClose(kind: kind, code: code, reason: text)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        finish(Self.close(code: closeCode.rawValue, reason: reason))
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            upgradeStatus = http.statusCode
        }
        if let byCode = closeFromTask() { finish(byCode); return }
        if let error {
            let e = error as NSError
            finish(RelayClose(kind: .failed(e.code), code: upgradeStatus, reason: e.localizedDescription))
        } else {
            finish(RelayClose(kind: .closed, code: upgradeStatus))
        }
    }
}
