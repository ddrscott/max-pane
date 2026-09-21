import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import MaxPaneKit
@testable import RelayClient

/// What libghostty's `readSelection()` returned on a real surface 73 columns
/// wide, for: a line with trailing spaces, a 120-character line (soft-wrapped
/// over two rows), a coloured line with trailing spaces, and a last line.
/// Captured once and kept, so the pure half is tested on the real thing.
private let captured =
    "trail   \n" + String(repeating: "abcdefghij", count: 12) + "\nred bold    \nlast"

/// And the HTML `copy_to_clipboard:html` wrote for the same selection.
private let capturedHTML =
    "<div style=\"font-family: monospace; white-space: pre;background-color: #1c1c1c;color: #d0d0d0;\">trail   \n"
    + String(repeating: "abcdefghij", count: 12)
    + "\n<div style=\"display: inline;color: rgb(172, 65, 66);\">red</div> "
    + "<div style=\"display: inline;color: rgb(126, 142, 80);font-weight: bold;\">bold</div>    \nlast</div>"

@Suite("what a copy out of a terminal puts on the clipboard")
struct TerminalCopyCleanTests {
    @Test("trailing spaces and tabs go from every line; a wrapped line stays one line; no newline is added")
    func trims() {
        let clean = TerminalCopy.clean(captured, trimTrailing: true)
        #expect(clean == "trail\n" + String(repeating: "abcdefghij", count: 12) + "\nred bold\nlast")
        #expect(clean.split(separator: "\n").count == 4, "the 120 characters are one line, as they were typed")
        #expect(!clean.hasSuffix("\n"))
        #expect(TerminalCopy.clean("a \t \nb\t", trimTrailing: true) == "a\nb")
    }

    @Test("leading and inner whitespace, blank lines and a selected final newline are content")
    func keeps() {
        #expect(TerminalCopy.clean("  a  b  \n\n    c\n", trimTrailing: true) == "  a  b\n\n    c\n")
        #expect(TerminalCopy.clean("", trimTrailing: true) == "")
        #expect(TerminalCopy.clean("a\r\nb  \r\n", trimTrailing: true) == "a\nb\n")
    }

    @Test("copy_trim_trailing = false copies the selection as the emulator gave it")
    func off() {
        #expect(TerminalCopy.clean(captured, trimTrailing: false) == captured)
    }

    @Test("a rectangular selection is one line per row, each trimmed")
    func rectangle() {
        // As captured from a ⌃⌥-drag over columns 4…8 of three rows.
        #expect(TerminalCopy.clean(" 48 a\n 49  \n 50 a", trimTrailing: true) == " 48 a\n 49\n 50 a")
    }

    @Test("copy_trim_trailing: on by default, under Terminals, read at each copy")
    @MainActor
    func setting() throws {
        #expect(Config().copyTrimTrailing)
        let field = try #require(ConfigField.all.first { $0.key == "copy_trim_trailing" })
        #expect(field.group == .terminals)
        #expect(field.appliesLive)
        #expect(ConfigFile.decode(TomlDocument("copy_trim_trailing = false\n")).0.copyTrimTrailing == false)
        // The emulator's own copy (`copy_on_select`) is told the same thing.
        func line(_ config: Config) -> [String] {
            TerminalControllerPool.makeController(for: config).terminalConfiguration.rendered
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("clipboard-trim") }
        }
        var off = Config()
        off.copyTrimTrailing = false
        #expect(line(Config()) == ["clipboard-trim-trailing-spaces = true"])
        #expect(line(off) == ["clipboard-trim-trailing-spaces = false"])
    }
}

@Suite("Copy with Styles: the emulator's HTML, read and written again")
struct TerminalCopyStyledTests {
    @Test("the runs, their colours and weight, and the terminal's own colours behind them")
    func parses() throws {
        let styled = try #require(TerminalCopy.parse(html: capturedHTML))
        #expect(styled.background == TerminalCopy.RGB(r: 0x1c, g: 0x1c, b: 0x1c))
        #expect(styled.foreground == TerminalCopy.RGB(r: 0xd0, g: 0xd0, b: 0xd0))
        #expect(styled.plain == captured)
        let red = try #require(styled.runs.first { $0.text == "red" })
        #expect(red.foreground == TerminalCopy.RGB(r: 172, g: 65, b: 66))
        #expect(!red.bold)
        let bold = try #require(styled.runs.first { $0.text == "bold" })
        #expect(bold.bold)
        #expect(bold.foreground == TerminalCopy.RGB(r: 126, g: 142, b: 80))
    }

    @Test("entities are text, and anything that is not the emulator's HTML is refused")
    func entitiesAndRefusals() throws {
        let styled = try #require(TerminalCopy.parse(
            html: "<div style=\"white-space: pre;\">a &lt;b&gt; &amp;&amp; &#955; &quot;q&quot;</div>"))
        #expect(styled.plain == "a <b> && λ \"q\"")
        #expect(TerminalCopy.parse(html: "plain text") == nil)
        #expect(TerminalCopy.parse(html: "<div>unclosed") == nil)
        #expect(TerminalCopy.parse(html: "<div><script>x</script></div>") == nil)
    }

    @Test("trimming is per line, and a run with a background of its own is a bar somebody drew")
    func cleansStyled() throws {
        let styled = try #require(TerminalCopy.parse(html: capturedHTML))
        let clean = TerminalCopy.clean(styled, trimTrailing: true)
        #expect(clean.plain == TerminalCopy.clean(captured, trimTrailing: true))
        #expect(clean.runs.first { $0.text == "bold" }?.bold == true)

        let bar = try #require(TerminalCopy.parse(
            html: "<div style=\"white-space: pre;\">x <div style=\"display: inline;background-color: #ff0000;\">   </div>\ny  </div>"))
        #expect(TerminalCopy.clean(bar, trimTrailing: true).plain == "x    \ny")
        #expect(TerminalCopy.clean(styled, trimTrailing: false) == styled)
    }

    @Test("HTML out: one <pre> in the terminal's font and colours, escaped")
    func html() throws {
        var styled = try #require(TerminalCopy.parse(html: capturedHTML))
        styled.runs.append(TerminalCopy.Run(text: "<&>"))
        let html = TerminalCopy.html(styled, fontName: "JetBrains Mono", fontSize: 13)
        #expect(html.contains("font-family: 'JetBrains Mono', monospace"))
        #expect(html.contains("font-size: 13pt"))
        #expect(html.contains("background-color: #1c1c1c"))
        #expect(html.contains("<span style=\"color: #ac4142\">red</span>"))
        #expect(html.contains("font-weight: bold"))
        #expect(html.contains("&lt;&amp;&gt;"))
    }

    @Test("the pasteboard gets plain text, RTF and HTML under the types apps read; never the general one")
    @MainActor
    func writes() throws {
        let board = NSPasteboard(name: .init("maxpane.tests.copy-styles.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let styled = TerminalCopy.clean(try #require(TerminalCopy.parse(html: capturedHTML)), trimTrailing: true)
        TerminalCopy.write("plain", styled: styled, fontName: "Menlo", fontSize: 12, to: board)
        #expect(board.string(forType: .string) == "plain")
        #expect(board.string(forType: .html)?.contains("<pre") == true)
        let rtf = try #require(board.data(forType: .rtf))
        let back = try #require(NSAttributedString(rtf: rtf, documentAttributes: nil))
        #expect(back.string == styled.plain)
        let at = (back.string as NSString).range(of: "bold").location
        let font = try #require(back.attribute(.font, at: at, effectiveRange: nil) as? NSFont)
        #expect(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
        #expect(font.familyName == "Menlo")

        TerminalCopy.write("only", to: board)
        #expect(board.types?.contains(.rtf) != true)
        #expect(board.string(forType: .string) == "only")
    }
}

@Suite("the commands: ⌥⌘C and ⇧⌘C")
struct TerminalCopyCommandTests {
    @Test("under Edit beside Copy, rebindable, on free chords, and a page's in a web pane")
    func commands() {
        for (command, title, chord) in [
            (Command.copyWithStyles, "Copy with Styles", KeyChord(key: "c", modifiers: [.command, .option])),
            (Command.copyMode, "Copy Mode", KeyChord(key: "c", modifiers: [.command, .shift])),
        ] {
            #expect(command.title == title)
            #expect(command.menu == .edit)
            #expect(command.submenu == nil)
            #expect(command.followsCopy)
            #expect(command.yieldsToPage)
            #expect(Command(rawValue: command.rawValue) == command)
            #expect(Keymap.defaults.chords(for: command) == [chord])
            #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [command])
            #expect(!Keymap.defaults.claimed.contains(chord), "a web pane's page keeps it")
        }
        #expect(Command.copyMode.activeTitle == "Leave Copy Mode")
        #expect(Command.allCases.filter(\.followsCopy) == [.copyWithStyles, .copyMode])
    }

    @Test("COPY MODE borrows the state chip's column, above COPIED and below BLOCKED and a dead server")
    func chip() {
        var model = LaneHeaderModel()
        #expect(model.borrowedChip == nil)
        model.copied = true
        #expect(model.borrowedChip?.word == "COPIED")
        model.copyMode = true
        #expect(model.borrowedChip?.word == "COPY MODE")
        #expect(model.borrowedChip?.glyph == "M")
        #expect(!model.showsCopied)
        model.state = .blocked
        #expect(model.borrowedChip == nil)
    }
}

// MARK: - copy mode's keys

@Suite("copy mode: the key table, with no terminal in it")
struct CopyModeKeyTests {
    /// 20×10, 100 rows of history, looking at the last ten, cursor bottom-left.
    private func mode(column: Int = 0, row: Int = 99) -> CopyMode {
        CopyMode(columns: 20, rows: 10, total: 100, offset: 90, cursor: .init(column: column, row: row))
    }

    private func press(_ mode: inout CopyMode, _ keys: String, lines: [Int: String] = [:]) -> [CopyMode.Effect] {
        var effects: [CopyMode.Effect] = []
        for c in keys { effects += mode.press(.character(c)) { lines[$0] } }
        return effects
    }

    @Test("h j k l and the arrows move one cell, and stop at the edges of the grid and of history")
    func cells() {
        var m = mode(column: 5, row: 95)
        _ = press(&m, "hhkl")
        #expect(m.cursor == .init(column: 4, row: 94))
        _ = m.press(.left); _ = m.press(.up); _ = m.press(.right); _ = m.press(.down)
        #expect(m.cursor == .init(column: 4, row: 94))
        _ = press(&m, String(repeating: "h", count: 30))
        #expect(m.cursor.column == 0)
        _ = press(&m, String(repeating: "l", count: 30))
        #expect(m.cursor.column == 19)
        _ = press(&m, String(repeating: "j", count: 30))
        #expect(m.cursor.row == 99)
        #expect(m.offset == 90)
    }

    @Test("moving past the top of the viewport takes the viewport with it, into the scrollback and no further")
    func scrolls() {
        var m = mode(row: 90)
        _ = press(&m, "k")
        #expect(m.cursor.row == 89)
        #expect(m.offset == 89)
        #expect(m.viewportRow == 0)
        _ = press(&m, String(repeating: "k", count: 200))
        #expect(m.cursor.row == 0)
        #expect(m.offset == 0)
        _ = press(&m, "j")
        #expect(m.offset == 0)
        #expect(m.viewportRow == 1)
    }

    @Test("⌃U ⌃D half a page and ⌃B ⌃F a page, the cursor keeping its place on screen; g and G the ends")
    func pages() {
        var m = mode(row: 95)
        _ = m.press(.control("u"))
        #expect(m.offset == 85)
        #expect(m.cursor.row == 90)
        _ = m.press(.control("d"))
        #expect(m.offset == 90)
        #expect(m.cursor.row == 95)
        _ = m.press(.control("b"))
        #expect(m.offset == 80)
        _ = m.press(.pageDown)
        #expect(m.offset == 90)
        // At the bottom already: the cursor goes, the view cannot.
        _ = m.press(.control("d"))
        #expect(m.offset == 90)
        #expect(m.cursor.row == 99)
        _ = press(&m, "g")
        #expect(m.cursor == .init(column: 0, row: 0))
        #expect(m.offset == 0)
        _ = press(&m, "G")
        #expect(m.cursor.row == 99)
        #expect(m.offset == 90)
    }

    @Test("0 ^ $ w b read the line; a word is what whitespace separates")
    func words() {
        let lines = [98: "  tail of 98", 99: "  src/a.ts:42  done   "]
        var m = mode()
        _ = press(&m, "^", lines: lines)
        #expect(m.cursor.column == 2)
        _ = press(&m, "w", lines: lines)
        #expect(m.cursor.column == 15)
        _ = press(&m, "$", lines: lines)
        #expect(m.cursor.column == 18, "the last character, not the trailing blanks")
        _ = press(&m, "b", lines: lines)
        #expect(m.cursor.column == 15)
        _ = press(&m, "bb", lines: lines)
        #expect(m.cursor == .init(column: 10, row: 98), "b at the first word goes to the last word of the line above")
        _ = press(&m, "ww", lines: lines)
        #expect(m.cursor == .init(column: 15, row: 99))
        _ = press(&m, "0", lines: lines)
        #expect(m.cursor.column == 0)
        // A row that is not on screen has no text: $ is the margin.
        _ = press(&m, "$")
        #expect(m.cursor.column == 19)
    }

    @Test("v selects from the cell it was pressed on; V whole lines, either way up; each toggles off")
    func selects() {
        var m = mode(column: 3, row: 95)
        #expect(m.drag == nil)
        _ = press(&m, "vllj")
        #expect(m.drag?.from == .init(column: 3, row: 95))
        #expect(m.drag?.to == .init(column: 5, row: 96))
        _ = press(&m, "v")
        #expect(m.drag == nil)
        _ = press(&m, "Vjj")
        #expect(m.drag?.from == .init(column: 0, row: 96))
        #expect(m.drag?.to == .init(column: 19, row: 98))
        _ = press(&m, "kkkk")
        #expect(m.drag?.from == .init(column: 19, row: 96))
        #expect(m.drag?.to == .init(column: 0, row: 94))
        _ = press(&m, "v")
        #expect(m.selecting == .characters(m.cursor), "v from V is a character selection from here")
    }

    @Test("a selection can start on one screen and end on another")
    func acrossScreens() {
        var m = mode(row: 99)
        _ = press(&m, "V" + String(repeating: "k", count: 40))
        #expect(m.drag?.from.row == 99)
        #expect(m.drag?.to.row == 59)
        #expect(m.offset == 59)
    }

    @Test("y and ↩ copy and leave, with a selection; Esc and q leave; nothing else has an effect")
    func leaves() {
        var m = mode()
        #expect(press(&m, "y") == [])
        #expect(m.press(.enter) == [])
        _ = press(&m, "v")
        #expect(press(&m, "y") == [.copy, .leave])
        #expect(m.press(.enter) == [.copy, .leave])
        #expect(m.press(.escape) == [.leave])
        #expect(press(&m, "q") == [.leave])
        #expect(press(&m, "axz;:!") == [])
        #expect(m.press(.control("c")) == [])
    }

    @Test("/ types a search in the notice line: ↩ finds, ⌫ edits, Esc drops it; n and N step")
    func finds() {
        var m = mode()
        #expect(press(&m, "n") == [], "nothing searched for yet")
        #expect(press(&m, "/erq") == [])
        #expect(m.status == "/erq")
        #expect(m.cursor == .init(column: 0, row: 99), "q and the rest are letters while a search is typed")
        _ = m.press(.backspace)
        #expect(press(&m, "r") == [])
        #expect(m.press(.enter) == [.find("err")])
        #expect(m.needle == nil)
        #expect(press(&m, "n") == [.findAgain(older: true)])
        #expect(press(&m, "N") == [.findAgain(older: false)])
        _ = press(&m, "/x")
        #expect(m.press(.escape) == [], "Esc leaves the search line, not copy mode")
        #expect(m.needle == nil)
        #expect(m.found == "err")
        _ = press(&m, "/")
        #expect(m.press(.enter) == [])
        _ = press(&m, "/")
        _ = m.press(.backspace)
        #expect(m.needle == nil)
    }

    @Test("a viewport that moved by itself keeps the cursor on screen; a search lands it on a cell")
    func moved() {
        var m = mode(column: 4, row: 99)
        m.moved(toOffset: 40)
        #expect(m.offset == 40)
        #expect(m.cursor == .init(column: 4, row: 49))
        m.moved(toOffset: 10, cursor: .init(column: 7, row: 12))
        #expect(m.cursor == .init(column: 7, row: 12))
        #expect(m.viewportRow == 2)
        m.moved(toOffset: 500)
        #expect(m.offset == 90)
    }

    @Test("a search lands on the occurrence nearest the cursor, case ignored")
    func nearest() {
        let lines = ["error: one", "ok", "  Error two and error three", "ok"]
        #expect(CopyMode.nearest("ERROR", in: lines, to: (0, 3))?.row == 2)
        #expect(CopyMode.nearest("error", in: lines, to: (20, 2))?.column == 16)
        #expect(CopyMode.nearest("error", in: lines, to: (0, 0))! == (0, 0))
        #expect(CopyMode.nearest("absent", in: lines, to: (0, 0)) == nil)
        #expect(CopyMode.nearest("", in: lines, to: (0, 0)) == nil)
    }

    @Test("a ⌘-chord is not copy mode's; ⌃ and a letter is; the named keys by key code")
    @MainActor
    func events() throws {
        func event(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
                context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                isARepeat: false, keyCode: code))
        }
        #expect(CopyMode.key(for: try event("j", 38)) == .character("j"))
        #expect(CopyMode.key(for: try event("G", 5, [.shift])) == .character("G"))
        #expect(CopyMode.key(for: try event("\u{15}", 32, [.control])) == .control("u"))
        #expect(CopyMode.key(for: try event("\u{1b}", 53)) == .escape)
        #expect(CopyMode.key(for: try event("\r", 36)) == .enter)
        #expect(CopyMode.key(for: try event("c", 8, [.command])) == nil)
    }
}

// MARK: - on a real surface

/// The pane's copy and copy mode against a real libghostty surface. Two
/// pasteboards, neither the owner's (`GeneralPasteboardStandIn`).
@Suite("copying out of a real terminal", .serialized)
@MainActor
struct TerminalCopySurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "copy-side-test"
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
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let wire = Wire()
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.copy-side.\(UUID().uuidString)"))
        let general = GeneralPasteboardStandIn.pasteboard
        var config: Config
        var chipChanges = 0

        init(config: Config = Config()) async throws {
            self.config = config
            await GeneralPasteboardStandIn.take()
            #expect(NSPasteboard.general === general)
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-copy-side-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "copy-side", near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.pasteboard = pasteboard
            pane.attach(wire)
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 400)
            window.contentView?.addSubview(pane.view)
            pane.liveConfig = { [unowned self] in self.config }
            pane.onCopyModeChanged = { [unowned self] in self.chipChanges += 1 }
            window.contentView?.layoutSubtreeIfNeeded()
            pasteboard.clearContents()
            pasteboard.setString("before", forType: .string)
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

        var terminal: ClickableTerminalView {
            func find(_ view: NSView) -> ClickableTerminalView? {
                if let hit = view as? ClickableTerminalView { return hit }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(pane.view)!
        }

        func prints(_ text: String) async throws {
            wire.onData?(ArraySlice(Array(text.utf8)))
            try await settle()
        }

        func selectAll() async throws {
            #expect(terminal.performBindingAction("select_all"))
            try await settle()
        }

        func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }

        /// Real key events, handed to the view the way AppKit hands them.
        func keys(_ text: String, _ flags: NSEvent.ModifierFlags = []) async throws {
            for c in text { try key(String(c), code: c == "\u{1b}" ? 53 : c == "\r" ? 36 : 0, flags) }
            try await idle()
        }

        func key(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws {
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                isARepeat: false, keyCode: code))
            terminal.keyDown(with: event)
            let up = try #require(NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased(),
                isARepeat: false, keyCode: code))
            terminal.keyUp(with: up)
        }

        func idle() async throws {
            for _ in 0..<400 {
                try await Task.sleep(nanoseconds: 20_000_000)
                if !pane.copyDriver.isBusy { break }
            }
            try await Task.sleep(nanoseconds: 60_000_000)
        }

        var copied: String? { pasteboard.string(forType: .string) }
        var history: [String] { store.clipHistory(config).map(\.content) }
        var screen: String { pane.viewportText }

        func close() {
            GeneralPasteboardStandIn.giveBack()
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static let long = String(repeating: "abcdefghij", count: 12)

    @Test("FINDING: the emulator's own copy joins a wrapped line, trims, and adds an HTML flavour no app reads")
    func whatCommandCDidBefore() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints("trail   \r\n\(Self.long)\r\nlast")
        #expect(rig.screen.components(separatedBy: "\n").prefix(4).count == 4, "the long line is on two rows")
        try await rig.selectAll()
        #expect(rig.terminal.performBindingAction("copy_to_clipboard"))
        try await rig.settle()
        #expect(rig.general.string(forType: .string) == "trail\n\(Self.long)\nlast")
        #expect(rig.general.types?.contains(TerminalCopy.libraryHTMLType) == true)
        #expect(rig.general.types?.contains(.html) != true)
    }

    @Test("⌘C is the pane's: cleaned, on the pane's pasteboard, kept in paste history as it landed")
    func copies() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints("trail   \r\n\(Self.long)\r\nlast")
        rig.terminal.copy(nil)
        #expect(rig.copied == "before", "nothing selected: nothing copied")
        try await rig.selectAll()
        rig.terminal.copy(nil)
        try await rig.settle()
        #expect(rig.copied == "trail\n\(Self.long)\nlast")
        #expect(rig.pasteboard.types?.contains(.html) != true)
        #expect(rig.general.string(forType: .string) == "general-secret", "the library did not copy as well")
        #expect(rig.history.first == "trail\n\(Self.long)\nlast")

        rig.config.copyTrimTrailing = false
        rig.terminal.copy(nil)
        #expect(rig.copied == "trail   \n\(Self.long)\nlast")
    }

    @Test("⌥⌘C, Copy with Styles: plain text, RTF and HTML, in the terminal's colours and font")
    func styles() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints("plain \u{1b}[31mred\u{1b}[0m \u{1b}[1mbold\u{1b}[0m   ")
        #expect(!rig.pane.copySelection(styled: true))
        #expect(rig.pane.noticeText == "not copied: nothing is selected")
        try await rig.selectAll()
        #expect(rig.pane.copySelection(styled: true))
        #expect(rig.copied == "plain red bold")
        let html = try #require(rig.pasteboard.string(forType: .html))
        #expect(html.contains("font-family: 'JetBrains Mono'"))
        #expect(html.contains(">red</span>"))
        #expect(html.contains("font-weight: bold"))
        let rtf = try #require(rig.pasteboard.data(forType: .rtf))
        #expect(NSAttributedString(rtf: rtf, documentAttributes: nil)?.string == "plain red bold")
        #expect(rig.pane.noticeText?.hasPrefix("copied with styles") == true)
        #expect(rig.history.first == "plain red bold")
    }

    private func rows(_ range: ClosedRange<Int>) -> String {
        range.map { "row \($0) alpha" }.joined(separator: "\n")
    }

    @Test("copy mode: keys move a cursor and select, y copies and leaves, and the pty hears nothing")
    func copyMode() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        // A program that asked for the mouse, and for key releases (kitty).
        try await rig.prints((0..<120).map { "row \($0) alpha   \r\n" }.joined() + "\u{1b}[?1000h\u{1b}[?1006h\u{1b}[>11u")
        rig.wire.sent.removeAll()

        rig.pane.toggleCopyMode()
        #expect(rig.pane.isInCopyMode)
        #expect(rig.chipChanges == 1)
        #expect(rig.pane.noticeText?.hasPrefix("copy mode") == true)
        #expect(rig.pane.copyDriver.cursorCell?.column == 0)
        // The cell is the emulator's own measure, not a division of the view.
        #expect((rig.pane.copyDriver.metrics?.cellWidthPixels ?? 0) > 0)
        #expect((rig.pane.copyDriver.metrics?.cellHeightPixels ?? 0) > 0)

        try await rig.keys("kk0v$")
        #expect(rig.pane.noticeText == "copy mode · selecting · y copies · Esc leaves")
        try await rig.keys("y")
        #expect(rig.copied == "row 117 alpha")
        #expect(!rig.pane.isInCopyMode)
        #expect(rig.chipChanges == 2)
        #expect(rig.pane.noticeText == "copied · 1 line")
        #expect(rig.history.first == "row 117 alpha")
        #expect(rig.wire.sent.isEmpty, "no key, and no click, reached the pty: \(rig.wire.sent)")
        #expect(rig.general.string(forType: .string) == "general-secret")
    }

    @Test("copy mode: a selection from this screen back into the scrollback, line-wise, in one piece")
    func acrossScrollback() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints((0..<120).map { "row \($0) alpha\r\n" }.joined() + "\u{1b}[?1000h\u{1b}[?1006h")
        rig.wire.sent.removeAll()
        rig.pane.toggleCopyMode()
        try await rig.keys("V" + String(repeating: "k", count: 60))
        #expect(rig.screen.hasPrefix("row 59 alpha"), "the viewport followed the cursor")
        try await rig.keys("jj")
        try await rig.keys("\r")
        #expect(rig.copied == rows(61...119))
        #expect(rig.wire.sent.isEmpty)
        // Left: the view is back at the bottom, and nothing is selected.
        try await rig.settle()
        #expect(rig.screen.contains("row 119 alpha"))
        rig.terminal.copy(nil)
        #expect(rig.copied == rows(61...119))
    }

    @Test("copy mode holds the screen still: output waits, and arrives when it ends")
    func holdsOutput() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints("one\r\ntwo\r\n")
        rig.pane.toggleCopyMode()
        try await rig.prints("LATE\r\n")
        #expect(!rig.screen.contains("LATE"))
        try await rig.keys("\u{1b}")
        try await rig.settle()
        #expect(!rig.pane.isInCopyMode)
        #expect(rig.screen.contains("LATE"))
        #expect(rig.pane.noticeText == nil)
        #expect(rig.wire.sent.isEmpty, "Esc left copy mode and was not typed")
        // ⇧⌘C again is the way out too.
        rig.pane.toggleCopyMode()
        rig.pane.toggleCopyMode()
        #expect(!rig.pane.isInCopyMode)
    }

    @Test("copy mode: / finds in the scrollback and puts the cursor on it; n goes on to the one before")
    func finds() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints((0..<120).map { "row \($0) \($0 % 50 == 7 ? "needle" : "alpha")\r\n" }.joined())
        rig.pane.toggleCopyMode()
        try await rig.keys("/NEEDLE")
        #expect(rig.pane.noticeText == "/NEEDLE")
        try await rig.keys("\r")
        try await rig.keys("Vy")
        #expect(rig.copied == "row 107 needle")

        rig.pane.toggleCopyMode()
        try await rig.keys("/needle\r")
        try await rig.keys("n")
        try await rig.keys("Vy")
        #expect(rig.copied == "row 57 needle")

        rig.pane.toggleCopyMode()
        try await rig.keys("/absent\r")
        #expect(rig.pane.noticeText == "not found: absent")
        #expect(rig.pane.isInCopyMode)
    }
}
