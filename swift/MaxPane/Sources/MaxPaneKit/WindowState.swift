import AppKit
import Foundation

/// Where the window was when the app last ran (ADR-0036): fullscreen, or a
/// frame on a display. One `app_state` key in the ledger, beside the sidebar's
/// folds, so it is per profile and lives where everything else this app
/// remembers lives — not `setFrameAutosaveName`, which writes to UserDefaults
/// and cannot say "fullscreen".
///
/// `{"fullscreen":true}` or
/// `{"fullscreen":false,"frame":[x,y,w,h],"screen":"<display id>"}`.
public struct WindowState: Equatable, Sendable {
    public var fullscreen: Bool
    /// The windowed frame, in screen points, when not fullscreen.
    public var frame: CGRect?
    /// The display the frame was on: `CGDirectDisplayID` as a string, which
    /// is what `NSScreen` gives and what survives a relaunch. Nil when the
    /// window was on no screen at all, which AppKit does not really allow.
    public var screen: String?

    public init(fullscreen: Bool, frame: CGRect? = nil, screen: String? = nil) {
        self.fullscreen = fullscreen
        self.frame = frame
        self.screen = screen
    }

    public static let fullscreen = WindowState(fullscreen: true)

    // MARK: - encoding

    /// Compact JSON with the keys above and nothing else, so what is in the
    /// ledger reads back in `sqlite3` as the sentence in the doc comment.
    public var encoded: String {
        var parts = ["\"fullscreen\":\(fullscreen)"]
        if !fullscreen, let frame {
            let n = [frame.origin.x, frame.origin.y, frame.width, frame.height].map(Self.number)
            parts.append("\"frame\":[\(n.joined(separator: ","))]")
            if let screen {
                parts.append("\"screen\":\(Self.quoted(screen))")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Nil on anything that is not the shape above: a hand-edited ledger or a
    /// future build's value reads as nothing remembered, which is the first
    /// launch, which is fullscreen. Never a crash over a preference.
    public static func decode(_ json: String) -> WindowState? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fullscreen = object["fullscreen"] as? Bool
        else { return nil }
        var state = WindowState(fullscreen: fullscreen)
        if fullscreen { return state }
        // Windowed without a frame is not a place to put a window.
        guard let box = object["frame"] as? [Any], box.count == 4 else { return nil }
        let n = box.compactMap { ($0 as? NSNumber)?.doubleValue }
        guard n.count == 4, n.allSatisfy(\.isFinite) else { return nil }
        state.frame = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        state.screen = object["screen"] as? String
        return state
    }

    private static func number(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(Double(v))
    }

    private static func quoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        // `["…"]` → `"…"`
        return String(array.dropFirst().dropLast())
    }

    // MARK: - restore

    /// A display as the restore rules see it: its id and the part of it a
    /// window may occupy, which excludes the menu bar and the Dock.
    public struct Screen: Equatable, Sendable {
        public var id: String
        public var visibleFrame: CGRect
        public init(id: String, visibleFrame: CGRect) {
            self.id = id
            self.visibleFrame = visibleFrame
        }

        /// `NSScreen`'s display number, the one thing about a screen that is
        /// the same after a relaunch. The name is not: two of the same monitor
        /// share one.
        public static func id(of screen: NSScreen) -> String {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let number = screen.deviceDescription[key] as? NSNumber {
                return number.stringValue
            }
            return screen.localizedName
        }

        public init(_ screen: NSScreen) {
            self.init(id: Self.id(of: screen), visibleFrame: screen.visibleFrame)
        }
    }

    /// What to do with the window at launch.
    public enum Placement: Equatable, Sendable {
        /// Enter fullscreen after the window exists, on the named display when
        /// it still exists (nil: wherever the window is).
        case fullscreen(on: Screen?)
        /// Show the window at this frame, which is on a screen.
        case windowed(CGRect)
    }

    /// The launch decision. Nothing remembered — the first launch — is
    /// fullscreen, which is what PRD §5.2 asked for and what the ledger of
    /// everyone who has ever run the app says. A remembered fullscreen is
    /// fullscreen; a remembered frame is put back where it was, clamped onto a
    /// screen that still exists.
    ///
    /// `screens` is empty only on a headless machine; then a remembered frame
    /// is trusted as it is, because there is nothing to clamp onto.
    public static func placement(for state: WindowState?, screens: [Screen]) -> Placement {
        guard let state else { return .fullscreen(on: nil) }
        if state.fullscreen {
            return .fullscreen(on: screens.first { $0.id == state.screen })
        }
        guard let frame = state.frame else { return .fullscreen(on: nil) }
        return .windowed(clamp(frame, remembered: state.screen, onto: screens))
    }

    /// Put `frame` onto a screen. The remembered one when it is still there;
    /// otherwise the screen it overlaps most; otherwise — off every screen —
    /// the nearest one to its centre. Then the size shrinks to what that
    /// screen's visible area can hold, and the origin moves so the whole
    /// window is inside it: never off screen, never under the menu bar.
    public static func clamp(_ frame: CGRect, remembered: String?, onto screens: [Screen]) -> CGRect {
        guard let target = nearest(to: frame, remembered: remembered, in: screens) else { return frame }
        let visible = target.visibleFrame
        let width = min(frame.width, visible.width)
        let height = min(frame.height, visible.height)
        let x = min(max(frame.minX, visible.minX), visible.maxX - width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func nearest(to frame: CGRect, remembered: String?, in screens: [Screen]) -> Screen? {
        if let same = screens.first(where: { $0.id == remembered }) { return same }
        func overlap(_ screen: Screen) -> CGFloat {
            let shared = screen.visibleFrame.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let most = screens.max(by: { overlap($0) < overlap($1) }), overlap(most) > 0 { return most }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return screens.min { distance(centre, to: $0.visibleFrame) < distance(centre, to: $1.visibleFrame) }
    }

    /// Distance from a point to the nearest point of a rect; zero inside it.
    private static func distance(_ p: CGPoint, to r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Whether this launch may write the state. `MAXPANE_WINDOWED` is a smoke
    /// test on somebody's machine, and a smoke test must not change what the
    /// owner comes back to.
    public static func writesEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MAXPANE_WINDOWED"] == nil
    }

    /// The window as it is now, for writing.
    @MainActor
    public static func of(_ window: NSWindow) -> WindowState {
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        return WindowState(
            fullscreen: false,
            frame: window.frame,
            screen: window.screen.map(Screen.id(of:)))
    }
}

/// Keeps the ledger's copy of the window's state current (ADR-0036).
///
/// It listens to the window's own notifications rather than being its
/// delegate: the controller is the delegate for the two fullscreen callbacks
/// it already has, and a keeper that needs no delegate can be wired to any
/// window, which is how it is tested.
///
/// Writes happen on every fullscreen enter and exit, on a move or resize
/// after a 0.5 s quiet (a drag is hundreds of frames; that is one write), and
/// on `flush`, which quit calls. Never while a fullscreen transition is in
/// flight: the frames on the way in and out are the animation's, not the
/// user's, and AppKit resizes the window several times per transition.
@MainActor
public final class WindowStateKeeper {
    public static let quiet: TimeInterval = 0.5

    private let window: NSWindow
    private let write: (WindowState) -> Void
    private var observers: [any NSObjectProtocol] = []
    private var pending: Timer?
    private(set) var transitioning = false

    /// `write` is where a state goes; `MAXPANE_WINDOWED` passes nothing at all
    /// in place of a keeper, so a smoke test leaves what the owner comes back
    /// to alone.
    public init(window: NSWindow, write: @escaping (WindowState) -> Void) {
        self.window = window
        self.write = write
        let centre = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            // AppKit posts these on the main thread, synchronously with the
            // change; `queue: nil` keeps them that way.
            observers.append(centre.addObserver(forName: name, object: window, queue: nil) { _ in
                MainActor.assumeIsolated(handler)
            })
        }
        // The keeper is held by whoever owns the window, so a weak self here
        // is a keeper that has already gone, and there is nothing to do.
        on(NSWindow.willEnterFullScreenNotification) { [weak self] in self?.transitionBegan() }
        on(NSWindow.willExitFullScreenNotification) { [weak self] in self?.transitionBegan() }
        on(NSWindow.didEnterFullScreenNotification) { [weak self] in self?.transitionEnded() }
        on(NSWindow.didExitFullScreenNotification) { [weak self] in self?.transitionEnded() }
        on(NSWindow.didMoveNotification) { [weak self] in self?.changed() }
        on(NSWindow.didResizeNotification) { [weak self] in self?.changed() }
    }

    /// Stop listening. The app never calls it — there is one window and it
    /// lives as long as the process, and a nonisolated `deinit` cannot touch
    /// the observers anyway — but a test that makes several keepers on one
    /// window wants the earlier ones quiet.
    public func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        pending?.invalidate()
        pending = nil
    }

    private func transitionBegan() {
        transitioning = true
        pending?.invalidate()
        pending = nil
    }

    private func transitionEnded() {
        transitioning = false
        flush()
    }

    private func changed() {
        guard !transitioning else { return }
        pending?.invalidate()
        pending = Timer.scheduledTimer(withTimeInterval: Self.quiet, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// Write the window as it is now. Quit calls this so the last drag is not
    /// lost to the debounce. Mid-transition it writes nothing: the state
    /// before the transition is already in the ledger and is the truer one.
    public func flush() {
        pending?.invalidate()
        pending = nil
        guard !transitioning else { return }
        write(WindowState.of(window))
    }
}
