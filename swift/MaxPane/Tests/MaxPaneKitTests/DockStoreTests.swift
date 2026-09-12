import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// The Swift side of docking is one seam and one derived list, and both are
/// load-bearing in a way the Rust suite cannot see: `stripLanes` is what the
/// layout half indexes with, and the whole eviction guarantee rests on the
/// indices it sends matching the array it laid out.
///
/// Everything else about docking — the rules, the ordinal, the policy — is
/// tested in `crates/laned-core/tests/docking.rs`, against the same ledger.
@Suite("docking through the store")
@MainActor
struct DockStoreTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-dock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    private func lanes(_ store: StripStore, _ n: Int) throws -> [String] {
        for i in 0..<n {
            try store.newWebLane(url: "https://lane\(i)", near: nil)
        }
        return store.state.lanes.map(\.id)
    }

    @Test("a docked lane leaves the laid-out strip but not the snapshot")
    func stripLanesExcludesDocks() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try lanes(store, 4)

        try store.dockLane(ids[1], side: .left, mode: .inset)

        #expect(store.stripLanes.map(\.id) == [ids[0], ids[2], ids[3]])
        // Still in the snapshot, because ⌘P, gather, the sidebar and `ls` all
        // want it — and because that is what remembers where it goes back to.
        #expect(store.state.lanes.count == 4)
        #expect(store.dockedLane(.left)?.id == ids[1])
        #expect(store.dockedLane(.right) == nil)
    }

    /// The index a `Viewport` carries is an index into `stripLanes`, and the
    /// core removes docked lanes the same way before planning. This is the
    /// arithmetic that makes the two agree, checked from the side that sends it.
    @Test("a viewport measured over the laid-out strip names the lane it meant")
    func viewportIndicesLineUp() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try lanes(store, 12)
        try store.dockLane(ids[0], side: .left, mode: .overlay)

        // Looking at the middle of the eleven lanes the strip now lays out.
        let laid = store.stripLanes
        let plan = store.planEviction(
            viewport: Viewport(firstVisible: 5, lastVisible: 5),
            memory: MemoryReport(
                webContentRssBytes: 100 << 30, softBudgetBytes: 9 << 30,
                hardBudgetBytes: 12 << 30, targetBytes: 1, paneFootprints: []))

        let kept = plan.filter { $0.action == .keep }.map(\.laneId)
        // The dock, and the lane actually on screen. Nothing else.
        #expect(Set(kept) == Set([ids[0], laid[5].id]))
    }

    @Test("the dock's width is remembered apart from the lane's own")
    func widthsAreSeparate() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try lanes(store, 1)

        try store.setLaneWidth(ids[0], 800)
        try store.dockLane(ids[0], side: .right, mode: .inset)
        try store.setDockWidth(ids[0], 320)

        #expect(store.dockedLane(.right)?.dock?.widthPt == 320)
        #expect(store.lane(ids[0])?.widthPt == 800)

        try store.undockLane(ids[0])
        #expect(store.lane(ids[0])?.widthPt == 800)
    }

    @Test("undocking puts the lane back where it was")
    func undockRestoresTheOrder() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try lanes(store, 5)

        try store.dockLane(ids[2], side: .left, mode: .inset)
        try store.newWebLane(url: "https://arrived", near: ids[0])
        try store.undockLane(ids[2])

        let back = store.stripLanes.map(\.id)
        #expect(back.firstIndex(of: ids[2]) == 3)
        #expect(back.last == ids[4])
    }

    /// ⇧⌘P kept its key and lost its word, and nothing about what it does
    /// changed — including that it is independent of docking.
    @Test("keepLive and docking do not touch each other")
    func keepLiveIsIndependent() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ids = try lanes(store, 1)

        try store.setKeepLive(ids[0], true)
        try store.dockLane(ids[0], side: .left, mode: .inset)
        try store.undockLane(ids[0])

        #expect(store.lane(ids[0])?.keepLive == true)
        #expect(store.lane(ids[0])?.dock == nil)
    }
}
