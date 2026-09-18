import Testing
import LanedCore
@testable import MaxPaneKit

/// ⌘P with nothing typed.
///
/// The owner: *"`cmd-p` should show a list of candidates sorted by most recently
/// accessed instead of a blank list."* Pure, so the ordering and the starting row
/// are checked without a panel.
@Suite("⌘P before anything is typed")
@MainActor
struct SearchRecentTests {
    private func pane(_ id: String, _ lane: String, url: String? = nil) -> Pane {
        Pane(id: id, laneId: lane, position: 0, kind: url == nil ? .pty : .web,
             relaySessionId: url == nil ? "s-\(id)" : nil, relayServer: nil, url: url, scrollY: nil,
             dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false)
    }

    private func lane(_ id: String, focused at: Int64, title: String?, panes: [Pane]) -> Lane {
        Lane(id: id, ordinal: 1, widthPt: 656, title: title, projectRoot: "/src/\(id)",
             projectSource: .cwd, createdAt: 0, lastFocusAt: at, keepLive: false,
             dock: nil, span: 1, panes: panes)
    }

    @Test("most recently focused first")
    func mostRecentFirst() {
        let lanes = [
            lane("a", focused: 100, title: "agent", panes: [pane("a1", "a")]),
            lane("b", focused: 300, title: "docs", panes: [pane("b1", "b", url: "https://docs")]),
            lane("c", focused: 200, title: "tests", panes: [pane("c1", "c")]),
        ]
        let hits = SearchPaletteController.recentHits(lanes: lanes, focusedPaneId: nil)
        #expect(hits.map(\.laneId) == ["b", "c", "a"])
        #expect(hits.map(\.text) == ["docs", "tests", "agent"])
    }

    @Test("a tie on the clock keeps strip order")
    func tiesKeepStripOrder() {
        let lanes = ["x", "y", "z"].map { lane($0, focused: 5, title: $0, panes: [pane("\($0)1", $0)]) }
        #expect(SearchPaletteController.recentHits(lanes: lanes, focusedPaneId: nil).map(\.laneId) == ["x", "y", "z"])
    }

    @Test("a split lane's row aims at the pane with the keyboard, otherwise the top one")
    func aimsAtTheFocusedPane() {
        let split = lane("s", focused: 10, title: "split", panes: [pane("top", "s"), pane("bottom", "s")])
        #expect(SearchPaletteController.recentHits(lanes: [split], focusedPaneId: "bottom").first?.paneId == "bottom")
        #expect(SearchPaletteController.recentHits(lanes: [split], focusedPaneId: "elsewhere").first?.paneId == "top")
    }

    @Test("an untitled lane is named by its address or its project, and a lane with no panes is not offered")
    func namingAndEmptyLanes() {
        let untitledWeb = lane("w", focused: 3, title: nil, panes: [pane("w1", "w", url: "https://example.com/x")])
        let empty = lane("e", focused: 9, title: "nothing here", panes: [])
        let hits = SearchPaletteController.recentHits(lanes: [untitledWeb, empty], focusedPaneId: nil)
        #expect(hits.map(\.laneId) == ["w"])
        #expect(hits.first?.text == "https://example.com/x")
    }

    @Test("↩ goes back: the lane you are in is listed, but the one before it is selected")
    func startsOnThePreviousLane() {
        let hits = SearchPaletteController.recentHits(lanes: [
            lane("here", focused: 900, title: "here", panes: [pane("h1", "here")]),
            lane("before", focused: 800, title: "before", panes: [pane("b1", "before")]),
        ], focusedPaneId: "h1")
        #expect(SearchPaletteController.initialRow(hits: hits, focusedPaneId: "h1") == 1)
        #expect(SearchPaletteController.initialRow(hits: hits, focusedPaneId: nil) == 0)
        #expect(SearchPaletteController.initialRow(hits: Array(hits.prefix(1)), focusedPaneId: "h1") == 0)
    }
}
