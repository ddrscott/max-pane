import AppKit
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

    func connect()
    func disconnect()
    func send(_ bytes: ArraySlice<UInt8>)

    /// Reshape the PTY. This changes the terminal for **every** client attached
    /// to the session, the phone included, which is why it is debounced to the
    /// size the user settles on. See ADR-0007.
    func claimSize(cols: Int, rows: Int)
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

    init(pane: Pane, store: StripStore, config: Config) {
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
            // A recycled lane view brings a fresh surface, at the config's font
            // size — so a zoomed pane scrolled off the strip and back would
            // come back the wrong size without this.
            self?.applyZoom()
        }
        terminal.onCommandClick = { [weak self] point in self?.openToken(at: point) }
        container.onPaste = { [weak self] in self?.pasteFromClipboard() }

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
        terminal.controller = TerminalControllerPool.shared.controller(for: config)
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
        // single byte has arrived.
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
        }
        attachment.onTitle = { [weak self] title in
            self?.adoptTitle(title)
        }
        attachment.onConnectionChange = { [weak self] connected in
            self?.status.isHidden = connected
            self?.status.setState(connected ? .connected : .reconnecting)
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
        guard window.firstResponder !== terminal else {
            wantsFocus = false
            return
        }
        if window.makeFirstResponder(terminal) { wantsFocus = false }
    }

    func tearDown() {
        scrollbackDebounce?.cancel()
        attachment?.disconnect()
        attachment = nil
    }

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
    func pasteFromClipboard() {
        guard let text = TerminalPaste.clipboardText() else { return }
        let bytes = TerminalPaste.bytes(for: text)
        guard !bytes.isEmpty else { return }
        session.sendInput(Data(bytes))
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
        if available {
            status.setState(.connected)
            attachment?.connect()
        } else {
            status.setState(.reconnecting)
        }
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
        // Mid-drag, the shape the pointer is passing through is not a decision.
        guard !isLiveResizing else { return }
        attachment?.claimSize(cols: cols, rows: rows)
    }

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
        attachment?.claimSize(cols: hostCols, rows: hostRows)
    }

    /// The explicit "claim this session" command (ADR-0007 §5).
    func claimSessionAtLaneWidth() {
        attachment?.claimSize(cols: hostCols, rows: hostRows)
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
    func setThumbnail(scale: CGFloat?, backingScale: CGFloat) {
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
            label.stringValue = "RECONNECTING"
            label.textColor = Theme.accent
            layerBackgroundColor = Theme.accent.withAlphaComponent(0.12)
        case .exited(let code):
            isHidden = false
            label.stringValue = code == 0 ? "EXITED" : "EXITED \(code)"
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
            let made = TerminalController(
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
                    // Selecting text puts it on the clipboard, as it did before
                    // the migration and as it does in Relay. Ghostty's own
                    // default is off.
                    builder.withCustom("copy-on-select", "true")
                    // Matching the lane's own gutter, so text does not start
                    // hard against the divider.
                    builder.withWindowPaddingX(Int(TerminalPaneController.terminalPadding.x))
                    builder.withWindowPaddingY(Int(TerminalPaneController.terminalPadding.y))
                })
            controller = made
            return made
        }
    }

    /// Afterglow and Alabaster, with the two colours that are ours.
    ///
    /// The theme is rendered *after* the configuration, so a colour set in the
    /// config is overwritten by whatever the theme says — which is why these
    /// belong here and not beside the font. Starting from Ghostty's defaults
    /// keeps a full, legible ANSI palette; overriding the background makes the
    /// pane the same colour as the lane around it, and the cursor is the
    /// accent because a cursor marks where the focus is.
    static var theme: TerminalTheme {
        TerminalTheme(
            light: TerminalConfiguration(startingFrom: .alabaster) { builder in
                builder.withBackground(hex(Theme.laneBackground, in: .aqua))
                builder.withCursorColor(hex(Theme.accent, in: .aqua))
            },
            dark: TerminalConfiguration(startingFrom: .afterglow) { builder in
                builder.withBackground(hex(Theme.laneBackground, in: .darkAqua))
                builder.withCursorColor(hex(Theme.accent, in: .darkAqua))
            })
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
