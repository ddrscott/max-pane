import AppKit

/// The frame every dialog in the app is drawn in.
///
/// The owner, looking at ⌘P and then at ⌘/: *"`cmd-p` shows up in a nice
/// auto-dismiss dialog, but `cmd-/` and some other dialogs don't. Can make all
/// the other dialogs auto-dismiss with a common component?"* — and: *"All
/// dialogs show popup centered in the app with balanced margins/padding …
/// subtle animation/transition goes a long way."* Until this, the palette,
/// history, and both import wizards each carried their own copy of a borderless
/// panel, a keep-alive cycle, a child-window attach and an origin guessed at
/// some fraction above the window's middle, while ⌘/ was a titled utility
/// window that never went away. One base now owns all of it.
///
/// **Square and borderless**, because a `.titled` panel gets macOS's rounded
/// window chrome no matter what its content layer says — and a rounded card is
/// the house style's one prohibition. `SquarePanel` gets back the focus
/// behaviour `.titled` would have given.
///
/// **Centred in the window's content**, below any title bar, at the size asked
/// for or smaller, with the same margin on every side. Whole points, so the
/// one-point border stays one crisp point.
///
/// **It arrives and it leaves.** A rise of a few points and a fade in, on the
/// app's pane-sized clock; a shorter, softer fade out. Nothing that appears
/// under the pointer should feel like it was always there. Under Reduce Motion
/// both are skipped and the result is identical.
///
/// **It closes the way it was asked to.** `.clickAway` goes on Esc or on the
/// keyboard going anywhere else; `.explicitOnly` goes on Esc or its own buttons
/// — for a wizard, where a stray click on the strip must not throw away an
/// import half chosen. A popup opened on top of another is not "anywhere else":
/// a confirmation over history leaves history open, and hands it the keyboard
/// back when it goes.
@MainActor
class Popup: NSWindowController, NSWindowDelegate {
    enum Dismissal { case clickAway, explicitOnly }

    /// Between a popup and the edge of the window it is centred in.
    static let margin: CGFloat = 40
    /// How far below its resting place a popup starts, and half that when it
    /// leaves: enough to read as arriving, not enough to read as travel.
    static let rise: CGFloat = 8
    /// Leaving is quicker than arriving. The user has already moved on.
    static let exitDuration: TimeInterval = 0.12

    let dismissal: Dismissal

    /// The popup keeps itself alive while it is on screen.
    ///
    /// A text field's delegate and a table's data source are weak, and the
    /// caller is under no obligation to hold a popup it has handed a completion
    /// to. Without this the controller is released the moment `present`
    /// returns: whatever was already built stays on screen, and everything that
    /// needs the controller afterwards silently does nothing. A deliberate
    /// cycle, broken when the popup has finished leaving.
    private var whileOpen: Popup?
    private var escapeMonitor: Any?
    private var closeCompletion: (() -> Void)?
    private var restingFrame: NSRect?
    /// Bumped on every presentation, so a close that was still fading when the
    /// same popup was asked for again does not order the new one out.
    private var generation = 0
    private(set) var isClosing = false

    var isOpen: Bool { whileOpen != nil && !isClosing }

    /// True for a popup whose own key handling already does something with Esc
    /// — the palettes' and wizards' monitors — so the base does not add a second.
    var handlesEscape: Bool { false }

    /// Whether switching to another app counts as clicking away. True for a
    /// palette, which has lost a second of typing; false for a window someone
    /// reads, where ⌘-Tab to check something is not a decision to close it.
    var closesWhenAppDeactivates: Bool { true }

    init(size: NSSize, dismissal: Dismissal, resizable: Bool = false, minSize: NSSize? = nil) {
        let panel = SquarePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: resizable ? [.borderless, .resizable, .nonactivatingPanel] : [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        // A borderless window is transparent by default, so the square edge has
        // to be painted by the content rather than inherited.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        if let minSize { panel.minSize = minSize }
        self.dismissal = dismissal
        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - subclass hooks

    /// On screen and key. Give the first responder its field here.
    func popupDidPresent() {}

    /// Esc, or — for `.clickAway` — the keyboard going elsewhere. Subclasses
    /// that owe their caller an answer deliver "cancelled" and close.
    func popupCancelled() { closePopup() }

    // MARK: - showing and hiding

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        generation += 1
        whileOpen = self
        isClosing = false
        closeCompletion = nil

        let area = parent.map { $0.convertToScreen($0.contentLayoutRect) }
            ?? NSScreen.main?.visibleFrame ?? panel.frame
        let target = Self.frame(size: restingFrame?.size ?? panel.frame.size, minSize: panel.minSize, in: area)
        restingFrame = nil
        if let parent, panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }

        if Motion.isReduced {
            panel.alphaValue = 1
            panel.setFrame(target, display: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.alphaValue = 0
            panel.setFrame(target.offsetBy(dx: 0, dy: -Self.rise), display: true)
            panel.makeKeyAndOrderFront(nil)
            // Origin only — the size is already final — so nothing inside lays
            // out again on any frame of the entrance.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.pane
                context.timingFunction = Motion.easeOutTiming
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
        if !handlesEscape, escapeMonitor == nil { installEscape() }
        popupDidPresent()
    }

    /// Fade out, then order out and let go. `completion` runs once it has gone.
    func closePopup(animated: Bool = true, completion: (() -> Void)? = nil) {
        guard whileOpen != nil, !isClosing, let panel = window else { return }
        isClosing = true
        closeCompletion = completion
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        // A popup this one sat on gets the keyboard back, rather than being left
        // on screen with nothing typing into it.
        if let parent = panel.parent as? SquarePanel { parent.makeKey() }

        let generation = generation
        guard animated, !Motion.isReduced, panel.isVisible else {
            finishClosing(generation)
            return
        }
        restingFrame = panel.frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.exitDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: 0, dy: -Self.rise / 2), display: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration) { [weak self] in
            self?.finishClosing(generation)
        }
    }

    private func finishClosing(_ closing: Int) {
        guard closing == generation, isClosing, let panel = window else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.alphaValue = 1
        if let restingFrame { panel.setFrame(restingFrame, display: false) }
        let completion = closeCompletion
        closeCompletion = nil
        isClosing = false
        completion?()
        // Last: this may be the only thing keeping the popup alive.
        whileOpen = nil
    }

    func windowDidResignKey(_ notification: Notification) {
        guard dismissal == .clickAway, isOpen, let panel = window else { return }
        if !closesWhenAppDeactivates, !NSApp.isActive { return }
        // A popup opened on top of this one takes the keyboard without this one
        // having been clicked away from.
        if panel.childWindows?.contains(where: { $0.isVisible }) == true { return }
        popupCancelled()
    }

    private func installEscape() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true, event.keyCode == 53 else { return event }
            self.popupCancelled()
            return nil
        }
    }

    // MARK: - geometry

    /// Where a popup of `size` goes inside `area`: centred, no nearer any edge
    /// than `margin`, never below `minSize` while the area can hold it, on whole
    /// points. Pure, because "balanced margins" is a number.
    static func frame(size: NSSize, minSize: NSSize = .zero, in area: NSRect, margin: CGFloat = margin) -> NSRect {
        let room = NSSize(width: max(0, area.width - 2 * margin), height: max(0, area.height - 2 * margin))
        let width = max(min(size.width, room.width), min(minSize.width, area.width))
        let height = max(min(size.height, room.height), min(minSize.height, area.height))
        return NSRect(
            x: (area.midX - width / 2).rounded(), y: (area.midY - height / 2).rounded(),
            width: width.rounded(), height: height.rounded())
    }
}
