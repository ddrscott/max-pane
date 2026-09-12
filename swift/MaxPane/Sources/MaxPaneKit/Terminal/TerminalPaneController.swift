import AppKit
import LanedCore
import SwiftTerm

/// The byte stream a terminal pane is attached to.
///
/// Narrow on purpose. The concrete implementation is the RelayTTY protocol
/// client; this exists so the pane can be reasoned about, and tested, without
/// one — and so the client stays a thing with no opinion about AppKit.
@MainActor
protocol RelayAttachment: AnyObject {
    var sessionId: String { get }
    /// Terminal output, already inflated and in wire order.
    var onData: ((ArraySlice<UInt8>) -> Void)? { get set }
    /// The PTY's size, as the host reports it. **Inbound only** — see the
    /// resize note on `TerminalPaneController`.
    var onHostResize: ((_ cols: Int, _ rows: Int) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    /// `false` while reconnecting, which the pane renders rather than hides.
    var onConnectionChange: ((Bool) -> Void)? { get set }

    func connect()
    func disconnect()
    func send(_ bytes: ArraySlice<UInt8>)
}

/// A terminal pane: a SwiftTerm view attached to a RelayTTY session.
///
/// **On resize.** RelayTTY's PTY resize is global last-writer-wins — one PTY,
/// one `winsize`, no per-client viewport. PRD §3 keeps the phone client on the
/// same sessions and §8 makes lanes narrow portrait columns, so a MaxPane column
/// that asserted its own size would reshape the PTY for every other client and
/// force a full TUI redraw on each flip. This pane therefore **never sends
/// RESIZE**: it takes the host's size from the inbound frame and fits the
/// content inside the column. See the resize ADR.
///
/// pty panes are never unparented and never evicted (PRD §10.3): SwiftTerm is
/// cheap, and the attachment is the thing holding the session's continuity.
@MainActor
final class TerminalPaneController: NSObject, PaneController {
    let paneId: String
    private let store: StripStore
    private let config: Config
    private let container = NSView()
    private let terminal: TerminalView
    private let status = ReconnectingBanner()

    private var attachment: RelayAttachment?
    private var pane: Pane
    private var scrollbackDebounce: DispatchWorkItem?

    /// Last cwd seen, for ⌘T spawning a sibling in the right place and for
    /// tagging. Sourced from OSC 7 in the stream, backed by the session file.
    private(set) var currentCwd: String?

    var view: NSView { container }

    init(pane: Pane, store: StripStore, config: Config) {
        self.paneId = pane.id
        self.pane = pane
        self.store = store
        self.config = config
        self.terminal = TerminalView(frame: .zero)
        super.init()

        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.laneBackground.cgColor

        terminal.autoresizingMask = [.width, .height]
        terminal.frame = container.bounds
        terminal.terminalDelegate = self
        container.addSubview(terminal)

        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: container.topAnchor),
            status.heightAnchor.constraint(equalToConstant: 22),
        ])
        status.isHidden = true

        // Seed cwd from the session file so a freshly restored lane is tagged
        // before a single byte has arrived.
        if let sessionId = pane.relaySessionId {
            currentCwd = RelaySessionDirectory().session(sessionId)?.cwd
            reportCwd()
        }
    }

    /// Attach to the live session. Separate from `init` so a lane can exist —
    /// with its ordinal, its tag and its place on the strip — while Relay is
    /// unreachable (PRD §11, §15.8).
    func attach(_ attachment: RelayAttachment) {
        self.attachment = attachment

        attachment.onData = { [weak self] bytes in
            guard let self else { return }
            self.terminal.feed(byteArray: bytes)
            self.sniffOSC7(bytes)
            self.scheduleScrollbackPush()
        }
        attachment.onHostResize = { [weak self] cols, rows in
            // The host reshaped the PTY — possibly because a phone attached.
            // Follow it; never lead it.
            self?.terminal.getTerminal().resize(cols: cols, rows: rows)
        }
        attachment.onTitle = { [weak self] title in
            guard let self, let laneId = self.store.lane(containing: self.paneId)?.id else { return }
            try? self.store.setLaneTitle(laneId, title)
        }
        attachment.onConnectionChange = { [weak self] connected in
            self?.status.isHidden = connected
            self?.status.setState(connected ? .connected : .reconnecting)
        }
        attachment.onExit = { [weak self] code in
            self?.status.isHidden = false
            self?.status.setState(.exited(code))
        }
        attachment.connect()
    }

    // MARK: - PaneController

    func apply(_ pane: Pane) { self.pane = pane }

    func takeFocus() { container.window?.makeFirstResponder(terminal) }

    func tearDown() {
        scrollbackDebounce?.cancel()
        attachment?.disconnect()
        attachment = nil
    }

    // pty panes are exempt from all four of these (PRD §10.3). The policy in
    // `laned-core` never emits anything but `.keep` for them; these are here
    // because the protocol asks, and they do nothing on purpose.
    func unparent() {}
    func reparentIfNeeded() {}
    func evict() {}
    func rehydrate() {}

    // MARK: - cwd

    /// Pull the working directory out of OSC 7 as it goes past.
    ///
    /// pty-host reads OSC 7 to update its own session metadata but does not
    /// strip it from the output stream — its escape extractor removes only OSC
    /// 9, 52 and 1337. So the sequence is still here in bytes already being fed
    /// to the terminal, and sniffing it is three orders of magnitude fresher
    /// than the ≤5 s session-file flush. ADR-0005.
    ///
    /// Format: `ESC ] 7 ; file://<host>/<path> BEL` (or `ESC \` as terminator).
    private func sniffOSC7(_ bytes: ArraySlice<UInt8>) {
        guard let path = Self.extractOSC7Path(bytes) else { return }
        guard path != currentCwd else { return }
        currentCwd = path
        reportCwd()
    }

    static func extractOSC7Path(_ bytes: ArraySlice<UInt8>) -> String? {
        let prefix = Array("\u{1b}]7;file://".utf8)
        let buf = Array(bytes)
        guard buf.count > prefix.count else { return nil }

        // Scan for the last occurrence: a burst can contain several prompts and
        // only the newest is true.
        var found: String? = nil
        var i = 0
        while i + prefix.count <= buf.count {
            guard Array(buf[i..<(i + prefix.count)]) == prefix else {
                i += 1
                continue
            }
            var j = i + prefix.count
            var payload: [UInt8] = []
            while j < buf.count {
                let b = buf[j]
                // BEL, or ESC \ (ST).
                if b == 0x07 { break }
                if b == 0x1b, j + 1 < buf.count, buf[j + 1] == 0x5c { break }
                payload.append(b)
                j += 1
            }
            // `file://host/path` — drop the host, keep the path.
            if let text = String(bytes: payload, encoding: .utf8),
               let slash = text.firstIndex(of: "/") {
                let raw = String(text[slash...])
                found = raw.removingPercentEncoding ?? raw
            }
            i = j
        }
        return found
    }

    private func reportCwd() {
        guard let cwd = currentCwd, let laneId = store.lane(containing: paneId)?.id else { return }
        // Cheap: an unchanged cwd costs 0.009 ms and writes nothing.
        store.observeCwd(laneId, cwd)
    }

    // MARK: - search index

    /// Push the last 200 lines to `laned-core` so ⌘P can find them (PRD §7.5).
    ///
    /// Debounced hard. A busy agent produces output continuously, and the index
    /// only needs to be roughly current — it is a way to find a lane, not a log.
    private func scheduleScrollbackPush() {
        scrollbackDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushScrollback() }
        scrollbackDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func pushScrollback() {
        // SwiftTerm keeps `buffer.lines` internal, so the only public way to the
        // scrollback is the whole buffer at once. That is more allocation than
        // the 200 lines we keep, which is why this runs on a 1.5 s debounce and
        // only while output is actually flowing. If M2's 30-session numbers say
        // it matters, the fix is a public tail accessor upstream, not a private
        // reach-around here.
        let data = terminal.getTerminal().getBufferAsData()
        guard let text = String(data: data, encoding: .utf8) else { return }

        var lines: [String] = []
        lines.reserveCapacity(Self.scrollbackLines)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append(String(line))
            if lines.count == Self.scrollbackLines { break }
        }
        guard !lines.isEmpty else { return }
        // Oldest first, matching what the index expects.
        store.pushScrollback(paneId, lines.reversed())
    }

    /// PRD §7.5's cap.
    private static let scrollbackLines = 200
}

// MARK: - SwiftTerm

/// SwiftTerm's delegate predates strict concurrency; every callback here
/// arrives on the main thread in practice, which `@preconcurrency` lets us say
/// without scattering assumeIsolated through the file.
extension TerminalPaneController: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        attachment?.send(data)
    }

    /// SwiftTerm telling us its view geometry changed.
    ///
    /// Deliberately does **not** forward to Relay. See the class note: the PTY
    /// has one size shared by every client, and a narrow lane must not impose
    /// its own on a phone that is also watching.
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: TerminalView, title: String) {
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        try? store.setLaneTitle(laneId, title)
    }

    /// OSC 7 also arrives here when SwiftTerm parses it, which is a second,
    /// cheaper path to the same answer.
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory else { return }
        let path = URL(string: directory)?.path ?? directory
        guard path != currentCwd else { return }
        currentCwd = path
        reportCwd()
    }

    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        // A clicked link in a terminal is the same gesture as the BROWSER shim:
        // a web pane right of this one.
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        try? store.newWebLane(url: link, near: laneId)
    }

    func bell(source: TerminalView) {}

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

/// The thin banner across the top of a terminal pane when it is not attached.
///
/// PRD §11: "If Relay is unreachable at launch, pty panes render a
/// 'reconnecting' state and retry with backoff; the lane and ordinal are
/// unaffected." The lane is still there, in the right place, with the right tag.
/// Only this strip says otherwise.
@MainActor
final class ReconnectingBanner: NSView {
    enum State {
        case connected
        case reconnecting
        case exited(Int32)
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = Theme.mono(10, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func setState(_ state: State) {
        switch state {
        case .connected:
            isHidden = true
        case .reconnecting:
            isHidden = false
            label.stringValue = "// RECONNECTING"
            label.textColor = Theme.accent
            layer?.backgroundColor = Theme.accent.withAlphaComponent(0.12).cgColor
        case .exited(let code):
            isHidden = false
            label.stringValue = code == 0 ? "// EXITED" : "// EXITED \(code)"
            label.textColor = Theme.dimText
            layer?.backgroundColor = Theme.laneBorder.withAlphaComponent(0.3).cgColor
        }
    }
}
