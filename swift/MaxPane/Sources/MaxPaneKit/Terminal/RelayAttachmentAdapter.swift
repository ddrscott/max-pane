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

    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onHostResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

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

    init(sessionId: String, transport: ((DispatchQueue) -> RelayTransport)? = nil) {
        self.sessionId = sessionId
        self.makeTransport = transport
    }

    func connect() {
        wantsConnection = true
        openSession()
    }

    func disconnect() {
        wantsConnection = false
        isAttached = false
        pending.clear()
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
        guard let session, isAttached else {
            if !pending.hold(bytes) {
                Log.warn("\(sessionId): dropped input buffered while disconnected — over \(PendingInput.limit)B")
            }
            return
        }
        session.sendInput(Array(bytes))
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
            let queue = DispatchQueue(label: "relay.session.\(sessionId)")
            session = RelaySession(id: sessionId, queue: queue, transport: makeTransport(queue))
        } else {
            session = RelaySession(id: sessionId)
        }
        self.session = session

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
        session.onReplay = { [weak self] plain, _ in
            Task { @MainActor in
                guard let self else { return }
                self.lastOffset = session.offset
                self.onData?(plain[...])
            }
        }
        session.onResize = { [weak self] cols, rows in
            Task { @MainActor in self?.onHostResize?(cols, rows) }
        }
        session.onTitle = { [weak self] title in
            Task { @MainActor in self?.onTitle?(title) }
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
            Log.debug("attached \(sessionId) at offset \(lastOffset)")
        } catch {
            Log.warn("could not attach \(sessionId) at \(RelayPaths.socket(for: sessionId)): \(error)")
            self.session = nil
            onConnectionChange?(false)
            scheduleReconnect()
        }
    }

    /// Send what was held while the socket was down, or decide against it.
    private func flushPendingInput() {
        guard let session, !pending.isEmpty else { return }
        guard let bytes = pending.take() else {
            Log.warn("\(sessionId): dropped input buffered more than \(Int(PendingInput.maxAge))s ago")
            return
        }
        Log.debug("\(sessionId): flushed \(bytes.count)B of input held while disconnected")
        session.sendInput(bytes)
    }

    private func handleClosed(_ reason: RelayClose?) {
        session = nil
        isAttached = false
        guard wantsConnection else { return }
        onConnectionChange?(false)
        // A server that refused the credential (WS close 4001/1008) will
        // refuse it again; retrying would only be a loop with a log line.
        if let reason, reason.isFinal {
            Log.warn("\(sessionId): not reconnecting — \(reason)")
            wantsConnection = false
            pending.clear()
            return
        }
        if let reason { Log.debug("\(sessionId): connection \(reason); reconnecting") }
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
