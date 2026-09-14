import AppKit
import Testing
@testable import MaxPaneKit

/// The row above the strip, level with the sidebar's header.
///
/// Every control stands in for a key, so what has to hold is that each asks for
/// exactly that key's command, that the switch shows the layout the strip is in,
/// and that the row is the sidebar header's height — the one number the two
/// halves of the band have to share.
@Suite("the strip toolbar")
@MainActor
struct StripToolbarTests {
    private func click(_ button: SidebarButton) {
        _ = (button.target as? NSObject)?.perform(button.action, with: button)
    }

    @Test("the switch lights the layout the strip is in")
    func switchFollowsLayout() {
        let bar = StripToolbar()
        #expect(bar.lanesButton.isOn && !bar.galleryButton.isOn)
        bar.setLayout(isGallery: true)
        #expect(!bar.lanesButton.isOn && bar.galleryButton.isOn)
        bar.setLayout(isGallery: false)
        #expect(bar.lanesButton.isOn && !bar.galleryButton.isOn)
    }

    @Test("each control asks for the command its key runs")
    func controlsCallThrough() {
        let bar = StripToolbar()
        var asked: [String] = []
        bar.onLayout = { asked.append($0 ? "gallery" : "lanes") }
        bar.onFind = { asked.append("find") }
        click(bar.galleryButton)
        click(bar.lanesButton)
        click(bar.findButton)
        #expect(asked == ["gallery", "lanes", "find"])
    }

    @Test("the count reads like the footer's, with the live marker when anything runs")
    func sessionCount() {
        let bar = StripToolbar()
        bar.setSessions(0)
        #expect(bar.sessions.stringValue == "0 sessions")
        bar.setSessions(1)
        #expect(bar.sessions.stringValue == "$ 1 session")
        bar.setSessions(11)
        #expect(bar.sessions.stringValue == "$ 11 sessions")
    }

    /// The first render sheet came back with the switch and ⌘P and no count at
    /// all — nothing failed, the label simply was not where anyone could see it.
    /// So its place is asserted in numbers.
    @Test("the session count is laid out against the right edge, inside the row")
    func countIsOnScreen() {
        let bar = StripToolbar(frame: NSRect(x: 0, y: 0, width: 1200, height: StripToolbar.height))
        bar.setSessions(11)
        bar.layoutSubtreeIfNeeded()
        let count = bar.sessions.frame
        let where_ = "count at \(count), intrinsic \(bar.sessions.intrinsicContentSize), bar \(bar.bounds), text \(bar.sessions.stringValue)"
        // As wide as its text, not as wide as the gap: the first layout gave it 944 pt.
        #expect(count.width > 40 && count.width < 200, "\(where_)")
        #expect(count.minX > bar.bounds.width / 2, "\(where_)")
        // Against the right edge. A text field's frame carries a couple of points
        // of inset past the constraint, so "at the edge" is within that.
        #expect(abs(count.maxX - (bar.bounds.width - 10)) <= 3, "\(where_)")
        #expect(count.minY >= 0 && count.maxY <= bar.bounds.height, "\(where_)")
    }

    /// The sidebar's header is pinned at 34 pt in `buildHeader`. If either number
    /// moves alone, the rule under the row steps where the sidebar ends.
    @Test("it is the sidebar header's height")
    func matchesTheSidebarHeader() {
        #expect(StripToolbar.height == 34)
    }

    /// Gated on `MAXPANE_SHOTS` like every other sheet.
    @Test("renders in both layouts")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        for gallery in [false, true] {
            try AppearanceSheet.render(to: dir, named: "strip-toolbar-\(gallery ? "gallery" : "lanes")") {
                let bar = StripToolbar(frame: NSRect(x: 0, y: 0, width: 1200, height: StripToolbar.height))
                bar.setLayout(isGallery: gallery)
                bar.setSessions(11)
                return bar
            }
        }
    }
}
