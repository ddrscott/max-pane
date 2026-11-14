import Testing
import AppKit
import Foundation
import LanedCore
@testable import MaxPaneKit

/// Edit › Dictate… (F5, ADR-0049): what a send types, what history keeps,
/// the keys, and the popup driven without a microphone. The system's
/// dictation is never started here; a recorder stands in for it.

@Suite("dictation: what a send types")
struct DictationOutgoingTests {
    @Test("send is the text as it stands, lines and all")
    func send() {
        #expect(Dictation.outgoing("fix the tests\nthen ship it", oneLine: false) == "fix the tests\nthen ship it")
    }

    @Test("send one line joins the lines the way Paste as One Line does")
    func oneLine() {
        #expect(Dictation.outgoing("fix the tests\n\nthen ship it\n", oneLine: true) == "fix the tests then ship it")
    }

    @Test("nothing but whitespace sends nothing, either way")
    func blank() {
        #expect(Dictation.outgoing("  \n\t", oneLine: false) == nil)
        #expect(Dictation.outgoing("\n\n", oneLine: true) == nil)
    }

    @Test("a box is new unless it is blank or exactly the entry it came from")
    func isNew() {
        #expect(Dictation.isNew("hello", loadedFrom: ""))
        #expect(!Dictation.isNew("hello", loadedFrom: "hello"))
        #expect(Dictation.isNew("hello there", loadedFrom: "hello"))
        #expect(!Dictation.isNew("   ", loadedFrom: ""))
    }

    @Test("a row shows the first line with something on it, and its size and age")
    func row() {
        let entry = DictationEntry(id: 1, content: "\n  first words\nsecond", at: 1_000)
        #expect(Dictation.headline(entry) == "first words")
        let now = Date(timeIntervalSince1970: 1 + 300)
        #expect(Dictation.detail(entry, now: now).hasPrefix("2 lines · "))
    }
}

@Suite("dictation: F5 and the microphone key")
@MainActor
struct DictationKeyTests {
    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    @Test("F5 and 🎤 are Dictate's, and print as what they are")
    func defaults() {
        let chords = Keymap.defaults.chords(for: .dictate)
        #expect(chords.map(\.text) == ["F5", "🎤"])
        #expect(Command.dictate.menuChord == nil, "no ⌘, so the key monitor matches it, not the menu")
        #expect(Command.dictate.menu == .edit)
    }

    @Test("f-keys parse from a config file the way they are printed")
    func parses() {
        #expect(KeyChord("f5") == KeyChord(key: "\u{F708}", modifiers: []))
        #expect(KeyChord("F5") == KeyChord(key: "\u{F708}", modifiers: []))
        #expect(KeyChord("cmd+f12") == KeyChord(key: "\u{F70F}", modifiers: [.command]))
        #expect(KeyChord("mic") == KeyChord(key: "🎤", modifiers: []))
        #expect(KeyChord(key: "\u{F708}", modifiers: []).configText == "f5")
    }

    @Test("a real F5 press, which carries .function, is the chord")
    func typedF5() {
        let event = key(96, "\u{F708}", [.function, .numericPad])
        #expect(KeyChord.typed(event) == KeyChord(key: "\u{F708}", modifiers: []))
        #expect(KeyChord(event: event) == KeyChord(key: "\u{F708}", modifiers: []))
        #expect(Command.dictate.chords.contains(KeyChord.typed(event)))
    }

    @Test("the microphone key is matched by its code, having no character")
    func typedMic() {
        let event = key(176, "")
        #expect(KeyChord.typed(event) == KeyChord(key: "🎤", modifiers: []))
        #expect(KeyChord(event: event) == KeyChord(key: "🎤", modifiers: []))
    }

    @Test("caps lock does not stop a chord matching")
    func capsLock() {
        let event = key(31, "o", [.command, .capsLock])
        #expect(KeyChord.typed(event) == KeyChord(key: "o", modifiers: [.command]))
    }
}

@Suite("dictation: the popup", .serialized)
@MainActor
struct DictationPopupTests {
    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let paneId: String
        var config = Config()
        var calls: [String] = []
        var sent: [String?] = []

        init(private lane: Bool = false) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-dictation-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "dictation", near: nil)
            paneId = store.state.lanes[0].panes[0].id
        }

        func popup() -> DictationPopup {
            let recorder = DictationSwitch(
                start: { [unowned self] in self.calls.append("start") },
                stop: { [unowned self] in self.calls.append("stop") })
            return DictationPopup(
                store: store, config: { [unowned self] in self.config }, paneId: paneId,
                target: "tests", dictation: recorder
            ) { [unowned self] in self.sent.append($0) }
        }

        func kept() -> [String] { store.dictationHistory(config).map(\.content) }

        func say(_ text: String) {
            store.recordDictation(paneId: paneId, text: text, config: config)
        }

        func close() { try? FileManager.default.removeItem(at: dir) }
    }

    private func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
            keyCode: code)!
    }

    @Test("Esc stops listening first, and closes the second time, keeping what was said")
    func escapeTwice() throws {
        let rig = try Rig()
        defer { rig.close() }
        let popup = rig.popup()
        popup.startListening()
        popup.editor.string = "half a thought"
        #expect(popup.handle(key(53, "\u{1b}")))
        #expect(!popup.isListening)
        #expect(rig.sent.isEmpty, "the first Esc only stops")
        #expect(popup.handle(key(53, "\u{1b}")))
        #expect(rig.sent == [nil], "the second closes and sends nothing")
        #expect(rig.kept() == ["half a thought"], "nothing you said is lost to an Esc")
        #expect(rig.calls == ["start", "stop"])
    }

    @Test("F5 inside the popup listens again")
    func f5Toggles() throws {
        let rig = try Rig()
        defer { rig.close() }
        let popup = rig.popup()
        #expect(popup.handle(key(96, "\u{F708}", [.function])))
        #expect(popup.isListening)
        #expect(popup.handle(key(96, "\u{F708}", [.function])))
        #expect(!popup.isListening)
        #expect(rig.calls == ["start", "stop"])
    }

    @Test("⌘↩ sends the text as it stands and keeps it")
    func send() throws {
        let rig = try Rig()
        defer { rig.close() }
        let popup = rig.popup()
        popup.startListening()
        popup.editor.string = "run the build\nthen the tests"
        #expect(popup.handle(key(36, "\r", [.command])))
        #expect(rig.sent == ["run the build\nthen the tests"])
        #expect(rig.kept() == ["run the build\nthen the tests"])
        #expect(rig.calls.last == "stop", "listening stops before it types")
    }

    @Test("⇧⌘↩ sends one line, and history keeps the lines")
    func sendOneLine() throws {
        let rig = try Rig()
        defer { rig.close() }
        let popup = rig.popup()
        popup.editor.string = "run the build\nthen the tests"
        #expect(popup.handle(key(36, "\r", [.command, .shift])))
        #expect(rig.sent == ["run the build then the tests"])
        #expect(rig.kept() == ["run the build\nthen the tests"])
    }

    @Test("an empty box sends nothing and stays open")
    func sendNothing() throws {
        let rig = try Rig()
        defer { rig.close() }
        let popup = rig.popup()
        popup.send(oneLine: false)
        #expect(rig.sent.isEmpty)
    }

    @Test("it opens with history, newest first")
    func opensWithHistory() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.say("older")
        rig.say("newer")
        let popup = rig.popup()
        #expect(popup.entries.map(\.content) == ["newer", "older"])
        #expect(popup.table.numberOfRows == 2)
    }

    @Test("recalling an entry keeps what the box held first")
    func recallKeepsTheBox() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.say("from yesterday")
        let popup = rig.popup()
        popup.editor.string = "just said this"
        popup.load(row: 0)
        #expect(popup.text == "from yesterday")
        #expect(rig.kept() == ["just said this", "from yesterday"])
    }

    @Test("a recalled entry, edited and sent, is a new entry and the original stays")
    func editIsNew() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.say("run the build")
        let popup = rig.popup()
        popup.load(row: 0)
        popup.editor.string = "run the release build"
        popup.send(oneLine: false)
        #expect(rig.sent == ["run the release build"])
        #expect(rig.kept() == ["run the release build", "run the build"])
    }

    @Test("a recalled entry left alone is not kept again on close")
    func recallUntouched() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.say("first")
        rig.say("second")
        let popup = rig.popup()
        popup.load(row: 1)
        popup.escape()
        #expect(rig.sent == [nil])
        #expect(rig.kept() == ["second", "first"], "the order did not move")
    }

    @Test("a recalled entry sent as it was moves to the top")
    func recallSent() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.say("first")
        rig.say("second")
        let popup = rig.popup()
        popup.load(row: 1)
        popup.send(oneLine: false)
        #expect(rig.sent == ["first"])
        #expect(rig.kept() == ["first", "second"])
    }

    @Test("dictation_history_keep = 0 keeps nothing, and still sends")
    func historyOff() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.config.dictationHistoryKeep = 0
        let popup = rig.popup()
        popup.editor.string = "off the record"
        popup.send(oneLine: false)
        #expect(rig.sent == ["off the record"])
        rig.config.dictationHistoryKeep = 200
        #expect(rig.kept().isEmpty)
    }
}
