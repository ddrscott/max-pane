import Testing
import AppKit
@testable import MaxPaneKit

/// Whether the close/minimise/zoom buttons are kept off whatever is beneath
/// them, and — the half that is easy to get wrong — whether the space reserved
/// for them is given back the moment they are gone.
///
/// The reported bug is one of four arrangements: windowed or fullscreen, times
/// sidebar open or collapsed. Three of the four must reserve nothing, and a fix
/// that passes only the reported one is a fix that puts a dead band across the
/// top of a fullscreen strip. All four are spelled out below.
@Suite("titlebar avoidance")
struct TitlebarAvoidanceTests {
    /// A windowed title bar, and the buttons' reach measured from the window's
    /// left edge.
    private let band: CGFloat = 28
    private let buttons = TitlebarAvoidance.assumedButtonsEnd

    /// The sidebar is never narrower than `minimumThickness`, so with it open
    /// the strip starts well clear of the buttons.
    private let sidebarWidth: CGFloat = 290

    @Test("windowed with the sidebar open, the sidebar moves down and the strip does not")
    func windowedSidebarOpen() {
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: 0) == band)
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: sidebarWidth) == CGFloat(0))
    }

    /// Fixing only the sidebar moves the bug rather than removing it: collapsed,
    /// the strip is the leftmost thing and the first lane's header is what the
    /// buttons land on.
    @Test("windowed with the sidebar collapsed, the strip takes the inset instead")
    func windowedSidebarCollapsed() {
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: 0) == band)
    }

    @Test("fullscreen reserves nothing, either way")
    func fullscreenReservesNothing() {
        for leftEdge: CGFloat in [0, sidebarWidth] {
            #expect(TitlebarAvoidance.inset(band: 0, buttonsEndAt: buttons, contentStartsAt: leftEdge) == CGFloat(0))
        }
    }

    /// The rule is about the corner, not about which container happens to own
    /// it. A sidebar dragged narrower than the buttons hands the corner to the
    /// strip without anything having to be told that can happen.
    @Test("a sidebar narrower than the buttons leaves the strip under them")
    func narrowSidebarStillCoversTheStrip() {
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: 40) == band)
    }

    /// The boundary, both sides of it: content starting exactly where the
    /// buttons stop is already clear.
    @Test("the inset stops exactly where the buttons do")
    func boundary() {
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: buttons) == CGFloat(0))
        #expect(TitlebarAvoidance.inset(band: band, buttonsEndAt: buttons, contentStartsAt: buttons - 1) == band)
    }

    /// `band(of:)` and `buttonsEnd(of:)` against a real window built the way
    /// `StripWindowController` builds its one: transparent title bar, hidden
    /// title, full-size content view. The numbers are macOS's, not ours, so
    /// these assert the shape of the answer rather than a particular height.
    @MainActor
    @Test("a windowed, full-size-content window reports a band and the buttons' reach")
    func measuresARealWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        // Enough to cover `+ NEW`, and not so much that something has gone wrong
        // with the coordinate space — a standard title bar is 28 pt.
        let measured = TitlebarAvoidance.band(of: window)
        #expect(measured > 20 && measured < 60)

        // Three buttons and a margin, against a 1200 pt window: a plausible
        // answer is a small number, and the failure this catches is a frame read
        // in the wrong space, which would be near 1200 or zero.
        let end = TitlebarAvoidance.buttonsEnd(of: window)
        #expect(end > TitlebarAvoidance.margin && end < 200)

    }

    /// The half a screenshot cannot reach. Entering fullscreen for real takes a
    /// display and a Space from whoever is using the machine, and forcing
    /// `.fullScreen` into a live window's style mask to fake it crashes the
    /// process — so the branch is checked on the arithmetic instead.
    @Test("fullscreen gives the band back, whatever the window measures")
    func fullscreenBandIsZero() {
        #expect(TitlebarAvoidance.band(isFullScreen: true, contentTop: 800, layoutTop: 772) == CGFloat(0))
        #expect(TitlebarAvoidance.band(isFullScreen: false, contentTop: 800, layoutTop: 772) == CGFloat(28))
    }

    /// A title bar taller than the content view is not a thing, and a negative
    /// inset would push the sidebar's header up off the top of the window.
    @Test("a nonsense measurement reserves nothing rather than a negative band")
    func neverNegative() {
        #expect(TitlebarAvoidance.band(isFullScreen: false, contentTop: 700, layoutTop: 800) == CGFloat(0))
    }
}
