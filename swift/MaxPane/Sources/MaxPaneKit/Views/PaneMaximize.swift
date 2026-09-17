import AppKit
import LanedCore

/// ⇧⌘↩ — one pane over the whole visible strip, and the same key to put it back
/// (iTerm's Maximize Active Pane). See ADR-0019.
///
/// **A view state, not a size.** The lane does not widen, the ledger is not
/// written, and the strip underneath keeps its layout and its scroll offset:
/// the pane's view is lifted out of its lane's stack into `MaximizedPaneView`,
/// which sits over the strip's visible window, and a placeholder holds its slot
/// so the panes it was stacked with keep their heights. "Returns to exactly
/// the frame it had" is then true by construction — that frame was never given
/// to anything else.
///
/// It is the third time a pane is shown larger than its lane (a gallery tile
/// expanded in place, ADR-0011; a page's full screen, ADR-0014), and the rule
/// all three follow is in ADR-0019: the lane's own geometry is never the thing
/// that grows.

// MARK: - the rule

/// What ends a maximize without being asked.
///
/// One rule, held everywhere: **a snapshot that moves focus off the maximized
/// pane, or changes the shape of the strip, restores first.** It is asked of
/// every snapshot in `StripViewController.apply`, so it needs no list of
/// commands and cannot miss one — ⌘[ and ⌘], a click in the sidebar on a
/// BLOCKED session, a lane arriving from ⌘O or from `maxpane run`, ⌘W, a split,
/// a dock, a preset, a gather: each is a snapshot that differs in exactly one
/// of the two ways below. A title, a telemetry tick, a zoom or a page
/// navigating is neither, and leaves the pane where it is.
enum MaximizeRule {
    /// The part of a lane a maximized pane's place depends on.
    struct LaneShape: Equatable {
        var id: String
        var widthPt: UInt32
        var span: UInt32
        var dock: Dock?
        var panes: [String]
    }

    static func shape(_ lanes: [Lane]) -> [LaneShape] {
        lanes.map {
            LaneShape(id: $0.id, widthPt: $0.widthPt, span: $0.span, dock: $0.dock, panes: $0.panes.map(\.id))
        }
    }

    /// Whether going from `before` to `after` takes `paneId` out of maximize.
    static func restores(maximized paneId: String, before: [Lane], after: StripState) -> Bool {
        if after.focusedPaneId != paneId { return true }
        return shape(before) != shape(after.lanes)
    }
}

// MARK: - the slot left behind

/// What stands in a lane's stack where the maximized pane was.
///
/// It exists for the panes beside it: a slot taken out of the stack would hand
/// its height to its siblings, and a terminal that grew for the length of a
/// maximize is a PTY reshaped for every client of it. Covered by the overlay
/// on the strip; visible in a dock, which stays where it is, so it says what
/// happened rather than showing an empty box.
final class MaximizePlaceholderView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerBackgroundColor = Theme.laneBackground
        label.font = Theme.mono(10)
        label.textColor = Theme.dimText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.stringValue = ["maximized", Command.toggleMaximizePane.chords.first?.text]
            .compactMap { $0 }.joined(separator: "  ")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

// MARK: - the overlay

/// The maximized pane's frame: a header row that says so, and the pane.
///
/// The row is the visible sign. Without one a maximized single pane is a strip
/// with one enormous lane and no neighbours, which is what a broken strip looks
/// like. It carries the lane's title, so you know *which* pane, and a
/// `MAXIMIZED` chip in the accent green — outlined on every side and square,
/// the shape every other chip in a header has (ADR-0015). Focus is what the
/// accent means, and a maximized pane always has it. Clicking the chip
/// restores; the key beside it is the one that does the same.
final class MaximizedPaneView: NSView {
    static let barHeight = Theme.laneHeaderHeight

    var onRestore: (() -> Void)?

    private let bar = NSView()
    private let rule = NSView()
    private let title = NSTextField(labelWithString: "")
    private let chip = MaximizedChip()
    private let hint = NSTextField(labelWithString: "")
    private let body = NSView()
    private var pinned: [NSLayoutConstraint] = []
    private(set) weak var paneView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerBackgroundColor = Theme.laneBackground
        layerBorderColor = Theme.laneBorder
        layer?.borderWidth = Theme.borderWidth
        layer?.cornerRadius = 0

        title.font = Theme.mono(11)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hint.font = Theme.mono(10)
        hint.textColor = Theme.dimText
        rule.wantsLayer = true
        rule.layerBackgroundColor = Theme.laneBorder
        chip.onPress = { [weak self] in self?.onRestore?() }

        for view in [bar, body] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        for view in [title, chip, hint, rule] {
            view.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),
            body.topAnchor.constraint(equalTo: bar.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),

            title.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -10),
            hint.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            chip.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -8),
            chip.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: Theme.borderWidth),
        ])
        setAccessibilityLabel("Maximized pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    var titleText: String {
        get { title.stringValue }
        set { title.stringValue = newValue }
    }

    var chipText: String { chip.text }

    /// Take the pane's view. Within one window, so a terminal keeps its surface
    /// and a page keeps playing — the same reparenting a dock and a gallery
    /// tile already rely on.
    func show(_ view: NSView) {
        hint.stringValue = Command.toggleMaximizePane.chords.first?.text ?? ""
        release()
        paneView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(view)
        pinned = [
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ]
        NSLayoutConstraint.activate(pinned)
    }

    /// Let go of the pane's view without unparenting it: whoever takes it next
    /// re-parents it, and a view that never leaves the window never loses what
    /// it was showing.
    func release() {
        NSLayoutConstraint.deactivate(pinned)
        pinned = []
        paneView = nil
    }
}

/// `MAXIMIZED`, outlined in the accent on all four sides, square.
final class MaximizedChip: NSView {
    var onPress: (() -> Void)?
    let text = "MAXIMIZED"
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layerBorderColor = Theme.accent.withAlphaComponent(0.6)
        label.stringValue = text
        label.font = Theme.mono(9, weight: .bold)
        label.textColor = Theme.accent
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        toolTip = "Restore Pane"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Restore Pane")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func mouseDown(with event: NSEvent) { onPress?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// MARK: - the mechanism

/// Lifts one pane's view over the strip and puts it back.
///
/// Knows nothing about the ledger, commands or focus: it is handed a view and
/// the lane it stands in, and asks its owner three questions through closures.
/// That is what lets a test drive it with two plain views in a window.
///
/// **Motion.** The overlay's frame is final the moment it is on screen and its
/// *layer* eases from the rect the pane had — the gallery's way of growing a
/// tile (`GalleryLayout.moveTransforms`), on `Motion.lane` and the same curve,
/// and not at all under Reduce Motion. So the pane inside is laid out once per
/// toggle, not once per frame: a terminal reflows once going up, and once
/// coming down when the view lands back in its slot.
@MainActor
final class PaneMaximizer {
    enum Phase { case maximized, restoring }

    private(set) var paneId: String?
    private(set) var phase: Phase?
    let overlay = MaximizedPaneView()

    /// The view the overlay is a subview of: the strip controller's own.
    private unowned let host: NSView
    /// Where the overlay goes, in `host`'s coordinates.
    var viewportRect: () -> CGRect = { .zero }
    /// The lane view a pane stands in right now, if it has one.
    var laneView: (_ paneId: String) -> LaneView? = { _ in nil }
    /// Whether the ledger still has the pane. One that was closed while it was
    /// maximized has no slot to go back to.
    var paneExists: (_ paneId: String) -> Bool = { _ in true }
    /// The pane's view is back in its lane, or gone.
    var onLanded: ((_ paneId: String) -> Void)?

    private var placeholder: MaximizePlaceholderView?
    private var paneView: NSView?
    private var timer: MotionTimer?

    init(host: NSView) { self.host = host }

    /// The pane is over the strip and staying there.
    var isMaximized: Bool { phase == .maximized }
    /// The overlay is on screen — maximized, or on its way back.
    var isActive: Bool { phase != nil }

    /// What a lane's stack should hold for `paneId` while its real view is in
    /// the overlay: a lane view rebuilt mid-maximize must not take it back.
    func placeholder(for paneId: String) -> NSView? {
        guard phase != nil, paneId == self.paneId else { return nil }
        if placeholder == nil { placeholder = MaximizePlaceholderView() }
        return placeholder
    }

    func contains(windowPoint: NSPoint) -> Bool {
        guard phase != nil, overlay.superview != nil else { return false }
        return overlay.bounds.contains(overlay.convert(windowPoint, from: nil))
    }

    // MARK: up

    func maximize(paneId: String, view: NSView, in laneView: LaneView, title: String, animated: Bool) {
        land()
        guard let index = laneView.arrangedPaneIds.firstIndex(of: paneId) else { return }
        let from = view.superview == nil ? nil : view.convert(view.bounds, to: host)

        self.paneId = paneId
        phase = .maximized
        paneView = view
        let slot = MaximizePlaceholderView()
        placeholder = slot
        // The slot first, so the stack never has a pass with this pane missing
        // and its siblings taking its height.
        laneView.setPaneView(slot, for: paneId, at: index)

        overlay.alphaValue = 1
        overlay.titleText = title
        overlay.frame = viewportRect()
        overlay.show(view)
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        overlay.layoutSubtreeIfNeeded()

        if animated, let from { animate(from: from, reversed: false) }
    }

    /// Follow the strip's visible window: a resized window, a dragged sidebar.
    func layout() {
        guard phase == .maximized else { return }
        let rect = viewportRect()
        if overlay.frame != rect { overlay.frame = rect }
    }

    // MARK: down

    func restore(animated: Bool) {
        guard phase == .maximized, let paneId else { return }
        let exists = paneExists(paneId)
        // Where it is going: its slot, wherever the strip has that now.
        let slot: CGRect? = placeholder.flatMap { $0.window == nil ? nil : $0.convert($0.bounds, to: host) }
        guard animated, !Motion.isReduced, host.window != nil, !exists || slot != nil else {
            phase = .restoring
            land()
            return
        }
        phase = .restoring
        let duration: TimeInterval
        if exists, let slot {
            animate(from: slot, reversed: true)
            duration = Motion.lane
        } else {
            // The pane was closed from under it. There is no slot to shrink
            // into, so it leaves the way a pane leaves a stack: it fades.
            duration = Motion.pane
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = Motion.easeOutTiming
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            overlay.layer?.add(fade, forKey: Self.animationKey)
        }
        // The layer animation draws; this is only its end. Core Animation's own
        // completion does not fire for a layer no screen is showing, and the
        // landing must happen regardless.
        timer = Motion.run(duration: duration, step: { _ in }) { [weak self] in self?.land() }
    }

    /// Finish a restore now: the view back in its slot, the overlay gone.
    /// Idempotent, and what anything that cannot wait for the animation calls.
    func land() {
        guard phase == .restoring, let paneId else { return }
        timer?.cancel()
        timer = nil
        overlay.layer?.removeAnimation(forKey: Self.animationKey)
        let view = paneView
        overlay.release()
        if let view {
            if paneExists(paneId), let laneView = laneView(paneId),
               laneView.paneView(for: paneId) is MaximizePlaceholderView,
               let index = laneView.arrangedPaneIds.firstIndex(of: paneId) {
                laneView.setPaneView(view, for: paneId, at: index)
                laneView.layoutSubtreeIfNeeded()
            } else {
                // No slot on screen: the lane scrolled out of the strip's
                // window, or the pane is gone. A lane that comes back installs
                // its controller's view like any other.
                view.removeFromSuperview()
            }
        }
        overlay.removeFromSuperview()
        placeholder = nil
        paneView = nil
        phase = nil
        self.paneId = nil
        onLanded?(paneId)
    }

    // MARK: motion

    private static let animationKey = "maximizeMove"

    /// Ease the overlay's layer between `rect` and its own frame. Up: from the
    /// pane's old rect to where it now is. Down: from where it is to its slot,
    /// held there until `land` takes it off screen.
    private func animate(from rect: CGRect, reversed: Bool) {
        guard !Motion.isReduced, let layer = overlay.layer, rect.width > 0, rect.height > 0 else { return }
        let ends = GalleryLayout.moveTransforms(
            from: rect, to: layer.frame, position: layer.position, model: layer.transform)
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: reversed ? ends.end : ends.start)
        animation.toValue = NSValue(caTransform3D: reversed ? ends.start : ends.end)
        animation.duration = Motion.lane
        animation.timingFunction = Motion.easeOutTiming
        if reversed {
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.add(animation, forKey: Self.animationKey)
    }
}
