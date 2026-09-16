import Testing
import AppKit
@testable import MaxPaneKit

/// The carousel margins are document, not `contentInsets`.
///
/// Found on a running instance, 2026-09-15: in a window where fewer than three
/// lanes fit, the focused lane's `s | m | xl` switch and `⋯` menu stopped
/// answering clicks. The strip had just started expressing the end-lane
/// margins as `NSScrollView.contentInsets`, and AppKit floats a private
/// `NSVisualEffectView` over an inset region that answers `hitTest` for
/// everything under it. The header controls of a centred lane sit exactly
/// there. A standalone probe reproduced it: a button drawn inside a 300 pt
/// inset hit-tested to `NSVisualEffectView`.
///
/// This pins the fix at the level the bug lived: a button inside the margin,
/// hit-tested through the scroll view, is the button.
@MainActor
struct StripDocumentPaddingTests {
    /// A scroll view set up the way the strip's is, with the document padded
    /// by `margins` and one button drawn inside the left margin's territory.
    private func strip(margins: (left: CGFloat, right: CGFloat)) -> (NSScrollView, NSButton, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        let document = StripDocumentView()
        let content = StripContentView()
        content.frame = NSRect(x: 0, y: 0, width: 2000, height: 400)
        let button = NSButton(title: "s", target: nil, action: nil)
        button.frame = NSRect(x: 40, y: 8, width: 40, height: 20)
        content.addSubview(button)
        scroll.documentView = document
        document.addSubview(content)
        window.contentView?.addSubview(scroll)
        document.layOut(content: content, margins: margins)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        return (scroll, button, window)
    }

    @Test func aButtonInsideTheMarginIsStillTheButton() {
        let (scroll, button, window) = strip(margins: (300, 300))
        defer { window.orderOut(nil) }
        let inWindow = button.convert(button.bounds, to: nil)
        // The button is drawn 300 pt in, where a content inset would have been.
        #expect(inWindow.minX == 340)
        let hit = scroll.hitTest(NSPoint(x: inWindow.midX, y: inWindow.midY))
        #expect(hit === button)
    }

    @Test func theDocumentIsTheContentPlusBothMargins() {
        let (scroll, _, window) = strip(margins: (300, 120))
        defer { window.orderOut(nil) }
        let expected: CGFloat = 2000 + 300 + 120
        #expect(scroll.documentView?.frame.width == expected)
        #expect(scroll.contentInsets.left == 0)
        #expect(scroll.contentInsets.right == 0)
    }
}
