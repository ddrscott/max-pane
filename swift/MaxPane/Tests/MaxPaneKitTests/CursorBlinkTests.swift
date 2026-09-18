import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import MaxPaneKit

/// `cursor_blink`: which terminal cursors blink. `focused` unless the file
/// says otherwise.
@Suite("cursor blink is a setting, and only the focused terminal by default")
struct CursorBlinkSettingTests {
    private var field: ConfigField? { ConfigField.all.first { $0.key == "cursor_blink" } }

    @Test("focused by default, a choice of three under Terminals, taken on relaunch like the font")
    func schema() throws {
        #expect(Config().cursorBlink == .focused)
        let field = try #require(field)
        #expect(field.name == "cursorBlink")
        #expect(field.group == .terminals)
        #expect(field.defaultValue == .string("focused"))
        guard case .choice(let options) = field.control else {
            Issue.record("cursor_blink is not a choice")
            return
        }
        #expect(options == ["focused", "always", "never"])
        let font = try #require(ConfigField.all.first { $0.key == "font_size" })
        #expect(field.appliesLive == font.appliesLive)
        #expect(!field.appliesLive)
    }

    @Test("each value is read; a word that is not one of them, or a wrong type, costs only itself")
    func decodes() {
        func decode(_ text: String) -> (Config, [ConfigProblem]) { ConfigFile.decode(TomlDocument(text)) }
        #expect(decode("font_size = 15\n").0.cursorBlink == .focused)
        #expect(decode("cursor_blink = \"always\"\n").0.cursorBlink == .always)
        #expect(decode("cursor_blink = \"never\"\n").0.cursorBlink == .never)
        #expect(decode("cursor_blink = \"focused\"\n").0.cursorBlink == .focused)
        for bad in ["cursor_blink = \"sometimes\"", "cursor_blink = true"] {
            let (config, problems) = decode(bad + "\nfont_size = 15\n")
            #expect(config.cursorBlink == .focused)
            #expect(config.fontSize == 15)
            #expect(problems.map(\.key) == ["cursor_blink"])
            #expect(problems.first?.reason.contains("\"focused\", \"always\", \"never\"") == true)
        }
    }

    @Test("the settings window writes one line, and taking it out is focused again")
    @MainActor
    func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-cursor-blink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try Data("# mine\nfont_size = 15  # big\n".utf8).write(to: file)
        let store = ConfigStore(path: file, watches: false)
        let field = try #require(field)

        #expect(!store.isSet(field))
        store.set(field, to: .string("never"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nfont_size = 15  # big\ncursor_blink = \"never\"\n")
        #expect(store.config.cursorBlink == .never)
        #expect(ConfigStore(path: file, watches: false).config.cursorBlink == .never)

        store.set(field, to: nil)
        #expect(!store.isSet(field))
        #expect(store.config.cursorBlink == .focused)
    }

    @Test("the old config.json spelling is read too")
    func json() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"cursorBlink":"always"}"#.utf8))
        #expect(config.cursorBlink == .always)
    }

    @Test("the terminal configuration says blink or not, once, for all three")
    @MainActor
    func reachesTheBuilder() {
        func lines(_ blink: CursorBlink) -> [String] {
            var config = Config()
            config.cursorBlink = blink
            return TerminalControllerPool.makeController(for: config).terminalConfiguration.rendered
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("cursor-style-blink") }
        }
        // `focused` and `always` differ in what a surface is told about focus,
        // not in Ghostty's configuration. See `CursorBlinkSurfaceTests`.
        #expect(lines(.focused) == ["cursor-style-blink = true"])
        #expect(lines(.always) == ["cursor-style-blink = true"])
        #expect(lines(.never) == ["cursor-style-blink = false"])
    }
}

/// The same on real surfaces, asking Ghostty itself what it believes.
///
/// The observable is focus reporting: a program that sends `CSI ? 1004 h` is
/// answered with `CSI I` or `CSI O` for the surface's focus at that moment, and
/// again at each change. That is the state the renderer blinks from, read out
/// of the emulator rather than out of a flag of ours.
@Suite("only the terminal with the keyboard believes it is focused", .serialized)
@MainActor
struct CursorBlinkSurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "cursor-blink-test"
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

        /// `I` and `O`, in the order Ghostty reported them.
        var reports: String { CursorBlinkSurfaceTests.reports(in: sent) }
    }

    nonisolated static func reports(in bytes: [UInt8]) -> String {
        var out = ""
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0x1b, bytes[i + 1] == 0x5b, bytes[i + 2] == 0x49 || bytes[i + 2] == 0x4f {
                out.append(bytes[i + 2] == 0x49 ? "I" : "O")
                i += 3
            } else {
                i += 1
            }
        }
        return out
    }

    private final class Keyboard: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let host: NSView
        /// Something that is not a terminal and can hold the keyboard.
        let elsewhere = Keyboard(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        var lanes: [LaneView] = []
        var panes: [TerminalPaneController] = []
        var wires: [Wire] = []
        var windowIsKey: Bool

        init(config: Config, terminals: Int, windowIsKey: Bool = true) async throws {
            self.windowIsKey = windowIsKey
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-cursor-blink-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 1400, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            host = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 600))
            window.contentView = host
            host.addSubview(elsewhere)
            for n in 0..<terminals {
                try store.newTerminalLane(relaySessionId: "cursor-blink-\(n)", near: nil)
            }
            // Not the shared controller — see `TerminalControllerPool.makeController`.
            let shared = TerminalControllerPool.makeController(for: config)
            for (n, lane) in store.state.lanes.enumerated() {
                let pane = lane.panes[0]
                let controller = TerminalPaneController(pane: pane, store: store, config: config, controller: shared)
                controller.windowIsKey = { [unowned self] _ in self.windowIsKey }
                let wire = Wire()
                controller.attach(wire)
                let laneView = LaneView(lane: lane, widthBounds: 420...900)
                laneView.frame = NSRect(x: 20 + CGFloat(n) * 680, y: 0, width: 656, height: 600)
                host.addSubview(laneView)
                laneView.setPaneView(controller.view, for: pane.id, at: 0)
                lanes.append(laneView)
                panes.append(controller)
                wires.append(wire)
            }
            host.layoutSubtreeIfNeeded()
            var quiet = 0
            var last = -1
            for _ in 0..<240 where quiet < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                let now = wires.reduce(0) { $0 + $1.claims }
                quiet = (now == last && wires.allSatisfy { $0.claims > 0 }) ? quiet + 1 : 0
                last = now
            }
            // What a program that wants focus events sends.
            for wire in wires { wire.onData?(ArraySlice(Array("\u{1b}[?1004h".utf8))) }
            try await settle()
        }

        func settle() async throws { try await Task.sleep(nanoseconds: 350_000_000) }

        /// What each surface last said about itself.
        var beliefs: [Character?] { wires.map { $0.reports.last } }

        func terminalView(_ n: Int) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view is ClickableTerminalView { return view }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(panes[n].view)
        }

        func close() {
            panes.forEach { $0.tearDown() }
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// The cause, kept as a test: the library tells a surface about focus only
    /// when its view gains or loses first responder, and Ghostty's surfaces are
    /// born focused. If this ever fails the library has started saying so at
    /// birth, and `syncSurfaceFocus` has less to do.
    @Test("the library alone: a surface that never held the keyboard says it is focused, and is never told otherwise")
    func bareSurfaceIsBornFocused() async throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes: [UInt8] = []
            private var sizes = 0
            func wrote(_ data: Data) { lock.withLock { bytes.append(contentsOf: data) } }
            func sized() { lock.withLock { sizes += 1 } }
            var count: Int { lock.withLock { sizes } }
            var reports: String { lock.withLock { CursorBlinkSurfaceTests.reports(in: bytes) } }
        }
        let box = Box()
        let session = InMemoryTerminalSession(
            write: { box.wrote($0) }, resize: { _ in box.sized() }, suppressesPixelOnlyResizes: false)
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        terminal.controller = TerminalControllerPool.makeController(for: Config())
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        window.contentView?.addSubview(terminal)
        terminal.layoutSubtreeIfNeeded()
        var quiet = 0
        var last = 0
        for _ in 0..<240 where quiet < 12 {
            terminal.fitToSize()
            try await Task.sleep(nanoseconds: 25_000_000)
            let now = box.count
            quiet = (now == last && now > 0) ? quiet + 1 : 0
            last = now
        }
        session.receive("\u{1b}[?1004h")
        session.waitForPendingOutput()
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(window.firstResponder !== terminal)
        #expect(box.reports == "I")

        // And the route the pane uses to correct it moves the surface without
        // moving the keyboard.
        terminal.tellSurface(focused: false)
        try await Task.sleep(nanoseconds: 350_000_000)
        #expect(box.reports == "IO")
        #expect(window.firstResponder !== terminal)
    }

    @Test("a terminal that has never been focused does not believe it is")
    func neverFocused() async throws {
        let rig = try await Rig(config: Config(), terminals: 3)
        defer { rig.close() }
        // The newest lane is the ledger's focused pane and takes the keyboard
        // as it lands in the window, which is `applyPendingFocus` at work. The
        // other two have never been first responder, and were never told so.
        let holder = try #require((0..<3).first { rig.window.firstResponder === rig.terminalView($0) })
        for n in 0..<3 where n != holder {
            #expect(rig.wires[n].reports == "O", "pane \(n): \(rig.wires[n].reports)")
        }
        #expect(rig.wires[holder].reports.last == "I")
    }

    @Test("focus moving between two terminals: exactly one at each step, and it is the one with the keyboard")
    func exactlyOne() async throws {
        let rig = try await Rig(config: Config(), terminals: 2)
        defer { rig.close() }
        for step in [0, 1, 0, 0, 1] {
            try rig.store.focusPane(rig.panes[step].paneId)
            rig.panes[step].takeFocus()
            try await rig.settle()
            #expect(rig.window.firstResponder === rig.terminalView(step), "step \(step): the keyboard")
            let expected: [Character?] = step == 0 ? ["I", "O"] : ["O", "I"]
            #expect(rig.beliefs == expected, "step \(step): \(rig.wires.map(\.reports))")
        }
    }

    @Test("the keyboard going to something that is not a terminal leaves none focused, and coming back resumes")
    func elsewhere() async throws {
        let rig = try await Rig(config: Config(), terminals: 2)
        defer { rig.close() }
        try rig.store.focusPane(rig.panes[0].paneId)
        rig.panes[0].takeFocus()
        try await rig.settle()
        #expect(rig.beliefs == ["I", "O"])

        // A web view, the ⌘O field, the sidebar's filter: the ledger still
        // names pane 0, and the keys do not go there.
        #expect(rig.window.makeFirstResponder(rig.elsewhere))
        try await rig.settle()
        #expect(rig.beliefs == ["O", "O"])

        rig.panes[0].takeFocus()
        try await rig.settle()
        #expect(rig.window.firstResponder === rig.terminalView(0))
        #expect(rig.beliefs == ["I", "O"])
    }

    /// The library reports focus to a view made first responder whatever the
    /// window's state: `maxpane run` from another app focuses a new lane in a
    /// window that is not key. The keyboard is still owed to the pane for when
    /// the window comes back, so first responder stays; the cursor does not blink.
    @Test("in a window that is not key the pane keeps the keyboard and its cursor stays still")
    func notKey() async throws {
        let rig = try await Rig(config: Config(), terminals: 2, windowIsKey: false)
        defer { rig.close() }
        for step in [0, 1] {
            rig.panes[step].takeFocus()
            try await rig.settle()
            #expect(rig.window.firstResponder === rig.terminalView(step))
            #expect(rig.beliefs == ["O", "O"], "\(rig.wires.map(\.reports))")
        }
    }

    /// `takeFocus`'s own regression, from the other side: a reparented pane
    /// must come back with the keyboard *and* the cursor, and its neighbour
    /// with neither. Maximize is a reparent, and so is a gallery tile.
    @Test("lifted by ⇧⌘↩ and put back, and held as a gallery tile: keyboard and cursor still agree")
    func reparented() async throws {
        let rig = try await Rig(config: Config(), terminals: 2)
        defer { rig.close() }
        let pane = rig.panes[0]
        try rig.store.focusPane(pane.paneId)
        pane.takeFocus()
        try await rig.settle()

        let maximizer = PaneMaximizer(host: rig.host)
        maximizer.viewportRect = { [host = rig.host] in host.bounds }
        maximizer.laneView = { [lane = rig.lanes[0]] _ in lane }
        maximizer.maximize(paneId: pane.paneId, view: pane.view, in: rig.lanes[0], title: "t", animated: false)
        rig.host.layoutSubtreeIfNeeded()
        try await rig.settle()
        #expect(rig.window.firstResponder === rig.terminalView(0), "maximized: the keyboard")
        #expect(rig.beliefs == ["I", "O"], "maximized: \(rig.wires.map(\.reports))")

        maximizer.restore(animated: false)
        rig.host.layoutSubtreeIfNeeded()
        try await rig.settle()
        #expect(rig.window.firstResponder === rig.terminalView(0), "restored: the keyboard")
        #expect(rig.beliefs == ["I", "O"], "restored: \(rig.wires.map(\.reports))")

        // Into a tile and out of it: every terminal is held, one has the keys.
        for scale in [0.3, nil] as [CGFloat?] {
            rig.panes.forEach { $0.setThumbnail(scale: scale, backingScale: 2) }
            rig.host.layoutSubtreeIfNeeded()
            try await rig.settle()
            #expect(rig.window.firstResponder === rig.terminalView(0))
            #expect(rig.beliefs == ["I", "O"], "tile \(String(describing: scale)): \(rig.wires.map(\.reports))")
        }

        // Out of the window and back, which is a lane view recycled on scroll.
        let lane = rig.lanes[1]
        lane.removeFromSuperview()
        rig.host.addSubview(lane)
        rig.host.layoutSubtreeIfNeeded()
        try await rig.settle()
        #expect(rig.beliefs == ["I", "O"], "recycled: \(rig.wires.map(\.reports))")
    }

    @Test("always: every surface is told it is focused, wherever the keyboard is")
    func always() async throws {
        var config = Config()
        config.cursorBlink = .always
        let rig = try await Rig(config: config, terminals: 2)
        defer { rig.close() }
        #expect(rig.beliefs == ["I", "I"])
        rig.panes[0].takeFocus()
        try await rig.settle()
        rig.panes[1].takeFocus()
        try await rig.settle()
        #expect(rig.window.firstResponder === rig.terminalView(1))
        #expect(rig.beliefs == ["I", "I"], "\(rig.wires.map(\.reports))")
        #expect(rig.window.makeFirstResponder(rig.elsewhere))
        try await rig.settle()
        #expect(rig.beliefs == ["I", "I"], "\(rig.wires.map(\.reports))")
    }

    @Test("never: focus is still told truthfully; it is the configuration that holds the cursor still")
    func never() async throws {
        var config = Config()
        config.cursorBlink = .never
        let rig = try await Rig(config: config, terminals: 2)
        defer { rig.close() }
        rig.panes[1].takeFocus()
        try await rig.settle()
        #expect(rig.beliefs == ["O", "I"])
    }
}
