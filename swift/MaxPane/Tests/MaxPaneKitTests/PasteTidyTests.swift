import Testing
import AppKit
import Foundation
import RelayClient
@testable import MaxPaneKit

/// Pasted text is tidied when it obviously should be (ADR-0029): smart
/// punctuation, a copied prompt, stray whitespace. Each rule on its own, the
/// prose guard from both sides, and the door the tidied text goes through.

@Suite("tidying: smart punctuation is straightened")
struct PasteStraightenTests {
    @Test("curly double and single quotes, all four of each")
    func quotes() {
        #expect(TerminalPaste.straightenPunctuation("echo “a” „b‟") == "echo \"a\" \"b\"")
        #expect(TerminalPaste.straightenPunctuation("echo ‘a’ ‚b‛") == "echo 'a' 'b'")
        #expect(TerminalPaste.tidy("cd “My Files”").quotes == 2)
    }

    @Test("the dash rule: a long dash that starts a word before a letter or digit is --, any other is -")
    func dashes() {
        // Two that become `--`.
        #expect(TerminalPaste.straightenPunctuation("—force") == "--force")
        #expect(TerminalPaste.straightenPunctuation("git commit –amend —no-edit") == "git commit --amend --no-edit")
        #expect(TerminalPaste.straightenPunctuation("head ―2") == "head --2")
        // Two that become `-`.
        #expect(TerminalPaste.straightenPunctuation("this — that") == "this - that")
        #expect(TerminalPaste.straightenPunctuation("pages 10–20, foo—bar") == "pages 10-20, foo-bar")
        // One hyphen survived the autocorrect: the pair is already `--`.
        #expect(TerminalPaste.straightenPunctuation("ls –-all ——color") == "ls --all --color")
        // Not an option: nothing, or something that is not ASCII, follows.
        #expect(TerminalPaste.straightenPunctuation("cat —") == "cat -")
        #expect(TerminalPaste.straightenPunctuation("—été") == "-été")
        // The hyphen look-alikes are always one.
        #expect(TerminalPaste.straightenPunctuation("a‐b ‑c ‒d −e") == "a-b -c -d -e")
        #expect(TerminalPaste.tidy("rm —force –-all").dashes == 2)
    }

    @Test("an ellipsis is three dots")
    func ellipsis() {
        #expect(TerminalPaste.straightenPunctuation("git log main…topic") == "git log main...topic")
        #expect(TerminalPaste.tidy("a…b…").ellipses == 2)
    }

    @Test("non-breaking and other Unicode spaces become a space")
    func spaces() {
        let odd = ["\u{a0}", "\u{1680}", "\u{2000}", "\u{2003}", "\u{2009}", "\u{200a}", "\u{202f}", "\u{205f}", "\u{3000}"]
        for space in odd {
            #expect(TerminalPaste.straightenPunctuation("ls\(space)-la") == "ls -la", "U+\(String(space.unicodeScalars.first!.value, radix: 16))")
        }
        #expect(TerminalPaste.tidy("ls\u{a0}-la\u{a0}x").spaces == 2)
        // A tab and a newline are not "odd spaces".
        #expect(TerminalPaste.straightenPunctuation("a\tb\nc") == "a\tb\nc")
    }

    @Test("zero-width characters go; a joiner stays where it is holding something together")
    func invisibles() {
        #expect(TerminalPaste.straightenPunctuation("\u{feff}ls\u{200b} -la\u{2060}\u{ad}") == "ls -la")
        #expect(TerminalPaste.straightenPunctuation("ls\u{200d} \u{200e}-la\u{200f}") == "ls -la")
        let family = "echo 👨\u{200d}👩\u{200d}👧"
        #expect(TerminalPaste.straightenPunctuation(family) == family)
        let persian = "echo می\u{200c}خواهم"
        #expect(TerminalPaste.straightenPunctuation(persian) == persian)
        #expect(TerminalPaste.tidy("l\u{200b}s\u{feff}").invisibles == 2)
    }

    @Test("plain text is not touched and nothing is reported")
    func plain() {
        let text = "grep -rn \"it's\" -- ./src | sort -u"
        let tidy = TerminalPaste.tidy(text)
        #expect(tidy.text == text)
        #expect(!tidy.changed)
        #expect(tidy.notice == nil)
    }
}

@Suite("tidying: what looks like a command, and what is clearly prose")
struct PasteProseGuardTests {
    @Test("lines that look like a command")
    func commands() {
        for line in [
            "git commit —amend", "ls", "./configure --prefix=/usr", "/usr/bin/env python3 x.py",
            "~/bin/deploy", "FOO=bar make", "_x=1 run", "$HOME/bin/tool", "$(brew --prefix)/bin/x",
            "  indented --flag", "| grep foo", "&& make install", "} || true", "fi", "[ -f x ] && echo “yes”",
            "git add .", "cd ..", "echo hello world", "for f in *; do", "if true; then",
            "$ brew install jq", "% ls -la", "# apt install nginx", "# a comment in a script", "#!/bin/sh",
            "sudo rm -rf build/",
        ] {
            #expect(TerminalPaste.looksLikeCommand(line), "\(line)")
        }
    }

    @Test("lines that do not")
    func prose() {
        for line in [
            "The quick brown fox", "Run this:", "this is what I meant", "please restart it",
            "it’s broken", "It's broken", "then it failed.", "restart the server, then wait.",
            "does it work?", "note: see below", "e.g. like so", "well, maybe", "“Quoted” words",
            "— and another thing", "- a list item", "1. a step", "> quoted", "$ ", "$", "$ 5 each.",
            "Rscript x.R", "café ouvert", "", "   ",
        ] {
            #expect(!TerminalPaste.looksLikeCommand(line), "\(line)")
        }
    }

    @Test("one line is never clearly prose; several are when any one is not a command")
    func guardRule() {
        #expect(!TerminalPaste.isClearlyProse("The “quick” fox — jumped."))
        #expect(!TerminalPaste.isClearlyProse("The “quick” fox.\n\n"))
        #expect(!TerminalPaste.isClearlyProse("cd “My Files”\nls —all"))
        #expect(TerminalPaste.isClearlyProse("cd “My Files”\nThen look around."))
        #expect(TerminalPaste.isClearlyProse("First line of “prose”.\nAnd a second — longer."))
        #expect(!TerminalPaste.isClearlyProse(""))
    }

    @Test("a continuation line is part of the command before it, and is not judged")
    func continuation() {
        let text = "docker run \\\n  —rm \\\n  “alpine”\nls"
        #expect(!TerminalPaste.isClearlyProse(text))
        #expect(TerminalPaste.tidy(text).text == "docker run \\\n  --rm \\\n  \"alpine\"\nls")
        // `\\` is an escaped backslash: the next line is its own, and is prose.
        #expect(TerminalPaste.isClearlyProse("echo \\\\\n—rm it is"))
    }

    @Test("prose of several lines keeps its punctuation; commands of several lines lose theirs")
    func applied() {
        let prose = "He said “no” — twice…\nThen he left."
        #expect(TerminalPaste.tidy(prose).text == prose)
        #expect(!TerminalPaste.tidy(prose).changed)
        let commands = "cd “My Files”\r\ngit commit —amend\r\n"
        let tidy = TerminalPaste.tidy(commands)
        #expect(tidy.text == "cd \"My Files\"\r\ngit commit --amend\r\n")
        #expect(TerminalPaste.bytes(for: tidy.text) == Array("cd \"My Files\"\rgit commit --amend".utf8))
        // A single line is what a copied command is, prose or not.
        #expect(TerminalPaste.tidy("He said “no” — twice…").text == "He said \"no\" - twice...")
    }
}

@Suite("tidying: a copied prompt is removed")
struct PastePromptTests {
    @Test("$, % and #, with the space, from one line or from every line")
    func strips() {
        #expect(TerminalPaste.stripPrompt("$ brew install jq") == "brew install jq")
        #expect(TerminalPaste.stripPrompt("% ls -la") == "ls -la")
        #expect(TerminalPaste.stripPrompt("# apt install nginx") == "apt install nginx")
        #expect(TerminalPaste.stripPrompt("$ cd repo\n$ make\n\n$ make install\n") == "cd repo\nmake\n\nmake install\n")
        #expect(TerminalPaste.tidy("$ cd repo\n$ make").prompt == "$ ")
    }

    @Test("only when every non-empty line has the same one")
    func allLines() {
        for text in [
            "$ ls\nfile1 file2",            // a transcript: the second line is output
            "$ cd repo\n% make",            // two different prompts
            "$ cd repo\n make",
            "  $ ls",                       // not at column 0
            "$ls", "$HOME/bin/x", "#!/bin/sh", "#comment",
        ] {
            #expect(TerminalPaste.stripPrompt(text) == text, "\(text.debugDescription)")
            #expect(TerminalPaste.tidy(text).prompt == nil)
        }
    }

    @Test("never >, and never from something that is not a command once it is off")
    func never() {
        for text in [
            "> quoted", "> cat <<EOF\n> x",
            "# A Heading", "# this is a comment", "# what it does, in words.", "$ 5 each", "% of total.",
            "$ $ ls", "# # nested",
        ] {
            #expect(TerminalPaste.stripPrompt(text) == text, "\(text.debugDescription)")
        }
    }

    @Test("a continuation line has no prompt to have, and is kept as it is")
    func continuation() {
        #expect(TerminalPaste.stripPrompt("$ docker run \\\n    --rm alpine\n$ ls") == "docker run \\\n    --rm alpine\nls")
    }
}

@Suite("tidying: stray whitespace is trimmed")
struct PasteTrimTests {
    @Test("leading blank lines and the end of each line")
    func trims() {
        #expect(TerminalPaste.trimStray("\n  \n\nls -la  \t\nmake \n") == "ls -la\nmake\n")
        #expect(TerminalPaste.trimStray("ls\u{a0}") == "ls")
        #expect(TerminalPaste.tidy("\n\nls  ").trimmed == 3)
        #expect(TerminalPaste.trimStray("   \n") == "")
    }

    @Test("indentation is kept: it is a heredoc, or Python")
    func indentation() {
        let python = "def f():\n    if x:\n\treturn 1"
        #expect(TerminalPaste.trimStray(python) == python)
        #expect(TerminalPaste.tidy(python + "  ").text == python)
        #expect(TerminalPaste.trimStray("    ls") == "    ls")
        #expect(TerminalPaste.trimStray("cat <<EOF  \n  body  \nEOF") == "cat <<EOF\n  body\nEOF")
    }

    @Test("an escaped space at the end of a line is a word, not a stray")
    func escapedSpace() {
        #expect(TerminalPaste.trimStray("cd My\\ ") == "cd My\\ ")
        #expect(TerminalPaste.trimStray("echo \\\\ ") == "echo \\\\")
    }

    @Test("nothing to trim changes nothing, line endings included")
    func untouched() {
        #expect(TerminalPaste.trimStray("a\r\nb\r\n") == "a\r\nb\r\n")
        #expect(TerminalPaste.tidy("a\r\nb\r\n").changed == false)
        #expect(TerminalPaste.trimStray("") == "")
    }
}

@Suite("tidying: all of it, twice, and what the pane says")
struct PasteTidyTests {
    static let samples = [
        "$ git commit —amend -m “it’s done”  \n",
        "\n\n$ cd “My Files”\n$ ls –la\u{a0}\n",
        "He said “no” — twice…\nThen he left.  ",
        "$ $ ls", "# # x", "% $ make", "  $ ls  ", "\u{feff}$\u{a0}ls", "—\u{200b}force", "\u{200b}—force",
        "docker run \\\n  —rm \\ \n  alpine  ", "   ", "", "a\r\n\r\nb  \r\n", "$ \n$ ls",
        "echo 👨\u{200d}👩\u{200d}👧 …", "… and so on —\nmore “prose” here.",
    ]

    @Test("idempotent: tidying twice changes nothing and reports nothing", arguments: samples)
    func idempotent(_ text: String) {
        let once = TerminalPaste.tidy(text)
        let twice = TerminalPaste.tidy(once.text)
        #expect(twice.text == once.text, "\(text.debugDescription)")
        #expect(!twice.changed, "\(text.debugDescription) → \(String(describing: twice.summary))")
    }

    @Test("the three in order: punctuation, then the prompt, then whitespace")
    func order() {
        // The space after the prompt is a non-breaking one until it is straightened.
        let tidy = TerminalPaste.tidy("\n$\u{a0}git commit —amend -m “done”  \n")
        #expect(tidy.text == "git commit --amend -m \"done\"\n")
        #expect(tidy == TerminalPaste.Tidied(
            text: "git commit --amend -m \"done\"\n", quotes: 2, dashes: 1, spaces: 1, prompt: "$ ", trimmed: 2))
    }

    @Test("the notice: what was done, in the order it was done, and nothing when nothing was")
    func notice() {
        #expect(TerminalPaste.tidy("$ echo “a” ‘b’").notice == "pasted · straightened 4 quotes · removed \"$ \"")
        #expect(TerminalPaste.tidy("ls “a b”").notice == "pasted · straightened 2 quotes")
        #expect(TerminalPaste.tidy("ls ’a —x…\u{a0}y").summary == "straightened 1 quote, 1 dash, 1 ellipsis, 1 odd space")
        #expect(TerminalPaste.tidy("l\u{200b}s ").summary == "removed 1 invisible character · trimmed whitespace")
        #expect(TerminalPaste.tidy("ls").notice == nil)
    }

    @Test("paste_tidy is in the config, on by default, under its snake_case key, and applies live")
    func config() throws {
        #expect(Config().pasteTidy)
        let field = try #require(ConfigField.all.first { $0.key == "paste_tidy" })
        #expect(field.appliesLive)
        #expect(field.group == .terminals)
    }
}

/// The door: what ⌘V sends, reading a pasteboard of the test's own.
@Suite("a paste is tidied before it is sent or asked about", .serialized)
@MainActor
struct PasteTidyDoorTests {
    private final class Wire: RelayAttachment {
        let sessionId = "paste-tidy-test"
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
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.paste-tidy.\(UUID().uuidString)"))

        init(config: Config = Config()) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-paste-tidy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "paste-tidy", near: nil)
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

        func copy(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        func settle() async throws { try await Task.sleep(nanoseconds: 120_000_000) }

        func close() {
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("⌘V sends the tidied text, and the pane says what it did")
    func tidies() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("$ git commit —amend -m “it’s done” \n")
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.wire.text == "git commit --amend -m \"it's done\"")
        #expect(rig.pane.noticeText == "pasted · straightened 3 quotes, 1 dash · removed \"$ \" · trimmed whitespace")
    }

    @Test("text with nothing to tidy says nothing")
    func quiet() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("ls -la\n")
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.wire.text == "ls -la")
        #expect(rig.pane.noticeText == nil)
    }

    @Test("⌥⌘V pastes it as it was copied, and so does paste_tidy = false, read at each paste")
    func asCopied() async throws {
        let copied = "$ ls —all “x”"
        let rig = try Rig()
        defer { rig.close() }
        rig.copy(copied)
        rig.pane.pasteFromClipboard(asking: false)
        try await rig.settle()
        #expect(rig.wire.text == copied)
        #expect(rig.pane.noticeText == nil)

        var off = Config()
        off.pasteTidy = false
        rig.pane.liveConfig = { off }
        rig.wire.sent = []
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.wire.text == copied)
        #expect(rig.pane.noticeText == nil)
    }

    @Test("tidy first, then decide whether to ask: trailing whitespace on one line asks nothing")
    func tidyThenAsk() async throws {
        let rig = try Rig()
        defer { rig.close() }
        // As copied this has a tab in it, which would ask. Tidied, it has not.
        rig.copy("$ make install \t\n")
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == "make install")
    }

    @Test("the sheet is asked about, shows, and sends the tidied text, and says it was tidied")
    func sheet() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("$ cd “My Files”\n$ git commit —amend\n")
        rig.pane.pasteFromClipboard()
        let sheet = try #require(rig.pane.pasteSheet)
        #expect(sheet.tidied == "straightened 2 quotes, 1 dash · removed \"$ \"")
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.noticeText == nil)
        sheet.send(oneLine: false)
        try await rig.settle()
        #expect(rig.wire.text == "cd \"My Files\"\rgit commit --amend")
        #expect(rig.pane.noticeText == "pasted · straightened 2 quotes, 1 dash · removed \"$ \"")
    }

    @Test("a cancelled sheet says nothing was pasted by saying nothing")
    func cancelled() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("$ a\n$ b")
        rig.pane.pasteFromClipboard()
        try #require(rig.pane.pasteSheet).answer(.cancelled)
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.noticeText == nil)
    }

    @Test("copied files are paths, not text, and are never tidied")
    func files() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let url = NSURL(fileURLWithPath: "/tmp/it’s — “final”…txt")
        rig.pasteboard.clearContents()
        rig.pasteboard.writeObjects([url])
        let clipboard = TerminalPaste.clipboard(rig.pasteboard)
        #expect(!clipboard.isCopiedText)
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.wire.text == "\"/tmp/it’s — “final”…txt\"")
        #expect(rig.pane.noticeText == nil)
        // And text handed to the door by anything but the pasteboard's string
        // (an image's path, a drop) is not copied text either.
        #expect(!TerminalPaste.Clipboard(text: "x").isCopiedText)
        rig.copy("x")
        #expect(TerminalPaste.clipboard(rig.pasteboard).isCopiedText)
    }
}
