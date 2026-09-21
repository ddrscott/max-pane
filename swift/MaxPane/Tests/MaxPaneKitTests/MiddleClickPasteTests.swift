import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import MaxPaneKit
@testable import RelayClient

@Suite("where a middle click in a terminal goes")
struct MiddleClickRoutingTests {
    private func route(
        enabled: Bool = true, inTile: Bool = false, captured: Bool = false, forced: Bool = false, selection: String? = nil
    ) -> TerminalPaste.MiddleClick {
        TerminalPaste.middleClick(
            enabled: enabled, inTile: inTile, mouseCaptured: captured, forced: forced, selection: selection)
    }

    @Test("the pane's selection first, else the clipboard")
    func selectionThenClipboard() {
        #expect(route(selection: "git status") == .selection("git status"))
        #expect(route() == .clipboard)
    }

    @Test("an empty or all-whitespace selection is no selection")
    func blankSelection() {
        #expect(route(selection: "") == .clipboard)
        #expect(route(selection: "  \n\t") == .clipboard)
    }

    @Test("a program with mouse reporting on keeps the click, selection or not")
    func programKeepsIt() {
        #expect(route(captured: true) == .program)
        #expect(route(captured: true, selection: "x") == .program)
    }

    @Test("⌥ or ⇧ takes it back, and changes nothing when the program never had it")
    func optionForces() {
        #expect(route(captured: true, forced: true) == .clipboard)
        #expect(route(captured: true, forced: true, selection: "x") == .selection("x"))
        #expect(route(forced: true, selection: "x") == .selection("x"))
    }

    @Test("middle_click_paste = false and an unexpanded gallery tile: nothing, and never the emulator's own paste")
    func offAndTiles() {
        #expect(route(enabled: false, selection: "x") == .ignored)
        #expect(route(enabled: false, forced: true) == .ignored)
        #expect(route(inTile: true, selection: "x") == .ignored)
        #expect(route(inTile: true, captured: true, forced: true) == .ignored)
        // A program that asked for the mouse still gets its click.
        #expect(route(enabled: false, captured: true) == .program)
        #expect(route(inTile: true, captured: true) == .program)
    }

    @Test("middle_click_paste is in the config, on by default, under Terminals, and applies live")
    func config() throws {
        #expect(Config().middleClickPaste)
        let field = try #require(ConfigField.all.first { $0.key == "middle_click_paste" })
        #expect(field.appliesLive)
        #expect(field.group == .terminals)
    }
}

/// The door, on a real surface: what a middle click sends. Two pasteboards,
/// neither the owner's (`GeneralPasteboardStandIn`).
@Suite("a middle click pastes through the pane's one door", .serialized)
@MainActor
struct MiddleClickPasteTests {
    private final class Wire: RelayAttachment {
        let sessionId = "middle-click-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        var claims = 0
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) { claims += 1 }
        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let wire = Wire()
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.middle-click.\(UUID().uuidString)"))
        let general = GeneralPasteboardStandIn.pasteboard
        var config: Config

        init(config: Config = Config()) async throws {
            self.config = config
            await GeneralPasteboardStandIn.take()
            #expect(NSPasteboard.general === general)
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-middle-click-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "middle-click", near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.pasteboard = pasteboard
            pane.attach(wire)
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 600)
            window.contentView?.addSubview(pane.view)
            pane.liveConfig = { [unowned self] in self.config }
            window.contentView?.layoutSubtreeIfNeeded()
            copy("from-the-clipboard")
            general.clearContents()
            general.setString("general-secret", forType: .string)
            var quiet = 0
            var last = -1
            for _ in 0..<240 where quiet < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                quiet = (wire.claims == last && wire.claims > 0) ? quiet + 1 : 0
                last = wire.claims
            }
            wire.sent.removeAll()
        }

        func copy(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        var terminal: ClickableTerminalView {
            func find(_ view: NSView) -> ClickableTerminalView? {
                if let hit = view as? ClickableTerminalView { return hit }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(pane.view)!
        }

        func prints(_ text: String) { wire.onData?(ArraySlice(Array(text.utf8))) }

        /// A real button-2 event, made and never posted.
        func middle(_ type: CGEventType, _ flags: CGEventFlags = []) throws -> NSEvent {
            let cg = try #require(CGEvent(
                mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
            cg.flags = flags
            return try #require(NSEvent(cgEvent: cg))
        }

        func middleClick(_ flags: CGEventFlags = []) throws {
            terminal.otherMouseDown(with: try middle(.otherMouseDown, flags))
            terminal.otherMouseUp(with: try middle(.otherMouseUp, flags))
        }

        func settle() async throws { try await Task.sleep(nanoseconds: 300_000_000) }

        func close() {
            GeneralPasteboardStandIn.giveBack()
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("with nothing selected it pastes the clipboard, tidied as ⌘V would")
    func clipboard() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.copy("$ ls “a b” \n")
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.text == "ls \"a b\"")
        #expect(rig.pane.noticeText?.hasPrefix("pasted · ") == true)
    }

    @Test("with a selection it pastes the selection, read from the surface, and no pasteboard changes")
    func selection() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.prints("echo selected-words")
        try await rig.settle()
        let generalBefore = rig.general.changeCount
        let ownBefore = rig.pasteboard.changeCount
        #expect(rig.terminal.performBindingAction("select_all"))
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.text == "echo selected-words")
        #expect(rig.general.changeCount == generalBefore)
        #expect(rig.general.string(forType: .string) == "general-secret")
        #expect(rig.pasteboard.changeCount == ownBefore)
    }

    @Test("a risky middle-click paste asks first, like any other")
    func asks() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.copy("one\ntwo")
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.pasteSheet != nil)
    }

    @Test("a program with mouse reporting on gets the click; ⌥-middle-click pastes anyway")
    func mouseReporting() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.prints("\u{1b}[?1000h\u{1b}[?1006h")
        try await rig.settle()
        #expect(rig.terminal.isMouseCaptured)
        try rig.middleClick()
        try await rig.settle()
        // What went out is the emulator's report of button 2, not a paste.
        #expect(!rig.wire.text.contains("from-the-clipboard"))
        #expect(rig.wire.text.contains("\u{1b}[<1;"))
        rig.wire.sent.removeAll()
        try rig.middleClick(.maskAlternate)
        try await rig.settle()
        #expect(rig.wire.text == "from-the-clipboard")
        rig.wire.sent.removeAll()
        try rig.middleClick(.maskShift)
        try await rig.settle()
        #expect(rig.wire.text == "from-the-clipboard")
    }

    @Test("middle_click_paste = false, read at each click, and an unexpanded gallery tile: nothing is pasted")
    func offAndTile() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.config.middleClickPaste = false
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        rig.config.middleClickPaste = true
        rig.pane.setThumbnail(scale: 0.3, backingScale: 2)
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        rig.pane.setThumbnail(scale: 0.9, backingScale: 2, expanded: true)
        try rig.middleClick()
        try await rig.settle()
        #expect(rig.wire.text == "from-the-clipboard")
    }

    @Test("the seams stand in for the surface: a selection wins over the clipboard and takes the keyboard's pane")
    func seams() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.pane.selectionSource = { "picked" }
        rig.pane.mouseCapturedSource = { true }
        #expect(!rig.pane.middleClick(forced: false))
        #expect(rig.pane.middleClick(forced: true))
        try await rig.settle()
        #expect(rig.wire.text == "picked")
        #expect(rig.store.state.focusedPaneId == rig.store.state.lanes[0].panes[0].id)
    }
}
