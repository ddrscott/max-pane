import AppKit

/// Keeping the window's close/minimise/zoom buttons off whatever is underneath
/// them.
///
/// The owner's report: *"when not in full screen the 'new' button is obscured
/// by the Mac window management buttons."* The window is
/// `titlebarAppearsTransparent` + `.fullSizeContentView` on purpose — the strip
/// is the interface and 28 pt of empty title bar is 28 pt of lane — but macOS
/// still draws the three buttons over that content, and the first thing there
/// is the sidebar's `+ NEW`.
///
/// Reserving the band from the *window* would fix it and cost more than it
/// saves: the buttons occupy about 78 pt of a 1600 pt window, so a band across
/// the whole top is fifteen hundred points of nothing to spare seventy-eight.
/// The rule here is narrower — whoever's left edge is under the buttons starts
/// lower, and everything else still goes to the top. With the sidebar open that
/// is the sidebar and the strip is untouched; collapse it (⌘B) and the strip
/// becomes the leftmost thing and takes the inset instead. Fixing only the
/// sidebar moves the bug onto the first lane's header rather than removing it.
enum TitlebarAvoidance {
    /// Breathing room past the zoom button, so a header's first pixel is not
    /// flush against the last button.
    static let margin: CGFloat = 8

    /// What to assume the buttons take when the window will not say — a window
    /// not yet on screen has no title bar view to measure. Measured at 70 pt on
    /// macOS 15 for the standard three.
    static let assumedButtonsEnd: CGFloat = 70 + margin

    /// How far down content starting at `leftEdge` has to begin.
    ///
    /// Two facts and no state: a fullscreen window has no band and nothing to
    /// avoid, and content that starts to the right of the buttons is already
    /// clear of them however tall the band is.
    static func inset(band: CGFloat, buttonsEndAt: CGFloat, contentStartsAt leftEdge: CGFloat) -> CGFloat {
        guard band > 0, leftEdge < buttonsEndAt else { return 0 }
        return band
    }

    /// The height of the strip of content the title bar is drawn over.
    ///
    /// `contentLayoutRect` is the supported answer and needs no arithmetic about
    /// title bar heights, which are not ours to predict. Fullscreen is
    /// short-circuited rather than measured: there the title bar is an overlay
    /// that slides in when the pointer reaches the top, so a measurement taken
    /// while it is showing would reserve a band that the next measurement gives
    /// back — a strip that twitches whenever you reach for the menu bar.
    static func band(of window: NSWindow) -> CGFloat {
        guard let content = window.contentView else { return 0 }
        return band(
            isFullScreen: window.styleMask.contains(.fullScreen),
            contentTop: content.bounds.maxY,
            layoutTop: window.contentLayoutRect.maxY)
    }

    /// The arithmetic of the above, with the window taken out of it.
    ///
    /// Separate because the fullscreen branch cannot be reached from a test any
    /// other way: `.fullScreen` is a flag AppKit sets during a transition it
    /// owns, and forcing it into a live window's style mask crashes the process
    /// rather than pretending — tried, from this suite.
    static func band(isFullScreen: Bool, contentTop: CGFloat, layoutTop: CGFloat) -> CGFloat {
        guard !isFullScreen else { return 0 }
        return max(0, contentTop - layoutTop)
    }

    /// Where the three buttons stop, measured from the window's left edge.
    static func buttonsEnd(of window: NSWindow) -> CGFloat {
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
            .filter { !$0.isHidden }
        guard let rightmost = buttons.map({ $0.frame.maxX }).max() else { return assumedButtonsEnd }
        return rightmost + margin
    }
}
