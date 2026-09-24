import Testing
import AppKit
import Foundation
import LanedCore
@testable import MaxPaneKit

// serial pass: a real surface, settled against the wall clock. The whole suite
// runs in `scripts/test.sh`'s second, --no-parallel pass; see README, "The
// serial pass".

/// Advanced Paste (ADR-0032): the order the steps are applied in, the regular
/// expression, and that the sheet shows and sends `TerminalPaste.compose` and
/// nothing else. Every pasteboard here is a private named one;
/// `NSPasteboard.general` is never read or written.

private typealias Advanced = TerminalPaste.Advanced

@Suite("advanced paste: the order of application")
struct AdvancedPasteOrderTests {
    @Test("no toggles and no pattern is the text")
    func nothing() {
        let text = "  “one”\t\n$ two\n"
        #expect(TerminalPaste.compose(text, Advanced()) == TerminalPaste.Composed(text: text))
    }

    @Test("each toggle alone is the function it names")
    func each() {
        let text = "$ echo “hi”\t \n$ ls\t-la\n"
        let expected: [Advanced.Step: String] = [
            .straighten: TerminalPaste.straightenPunctuation(text),
            .stripPrompt: TerminalPaste.stripPrompt(text),
            .trimStray: TerminalPaste.trimStray(text),
            .tabsToSpaces: TerminalPaste.tabsToSpaces(text, width: 3),
            .oneLine: TerminalPaste.oneLine(text),
            .escape: TerminalPaste.escaped(text)!,
            .base64Encode: TerminalPaste.base64Encoded(text),
        ]
        for (step, want) in expected {
            #expect(TerminalPaste.compose(text, Advanced(steps: [step], tabWidth: 3)).text == want, "\(step)")
        }
        let encoded = TerminalPaste.base64Encoded(text)
        #expect(TerminalPaste.compose(encoded, Advanced(steps: [.base64Decode])).text == text)
    }

    @Test("all of them: decode, tidy in ⌘V's order, the pattern, tabs, one line, escape, encode")
    func all() throws {
        let text = "$ echo “a\tb” \n$ printf\t'%s' x\n"
        var advanced = Advanced(steps: Set(Advanced.Step.allCases), pattern: "^(\\w+)", replacement: "/bin/$1", tabWidth: 2)
        var want = text
        want = TerminalPaste.straightenPunctuation(want)
        want = TerminalPaste.stripPrompt(want)
        want = TerminalPaste.trimStray(want)
        guard case .replaced(let replaced, let count) = TerminalPaste.substitute(want, pattern: "^(\\w+)", replacement: "/bin/$1")
        else { Issue.record("the pattern is fine"); return }
        #expect(count == 2)
        want = TerminalPaste.tabsToSpaces(replaced, width: 2)
        want = TerminalPaste.oneLine(want)
        want = try #require(TerminalPaste.escaped(want))
        let plain = want
        want = TerminalPaste.base64Encoded(want)

        let composed = TerminalPaste.compose(TerminalPaste.base64Encoded(text), advanced)
        #expect(composed.text == want)
        #expect(composed.replacements == 2)
        #expect(composed.problem == nil)

        advanced.steps.remove(.base64Encode)
        #expect(TerminalPaste.compose(TerminalPaste.base64Encoded(text), advanced).text == plain)
        #expect(plain == "\"/bin/echo \\\"a  b\\\" /bin/printf  '%s' x\"")
    }

    @Test("the order is the enum's, not the order the toggles were switched on in")
    func fixed() {
        #expect(Advanced.Step.allCases == Advanced.Step.beforeRegex + Advanced.Step.afterRegex)
        #expect(Advanced.Step.allCases == Advanced.Step.allCases.sorted())
        var late = Advanced()
        for step in Advanced.Step.allCases.reversed() where step != .base64Decode { late.steps.insert(step) }
        var early = Advanced()
        for step in Advanced.Step.allCases where step != .base64Decode { early.steps.insert(step) }
        #expect(TerminalPaste.compose("a\n\tb\n", late) == TerminalPaste.compose("a\n\tb\n", early))
    }

    @Test("the pattern sees tabs and lines: it runs before Tabs to Spaces and One Line")
    func regexBeforeLayout() {
        let advanced = Advanced(steps: [.tabsToSpaces, .oneLine], pattern: "^\\t", replacement: "> ", tabWidth: 4)
        #expect(TerminalPaste.compose("a\n\tb\n\tc\td", advanced).text == "a > b > c    d")
    }

    @Test("the pattern meets straightened quotes and no prompt: it runs after tidying")
    func regexAfterTidy() {
        let advanced = Advanced(steps: [.straighten, .stripPrompt], pattern: "^echo \"(.*)\"$", replacement: "say $1")
        #expect(TerminalPaste.compose("$ echo “hi”", advanced).text == "say hi")
    }

    @Test("escape quotes what One Line left, so nothing in it is a Return")
    func escapeAfterOneLine() {
        let composed = TerminalPaste.compose("echo $HOME\nls", Advanced(steps: [.oneLine, .escape]))
        #expect(composed.text == "\"echo \\$HOME ls\"")
        #expect(!TerminalPaste.bytes(for: composed.text).contains(0x0d))
    }

    @Test("text that is not base64 refuses, and nothing is composed some other way")
    func refuses() {
        let composed = TerminalPaste.compose("not base64!", Advanced(steps: [.base64Decode, .oneLine]))
        #expect(composed.text.isEmpty)
        #expect(composed.refusal == "not pasted: this is not base64")
        #expect(composed.problem != nil)
    }

    @Test("escaping nothing is nothing")
    func empty() {
        #expect(TerminalPaste.compose("\n\n", Advanced(steps: [.escape])).text.isEmpty)
    }
}

@Suite("advanced paste: the regular expression")
struct AdvancedPasteRegexTests {
    @Test("groups: $1 and $2 in the template, $0 the match, \\$ a dollar")
    func groups() {
        #expect(TerminalPaste.substitute("john smith", pattern: "(\\w+) (\\w+)", replacement: "$2, $1")
            == .replaced("smith, john", count: 1))
        #expect(TerminalPaste.substitute("a b", pattern: "\\w", replacement: "[$0]") == .replaced("[a] [b]", count: 2))
        #expect(TerminalPaste.substitute("5", pattern: "\\d", replacement: "\\$$0") == .replaced("$5", count: 1))
    }

    @Test("an empty replacement deletes")
    func deletes() {
        #expect(TerminalPaste.substitute("a-b-c", pattern: "-", replacement: "") == .replaced("abc", count: 2))
    }

    @Test("^ and $ match at every line")
    func anchors() {
        #expect(TerminalPaste.substitute("a\nb", pattern: "^", replacement: "  ") == .replaced("  a\n  b", count: 2))
        #expect(TerminalPaste.substitute("a;\nb;", pattern: ";$", replacement: "") == .replaced("a\nb", count: 2))
    }

    @Test("no match is the text, zero times")
    func noMatch() {
        #expect(TerminalPaste.substitute("abc", pattern: "x+", replacement: "y") == .replaced("abc", count: 0))
        let composed = TerminalPaste.compose("abc", Advanced(pattern: "x+", replacement: "y"))
        #expect(composed.text == "abc")
        #expect(composed.replacements == 0)
        #expect(composed.problem == nil)
    }

    @Test("an invalid pattern is said, never thrown, and pastes nothing", arguments: ["(", "[a-", "a{2,1}", "\\", "(?<n", "*a"])
    func invalid(pattern: String) {
        guard case .invalid(let why) = TerminalPaste.substitute("abc", pattern: pattern, replacement: "x") else {
            Issue.record("\(pattern) compiled")
            return
        }
        #expect(why.hasPrefix("not a regular expression"))
        let composed = TerminalPaste.compose("abc", Advanced(steps: [.oneLine], pattern: pattern))
        #expect(composed.regexProblem == why)
        #expect(composed.text.isEmpty)
    }

    @Test("a template naming a group the pattern does not have, or ending in a backslash, does not throw",
          arguments: ["$9", "$1$2", "\\", "$", "${name}"])
    func oddTemplates(template: String) {
        guard case .replaced = TerminalPaste.substitute("abc", pattern: "(b)", replacement: template) else {
            Issue.record("a fine pattern was called invalid")
            return
        }
    }

    @Test("an empty pattern is off")
    func off() {
        #expect(TerminalPaste.compose("abc", Advanced(pattern: "", replacement: "x")).replacements == nil)
    }
}

@Suite("advanced paste: the sheet", .serialized)
@MainActor
struct AdvancedPasteSheetTests {
    typealias Rig = PasteHistoryDoorTests.Rig

    private func key(_ characters: String, code: UInt16, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private func open(_ rig: Rig, _ text: String, memory: AdvancedPasteMemory = AdvancedPasteMemory()) throws -> AdvancedPasteSheet {
        rig.pane.advancedMemory = memory
        rig.copy(text)
        let target = try #require(rig.pane.view as? TerminalPasteTarget)
        target.pasteSpecialIntoTerminalPane(Command.advancedPaste.rawValue as NSString)
        return try #require(rig.pane.advancedSheet)
    }

    @Test("the command: ⌥⇧⌘V, in Paste Special, rebindable, and a chord a page keeps")
    func command() {
        let command = Command.advancedPaste
        #expect(command.title == "Advanced Paste…")
        #expect(command.menu == .edit)
        #expect(command.submenu == "Paste Special")
        #expect(Command(rawValue: "advancedPaste") == command)
        let chord = KeyChord(key: "v", modifiers: [.command, .option, .shift])
        #expect(Keymap.defaults.chords(for: command) == [chord])
        #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [command])
        // A web pane asks `claimed` before it lets a page see a ⌘-chord.
        #expect(!Keymap.defaults.claimed.contains(chord), "the page gets ⌥⇧⌘V")
        #expect(Keymap.defaults.claimed.contains(KeyChord(key: "v", modifiers: [.command, .option])))
        // With ⌥⌘C and ⇧⌘C (ADR-0033) and ⌘K (ADR-0039): terminal-only, on
        // chords a browser or a page uses.
        #expect(Command.allCases.filter(\.yieldsToPage) == [.copyWithStyles, .copyMode, command, .clearScrollback])
    }

    @Test("it opens over the pane with the clipboard in it, nothing sent, every toggle off")
    func opens() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "one\n\ttwo\n")
        try await rig.settle()
        #expect(sheet.content == "one\n\ttwo\n")
        #expect(sheet.advanced.steps.isEmpty)
        #expect(rig.wire.sent.isEmpty)
        #expect(sheet.superview === rig.pane.view)
        // A second one, or a ⌘V, while it is up is neither queued nor an answer.
        rig.pane.advancedPaste()
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.pane.advancedSheet === sheet)
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("an empty clipboard opens nothing")
    func nothingCopied() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pane.advancedPaste()
        #expect(rig.pane.advancedSheet == nil)
    }

    @Test("what it sends is the composition, and the preview is those bytes")
    func outputIsTheComposition() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let text = "$ echo “a\tb” \n$ printf '\u{1b}[1m%s' x\n"
        let sheet = try open(rig, text)
        for step in [Advanced.Step.straighten, .stripPrompt, .trimStray, .tabsToSpaces] { sheet.toggle(step) }
        sheet.setRegex(pattern: "^(\\w+)", replacement: "/bin/$1")

        let want = TerminalPaste.compose(text, Advanced(
            steps: [.straighten, .stripPrompt, .trimStray, .tabsToSpaces], pattern: "^(\\w+)", replacement: "/bin/$1",
            tabWidth: Int(rig.config.pasteTabWidth)))
        #expect(sheet.composed == want)
        #expect(want.text == "/bin/echo \"a    b\"\n/bin/printf '\u{1b}[1m%s' x\n")
        let shown = sheet.previewLines
        let summary = sheet.summaryText

        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.pane.advancedSheet == nil)
        #expect(rig.wire.sent == TerminalPaste.bytes(for: want.text))
        // The preview, read back: the bytes on the wire with each control
        // character as its picture, a line per Return.
        let wire = rig.wire.text.split(separator: "\r", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: "\u{1b}", with: "␛")
        }
        #expect(shown == wire)
        #expect(summary == "2 lines · \(rig.wire.sent.count) bytes")
        #expect(rig.pane.pasteSheet == nil, "the sheet was the question: two lines do not ask again")
    }

    @Test("the content is editable, and what is sent is the edit")
    func edited() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "rm -rf /")
        sheet.editor.string = "ls /"
        sheet.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(sheet.previewLines == ["ls /"])
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.wire.text == "ls /")
        #expect(rig.kept == ["ls /"])
    }

    @Test("the content and both fields never have their text improved by macOS")
    func plainText() throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "echo \"--force\"...")
        #expect(PlainText.isHardened(sheet.editor))
        #expect(sheet.editor.font?.isFixedPitch == true)
        for field in [sheet.patternField, sheet.replacementField] {
            let editor = try #require(field.cell?.fieldEditor(for: field))
            #expect(PlainText.isHardened(editor))
            #expect(editor.isFieldEditor)
            #expect(editor !== rig.window.fieldEditor(true, for: nil), "not the window's shared one")
        }
        // Typed, as the keyboard would: what goes in is what is there.
        sheet.editor.string = ""
        sheet.editor.insertText("echo \"a\" -- 'b'...", replacementRange: NSRange(location: 0, length: 0))
        #expect(sheet.content == "echo \"a\" -- 'b'...")
    }

    @Test("keys: digits toggle in the column's order, P pastes, ↩ and Esc cancel")
    func keys() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var sheet = try open(rig, "a\n\tb")
        sheet.keyDown(with: try key("5", code: 23))
        sheet.keyDown(with: try key("6", code: 22))
        #expect(sheet.advanced.steps == [.tabsToSpaces, .oneLine])
        sheet.keyDown(with: try key("5", code: 23))
        #expect(sheet.advanced.steps == [.oneLine])
        sheet.keyDown(with: try key("9", code: 25))
        sheet.keyDown(with: try key("x", code: 7))
        #expect(sheet.advanced.steps == [.oneLine])
        sheet.keyDown(with: try key("p", code: 35))
        try await rig.settle()
        #expect(rig.wire.text == "a \tb")

        for code: UInt16 in [36, 53] {
            rig.wire.sent = []
            sheet = try open(rig, "one\ntwo")
            sheet.keyDown(with: try key("\r", code: code))
            try await rig.settle()
            #expect(rig.pane.advancedSheet == nil)
            #expect(rig.wire.sent.isEmpty)
        }
    }

    @Test("⌘↩ pastes from inside the content; ⌘V there pastes into the content, not the terminal")
    func fromTheEditor() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "ls")
        #expect(rig.window.makeFirstResponder(sheet.editor))
        #expect(sheet.holdsKeyboard)
        // The Edit menu's ⌘V asks the responder chain for a terminal first.
        // From the content, the first to answer is the sheet, which hands the
        // box a `paste:`, and not the pane's container beyond it. (`paste:`
        // itself reads the general pasteboard, which no test touches.)
        let action = #selector(TerminalPasteTarget.pasteIntoTerminalPane(_:))
        var responder: NSResponder? = sheet.editor
        while let next = responder, !next.responds(to: action) { responder = next.nextResponder }
        #expect(responder === sheet)
        sheet.pasteIntoTerminalPaneWithoutAsking(nil)
        sheet.pasteSpecialIntoTerminalPane(Command.pasteEscaped.rawValue as NSString)
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.advancedSheet === sheet)

        // A lane resized across the two arrangements mid-edit keeps the caret.
        #expect(sheet.isWide == true)
        rig.pane.view.frame.size.width = 400
        rig.pane.view.layoutSubtreeIfNeeded()
        #expect(sheet.isWide == false)
        #expect(rig.window.firstResponder === sheet.editor)

        #expect(sheet.performKeyEquivalent(with: try key("\r", code: 36, [.command])))
        try await rig.settle()
        #expect(rig.wire.text == "ls")
    }

    @Test("an invalid pattern, or text that will not decode, keeps the sheet up and sends nothing")
    func problems() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "hello, there!")
        sheet.setRegex(pattern: "(", replacement: "")
        #expect(sheet.composed.regexProblem != nil)
        #expect(sheet.previewLines.isEmpty)
        sheet.send(slowly: false)
        sheet.setRegex(pattern: "", replacement: "")
        sheet.toggle(.base64Decode)
        #expect(sheet.summaryText == "not pasted: this is not base64")
        sheet.send(slowly: true)
        try await rig.settle()
        #expect(rig.pane.advancedSheet === sheet)
        #expect(rig.wire.sent.isEmpty)
        sheet.toggle(.base64Decode)
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.wire.text == "hello, there!")
    }

    @Test("Paste Slowly sends the same bytes by the slow road")
    func slowly() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let sheet = try open(rig, "one\ntwo\n")
        sheet.keyDown(with: try key("s", code: 1))
        try await rig.settle()
        #expect(rig.wire.text == "one\rtwo")
        #expect(rig.kept == ["one\ntwo"])
    }

    @Test("the toggles and the pattern are remembered for the launch; the content never is")
    func remembers() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let memory = AdvancedPasteMemory()
        var sheet = try open(rig, "first\tpaste", memory: memory)
        sheet.toggle(.tabsToSpaces)
        sheet.setRegex(pattern: "p", replacement: "P")
        sheet.answer(.cancelled)
        try await rig.settle()

        sheet = try open(rig, "second\tpaste", memory: memory)
        #expect(sheet.advanced.steps == [.tabsToSpaces])
        #expect(sheet.patternField.stringValue == "p")
        #expect(sheet.replacementField.stringValue == "P")
        #expect(sheet.content == "second\tpaste")
        #expect(sheet.composed.text == "second    Paste")
        sheet.answer(.cancelled)

        // Another launch is another memory: nothing was written anywhere.
        #expect(AdvancedPasteMemory().last == Advanced())
        let mirror = Mirror(reflecting: memory).children.map { "\($0.value)" }.joined()
        #expect(!mirror.contains("first") && !mirror.contains("second"))
    }

    @Test("the tab width is the config's at each opening, not the remembered one")
    func tabWidth() throws {
        let rig = try Rig()
        defer { rig.close() }
        let memory = AdvancedPasteMemory()
        try open(rig, "a", memory: memory).answer(.cancelled)
        rig.config.pasteTabWidth = 8
        #expect(try open(rig, "a", memory: memory).advanced.tabWidth == 8)
    }

    @Test("history keeps what was sent; a marked pasteboard keeps nothing, whatever was edited")
    func history() async throws {
        let rig = try Rig()
        defer { rig.close() }
        var sheet = try open(rig, "echo “hi”\n")
        sheet.toggle(.straighten)
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.kept == ["echo \"hi\""])

        rig.copy("hunter2", marker: "org.nspasteboard.ConcealedType")
        let target = try #require(rig.pane.view as? TerminalPasteTarget)
        target.pasteSpecialIntoTerminalPane(Command.advancedPaste.rawValue as NSString)
        sheet = try #require(rig.pane.advancedSheet)
        sheet.editor.string = "echo hunter2"
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.wire.text.hasSuffix("echo hunter2"))
        #expect(rig.kept == ["echo \"hi\""])
    }

    @Test("base64 of something shaped like a secret is not kept: the net could not see it")
    func encodedSecret() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let secret = "export KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx"
        var sheet = try open(rig, secret)
        sheet.toggle(.base64Encode)
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.wire.text == TerminalPaste.base64Encoded(secret))
        #expect(rig.kept.isEmpty)

        sheet = try open(rig, "plain words")
        sheet.toggle(.base64Encode)
        sheet.send(slowly: false)
        try await rig.settle()
        #expect(rig.kept == [TerminalPaste.base64Encoded("plain words")])
    }

    @Test("the pane going away takes the sheet with it, unsent")
    func tearDown() throws {
        let rig = try Rig()
        let sheet = try open(rig, "ls")
        rig.close()
        #expect(sheet.superview == nil)
        #expect(rig.wire.sent.isEmpty)
    }
}

/// The sheet as a picture, in both appearances. Gated on `MAXPANE_SHOTS`.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("advanced paste sheet rendering")
@MainActor
struct AdvancedPasteRenderTests {
    @Test("renders the sheet over a lane-sized pane, some toggles on, and with a bad pattern")
    func render() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let text = """
            $ curl -fsSL “https://example.com/install.sh” \\
            \t| sh -s -- —prefix "$HOME/.local"   
            $ printf '\u{1b}[31mred\u{1b}[0m\\n'
            $ export PATH="$HOME/.local/bin:$PATH"

            """
        for (name, pattern, size) in [
            ("advanced-paste-sheet", "example\\.(com)", NSSize(width: 656, height: 620)),
            ("advanced-paste-sheet-invalid", "example\\.(com", NSSize(width: 656, height: 620)),
            // A lane split down, and a lane at `s`: the other arrangement.
            ("advanced-paste-sheet-short", "example\\.(com)", NSSize(width: 656, height: 330)),
            ("advanced-paste-sheet-narrow", "example\\.(com)", NSSize(width: 400, height: 620)),
        ] {
            try AppearanceSheet.render(to: dir, named: name) {
                let host = NSView(frame: NSRect(origin: .zero, size: size))
                host.wantsLayer = true
                host.layerBackgroundColor = Theme.laneBackground
                let memory = AdvancedPasteMemory()
                memory.last = Advanced(
                    steps: [.straighten, .stripPrompt, .trimStray, .tabsToSpaces], pattern: pattern,
                    replacement: "internal.$1")
                let sheet = AdvancedPasteSheet(
                    text: text, tabWidth: 4, terminalFont: NSFont(name: Config().fontName, size: 11),
                    memory: memory) { _ in }
                sheet.frame = host.bounds
                sheet.autoresizingMask = [.width, .height]
                host.addSubview(sheet)
                return host
            }
        }
    }
}
