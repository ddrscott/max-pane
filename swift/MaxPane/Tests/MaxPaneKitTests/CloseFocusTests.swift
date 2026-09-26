import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// ⌘D, run a thing, ⌘W: the keyboard lands back where the split was made.
///
/// The rule itself — up, then left — lives in `laned-core` and is tested case
/// by case in `crates/laned-core/tests/close_focus.rs`. This is the round trip
/// through the store the shell actually calls, with the ⌘D and ⌘W halves
/// driven the way `StripWindowController` drives them.
@Suite("closing the focused pane hands focus up, then left")
@MainActor
struct CloseFocusTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-close-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    /// ⌘W, as the window controller does it: whatever has focus.
    private func commandW(_ store: StripStore) throws {
        if let focused = store.state.focusedPaneId { try store.closePane(focused) }
    }

    @Test("⌘D then ⌘W puts focus back on the pane the split came from")
    func splitThenCloseRoundTrips() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newTerminalLane(relaySessionId: "a", near: nil)
        try store.newTerminalLane(relaySessionId: "b", near: store.state.lanes.last?.id)
        try store.newTerminalLane(relaySessionId: "c", near: store.state.lanes.last?.id)
        let middle = store.state.lanes[1]
        let start = middle.panes[0].id
        try store.focusPane(start)

        try store.addTerminalPane(to: middle.id, session: SessionKey(id: "b2"))
        let split = store.lane(middle.id)?.panes.last?.id
        #expect(store.state.focusedPaneId == split, "⌘D focuses the new pane")

        try commandW(store)
        #expect(store.state.focusedPaneId == start)
        #expect(store.lane(middle.id)?.panes.map(\.id) == [start])
    }

    @Test("closing a lane's only pane hands focus to the bottom of the lane on its left")
    func lastPaneHandsLeft() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newTerminalLane(relaySessionId: "a", near: nil)
        let left = store.state.lanes[0]
        try store.addTerminalPane(to: left.id, session: SessionKey(id: "a2"))
        let bottom = store.lane(left.id)?.panes.last?.id
        try store.newTerminalLane(relaySessionId: "b", near: left.id)
        let right = try #require(store.state.lanes.last)
        try store.focusPane(right.panes[0].id)

        try commandW(store)
        #expect(store.state.lanes.map(\.id) == [left.id])
        #expect(store.state.focusedPaneId == bottom)
    }
}
