import AppKit
import Testing
import LanedCore
@testable import MaxPaneKit

/// How wide a pane is, given how wide its lane is.
///
/// The bug this exists for was reported as a dock bug — *"the right side dock
/// doesn't resize the lane correctly, the webview should be expanded to fill up
/// the space"* — and was not one. The lane view's frame was right at both ends
/// of the window and in the strip; the pane *inside* it was laid out at the
/// fitting width of the browser chrome bar and centred, so every web pane in the
/// app was narrow with lane background either side of it. A dock is just where
/// the column is narrow enough for the page to visibly run out of room.
///
/// It is tested through a real `LaneView` rather than as arithmetic because
/// there is no arithmetic in it: the wrong number came from an `NSStackView`
/// default, and the only thing that can catch a default is laying one out.
@Suite("how wide a pane is laid out")
@MainActor
struct LanePaneLayoutTests {
    private func lane(width: UInt32, dock: Dock?) -> Lane {
        Lane(id: "L", ordinal: 0, widthPt: width, title: nil,
             projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
             keepLive: false, dock: dock, span: 1,
             panes: [Pane(id: "P", laneId: "L", position: 0, kind: .web, relaySessionId: nil, relayServer: nil,
                          url: "https://e.com", scrollY: 0, dataStoreId: nil,
                          snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false)])
    }

    /// A stand-in for `WebPaneContainer`: a host with a full-width row of text
    /// pinned across the bottom of it, which is the shape that gives a web
    /// pane's container an intrinsic width. A `WKWebView` cannot be built in a
    /// test process, and it is not the part that was wrong.
    private func chromedPane(url: String) -> NSView {
        let host = NSView()
        let field = NSTextField(labelWithString: url)
        field.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            field.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private func laidOut(lane: Lane, drawnWidth: CGFloat, pane: NSView) -> NSView {
        let view = LaneView(lane: lane, widthBounds: 240...900)
        view.setPaneView(pane, for: "P", at: 0)
        // A window-sized host, so the lane is laid out somewhere real rather
        // than at the origin of nothing.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        host.addSubview(view)
        view.frame = NSRect(x: 1600 - drawnWidth, y: 0, width: drawnWidth, height: 900)
        view.needsLayout = true
        host.layoutSubtreeIfNeeded()
        return pane
    }

    @Test("a pane fills the lane it is in, not its own fitting width")
    func paneFillsTheLane() {
        let pane = chromedPane(url: "en.wikipedia.org/wiki/Whale")
        let laid = laidOut(lane: lane(width: 656, dock: nil), drawnWidth: 656, pane: pane)
        #expect(laid.frame.width == CGFloat(656))
        #expect(laid.frame.minX == CGFloat(0))
        // The thing that made it look like a layout that nearly worked: the
        // fitting width is a real number, just not this one.
        #expect(laid.fittingSize.width < CGFloat(656))
    }

    /// The reported case. A docked lane's view is frame-set by `layoutDocks` to
    /// the dock's width while `lane.widthPt` still says what the strip owes it
    /// back — so the pane has to follow the frame, not either stored number.
    @Test("a docked lane's pane follows the dock's width, not the lane's strip width")
    func dockedPaneFollowsTheDock() {
        let docked = lane(width: 900, dock: Dock(side: .right, mode: .inset, widthPt: 420))
        let pane = chromedPane(url: "mail.google.com")
        let laid = laidOut(lane: docked, drawnWidth: 420, pane: pane)
        #expect(laid.frame.width == CGFloat(420))
    }

    /// `DockGeometry` clamps a dock the window cannot afford, so the width the
    /// lane view is actually drawn at is a third number again — neither the
    /// lane's nor the dock's. The pane follows that one too.
    @Test("a pane follows a dock that the window clamped narrower")
    func paneFollowsTheClampedWidth() {
        let docked = lane(width: 900, dock: Dock(side: .right, mode: .inset, widthPt: 900))
        let clamped = DockGeometry.resolve(
            left: nil, right: docked.dock, viewport: 1000, laneMinPt: 420)
        let width = clamped.right?.width ?? 0
        #expect(width == CGFloat(580))
        let pane = chromedPane(url: "mail.google.com")
        #expect(laidOut(lane: docked, drawnWidth: width, pane: pane).frame.width == width)
    }

    /// The width came from the chrome bar's fitting size, so it moved with the
    /// length of the URL in it — two lanes side by side were two different
    /// widths. Same lane width in, same pane width out, whatever is in the bar.
    @Test("the URL in the chrome bar does not change how wide the pane is")
    func urlLengthDoesNotLeakIntoTheWidth() {
        let short = laidOut(
            lane: lane(width: 560, dock: nil), drawnWidth: 560, pane: chromedPane(url: "e.co"))
        let long = laidOut(
            lane: lane(width: 560, dock: nil), drawnWidth: 560,
            pane: chromedPane(url: "en.wikipedia.org/wiki/List_of_cetaceans_by_population"))
        #expect(short.frame.width == long.frame.width)
        #expect(short.frame.width == CGFloat(560))
    }

    /// A terminal pane has nothing intrinsic in it and came out full width by
    /// luck, which is why this went unnoticed until web panes grew a chrome bar.
    /// It has to stay full width now that the pins are explicit.
    @Test("a pane with no intrinsic width still fills the lane")
    func plainPaneStillFills() {
        let laid = laidOut(lane: lane(width: 480, dock: nil), drawnWidth: 480, pane: NSView())
        #expect(laid.frame.width == CGFloat(480))
    }

    /// Resizing is the case the owner checked by hand and reported as *"it does
    /// not correct itself"*: dragging the dock's inner edge left the page wrong.
    @Test("a pane follows the lane through a resize")
    func paneFollowsAResize() {
        let l = lane(width: 900, dock: Dock(side: .right, mode: .inset, widthPt: 420))
        let view = LaneView(lane: l, widthBounds: 240...900)
        let pane = chromedPane(url: "mail.google.com")
        view.setPaneView(pane, for: "P", at: 0)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        host.addSubview(view)
        for width in [CGFloat(420), 700, 300, 560] {
            view.frame = NSRect(x: 1600 - width, y: 0, width: width, height: 900)
            view.needsLayout = true
            host.layoutSubtreeIfNeeded()
            #expect(pane.frame.width == width)
        }
    }
}
