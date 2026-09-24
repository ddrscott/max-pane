import AppKit
import Testing
@testable import MaxPaneKit

/// ⌘↩ — Expand Tile, and the same key to put it back.
///
/// The owner asked: *"do we have a shortcut to toggle lane expansion?"* We did
/// not. Expanding was a double click and collapsing was a click on the gallery
/// background; the keyboard reached everything *around* expansion — ⌘G in, ⌘J
/// and ⌘[ / ⌘] to move an expansion that already existed — and not expansion
/// itself, so a keyboard user arrived in the gallery and was stuck on
/// thumbnails.
///
/// These drive the controller the key ends at, on `MaximizeRig`'s three lanes
/// with the middle one split, put up as a gallery. The refusals are asserted
/// through `expandTileRefusal`, which is the string the greyed View item and
/// the ⌘E row print.
@Suite("⌘↩ expands and collapses a gallery tile", .serialized)
@MainActor
struct GalleryExpandKeyTests {
    /// Exactly one tile is expanded, and it is the one the controller names.
    private func expandedTiles(_ rig: MaximizeRig) -> [String] {
        rig.store.state.lanes.map(\.id).filter { rig.strip.laneView(for: $0)?.isExpandedTile == true }
    }

    // MARK: the key

    @Test("the command ships on ⌘↩, in the View menu, and nothing else has the key")
    func defaultChord() {
        let chord = KeyChord(key: "\r", modifiers: [.command])
        #expect(Keymap.defaults.chords(for: .toggleExpandTile) == [chord])
        #expect(chord.text == "⌘↩")
        #expect(KeyChord("⌘↩") == chord)
        #expect(KeyChord("cmd+return") == chord)
        #expect(Command.toggleExpandTile.menu == .view)
        #expect(Command.toggleExpandTile.title == "Expand Tile")
        #expect(Command.toggleExpandTile.activeTitle == "Collapse Tile")
        let owners = Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) }
        #expect(owners == [.toggleExpandTile])
        // ⇧⌘↩ is still Maximize Pane's alone: the pair reads together and
        // neither takes the other's key.
        let shifted = KeyChord(key: "\r", modifiers: [.command, .shift])
        #expect(Keymap.defaults.chords(for: .toggleMaximizePane) == [shifted])
        #expect(Keymap(overrides: KeyBindings()).complaints.isEmpty)
        // Not a chord macOS or the Edit menu has spoken for.
        #expect(!Keymap.reserved.contains { $0.0 == chord })
    }

    @Test("`[keys]` moves it, and unbinds it")
    func rebinding() {
        let moved = Keymap(overrides: KeyBindings(["toggleExpandTile": ["ctrl+cmd+e"]]))
        #expect(moved.complaints.isEmpty)
        #expect(moved.chords(for: .toggleExpandTile) == [KeyChord(key: "e", modifiers: [.command, .control])])
        let unbound = Keymap(overrides: KeyBindings(["toggleExpandTile": []]))
        #expect(unbound.chords(for: .toggleExpandTile).isEmpty)
    }

    @Test("a page is not offered ⌘↩ — the key reaches the menu from inside a tile")
    func theChordReachesTheMenu() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        #expect(Command.claims(event))
        #expect(!Command.toggleExpandTile.yieldsToPage)
    }

    // MARK: what it does

    @Test("it expands the focused lane's tile, and pressing it again puts the tile back")
    func expandsAndCollapses() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.right)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(rig.strip.canToggleExpandTile)
            #expect(!rig.strip.focusedTileIsExpanded)

            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.rightLane)
            #expect(expandedTiles(rig) == [rig.rightLane])
            #expect(rig.strip.focusedTileIsExpanded)
            // The expanded tile has the keyboard, which is the whole point of
            // reaching it without a mouse.
            #expect(rig.store.state.focusedPaneId == rig.right)

            // The same key on the lane that is already up is the collapse: the
            // gallery keeps its focus and stays a gallery.
            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            #expect(expandedTiles(rig).isEmpty)
            #expect(rig.strip.isGallery)
            #expect(rig.store.state.focusedPaneId == rig.right)
        }
    }

    @Test("on another lane it moves the expansion rather than collapsing it")
    func movesToAnotherLane() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)

            // ⌘J / ⌘[ already carry the expansion with focus (ADR-0011, amended
            // 2026-09-24), so by the time ⌘↩ is pressed the focused lane is the
            // expanded one and the key collapses. Pressing it on a lane focus
            // has *not* reached — here, by expanding straight from the ledger
            // path — grows that one instead.
            rig.strip.collapseExpandedTile()
            await rig.settle()
            try rig.store.focusPane(rig.splitBottom)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)

            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.splitLane)
            #expect(expandedTiles(rig) == [rig.splitLane])
            // The pane that had the keyboard keeps it: the bottom of the split,
            // not the lane's first pane.
            #expect(rig.store.state.focusedPaneId == rig.splitBottom)
        }
    }

    // MARK: when it says no

    @Test("outside the gallery it is greyed, and ⇧⌘↩ is the strip's answer instead")
    func greyedOnTheStrip() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(!rig.strip.isGallery)
            #expect(!rig.strip.canToggleExpandTile)
            #expect(rig.strip.expandTileRefusal == "only in the gallery")
            // Pressing it anyway does nothing at all — no expansion held over
            // for the next ⌘G.
            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == nil)
            // The strip's equivalent is live, and this is not a second one.
            #expect(rig.strip.canToggleMaximize)
        }
    }

    @Test("a docked lane refuses, says why in one line, and leaves an expansion elsewhere alone")
    func aDockedLaneRefuses() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset, widthPt: 400)
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)

            // Focus into the wall. The expansion stays where it is — a docked
            // lane is exempt from the focus rule — and the key is greyed with
            // the reason, rather than silently doing nothing or wandering off
            // to the nearest lane that would take it.
            try rig.store.focusPane(rig.right)
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(!rig.strip.canToggleExpandTile)
            #expect(rig.strip.expandTileRefusal == "the lane is docked")
            #expect(!rig.strip.focusedTileIsExpanded)

            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)
            #expect(expandedTiles(rig) == [rig.leftLane])
            // And the wall still has no tile of its own.
            #expect(rig.strip.tileRect(rig.rightLane) == nil)
        }
    }

    @Test("Esc is not bound to it: in the gallery Esc belongs to the focused tile")
    func escIsNotTaken() async throws {
        // ADR-0011 spends Esc on the tile — *"answering an agent's prompt from
        // its thumbnail is what the gallery is for"* — and the expanded tile is
        // exactly the tile being answered. So the collapse half ships on ⌘↩
        // only, and Esc reaches the terminal or the page as it always did.
        let esc = KeyChord(key: "\u{1b}", modifiers: [])
        #expect(Keymap.defaults.chords(for: .toggleExpandTile) == [KeyChord(key: "\r", modifiers: [.command])])
        #expect(Command.allCases.allSatisfy { !Keymap.defaults.chords(for: $0).contains(esc) })

        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            rig.strip.toggleExpandFocusedTile()
            await rig.settle()
            #expect(rig.strip.expandedLaneId == rig.leftLane)

            // Esc is nobody's key equivalent here, so nothing routes it at the
            // window: the expanded tile keeps it, and ⌘G is still the only way
            // out of the gallery.
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53))
            #expect(!Command.claims(event))
            #expect(rig.strip.isGallery)
            #expect(rig.strip.expandedLaneId == rig.leftLane)
        }
    }
}
