import Foundation
import RelayClient

/// Connects a `TerminalPaneController` to a live RelayTTY session.
///
/// `RelaySession` is the protocol client — it knows framing, the handshake, the
/// offset arithmetic and gzip, and it knows nothing about AppKit. This is the
/// thin piece between it and the pane: it moves callbacks onto the main actor
/// and owns the reconnect policy.
///
/// **It never sends `RESIZE` on its own.** The only path to `claimSize` is the
/// user's explicit command (ADR-0007).
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

    /// PRD §11: "retry with backoff".
    private static let minimumDelay: TimeInterval = 0.5
    private static let maximumDelay: TimeInterval = 15
    /// Cap a cold replay. A 5.3 MB scrollback costs 210 ms of emulator parsing
    /// (M2 §3), which is fine once but not on every lane at launch. The search
    /// index keeps 200 lines and Relay keeps the real archive.
    private static let maximumReplayBytes: Double = 256 * 1024

    init(sessionId: String) {
        self.sessionId = sessionId
    }

    func connect() {
        wantsConnection = true
        openSession()
    }

    func disconnect() {
        wantsConnection = false
        session?.close()
        session = nil
    }

    func send(_ bytes: ArraySlice<UInt8>) {
        session?.sendInput(Array(bytes))
    }

    /// ADR-0007 §5. Reached only from the user's "claim this session" command,
    /// which confirms first because it reshapes the PTY for every other client.
    func claimSize(cols: Int, rows: Int) {
        session?.sendResize(cols: cols, rows: rows)
    }

    // MARK: - connection

    private func openSession() {
        guard wantsConnection, session == nil else { return }

        let session = RelaySession(id: sessionId)
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
                // An exited session is gone for good; do not reconnect to it.
                self?.wantsConnection = false
            }
        }
        session.onHandshake = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reconnectDelay = Self.minimumDelay
                self.onConnectionChange?(true)
            }
        }
        session.onClosed = { [weak self] in
            Task { @MainActor in self?.handleClosed() }
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
        } catch {
            self.session = nil
            onConnectionChange?(false)
            scheduleReconnect()
        }
    }

    private func handleClosed() {
        session = nil
        guard wantsConnection else { return }
        onConnectionChange?(false)
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
