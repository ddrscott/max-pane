import AppKit
import LanedCore

/// The speaker: one glyph, the same wherever a lane is identified.
///
/// `volume-2` while something in the lane is making sound, `volume-x` while it
/// is muted, nothing while it is neither. Grey, one step brighter under the
/// pointer, and never a state colour: sound is not agent state, and the greens
/// and the orange are spent (ADR-0015, ADR-0035).
///
/// It is a button. A click toggles mute, and the press is swallowed here, so
/// whatever it sits on — a sidebar row that selects, a lane header that drags —
/// never hears about it. A right-click opens the volume slider instead of the
/// host's own menu. While it has nothing to show it is not there at all:
/// `hitTest` answers nil and the host gets its clicks back.
@MainActor
final class SpeakerMark: NSView {
    /// At least this, whatever the glyph's size: the owner's 18 pt floor.
    static let minimumHit: CGFloat = 18

    var mark: AudioMark = .silent {
        didSet {
            guard mark != oldValue else { return }
            // Appears, leaves and changes with a fade; never a cut.
            Motion.fade(layer)
            toolTip = mark == .silent ? nil : mark.verb
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    /// The glyph's size in points; the view is laid out at least `minimumHit`.
    var points: CGFloat = 12 { didSet { needsDisplay = true } }

    var onToggle: (() -> Void)?
    /// Right-click. Handed the mark itself, to hang the slider from. Nil
    /// falls back to the host's own menu.
    var onVolume: ((SpeakerMark) -> Void)?

    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var pressed = false

    init(points: CGFloat = 12) {
        self.points = points
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: max(points, Self.minimumHit), height: max(points, Self.minimumHit))
    }

    /// The ink, for tests: grey at rest, one step brighter under the pointer.
    var ink: NSColor { isHovered ? .labelColor : SidebarInk.gone }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon = mark.icon, let image = IconImage.make(icon, points: points, colour: ink) else { return }
        image.draw(in: NSRect(
            x: ((bounds.width - points) / 2).rounded(), y: ((bounds.height - points) / 2).rounded(),
            width: points, height: points))
    }

    // MARK: - a button only while there is something to press

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard mark != .silent, !isHidden else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = mark != .silent }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        if mark != .silent { addCursorRect(bounds, cursor: .pointingHand) }
    }

    // Deliberately no `super`: the press ends here. A sidebar row would
    // select and reveal its lane with it, and a lane header would start a drag.
    override func mouseDown(with event: NSEvent) { pressed = mark != .silent }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        guard pressed, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard mark != .silent, let onVolume else { return super.rightMouseDown(with: event) }
        onVolume(self)
    }

    override func accessibilityLabel() -> String? { mark == .silent ? nil : mark.verb }
    override func accessibilityPerformPress() -> Bool {
        guard mark != .silent else { return false }
        onToggle?()
        return true
    }
}

/// A horizontal slider, 0 to 100, in the house's shapes: a hairline track, a
/// square knob, no capsule. `NSSlider`'s knob is a circle on every style it
/// has.
@MainActor
final class VolumeSlider: NSView {
    /// 0 to 100.
    var value: Int = 100 {
        didSet {
            value = min(max(value, 0), 100)
            if value != oldValue { needsDisplay = true }
        }
    }
    /// Live, on every step of a drag and every arrow key.
    var onChange: ((Int) -> Void)?

    static let knob = NSSize(width: 6, height: 14)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.slider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 22) }
    override var acceptsFirstResponder: Bool { true }

    private var track: NSRect {
        NSRect(x: Self.knob.width / 2, y: (bounds.height / 2 - 1).rounded(),
               width: max(1, bounds.width - Self.knob.width), height: 2)
    }

    /// Where the knob is drawn, for tests.
    var knobRect: NSRect {
        let x = track.minX + track.width * CGFloat(value) / 100
        return NSRect(x: (x - Self.knob.width / 2).rounded(), y: ((bounds.height - Self.knob.height) / 2).rounded(),
                      width: Self.knob.width, height: Self.knob.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.laneBorder.setFill()
        track.fill()
        Theme.dimText.setFill()
        NSRect(x: track.minX, y: track.minY, width: knobRect.midX - track.minX, height: track.height).fill()
        NSColor.labelColor.setFill()
        knobRect.fill()
    }

    /// The value under a point in this view, for the drag and for tests.
    func value(at point: NSPoint) -> Int {
        Int(((point.x - track.minX) / track.width * 100).rounded())
    }

    private func take(_ next: Int) {
        let clamped = min(max(next, 0), 100)
        guard clamped != value else { return }
        value = clamped
        onChange?(clamped)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        take(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseDragged(with event: NSEvent) {
        take(value(at: convert(event.locationInWindow, from: nil)))
    }

    override func keyDown(with event: NSEvent) {
        let step = event.modifierFlags.contains(.shift) ? 10 : 5
        switch event.keyCode {
        case 123, 125: take(value - step)   // ← ↓
        case 124, 126: take(value + step)   // → ↑
        default: super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : -event.scrollingDeltaX
        guard delta != 0 else { return }
        take(value + (delta > 0 ? 1 : -1) * max(1, Int(abs(delta) / 4)))
    }

    override func accessibilityValue() -> Any? { value }
}

/// One pane's volume: a slider, the percentage, and the mute, hung from the
/// speaker that was right-clicked.
///
/// A `Popup` for its square panel, its fade in and out, its Esc and its
/// click-away; anchored rather than centred (`anchorRect`), because it is
/// about a mark and not about the window. ↩ closes it too. Every step of a
/// drag is applied and written at once: there is nothing to confirm.
///
/// Zero is mute, and unmuting from zero returns to the level the slider was at
/// when this opened, not to the 1 % it passed on the way down.
@MainActor
final class VolumePopup: Popup {
    static let size = NSSize(width: 248, height: 56)

    /// The one on screen, so a second right-click replaces it.
    private(set) static weak var current: VolumePopup?

    let paneId: String
    private let center: PaneAudioCenter
    let slider = VolumeSlider()
    let mute = ChromeButton(icon: .volume2)
    private let readout = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var token: UUID?
    private var returnMonitor: Any?
    /// The level to come back to if this slider is taken to zero.
    private var restore: Int

    /// The readout as drawn, for tests.
    var readoutText: String { readout.stringValue }

    /// Hang the slider for `paneId` from `anchor`. Nil when this WebKit cannot
    /// turn a page down: no slider is better than one that does nothing.
    @discardableResult
    static func show(pane paneId: String, title: String, center: PaneAudioCenter, from anchor: NSView) -> VolumePopup? {
        guard WebPaneAudio.volumeIsSupported else { return nil }
        current?.closePopup(animated: false)
        let popup = VolumePopup(paneId: paneId, title: title, center: center)
        if let window = anchor.window {
            popup.anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        }
        current = popup
        popup.present(over: anchor.window)
        return popup
    }

    init(paneId: String, title: String, center: PaneAudioCenter) {
        self.paneId = paneId
        self.center = center
        let state = center.state(of: paneId)
        restore = state.volume
        super.init(size: Self.size, dismissal: .clickAway)

        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        caption.stringValue = title
        caption.font = Theme.mono(9)
        caption.textColor = Theme.dimText
        caption.lineBreakMode = .byTruncatingTail
        readout.font = Theme.mono(11, weight: .medium)
        readout.textColor = .labelColor
        readout.alignment = .right
        mute.isDimmed = false
        mute.onClick = { [weak self] in
            guard let self else { return }
            self.center.toggleMute(pane: self.paneId)
        }
        slider.onChange = { [weak self] value in
            guard let self else { return }
            self.center.setVolume(value, pane: self.paneId, restoring: self.restore)
        }
        for v in [caption, mute, slider, readout] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 7),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

            mute.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 6),
            mute.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
            slider.leadingAnchor.constraint(equalTo: mute.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: mute.centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 22),
            readout.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            readout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            readout.widthAnchor.constraint(equalToConstant: 36),
            readout.centerYAnchor.constraint(equalTo: mute.centerYAnchor),
        ])
        window?.contentView = content
        render(state, animated: false)
        // The mute can change from anywhere while this is up: the sidebar's
        // speaker, ⌃⌘M, `maxpane mute`.
        token = center.observe { [weak self] in
            guard let self else { return }
            self.render(self.center.state(of: self.paneId), animated: true)
        }
    }

    private func render(_ state: PaneAudio, animated: Bool) {
        // A level the person chose is the one to come back to; the zero a
        // drag ends on is not.
        if !state.muted { restore = state.volume }
        let shown = state.effectiveVolume
        if animated, abs(shown - slider.value) > 5 { Motion.fade(slider.layer) }
        slider.value = shown
        readout.stringValue = "\(shown)%"
        mute.icon = state.muted ? .volumeX : .volume2
        mute.toolTip = state.muted ? "Unmute" : "Mute"
    }

    override func popupDidPresent() {
        window?.makeFirstResponder(slider)
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true,
                  event.keyCode == 36 || event.keyCode == 76 else { return event }
            self.closePopup()
            return nil
        }
    }

    override func closePopup(animated: Bool = true, completion: (() -> Void)? = nil) {
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
        token.map(center.stopObserving)
        token = nil
        super.closePopup(animated: animated, completion: completion)
    }
}
