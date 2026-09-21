import AppKit
import Foundation
import RelayClient

/// Connects a `TerminalPaneController` to a live RelayTTY session.
///
/// `RelaySession` is the protocol client — it knows framing, the handshake, the
/// offset arithmetic and gzip, and it knows nothing about AppKit. This is the
/// thin piece between it and the pane: it moves callbacks onto the main actor
/// and owns the reconnect policy.
///
/// **It never decides to send `RESIZE`.** `claimSize` is reached from exactly
/// two places, both of them the user saying so: the explicit claim command
/// (ADR-0007 §5), and the drop at the end of a seam drag — dragging a pane's
/// height *is* asking for a different number of rows, and a TUI that thinks it
/// has fifty rows will paint fifty into a pane showing twenty. The drag holds
/// the claim back until the mouse comes up, because a 400pt drag crosses a row
/// boundary every 17 points and spike M2 measured one `htop` reshape at 6,671
/// bytes of forced redraw on every other client — including a phone.
@MainActor
final class RelayAttachmentAdapter: RelayAttachment {
    let sessionId: String
    /// The server the session is on, for the log; nil for this Mac.
    let server: String?

    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onHostResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onRefused: ((String) -> Void)?
    /// The emulator should be cleared before the next replay is fed to it:
    /// the server sent the whole ring where a delta was due.
    var onReplaceScreen: (() -> Void)?
    /// The wire went without anyone asking it to — a zombie, a failed read,
    /// a reconnect that could not open. Whoever watches this session's
    /// server checks it now (`SessionRegistry.laneLostWire`), so one lane
    /// noticing is every lane and the sidebar noticing (ADR-0023).
    var onWireLost: (() -> Void)?
    /// Input held while the wire was down was dropped rather than sent: how
    /// many bytes. The pane says so in one line; see `PendingInput` for why
    /// old keystrokes are not replayed into a session that has moved on.
    var onInputDropped: ((Int) -> Void)?
    var onClipboard: ((String) -> Void)?

    private var session: RelaySession?
    private var reconnectDelay: TimeInterval = 0.5
    private var wantsConnection = false
    /// Byte offset to resume from, so a reconnect replays only what was missed.
    private var lastOffset: Double = 0
    /// True from the SYNC that completes the handshake until the socket goes.
    ///
    /// Not `RelaySession.handshakeDone`: that is written on the session's own
    /// queue, and this is read on the main actor on the keystroke path.
    private var isAttached = false
    /// What the user typed or pasted at a pane whose socket was not up yet.
    private var pending = PendingInput()
    /// A reconnect's delta replay, held until its `SYNC` says whether it is
    /// one. See `syncArrived`.
    private var heldReplay: [UInt8]?

    /// PRD §11: "retry with backoff".
    private static let minimumDelay: TimeInterval = 0.5
    private static let maximumDelay: TimeInterval = 15
    /// Cap a cold replay. A 5.3 MB scrollback costs 210 ms of emulator parsing
    /// (M2 §3), which is fine once but not on every lane at launch. The search
    /// index keeps 200 lines and Relay keeps the real archive.
    private static let maximumReplayBytes: Double = 256 * 1024

    /// Builds the wire for each connection. Nil is today's Unix socket; the
    /// remote-relay spike passes a `WebSocketTransport` here and nothing else
    /// about the adapter or the pane changes (`docs/spikes/07-m7-remote-relay.md`).
    private let makeTransport: ((DispatchQueue) -> RelayTransport)?
    /// The live WebSocket, if that is what this session is on, for the wake
    /// hook. Nil on a Unix socket, which a sleep does not half-open.
    private weak var webSocket: WebSocketTransport?
    private var wakeObserver: NSObjectProtocol?

    init(sessionId: String, server: String? = nil, transport: ((DispatchQueue) -> RelayTransport)? = nil) {
        self.sessionId = sessionId
        self.server = server
        self.makeTransport = transport
        if transport != nil {
            // A remote connection after a sleep is silent until the zombie
            // timer notices, 45 s later. A PING now finds out in one round
            // trip, and a dead one reconnects at once (spike M7 §10).
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.webSocket?.pingNow() }
            }
        }
    }

    /// How long a lane gives its wire to answer a `PING` once its server's
    /// list has stopped answering, before it agrees and shows the banner.
    static let serverOffPongDeadline: TimeInterval = 4
    /// The deadline this adapter uses; a test shortens it.
    var pongDeadline: TimeInterval = RelayAttachmentAdapter.serverOffPongDeadline

    /// The session's server stopped answering its list, or started again —
    /// the source's verdict, handed down by the strip.
    ///
    /// **Off:** the wire is asked to prove itself now. A half-open socket —
    /// the tunnel's usual death — fails that in `serverOffPongDeadline` and
    /// closes as a zombie, which is the banner and the reconnect loop 4 s
    /// after the sidebar said so rather than 45. A wire that answers is left
    /// alone: the list being down is no reason to cut a session that works.
    ///
    /// **On:** a lane waiting out a backoff of up to 15 s reconnects now, and
    /// one whose attempt is hanging is tested the same way.
    func serverStateChanged(_ state: ServerState) {
        guard wantsConnection else { return }
        if state.isOff {
            webSocket?.pingNow(deadline: pongDeadline)
        } else if session == nil {
            reconnectDelay = Self.minimumDelay
            openSession()
        } else if !isAttached {
            // An attempt opened while the server was gone can sit on an edge
            // that said 101 and nothing else for 45 s. It proves itself now
            // or makes way for one that will.
            webSocket?.pingNow(deadline: pongDeadline)
        }
    }

    /// `sessionId`, or `server:sessionId`, for the log.
    private var label: String { server.map { "\($0):\(sessionId)" } ?? sessionId }

    func connect() {
        wantsConnection = true
        openSession()
    }

    func disconnect() {
        wantsConnection = false
        isAttached = false
        pending.clear()
        _ = paced.takeBacklog()
        heldReplay = nil
        session?.close()
        session = nil
    }

    /// Bytes for the PTY.
    ///
    /// A pane is live to the user before its socket is: `maxpane run` focuses
    /// a new lane the moment the ledger has it, which is one or more run loops
    /// — and, if Relay is still starting, several backoff rounds — before the
    /// handshake lands. Every reconnect reopens the same window.
    ///
    /// This used to be `session?.sendInput(...)`. That `?` discards a paste
    /// with no trace and no way to tell from the outside: the pane is drawn,
    /// the cursor blinks, and the bytes are gone. Holding them instead costs a
    /// few kilobytes, and `PendingInput` carries the rules that keep held
    /// input from turning into a surprise later.
    func send(_ bytes: ArraySlice<UInt8>) {
        guard session != nil, isAttached else {
            let held = pending.bytes.count + bytes.count
            if !pending.hold(bytes) {
                Log.warn("\(sessionId): dropped input buffered while disconnected — over \(PendingInput.limit)B")
                onInputDropped?(held)
            }
            return
        }
        paced.enqueue(bytes)
    }

    /// Everything that goes to the session goes through here: what is typed,
    /// what is pasted, what was held while the wire was down. At most 1 000
    /// bytes a message and one message per 5 ms; `PacedInput` has the numbers.
    private lazy var paced = PacedInput { [weak self] piece in
        self?.session?.sendInput(piece)
    }

    /// ADR-0007 §5. Reached only from the user's "claim this session" command,
    /// which confirms first because it reshapes the PTY for every other client.
    func claimSize(cols: Int, rows: Int) {
        session?.sendResize(cols: cols, rows: rows)
    }

    // MARK: - connection

    private func openSession() {
        guard wantsConnection, session == nil else { return }

        let session: RelaySession
        if let makeTransport {
            let queue = DispatchQueue(label: "relay.session.\(label)")
            let transport = makeTransport(queue)
            webSocket = transport as? WebSocketTransport
            session = RelaySession(id: sessionId, queue: queue, transport: transport)
        } else {
            session = RelaySession(id: sessionId)
        }
        self.session = session
        // What a delta replay would be, at most: the bytes past our offset.
        // Captured now because the session's offset moves on its own queue.
        let resumedFrom = lastOffset

        // Every callback arrives on the session's own queue. Hop to the main
        // actor before touching anything the UI owns.
        session.onData = { [weak self] bytes in
            let copy = Array(bytes)
            Task { @MainActor in
                guard let self else { return }
                self.lastOffset = session.offset
                self.onData?(copy[...])
            }
        }
        session.onReplay = { [weak self] plain, isDelta in
            Task { @MainActor in
                guard let self else { return }
                // A reconnect's replay is held until the SYNC after it says
                // how long a delta could honestly be; see `syncArrived`.
                if isDelta, resumedFrom > 0 {
                    self.heldReplay = plain
                    return
                }
                self.lastOffset = session.offset
                self.onData?(plain[...])
            }
        }
        session.onSync = { [weak self] value in
            Task { @MainActor in self?.syncArrived(value, resumedFrom: resumedFrom, offset: session.offset) }
        }
        session.onResize = { [weak self] cols, rows in
            Task { @MainActor in self?.onHostResize?(cols, rows) }
        }
        session.onTitle = { [weak self] title in
            Task { @MainActor in self?.onTitle?(title) }
        }
        session.onClipboard = { [weak self] text in
            Task { @MainActor in self?.onClipboard?(text) }
        }
        session.onExit = { [weak self] code in
            Task { @MainActor in
                self?.onExit?(code)
                // An exited session is gone for good; do not reconnect to it,
                // and do not keep input for a PTY that will never read it.
                self?.wantsConnection = false
                self?.pending.clear()
            }
        }
        session.onHandshake = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectDelay = Self.minimumDelay
                self.isAttached = true
                // Before the banner clears: what the user typed at this pane
                // goes first, ahead of anything they type once it looks live.
                self.flushPendingInput()
                self.onConnectionChange?(true)
            }
        }
        session.onClosed = { [weak self] in
            let reason = session.closeReason
            Task { @MainActor in self?.handleClosed(reason) }
        }
        session.onGzipError = { [weak self] _ in
            // A replay we cannot inflate is not fatal — reconnecting from
            // offset 0 gets a plain one.
            Task { @MainActor in
                self?.lastOffset = 0
                self?.session?.close()
            }
        }

        do {
            // A reconnect resumes from where we stopped, so the pane gets only
            // what it missed rather than the whole buffer again.
            let mode: AttachMode = .resume(
                offset: lastOffset,
                maxReplayBytes: lastOffset > 0 ? nil : Self.maximumReplayBytes)
            try session.connect(mode: mode)
            Log.debug("attached \(label) at offset \(lastOffset)")
        } catch {
            if server == nil {
                Log.warn("could not attach \(sessionId) at \(RelayPaths.socket(for: sessionId)): \(error)")
            } else {
                Log.warn("could not attach \(label): \(error)")
            }
            self.session = nil
            onConnectionChange?(false)
            onWireLost?()
            scheduleReconnect()
        }
    }

    /// The `SYNC` after a reconnect's replay. A reconnect asked for the bytes
    /// past `resumedFrom`; a delta replay can carry at most `sync −
    /// resumedFrom` of them. pty-host answers a `RESUME` it missed with the
    /// whole ring and no `SYNC(0)`, which the session cannot tell from a
    /// delta (spike M7 §3) — but the ring is longer than the gap, and that is
    /// the tell. Feeding it as a delta appends the scrollback again; the
    /// screen is replaced first instead, so the pane shows the ring once.
    private func syncArrived(_ sync: Double, resumedFrom: Double, offset: Double) {
        guard let held = heldReplay else { return }
        heldReplay = nil
        if Self.isFullReplay(bytes: held.count, resumedFrom: resumedFrom, sync: sync) {
            Log.debug("\(label): full replay disguised as a delta (\(held.count)B for a \(Int(sync - resumedFrom))B gap); replacing the screen")
            onReplaceScreen?()
        }
        lastOffset = offset
        onData?(held[...])
    }

    static func isFullReplay(bytes: Int, resumedFrom: Double, sync: Double) -> Bool {
        Double(bytes) > max(sync - resumedFrom, 0)
    }

    /// Send what was held while the socket was down, or decide against it.
    private func flushPendingInput() {
        guard session != nil, !pending.isEmpty else { return }
        let held = pending.bytes.count
        guard let bytes = pending.take() else {
            Log.warn("\(sessionId): dropped input buffered more than \(Int(PendingInput.maxAge))s ago")
            onInputDropped?(held)
            return
        }
        Log.debug("\(sessionId): flushed \(bytes.count)B of input held while disconnected")
        paced.enqueue(bytes[...])
    }

    private func handleClosed(_ reason: RelayClose?) {
        session = nil
        isAttached = false
        heldReplay = nil
        // The rest of a paste that was still going out when the wire went. It
        // is input with nowhere to go, the same as anything typed from here
        // on, and is held or dropped by the same rules.
        let unsent = paced.takeBacklog()
        guard wantsConnection else { return }
        if !unsent.isEmpty, !pending.hold(unsent[...]) {
            Log.warn("\(sessionId): dropped \(unsent.count)B still going out when the connection went")
            onInputDropped?(unsent.count)
        }
        onConnectionChange?(false)
        // A server that refused the credential (WS close 4001/1008, or a 401
        // on the upgrade) will refuse it again; retrying would only be a
        // loop with a log line. The pane is told in one line, naming the
        // server, and the lane stays where it is.
        if let reason, reason.isFinal {
            let why = server.map { "\($0): token refused" } ?? "refused"
            Log.warn("\(label): not reconnecting — \(reason)")
            wantsConnection = false
            pending.clear()
            onRefused?(reason.reason == "server not configured" ? "\(server ?? ""): server not configured" : why)
            return
        }
        if let reason { Log.debug("\(label): connection \(reason); reconnecting") }
        onWireLost?()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, Self.maximumDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openSession()
        }
    }
}
