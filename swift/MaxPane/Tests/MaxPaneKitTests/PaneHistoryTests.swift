import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// ⌃⌘, / ⌃⌘. through the store the shell calls. The rules are tested in
/// `crates/laned-core`; this is the round trip, and the keys.
@Suite("back and forward through panes")
@MainActor
struct PaneHistoryTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-pane-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    @Test("focus by click and by a new pane both count, and a step adds nothing")
    func stepsThroughWhatWasFocused() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newTerminalLane(relaySessionId: "a", near: nil)
        try store.newTerminalLane(relaySessionId: "b", near: store.state.lanes.last?.id)
        try store.newTerminalLane(relaySessionId: "c", near: store.state.lanes.last?.id)
        let ids = store.state.lanes.map { $0.panes[0].id }
        store.noteFocus(ids[0]) // on a; walked a b c a

        for expected in [ids[2], ids[1], ids[0]] {
            let target = try #require(store.paneHistoryBack())
            #expect(target == expected)
            try store.focusPane(target)
        }
        #expect(store.paneHistoryBack() == nil, "the end of the list does nothing")
        #expect(store.state.focusedPaneId == ids[0])
        #expect(store.paneHistoryForward() == ids[1])
    }

    @Test("the keys are reachable, and nobody else's")
    func keys() {
        #expect(Command.paneBack.chords == [KeyChord(key: ",", modifiers: [.command, .control])])
        #expect(Command.paneForward.chords == [KeyChord(key: ".", modifiers: [.command, .control])])
        for command in [Command.paneBack, .paneForward] {
            #expect(command.menu == .navigate)
            let chord = command.chords[0]
            #expect(!Keymap.reserved.contains { $0.0 == chord })
            #expect(Command.allCases.filter { $0.chords.contains(chord) } == [command])
        }
    }
}
