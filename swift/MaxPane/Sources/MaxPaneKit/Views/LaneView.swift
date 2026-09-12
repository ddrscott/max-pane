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

/// The lane's top strip: kind glyph, title, project tag.
///
/// The tag is a chip, not a coloured edge — category through content, which also
/// happens to be the only thing that survives being one of 150 columns.
@MainActor
final class LaneHeaderView: NSView {
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let tagChip = NSTextField(labelWithString: "")
    private let pin = NSTextField(labelWithString: "")

    var onDoubleClick: (() -> Void)?
    /// What the attached session is doing, when there is one.
    var telemetry: SessionTelemetry? { didSet { needsDisplay = true } }
    /// `(x in the superview's superview, isFinal)`.
    var onDrag: ((CGFloat, Bool) -> Void)?

    private var dragging = false

    var isFocused: Bool = false {
        didSet { title.textColor = isFocused ? .labelColor : Theme.dimText }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        glyph.font = Theme.mono(11, weight: .medium)
        glyph.alignment = .center
        title.font = Theme.mono(11)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = Theme.dimText
        tagChip.font = Theme.mono(10)
        tagChip.textColor = Theme.dimText
        tagChip.alignment = .right
        tagChip.lineBreakMode = .byTruncatingHead
        pin.font = Theme.mono(10)
        pin.textColor = Theme.accent

        for v in [glyph, pin, title, tagChip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 12),

            pin.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 2),
            pin.centerYAnchor.constraint(equalTo: centerYAnchor),
            pin.widthAnchor.constraint(equalToConstant: 8),

            title.leadingAnchor.constraint(equalTo: pin.trailingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            tagChip.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            tagChip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tagChip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tagChip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A hairline under the header, full width. A rule, not a rounded band.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth).fill()
    }

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

    func apply(_ lane: Lane) {
        let kind: PaneGlyph = lane.panes.first.map {
            switch $0.kind {
            case .pty: return .pty
            case .web: return .web
            case .placeholder: return .placeholder
            }
        } ?? .web

        glyph.stringValue = Theme.glyph(for: kind)
        // The orange $ marks a live terminal and nothing else.
        glyph.textColor = (kind == .pty) ? Theme.accent : Theme.dimText

        title.stringValue = lane.title
            ?? lane.panes.first?.url.flatMap { URL(string: $0)?.host }
            ?? "untitled"

        tagChip.stringValue = lane.projectRoot.map { ($0 as NSString).lastPathComponent } ?? ""
        pin.stringValue = lane.pinned ? "▪" : ""
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
