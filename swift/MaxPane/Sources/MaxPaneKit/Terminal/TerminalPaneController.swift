import AppKit
import RelayClient
import GhosttyTerminal
import LanedCore

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
    /// The PTY's size as the host reports it.
    var onHostResize: ((_ cols: Int, _ rows: Int) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    /// `false` while reconnecting, which the pane renders rather than hides.
    var onConnectionChange: ((Bool) -> Void)? { get set }
    /// The attachment has given up: the server refused the credential, or
    /// is not one this launch knows. One line for the pane, naming which.
    var onRefused: ((String) -> Void)? { get set }
    /// Clear the emulator before the next bytes: what follows is the whole
    /// scrollback again, not a continuation of it.
    var onReplaceScreen: (() -> Void)? { get set }
    /// Input held while the wire was down was dropped, not sent: how many
    /// bytes. Only the real adapter holds input, so only it calls this.
    var onInputDropped: ((Int) -> Void)? { get set }
    /// Text the session wants on the clipboard: relay's CLIPBOARD frame, which
    /// is how an OSC 52 write arrives from pty-host (ADR-0028).
    var onClipboard: ((String) -> Void)? { get set }

    /// The session's server stopped answering, or started again. A local
    /// attachment has no server and never hears this.
    func serverStateChanged(_ state: ServerState)

    func connect()
    func disconnect()
    func send(_ bytes: ArraySlice<UInt8>)
    /// Paste Slowly: `bytes` in the same queue as everything else, in small
    /// pieces with a longer gap (`PacedInput.enqueue(_:pace:)`). `report`
    /// hears how it goes and, last, that it finished or was cancelled.
    func send(_ bytes: ArraySlice<UInt8>, pace: PacedInput.Pace, report: @escaping (PacedInput.SlowEvent) -> Void)
    /// Stop a slow send: what has not gone never goes.
    func cancelSlowSend()

    /// Reshape the PTY. This changes the terminal for **every** client attached
    /// to the session, the phone included, which is why it is debounced to the
    /// size the user settles on. See ADR-0007.
    func claimSize(cols: Int, rows: Int)
}

extension RelayAttachment {
    var onInputDropped: ((Int) -> Void)? { get { nil } set {} }
    var onClipboard: ((String) -> Void)? { get { nil } set {} }
    func serverStateChanged(_ state: ServerState) {}
    /// An attachment with no pacing of its own has nothing to slow down.
    func send(_ bytes: ArraySlice<UInt8>, pace: PacedInput.Pace, report: @escaping (PacedInput.SlowEvent) -> Void) {
        send(bytes)
        report(.finished(bytes.count))
    }
    func cancelSlowSend() {}
}

/// A terminal pane: Ghostty's terminal core attached to a RelayTTY session.
///
/// Ghostty owns the grid. The view's size decides the columns and rows, the
/// session reports when that changed, and we pass the new shape to Relay — so
/// dragging a lane wider genuinely reflows the text. Inbound `RESIZE` is
/// therefore informational: another client may reshape the PTY, and the
/// terminal renders at that size inside the lane the user chose.
///
/// pty panes are never unparented and never evicted (PRD §10.3): the emulator
/// is cheap, and the attachment is what holds the session's continuity.
@MainActor
final class TerminalPaneController: NSObject, PaneController {
    let paneId: String
    private let store: StripStore
    private let config: Config
    private let container = TerminalPaneContainer()
    /// Focus was asked for while the pane had no window to give it.
    private var wantsFocus = false
    /// What Ghostty's surface was last told about focus. A surface is born
    /// believing it is focused, so that is what a new one resets this to.
    private var surfaceFocused = true
    /// Whether a window counts as holding the keyboard. A test's window is
    /// never key, and ordering one front would take the owner's screen.
    var windowIsKey: (NSWindow) -> Bool = { $0.isKeyWindow }
    /// The grid as Ghostty last measured it, for turning a click into a cell.
    private var grid: (columns: Int, rows: Int)?

    /// The terminal's inset inside its pane, matching the lane's own gutter.
    /// Shared with the controller's config: if the two drift, ⌘-click lands on
    /// the wrong cell by however far they disagree.
    static let terminalPadding = CGPoint(x: 6, y: 4)

    /// The terminal size a *new* session should start at.
    ///
    /// ADR-0007 says Max Pane never resizes a session, because the PTY's size is
    /// shared by every client including Scott's phone. It says nothing about the
    /// size a session is *born* at — at that instant we are the only client, and
    /// choosing it is not taking it from anyone.
    ///
    /// Getting this wrong is very visible: a session born at 80×40 in a lane
    /// that can show 60 rows leaves a third of the column black forever, and
    /// ADR-0007 then forbids us from fixing it.
    ///
    /// `viewHeight` is the caller's own, because there are now two callers —
    /// the window controller's ⌘N and the strip's ⌘-click-to-edit — and two
    /// copies of this arithmetic would drift the moment one of them was tuned.
    static func newSessionSize(config: Config, viewHeight: CGFloat) -> (cols: Int, rows: Int) {
        let font = NSFont(name: config.fontName, size: config.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: config.fontSize, weight: .regular)

        // Match SwiftTerm's own cell metric rather than approximating it.
        // `AppleTerminalView.computeFontDimensions` uses
        // `ceil(ascent + descent + leading)`; `boundingRectForFont.height` is
        // several points taller, and guessing high leaves a band of dead black
        // at the bottom of every terminal lane that ADR-0007 then forbids
        // fixing.
        let ctFont = font as CTFont
        let cellHeight = ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont))
        let advance = Double(font.advancement(forGlyph: font.glyph(withName: "space") ?? 0).width)
        let cellWidth = advance > 0 ? advance.rounded() : config.fontSize * 0.6

        let laneWidth = Double(config.laneDefaultPt) - 16
        let usableHeight = Double(viewHeight) - Double(Theme.laneHeaderHeight)

        let cols = max(40, Int(laneWidth / max(cellWidth, 1)))
        // Fall back to something sane before the strip has been laid out.
        let rows = usableHeight > 100 ? max(20, Int(usableHeight / max(cellHeight, 1))) : 40
        return (cols, rows)
    }
    private let terminal = ClickableTerminalView(frame: .zero)
    private let status = ReconnectingBanner()

    /// Ghostty's side of the pipe: bytes in from Relay, bytes out from the
    /// keyboard, and a resize whenever the view's grid changes.
    private var session: InMemoryTerminalSession!
    /// Everything leaving this pane, in one ordered queue. See `TerminalOutbound`.
    private var outbound: TerminalOutbound!
    private var attachment: RelayAttachment?
    private var pane: Pane
    private var scrollbackDebounce: DispatchWorkItem?
    private var isSessionAvailable = true
    /// True between `beginLiveResize` and `endLiveResize`. See those.
    private var isLiveResizing = false

    /// Lines seen on the wire, so the search index survives a `clear` and can
    /// see past the viewport — Ghostty's viewport read deliberately ignores
    /// scrollback.
    private var seenLines: [String] = []

    /// The grid as Ghostty last reported it.
    private(set) var hostCols = 80
    private(set) var hostRows = 40

    /// Last cwd seen. Ghostty reports OSC 7 natively, so this is no longer
    /// sniffed out of the byte stream by hand.
    private(set) var currentCwd: String?

    /// A ⌘-click found something worth opening. The strip decides what kind of
    /// lane it lands in — this pane knows the grid and the cwd and nothing at
    /// all about editors. See `FileOpen`.
    var onOpenToken: ((TerminalToken) -> Void)?
    /// The session ended, with this exit status. The strip takes the pane away.
    var onSessionExit: ((Int32) -> Void)?

    var view: NSView { container }

    /// `controller` is the shared one unless a test hands in its own — see
    /// `TerminalControllerPool.makeController`.
    init(pane: Pane, store: StripStore, config: Config, controller: TerminalController? = nil) {
        self.paneId = pane.id
        self.pane = pane
        self.store = store
        self.config = config
        super.init()

        // Ghostty's own tracing, behind the same flag as ours. Its lifecycle
        // and metrics categories are the only way to see why a surface did not
        // build, which is otherwise entirely silent.
        if ProcessInfo.processInfo.environment["MAXPANE_DEBUG"] != nil, !TerminalDebugLog.isEnabled {
            // Its default sink is `print`, and stdout to a file is block
            // buffered — so the output simply never appears. stderr is not.
            TerminalDebugLog.sink = { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            }
            // `.input` traces every byte crossing the surface boundary, in
            // both directions. It is how the bracketed-paste framing was
            // pinned down — `host <- terminal … \e[200~` is the whole bug in
            // one line — and it is the first thing to turn on for anything
            // about keys or paste. Behind its own flag rather than MAXPANE_DEBUG
            // because it prints what the user typed, passwords included.
            var categories: TerminalDebugCategory = [.lifecycle, .metrics]
            if ProcessInfo.processInfo.environment["MAXPANE_DEBUG_INPUT"] != nil {
                categories.insert(.input)
            }
            TerminalDebugLog.enable(categories)
        }

        container.wantsLayer = true
        container.layerBackgroundColor = Theme.laneBackground
        // Ghostty derives its grid from the view's size and only builds its
        // surface once it has one. Without a nudge on every layout pass the
        // pane renders nothing at all while bytes arrive perfectly happily —
        // which is exactly how this first came up: a header reading 254B/s
        // above an empty black column.
        container.onLayout = { [weak self] in
            self?.fitTerminal()
            // Ghostty swaps its own layer for an IOSurface layer once it has
            // rendered, and a filter set on the old one goes with it.
            self?.applyMinificationFilter()
        }
        container.onAttach = { [weak self] in
            self?.applyPendingFocus()
            // Leaving a window told the surface it lost focus; coming back
            // tells it nothing. Under `always` that is a still cursor.
            self?.syncSurfaceFocus()
            // A recycled lane view brings a fresh surface, at the config's font
            // size — so a zoomed pane scrolled off the strip and back would
            // come back the wrong size without this.
            self?.applyZoom()
        }
        terminal.onCommandClick = { [weak self] point in self?.openToken(at: point) }
        terminal.onMiddleClick = { [weak self] forced in self?.middleClick(forced: forced) ?? true }
        container.onPaste = { [weak self] in self?.pasteFromClipboard() }
        container.onPasteWithoutAsking = { [weak self] in self?.pasteFromClipboard(asking: false) }
        container.onPasteSpecial = { [weak self] special in self?.pasteSpecial(special) }
        terminal.onKeyDown = { [weak self] event in self?.keyDuringSlowPaste(event) ?? false }
        container.onDropFiles = { [weak self] pasteboard in self?.dropFiles(from: pasteboard) ?? false }

        let outbound = TerminalOutbound { [weak self] bytes in
            self?.attachment?.send(bytes[...])
        }
        self.outbound = outbound

        session = InMemoryTerminalSession(
            write: { [outbound] data in
                // Keyboard, mouse reports and device replies, on their way to
                // the PTY. Queued rather than sent: this callback arrives on
                // whichever thread Ghostty was parsing on, and the order it
                // arrives in is the only order the far end can be told about.
                outbound.enqueue(data)
            },
            resize: { [weak self] viewport in
                Task { @MainActor in
                    self?.grid = (Int(viewport.columns), Int(viewport.rows))
                    self?.gridChanged(cols: Int(viewport.columns), rows: Int(viewport.rows))
                }
            },
            // We only read columns and rows, so a pixel-only change during a
            // divider drag is noise — and each one would ask the far end for a
            // full repaint.
            suppressesPixelOnlyResizes: true)

        // The controller carries the font and palette, and is what actually
        // mints a surface. Ghostty refuses to build one without it — silently,
        // logging only "surface rebuild skipped: missing controller", which is
        // how this cost an hour of looking at a black column while the header
        // happily reported 254 B/s arriving.
        // A pane you made bigger stays bigger: the ledger carries it, so it
        // survives a relaunch and a lane view being recycled alike.
        zoom = pane.zoom
        terminal.controller = controller ?? TerminalControllerPool.shared.controller(for: config)
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.delegate = self
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.setAccessibilityElement(true)
        terminal.setAccessibilityLabel("Terminal")
        container.addSubview(terminal)

        status.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(status)
        terminalEdges = [
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(terminalEdges)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            status.topAnchor.constraint(equalTo: container.topAnchor),
            status.heightAnchor.constraint(equalToConstant: 22),
        ])
        status.isHidden = true

        // Seed cwd from the session file so a restored lane is tagged before a
        // single byte has arrived. A remote session has no file here; its
        // cwd arrives from the server's list (`adoptRemoteCwd`).
        if let sessionId = pane.relaySessionId, pane.relayServer == nil {
            currentCwd = RelaySessionDirectory().session(sessionId)?.cwd
            reportCwd()
        }
    }

    /// The cwd a remote server reports for this pane's session, from the
    /// registry. The remote shell sends no OSC 7 unless configured to
    /// (spike M7 §5), so this is the whole of how a remote lane gets its
    /// `host:path` tag.
    func adoptRemoteCwd(_ cwd: String) {
        guard !cwd.isEmpty, cwd != currentCwd else { return }
        currentCwd = cwd
        reportCwd()
    }

    /// One line in the banner, briefly: what could not be done, and why.
    ///
    /// `lasting: nil` stays until the next notice replaces it: an upload in
    /// progress is said for as long as it is true.
    ///
    /// A notice that replaces a notice with `fading: false` changes its words
    /// in place: a count going up is one line being kept true, not a hundred
    /// lines arriving, and a fade per step would be a flicker.
    func showNotice(_ text: String, lasting seconds: TimeInterval? = 3, fading: Bool = true) {
        let wasNotice = noticeText != nil
        status.isHidden = false
        status.setState(.notice(text))
        if fading || !wasNotice { Motion.fade(status.layer) }
        noticeTimer?.invalidate()
        noticeTimer = nil
        guard let seconds else { return }
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, case .notice = self.status.state else { return }
                Motion.fade(self.status.layer)
                self.status.setState(self.restingBanner)
            }
        }
    }
    private var noticeTimer: Timer?
    /// The notice on show, if one is: what a test reads.
    var noticeText: String? {
        if case .notice(let text) = status.state { return text }
        return nil
    }

    /// How this pane's server is doing, as its session list has it; nil for
    /// a local pane and for a server that is answering. Laid over the
    /// attachment's own report, so every lane on a dead server says so the
    /// moment the sidebar does, whatever its own socket still believes
    /// (ADR-0023).
    private var serverOff: ServerState?
    /// Whether the attachment last reported its wire up.
    private var isWireUp = true

    /// What the banner says when nothing sticky (an exit, a refusal, a
    /// notice) is on it.
    private var restingBanner: ReconnectingBanner.State {
        if let serverOff { return .offline(serverOff) }
        return (isWireUp && isSessionAvailable) ? .connected : .reconnecting
    }

    /// The server's state, from the registry by way of the strip. The
    /// attachment is told as well: it tests its own wire now rather than in
    /// 45 s, and reconnects now when the server is back.
    func serverStateChanged(_ state: ServerState) {
        let off: ServerState? = state.isOff ? state : nil
        guard off != serverOff else { return }
        serverOff = off
        attachment?.serverStateChanged(state)
        switch status.state {
        case .exited, .refused, .notice: return
        case .connected, .reconnecting, .offline: break
        }
        Motion.fade(status.layer)
        status.setState(restingBanner)
    }

    /// Attach to the live session. Separate from `init` so a lane can exist —
    /// with its ordinal, its tag and its place on the strip — while Relay is
    /// unreachable (PRD §11, §15.8).
    func attach(_ attachment: RelayAttachment) {
        self.attachment = attachment

        attachment.onData = { [weak self] bytes in
            guard let self else { return }
            self.session.receive(Data(bytes))
            self.rememberLiveLines(bytes)
            self.scheduleScrollbackPush()
        }
        attachment.onHostResize = { [weak self] cols, rows in
            // Informational. Ghostty's grid comes from the view, and deriving
            // it back from the PTY would fight the user's lane width on every
            // frame. Recorded so the header can show the real shape.
            self?.hostCols = cols
            self?.hostRows = rows
            self?.claimedSize = (cols, rows)
        }
        attachment.onTitle = { [weak self] title in
            self?.adoptTitle(title)
        }
        attachment.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            // A refusal is final and outlives every later disconnect report.
            self.isWireUp = connected
            if case .refused = self.status.state { return }
            self.status.setState(self.restingBanner)
        }
        attachment.onInputDropped = { [weak self] count in
            // Said, not swallowed: the pane looked alive while these were
            // typed. Old input is dropped on purpose (`PendingInput`).
            self?.showNotice("\(count) byte\(count == 1 ? "" : "s") typed while disconnected \(count == 1 ? "was" : "were") not sent")
        }
        attachment.onClipboard = { [weak self] text in self?.programSetClipboard(text) }
        attachment.onRefused = { [weak self] why in
            self?.status.isHidden = false
            self?.status.setState(.refused(why))
        }
        attachment.onReplaceScreen = { [weak self] in
            // Home, clear the screen, clear the scrollback, then a full reset:
            // the ring that follows is the whole screen again.
            self?.session.receive(Data("\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}c".utf8))
        }
        attachment.onExit = { [weak self] code in
            // Deliberately not `session.finish(...)`. That hands the exit to
            // Ghostty, which paints its own end-of-process screen over the
            // pane: "Ghostty failed to launch the requested command … Press
            // any key to close the window." Both halves are untrue here — the
            // command ran, Relay launched it, and no key closes anything — and
            // it lands on top of the output the exit is about. The lane's own
            // EXITED chip says the same thing in this app's vocabulary, and
            // leaving the surface alive keeps the scrollback readable.
            self?.status.isHidden = false
            self?.status.setState(.exited(code))
            self?.onSessionExit?(code)
        }
        attachment.connect()
    }

    // MARK: - PaneController

    func apply(_ pane: Pane) { self.pane = pane }

    /// Give this pane the keyboard.
    ///
    /// A pane is routinely asked for focus before it is in a window — a lane
    /// created by `maxpane run` is focused in the ledger the moment it exists,
    /// which is a run loop or two before it is on screen. `makeFirstResponder`
    /// just fails then, and since the strip only asks once, the pane comes up
    /// drawn, attached, and deaf. So remember the want and honour it on attach.
    func takeFocus() {
        wantsFocus = true
        applyPendingFocus()
    }

    /// Take the keyboard if it is owed to this pane.
    ///
    /// Two callers, and the second is the one that was missing. A view that
    /// leaves the view hierarchy stops being first responder — AppKit hands
    /// that back to the window — and the strip reparents pane views as a
    /// matter of course: a new lane materialising, a lane view recycled on
    /// scroll, a split reconciling. `takeFocus` used to clear its flag on the
    /// first success, so a pane focused and *then* reparented came back with
    /// the accent border, a live cursor, and no keyboard at all. Every
    /// keystroke and every ⌘V went to the window and stopped there, which is
    /// exactly the "freshly created lane where paste does nothing" report.
    ///
    /// Re-asserting is safe because of the two guards: the keyboard has to be
    /// unclaimed — after a reparent the window holds it precisely because
    /// nothing else does — and the ledger, not a local flag, has to say this
    /// pane is the focused one. A palette, a search field or the pane the user
    /// has since moved to keeps what it has.
    private func applyPendingFocus() {
        guard let window = container.window else { return }
        let unclaimed = window.firstResponder === window
        guard wantsFocus || (unclaimed && store.state.focusedPaneId == paneId) else { return }
        // A paste that is still a question holds the keyboard for this pane:
        // handing it to the terminal would let typing through under the sheet.
        // A question from a program holds it the same way.
        if let sheet: NSView = pasteSheet ?? clipboardSheet {
            if window.firstResponder !== sheet, window.makeFirstResponder(sheet) { wantsFocus = false }
            return
        }
        guard window.firstResponder !== terminal else {
            wantsFocus = false
            return
        }
        if window.makeFirstResponder(terminal) { wantsFocus = false }
    }

    /// Make the surface's idea of focus the true one: it is focused when its
    /// view is first responder in the key window, and not otherwise.
    ///
    /// First responder is the truth here, not the ledger's focused pane,
    /// because the cursor has to agree with where the keys go: with the ⌘O
    /// picker or a find bar holding the keyboard, the ledger still names this
    /// pane and nothing should blink. The library keeps that up on its own
    /// once a view has been first responder. What it never does is tell a
    /// surface its state at *birth*, and Ghostty's surfaces are born focused,
    /// so every terminal that had not yet held the keyboard blinked: each
    /// restored lane, each gallery tile. It also reports focus to a view made
    /// first responder in a window that is not key. Both are corrected here,
    /// from the three places the answer can change: a surface being built,
    /// the library reporting a focus change, and the view entering a window.
    ///
    /// `cursor_blink = "always"` keeps every surface told it is focused,
    /// which is what makes them all blink. Ghostty owns the blink itself.
    private func syncSurfaceFocus() {
        guard let window = container.window else { return }
        let ownsKeyboard = windowIsKey(window) && window.firstResponder === terminal
        let want = config.cursorBlink == .always || ownsKeyboard
        guard want != surfaceFocused else { return }
        terminal.tellSurface(focused: want)
    }

    func tearDown() {
        scrollbackDebounce?.cancel()
        // A paste still waiting on its question goes with the pane, unsent.
        pasteSheet?.dismissWithoutAnswering()
        pasteSheet = nil
        // And a program still waiting on the clipboard is told no.
        clipboardSheet?.dismissWithoutAnswering()
        clipboardSheet = nil
        clipboardAnswer?(false)
        clipboardAnswer = nil
        attachment?.disconnect()
        attachment = nil
    }

    /// The pane's server changed under it — added, removed, renamed, or
    /// given a new token in Settings — so the attachment it holds is for an
    /// endpoint that no longer exists. Drop it and attach through the new
    /// one. A refusal is final for an attachment, not for the pane: the
    /// banner is reset so the new attachment can report its own state, and
    /// a server that is now gone says so through its own transport.
    func reattach(_ attachment: RelayAttachment) {
        self.attachment?.disconnect()
        self.attachment = nil
        Motion.fade(status.layer)
        isWireUp = false
        status.setState(restingBanner)
        attach(attachment)
    }

    /// The session this pane is attached to, for the strip to find every
    /// pane on one server.
    var sessionKey: SessionKey? { pane.sessionKey }

    // MARK: - clipboard

    /// ⌘V, arriving from the Edit menu by way of the pane's container view.
    ///
    /// Deliberately not Ghostty's `paste:`. That one asks the local emulator to
    /// paste, and the local emulator decides the framing from what it believes
    /// the far end's modes to be — a belief that is a guess about a program on
    /// the other end of a socket. `TerminalPaste` makes the framing something
    /// this app knows rather than something it infers.
    ///
    /// The bytes go through the session, not straight at the attachment, so a
    /// paste and the keystrokes on either side of it are one stream in one
    /// order rather than two racing ones.
    func pasteFromClipboard(asking: Bool = true) {
        let images = TerminalPaste.ImageSettings(liveConfig?() ?? config)
        paste(TerminalPaste.clipboard(pasteboard, images: images.asFiles), asking: asking)
    }

    /// A middle click pastes: this pane's selection if it has one, else the
    /// clipboard, through the same door as ⌘V. False only when the click is
    /// the program's, and then it goes down to the emulator
    /// (`TerminalPaste.middleClick` has the rules). A click on a URL or a
    /// path pastes like any other; opening is ⌘-click's.
    ///
    /// The selection is read from the surface (`ghostty_surface_read_selection`),
    /// never by copying it to a pasteboard and reading it back: a middle click
    /// leaves the clipboard exactly as it was.
    @discardableResult
    func middleClick(forced: Bool) -> Bool {
        let live = liveConfig?() ?? config
        let route = TerminalPaste.middleClick(
            enabled: live.middleClickPaste,
            inTile: isUnexpandedTile,
            mouseCaptured: mouseCapturedSource?() ?? terminal.isMouseCaptured,
            forced: forced,
            selection: selectionSource?() ?? surface?.readSelection())
        let clipboard: TerminalPaste.Clipboard
        switch route {
        case .program: return false
        case .ignored: return true
        case .selection(let text): clipboard = TerminalPaste.Clipboard(text: text, isCopiedText: true)
        case .clipboard:
            clipboard = TerminalPaste.clipboard(pasteboard, images: TerminalPaste.ImageSettings(live).asFiles)
        }
        // The keyboard follows the paste, as it does a drop: the next thing
        // typed is Return, and it belongs where the text went.
        try? store.focusPane(paneId)
        takeFocus()
        paste(clipboard)
        return true
    }

    /// The surface, for the one thing the view does not pass on: reading the
    /// selection. Weak, and dropped when the library says it is gone.
    private weak var surface: TerminalSurface?

    /// Test seams: what the surface would have said.
    var selectionSource: (() -> String?)?
    var mouseCapturedSource: (() -> Bool)?

    /// A gallery tile that has not been expanded. Set by `setThumbnail`.
    private(set) var isUnexpandedTile = false

    /// Where ⌘V reads from. The general pasteboard, except in a test, which
    /// hands in one of its own and leaves the owner's clipboard alone.
    var pasteboard: NSPasteboard = .general

    /// The config as it is now, for the settings a paste reads each time
    /// (`paste_confirm_*`); the pane's own `config` is the one it was built
    /// with. Set by the strip; nil in a test, which gets the built-with one.
    var liveConfig: (() -> Config)?

    /// The question a paste is waiting on, while it is. One at a time.
    private(set) var pasteSheet: PasteAskSheet?

    /// The one door a paste goes through, whatever it came from.
    ///
    /// A paste that would press Return in the middle, ask a shell for
    /// completion, or is simply enormous asks first, in a sheet over this pane
    /// (ADR-0026). `asking: false` is ⌥⌘V, Paste Without Asking: the
    /// clipboard as it was copied, the question skipped this once.
    ///
    /// **Tidy first, then decide whether to ask** (ADR-0029): copied text has
    /// its smart punctuation straightened, a copied prompt removed and stray
    /// whitespace trimmed (`TerminalPaste.tidy`), the question is asked of
    /// what is left, and the sheet shows what is left. Paths made from files
    /// and pictures are not text and are never tidied. ⌥⌘V skips this too: it
    /// is the way to get exactly what was copied.
    func paste(_ clipboard: TerminalPaste.Clipboard, asking: Bool = true, slowly: Bool = false) {
        // A second paste while the first is still a question is not queued
        // behind it and does not answer it: the sheet is what has the floor.
        guard pasteSheet == nil, clipboardSheet == nil else { return }
        // A copied file whose name holds a control character is left out, and
        // the rest still go: say which, in the line the pane already has.
        if let notice = clipboard.notice { showNotice(notice) }
        guard let copied = clipboard.text else {
            if let image = clipboard.image { paste(image: image) }
            return
        }
        let live = liveConfig?() ?? config
        let settings = TerminalPaste.ConfirmSettings(live)
        var text = copied
        var tidied: String?
        if asking, clipboard.isCopiedText, live.pasteTidy {
            let tidy = TerminalPaste.tidy(text)
            text = tidy.text
            tidied = tidy.summary
        }
        if asking, TerminalPaste.asksFirst(text, settings) {
            ask(about: text, settings, tidied: tidied, slowly: slowly)
        } else {
            send(pasted: text, tidied: tidied, slowly: slowly)
        }
    }

    /// Put `text` on the wire as a paste: line endings as Return, no trailing
    /// one, no markers (`TerminalPaste`). Through the session, so it and the
    /// keystrokes either side of it are one stream; the adapter cuts that
    /// stream into paced pieces (`PacedInput`).
    ///
    /// `tidied` is what tidying did, when it did anything: the pane says so in
    /// its notice line as the bytes go, never before and never for nothing.
    private func send(pasted text: String, tidied: String? = nil, slowly: Bool = false) {
        let bytes = TerminalPaste.bytes(for: text)
        guard !bytes.isEmpty else { return }
        if slowly {
            send(slowly: bytes)
            return
        }
        if let tidied { showNotice("pasted · \(tidied)", lasting: 5) }
        // A paste long enough to be watched going in says so, so the wait is
        // not mistaken for a hang. What is typed meanwhile follows it.
        let seconds = Double(bytes.count) / Double(InputChunks.limit) * Self.secondsPerPiece
        if seconds >= 1 {
            let tidy = tidied.map { " · \($0)" } ?? ""
            showNotice("pasting \(TerminalPaste.size(bytes.count)), about \(Int(seconds.rounded())) s\(tidy)", lasting: 5)
        }
        session.sendInput(Data(bytes))
    }

    // MARK: paste special

    /// Edit › Paste Special. Each transform is a pure function in
    /// `TerminalPaste`; this is only which one, and which door.
    func pasteSpecial(_ special: TerminalPaste.Special) {
        guard pasteSheet == nil, clipboardSheet == nil else { return }
        let live = liveConfig?() ?? config
        switch special {
        case .slowly:
            // The same bytes as ⌘V, by the same door: tidied, asked about,
            // a screenshot as its path. Only the pace differs.
            guard !isPastingSlowly else { return }
            paste(TerminalPaste.clipboard(pasteboard, images: TerminalPaste.ImageSettings(live).asFiles), slowly: true)
        case .fileAsBase64:
            pasteFilesAsBase64()
        case .escaped, .base64, .base64Decoded:
            // The clipboard as ⌘V would read it, a copied file being its path.
            // A picture has no text to transform.
            guard let text = TerminalPaste.clipboard(pasteboard, images: false).text else {
                showNotice("not pasted: no text on the clipboard")
                return
            }
            switch special {
            case .escaped:
                // One quoted word, so nothing in it presses Return at a
                // prompt that will act on it: never tidied, never asked.
                if let word = TerminalPaste.escaped(text) { send(pasted: word) }
            case .base64:
                paste(TerminalPaste.Clipboard(text: TerminalPaste.base64Encoded(text)))
            default:
                switch TerminalPaste.base64Decoded(text) {
                // What comes out is anybody's text: by the door, so several
                // lines of it ask first. Not tidied; it is not a copy.
                case .success(let decoded): paste(TerminalPaste.Clipboard(text: decoded))
                case .failure(let refusal): showNotice(refusal.notice)
                }
            }
        }
    }

    /// How Paste File as Base64… asks which files, when the clipboard has
    /// none. An open panel; a test puts its own here and never sees one.
    var chooseFiles: (_ over: NSWindow?, _ chosen: @escaping ([URL]) -> Void) -> Void = { window, chosen in
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Paste"
        panel.message = "Paste as a base64 heredoc, up to 5 MB."
        let done: (NSApplication.ModalResponse) -> Void = { chosen($0 == .OK ? panel.urls : []) }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// The files copied in Finder, if there are any; otherwise ask.
    private func pasteFilesAsBase64() {
        let copied = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL] ?? [])
            .map { URL(fileURLWithPath: TerminalPaste.filePath(of: $0)) }
        guard copied.isEmpty else {
            pasteAsBase64(files: copied)
            return
        }
        chooseFiles(container.window) { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            self.pasteAsBase64(files: urls)
            // The panel had the keyboard; the Return that runs this is next.
            self.takeFocus()
        }
    }

    /// Each file as a heredoc that writes it, by name, into whatever directory
    /// the far shell is in. Several are several heredocs, each but the last
    /// ended by Return, as it has to be for the next to start. **The last has
    /// none**, so the prompt holds `EOF` and the owner presses Return.
    func pasteAsBase64(files: [URL]) {
        var total = 0
        var heredocs: [String] = []
        for url in files {
            let name = url.lastPathComponent
            // Sized before it is read: a 4 GB mistake is refused, not loaded.
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                showNotice("not pasted: \(name) is a folder")
                return
            }
            total += values?.fileSize ?? 0
            if let refusal = TerminalPaste.fileRefusal(bytes: total) {
                showNotice(refusal.notice)
                return
            }
            guard let data = try? Data(contentsOf: url) else {
                showNotice("not pasted: \(name) could not be read")
                return
            }
            guard let heredoc = TerminalPaste.base64Heredoc(name: name, data: data) else {
                showNotice("not pasted: a control character in the file's name")
                return
            }
            heredocs.append(heredoc)
        }
        guard !heredocs.isEmpty else { return }
        let what = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        showNotice("\(what) as base64, \(TerminalPaste.size(total)) · Return writes it", lasting: 5)
        // Not by the door: every line of it ends in Return by design, and the
        // sheet would ask about exactly that.
        send(pasted: heredocs.joined(separator: "\n"))
    }

    /// A slow paste is going out.
    private(set) var isPastingSlowly = false
    /// The last whole percent the notice said, so it changes a hundred times
    /// and not once per sixteen bytes.
    private var slowPercent = -1

    /// Paste Slowly: straight to the attachment's queue, marked slow, rather
    /// than through the emulator's write path, which has no way to say so.
    private func send(slowly bytes: [UInt8]) {
        guard let attachment, !isPastingSlowly else { return }
        isPastingSlowly = true
        slowPercent = -1
        let pace = TerminalPaste.slowPace(liveConfig?() ?? config)
        attachment.send(bytes[...], pace: pace) { [weak self] event in
            guard let self else { return }
            switch event {
            case .sent(let sent, let total):
                let percent = sent * 100 / max(total, 1)
                guard percent != self.slowPercent else { return }
                self.slowPercent = percent
                self.showNotice(TerminalPaste.slowNotice(event), lasting: nil, fading: false)
            case .finished, .cancelled:
                self.isPastingSlowly = false
                self.showNotice(TerminalPaste.slowNotice(event))
            }
        }
    }

    /// Stop a slow paste. What has not gone never goes.
    func cancelSlowPaste() {
        guard isPastingSlowly else { return }
        attachment?.cancelSlowSend()
    }

    /// A key while a slow paste goes stops it. Esc is only that, and is
    /// swallowed: the program should not hear Esc because a paste was called
    /// off. Any other key is typing, which the paste gives way to, and it
    /// goes on to the program behind what was already sent.
    func keyDuringSlowPaste(_ event: NSEvent) -> Bool {
        guard isPastingSlowly else { return false }
        cancelSlowPaste()
        return event.keyCode == 53
    }

    // MARK: images

    /// Where a local pane's pasted pictures are written. The profile's cache
    /// directory, except in a test, which hands in one of its own.
    var pastedImages = PastedImages()

    /// The relay server this pane's session is on, as the file has it now, or
    /// nil for a server the file no longer configures. Set by the strip for a
    /// remote pane; a test sets it to point at its fake server.
    var uploadEndpoint: (() -> RelayServer?)?

    /// One upload at a time. A second ⌘V of a picture while the first is
    /// still going up is dropped: it is almost always the same picture.
    private(set) var isUploadingImage = false

    /// A picture becomes a file, and the file's path is what is pasted: on
    /// this Mac for a local session, on the server for a remote one, because
    /// a path is only any use on the machine the program reading it runs on.
    /// Never asks: a path is one line with no tab in it.
    private func paste(image png: Data) {
        let settings = TerminalPaste.ImageSettings(liveConfig?() ?? config)
        if let refusal = TerminalPaste.imageRefusal(bytes: png.count, settings) {
            showNotice(refusal)
            return
        }
        if let server = pane.sessionKey?.server {
            upload(png, to: server)
            return
        }
        do {
            let url = try pastedImages.save(png)
            guard let word = TerminalPaste.shellWord(for: url.path) else {
                showNotice("image saved, but its path cannot be typed at a prompt: \(pastedImages.directory.path)")
                return
            }
            showNotice("saved \(url.lastPathComponent), \(TerminalPaste.size(png.count))")
            send(pasted: word)
        } catch {
            showNotice("image not pasted: \(error.localizedDescription)")
        }
    }

    /// `POST /api/upload` (`RelayUpload`), off the main thread; the prompt
    /// gets the server's path when there is one and nothing when there is
    /// not. What is typed meanwhile goes first, as it would have anyway.
    private func upload(_ png: Data, to server: String) {
        guard !isUploadingImage else { return }
        guard let endpoint = uploadEndpoint?() else {
            showNotice("\(server): could not upload the image — the server is not in config.toml")
            return
        }
        isUploadingImage = true
        showNotice("uploading \(TerminalPaste.size(png.count)) to \(server)…", lasting: nil)
        let filename = PastedImages.name(stem: PastedImages.stem(at: Date()), attempt: 1)
        RelayUpload(name: server, endpoint: endpoint).upload(png, filename: filename) { [weak self] result in
            guard let self else { return }
            self.isUploadingImage = false
            switch result {
            case .failure(let error):
                self.showNotice(error.localizedDescription, lasting: 6)
            case .success(let path):
                guard let word = TerminalPaste.shellWord(for: path) else {
                    self.showNotice("\(server): uploaded, but the server's path cannot be typed at a prompt")
                    return
                }
                self.showNotice("uploaded \((path as NSString).lastPathComponent), \(TerminalPaste.size(png.count)), to \(server)")
                self.send(pasted: word)
            }
        }
    }

    /// What one paced piece costs end to end: the 5 ms gap plus the timer's
    /// slack, as measured (1 MB, 1 049 pieces, in 7.1 s).
    private static let secondsPerPiece = 0.0068

    private func ask(
        about text: String, _ settings: TerminalPaste.ConfirmSettings, tidied: String? = nil, slowly: Bool = false
    ) {
        let font = NSFont(name: config.fontName, size: 11)
        let sheet = PasteAskSheet(text: text, settings: settings, terminalFont: font, tidied: tidied) { [weak self] answer in
            self?.pasteAnswered(answer, text: text, settings, tidied: tidied, slowly: slowly)
        }
        sheet.onClick = { [weak self] in
            guard let self else { return }
            try? self.store.focusPane(self.paneId)
            self.pasteSheet?.takeFocus()
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        Motion.fade(container.layer)
        container.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: container.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        pasteSheet = sheet
        sheet.takeFocus()
    }

    private func pasteAnswered(
        _ answer: PasteAnswer, text: String, _ settings: TerminalPaste.ConfirmSettings, tidied: String? = nil,
        slowly: Bool = false
    ) {
        pasteSheet = nil
        if case .paste(let oneLine, let tabsToSpaces) = answer {
            var out = text
            if tabsToSpaces { out = TerminalPaste.tabsToSpaces(out, width: settings.tabWidth) }
            if oneLine { out = TerminalPaste.oneLine(out) }
            send(pasted: out, tidied: tidied, slowly: slowly)
        }
        // The terminal gets the keyboard back either way; without this the
        // pane is focused according to the ledger and deaf in fact.
        takeFocus()
    }

    // MARK: - A program and the clipboard (OSC 52, ADR-0028)

    /// The lane's header showed `COPIED`. False when it could not (`BLOCKED`
    /// or a dead server holds the chip, or the pane is on no lane), and the
    /// pane says it in its own notice line instead: a program changing the
    /// clipboard is never invisible.
    var onProgramCopied: (() -> Bool)?
    /// The lane's title and the session's command, as the header has them.
    var describeAsker: (() -> (lane: String, program: String?))?

    /// The question a program's clipboard request is waiting on. One at a time.
    private(set) var clipboardSheet: ClipboardAskSheet?
    /// The answer that question owes, so a pane torn down under it says no.
    private var clipboardAnswer: ((Bool) -> Void)?

    /// A program set the clipboard. The one door for it, whichever road the
    /// text took: relay's `CLIPBOARD` frame, or Ghostty parsing the OSC 52
    /// itself. `osc52_write` is read now, not when the pane was built.
    func programSetClipboard(_ text: String) {
        switch ProgramClipboard.write(text, (liveConfig?() ?? config).osc52Write) {
        case .ignore:
            return
        case .refuse(let why):
            showNotice(why)
        case .set:
            commitProgramCopy(text)
        case .ask:
            askAboutClipboard(.write, text: text) { [weak self] allowed in
                if allowed { self?.commitProgramCopy(text) }
            }
        }
    }

    private func commitProgramCopy(_ text: String) {
        ProgramClipboard.set(text, on: pasteboard)
        if onProgramCopied?() != true { showNotice(ProgramClipboard.copiedNotice(text)) }
    }

    /// A program asked to read the clipboard, and `text` is what it would be
    /// given. `respond` is owed exactly one answer. `osc52_read` decides, as
    /// it stands now: `ask` by default, because this is a way for anything
    /// running in a terminal, on any machine, to take what was last copied.
    func programAskedToReadClipboard(_ text: String, respond: @escaping (Bool) -> Void) {
        switch (liveConfig?() ?? config).osc52Read {
        case .deny: respond(false)
        case .allow: respond(true)
        case .ask: askAboutClipboard(.read, text: text, respond)
        }
    }

    private func askAboutClipboard(
        _ question: ProgramClipboard.Question, text: String, _ respond: @escaping (Bool) -> Void
    ) {
        // A second question while one is open is answered no, not queued: a
        // program that asks in a loop must not be able to stack sheets.
        guard pasteSheet == nil, clipboardSheet == nil else {
            respond(false)
            return
        }
        let described = describeAsker?()
        let asker = ProgramClipboard.Asker(
            lane: described?.lane ?? store.lane(containing: paneId)?.title ?? "untitled",
            program: described?.program, server: pane.relayServer)
        let sheet = ClipboardAskSheet(
            question: question, asker: asker, text: text,
            terminalFont: NSFont(name: config.fontName, size: 11)
        ) { [weak self] allowed in
            guard let self else { return respond(false) }
            let hadKeyboard = self.clipboardSheet.map { self.container.window?.firstResponder === $0 } ?? false
            self.clipboardSheet = nil
            self.clipboardAnswer = nil
            respond(allowed)
            // Back to the terminal only if the sheet had the keyboard: a
            // question answered with a click from another lane's typing must
            // not move it.
            if hadKeyboard { self.takeFocus() }
        }
        sheet.onClick = { [weak self] in
            guard let self else { return }
            try? self.store.focusPane(self.paneId)
            self.clipboardSheet?.takeFocus()
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        Motion.fade(container.layer)
        container.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: container.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        clipboardSheet = sheet
        clipboardAnswer = respond
        // The program asked, not the person: the sheet takes the keyboard
        // only from its own terminal, so typing there stops going under it,
        // and never from another lane.
        if container.window?.firstResponder === terminal { sheet.takeFocus() }
    }

    /// Files dropped on the pane: their paths typed at the cursor, quoted as
    /// ⌘V would quote them, and the keyboard here so the next thing typed
    /// follows them. The drop comes from another app, so this one comes
    /// forward as well.
    private func dropFiles(from pasteboard: NSPasteboard) -> Bool {
        let clipboard = TerminalPaste.clipboard(pasteboard)
        guard clipboard.text != nil || clipboard.notice != nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        try? store.focusPane(paneId)
        takeFocus()
        paste(clipboard)
        return true
    }

    // pty panes are exempt from all four of these (PRD §10.3). The policy in
    // `laned-core` never emits anything but `.keep` for them; these exist
    // because the protocol asks, and they do nothing on purpose.
    func unparent() {}
    func reparentIfNeeded() {}
    func evict() {}
    func rehydrate() {}

    /// The session appeared in, or vanished from, RelayTTY's directory.
    func sessionAvailabilityChanged(_ available: Bool) {
        guard available != isSessionAvailable else { return }
        isSessionAvailable = available
        // A refused attachment stays refused; the registry's view of the
        // session coming and going does not change what the server said.
        if case .refused = status.state { return }
        status.setState(restingBanner)
        if available { attachment?.connect() }
    }

    // MARK: - size

    /// Ghostty's grid changed because the view did. Pass the new shape on.
    ///
    /// This is the whole of the resize story now: the lane's width decides the
    /// view's width, the view's width decides Ghostty's grid, and Ghostty tells
    /// us what it became. Nothing converts points to columns by hand any more,
    /// which is where the old implementation kept losing rows to a font metric
    /// that did not match the one the renderer actually used.
    private func gridChanged(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != hostCols || rows != hostRows else { return }
        hostCols = cols
        hostRows = rows
        // A preset that has just landed is still arriving: the font and the
        // width each re-derive the grid, a run loop apart. Wait for it to stop.
        if isSettling { scheduleSettle() }
        // Mid-drag, the shape the pointer is passing through is not a decision.
        guard !isLiveResizing else { return }
        claim(cols: cols, rows: rows)
    }

    /// The one way a size reaches the far end, so `claimedSize` cannot drift
    /// from what was actually sent.
    private func claim(cols: Int, rows: Int) {
        claimedSize = (cols, rows)
        attachment?.claimSize(cols: cols, rows: rows)
    }

    /// The size the PTY was last told, or last reported. What a size preset
    /// compares its landing against, so a preset that ends on the grid it
    /// started from sends nothing at all.
    private var claimedSize: (cols: Int, rows: Int)?

    /// The user has grabbed something that changes this pane's size and has not
    /// let go — today, the seam between two stacked panes.
    ///
    /// The grid still follows the view the whole way down: the terminal must
    /// reflow under the pointer or the drag is a lie. What is held back is the
    /// word to the far end. A pane's rows *do* have to reach the PTY — one
    /// `winsize`, and a full-screen TUI that thinks it has fifty rows paints
    /// fifty into a pane showing twenty — but dragging a seam across 400 points
    /// crosses a row boundary every seventeen, and spike M2 measured a single
    /// reshape of an `htop` session at **6 671 bytes of forced redraw on every
    /// other client attached to it**, a phone included. Twenty-three of those
    /// during one drag is the app fighting itself, which is the exact cost
    /// [ADR-0007](../../../../docs/decisions/0007-terminal-panes-never-resize-the-pty.md)
    /// was written about — and the supersede that lets a lane reshape the PTY
    /// at all bought "the text reflows when I resize", not "the text reflows
    /// twenty-three times while I am still deciding".
    ///
    /// So the far end learns the shape the drag *landed* on, once. The same
    /// one-commit-per-decision rule the ledger write beside it follows, applied
    /// to the only other thing a drag can spam.
    ///
    /// Deliberately not the mask that `LaneView.revealWidth` uses for a column
    /// opening. A mask is right when the user did not ask for a resize and the
    /// pane inside must not be told: it keeps its real size behind a hole in
    /// the shape of the animation. A seam drag is the opposite — the user *is*
    /// changing the pane's height, and a terminal masked to a shorter rectangle
    /// is one whose cursor and last three lines are simply under the edge.
    func beginLiveResize() {
        isLiveResizing = true
    }

    /// The drag ended. Tell the far end the shape it finished at.
    ///
    /// Unconditionally, even when the drag ended on the row count it started
    /// from: ADR-0007 §5 establishes that re-asserting a size already in effect
    /// is free, and "was there a net change" is state this would otherwise have
    /// to keep correct across a surface rebuild, an inbound `RESIZE` from a
    /// phone, and a lane view being recycled mid-drag.
    func endLiveResize() {
        guard isLiveResizing else { return }
        isLiveResizing = false
        guard hostCols > 0, hostRows > 0 else { return }
        claim(cols: hostCols, rows: hostRows)
    }

    /// The explicit "claim this session" command (ADR-0007 §5).
    func claimSessionAtLaneWidth() {
        claim(cols: hostCols, rows: hostRows)
    }

    // MARK: - size presets

    /// A size preset in flight (`LaneSizePreset`).
    ///
    /// The lane's width eases on `Motion.lane`, and a terminal that followed it
    /// frame by frame would reflow its text a dozen times and — with the font
    /// changing too — pass through column counts nobody chose, each one a
    /// reshape on every other client of the session. So for the length of the
    /// animation the terminal **keeps the width it had**, and is drawn scaled
    /// toward the cell it is heading for by giving its container larger bounds
    /// than frame, the same bounds-versus-frame trick a gallery tile uses. Its
    /// columns never move; its rows follow the pane's height as they always do.
    /// When the lane arrives the font and the width land together: one reflow.
    private struct SizeHold {
        /// The terminal's width when the preset began, held.
        var width: CGFloat
        /// How much smaller, or larger, a cell is drawn at the end: the target
        /// cell over the starting one. 1 when only the width changes.
        var endScale: CGFloat
        var progress: CGFloat = 0
        /// Whether the container clipped before the hold made it.
        var wasMasked: Bool
    }
    private var sizeHold: SizeHold?
    /// Between a preset landing and its grid going quiet. See `scheduleSettle`.
    private var isSettling = false
    private var settleGeneration = 0

    var isInSizeTransition: Bool { sizeHold != nil }

    /// Start a size preset toward `target` zoom. The ledger already holds the
    /// new zoom; this only has to get the surface there without jumping.
    func beginSizeTransition(toZoom target: Double, backingScale: CGFloat) {
        if sizeHold != nil { endSizeTransition() }
        let ladder = PaneZoom.ladder
        let next = min(max(target, ladder.first!), ladder.last!)
        let fromCell = LaneSizePreset.cellWidth(
            fontName: config.fontName, fontSize: config.fontSize * zoom, backingScale: backingScale)
        let toCell = LaneSizePreset.cellWidth(
            fontName: config.fontName, fontSize: config.fontSize * next, backingScale: backingScale)
        zoom = next

        // Nothing leaves for the far end until the grid has landed and gone
        // quiet; `finishSettle` then sends one size, or none.
        isLiveResizing = true
        isSettling = false
        settleGeneration &+= 1
        if claimedSize == nil, hostCols > 0, hostRows > 0 { claimedSize = (hostCols, hostRows) }

        let width = terminal.bounds.width > 0 ? terminal.bounds.width : container.bounds.width
        sizeHold = SizeHold(
            width: width, endScale: fromCell > 0 ? toCell / fromCell : 1,
            wasMasked: container.layer?.masksToBounds ?? false)
        // A lane going from xl to s draws a 160-column terminal into a column
        // shrinking to 80: clipped, not spilling over its neighbour.
        container.layer?.masksToBounds = true
        if thumbnailHold == nil {
            NSLayoutConstraint.deactivate(terminalEdges)
            terminal.translatesAutoresizingMaskIntoConstraints = true
        }
        fitTerminal()
    }

    /// One frame of the preset: `progress` is already eased.
    func stepSizeTransition(_ progress: CGFloat) {
        guard sizeHold != nil else { return }
        sizeHold?.progress = progress
        fitTerminal()
    }

    /// The lane has arrived. Font and width land together, and the far end
    /// hears about it once the grid has stopped moving.
    func endSizeTransition() {
        guard let hold = sizeHold else { return }
        sizeHold = nil
        container.setBoundsSize(container.frame.size)
        container.layer?.masksToBounds = hold.wasMasked
        if thumbnailHold == nil {
            terminal.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate(terminalEdges)
        }
        applyZoom()
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        terminal.fitToSize()
        isSettling = true
        scheduleSettle()
    }

    /// How long the grid has to be quiet before a preset's landing counts.
    ///
    /// Ghostty re-derives the grid once for the font and once for the width,
    /// and reports each through a hop to the main actor — so the size the
    /// preset lands on arrives a run loop or two after `endSizeTransition`, by
    /// way of a size it only passed through. Every report re-arms this.
    static let settleDelay: TimeInterval = 0.2

    private func scheduleSettle() {
        settleGeneration &+= 1
        let generation = settleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay) { [weak self] in
            guard let self, generation == self.settleGeneration else { return }
            self.finishSettle()
        }
    }

    /// Tell the far end the shape the preset landed on — only if it is not the
    /// one it already has. `m → s` keeps every column, so what changes there is
    /// the rows a smaller font fits into the same height; `s → m` gives them
    /// back, and nothing in between is ever sent.
    private func finishSettle() {
        guard isSettling, sizeHold == nil else { return }
        isSettling = false
        isLiveResizing = false
        guard let grid, grid.columns > 0, grid.rows > 0 else { return }
        if let claimedSize, claimedSize == (grid.columns, grid.rows) { return }
        claim(cols: grid.columns, rows: grid.rows)
    }

    // MARK: - zoom

    /// ⌘= / ⌘- / ⌘0 on this terminal: bigger or smaller text.
    ///
    /// Ghostty carries font size on the *controller*, and one controller backs
    /// every pane (ADR-0009) — so a per-pane size cannot come from the config.
    /// It comes from the surface's own font-size binding actions instead, which
    /// are per-surface and are what Ghostty's own ⌘+ does.
    private(set) var zoom: Double = 1

    func setZoom(_ next: Double) {
        let ladder = PaneZoom.ladder
        zoom = min(max(next, ladder.first!), ladder.last!)
        store.setPaneZoom(paneId, zoom)
        applyZoom()
    }

    /// Drive the surface to `zoom` from a known base rather than by however far
    /// it has to travel.
    ///
    /// Ghostty only offers *relative* font-size actions, and a surface rebuild
    /// — which happens whenever the strip recycles a lane view — silently puts
    /// the font back to the config's size. Tracking the delta we last applied
    /// would then be tracking a number the surface no longer agrees with. So
    /// this resets first: two actions instead of one, and the answer is right
    /// however the surface got where it is.
    private func applyZoom() {
        terminal.performBindingAction("reset_font_size")
        let delta = config.fontSize * (zoom - 1)
        guard abs(delta) > 0.01 else { return }
        terminal.performBindingAction(
            delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)")
    }

    /// The lane's width changed. Ghostty re-derives its grid from the view, so
    /// this only has to make sure the view has laid out.
    func laneWidthDidChange(to width: CGFloat) {
        terminal.fitToSize()
    }

    // MARK: - as a gallery tile

    /// How Core Animation shrinks this terminal's surface. `.linear` everywhere
    /// but the gallery, where `GalleryLayout.minificationFilter` decides.
    ///
    /// A filter and not a smaller surface, on purpose: Ghostty's cells are whole
    /// pixels, so drawing into fewer of them re-derives the grid — spike M5
    /// measured 80×58 becoming 79×54 at half size — and a grid that changes is
    /// a resize on every other client of the session.
    private var minificationFilter: CALayerContentsFilter = .linear

    /// The terminal's pinned edges, set aside while it is a tile.
    private var terminalEdges: [NSLayoutConstraint] = []

    /// While this pane is a gallery tile: the size the terminal holds, and how
    /// far the space around it may move before that counts as a real change.
    private struct ThumbnailHold {
        var size: CGSize
        var tolerance: CGFloat
    }
    private var thumbnailHold: ThumbnailHold?

    /// Enter a tile at `scale`, or leave one with nil.
    ///
    /// Two things, and the second is the one that matters. The filter is for
    /// sharpness. The hold is for the grid: inside a transformed tile, Auto
    /// Layout rounds this pane's frame to the *tile's* pixels, which can move it
    /// by a point — and a point can be a column. So the terminal leaves its
    /// constraints and keeps the size it had on the strip, adopting a new one
    /// only when the space it is given moves by more than rounding explains.
    func setThumbnail(scale: CGFloat?, backingScale: CGFloat, expanded: Bool = false) {
        isUnexpandedTile = scale != nil && !expanded
        // Two holds on one surface would each think it owned the constraints.
        // A preset cannot start in the gallery, so one in flight simply lands.
        if scale != nil, sizeHold != nil { endSizeTransition() }
        if let scale {
            minificationFilter = GalleryLayout.minificationFilter(scale: scale, backingScale: backingScale)
            let tolerance = GalleryLayout.roundingTolerance(scale: scale, backingScale: backingScale)
            if thumbnailHold != nil {
                thumbnailHold?.tolerance = tolerance
            } else {
                let size = terminal.bounds.size
                thumbnailHold = ThumbnailHold(size: size, tolerance: tolerance)
                NSLayoutConstraint.deactivate(terminalEdges)
                terminal.translatesAutoresizingMaskIntoConstraints = true
                terminal.frame = CGRect(origin: .zero, size: size)
            }
        } else {
            minificationFilter = .linear
            if thumbnailHold != nil {
                thumbnailHold = nil
                terminal.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate(terminalEdges)
            }
        }
        applyMinificationFilter()
        container.needsLayout = true
    }

    /// Size the surface: from its constraints on the strip, from the hold in a tile.
    private func fitTerminal() {
        if let hold = sizeHold {
            // Larger bounds than frame draw the terminal smaller; the terminal
            // keeps its width in those bounds, so its columns stay put, and
            // fills their height, so its rows follow the pane.
            let scale = max(0.05, 1 + (hold.endScale - 1) * hold.progress)
            let frame = container.frame.size
            let bounds = NSSize(width: frame.width / scale, height: frame.height / scale)
            if container.bounds.size != bounds { container.setBoundsSize(bounds) }
            let rect = CGRect(x: 0, y: 0, width: hold.width, height: bounds.height)
            if terminal.frame != rect { terminal.frame = rect }
            terminal.fitToSize()
            return
        }
        if var hold = thumbnailHold {
            // A terminal never laid out has nothing to hold; it takes the tile's.
            let measured = container.bounds.size
            hold.size = hold.size == .zero
                ? measured
                : GalleryLayout.heldSize(hold.size, measured: measured, tolerance: hold.tolerance)
            thumbnailHold = hold
            let frame = CGRect(origin: .zero, size: hold.size)
            if terminal.frame != frame { terminal.frame = frame }
        }
        terminal.fitToSize()
    }

    private func applyMinificationFilter() {
        let filter = minificationFilter
        func apply(_ layer: CALayer?) {
            guard let layer else { return }
            if layer.minificationFilter != filter { layer.minificationFilter = filter }
            layer.sublayers?.forEach(apply)
        }
        apply(terminal.layer)
    }

    // MARK: - cwd and title

    private func reportCwd() {
        guard let cwd = currentCwd, let laneId = store.lane(containing: paneId)?.id else { return }
        // Cheap: an unchanged cwd costs 0.009 ms and writes nothing.
        store.observeCwd(laneId, cwd)
    }

    private func adoptTitle(_ title: String) {
        guard !title.isEmpty, let laneId = store.lane(containing: paneId)?.id else { return }
        guard store.lane(laneId)?.title != title else { return }
        try? store.setLaneTitle(laneId, title)
    }

    /// Hand a clicked path or URL to the strip, which opens it in a new lane
    /// immediately right of this one.
    ///
    /// Right of the terminal that mentioned it, not at the end of the strip:
    /// the thing and the thing that referred to it belong side by side, which
    /// is the entire premise of putting web panes on the same strip as shells.
    ///
    /// *Which* kind of lane is not this pane's decision. A `.pdf` is a web pane
    /// and a `.ts` is `$EDITOR` in a terminal, and spawning the second needs a
    /// size, a cwd and a spawner that live one level up — so the token goes up
    /// and the strip routes it through `FileOpen`.
    func open(_ token: TerminalToken) {
        onOpenToken?(token)
    }

    /// ⌘-click: open whatever is under the pointer in the next lane.
    ///
    /// The word comes from the viewport read rather than from Ghostty's own
    /// word selection, because the interesting tokens are exactly the ones its
    /// word boundaries split — `src/foo.ts:42:10` is one thing to open, not
    /// four. `TerminalTokenizer` gates on the file existing, so a ⌘-click on
    /// prose does nothing rather than opening a pane onto a word.
    private func openToken(at point: CGPoint) {
        guard let grid,
              let cell = ClickableTerminalView.cell(
                  at: point,
                  columns: grid.columns,
                  rows: grid.rows,
                  viewSize: terminal.bounds.size,
                  padding: Self.terminalPadding),
              let text = session.readViewportText()
        else { return }

        let lines = text.components(separatedBy: "\n")
        guard cell.row < lines.count,
              let word = TerminalTokenizer.word(in: lines[cell.row], column: cell.column),
              let token = TerminalTokenizer.classify(word, cwd: currentCwd ?? "")
        else { return }
        open(token)
    }

    // MARK: - search index

    /// PRD §7.5's cap.
    private static let scrollbackLines = 200

    /// Push recent lines to `laned-core` so ⌘P can find them.
    ///
    /// Debounced hard. A busy agent produces output continuously and the index
    /// only needs to be roughly current — it is a way to find a lane, not a log.
    private func scheduleScrollbackPush() {
        scrollbackDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushScrollback() }
        scrollbackDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func pushScrollback() {
        // Ghostty's viewport read is exactly the visible rows and ignores
        // scrollback by design, so the live stream is what gives the index any
        // history at all: whatever is on screen now, plus what went past before
        // it scrolled off.
        var lines = seenLines
        if let viewport = session.readViewportText() {
            for line in viewport.split(separator: "\n", omittingEmptySubsequences: true) {
                let text = String(line)
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                if lines.last != text { lines.append(text) }
            }
        }
        if lines.count > Self.scrollbackLines {
            lines.removeFirst(lines.count - Self.scrollbackLines)
        }
        guard !lines.isEmpty else { return }
        store.pushScrollback(paneId, lines)
    }

    /// Lines seen on the live stream, capped at what the index keeps.
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
}

// MARK: - Ghostty delegates

extension TerminalPaneController: TerminalSurfaceFocusDelegate, TerminalSurfaceLifecycleDelegate {
    /// Every route into `ghostty_surface_set_focus` reports here, ours included.
    ///
    /// Checked a turn later, not here: this arrives from *inside*
    /// `becomeFirstResponder` and `resignFirstResponder`, where
    /// `window.firstResponder` is still the previous answer. Asked now, a pane
    /// taking the keyboard would be told it had not.
    func terminalDidChangeFocus(_ focused: Bool) {
        surfaceFocused = focused
        DispatchQueue.main.async { [weak self] in self?.syncSurfaceFocus() }
    }

    /// A new surface, and so a new belief that it is focused. A rebuild (a
    /// font size, a recycled lane view) is a birth as much as the first one.
    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
        surfaceFocused = true
        syncSurfaceFocus()
    }

    func terminalDidDetachSurface() { surface = nil }
}

extension TerminalPaneController: TerminalSurfaceClipboardConfirmationDelegate {
    /// OSC 52 that reached Ghostty itself. The terminals' configuration says
    /// `ask` for both directions, so every one arrives here, and without this
    /// conformance the library denies them all.
    ///
    /// A write is never allowed *through the library*, which would put it on
    /// `NSPasteboard.general` with nothing said: the pane's own door sets it,
    /// so the cap, the chip and the setting apply to it as they do to relay's
    /// `CLIPBOARD` frame, and the library is told no. For a read the library
    /// has already read the general pasteboard (it cannot be handed another)
    /// and `request.contents` is what it would give the program.
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        switch request.kind {
        case .osc52Write:
            programSetClipboard(request.contents)
            request.respond(allow: false)
        case .osc52Read:
            programAskedToReadClipboard(request.contents) { request.respond(allow: $0) }
        case .paste:
            // Ghostty's own paste protection. The pane never pastes through
            // Ghostty (`TerminalPaste`), so this is not expected; answered as
            // the library answers it for a host with no opinion.
            request.respond(allow: true)
        }
    }
}

extension TerminalPaneController: TerminalSurfaceTitleDelegate {
    func terminalDidChangeTitle(_ title: String) { adoptTitle(title) }
}

extension TerminalPaneController: TerminalSurfacePwdDelegate {
    /// OSC 7, reported natively.
    ///
    /// The previous implementation sniffed this out of the raw byte stream by
    /// hand, because SwiftTerm's own parse of it was not exposed. All of that
    /// code is gone.
    func terminalDidChangeWorkingDirectory(_ path: String) {
        let resolved = URL(string: path)?.path ?? path
        guard !resolved.isEmpty, resolved != currentCwd else { return }
        currentCwd = resolved
        reportCwd()
    }
}

extension TerminalPaneController: TerminalSurfaceOpenURLDelegate {
    /// A hyperlink the terminal recognised — including OSC 8 links, which is a
    /// good deal more than a regex over the visible text.
    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        guard let scheme = URL(string: url)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        open(.url(url))
    }
}

extension TerminalPaneController: TerminalSurfaceCloseDelegate {
    func terminalDidClose(processAlive: Bool) {
        status.isHidden = false
        status.setState(.exited(0))
    }
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
        /// The attachment stopped for good: which server, and why, in one line.
        case refused(String)
        /// Something could not be done here, said once and then gone.
        case notice(String)
        /// The session's server is not answering its session list: the
        /// state the sidebar and the lane header are showing, in the same
        /// word, and what that means for the keyboard.
        case offline(ServerState)
    }

    /// What the banner says about typing while the wire is down, and it is
    /// the truth: nothing typed now is going anywhere. The adapter holds
    /// input for `PendingInput.maxAge` so a blip of a reconnect loses
    /// nothing, and drops anything older rather than replaying it into a
    /// session that has moved on — a `y⏎` typed at one prompt must not land
    /// on another a minute later. A drop is said in one line when it
    /// happens (ADR-0023).
    static let inputNotSent = "INPUT IS NOT BEING SENT"

    private(set) var state: State = .connected
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
        self.state = state
        switch state {
        case .connected:
            isHidden = true
        case .reconnecting:
            isHidden = false
            label.stringValue = "RECONNECTING · \(Self.inputNotSent)"
            label.textColor = Theme.accent
            layerBackgroundColor = Theme.accent.withAlphaComponent(0.12)
        case .offline(let server):
            isHidden = false
            label.stringValue = "\(server.label) · \(Self.inputNotSent)"
            label.textColor = Theme.accent
            layerBackgroundColor = Theme.accent.withAlphaComponent(0.12)
        case .exited(let code):
            isHidden = false
            label.stringValue = code == 0 ? "EXITED" : "EXITED \(code)"
            label.textColor = Theme.dimText
            layerBackgroundColor = Theme.laneBorder.withAlphaComponent(0.3)
        case .refused(let why), .notice(let why):
            // Grey, at rest: neither is a state the greens are for, and a
            // permanent green line on a lane that cannot connect would spend
            // the colour on something that is true all day.
            isHidden = false
            label.stringValue = why.uppercased()
            label.textColor = Theme.dimText
            layerBackgroundColor = Theme.laneBorder.withAlphaComponent(0.3)
        }
    }
}

/// A pane's container, which tells Ghostty to re-measure whenever it lays out.
@MainActor
final class TerminalPaneContainer: NSView {
    var onLayout: (() -> Void)?
    var onAttach: (() -> Void)?
    var onPaste: (() -> Void)?
    var onPasteWithoutAsking: (() -> Void)?
    var onPasteSpecial: ((TerminalPaste.Special) -> Void)?
    /// Files from Finder dropped on the pane. Answers whether it took them.
    var onDropFiles: ((NSPasteboard) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Files only. Ghostty's view registers for nothing, so a drag over it
        // falls through to here; and the strip's own pane drag is mouse
        // tracking, not an AppKit dragging session, so the two never meet.
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDropFiles == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        onDropFiles?(sender.draggingPasteboard) ?? false
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }
}

/// The pane's paste, answered by the container rather than by the terminal.
///
/// The terminal view is Ghostty's, and a subclass in this module cannot
/// override a method the framework did not declare `open` — nor should it want
/// to, since `paste:` is the emulator path the pane deliberately does not take.
/// The container is the terminal's `nextResponder`, so the Edit menu's
/// nil-targeted send arrives here the moment the terminal declines it, and
/// arrives nowhere at all when a web pane has the keyboard — which is how ⌘V
/// still reaches WebKit untouched.
extension TerminalPaneContainer: TerminalPasteTarget {
    func pasteIntoTerminalPane(_ sender: Any?) { onPaste?() }
    func pasteIntoTerminalPaneWithoutAsking(_ sender: Any?) { onPasteWithoutAsking?() }
    func pasteSpecialIntoTerminalPane(_ sender: Any?) {
        guard let name = sender as? String, let special = TerminalPaste.Special(rawValue: name) else { return }
        onPasteSpecial?(special)
    }
}


/// One Ghostty controller for the whole strip.
///
/// A controller owns a libghostty *app*, and surfaces are minted from it — one
/// controller can back every pane. Making one per pane would stand up a
/// renderer, config and event loop per lane, which for a strip that routinely
/// holds a dozen sessions is a real cost for no gain: every pane wants the same
/// font and the same palette.
@MainActor
enum TerminalControllerPool {
    static let shared = TerminalControllerPool.Store()

    @MainActor
    final class Store {
        private var controller: TerminalController?

        /// The shared controller, built on first use from the app's config.
        func controller(for config: Config) -> TerminalController {
            if let controller { return controller }
            let made = TerminalControllerPool.makeController(for: config)
            controller = made
            return made
        }
    }

    /// A controller with the app's font, palette and padding, not shared.
    ///
    /// For tests that need a real surface measured exactly as a pane's would be,
    /// without touching the shared controller: a controller follows the
    /// appearance of the surfaces it minted, so a test window in the system's
    /// mode flips the palette under any other test that is waiting on the
    /// shared one (`AppearanceTests` is, and did).
    static func makeController(for config: Config) -> TerminalController {
        TerminalController(
                theme: theme,
                terminalConfiguration: TerminalConfiguration { builder in
                    builder.withFontFamily(config.fontName)
                    builder.withFontSize(Float(config.fontSize))
                    // The lane paints its own background; a terminal painting a
                    // second one on top shows a seam under the header.
                    builder.withBackgroundOpacity(0)
                    // Ghostty ships a full set of app keybindings — ⇧⌘W closes
                    // a window, ⌘T opens a tab — and claims them in
                    // `performKeyEquivalent`, which runs before the menu. In
                    // Ghostty those shortcuts do something; here they silently
                    // ate Max Pane's own, so Close Lane worked from the File
                    // menu and did nothing from the keyboard. The strip owns
                    // the window, so the terminal owns no window commands.
                    // Copy, paste and select-all are unaffected: those are
                    // responder-chain actions, driven by our Edit menu.
                    builder.withCustom("keybind", "clear")
                    // `copy_on_select`, off unless the config says otherwise:
                    // a selection made by accident must not replace what was
                    // copied on purpose. Written out both ways rather than
                    // left to Ghostty's default, so this cannot move when
                    // that does. ⌘C and the right-click Copy item are
                    // `copy_to_clipboard`, which does not read this.
                    builder.withCustom("copy-on-select", config.copyOnSelect ? "true" : "false")
                    // OSC 52. `ask` both ways, always, whatever `osc52_write`
                    // and `osc52_read` say: `ask` is what makes Ghostty bring
                    // each request to the pane, and the pane answers from the
                    // settings as they are at that moment. Left to Ghostty's
                    // defaults a write landed on the clipboard with nothing
                    // said and a read was denied with nobody asked (ADR-0028).
                    // ⌘C is `copy_to_clipboard`, which reads neither.
                    builder.withCustom("clipboard-write", "ask")
                    builder.withCustom("clipboard-read", "ask")
                    // `cursor_blink`. Ghostty blinks a focused surface's cursor
                    // and holds an unfocused one still and hollow, so
                    // `focused` and `always` are both "blink", and differ in
                    // what each surface is told about focus: see
                    // `syncSurfaceFocus`. Said both ways, as above. A program's
                    // DECSCUSR steady cursor still wins; this is the default
                    // style, not an override.
                    builder.withCursorStyleBlink(config.cursorBlink != .never)
                    // Matching the lane's own gutter, so text does not start
                    // hard against the divider.
                    builder.withWindowPaddingX(Int(TerminalPaneController.terminalPadding.x))
                    builder.withWindowPaddingY(Int(TerminalPaneController.terminalPadding.y))
                })
    }

    /// Afterglow and Alabaster, with the three colours that are ours.
    ///
    /// The theme is rendered *after* the configuration, so a colour set in the
    /// config is overwritten by whatever the theme says — which is why these
    /// belong here and not beside the font. Starting from Ghostty's defaults
    /// keeps a full, legible ANSI palette; overriding the background makes the
    /// pane the same colour as the lane around it, and the cursor is the
    /// accent because a cursor marks where the focus is.
    ///
    /// A selection is a faint accent wash under text that keeps its own
    /// colour. The stock themes paint selected text in one flat grey on
    /// another, which on the lane background came out as text and band the
    /// same shade — a selection you could make but not read. `cell-foreground`
    /// leaves every cell's colour alone, so a selected `ls` still shows its
    /// directories in blue; the wash is light enough that both the dark and
    /// the light palettes stay legible over it.
    static var theme: TerminalTheme {
        TerminalTheme(
            light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                builder.withBackground(hex(Theme.laneBackground, in: .aqua))
                builder.withCursorColor(hex(Theme.accent, in: .aqua))
                builder.withSelectionBackground(hex(selectionWash, in: .aqua))
                builder.withSelectionForeground("cell-foreground")
            },
            dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                builder.withBackground(hex(Theme.laneBackground, in: .darkAqua))
                builder.withCursorColor(hex(Theme.accent, in: .darkAqua))
                builder.withSelectionBackground(hex(selectionWash, in: .darkAqua))
                builder.withSelectionForeground("cell-foreground")
            })
    }

    /// The accent, laid over the lane background at the same strength the
    /// sidebar uses for its selected row, then flattened: Ghostty takes an
    /// opaque colour, and an alpha in the hex would be dropped.
    static var selectionWash: NSColor {
        NSColor(name: nil) { _ in
            Theme.accent.blended(withFraction: 0.84, of: Theme.laneBackground) ?? Theme.laneBackground
        }
    }

    /// `#rrggbb`, which is how Ghostty takes colours — so the theme is
    /// converted here rather than duplicated as literals.
    ///
    /// Resolved in a named appearance rather than the current one: the theme is
    /// built once, and a dynamic colour read at launch would otherwise freeze
    /// whichever mode the Mac happened to be in.
    static func hex(_ color: NSColor, in appearance: NSAppearance.Name) -> String {
        var resolved = color
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? .black
        }
        let channels = [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
        return "#" + channels.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }
}
