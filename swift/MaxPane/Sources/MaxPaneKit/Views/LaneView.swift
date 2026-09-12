import AppKit
import LanedCore

/// One column of the strip.
///
/// The design invariant, in code: a lane's width is clamped to
/// `[LANE_MIN, LANE_MAX]` and nothing it contains is allowed to widen it. Wide
/// content scrolls inside the pane, never past the lane's edge.
///
/// A lane is a column with a hard edge — square corners, a 1pt border, and
/// status carried by content (the header's glyph and tag chip) rather than by a
/// coloured rail bent around a radius.
@MainActor
final class LaneView: NSView {
    var laneId: String
    private let header = LaneHeaderView()
    private let stack = NSStackView()
    private let resizeHandle = LaneResizeHandle()
    private var paneViews: [String: NSView] = [:]

    /// Dragging the right edge. Reports live during the drag and once at the end
    /// so the ledger takes one write rather than one per frame.
    var onResize: ((UInt32, _ final: Bool) -> Void)?
    var onFocusPane: ((String) -> Void)?
    var onHeaderDoubleClick: (() -> Void)?
    /// Dragging the header reorders the strip (PRD §7.2). `x` is in the strip's
    /// coordinate space; `final` marks the drop.
    var onHeaderDrag: ((_ x: CGFloat, _ final: Bool) -> Void)?

    /// The header's overflow menu (`⋯`). These are the lane actions that already
    /// exist as `Command`s; the menu is a mouse-reachable path to them for the
    /// lane under the pointer rather than the focused one.
    ///
    /// Every one is optional and every menu item is disabled while its callback
    /// is nil, so a lane whose owner has not connected them shows a greyed-out
    /// menu instead of crashing.
    var onTogglePin: (() -> Void)?
    var onSetProjectTag: (() -> Void)?
    var onToggleSpan: (() -> Void)?
    /// ADR-0007's dangerous one: reshapes the PTY for every client of the
    /// session. Whoever connects this owes the user a confirmation first.
    var onClaimSession: (() -> Void)?
    var onCloseLane: (() -> Void)?

    /// What the drag handle is currently asking for. The parent reads it during
    /// a live resize; the ledger only hears about it on the drop.
    private(set) var desiredWidth: CGFloat = 0
    /// A spanned lane may be twice as wide (PRD §13 Phase 3), so this is per
    /// lane rather than a constant.
    var widthBounds: ClosedRange<UInt32> = 420...900

    init(lane: Lane, widthBounds: ClosedRange<UInt32>) {
        self.laneId = lane.id
        self.widthBounds = widthBounds
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = Theme.laneBackground.cgColor
        layer?.borderColor = Theme.laneBorder.cgColor
        layer?.borderWidth = Theme.borderWidth
        // Square. Explicitly, so nobody "improves" it later.
        layer?.cornerRadius = 0

        // Frame-positioned, deliberately. `StripContentView` lays lanes out by
        // summing widths (ADR-0004), so the lane's own frame is set from
        // outside. Leaving this false would hand placement to Auto Layout, which
        // has nothing pinning the height and collapses every lane to its header
        // — the whole strip becomes a row of 28pt bars with no panes in it.
        translatesAutoresizingMaskIntoConstraints = true
        frame.size.width = CGFloat(lane.widthPt)

        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = Theme.borderWidth
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        resizeHandle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(stack)
        addSubview(resizeHandle)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.laneHeaderHeight),

            stack.topAnchor.constraint(equalTo: header.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),

            resizeHandle.topAnchor.constraint(equalTo: topAnchor),
            resizeHandle.bottomAnchor.constraint(equalTo: bottomAnchor),
            resizeHandle.trailingAnchor.constraint(equalTo: trailingAnchor),
            resizeHandle.widthAnchor.constraint(equalToConstant: 6),
        ])

        resizeHandle.onDrag = { [weak self] delta, final in
            guard let self else { return }
            let next = UInt32(max(Double(self.widthBounds.lowerBound),
                                  min(Double(self.widthBounds.upperBound),
                                      Double(self.desiredWidth) + delta)))
            self.desiredWidth = CGFloat(next)
            self.onResize?(next, final)
        }
        header.onDoubleClick = { [weak self] in self?.onHeaderDoubleClick?() }
        header.onDrag = { [weak self] x, final in self?.onHeaderDrag?(x, final) }
        // The header reads the lane's callbacks through this at click time
        // rather than copying them: the strip connects them after `init`, and
        // reconnects them when it recycles this view onto a different lane. It
        // also lets the menu grey out an action nobody has connected.
        header.actions = self

        apply(lane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Adopt the latest session telemetry, so the header can show what the
    /// attached session is doing.
    func applyTelemetry(_ telemetry: [String: SessionTelemetry]) {
        let sessionId = currentSessionId
        header.telemetry = sessionId.flatMap { telemetry[$0] }
    }

    /// The Relay session this lane's first pty pane is attached to.
    var currentSessionId: String?

    /// Adopt a new snapshot of this lane. Called on every mutation that touches
    /// it, so it does the least work that produces the right result: the header
    /// is cheap to rebuild, the pane views are not and are reused by id.
    func apply(_ lane: Lane) {
        laneId = lane.id
        currentSessionId = lane.panes.first(where: { $0.kind == .pty })?.relaySessionId
        desiredWidth = CGFloat(lane.widthPt)
        header.apply(lane)
    }

    /// Install the view for a pane, or take one out. The lane owns arrangement;
    /// the caller owns what a pane view actually is, because a terminal and a
    /// web view have nothing in common but a rectangle.
    func setPaneView(_ view: NSView?, for paneId: String, at position: Int) {
        if let existing = paneViews[paneId] {
            guard existing !== view else { return }
            stack.removeArrangedSubview(existing)
            existing.removeFromSuperview()
            paneViews[paneId] = nil
        }
        guard let view else { return }
        paneViews[paneId] = view
        let index = min(position, stack.arrangedSubviews.count)
        stack.insertArrangedSubview(view, at: index)
    }

    func paneView(for paneId: String) -> NSView? { paneViews[paneId] }

    var installedPaneIds: Set<String> { Set(paneViews.keys) }

    /// Remove every pane view, for when the lane scrolls far enough off-screen
    /// that the strip is recycling it.
    func clearPaneViews() {
        for (_, view) in paneViews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        paneViews.removeAll()
    }

    // MARK: - focus and flash

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            layer?.borderColor = (isFocused ? Theme.accent : Theme.laneBorder).cgColor
            layer?.borderWidth = isFocused ? 2 : Theme.borderWidth
            header.isFocused = isFocused
        }
    }

    /// PRD §7.5 — "flash the lane border 300 ms" after search-to-scroll, so the
    /// eye lands on the lane the strip just scrolled to.
    func flash() {
        guard let layer else { return }
        let animation = CABasicAnimation(keyPath: "borderColor")
        animation.fromValue = Theme.accent.cgColor
        animation.toValue = (isFocused ? Theme.accent : Theme.laneBorder).cgColor
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let width = CABasicAnimation(keyPath: "borderWidth")
        width.fromValue = 3
        width.toValue = isFocused ? 2 : Theme.borderWidth
        width.duration = 0.3

        layer.add(animation, forKey: "flashColor")
        layer.add(width, forKey: "flashWidth")
    }
}

/// What the header's overflow menu can ask of the lane it sits on.
///
/// A protocol rather than five copied closures so the menu can tell the
/// difference between "this action is not connected" and "this action does
/// nothing", and grey the item out in the first case.
@MainActor
protocol LaneHeaderActions: AnyObject {
    var onTogglePin: (() -> Void)? { get }
    var onSetProjectTag: (() -> Void)? { get }
    var onToggleSpan: (() -> Void)? { get }
    var onClaimSession: (() -> Void)? { get }
    var onCloseLane: (() -> Void)? { get }
}

extension LaneView: LaneHeaderActions {}

/// The lane's top strip — and the whole of a pane's chrome.
///
/// Left to right: a status square, the kind glyph, the agent-state glyph, the
/// pin marker, the title; then right-aligned, a throughput/age badge, the
/// working directory, and the overflow menu. That is the bar's header plus the
/// kind glyph, in Max Pane's vocabulary: squares rather than dots, one accent
/// rather than a palette, and a hard rule under it rather than a rounded band.
///
/// Laid out by hand rather than with constraints, for two reasons. The
/// truncation policy — the path gives way to the title down to a floor, then
/// both truncate, and the badge leaves before either does — is not expressible
/// in compression priorities. And this row is re-laid for every visible lane on
/// every telemetry tick; at 150 lanes the constraint solver is not worth
/// inviting.
@MainActor
final class LaneHeaderView: NSView {
    private let kindGlyph = NSTextField(labelWithString: "")
    private let chip = NSTextField(labelWithString: "")
    private let pin = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let overflow = LaneHeaderMenuButton()

    var onDoubleClick: (() -> Void)?
    /// `(x in the superview's superview, isFinal)`.
    var onDrag: ((CGFloat, Bool) -> Void)?

    /// The lane, for the overflow menu's actions. Weak and read at click time:
    /// the owner connects its callbacks after the header exists, and a nil
    /// callback greys its item out instead of crashing.
    weak var actions: (any LaneHeaderActions)?

    /// What the attached session is doing, when there is one. Set on every
    /// registry tick — once a second, so "6s" can become "7s" — which is why
    /// `rebuild` compares the rendered model rather than the telemetry: the
    /// value is unchanged on most ticks but the age it prints is not.
    var telemetry: SessionTelemetry? { didSet { rebuild() } }

    private var lane: Lane?
    private var model = LaneHeaderModel()
    private var dragging = false
    private var statusSquare = NSRect.zero

    /// JetBrains Mono is monospaced, so one measurement is the whole metric: how
    /// many characters fit in a field is width ÷ this, exactly. The path and the
    /// badge sit a point smaller than the title — they are reference material,
    /// not the headline — so they have their own cell width, and mixing the two
    /// up costs the path a character in every lane.
    private static let font = Theme.mono(11)
    private static let smallFont = Theme.mono(10)
    private static let advance: CGFloat = cellWidth(of: font)
    private static let smallAdvance: CGFloat = cellWidth(of: smallFont)

    private static func cellWidth(of font: NSFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font]).width
    }

    private let leftInset: CGFloat = 8
    /// Clears the 6pt resize handle that sits on top of the lane's right edge.
    private let rightInset: CGFloat = 8
    private let gap: CGFloat = 8
    private let overflowWidth: CGFloat = 18

    var isFocused: Bool = false {
        didSet {
            guard isFocused != oldValue else { return }
            title.textColor = isFocused ? .labelColor : Theme.dimText
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        kindGlyph.font = Theme.mono(11, weight: .medium)
        chip.alignment = .center
        chip.wantsLayer = true
        // Square, like everything else. A chip with a radius is a pill, and a
        // pill is the RelayTTY card this app deliberately is not.
        chip.layer?.cornerRadius = 0
        title.font = Self.font
        title.lineBreakMode = .byTruncatingTail
        title.textColor = Theme.dimText
        badge.font = Self.smallFont
        badge.alignment = .right
        // The path is pre-fitted by `LaneHeaderPath`, which drops whole
        // components; AppKit's own tail truncation would undo that decision.
        path.font = Self.smallFont
        path.textColor = Theme.dimText
        path.alignment = .right
        path.lineBreakMode = .byClipping
        pin.font = Self.smallFont
        pin.alignment = .center
        // Neutral, not accent. Pinning is structural — it says this lane is
        // never evicted — and an orange mark for it would spend the one colour
        // that has to keep meaning "this agent is waiting on you".
        pin.textColor = .labelColor

        overflow.onPress = { [weak self] in self?.showOverflowMenu() }

        for v in [kindGlyph, chip, pin, title, badge, path] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        overflow.translatesAutoresizingMaskIntoConstraints = true
        addSubview(overflow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func apply(_ lane: Lane) {
        self.lane = lane
        rebuild()
    }

    // MARK: - content

    private func rebuild() {
        guard let lane else { return }
        let next = LaneHeaderModel(lane: lane, telemetry: telemetry)
        guard next != model else { return }
        model = next

        kindGlyph.stringValue = Theme.glyph(for: model.kind)
        // The orange $ marks a live terminal and nothing else.
        // Not the accent: every terminal lane carries this glyph, so tinting it
        // orange spends the alarm colour on the most routine state there is.
        kindGlyph.textColor = (model.kind == .pty && model.isLive) ? Theme.flowing : Theme.dimText
        applyChip()
        pin.stringValue = model.pinned ? "▪" : ""
        title.stringValue = model.title
        badge.stringValue = model.badge
        // Throughput is the thing that is changing right now, so it gets the
        // accent; a quiet lane's age is reference material and stays dim.
        badge.textColor = model.badgeIsThroughput ? Theme.flowing : Theme.dimText
        toolTip = model.tooltip.isEmpty ? nil : model.tooltip

        needsLayout = true
        needsDisplay = true
    }

    /// The agent-state chip: `BLOCKED`, `WORKING`, `DONE`, `EXITED`, and nothing
    /// at all for idle and unknown. RelayTTY renders nothing for those two and
    /// is right to — a chip on every header is a chip nobody reads, and this one
    /// has to survive being one of ten.
    ///
    /// **Blocked is filled; focus is an outline.** The focused lane wears a 2pt
    /// Signal Orange border around the whole column, and BLOCKED is Signal
    /// Orange too, so the two could be confused. They are not, because they use
    /// different channels: attention is a solid orange block *inside* the header
    /// with a word in it, focus is a hairline *around* the column. A focused
    /// idle lane has no orange anywhere inside it; a blocked unfocused lane has
    /// a grey outline and an orange block. The focused header therefore gets a
    /// neutral lift rather than the accent wash it first had — an orange-tinted
    /// header on a focused idle lane was exactly the collision.
    private func applyChip() {
        guard let state = model.state, state.hasChip else {
            chip.stringValue = ""
            chip.layer?.backgroundColor = NSColor.clear.cgColor
            chip.layer?.borderWidth = 0
            return
        }
        let colour = Theme.agentStateColor(state)
        if chipFits {
            chip.stringValue = state.chipText
            chip.font = Theme.mono(9, weight: .bold)
            if state == .blocked {
                // The only filled thing in the header, because it is the only
                // thing worth interrupting someone for.
                chip.layer?.backgroundColor = colour.cgColor
                chip.layer?.borderWidth = 0
                chip.textColor = .black
            } else {
                chip.layer?.backgroundColor = NSColor.clear.cgColor
                chip.layer?.borderColor = colour.withAlphaComponent(0.6).cgColor
                chip.layer?.borderWidth = 1
                chip.textColor = colour
            }
        } else {
            // Too narrow for a word. The glyph keeps the colour and the meaning
            // and costs one cell; `!` for blocked is still the loudest thing in
            // the row.
            chip.stringValue = state.glyph
            chip.font = Theme.mono(11, weight: .bold)
            chip.layer?.backgroundColor = NSColor.clear.cgColor
            chip.layer?.borderWidth = 0
            chip.textColor = colour
        }
    }

    /// Whether the last layout had room for words rather than a glyph. Decided
    /// in `layout`, because it depends on what the title and path need.
    private var chipFits = true

    // MARK: - layout

    override func layout() {
        super.layout()
        let advance = Self.advance
        let mid = bounds.midY

        var x = leftInset
        let square: CGFloat = 7
        statusSquare = NSRect(x: x, y: (bounds.height - square) / 2, width: square, height: square)
        x += square + 6

        let cell = ceil(advance)
        kindGlyph.frame = NSRect(x: x, y: mid - 8, width: cell + 2, height: 16)
        x += cell + 2

        let overflowX = bounds.width - rightInset - overflowWidth
        overflow.frame = NSRect(x: overflowX, y: (bounds.height - 18) / 2, width: overflowWidth, height: 18)

        var rightEdge = overflowX - 6
        // The pin sits beside the `⋯` that toggles it rather than beside the
        // status square, which is also a small orange square: three squares in a
        // row on the left read as one indicator with a bug in it.
        if model.pinned {
            // Measured rather than assumed to be one cell: `▪` is not in
            // JetBrains Mono, so it comes from a fallback face at its own width
            // and a one-cell box clips it away to nothing.
            let pinWidth = width(of: pin.stringValue, font: Self.smallFont) + 2
            pin.frame = NSRect(x: rightEdge - pinWidth, y: mid - 8, width: pinWidth, height: 16)
            rightEdge -= pinWidth + 6
        } else {
            pin.frame = NSRect(x: rightEdge, y: mid - 8, width: 0, height: 16)
        }
        // The chip sits at a fixed x on every lane, so a strip of ten headers
        // has one column your eye runs along rather than ten places to look.
        let chipX = x
        var chipWidth: CGFloat = 0
        if let state = model.state, state.hasChip {
            let wordWidth = width(of: state.chipText, font: Theme.mono(9, weight: .bold)) + 10
            let glyphWidth = cell + 4
            // Words when the title and the path can still both be read beside
            // them; a coloured glyph when they cannot.
            let roomForWords = rightEdge - x - wordWidth - gap
                >= min(width(of: model.title, font: Self.font), advance * 10) + Self.smallAdvance * 12
            chipFits = roomForWords
            chipWidth = roomForWords ? wordWidth : glyphWidth
            applyChip()
            chip.frame = NSRect(x: chipX, y: mid - 7, width: chipWidth, height: 14)
            x += chipWidth + 6
        } else {
            // A lane with nothing to report gets the space back rather than a
            // placeholder that means nothing.
            chip.frame = NSRect(x: chipX, y: mid - 7, width: 0, height: 14)
        }

        let available = max(0, rightEdge - x)

        let titleWanted = width(of: model.title, font: Self.font)
        let pathWanted = width(of: LaneHeaderPath.abbreviate(model.path), font: Self.smallFont)
        let badgeWanted = model.badge.isEmpty ? 0 : width(of: model.badge, font: Self.smallFont)

        // The badge is the first thing to go: it is the only field whose
        // information is also in the sidebar, and losing it keeps the title and
        // the path — which exist nowhere else — legible for longer.
        let showBadge = badgeWanted > 0
            && available >= titleWanted + pathWanted + badgeWanted + gap * 3
        let reserved = showBadge ? badgeWanted + gap : 0
        let forTitleAndPath = max(0, available - reserved - gap)

        // The path yields to the title first, but only down to a floor of about
        // twelve characters — below that it stops being an identifier and
        // becomes decoration, and the title can start truncating instead.
        let pathFloor = min(pathWanted, Self.smallAdvance * 12)
        var pathBudget = min(pathWanted, max(forTitleAndPath - titleWanted, pathFloor))
        // ...and the title always keeps six characters, so a pathological path
        // can never erase it entirely.
        pathBudget = min(pathBudget, max(0, forTitleAndPath - advance * 6))

        let fitted = LaneHeaderPath.fit(
            model.path, maxChars: Int((pathBudget / Self.smallAdvance).rounded(.down)))
        path.stringValue = fitted
        // Dropping a whole component can leave the field wider than the string
        // that ended up in it. Hand the slack back to the title rather than
        // parking it between the badge and the path, where it reads as a column
        // that is not there.
        let pathWidth = min(pathBudget, width(of: fitted, font: Self.smallFont))
        let titleWidth = max(0, forTitleAndPath - pathWidth)

        title.frame = NSRect(x: x, y: mid - 9, width: titleWidth, height: 18)
        badge.frame = NSRect(
            x: rightEdge - pathWidth - reserved, y: mid - 8,
            width: showBadge ? badgeWanted : 0, height: 16)
        badge.isHidden = !showBadge
        path.frame = NSRect(x: rightEdge - pathWidth, y: mid - 8, width: pathWidth, height: 16)

        // The status square is drawn, not a subview, and its rect is only known
        // here. Without this a lane that lays out after its first `draw` — every
        // freshly materialised lane, as it happens — paints the square at
        // `.zero` and never repaints it, so the one indicator the header exists
        // for is simply missing.
        needsDisplay = true
    }

    private func width(of string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // A neutral lift, deliberately not an accent wash. Focus is already the
        // 2pt Signal Orange border around the column; tinting the header orange
        // as well made a focused idle lane look like a blocked one, and blocked
        // is the only thing in this app allowed to shout in orange.
        if isFocused {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
            bounds.fill()
        }

        // Liveness, as a square — the bar's green dot, in a vocabulary with no
        // round corners. Filled means running; outlined means gone, and the chip
        // beside it says how.
        //
        // Green, not orange, and this is the point: every live lane would
        // otherwise carry an orange mark, and an accent that appears on all ten
        // lanes cannot also mean "this one needs you". The colour is the theme's
        // own — the one non-accent state colour it already defines — rather than
        // a new one invented here.
        if model.isLive {
            Theme.agentStateColor(.working).setFill()
            statusSquare.fill()
        } else {
            Theme.dimText.setStroke()
            let inset = statusSquare.insetBy(dx: 0.5, dy: 0.5)
            let box = NSBezierPath(rect: inset)
            box.lineWidth = 1
            box.stroke()
        }

        // A hairline under the header, full width. A rule, not a rounded band.
        (isFocused ? NSColor.labelColor.withAlphaComponent(0.35) : Theme.laneBorder).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth).fill()
    }

    // MARK: - overflow menu

    /// Right-clicking anywhere in the header opens the same menu the `⋯` does —
    /// the button is the discoverable path, the right-click is the fast one.
    override func menu(for event: NSEvent) -> NSMenu? { overflowMenu() }

    private func showOverflowMenu() {
        overflowMenu().popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: overflow.bounds.height + 2),
            in: overflow)
    }

    private func overflowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Titles and keys come from `Command` so this menu cannot drift from the
        // menu bar, and so it teaches the shortcut rather than replacing it.
        add(to: menu, model.pinned ? "Unpin Lane" : Command.togglePinned.title,
            command: .togglePinned, action: #selector(menuTogglePin), enabled: actions?.onTogglePin != nil)
        add(to: menu, "Set Project Tag…",
            command: nil, action: #selector(menuSetProjectTag), enabled: actions?.onSetProjectTag != nil)
        add(to: menu, Command.toggleSpan.title,
            command: .toggleSpan, action: #selector(menuToggleSpan), enabled: actions?.onToggleSpan != nil,
            state: (lane?.span ?? 1) > 1 ? .on : .off)

        menu.addItem(.separator())
        add(to: menu, "Copy Working Directory",
            command: nil, action: #selector(menuCopyPath), enabled: !model.path.isEmpty)

        if model.isTerminal {
            menu.addItem(.separator())
            // ADR-0007: this reshapes the PTY for every other client attached to
            // the session, including a phone. It is last, alone, and behind a
            // confirmation, which is the whole point.
            add(to: menu, Command.claimSession.title,
                command: .claimSession, action: #selector(menuClaimSession),
                enabled: actions?.onClaimSession != nil)
        }

        menu.addItem(.separator())
        add(to: menu, Command.closeLane.title,
            command: .closeLane, action: #selector(menuCloseLane), enabled: actions?.onCloseLane != nil)
        return menu
    }

    private func add(
        to menu: NSMenu, _ title: String, command: Command?, action: Selector,
        enabled: Bool, state: NSControl.StateValue = .off
    ) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        if let command {
            let (key, mask) = command.shortcut
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = mask
        }
        item.target = self
        item.isEnabled = enabled
        item.state = state
        item.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.mono(12),
            .foregroundColor: enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor,
        ])
    }

    @objc private func menuTogglePin() { actions?.onTogglePin?() }
    @objc private func menuSetProjectTag() { actions?.onSetProjectTag?() }
    @objc private func menuToggleSpan() { actions?.onToggleSpan?() }
    @objc private func menuClaimSession() { actions?.onClaimSession?() }
    @objc private func menuCloseLane() { actions?.onCloseLane?() }

    /// No callback needed: the header already holds the only untruncated copy of
    /// the path in the UI, so it may as well be the thing that hands it over.
    @objc private func menuCopyPath() {
        guard !model.path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path, forType: .string)
    }

    // MARK: - dragging

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            dragging = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let strip = superview?.superview else { return }
        onDrag?(strip.convert(event.locationInWindow, from: nil).x, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging, let strip = superview?.superview else {
            dragging = false
            return
        }
        dragging = false
        onDrag?(strip.convert(event.locationInWindow, from: nil).x, true)
    }
}

/// The `⋯` at the end of the header.
///
/// A borderless button rather than an image button so the glyph stays in the
/// same typeface as everything else in the row, and so hover can turn it orange
/// without an asset.
@MainActor
final class LaneHeaderMenuButton: NSView {
    var onPress: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) { onPress?() }

    override func draw(_ dirtyRect: NSRect) {
        let glyph = "⋯" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(13, weight: .bold),
            .foregroundColor: hovering ? Theme.accent : Theme.dimText,
        ]
        let size = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// The 6pt strip along a lane's right edge that resizes it (PRD §8).
@MainActor
final class LaneResizeHandle: NSView {
    /// `(delta in points, isFinal)`.
    var onDrag: ((Double, Bool) -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        lastX = convert(event.locationInWindow, from: nil).x
    }

    override func mouseDragged(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        onDrag?(Double(x - lastX), false)
    }

    override func mouseUp(with event: NSEvent) {
        // One ledger write per drag, not one per frame.
        onDrag?(0, true)
    }
}
