import AppKit
import GhosttyTerminal
import LanedCore
import Testing
@testable import MaxPaneKit

/// ⇧⌘↩ — Maximize Pane, and the same key to put it back (ADR-0019).
///
/// The claim is "exactly as it was", so the tests measure rather than argue:
/// a real `StripViewController` over a real ledger in a window no screen shows,
/// with three lanes — the middle one split two to one — and every pane's frame,
/// the strip's scroll offset and the ledger's snapshot compared before and
/// after. The panes are stand-ins (`StubPane`), because what is under test is
/// where the strip puts a pane's view, not what the view draws; a real page is
/// in `WebMaximizeTests`.
@Suite("maximize pane", .serialized)
@MainActor
struct MaximizePaneTests {
    // MARK: the key

    @Test("the command ships on ⇧⌘↩, in the View menu, and nothing else has the key")
    func defaultChord() {
        let chord = KeyChord(key: "\r", modifiers: [.command, .shift])
        #expect(Keymap.defaults.chords(for: .toggleMaximizePane) == [chord])
        #expect(chord.text == "⇧⌘↩")
        #expect(KeyChord("⇧⌘↩") == chord)
        #expect(KeyChord("cmd+shift+return") == chord)
        #expect(Command.toggleMaximizePane.menu == .view)
        #expect(Command.toggleMaximizePane.title == "Maximize Pane")
        #expect(Command.toggleMaximizePane.activeTitle == "Restore Pane")
        let owners = Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) }
        #expect(owners == [.toggleMaximizePane])
        // Resolving the shipped map against an empty config finds no collision.
        #expect(Keymap(overrides: KeyBindings()).complaints.isEmpty)
    }

    @Test("`[keys]` moves it, and unbinds it")
    func rebinding() {
        let moved = Keymap(overrides: KeyBindings(["toggleMaximizePane": ["ctrl+cmd+m"]]))
        #expect(moved.complaints.isEmpty)
        #expect(moved.chords(for: .toggleMaximizePane) == [KeyChord(key: "m", modifiers: [.command, .control])])
        let unbound = Keymap(overrides: KeyBindings(["toggleMaximizePane": []]))
        #expect(unbound.chords(for: .toggleMaximizePane).isEmpty)
    }

    @Test("a terminal does not take ⇧⌘↩ for the pty, and a page is not offered it")
    func theChordReachesTheMenu() throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        // What a web pane's container asks before its `WKWebView` sees a chord.
        #expect(Command.claims(event))

        // A real Ghostty view with the app's configuration (`keybind = clear`,
        // ADR-0009), holding the keyboard. `performKeyEquivalent` is the walk
        // that runs before the main menu; false is "not mine", and the menu's
        // Maximize Pane item is what answers next.
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        terminal.controller = TerminalControllerPool.makeController(for: Config())
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        window.contentView?.addSubview(terminal)
        terminal.layoutSubtreeIfNeeded()
        #expect(window.makeFirstResponder(terminal))
        #expect(window.firstResponder === terminal)
        #expect(!terminal.performKeyEquivalent(with: event))
    }

    // MARK: the round trip

    @Test("the toggle is its own inverse: frames, split ratio, scroll offset and ledger")
    func roundTrip() async throws {
        try await MaximizeRig.with { rig in
            let pane = rig.splitTop
            try rig.store.focusPane(pane)
            await rig.settle()
            let frames = rig.frames()
            let scroll = rig.scrollOrigin
            let ledger = rig.store.state
            #expect(abs(frames[rig.splitTop]!.height / frames[rig.splitBottom]!.height - 2) < 0.05)

            rig.strip.toggleMaximizeFocusedPane()
            rig.layout()
            #expect(rig.strip.isPaneMaximized)
            #expect(rig.strip.maximizedPaneId == pane)
            // The pane is the strip's whole visible window, less the row that
            // says it is maximized.
            let viewport = rig.strip.maximizedViewportRect
            #expect(viewport.width > 1200)
            let overlay = rig.strip.maximizedOverlay
            #expect(overlay.superview === rig.strip.view)
            #expect(overlay.frame == viewport)
            let up = rig.stub(pane).view
            #expect(up.isDescendant(of: overlay))
            #expect(up.frame.width == viewport.width)
            #expect(up.frame.height == viewport.height - MaximizedPaneView.barHeight)
            // Its siblings and neighbours did not move, and nothing scrolled.
            for (id, frame) in rig.frames() where id != pane { #expect(frame == frames[id]) }
            #expect(rig.scrollOrigin == scroll)
            // The keyboard stays with it.
            #expect(rig.store.state.focusedPaneId == pane)
            #expect(rig.stub(pane).focusCount > 0)

            rig.strip.toggleMaximizeFocusedPane()
            #expect(!rig.strip.isPaneMaximized)
            rig.strip.landMaximizeTransition()
            rig.layout()
            #expect(overlay.superview == nil)
            #expect(rig.frames() == frames)
            #expect(rig.scrollOrigin == scroll)

            // Nothing was written: the snapshot is the same one, revision and
            // all, and the core has not moved on from it either.
            rig.store.refreshIfChanged()
            #expect(rig.store.state == ledger)
        }
    }

    @Test("it says it is maximized, in the accent, and the chip puts it back")
    func theSign() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.left)
            await rig.settle()
            rig.strip.toggleMaximizeFocusedPane()
            let overlay = rig.strip.maximizedOverlay
            #expect(overlay.chipText == "MAXIMIZED")
            #expect(!overlay.titleText.isEmpty)
            let chip = try #require(overlay.firstDescendant(MaximizedChip.self))
            // Outlined on every side and square: no single-edge rail.
            #expect(chip.layer?.borderWidth == 1)
            #expect(chip.layer?.cornerRadius == 0)
            #expect(chip.layerBorderColor == Theme.accent.withAlphaComponent(0.6))
            // It eases from the pane's own rect on the strip's clock — or, under
            // Reduce Motion, simply lands.
            let move = overlay.layer?.animation(forKey: "maximizeMove") as? CABasicAnimation
            if Motion.isReduced {
                #expect(move == nil)
            } else {
                #expect(move?.keyPath == "transform")
                #expect(move?.duration == Motion.lane)
            }
            chip.onPress?()
            #expect(!rig.strip.isPaneMaximized)
        }
    }

    // MARK: the rule

    @Test("moving focus restores first: left, right, down, and a click in the sidebar")
    func focusRestores() async throws {
        try await MaximizeRig.with { rig in
            for move in [StripViewController.FocusDirection.left, .right, .down] {
                try rig.store.focusPane(rig.splitTop)
                await rig.settle()
                let frames = rig.frames()
                rig.strip.toggleMaximizeFocusedPane()
                #expect(rig.strip.isPaneMaximized)
                rig.strip.moveFocus(move)
                #expect(!rig.strip.isPaneMaximized)
                let expected = move == .left ? rig.left : move == .right ? rig.right : rig.splitBottom
                #expect(rig.store.state.focusedPaneId == expected)
                rig.strip.landMaximizeTransition()
                rig.layout()
                #expect(rig.frames() == frames)
            }

            // A session in a covered lane going BLOCKED shows in the sidebar,
            // and clicking its row is this call: restore, then go there.
            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            rig.strip.toggleMaximizeFocusedPane()
            #expect(rig.strip.select(laneId: rig.rightLane, paneId: nil))
            #expect(!rig.strip.isPaneMaximized)
            #expect(rig.store.state.focusedPaneId == rig.right)
        }
    }

    @Test("changing the strip restores first: a new lane, a closed pane, a width, a dock, the gallery")
    func stripChangesRestore() async throws {
        try await MaximizeRig.with { rig in
            @MainActor func up(_ pane: String) async throws {
                rig.strip.landMaximizeTransition()
                try rig.store.focusPane(pane)
                await rig.settle()
                rig.strip.toggleMaximizeFocusedPane()
                #expect(rig.strip.isPaneMaximized)
            }

            // ⌘O's lane arriving (the picker alone changes nothing).
            try await up(rig.splitTop)
            try rig.store.newWebLane(url: "about:blank", near: rig.splitLane)
            #expect(!rig.strip.isPaneMaximized)

            try await up(rig.splitTop)
            try rig.store.setLaneWidth(rig.splitLane, 700)
            #expect(!rig.strip.isPaneMaximized)

            try await up(rig.splitTop)
            try rig.store.dockLane(rig.rightLane, side: .right, mode: .inset)
            #expect(!rig.strip.isPaneMaximized)
            try rig.store.undockLane(rig.rightLane)

            try await up(rig.splitTop)
            #expect(rig.strip.setLayout(.gallery))
            #expect(!rig.strip.isPaneMaximized)
            // At once: the gallery takes every lane view, this pane's included.
            #expect(rig.strip.maximizedOverlay.superview == nil)
            // The gallery offers the key too; leaving it restores the same way.
            #expect(rig.strip.canToggleMaximize)
            rig.strip.toggleMaximizeFocusedPane()
            #expect(rig.strip.isPaneMaximized)
            #expect(rig.strip.setLayout(.lanes))
            #expect(!rig.strip.isPaneMaximized)
            #expect(rig.strip.maximizedOverlay.superview == nil)

            // ⌘W on the maximized pane: it closes, and the overlay goes with it.
            try await up(rig.splitTop)
            try rig.store.closePane(rig.splitTop)
            #expect(!rig.strip.isPaneMaximized)
            rig.strip.landMaximizeTransition()
            #expect(rig.strip.maximizedOverlay.superview == nil)
            #expect(rig.store.pane(rig.splitTop) == nil)
        }
    }

    @Test("what is not focus and not the strip's shape leaves it up")
    func whatDoesNotRestore() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            rig.strip.toggleMaximizeFocusedPane()
            // A click inside the pane re-notes the focus it already has.
            rig.store.noteFocus(rig.splitTop)
            #expect(rig.strip.isPaneMaximized)
            try rig.store.setLaneTitle(rig.leftLane, "renamed")
            #expect(rig.strip.isPaneMaximized)
            try rig.store.setKeepLive(rig.rightLane, true)
            #expect(rig.strip.isPaneMaximized)
            // And the window changing size takes the pane with it.
            rig.window.setContentSize(NSSize(width: 1300, height: 900))
            rig.layout()
            #expect(rig.strip.maximizedOverlay.frame == rig.strip.maximizedViewportRect)
            #expect(rig.strip.maximizedViewportRect.width < 1300)
        }
    }

    @Test("the rule itself: focus or shape, and nothing else")
    func rule() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.splitTop)
            let before = rig.store.state
            #expect(!MaximizeRule.restores(maximized: rig.splitTop, before: before.lanes, after: before))
            #expect(MaximizeRule.restores(maximized: rig.splitBottom, before: before.lanes, after: before))
            try rig.store.setLaneTitle(rig.leftLane, "renamed")
            #expect(!MaximizeRule.restores(maximized: rig.splitTop, before: before.lanes, after: rig.store.state))
            try rig.store.nudgeLane(rig.leftLane, right: true)
            #expect(MaximizeRule.restores(maximized: rig.splitTop, before: before.lanes, after: rig.store.state))
        }
    }

    // MARK: a terminal

    /// ADR-0007 as amended: a pane's size reaches the PTY, once per decision.
    /// A maximized terminal gets the columns the window holds — a wide pane
    /// that kept 80 would not be a terminal — and the far end hears one size
    /// going up and one coming down, none of them a size it only passed through.
    @Test("a terminal is told one size going up and one coming down, and ends where it began")
    func terminalReflowsOncePerToggle() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-maximize-pty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "maximize-test", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        let config = Config()
        let controller = TerminalPaneController(
            pane: pane, store: store, config: config,
            controller: TerminalControllerPool.makeController(for: config))
        let attachment = SizeRecorder()
        controller.attach(attachment)

        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 800))
        window.contentView = host
        let laneView = LaneView(lane: lane, widthBounds: 420...900)
        laneView.frame = NSRect(x: 100, y: 0, width: 656, height: 800)
        host.addSubview(laneView)
        laneView.setPaneView(controller.view, for: pane.id, at: 0)
        host.layoutSubtreeIfNeeded()

        func quiet() async throws {
            var quiet = 0
            var last = attachment.claims.count
            for _ in 0..<240 where quiet < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                let now = attachment.claims.count
                quiet = now == last ? quiet + 1 : 0
                last = now
            }
        }
        try await quiet()
        let start = try #require(attachment.claims.last, "the pane never claimed a size")
        attachment.claims.removeAll()

        let maximizer = PaneMaximizer(host: host)
        maximizer.viewportRect = { host.bounds }
        maximizer.laneView = { _ in laneView }
        maximizer.maximize(paneId: pane.id, view: controller.view, in: laneView, title: "t", animated: true)
        host.layoutSubtreeIfNeeded()
        try await quiet()
        #expect(attachment.claims.count == 1, "going up: \(attachment.claims)")
        #expect((attachment.claims.last?.cols ?? 0) > start.cols * 2)

        attachment.claims.removeAll()
        maximizer.restore(animated: true)
        // Still easing: the view has not moved yet, so nothing has been said.
        if !Motion.isReduced { #expect(attachment.claims.isEmpty) }
        maximizer.land()
        host.layoutSubtreeIfNeeded()
        try await quiet()
        #expect(attachment.claims.count == 1, "coming down: \(attachment.claims)")
        #expect(attachment.claims.last == start)
        controller.tearDown()
    }

    // MARK: the gallery

    @Test("from a gallery tile, and from an expanded one: the whole gallery, and back into the tile")
    func fromTheGallery() async throws {
        try await MaximizeRig.with { rig in
            let pane = rig.splitTop
            try rig.store.focusPane(pane)
            await rig.settle()
            #expect(rig.strip.setLayout(.gallery))
            await rig.settle()
            // A tile's bounds are the lane's and its frame is smaller, and AppKit
            // snaps what is inside to backing pixels on every layout pass, so a
            // pane in a tile moves by a fraction of a point whether or not
            // anything was maximized. Within a point is "where it was".
            func near(_ a: CGRect, _ b: CGRect) -> Bool {
                abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
                    && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
            }

            for expanded in [false, true] {
                if expanded {
                    // Expanding gives the pane the keyboard, which is a write.
                    rig.strip.expandTile(laneId: rig.splitLane, paneId: pane)
                    await rig.settle()
                }
                let ledger = rig.store.state
                let view = rig.stub(pane).view
                let inTile = view.convert(view.bounds, to: rig.strip.view)
                let sibling = rig.stub(rig.splitBottom).view
                let siblingInTile = sibling.convert(sibling.bounds, to: rig.strip.view)
                // A tile draws its lane small; an expanded one draws it larger.
                #expect(inTile.width < rig.strip.view.bounds.width / 2)

                #expect(rig.strip.canToggleMaximize)
                rig.strip.toggleMaximizeFocusedPane()
                rig.layout()
                #expect(rig.strip.isPaneMaximized)
                #expect(rig.strip.isGallery)
                #expect(rig.strip.expandedLaneId == (expanded ? rig.splitLane : nil))
                let overlay = rig.strip.maximizedOverlay
                // The gallery is the viewport: docks are tiles here, not walls.
                #expect(rig.strip.maximizedViewportRect == rig.strip.view.bounds)
                #expect(overlay.frame == rig.strip.view.bounds)
                #expect(view.isDescendant(of: overlay))
                // At its real size, not a tile's scale.
                let up = view.convert(view.bounds, to: rig.strip.view)
                #expect(up.width == rig.strip.view.bounds.width)
                #expect(near(sibling.convert(sibling.bounds, to: rig.strip.view), siblingInTile))

                rig.strip.toggleMaximizeFocusedPane()
                rig.strip.landMaximizeTransition()
                rig.layout()
                #expect(!rig.strip.isPaneMaximized)
                #expect(overlay.superview == nil)
                #expect(rig.strip.isGallery)
                #expect(rig.strip.expandedLaneId == (expanded ? rig.splitLane : nil))
                #expect(near(view.convert(view.bounds, to: rig.strip.view), inTile))
                #expect(near(sibling.convert(sibling.bounds, to: rig.strip.view), siblingInTile))
                // Nothing was written, in either kind of tile.
                rig.store.refreshIfChanged()
                #expect(rig.store.state == ledger)
            }
        }
    }

    /// A tile holds its terminal at the strip's size and draws it small. Going
    /// up it has to let go, or the pane fills the window and the terminal stays
    /// the size of a lane in its corner; coming down the gallery takes hold
    /// again at the size the slot gives it, which is the one it started with.
    @Test("a terminal in a tile lets go of its thumbnail hold going up, and is held again at the same size")
    func terminalInATile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-maximize-tile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "maximize-tile-test", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        let config = Config()
        let controller = TerminalPaneController(
            pane: pane, store: store, config: config,
            controller: TerminalControllerPool.makeController(for: config))
        let attachment = SizeRecorder()
        controller.attach(attachment)

        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 800))
        window.contentView = host
        let laneView = LaneView(lane: lane, widthBounds: 420...900)
        laneView.frame = NSRect(x: 100, y: 0, width: 656, height: 800)
        host.addSubview(laneView)
        laneView.setPaneView(controller.view, for: pane.id, at: 0)
        host.layoutSubtreeIfNeeded()

        func quiet() async throws {
            var quiet = 0
            var last = attachment.claims.count
            for _ in 0..<240 where quiet < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                let now = attachment.claims.count
                quiet = now == last ? quiet + 1 : 0
                last = now
            }
        }
        try await quiet()
        let start = try #require(attachment.claims.last, "the pane never claimed a size")
        // What the gallery does to every terminal on the way in.
        controller.setThumbnail(scale: 0.3, backingScale: 2)
        host.layoutSubtreeIfNeeded()
        try await quiet()
        attachment.claims.removeAll()

        // What the strip does in the gallery: let go, then lift.
        controller.setThumbnail(scale: nil, backingScale: 1)
        let maximizer = PaneMaximizer(host: host)
        maximizer.viewportRect = { host.bounds }
        maximizer.laneView = { _ in laneView }
        maximizer.maximize(paneId: pane.id, view: controller.view, in: laneView, title: "t", animated: false)
        host.layoutSubtreeIfNeeded()
        try await quiet()
        #expect(attachment.claims.count == 1, "going up: \(attachment.claims)")
        #expect((attachment.claims.last?.cols ?? 0) > start.cols * 2)

        attachment.claims.removeAll()
        maximizer.restore(animated: false)
        host.layoutSubtreeIfNeeded()
        // And what `onLanded` has the gallery do: take hold again.
        controller.setThumbnail(scale: 0.3, backingScale: 2)
        host.layoutSubtreeIfNeeded()
        try await quiet()
        #expect(attachment.claims.count == 1, "coming down: \(attachment.claims)")
        #expect(attachment.claims.last == start)
        controller.tearDown()
    }

    // MARK: a docked lane

    @Test("a docked lane's pane fills the strip's window, not the dock's, and the dock stays")
    func dockedLane() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.dockLane(rig.leftLane, side: .left, mode: .inset, widthPt: 400)
            try rig.store.focusPane(rig.left)
            await rig.settle()
            rig.strip.landMaximizeTransition()
            let frames = rig.frames()
            let dockFrame = try #require(frames[rig.left])
            #expect(abs(dockFrame.width - 400) < 1)

            rig.strip.toggleMaximizeFocusedPane()
            rig.layout()
            #expect(rig.strip.maximizedPaneId == rig.left)
            let viewport = rig.strip.maximizedViewportRect
            // Clear of the dock, which keeps its edge with the slot in it.
            #expect(viewport.minX >= 400)
            #expect(rig.strip.maximizedOverlay.frame == viewport)
            #expect(rig.stub(rig.left).view.frame.width == viewport.width)
            let slot = try #require(rig.strip.view.firstDescendant(MaximizePlaceholderView.self))
            #expect(slot.convert(slot.bounds, to: nil) == dockFrame)

            rig.strip.toggleMaximizeFocusedPane()
            rig.strip.landMaximizeTransition()
            rig.layout()
            #expect(rig.frames() == frames)
        }
    }
}

// MARK: - the rig

/// Every size a terminal pane sends to the far end, and nothing else.
@MainActor
private final class SizeRecorder: RelayAttachment {
    struct Size: Equatable { let cols: Int; let rows: Int }
    let sessionId = "maximize-test"
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onHostResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var claims: [Size] = []

    func connect() {}
    func disconnect() {}
    func send(_ bytes: ArraySlice<UInt8>) {}
    func claimSize(cols: Int, rows: Int) { claims.append(Size(cols: cols, rows: rows)) }
}

/// A pane with nothing in it but a view.
@MainActor
final class StubPane: PaneController {
    let paneId: String
    let view = NSView()
    var focusCount = 0
    init(_ pane: Pane) { paneId = pane.id }
    func apply(_ pane: Pane) {}
    func takeFocus() { focusCount += 1 }
    func tearDown() {}
    func unparent() {}
    func reparentIfNeeded() {}
    func evict() {}
    func rehydrate() {}
}

/// Three lanes on a real ledger, the middle one split two to one, in a real
/// `StripViewController` in a window off every screen.
@MainActor
final class MaximizeRig {
    let dir: URL
    let store: StripStore
    let strip: StripViewController
    let window: NSWindow
    private var stubs: [String: StubPane] = [:]

    let leftLane: String, splitLane: String, rightLane: String
    let left: String, splitTop: String, splitBottom: String, right: String

    static func with(_ body: (MaximizeRig) async throws -> Void) async throws {
        let rig = try await MaximizeRig()
        do {
            try await body(rig)
        } catch {
            rig.tearDown()
            throw error
        }
        rig.tearDown()
    }

    private init() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-maximize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        for _ in 0..<3 { try store.newWebLane(url: "about:blank", near: store.state.lanes.last?.id) }
        let lanes = store.state.lanes
        leftLane = lanes[0].id
        splitLane = lanes[1].id
        rightLane = lanes[2].id
        try store.addPane(to: splitLane, kind: .web, relaySessionId: nil, url: "about:blank")
        let split = try #require(store.lane(splitLane))
        left = lanes[0].panes[0].id
        right = lanes[2].panes[0].id
        splitTop = split.panes[0].id
        splitBottom = split.panes[1].id
        try store.setPaneHeights([(paneId: splitTop, weight: 2), (paneId: splitBottom, weight: 1)])

        strip = StripViewController(store: store, config: Config())
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1000))
        strip.controllerFactory = { [weak self] pane, _ in
            let stub = StubPane(pane)
            self?.stubs[pane.id] = stub
            return stub
        }
        strip.view.frame = window.contentView!.bounds
        strip.view.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(strip.view)
        await settle()
    }

    func stub(_ paneId: String) -> StubPane { stubs[paneId]! }

    func layout() { window.contentView?.layoutSubtreeIfNeeded() }

    /// Let the strip's own deferred work run — launch settling, a scroll to the
    /// focused lane — and lay out.
    func settle() async {
        for _ in 0..<3 {
            layout()
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        layout()
    }

    /// Every pane's view, in window coordinates, for the panes that have one on
    /// screen.
    func frames() -> [String: CGRect] {
        var out: [String: CGRect] = [:]
        for (id, stub) in stubs where stub.view.window != nil && store.pane(id) != nil {
            out[id] = stub.view.convert(stub.view.bounds, to: nil)
        }
        return out
    }

    var scrollOrigin: CGPoint {
        strip.view.firstDescendant(NSScrollView.self)?.contentView.bounds.origin ?? .zero
    }

    func tearDown() {
        window.orderOut(nil)
        strip.view.removeFromSuperview()
        try? FileManager.default.removeItem(at: dir)
    }
}

extension NSView {
    func firstDescendant<T: NSView>(_ type: T.Type) -> T? {
        for subview in subviews {
            if let hit = subview as? T { return hit }
            if let hit = subview.firstDescendant(type) { return hit }
        }
        return nil
    }
}
