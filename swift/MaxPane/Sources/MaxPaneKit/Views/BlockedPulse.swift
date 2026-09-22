import AppKit

/// BLOCKED, moving: the one thing a green family cannot say with hue alone.
///
/// Focus, working and blocked are all green now (ADR-0015), so BLOCKED gets a
/// channel the other two never use: a slow breath between full and reduced
/// opacity. It is Core Animation on the render server, not a timer, so ten
/// blocked lanes cost no main-thread work, and it is never *off* — the floor is
/// well above zero, so a glance at the wrong moment still finds the mark.
///
/// **Phase-locked to the clock.** A sidebar row is rebuilt as a new cell when
/// its age ticks, and a pulse restarted from full on every rebuild would twitch
/// once a second. Each animation starts at the phase the wall clock is in, so a
/// replacement picks up exactly where its predecessor was — and every blocked
/// mark on screen breathes together rather than ten out of step.
///
/// Under Reduce Motion there is no animation at all: the mark is steady at full
/// strength, and BLOCKED is told apart by brightness plus its filled mark.
@MainActor
enum BlockedPulse {
    static let key = "maxpane.blocked-pulse"
    /// One full breath, out and back.
    static let period: CFTimeInterval = 1.8
    /// The reduced end: dimmer, never gone.
    static let floor: Float = 0.6

    /// Read per call, like `Motion.isReduced`, and replaceable so a test can
    /// ask for either answer without changing the owner's system preference.
    static var isReduced: () -> Bool = { Motion.isReduced }

    static func animation(now: CFTimeInterval = CACurrentMediaTime()) -> CABasicAnimation {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = Float(1)
        pulse.toValue = floor
        pulse.duration = period / 2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        pulse.timeOffset = now.truncatingRemainder(dividingBy: period)
        pulse.isRemovedOnCompletion = false
        return pulse
    }

    /// Start or stop the pulse on `layer`. It runs only when `on`, the layer is
    /// in a window, and motion is not reduced; anything else removes it.
    ///
    /// Stopping eases the layer back to full over `Motion.pane` from wherever
    /// the breath had it, because removing an opacity animation mid-breath is a
    /// visible jump.
    static func set(_ layer: CALayer?, on: Bool, inWindow: Bool) {
        guard let layer else { return }
        let reduced = isReduced()
        let wanted = on && inWindow && !reduced
        let running = layer.animation(forKey: key) != nil
        if wanted, !running {
            layer.removeAnimation(forKey: settleKey)
            layer.add(animation(), forKey: key)
        } else if !wanted, running {
            let current = layer.presentation()?.opacity ?? layer.opacity
            layer.removeAnimation(forKey: key)
            guard inWindow, !reduced, current < 1 else { return }
            let settle = CABasicAnimation(keyPath: "opacity")
            settle.fromValue = current
            settle.toValue = Float(1)
            settle.duration = Motion.pane
            settle.timingFunction = Motion.easeOutTiming
            layer.add(settle, forKey: settleKey)
        }
    }

    static let settleKey = "maxpane.blocked-pulse.settle"
}

/// A label that pulses while it marks something blocked.
///
/// A label rather than a flag on every caller, because "only while on screen"
/// and "stop when Reduce Motion is switched on" are both events the view hears
/// first: leaving a window drops the animation, coming back restarts it in
/// phase, and the accessibility notification re-reads the preference live.
final class PulseLabel: NSTextField {
    var isPulsing = false {
        didSet { if isPulsing != oldValue { sync() } }
    }

    private var displayOptions: NSObjectProtocol?

    deinit {
        MainActor.assumeIsolated {
            if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, displayOptions == nil {
            displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        } else if window == nil, let displayOptions {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptions)
            self.displayOptions = nil
        }
        sync()
    }

    /// Whether the pulse is running right now, for tests.
    var isAnimatingPulse: Bool { layer?.animation(forKey: BlockedPulse.key) != nil }

    func sync() {
        wantsLayer = true
        BlockedPulse.set(layer, on: isPulsing, inWindow: window != nil)
    }
}

/// An image that pulses while it marks something blocked: a folded sidebar
/// header's triangle, carrying the brightest state under it. The same
/// contract as `PulseLabel` — on screen only, in phase, off under Reduce
/// Motion — for a mark that is a glyph rather than a word.
final class PulseImageView: NSImageView {
    var isPulsing = false {
        didSet { if isPulsing != oldValue { sync() } }
    }

    private var displayOptions: NSObjectProtocol?

    deinit {
        MainActor.assumeIsolated {
            if let displayOptions { NSWorkspace.shared.notificationCenter.removeObserver(displayOptions) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, displayOptions == nil {
            displayOptions = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        } else if window == nil, let displayOptions {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptions)
            self.displayOptions = nil
        }
        sync()
    }

    /// Whether the pulse is running right now, for tests.
    var isAnimatingPulse: Bool { layer?.animation(forKey: BlockedPulse.key) != nil }

    func sync() {
        wantsLayer = true
        BlockedPulse.set(layer, on: isPulsing, inWindow: window != nil)
    }
}
