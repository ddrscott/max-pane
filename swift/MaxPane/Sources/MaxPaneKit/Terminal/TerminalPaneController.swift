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

    /// Send exactly one `RESIZE`. **Only ever called from the user's explicit
    /// "claim this session" command** — see ADR-0007. Nothing automatic may
    /// reach this.
    func claimSize(cols: Int, rows: Int)
}

/// A terminal pane: a SwiftTerm view attached to a RelayTTY session.
///
/// **On resize.** RelayTTY's PTY resize is global last-writer-wins — one PTY,
/// one `winsize`, no per-client viewport. PRD §3 keeps the phone client on the
/// same sessions and §8 makes lanes narrow portrait columns, so a MaxPane column
/// that asserted its own size would reshape the PTY for every other client and
/// force a full TUI redraw on each flip. This pane therefore **never sends
/// RESIZE**: it takes the host's size from the inbound frame and fits the
/// content inside the column.
///
/// Spike M2 measured both sides of that: flipping between a 50-column lane and a
/// 100-column phone forced 6 671 bytes of redraw on every other attached client
/// per flip for `htop`, while a client that never sends RESIZE learned the host
/// size from inbound frames alone and caused zero `SIGWINCH`s.
/// [ADR-0007](../../../../docs/decisions/0007-terminal-panes-never-resize-the-pty.md).
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
    private var isSessionAvailable = true
    /// Lines seen on the wire, so the index survives a `clear`. See pushScrollback.
    private var seenLines: [String] = []
    /// The PTY's size as the host last reported it. Authoritative — never read
    /// this from the session JSON, which lags by seconds (ADR-0007).
    private(set) var hostCols = 80
    private(set) var hostRows = 40

    /// Last cwd seen, for ⌘T spawning a sibling in the right place and for
    /// tagging. Sourced from OSC 7 in the stream, backed by the session file.
    private(set) var currentCwd: String?

    var view: NSView { container }

    init(pane: Pane, store: StripStore, config: Config) {
        self.paneId = pane.id
        self.pane = pane
        self.store = store
        self.config = config
        self.terminal = AutoCopyTerminalView(frame: .zero)
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
            self.rememberLiveLines(bytes)
            self.scheduleScrollbackPush()
        }
        attachment.onHostResize = { [weak self] cols, rows in
            // The host reshaped the PTY — possibly because a phone attached.
            // Follow it; never lead it.
            guard let self else { return }
            self.hostCols = cols
            self.hostRows = rows
            self.terminal.getTerminal().resize(cols: cols, rows: rows)
            self.fitLaneToSession()
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

    /// The session appeared in, or vanished from, RelayTTY's directory.
    ///
    /// Vanishing is not the same as the process exiting: the relay host can be
    /// restarted under us. Either way the lane stays put and the banner
    /// explains itself.
    func sessionAvailabilityChanged(_ available: Bool) {
        guard available != isSessionAvailable else { return }
        isSessionAvailable = available
        if available {
            status.setState(.connected)
            attachment?.connect()
        } else {
            status.setState(.reconnecting)
        }
    }

    // MARK: - fitting the lane to the session (ADR-0007)

    /// Size the lane to the session, not the session to the lane.
    ///
    /// The PTY's width belongs to whoever started it. A lane cannot change it
    /// without reshaping the terminal for every other client, so the lane moves
    /// instead: `clamp(hostCols × cellWidth + gutter, LANE_MIN, LANE_MAX)`.
    ///
    /// M2 measured that this is nearly always enough — real sessions on this
    /// machine run 52 to 73 columns, and at 12 pt (a 7 pt cell) even 128 columns
    /// fits in 896 pt. Shrinking the font is the fallback past that, not the
    /// mechanism.
    private func fitLaneToSession() {
        guard let laneId = store.lane(containing: paneId)?.id else { return }

        let wanted = Self.laneWidth(forCols: hostCols, cellWidth: cellWidth(at: config.fontSize))
        let clamped = config.clampWidth(wanted)

        if wanted > config.widthRange.upperBound {
            // Wider than any lane may be: shrink the font until it fits, down to
            // the floor, then stop and let the user scroll the rest.
            let available = Double(config.widthRange.upperBound) - Self.gutter
            var size = config.fontSize
            while size > Self.minimumFontSize,
                  Double(hostCols) * cellWidth(at: size) > available {
                size -= 1
            }
            applyFontSize(max(size, Self.minimumFontSize))
        } else if terminal.font.pointSize != config.fontSize {
            // Back inside the range: return to the configured size.
            applyFontSize(config.fontSize)
        }

        guard store.lane(laneId)?.widthPt != clamped else { return }
        // Animated, because a phone can move this under the user and a column
        // that jumps without explanation reads as a glitch.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            try? store.setLaneWidth(laneId, clamped)
        }
    }

    /// Points of lane needed for `cols` columns at a given cell width.
    static func laneWidth(forCols cols: Int, cellWidth: Double) -> UInt32 {
        UInt32(max(0, (Double(cols) * cellWidth + gutter).rounded(.up)))
    }

    /// Lane chrome either side of the terminal grid.
    static let gutter: Double = 16
    /// Below this the text stops being readable, so clip instead of shrinking.
    static let minimumFontSize: Double = 9

    private func cellWidth(at size: Double) -> Double {
        let font = NSFont(name: config.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = Double(font.advancement(forGlyph: font.glyph(withName: "space") ?? 0).width)
        // A font that reports nothing useful still has to produce a cell width;
        // 0.6em is the usual monospace ratio.
        return advance > 0 ? advance.rounded() : size * 0.6
    }

    private func applyFontSize(_ size: Double) {
        guard terminal.font.pointSize != size else { return }
        terminal.font = NSFont(name: config.fontName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The user's explicit "this session is mine at this width" (ADR-0007 §5).
    ///
    /// The **only** path that sends `RESIZE`. It reshapes the PTY for every
    /// other attached client, including Scott's phone, which is why it is a
    /// command and never a side effect.
    func claimSessionAtLaneWidth() {
        guard let lane = store.lane(containing: paneId) else { return }
        let available = Double(lane.widthPt) - Self.gutter
        let cols = max(20, Int(available / cellWidth(at: config.fontSize)))
        let rows = max(10, Int((terminal.bounds.height - Theme.laneHeaderHeight) / terminal.font.boundingRectForFont.height))
        attachment?.claimSize(cols: cols, rows: rows)
    }

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
        // Walk back from the bottom of the scrollback, taking only the lines we
        // keep. `getScrollInvariantLine` indexes from the start of the scroll
        // buffer including what has already been trimmed off the top, so the
        // last real row is `totalLinesTrimmed + topVisibleRow + rows - 1`.
        //
        // All public API, and M2 measured the whole 200-line walk at 0.48 ms.
        // `getBufferAsData()` would materialise the entire buffer — megabytes of
        // allocation, for 20 terminals, to keep 200 lines.
        let term = terminal.getTerminal()
        var row = term.buffer.totalLinesTrimmed + term.getTopVisibleRow() + term.rows - 1

        var lines: [String] = []
        lines.reserveCapacity(Self.scrollbackLines)
        while row >= 0, lines.count < Self.scrollbackLines {
            guard let line = term.getScrollInvariantLine(row: row) else { break }
            let text = Self.text(of: line, cols: term.cols, in: term)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(text)
            }
            row -= 1
        }
        // A fresh attach does not reliably fill the buffer: M2 saw 125 lines on
        // a real session, because a full replay is truncated at the last
        // `ESC[2J` and everything before the clear is simply gone. So the index
        // also gets fed from live output as it arrives, and the two are merged
        // newest-last here.
        let merged = mergeWithSeenLines(lines.reversed())
        guard !merged.isEmpty else { return }
        store.pushScrollback(paneId, merged)
    }

    /// One buffer line as text.
    ///
    /// Per-cell rather than `BufferLine.translateToString`, which **silently
    /// drops astral-plane scalars** — emoji and flags come back as blanks. M2
    /// measured both paths at the same cost (0.474 vs 0.483 ms for 200 lines),
    /// so there is nothing to trade off, and agent output is full of emoji.
    private static func text(of line: BufferLine, cols: Int, in term: Terminal) -> String {
        var out = ""
        out.reserveCapacity(cols)
        for col in 0..<min(cols, line.count) {
            let cd = line[col]
            if cd.width == 0 { continue }
            out.append(term.getCharacter(for: cd))
        }
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Lines seen on the live stream, so the index survives a `clear`.
    ///
    /// Capped at the same 200: this is a way to find a lane, not a log.
    private func rememberLiveLines(_ bytes: ArraySlice<UInt8>) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Self.stripEscapes(String(raw))
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            seenLines.append(line)
        }
        if seenLines.count > Self.scrollbackLines {
            seenLines.removeFirst(seenLines.count - Self.scrollbackLines)
        }
    }

    /// Whatever is in the emulator's buffer, plus anything the live stream saw
    /// that the buffer no longer holds. Newest last, capped.
    private func mergeWithSeenLines(_ fromBuffer: [String]) -> [String] {
        guard !seenLines.isEmpty else { return fromBuffer }
        let known = Set(fromBuffer)
        var merged = seenLines.filter { !known.contains($0) }
        merged.append(contentsOf: fromBuffer)
        if merged.count > Self.scrollbackLines {
            merged.removeFirst(merged.count - Self.scrollbackLines)
        }
        return merged
    }

    /// Drop CSI/OSC escape sequences so the index holds text rather than
    /// formatting. Deliberately crude — it only has to be good enough to search.
    static func stripEscapes(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var iterator = s.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            guard c == "\u{1b}" else {
                if c != "\r" { out.append(c) }
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                // CSI: parameters, then a final byte in @-~.
                while let p = iterator.next() {
                    if ("@"..."~").contains(p) { break }
                }
            } else if next == "]" {
                // OSC: runs to BEL, or to ST (ESC \). The backslash is part of
                // the terminator and must be consumed, not emitted.
                while let p = iterator.next() {
                    if p == "\u{07}" { break }
                    if p == "\u{1b}" {
                        let after = iterator.next()
                        if after != "\\" { pending = after }
                        break
                    }
                }
            }
        }
        return out
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
    /// OSC 52 — the terminal asking for something to be put on the clipboard.
    ///
    /// Agents use this to hand you a command or a path without you selecting it.
    /// Dropping it on the floor, which is what an empty implementation does,
    /// looks exactly like the feature not existing.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
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

/// A `TerminalView` that copies the selection the moment you finish making one.
///
/// RelayTTY does this, and it is the reason a daily user of it has never pressed
/// ⌘C in a terminal: you drag over a stack trace and it is already on the
/// clipboard. Without it the gesture silently does nothing, which reads as the
/// selection not having worked at all.
final class AutoCopyTerminalView: TerminalView {
    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // `getSelection` is nil unless a selection is actually active, so an
        // ordinary click into a pane never clobbers the clipboard.
        guard let selected = getSelection(), !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
    }
}
