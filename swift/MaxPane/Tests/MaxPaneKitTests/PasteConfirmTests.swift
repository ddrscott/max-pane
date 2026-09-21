import Testing
import AppKit
import Foundation
import RelayClient
@testable import MaxPaneKit

/// A paste that asks first (ADR-0026), and the pieces every paste leaves in.
///
/// With no bracketed paste, an interior newline *is* the Return key. These pin
/// which pastes are held for a question, what each answer sends, and that an
/// unanswered or cancelled one sends nothing at all.

@Suite("which pastes ask first")
struct PasteAsksFirstTests {
    private let all = TerminalPaste.ConfirmSettings()

    @Test("one line asks nothing, and a trailing newline does not make it two")
    func singleLine() {
        #expect(!TerminalPaste.asksFirst("ls -la", all))
        #expect(!TerminalPaste.asksFirst("ls -la\n", all))
        #expect(!TerminalPaste.asksFirst("ls -la\r\n\r\n", all))
        #expect(TerminalPaste.shape(of: "ls -la\n").lines == 1)
    }

    @Test("an interior line ending asks, whichever kind it is")
    func multiline() {
        for text in ["a\nb", "a\r\nb", "a\rb", "a\nb\n", "\nb"] {
            #expect(TerminalPaste.asksFirst(text, all), "\(text.debugDescription)")
        }
        #expect(TerminalPaste.shape(of: "a\r\nb\nc\n").lines == 3)
    }

    @Test("a tab asks")
    func tabs() {
        #expect(TerminalPaste.asksFirst("a\tb", all))
        #expect(TerminalPaste.shape(of: "\ta\t").tabs == 2)
    }

    @Test("more bytes than paste_confirm_bytes asks; exactly that many does not; 0 never does")
    func large() {
        let limit = TerminalPaste.ConfirmSettings(bytes: 100)
        #expect(!TerminalPaste.asksFirst(String(repeating: "x", count: 100), limit))
        #expect(TerminalPaste.asksFirst(String(repeating: "x", count: 101), limit))
        // Bytes, not characters: 34 × 3 = 102.
        #expect(TerminalPaste.asksFirst(String(repeating: "é́", count: 26), limit))
        let never = TerminalPaste.ConfirmSettings(bytes: 0)
        #expect(!TerminalPaste.asksFirst(String(repeating: "x", count: 5_000_000), never))
        #expect(!TerminalPaste.asksFirst(String(repeating: "x", count: 16_384), all))
        #expect(TerminalPaste.asksFirst(String(repeating: "x", count: 16_385), all))
    }

    @Test("each reason has its own setting")
    func settings() {
        let text = "a\tb\nc"
        #expect(!TerminalPaste.asksFirst(text, .init(multiline: false, tabs: false, bytes: 0)))
        #expect(TerminalPaste.asksFirst(text, .init(multiline: true, tabs: false, bytes: 0)))
        #expect(TerminalPaste.asksFirst(text, .init(multiline: false, tabs: true, bytes: 0)))
        #expect(TerminalPaste.asksFirst(text, .init(multiline: false, tabs: false, bytes: 4)))
    }

    @Test("nothing to send asks nothing")
    func empty() {
        #expect(!TerminalPaste.asksFirst("", all))
        #expect(!TerminalPaste.asksFirst("\n\n", all))
    }

    @Test("the settings come from the config, under their snake_case keys, and apply live")
    func config() throws {
        #expect(TerminalPaste.ConfirmSettings(Config()) == TerminalPaste.ConfirmSettings())
        var config = Config()
        config.pasteConfirmMultiline = false
        config.pasteConfirmTabs = false
        config.pasteConfirmBytes = 0
        config.pasteTabWidth = 2
        #expect(TerminalPaste.ConfirmSettings(config) == .init(multiline: false, tabs: false, bytes: 0, tabWidth: 2))
        for key in ["paste_confirm_multiline", "paste_confirm_tabs", "paste_confirm_bytes", "paste_tab_width"] {
            let field = try #require(ConfigField.all.first { $0.key == key }, "\(key)")
            #expect(field.appliesLive)
            #expect(field.group == .terminals)
        }
    }

    @Test("what the sheet says is unusual: one line per reason, all that are true")
    func reasons() {
        let shape = TerminalPaste.shape(of: "a\tb\nc\nd")
        let lines = shape.reasons(.init(bytes: 4))
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("2 of its 3 lines end in Return"))
        #expect(lines[1].hasPrefix("1 tab:"))
        #expect(lines[2].hasPrefix("7 bytes: more than the 4 bytes"))
        #expect(TerminalPaste.shape(of: "plain").reasons(.init()).isEmpty)
    }
}

@Suite("the paste sheet's transforms")
struct PasteTransformTests {
    @Test("one line: lines joined with a space, no Return left in it")
    func joins() {
        #expect(TerminalPaste.oneLine("a\nb\nc") == "a b c")
        #expect(TerminalPaste.oneLine("a\r\nb\rc\n") == "a b c")
        #expect(!TerminalPaste.bytes(for: TerminalPaste.oneLine("a\nb\r\nc\n\n")).contains(0x0d))
    }

    @Test("one line: a trailing backslash is a continuation, joined as the shell joins it")
    func continuation() {
        #expect(TerminalPaste.oneLine("docker run \\\n  --rm \\\n  alpine") == "docker run   --rm   alpine")
        #expect(TerminalPaste.oneLine("ab\\\ncd") == "abcd")
        // An escaped backslash at the end of a line is not a continuation.
        #expect(TerminalPaste.oneLine("echo \\\\\nls") == "echo \\\\ ls")
        #expect(TerminalPaste.oneLine("echo \\\\\\\nls") == "echo \\\\ls")
        // Nothing to continue onto: the last line keeps its backslash.
        #expect(TerminalPaste.oneLine("a\nb\\") == "a b\\")
    }

    @Test("one line: empty lines do not become runs of spaces, indentation is kept")
    func emptyLines() {
        #expect(TerminalPaste.oneLine("a\n\n\nb") == "a b")
        #expect(TerminalPaste.oneLine("if x\n  y") == "if x   y")
        #expect(TerminalPaste.oneLine("one") == "one")
        #expect(TerminalPaste.oneLine("") == "")
    }

    @Test("tabs to spaces: each tab is that many spaces, and nothing else moves")
    func tabs() {
        #expect(TerminalPaste.tabsToSpaces("a\tb", width: 4) == "a    b")
        #expect(TerminalPaste.tabsToSpaces("\t\tx\n\ty", width: 2) == "    x\n  y")
        #expect(TerminalPaste.tabsToSpaces("no tabs", width: 4) == "no tabs")
        #expect(!TerminalPaste.asksFirst(TerminalPaste.tabsToSpaces("a\tb", width: 4), .init()))
    }

    @Test("the preview: the first eight lines as sent, control characters made visible")
    func preview() {
        let text = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let (lines, more) = TerminalPaste.preview(text)
        #expect(lines == (1...8).map { "line \($0)" })
        #expect(more == 4)

        let odd = TerminalPaste.preview("a\tb\u{1b}[31m\u{7f}\u{85}").lines
        #expect(odd == ["a␉b␛[31m␡<U+0085>"])
        #expect(TerminalPaste.preview(String(repeating: "x", count: 500)).lines[0].count == 241)
        #expect(TerminalPaste.preview("one").more == 0)
    }

    @Test("sizes read as a person says them")
    func sizes() {
        #expect(TerminalPaste.size(1) == "1 byte")
        #expect(TerminalPaste.size(312) == "312 bytes")
        #expect(TerminalPaste.size(16_384) == "16.0 KB")
        #expect(TerminalPaste.size(1_048_576) == "1.0 MB")
    }
}

@Suite("a paste leaves in pieces of at most 1 000 bytes")
@MainActor
struct PasteChunkTests {
    @Test("the limit is 1 000, in order, nothing lost")
    func ascii() {
        let bytes = (0..<2_500).map { UInt8(truncatingIfNeeded: 0x20 + $0 % 90) }
        let pieces = TerminalPaste.chunks(of: bytes)
        #expect(InputChunks.limit == 1000)
        #expect(pieces.map(\.count) == [1000, 1000, 500])
        #expect(pieces.flatMap { $0 } == bytes)
        #expect(TerminalPaste.chunks(of: []).isEmpty)
        #expect(TerminalPaste.chunks(of: Array(repeating: 0x61, count: 1000)).count == 1)
    }

    @Test("no piece ends in the middle of a character: two, three and four byte sequences")
    func multibyte() throws {
        for (unit, width) in [("é", 2), ("界", 3), ("😀", 4)] {
            // One ASCII byte first, so the limit falls inside a sequence.
            let text = "x" + String(repeating: unit, count: 1200)
            let bytes = Array(text.utf8)
            let pieces = TerminalPaste.chunks(of: bytes)
            #expect(pieces.flatMap { $0 } == bytes)
            for (index, piece) in pieces.enumerated() {
                #expect(piece.count <= 1000)
                // Backing up to a boundary costs less than one character.
                if index < pieces.count - 1 { #expect(piece.count > 1000 - width) }
                #expect(String(bytes: piece, encoding: .utf8) != nil, "a piece of \(unit) is not whole UTF-8")
            }
        }
    }

    @Test("bytes that are not UTF-8 are cut at the limit rather than looped over")
    func notUTF8() {
        let bytes = [UInt8](repeating: 0x80, count: 2100)
        #expect(TerminalPaste.chunks(of: bytes).map(\.count) == [1000, 1000, 100])
    }

    /// Gaps held until the test lets them end.
    @MainActor
    final class Clock {
        var waiting: [@MainActor () -> Void] = []
        var delays: [TimeInterval] = []
        func after(_ delay: TimeInterval, _ block: @escaping @MainActor () -> Void) {
            delays.append(delay)
            waiting.append(block)
        }
        /// End the oldest gap.
        func tick() { if !waiting.isEmpty { waiting.removeFirst()() } }
        func runOut() { while !waiting.isEmpty { tick() } }
    }

    @Test("the first piece leaves at once, and each later one a gap after the last")
    func paced() {
        let clock = Clock()
        var sent: [[UInt8]] = []
        let paced = PacedInput(after: clock.after) { sent.append($0) }
        let bytes = Array(String(repeating: "界", count: 1000).utf8)   // 3 000 bytes

        paced.enqueue(bytes[...])
        #expect(sent.count == 1)
        #expect(paced.backlog == 3000 - sent[0].count)
        clock.tick()
        #expect(sent.count == 2)
        clock.runOut()
        #expect(sent.count == 4)
        #expect(sent.map(\.count) == [999, 999, 999, 3])
        #expect(sent.flatMap { $0 } == bytes)
        #expect(clock.delays.allSatisfy { $0 == PacedInput.gap })
        #expect(PacedInput.gap == 0.005)
        #expect(paced.backlog == 0)
    }

    @Test("what is typed during a long paste goes out after it, never inside it")
    func typingDuringAPaste() {
        let clock = Clock()
        var sent: [[UInt8]] = []
        let paced = PacedInput(after: clock.after) { sent.append($0) }
        let paste = [UInt8](repeating: 0x70, count: 2500)

        paced.enqueue(paste[...])
        paced.enqueue(Array("ls\r".utf8)[...])     // typed while piece one is in its gap
        clock.tick()
        paced.enqueue([0x03])                       // and ^C a piece later
        clock.runOut()

        #expect(sent.flatMap { $0 } == paste + Array("ls\r".utf8) + [0x03])
        #expect(sent.allSatisfy { $0.count <= 1000 })
        // The paste's own pieces are all paste: a keystroke never lands inside one.
        #expect(sent[0] == [UInt8](repeating: 0x70, count: 1000))
        #expect(sent[1] == [UInt8](repeating: 0x70, count: 1000))
    }

    @Test("a keystroke on an idle wire is not held for a gap")
    func keystroke() {
        let clock = Clock()
        var sent: [[UInt8]] = []
        let paced = PacedInput(after: clock.after) { sent.append($0) }
        paced.enqueue([0x61])
        #expect(sent == [[0x61]])
        clock.runOut()
        paced.enqueue([0x62])
        #expect(sent == [[0x61], [0x62]])
    }

    @Test("a wire that goes mid-paste gets the rest back, once")
    func backlog() {
        let clock = Clock()
        var sent: [[UInt8]] = []
        let paced = PacedInput(after: clock.after) { sent.append($0) }
        let paste = (0..<2500).map { UInt8(truncatingIfNeeded: $0) }
        paced.enqueue(paste[...])
        let rest = paced.takeBacklog()
        #expect(sent.flatMap { $0 } + rest == paste)
        clock.runOut()
        #expect(sent.count == 1)
        #expect(paced.takeBacklog().isEmpty)
    }
}

/// The door itself: `TerminalPaneController.paste(_:asking:)`, with a wire
/// that records what reached it.
@Suite("a risky paste asks before a byte is sent", .serialized)
@MainActor
struct PasteSheetTests {
    private final class Wire: RelayAttachment {
        let sessionId = "paste-sheet-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) {}
        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let wire = Wire()
        /// A pasteboard nobody else has. Never `NSPasteboard.general`.
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.paste-sheet.\(UUID().uuidString)"))

        init(config: Config = Config()) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-paste-sheet-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "paste-sheet", near: nil)
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
            pasteboard.clearContents()
        }

        /// The outbound queue drains on the main queue; give it its turns.
        func settle() async throws { try await Task.sleep(nanoseconds: 120_000_000) }

        func close() {
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("several lines: a sheet goes up over the pane and nothing is sent")
    func asks() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.paste(.init(text: "rm -rf build\nmake\nmake install\n"))
        try await rig.settle()
        let sheet = try #require(rig.pane.pasteSheet)
        #expect(sheet.superview === rig.pane.view)
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("cancel, by button, Esc or Return, sends nothing, and the sheet is gone")
    func cancels() async throws {
        for key: UInt16? in [nil, 53, 36] {
            let rig = try Rig()
            defer { rig.close() }
            rig.pane.paste(.init(text: "one\ntwo"))
            let sheet = try #require(rig.pane.pasteSheet)
            if let key {
                let event = try #require(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                    context: nil, characters: key == 53 ? "\u{1b}" : "\r",
                    charactersIgnoringModifiers: key == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: key))
                sheet.keyDown(with: event)
            } else {
                sheet.answer(.cancelled)
            }
            try await rig.settle()
            #expect(rig.pane.pasteSheet == nil)
            #expect(sheet.superview == nil)
            #expect(rig.wire.sent.isEmpty, "keyCode \(String(describing: key)) sent \(rig.wire.text.debugDescription)")
        }
    }

    @Test("a pane torn down under an unanswered sheet sends nothing")
    func tornDown() async throws {
        let rig = try Rig()
        rig.pane.paste(.init(text: "one\ntwo"))
        let wire = rig.wire
        rig.close()
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(wire.sent.isEmpty)
    }

    @Test("Paste sends it as it is: P on the keyboard")
    func pastes() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.paste(.init(text: "one\ntwo\n"))
        let sheet = try #require(rig.pane.pasteSheet)
        let p = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "p", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        sheet.keyDown(with: p)
        try await rig.settle()
        #expect(rig.wire.text == "one\rtwo")
        #expect(rig.pane.pasteSheet == nil)
    }

    @Test("Paste as One Line sends no Return at all, and Tabs to Spaces sends no tab")
    func transforms() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.paste(.init(text: "curl \\\n\t-s example.com\n| jq .\n"))
        let sheet = try #require(rig.pane.pasteSheet)
        sheet.toggleTabs()
        #expect(sheet.tabsToSpaces)
        sheet.send(oneLine: true)
        try await rig.settle()
        #expect(rig.wire.text == "curl     -s example.com | jq .")
    }

    @Test("One Line is not offered to a paste of one line")
    func oneLineOnlyForLines() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.paste(.init(text: "a\tb"))
        let sheet = try #require(rig.pane.pasteSheet)
        sheet.send(oneLine: true)
        try await rig.settle()
        #expect(rig.pane.pasteSheet != nil)
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("a second paste while one is a question neither queues nor answers it")
    func oneAtATime() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.paste(.init(text: "one\ntwo"))
        let first = try #require(rig.pane.pasteSheet)
        rig.pane.paste(.init(text: "plain"))
        rig.pane.paste(.init(text: "plain"), asking: false)
        try await rig.settle()
        #expect(rig.pane.pasteSheet === first)
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("⌥⌘V, Paste Without Asking: no sheet, the same bytes ⌘V would have sent")
    func bypass() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pasteboard.setString("one\n\ttwo\n", forType: .string)
        let target = try #require(rig.pane.view as? TerminalPasteTarget)

        target.pasteIntoTerminalPane(nil)
        try await rig.settle()
        #expect(rig.pane.pasteSheet != nil)
        #expect(rig.wire.sent.isEmpty)
        rig.pane.pasteSheet?.answer(.cancelled)

        target.pasteIntoTerminalPaneWithoutAsking(nil)
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == "one\r\ttwo")
    }

    @Test("the command: ⌥⌘V by default, rebindable, in the Edit menu")
    func command() {
        let command = Command.pasteWithoutAsking
        #expect(command.title == "Paste Without Asking")
        #expect(command.menu == .edit)
        #expect(Keymap.defaults.chords(for: command) == [KeyChord(key: "v", modifiers: [.command, .option])])
        #expect(Command(rawValue: "pasteWithoutAsking") == command)
    }

    @Test("with the settings off a paste of several lines goes straight out")
    func settingsOff() async throws {
        var config = Config()
        config.pasteConfirmMultiline = false
        let rig = try Rig(config: config)
        defer { rig.close() }
        rig.pane.paste(.init(text: "one\ntwo"))
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == "one\rtwo")
    }

    @Test("the settings are read at each paste, not when the pane was built")
    func live() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var now = Config()
        rig.pane.liveConfig = { now }
        now.pasteConfirmMultiline = false
        rig.pane.paste(.init(text: "one\ntwo"))
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == "one\rtwo")
    }

    @Test("files copied in Finder never ask for their own separators, however odd the names")
    func files() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let names = ["/tmp/a b.txt", "/tmp/plain", "/tmp/it's $5!.png", "/tmp/naïve 界.md"]
        rig.pasteboard.writeObjects(names.map { path -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
            item.setString((path as NSString).lastPathComponent, forType: .string)
            return item
        })
        let clipboard = TerminalPaste.clipboard(rig.pasteboard)
        #expect(!TerminalPaste.asksFirst(try #require(clipboard.text), .init()))
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == clipboard.text)
        #expect(rig.wire.text.components(separatedBy: "/tmp/").count == 5)
    }
}

/// The sheet as a picture, in both appearances, since a layout is not a list
/// of decisions. Gated on `MAXPANE_SHOTS`, so it costs nothing normally.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("paste sheet rendering")
@MainActor
struct PasteSheetRenderTests {
    @Test("renders the sheet over a lane-sized pane")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let text = """
            # install
            curl -fsSL https://example.com/install.sh \\
            \t| sh -s -- --prefix "$HOME/.local"
            export PATH="$HOME/.local/bin:$PATH"
            \u{1b}[31mred\u{1b}[0m and a very long line: \(String(repeating: "lorem ipsum ", count: 20))
            six
            seven
            eight
            nine
            ten

            """
        try AppearanceSheet.render(to: dir, named: "paste-ask-sheet") {
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 656, height: 420))
            host.wantsLayer = true
            host.layerBackgroundColor = Theme.laneBackground
            let sheet = PasteAskSheet(
                text: text, settings: .init(bytes: 256),
                terminalFont: NSFont(name: Config().fontName, size: 11)) { _ in }
            sheet.frame = host.bounds
            sheet.autoresizingMask = [.width, .height]
            host.addSubview(sheet)
            return host
        }
    }
}
