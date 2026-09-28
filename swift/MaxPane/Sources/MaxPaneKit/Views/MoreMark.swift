import AppKit

/// `⋯`: three square dots, and the menu behind them.
///
/// A server's sidebar header folds on a click like every other header, so its
/// actions — Color ▸, Rename…, Disable, Server Settings… — needed a door of
/// their own that is not a right-click you have to know about. This is it.
///
/// Like `SpeakerMark` it is a button that swallows its own press, so the row
/// under it never folds. It is drawn only while it is `shown` (the header is
/// under the pointer, or its server is not answering and the way to fix that
/// should be in sight); the change fades on `Motion` timing, and lands
/// without a middle under Reduce Motion.
@MainActor
final class MoreMark: NSView {
    static let size: CGFloat = 18

    /// Whether the dots are drawn. The slot is kept either way, so nothing
    /// beside it moves when they come and go.
    var shown = false {
        didSet {
            guard shown != oldValue else { return }
            Motion.fade(layer)
            needsDisplay = true
        }
    }

    /// Handed the mark itself, to hang the menu from.
    var onPress: ((MoreMark) -> Void)?

    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var pressed = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.size, height: Self.size) }

    /// Grey at rest, one step brighter under the pointer; never a state colour.
    var ink: NSColor { isHovered ? .labelColor : Theme.dimText }

    override func draw(_ dirtyRect: NSRect) {
        guard shown else { return }
        // Three 2 pt squares, 2 pt apart: the house has no round dot.
        let dot: CGFloat = 2, gap: CGFloat = 2
        let width = dot * 3 + gap * 2
        let x0 = ((bounds.width - width) / 2).rounded()
        let y = ((bounds.height - dot) / 2).rounded()
        ink.setFill()
        for i in 0..<3 {
            NSRect(x: x0 + CGFloat(i) * (dot + gap), y: y, width: dot, height: dot).fill()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // Deliberately no `super`: the press ends here, so the header under it
    // never folds.
    override func mouseDown(with event: NSEvent) { pressed = true }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(self)
    }

    override func accessibilityLabel() -> String? { "Server menu" }
    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }
}
