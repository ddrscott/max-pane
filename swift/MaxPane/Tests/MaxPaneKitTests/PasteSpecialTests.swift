import AppKit
import Foundation
import Testing
@testable import MaxPaneKit
@testable import RelayClient

@Suite("Paste Special: each transform is a pure function")
struct PasteSpecialTransformTests {
    @Test("Paste Escaped: bare, double quotes, single quotes on a !, as a path is")
    func escapedLikeAPath() {
        #expect(TerminalPaste.escaped("plain-word_1.txt") == "plain-word_1.txt")
        #expect(TerminalPaste.escaped("two words") == "\"two words\"")
        #expect(TerminalPaste.escaped("cost $5 \"x\" `id` \\") == "\"cost \\$5 \\\"x\\\" \\`id\\` \\\\\"")
        #expect(TerminalPaste.escaped("hey! it's") == "'hey! it'\\''s'")
        #expect(TerminalPaste.escaped("rm -rf /; echo *") == "\"rm -rf /; echo *\"")
        #expect(TerminalPaste.escaped("") == nil)
        #expect(TerminalPaste.escaped("\n\n") == nil)
    }

    @Test("a newline stays a newline inside the quotes, and the ones at the end are dropped")
    func escapedNewlines() {
        #expect(TerminalPaste.escaped("one\ntwo\n") == "\"one\ntwo\"")
        #expect(TerminalPaste.escaped("one\r\ntwo\rthree") == "\"one\ntwo\nthree\"")
        #expect(TerminalPaste.escaped("a\nb") == "\"a\nb\"", "even bare words: two lines are not one bare word")
        #expect(TerminalPaste.escaped("run!\nnow") == "'run!\nnow'")
        // On the wire the newline is Return inside an open quote, and the
        // paste does not end in one.
        let bytes = TerminalPaste.bytes(for: TerminalPaste.escaped("echo $HOME\nls\n")!)
        #expect(String(decoding: bytes, as: UTF8.self) == "\"echo \\$HOME\rls\"")
    }

    @Test("any other control character makes it $'…', one line of printable text")
    func escapedControls() {
        #expect(TerminalPaste.escaped("a\tb") == "$'a\\tb'")
        #expect(TerminalPaste.escaped("a\tb\nc") == "$'a\\tb\\nc'")
        #expect(TerminalPaste.escaped("\u{1b}[31mred") == "$'\\033[31mred'")
        #expect(TerminalPaste.escaped("\u{03}") == "$'\\003'")
        #expect(TerminalPaste.escaped("\u{7f}1") == "$'\\1771'")
        #expect(TerminalPaste.escaped("\u{85}") == "$'\\302\\205'")
        #expect(TerminalPaste.escaped("it's\t\\ $x !") == "$'it\\'s\\t\\\\ $x \\041'")
        for text in ["a\tb", "x\u{1b}y\nz", "\u{03}\u{04}"] {
            let out = TerminalPaste.escaped(text)!
            #expect(!out.unicodeScalars.contains { $0.properties.generalCategory == .control })
        }
    }

    @Test("Paste as Base64: standard, padded, never wrapped")
    func encode() {
        #expect(TerminalPaste.base64Encoded("hi") == "aGk=")
        #expect(TerminalPaste.base64Encoded("héllo\n") == "aMOpbGxvCg==")
        let long = TerminalPaste.base64Encoded(String(repeating: "x", count: 600))
        #expect(long.count == 800)
        #expect(!long.contains("\n"))
    }

    @Test("Paste Base64-Decoded: wrapped or unpadded is fine")
    func decode() {
        #expect(TerminalPaste.base64Decoded("aGk=") == .success("hi"))
        #expect(TerminalPaste.base64Decoded("aGk") == .success("hi"))
        #expect(TerminalPaste.base64Decoded("  aMOp\nbGxv\r\nCg==\n") == .success("héllo\n"))
        let text = "line one\nline two ✓"
        #expect(TerminalPaste.base64Decoded(TerminalPaste.base64Encoded(text)) == .success(text))
    }

    @Test("what is not base64, or not text, is refused in one line")
    func decodeRefuses() {
        let notBase64 = TerminalPaste.Refusal(notice: "not pasted: the clipboard is not base64")
        for bad in ["", "   ", "not base64!", "aGk=aGk=", "a", "aGk===", "aGk-_"] {
            #expect(TerminalPaste.base64Decoded(bad) == .failure(notBase64), "\(bad)")
        }
        // Valid base64 of bytes that are not UTF-8.
        let binary = Data([0xff, 0xfe, 0x00, 0x80]).base64EncodedString()
        #expect(TerminalPaste.base64Decoded(binary)
            == .failure(.init(notice: "not pasted: that base64 is 4 bytes that are not UTF-8 text")))
    }

    @Test("the heredoc: decode to the name, wrapped at 76, and no Return after EOF")
    func heredoc() throws {
        let data = Data((0..<200).map { UInt8($0) })
        let out = try #require(TerminalPaste.base64Heredoc(name: "notes.txt", data: data))
        let lines = out.components(separatedBy: "\n")
        #expect(lines.first == "base64 -d > notes.txt <<'EOF'")
        #expect(lines.last == "EOF")
        #expect(!out.hasSuffix("\n"))
        let body = lines.dropFirst().dropLast()
        #expect(body.dropLast().allSatisfy { $0.count == 76 })
        #expect((body.last?.count ?? 0) <= 76)
        #expect(Data(base64Encoded: body.joined()) == data)
        // As it goes out: Return after every line but the last.
        let bytes = TerminalPaste.bytes(for: out)
        #expect(bytes.last == UInt8(ascii: "F"))
        #expect(bytes.filter { $0 == 0x0d }.count == lines.count - 1)
    }

    @Test("a name with spaces is one quoted word; a control character refuses")
    func heredocNames() {
        #expect(TerminalPaste.base64Heredoc(name: "my notes (1).txt", data: Data("x".utf8))
            == "base64 -d > \"my notes (1).txt\" <<'EOF'\neA==\nEOF")
        #expect(TerminalPaste.base64Heredoc(name: "cost $5!.txt", data: Data())
            == "base64 -d > 'cost $5!.txt' <<'EOF'\nEOF")
        #expect(TerminalPaste.base64Heredoc(name: "a\nb", data: Data()) == nil)
        #expect(TerminalPaste.base64Heredoc(name: "", data: Data()) == nil)
    }

    @Test("a file with a line EOF in it cannot end the heredoc early")
    func heredocContentWithEOF() throws {
        let data = Data("first\nEOF\nrm -rf ~\n".utf8)
        let out = try #require(TerminalPaste.base64Heredoc(name: "f", data: data))
        let lines = out.components(separatedBy: "\n")
        let delimiter = try #require(lines.last)
        #expect(lines.first == "base64 -d > f <<'\(delimiter)'")
        #expect(!lines.dropFirst().dropLast().contains(delimiter))
        #expect(Data(base64Encoded: lines.dropFirst().dropLast().joined()) == data)
    }

    @Test("the delimiter is the first of EOF, EOF_1, EOF_2… that is not a line of the body")
    func delimiter() {
        #expect(TerminalPaste.heredocDelimiter(notIn: []) == "EOF")
        #expect(TerminalPaste.heredocDelimiter(notIn: ["xEOF", "EOF ", "eof"]) == "EOF")
        #expect(TerminalPaste.heredocDelimiter(notIn: ["a", "EOF", "b"]) == "EOF_1")
        #expect(TerminalPaste.heredocDelimiter(notIn: ["EOF_1", "EOF", "EOF_2"]) == "EOF_3")
    }

    @Test("more than 5 MB of files is refused")
    func fileLimit() {
        #expect(TerminalPaste.fileRefusal(bytes: 5 * 1_048_576) == nil)
        #expect(TerminalPaste.fileRefusal(bytes: 5 * 1_048_576 + 1)?.notice
            == "not pasted: 5.0 MB is more than the 5 MB a file paste takes")
    }

    @Test("Paste Slowly's settings: 16 bytes and 10 ms, live, clamped to what a piece may be")
    func slowSettings() throws {
        #expect(TerminalPaste.slowPace(Config()) == PacedInput.Pace(chunk: 16, gap: 0.010))
        var config = Config()
        config.pasteSlowChunk = 5000
        config.pasteSlowDelayMs = 250
        #expect(TerminalPaste.slowPace(config).chunk == InputChunks.limit)
        #expect(TerminalPaste.slowPace(config).gap == 0.25)
        config.pasteSlowChunk = 0
        #expect(TerminalPaste.slowPace(config).chunk == 1)
        for key in ["paste_slow_chunk", "paste_slow_delay_ms"] {
            let field = try #require(ConfigField.all.first { $0.key == key }, "\(key)")
            #expect(field.appliesLive)
            #expect(field.group == .terminals)
        }
    }

    @Test("the commands: a Paste Special submenu of Edit; ⌃⌘V, ⌥⌘V and the sheet's ⌥⇧⌘V, and nothing else bound")
    func commands() {
        let special = Command.allCases.filter { $0.submenu == "Paste Special" }
        #expect(special == [.pasteWithoutAsking, .pasteEscaped, .pasteAsBase64, .pasteBase64Decoded,
                            .pasteFileAsBase64, .pasteSlowly, .advancedPaste])
        #expect(special.allSatisfy { $0.menu == .edit })
        #expect(Command.allCases.filter { $0.submenu != nil } == special)
        #expect(special.map(\.title) == ["Paste Without Asking", "Paste Escaped", "Paste as Base64",
                                        "Paste Base64-Decoded", "Paste File as Base64…", "Paste Slowly",
                                        "Advanced Paste…"])
        #expect(Keymap.defaults.chords(for: .pasteEscaped) == [KeyChord(key: "v", modifiers: [.command, .control])])
        for command in [Command.pasteAsBase64, .pasteBase64Decoded, .pasteFileAsBase64, .pasteSlowly] {
            #expect(Keymap.defaults.chords(for: command).isEmpty)
        }
        // Every transform that is not a plain paste names its command.
        for item in TerminalPaste.Special.allCases {
            #expect(Command(rawValue: item.rawValue)?.submenu == "Paste Special")
        }
        // ⌃⌘V is nobody else's.
        let chord = KeyChord(key: "v", modifiers: [.command, .control])
        #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [.pasteEscaped])
    }
}

@Suite("Paste Slowly is a stretch of the one queue")
@MainActor
struct PasteSlowlyPacingTests {
    typealias Clock = PasteChunkTests.Clock

    private final class Log {
        var sent: [[UInt8]] = []
        var events: [PacedInput.SlowEvent] = []
    }

    @Test("16 bytes at a time, 10 ms apart, never splitting a character")
    func slow() {
        let clock = Clock()
        let log = Log()
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        let bytes = Array(String(repeating: "界", count: 20).utf8)   // 60 bytes

        paced.enqueue(bytes[...], pace: .init(), report: { log.events.append($0) })
        #expect(log.sent.count == 1)
        #expect(paced.isSlow)
        clock.runOut()
        #expect(log.sent.map(\.count) == [15, 15, 15, 15])
        #expect(log.sent.flatMap { $0 } == bytes)
        #expect(clock.delays.allSatisfy { $0 == 0.010 })
        #expect(log.events == [.sent(15, of: 60), .sent(30, of: 60), .sent(45, of: 60), .finished(60)])
        #expect(!paced.isSlow)
        #expect(paced.backlog == 0)
    }

    @Test("cancelled, it sends nothing after; what was typed to cancel it follows")
    func cancel() {
        let clock = Clock()
        let log = Log()
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        let bytes = [UInt8](repeating: 0x61, count: 160)

        paced.enqueue(bytes[...], pace: .init(), report: { log.events.append($0) })
        clock.tick()
        clock.tick()
        #expect(log.sent.count == 3)

        paced.cancelSlow()
        #expect(log.events.last == .cancelled(sent: 48, of: 160))
        #expect(!paced.isSlow)
        #expect(paced.backlog == 0)
        clock.runOut()
        #expect(log.sent.count == 3, "not one byte of the paste after the cancel")

        paced.enqueue(Array("ls\r".utf8)[...])
        clock.runOut()
        #expect(log.sent.count == 4)
        #expect(log.sent.last == Array("ls\r".utf8))
        #expect(log.sent.flatMap { $0 }.count == 48 + 3)
        paced.cancelSlow()   // nothing to cancel, nothing said
        #expect(log.events.filter { if case .cancelled = $0 { return true } else { return false } }.count == 1)
    }

    @Test("a key queued behind the paste survives the cancel, and leaves at the usual pace")
    func typedBehind() {
        let clock = Clock()
        let log = Log()
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        paced.enqueue([UInt8](repeating: 0x61, count: 100)[...], pace: .init(), report: { log.events.append($0) })
        paced.enqueue(Array("q".utf8)[...])
        paced.cancelSlow()
        clock.runOut()
        #expect(log.sent.map(\.count) == [16, 1])
        #expect(log.sent.last == Array("q".utf8))
    }

    @Test("what was queued before it leaves whole and fast; what comes after waits for it")
    func ordered() {
        let clock = Clock()
        let log = Log()
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        paced.enqueue([UInt8](repeating: 0x41, count: 1500)[...])
        paced.enqueue([UInt8](repeating: 0x42, count: 40)[...], pace: .init(), report: { log.events.append($0) })
        paced.enqueue([UInt8](repeating: 0x43, count: 1200)[...])
        clock.runOut()
        #expect(log.sent.map(\.count) == [1000, 500, 16, 16, 8, 1000, 200])
        #expect(log.sent[1].allSatisfy { $0 == 0x41 }, "a fast piece stops where the slow stretch starts")
        #expect(log.sent[4].allSatisfy { $0 == 0x42 })
        #expect(clock.delays == [0.005, 0.005, 0.010, 0.010, 0.010, 0.005, 0.005])
        #expect(log.events.last == .finished(40))
    }

    @Test("a wire that goes cancels it: the rest is not held to be flushed at full speed")
    func wireGone() {
        let clock = Clock()
        let log = Log()
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        paced.enqueue([UInt8](repeating: 0x61, count: 100)[...], pace: .init(), report: { log.events.append($0) })
        paced.enqueue(Array("typed".utf8)[...])
        #expect(paced.takeBacklog() == Array("typed".utf8))
        #expect(log.events.last == .cancelled(sent: 16, of: 100))
        clock.runOut()
        #expect(log.sent.count == 1)
    }

    @Test("one at a time: a second while the first is going is ordinary input behind it")
    func second() {
        let clock = Clock()
        let log = Log()
        var other: [PacedInput.SlowEvent] = []
        let paced = PacedInput(after: clock.after) { log.sent.append($0) }
        paced.enqueue([UInt8](repeating: 0x61, count: 32)[...], pace: .init(), report: { log.events.append($0) })
        paced.enqueue([UInt8](repeating: 0x62, count: 32)[...], pace: .init(), report: { other.append($0) })
        #expect(other == [.finished(32)])
        clock.runOut()
        #expect(log.sent.map(\.count) == [16, 16, 32])
    }

    @Test("the pane's line")
    func notices() {
        #expect(TerminalPaste.slowNotice(.sent(1229, of: 18_637)) == "pasting slowly · 1.2 KB of 18.2 KB · Esc cancels")
        #expect(TerminalPaste.slowNotice(.finished(312)) == "pasted slowly · 312 bytes")
        #expect(TerminalPaste.slowNotice(.cancelled(sent: 48, of: 160)) == "slow paste cancelled · 48 bytes of 160 bytes sent")
    }
}

/// The door: what each item sends, reading a pasteboard of the test's own and
/// a file chooser of the test's own. Never `NSPasteboard.general`, never a
/// real open panel.
@Suite("Edit › Paste Special, through a pane", .serialized)
@MainActor
struct PasteSpecialDoorTests {
    /// A wire with the real pacer behind it, its gaps held by the test.
    @MainActor
    private final class Wire: RelayAttachment {
        let sessionId = "paste-special-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        var pieces: [Int] = []
        var pace: PacedInput.Pace?
        let clock = PasteChunkTests.Clock()
        private(set) var paced: PacedInput!
        init() {
            paced = PacedInput(after: clock.after) { [unowned self] piece in
                self.sent.append(contentsOf: piece)
                self.pieces.append(piece.count)
            }
        }
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { paced.enqueue(bytes) }
        func send(_ bytes: ArraySlice<UInt8>, pace: PacedInput.Pace, report: @escaping (PacedInput.SlowEvent) -> Void) {
            self.pace = pace
            paced.enqueue(bytes, pace: pace, report: report)
        }
        func cancelSlowSend() { paced.cancelSlow() }
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
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.paste-special.\(UUID().uuidString)"))
        var asked = 0

        init(config: Config = Config()) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-paste-special-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "paste-special", near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.pasteboard = pasteboard
            // No test ever sees an open panel.
            pane.chooseFiles = { [unowned self] _, chosen in
                self.asked += 1
                chosen([])
            }
            pane.attach(wire)
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 600)
            window.contentView?.addSubview(pane.view)
            pasteboard.clearContents()
        }

        func copy(_ text: String) {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        func copy(files: [URL]) {
            pasteboard.clearContents()
            pasteboard.writeObjects(files.map { $0 as NSURL })
        }

        func file(_ name: String, _ data: Data) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        /// Let the emulator's write path drain, then every gap end.
        func settle() async throws {
            try await Task.sleep(nanoseconds: 120_000_000)
            wire.clock.runOut()
        }

        func close() {
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @Test("Paste Escaped of several lines is one quoted word, untidied, and never asks")
    func escaped() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("$ echo “hi” \nrm -rf $HOME\n")
        let target = try #require(rig.pane.view as? TerminalPasteTarget)
        target.pasteSpecialIntoTerminalPane(Command.pasteEscaped.rawValue as NSString)
        try await rig.settle()
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.wire.text == "\"\\$ echo “hi” \rrm -rf \\$HOME\"")
    }

    @Test("Paste as Base64, and back; a decode of several lines asks like any paste")
    func base64() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("héllo")
        rig.pane.pasteSpecial(.base64)
        try await rig.settle()
        #expect(rig.wire.text == "aMOpbGxv")

        rig.wire.sent = []
        rig.copy("aMOpbGxv\n")
        rig.pane.pasteSpecial(.base64Decoded)
        try await rig.settle()
        #expect(rig.wire.text == "héllo")

        rig.wire.sent = []
        rig.copy(TerminalPaste.base64Encoded("one\ntwo"))
        rig.pane.pasteSpecial(.base64Decoded)
        try await rig.settle()
        #expect(rig.pane.pasteSheet != nil)
        #expect(rig.wire.sent.isEmpty)
        rig.pane.pasteSheet?.answer(.cancelled)
    }

    @Test("a refusal is one line, and the prompt gets nothing")
    func refusals() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("definitely not base64!")
        rig.pane.pasteSpecial(.base64Decoded)
        try await rig.settle()
        #expect(rig.pane.noticeText == "not pasted: the clipboard is not base64")

        rig.pasteboard.clearContents()
        rig.pane.pasteSpecial(.escaped)
        try await rig.settle()
        #expect(rig.pane.noticeText == "not pasted: no text on the clipboard")
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("Paste File as Base64…: the files copied in Finder, no panel, no sheet, no final Return")
    func copiedFile() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let data = Data((0..<100).map { UInt8($0) })
        let url = try rig.file("my data.bin", data)
        rig.copy(files: [url])
        rig.pane.pasteSpecial(.fileAsBase64)
        try await rig.settle()
        #expect(rig.asked == 0)
        #expect(rig.pane.pasteSheet == nil)
        let lines = rig.wire.text.components(separatedBy: "\r")
        #expect(lines.first == "base64 -d > \"my data.bin\" <<'EOF'")
        #expect(lines.last == "EOF")
        #expect(Data(base64Encoded: lines.dropFirst().dropLast().joined()) == data)
        #expect(rig.pane.noticeText == "my data.bin as base64, 100 bytes · Return writes it")
        #expect(rig.wire.pieces.allSatisfy { $0 <= InputChunks.limit })
    }

    @Test("with no files copied it asks which, through the injected chooser; none chosen, nothing sent")
    func chosenFile() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("some text that is not a file")
        rig.pane.pasteSpecial(.fileAsBase64)
        try await rig.settle()
        #expect(rig.asked == 1)
        #expect(rig.wire.sent.isEmpty)

        let one = try rig.file("a.txt", Data("A".utf8))
        let two = try rig.file("b.txt", Data("EOF\n".utf8))
        rig.pane.chooseFiles = { _, chosen in chosen([one, two]) }
        rig.pane.pasteSpecial(.fileAsBase64)
        try await rig.settle()
        #expect(rig.wire.text == "base64 -d > a.txt <<'EOF'\rQQ==\rEOF\rbase64 -d > b.txt <<'EOF'\rRU9GCg==\rEOF")
    }

    @Test("over 5 MB, or a folder, is refused in one line")
    func tooBig() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let big = try rig.file("big.bin", Data(count: TerminalPaste.fileLimit + 1))
        rig.copy(files: [big])
        rig.pane.pasteSpecial(.fileAsBase64)
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.noticeText == "not pasted: 5.0 MB is more than the 5 MB a file paste takes")

        rig.copy(files: [rig.dir])
        rig.pane.pasteSpecial(.fileAsBase64)
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.noticeText?.hasSuffix("is a folder") == true)
    }

    @Test("Paste Slowly: ⌘V's bytes, tidied, in small pieces, with a line that says how far")
    func slowly() async throws {
        var config = Config()
        config.pasteSlowChunk = 8
        config.pasteSlowDelayMs = 20
        let rig = try Rig(config: config)
        defer { rig.close() }
        rig.copy("$ echo “" + String(repeating: "x", count: 30) + "”\n")
        rig.pane.pasteSpecial(.slowly)
        #expect(rig.wire.pace == PacedInput.Pace(chunk: 8, gap: 0.020))
        #expect(rig.pane.isPastingSlowly)
        #expect(rig.wire.pieces == [8])
        #expect(rig.pane.noticeText == "pasting slowly · 8 bytes of 37 bytes · Esc cancels")
        rig.wire.clock.runOut()
        #expect(rig.wire.text == "echo \"" + String(repeating: "x", count: 30) + "\"")
        #expect(rig.wire.pieces == [8, 8, 8, 8, 5])
        #expect(!rig.pane.isPastingSlowly)
        #expect(rig.pane.noticeText == "pasted slowly · 37 bytes")
    }

    @Test("a slow paste of several lines asks first, and is slow once answered")
    func slowlyAsks() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy("one\ntwo")
        rig.pane.pasteSpecial(.slowly)
        #expect(rig.wire.sent.isEmpty)
        let sheet = try #require(rig.pane.pasteSheet)
        sheet.answer(.paste(oneLine: false, tabsToSpaces: false))
        #expect(rig.wire.pace != nil)
        rig.wire.clock.runOut()
        #expect(rig.wire.text == "one\rtwo")
    }

    @Test("Esc cancels it and is swallowed; nothing is sent after")
    func escCancels() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy(String(repeating: "y", count: 400))
        rig.pane.pasteSpecial(.slowly)
        rig.wire.clock.tick()
        #expect(rig.wire.sent.count == 32)

        #expect(rig.pane.keyDuringSlowPaste(try key(53, "\u{1b}")), "Esc is the pane's, not the program's")
        #expect(!rig.pane.isPastingSlowly)
        #expect(rig.pane.noticeText == "slow paste cancelled · 32 bytes of 400 bytes sent")
        try await rig.settle()
        #expect(rig.wire.sent.count == 32)
        // With no slow paste going, Esc is the program's again.
        #expect(!rig.pane.keyDuringSlowPaste(try key(53, "\u{1b}")))
    }

    @Test("typing cancels it too, and the key goes on to the program")
    func typingCancels() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy(String(repeating: "y", count: 400))
        rig.pane.pasteSpecial(.slowly)
        #expect(!rig.pane.keyDuringSlowPaste(try key(0, "a")), "not swallowed")
        #expect(!rig.pane.isPastingSlowly)
        rig.wire.send(Array("a".utf8)[...])
        try await rig.settle()
        #expect(rig.wire.text == String(repeating: "y", count: 16) + "a")
    }

    @Test("a second slow paste while one is going does nothing")
    func oneAtATime() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.copy(String(repeating: "y", count: 64))
        rig.pane.pasteSpecial(.slowly)
        rig.pane.pasteSpecial(.slowly)
        rig.wire.clock.runOut()
        #expect(rig.wire.sent.count == 64)
    }
}
