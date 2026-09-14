import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// The Swift half of "a session is on the strip once".
///
/// The sidebar and ⌘O decide whether a session is already on the strip from the
/// store, and they used to ask `state.lanes` — which a gather view narrows. A
/// session whose lane was tagged with another project therefore looked
/// unattached, and one of the owner's reached six lanes. The core now refuses
/// the second lane; these pin that the store answers the question from every
/// lane, so the doors reveal instead of trying.
@Suite("attaching a session through the store")
@MainActor
struct SessionAttachStoreTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    /// A session lane tagged `/src/max-pane`, a page tagged `/src/trifecta`,
    /// and a gather on the page's project — the state the duplicates came from.
    private func gatheredAway(_ store: StripStore) throws -> (agent: String, docs: String) {
        try store.attachSessionAtEnd(relaySessionId: "s1")
        let agent = try #require(store.state.lanes.last?.id)
        try store.setManualTag(agent, "/src/max-pane")
        try store.newWebLane(url: "https://docs", near: nil)
        let docs = try #require(store.state.lanes.last?.id)
        try store.setManualTag(docs, "/src/trifecta")
        try store.gather(projectRoot: "/src/trifecta")
        return (agent, docs)
    }

    @Test("a gather hides the lane from the strip, not from the question")
    func gatherDoesNotHideTheSession() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (agent, docs) = try gatheredAway(store)

        #expect(store.state.lanes.map(\.id) == [docs], "the gather did not narrow the snapshot")
        #expect(store.allLanes.map(\.id) == [agent, docs])
        #expect(store.lane(holdingSession: "s1")?.id == agent)
    }

    @Test("attaching a session that already has a lane is refused, even gathered away")
    func secondAttachIsRefused() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try gatheredAway(store)

        #expect(throws: (any Error).self) { try store.attachSessionAtEnd(relaySessionId: "s1") }
        try store.ungather()
        let panes = store.allLanes.flatMap(\.panes).filter { $0.relaySessionId == "s1" }
        #expect(panes.count == 1)
    }

    @Test("with nothing gathered, every lane is the snapshot")
    func ungatheredAllLanesIsTheSnapshot() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.attachSessionAtEnd(relaySessionId: "s1")
        try store.newWebLane(url: "https://docs", near: nil)

        #expect(store.allLanes.map(\.id) == store.state.lanes.map(\.id))
        #expect(store.lane(holdingSession: "nobody") == nil)
    }
}
