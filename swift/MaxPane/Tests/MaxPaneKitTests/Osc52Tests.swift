import AppKit
import Foundation
import GhosttyTerminal
import ObjectiveC
import Testing
@testable import MaxPaneKit
@testable import RelayClient

/// A private pasteboard standing where `NSPasteboard.general` is, for the
/// whole test process, from the first time it is asked for.
///
/// The library reads and writes `NSPasteboard.general` by name and cannot be
/// handed another (`TerminalCallbacks.readClipboard`, `setPasteboardString`),
/// so a test of a real surface reading the clipboard *would* read the owner's,
/// and one that went wrong would write it. `+[NSPasteboard generalPasteboard]`
/// is an Objective-C class method, so it can be pointed elsewhere. Never put
/// back: no test has a reason to want the real one.
@MainActor
enum GeneralPasteboardStandIn {
    static let pasteboard: NSPasteboard = {
        let board = NSPasteboard(name: .init("maxpane.tests.general-stand-in.\(UUID().uuidString)"))
        let method = class_getClassMethod(NSPasteboard.self, NSSelectorFromString("generalPasteboard"))!
        let block: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        method_setImplementation(method, imp_implementationWithBlock(block))
        return board
    }()

    // There is one of it, and suites run beside each other: whoever puts a
    // known string on it holds it until they are done.
    private static var held = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    static func take() async {
        _ = pasteboard
        if held {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            held = true
        }
    }

    static func giveBack() {
        if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() }
    }
}

@Suite("osc52_write and osc52_read are settings: allow, and ask")
struct Osc52SettingTests {
    private func lookup(_ key: String) -> ConfigField? { ConfigField.all.first { $0.key == key } }

    @Test("write is allowed and read asks by default; both are choices under Terminals, read at each request")
    func schema() throws {
        #expect(Config().osc52Write == .allow)
        #expect(Config().osc52Read == .ask)
        for (key, shipped) in [("osc52_write", "allow"), ("osc52_read", "ask")] {
            let field = try #require(lookup(key))
            #expect(field.group == .terminals)
            #expect(field.defaultValue == .string(shipped))
            #expect(field.appliesLive)
            guard case .choice(let options) = field.control else {
                Issue.record("\(key) is not a choice")
                continue
            }
            #expect(options == ["allow", "ask", "deny"])
        }
    }

    @Test("each value is read; a word that is not one of them costs only itself")
    func decodes() {
        func decode(_ text: String) -> (Config, [ConfigProblem]) { ConfigFile.decode(TomlDocument(text)) }
        for value in ClipboardPermission.allCases {
            let (config, problems) = decode("osc52_write = \"\(value.rawValue)\"\nosc52_read = \"\(value.rawValue)\"\n")
            #expect(config.osc52Write == value)
            #expect(config.osc52Read == value)
            #expect(problems.isEmpty)
        }
        let (config, problems) = decode("osc52_read = \"sure\"\nosc52_write = true\nfont_size = 15\n")
        #expect(config.osc52Read == .ask)
        #expect(config.osc52Write == .allow)
        #expect(config.fontSize == 15)
        #expect(Set(problems.map(\.key)) == ["osc52_read", "osc52_write"])
    }

    @Test("Ghostty is told to ask about both, whatever the settings say, and copy-on-select is its own line")
    @MainActor
    func reachesTheBuilder() {
        func lines(_ config: Config) -> [String] {
            TerminalControllerPool.makeController(for: config).terminalConfiguration.rendered
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("clipboard-") || $0.hasPrefix("copy-on-select") }.sorted()
        }
        // `clipboard-trim-trailing-spaces` is `copy_trim_trailing` (ADR-0033),
        // for the copy `copy_on_select` makes inside the emulator.
        let asks = [
            "clipboard-read = ask", "clipboard-trim-trailing-spaces = true", "clipboard-write = ask",
            "copy-on-select = false",
        ]
        #expect(lines(Config()) == asks)
        var other = Config()
        other.osc52Write = .deny
        other.osc52Read = .allow
        #expect(lines(other) == asks)
    }
}

@Suite("what a program's copy amounts to")
struct ProgramClipboardTests {
    @Test("allow sets, ask asks, deny ignores; an empty one never clears the clipboard")
    func permissions() {
        #expect(ProgramClipboard.write("hello", .allow) == .set)
        #expect(ProgramClipboard.write("hello", .ask) == .ask)
        #expect(ProgramClipboard.write("hello", .deny) == .ignore)
        for permission in ClipboardPermission.allCases {
            #expect(ProgramClipboard.write("", permission) == .ignore)
        }
    }

    @Test("1 MiB is the most: exactly that is set, one byte more is refused in a line, and deny stays silent")
    func cap() {
        let most = String(repeating: "x", count: ProgramClipboard.maxBytes)
        #expect(ProgramClipboard.write(most, .allow) == .set)
        #expect(ProgramClipboard.write(most + "x", .allow)
            == .refuse("a program's copy was refused: 1.0 MB is more than 1 MiB"))
        #expect(ProgramClipboard.write(most + "x", .ask)
            == .refuse("a program's copy was refused: 1.0 MB is more than 1 MiB"))
        #expect(ProgramClipboard.write(most + "x", .deny) == .ignore)
        // Bytes, not characters.
        let wide = String(repeating: "é", count: ProgramClipboard.maxBytes / 2 + 1)
        if case .refuse = ProgramClipboard.write(wide, .allow) {} else { Issue.record("measured in characters") }
    }

    @Test("the sheet names the lane, the program when it is known, and the server a remote read goes to")
    func wording() {
        let local = ProgramClipboard.wording(
            .read, .init(lane: "api", program: "nvim", server: nil), text: "one\ntwo")
        #expect(local.summary == "`nvim` in “api” wants to read the clipboard")
        #expect(local.detail == "2 lines · 7 bytes would be handed over. It goes to whatever is running in that terminal.")
        let remote = ProgramClipboard.wording(
            .read, .init(lane: "deploy", program: nil, server: "yorkshire"), text: "token")
        #expect(remote.summary == "A program in “deploy” on yorkshire wants to read the clipboard")
        #expect(remote.detail == "1 line · 5 bytes would be handed over. It leaves this Mac for yorkshire.")
        let write = ProgramClipboard.wording(
            .write, .init(lane: "api", program: "", server: nil), text: "x")
        #expect(write.summary == "A program in “api” wants to set the clipboard")
        #expect(write.detail == "1 line · 1 byte would replace what is on it.")
    }

    @Test("the one place it lands: a pasteboard handed in")
    @MainActor
    func sets() {
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.osc52-set.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        ProgramClipboard.set("after", on: pasteboard)
        #expect(pasteboard.string(forType: .string) == "after")
    }
}

@Suite("relay's CLIPBOARD frame is delivered, not dropped")
struct RelayClipboardFrameTests {
    private final class Pipe: RelayTransport {
        var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)?
        var onClosed: ((RelayClose) -> Void)?
        var tConnected: Double = 0
        var tFirstSent: Double = 0
        func open(firstPayload: [UInt8]) throws {}
        func send(_ payload: [UInt8]) {}
        func close() {}
    }

    @Test("0x16 is text for the clipboard; an empty one and one over 1 MiB are not delivered; DATA's offset is untouched")
    func delivers() throws {
        let pipe = Pipe()
        let session = RelaySession(id: "osc52-frame", transport: pipe)
        var got: [String] = []
        session.onClipboard = { got.append($0) }
        try session.connect()
        pipe.onPayload?(WSMsg.clipboard, ArraySlice(Array("héllo".utf8)))
        pipe.onPayload?(WSMsg.clipboard, [])
        pipe.onPayload?(WSMsg.clipboard, ArraySlice([UInt8](repeating: 0x78, count: RelaySession.maxClipboardBytes + 1)))
        pipe.onPayload?(WSMsg.clipboard, ArraySlice([UInt8](repeating: 0x78, count: RelaySession.maxClipboardBytes)))
        #expect(got.count == 2)
        #expect(got.first == "héllo")
        #expect(got.last?.utf8.count == RelaySession.maxClipboardBytes)
        #expect(session.offset == 0)
    }
}

/// OSC 52 on a real Ghostty surface, inside a real pane in a real lane.
///
/// Two pasteboards, neither the owner's: the pane's own seam, which is where
/// a program's copy must land, and `GeneralPasteboardStandIn`, which is what
/// the library reads for a read request and where it would write if a write
/// ever got past the pane.
@Suite("OSC 52 on a real surface", .serialized)
@MainActor
struct Osc52SurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "osc52-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var onClipboard: ((String) -> Void)?
        var sent: [UInt8] = []
        var claims = 0
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) { claims += 1 }
        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    /// What Ghostty answers a read with when the answer is no: the reply,
    /// with nothing in it, so the program is not left waiting.
    private static let emptyReply = "\u{1b}]52;c;\u{1b}\\"
    private static func reply(_ text: String) -> String {
        "\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{1b}\\"
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let laneView: LaneView
        let pane: TerminalPaneController
        let wire = Wire()
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.osc52.\(UUID().uuidString)"))
        let general = GeneralPasteboardStandIn.pasteboard
        var config: Config

        init(config: Config = Config(), server: String? = nil) async throws {
            self.config = config
            await GeneralPasteboardStandIn.take()
            #expect(NSPasteboard.general === general)
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-osc52-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(session: SessionKey(server: server, id: "osc52"), near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let lane = store.state.lanes[0]
            pane = TerminalPaneController(
                pane: lane.panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.pasteboard = pasteboard
            pane.attach(wire)
            laneView = LaneView(lane: lane, widthBounds: 420...900)
            laneView.frame = NSRect(x: 20, y: 0, width: 656, height: 600)
            window.contentView?.addSubview(laneView)
            laneView.setPaneView(pane.view, for: lane.panes[0].id, at: 0)
            pane.liveConfig = { [unowned self] in self.config }
            pane.onProgramCopied = { [unowned self] in self.laneView.flashCopied() }
            window.contentView?.layoutSubtreeIfNeeded()
            pasteboard.clearContents()
            pasteboard.setString("untouched", forType: .string)
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

        /// What a program prints: `printf "\033]52;c;$(printf hello | base64)\a"`.
        func programCopies(_ text: String) {
            wire.onData?(ArraySlice(Array("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}".utf8)))
        }

        /// `printf "\033]52;c;?\a"`.
        func programAsksToRead() { wire.onData?(ArraySlice(Array("\u{1b}]52;c;?\u{07}".utf8))) }

        func settle() async throws { try await Task.sleep(nanoseconds: 450_000_000) }

        var header: LaneHeaderView? {
            func find(_ view: NSView) -> LaneHeaderView? {
                if let header = view as? LaneHeaderView { return header }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(laneView)
        }

        func key(_ characters: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        }

        private var closed = false
        func close() {
            guard !closed else { return }
            closed = true
            GeneralPasteboardStandIn.giveBack()
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("a write lands on the pane's pasteboard with copy_on_select off, the header says COPIED, and the library wrote nothing")
    func writes() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        #expect(rig.config.copyOnSelect == false)
        rig.programCopies("hello from tmux")
        try await rig.settle()
        #expect(rig.pasteboard.string(forType: .string) == "hello from tmux")
        // The library's own write would have gone here.
        #expect(rig.general.string(forType: .string) == "general-secret")
        #expect(rig.header?.chipText == "COPIED")
        #expect(rig.pane.noticeText == nil)
        #expect(rig.pane.clipboardSheet == nil)
        // A write has no reply.
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("COPIED goes again on its own")
    func chipFades() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.programCopies("x")
        try await rig.settle()
        #expect(rig.header?.chipText == "COPIED")
        try await Task.sleep(nanoseconds: UInt64((LaneHeaderView.copiedSeconds + 0.4) * 1_000_000_000))
        // Back to what it said before: the rig's session is one no registry
        // has heard of, which the header calls EXITED.
        #expect(rig.header?.chipText == "EXITED")
    }

    @Test("with no header to say it, the pane says it")
    func noticeInstead() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.pane.onProgramCopied = nil
        rig.programCopies("hello")
        try await rig.settle()
        #expect(rig.pasteboard.string(forType: .string) == "hello")
        #expect(rig.pane.noticeText == "a program copied 5 bytes to the clipboard")
    }

    @Test("osc52_write = deny: nothing is set and nothing is said; the setting is read at each request")
    func writeDenied() async throws {
        var config = Config()
        config.osc52Write = .deny
        let rig = try await Rig(config: config)
        defer { rig.close() }
        rig.programCopies("nope")
        try await rig.settle()
        #expect(rig.pasteboard.string(forType: .string) == "untouched")
        #expect(rig.general.string(forType: .string) == "general-secret")
        #expect(rig.header?.chipText == "EXITED")
        #expect(rig.pane.noticeText == nil)

        rig.config.osc52Write = .allow
        rig.programCopies("now yes")
        try await rig.settle()
        #expect(rig.pasteboard.string(forType: .string) == "now yes")
    }

    @Test("osc52_write = ask: a sheet, Deny by ↩ sets nothing, Allow by ⌥A sets it")
    func writeAsks() async throws {
        var config = Config()
        config.osc52Write = .ask
        let rig = try await Rig(config: config)
        defer { rig.close() }
        rig.programCopies("maybe")
        try await rig.settle()
        var sheet = try #require(rig.pane.clipboardSheet)
        #expect(sheet.question == .write)
        #expect(sheet.previewText == "maybe")
        #expect(rig.pasteboard.string(forType: .string) == "untouched")
        sheet.keyDown(with: try rig.key("\r", code: 36))
        #expect(rig.pane.clipboardSheet == nil)
        #expect(rig.pasteboard.string(forType: .string) == "untouched")

        rig.programCopies("maybe")
        try await rig.settle()
        sheet = try #require(rig.pane.clipboardSheet)
        sheet.keyDown(with: try rig.key("a", code: 0, .option))
        #expect(rig.pasteboard.string(forType: .string) == "maybe")
        #expect(rig.header?.chipText == "COPIED")
    }

    @Test("more than 1 MiB is refused in one line, at the pane's door")
    func capped() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.pane.programSetClipboard(String(repeating: "x", count: ProgramClipboard.maxBytes + 1))
        #expect(rig.pasteboard.string(forType: .string) == "untouched")
        #expect(rig.pane.noticeText == "a program's copy was refused: 1.0 MB is more than 1 MiB")
    }

    @Test("relay's CLIPBOARD frame goes through the same door and obeys the same setting")
    func frame() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.wire.onClipboard?("lifted out by pty-host")
        #expect(rig.pasteboard.string(forType: .string) == "lifted out by pty-host")
        #expect(rig.header?.chipText == "COPIED")
        rig.config.osc52Write = .deny
        rig.wire.onClipboard?("not this one")
        #expect(rig.pasteboard.string(forType: .string) == "lifted out by pty-host")
    }

    @Test("a read asks by default: the sheet shows what would go, nothing goes meanwhile, and ↩ denies with an empty reply")
    func readAsksAndDenies() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.programAsksToRead()
        try await rig.settle()
        let sheet = try #require(rig.pane.clipboardSheet)
        #expect(sheet.superview === rig.pane.view)
        #expect(sheet.question == .read)
        #expect(sheet.previewText == "general-secret")
        #expect(sheet.summaryText.hasSuffix("wants to read the clipboard"))
        #expect(rig.wire.sent.isEmpty)

        // Somebody still typing: no letter answers it, `a` least of all.
        for letter in ["a", "y", "p"] { sheet.keyDown(with: try rig.key(letter, code: 0)) }
        #expect(rig.pane.clipboardSheet === sheet)
        #expect(rig.wire.sent.isEmpty)

        sheet.keyDown(with: try rig.key("\r", code: 36))
        try await rig.settle()
        #expect(rig.pane.clipboardSheet == nil)
        #expect(rig.wire.text == Self.emptyReply)
    }

    @Test("in a remote lane the sheet names the server the clipboard would leave for, and the door is the same")
    func remote() async throws {
        let rig = try await Rig(server: "yorkshire")
        defer { rig.close() }
        rig.pane.describeAsker = { ("deploy", "nvim") }
        rig.programAsksToRead()
        try await rig.settle()
        let sheet = try #require(rig.pane.clipboardSheet)
        #expect(sheet.summaryText == "`nvim` in “deploy” on yorkshire wants to read the clipboard")
        #expect(sheet.detailText.hasSuffix("It leaves this Mac for yorkshire."))
        sheet.answer(false)
        rig.wire.onClipboard?("yanked on yorkshire")
        #expect(rig.pasteboard.string(forType: .string) == "yanked on yorkshire")
    }

    @Test("⌥A allows, and the program is handed exactly what the sheet showed")
    func readAllowed() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.programAsksToRead()
        try await rig.settle()
        let sheet = try #require(rig.pane.clipboardSheet)
        sheet.keyDown(with: try rig.key("a", code: 0, .option))
        try await rig.settle()
        #expect(rig.wire.text == Self.reply("general-secret"))
        // Nothing is remembered: the next one asks again.
        rig.wire.sent.removeAll()
        rig.programAsksToRead()
        try await rig.settle()
        #expect(rig.pane.clipboardSheet != nil)
        #expect(rig.wire.sent.isEmpty)
    }

    @Test("a second request under an open sheet is denied, not stacked; a pane torn down under one denies it")
    func oneAtATime() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        rig.programAsksToRead()
        try await rig.settle()
        let first = try #require(rig.pane.clipboardSheet)
        rig.programAsksToRead()
        try await rig.settle()
        #expect(rig.pane.clipboardSheet === first)
        #expect(rig.wire.text == Self.emptyReply)
        // A paste does not go under it either.
        rig.pane.paste(.init(text: "plain"))
        try await rig.settle()
        #expect(rig.wire.text == Self.emptyReply)

        let wire = rig.wire
        wire.sent.removeAll()
        rig.close()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!wire.text.contains(Data("general-secret".utf8).base64EncodedString()))
    }

    @Test("osc52_read = deny answers with nothing and asks nobody; allow hands it over unasked; read at each request")
    func readSettings() async throws {
        var config = Config()
        config.osc52Read = .deny
        let rig = try await Rig(config: config)
        defer { rig.close() }
        rig.programAsksToRead()
        try await rig.settle()
        #expect(rig.pane.clipboardSheet == nil)
        #expect(rig.wire.text == Self.emptyReply)

        rig.wire.sent.removeAll()
        rig.config.osc52Read = .allow
        rig.programAsksToRead()
        try await rig.settle()
        #expect(rig.pane.clipboardSheet == nil)
        #expect(rig.wire.text == Self.reply("general-secret"))
    }
}
