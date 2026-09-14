import AppKit
import QuartzCore

/// Light and dark, followed live.
///
/// The owner: *"we should respect system light/dark modes and pass them through
/// to the browser instance, too."* `Theme`'s colours were already dynamic, and
/// nothing followed them anyway: views painted their layers with `.cgColor`, and
/// a `CGColor` is a snapshot of whichever appearance was current when it was
/// taken. Switching the Mac to light left every lane, header, sidebar and popup
/// dark until something happened to rebuild it.
///
/// There are three pieces, and none of them is a list of views to remember:
///
/// - **`layerBackgroundColor` / `layerBorderColor`** on `NSView` replace
///   `layer?.backgroundColor = x.cgColor`. The view keeps the *dynamic* colour
///   and re-resolves it against its own `effectiveAppearance` whenever that
///   changes, so a view written next year cannot forget to.
/// - **`Appearance.apply`** pins or releases `NSApp.appearance` for the `theme`
///   setting. Terminals and web pages need nothing from it: Ghostty's view and
///   `WKWebView` both follow their own `effectiveAppearance`, which is the same
///   signal the layers follow.
/// - **A crossfade** on every window when the app's appearance changes, on the
///   lane clock, so the switch eases rather than cuts. Skipped under Reduce
///   Motion, where the result is identical and simply has no middle.
@MainActor
public enum Appearance {
    /// Where the crossfade is found on each window's content layer.
    ///
    /// Not a key of ours: Core Animation files every `CATransition` under
    /// `kCATransition` whatever key it is added with, so that is the only name
    /// it can be looked up by.
    static let fadeKey = kCATransition

    /// Follow the system (`.system`), or pin light or dark. Live: every view,
    /// terminal and page repaints where it stands, nothing reloads.
    public static func apply(_ choice: ThemeChoice) {
        watchApp()
        let next = choice.appearance
        guard NSApp.appearance?.name != next?.name else { return }
        NSApp.appearance = next
    }

    private static var appObservation: NSKeyValueObservation?
    private static var lastMode: NSAppearance.Name?

    /// The one app-wide observer, and all it does is fade.
    ///
    /// It is not where views repaint, and cannot be: measured, this fires
    /// *before* AppKit has pushed the new appearance down to views in a window
    /// — a lane asked here still answers `aqua` after the app has gone dark. A
    /// transition added now is still inside the same transaction as every
    /// repaint that follows, which is all a crossfade needs.
    static func watchApp() {
        guard appObservation == nil else { return }
        let app = NSApplication.shared
        lastMode = mode(of: app.effectiveAppearance)
        appObservation = app.observe(\.effectiveAppearance, options: [.new]) { app, _ in
            MainActor.assumeIsolated {
                let now = mode(of: app.effectiveAppearance)
                defer { lastMode = now }
                guard now != lastMode else { return }
                crossfade(app.windows)
            }
        }
    }

    /// A fade over each window's contents, from the last committed frame to
    /// whatever the new appearance paints.
    ///
    /// On the window's content layer rather than per property: text, icons,
    /// the terminal's Metal layer and WebKit's page all change in the same
    /// transaction as the layer colours, and a per-property animation would fade
    /// the grounds and cut everything drawn on them.
    static func crossfade(_ windows: [NSWindow]) {
        guard !Motion.isReduced else { return }
        for window in windows {
            guard let layer = window.contentView?.layer else { continue }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.lane
            fade.timingFunction = Motion.easeOutTiming
            layer.add(fade, forKey: fadeKey)
        }
    }

    static func mode(of appearance: NSAppearance) -> NSAppearance.Name {
        appearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
    }
}

extension ThemeChoice {
    /// What `NSApp.appearance` becomes. `nil` is what follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

extension NSView {
    /// `layer.backgroundColor`, kept in this view's appearance.
    ///
    /// Takes the dynamic `NSColor`, not a `CGColor`: the conversion happens here,
    /// against `effectiveAppearance`, and again every time that changes. Needs
    /// `wantsLayer` first, like the property it replaces.
    var layerBackgroundColor: NSColor? {
        get { LayerPaint.existing(on: self)?.background }
        set { LayerPaint.on(self).setBackground(newValue) }
    }

    /// `layer.borderColor`, kept in this view's appearance.
    var layerBorderColor: NSColor? {
        get { LayerPaint.existing(on: self)?.border }
        set { LayerPaint.on(self).setBorder(newValue) }
    }

    /// Run `body` now, and again whenever this view's appearance changes, with
    /// that appearance current — so an `NSColor` read inside resolves to it.
    ///
    /// For what is not a layer colour: an API that copies the colour it is
    /// handed, like `WKWebView.underPageBackgroundColor`. One per view; a
    /// second call replaces the first.
    func onAppearanceChange(_ body: @escaping @MainActor (NSView) -> Void) {
        LayerPaint.on(self).setHook(body)
    }
}

extension NSColor {
    /// This colour as a `CGColor` in `appearance`.
    ///
    /// For the one-off uses that are not a paint — an animation's endpoints —
    /// where a snapshot is what is wanted, as long as it is the right one.
    func cgColor(in appearance: NSAppearance) -> CGColor {
        var resolved = cgColor
        appearance.performAsCurrentDrawingAppearance { resolved = self.cgColor }
        return resolved
    }
}

/// What a view has been asked to paint, and the observation that repaints it.
///
/// Hangs off the view as an associated object, so it lives exactly as long as
/// the view and needs no registry to be cleaned out of.
@MainActor
final class LayerPaint {
    private weak var view: NSView?
    private(set) var background: NSColor?
    private(set) var border: NSColor?
    private var paintsBackground = false
    private var paintsBorder = false
    private var hook: (@MainActor (NSView) -> Void)?
    private var observation: NSKeyValueObservation?

    /// Also fires when a view is attached to a window whose appearance changed
    /// while it was away — measured, which is what covers a lane recycled out of
    /// the strip and back, or a tile re-parented into the gallery. A view in no
    /// window gets nothing, and needs nothing: it is painted again the moment it
    /// is attached somewhere that looks different.
    private init(_ view: NSView) {
        self.view = view
        Appearance.watchApp()
        observation = view.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.repaint() }
        }
    }

    nonisolated(unsafe) private static let key = UnsafeRawPointer(
        UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))

    static func existing(on view: NSView) -> LayerPaint? {
        objc_getAssociatedObject(view, key) as? LayerPaint
    }

    static func on(_ view: NSView) -> LayerPaint {
        if let paint = existing(on: view) { return paint }
        let paint = LayerPaint(view)
        objc_setAssociatedObject(view, key, paint, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return paint
    }

    func setBackground(_ color: NSColor?) {
        background = color
        paintsBackground = true
        repaint()
    }

    func setBorder(_ color: NSColor?) {
        border = color
        paintsBorder = true
        repaint()
    }

    func setHook(_ body: @escaping @MainActor (NSView) -> Void) {
        hook = body
        repaint()
    }

    func repaint() {
        guard let view else { return }
        let appearance = view.effectiveAppearance
        if paintsBackground { view.layer?.backgroundColor = background?.cgColor(in: appearance) }
        if paintsBorder { view.layer?.borderColor = border?.cgColor(in: appearance) }
        if let hook {
            appearance.performAsCurrentDrawingAppearance { hook(view) }
        }
    }
}
