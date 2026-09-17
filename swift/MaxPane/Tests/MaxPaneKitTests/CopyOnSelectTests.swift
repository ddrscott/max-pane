import AppKit
import Foundation
import GhosttyTerminal
import Testing
@testable import MaxPaneKit

/// `copy_on_select`: a selection is not a copy unless the config says it is.
///
/// It was hard-coded on from the libghostty migration, and every accidental
/// highlight replaced whatever had been copied on purpose a moment before.
@Suite("copy on select is a setting, and off")
struct CopyOnSelectSettingTests {
    private var field: ConfigField? { ConfigField.all.first { $0.key == "copy_on_select" } }

    @Test("off by default, a toggle under Terminals, taken on relaunch like the font")
    func schema() throws {
        #expect(Config().copyOnSelect == false)
        let field = try #require(field)
        #expect(field.name == "copyOnSelect")
        #expect(field.group == .terminals)
        #expect(field.defaultValue == .bool(false))
        // Read once, when the terminals' shared configuration is built — the
        // same as `font_name` and `font_size`. The window says "on relaunch".
        let font = try #require(ConfigField.all.first { $0.key == "font_size" })
        #expect(field.appliesLive == font.appliesLive)
        #expect(!field.appliesLive)
    }

    @Test("a file with no such line is off; the line is read either way; a wrong type costs only itself")
    func decodes() {
        func decode(_ text: String) -> (Config, [ConfigProblem]) { ConfigFile.decode(TomlDocument(text)) }
        #expect(decode("font_size = 15\n").0.copyOnSelect == false)
        #expect(decode("copy_on_select = true\n").0.copyOnSelect == true)
        #expect(decode("copy_on_select = false\n").0.copyOnSelect == false)
        let (config, problems) = decode("copy_on_select = \"yes\"\nfont_size = 15\n")
        #expect(config.copyOnSelect == false)
        #expect(config.fontSize == 15)
        #expect(problems.map(\.key) == ["copy_on_select"])
    }

    @Test("the settings window writes one line, and taking it out is off again")
    @MainActor
    func roundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-copy-on-select-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try Data("# mine\nfont_size = 15  # big\n".utf8).write(to: file)
        let store = ConfigStore(path: file, watches: false)
        let field = try #require(field)

        // Reading a file that does not mention it writes nothing into it.
        #expect(!store.isSet(field))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nfont_size = 15  # big\n")

        store.set(field, to: .bool(true))
        #expect(try String(contentsOf: file, encoding: .utf8) == "# mine\nfont_size = 15  # big\ncopy_on_select = true\n")
        #expect(store.config.copyOnSelect)
        #expect(ConfigStore(path: file, watches: false).config.copyOnSelect)

        store.set(field, to: nil)
        #expect(!store.isSet(field))
        #expect(store.config.copyOnSelect == false)
    }

    @Test("the terminal configuration says it out loud, both ways")
    @MainActor
    func reachesTheBuilder() {
        func lines(_ config: Config) -> [String] {
            TerminalControllerPool.makeController(for: config).terminalConfiguration.rendered
                .split(separator: "\n").map(String.init).filter { $0.hasPrefix("copy-on-select") }
        }
        // Never left to Ghostty's default, which is what would let it move.
        #expect(lines(Config()) == ["copy-on-select = false"])
        var on = Config()
        on.copyOnSelect = true
        #expect(lines(on) == ["copy-on-select = true"])
    }
}

/// The same, on a real surface and the real pasteboard — which is the only
/// place "selecting does not copy, ⌘C does" can be seen to be true.
///
/// The general pasteboard is the user's. Whatever string was on it is put back.
@Suite("selecting and copying, on a real surface", .serialized)
@MainActor
struct CopyOnSelectSurfaceTests {
    private static let sentinel = "maxpane-copy-on-select-sentinel"

    private final class Rig {
        final class Viewports: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func add() { lock.withLock { n += 1 } }
            var count: Int { lock.withLock { n } }
        }

        let viewports = Viewports()
        let session: InMemoryTerminalSession
        let terminal: ClickableTerminalView
        let window: NSWindow

        @MainActor
        init(config: Config) async throws {
            let viewports = self.viewports
            session = InMemoryTerminalSession(
                write: { _ in }, resize: { _ in viewports.add() }, suppressesPixelOnlyResizes: false)
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
            // Not the shared controller — see `TerminalControllerPool.makeController`.
            terminal.controller = TerminalControllerPool.makeController(for: config)
            terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            window.contentView?.addSubview(terminal)
            terminal.layoutSubtreeIfNeeded()
            var quiet = 0
            var last = viewports.count
            for _ in 0..<240 where quiet < 12 {
                terminal.fitToSize()
                try await Task.sleep(nanoseconds: 25_000_000)
                let now = viewports.count
                quiet = (now == last && now > 0) ? quiet + 1 : 0
                last = now
            }
            session.receive("copy me\r\n")
            session.waitForPendingOutput()
        }

        /// Select everything, then give any clipboard write — they hop to the
        /// main queue — long enough to have landed.
        @MainActor
        func select() async throws {
            #expect(terminal.performBindingAction("select_all"))
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    /// Runs `body` with a known string on the general pasteboard, then puts
    /// back what was there.
    private func withSentinel(_ body: () async throws -> Void) async throws {
        let pasteboard = NSPasteboard.general
        let before = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(Self.sentinel, forType: .string)
        defer {
            pasteboard.clearContents()
            if let before { pasteboard.setString(before, forType: .string) }
        }
        try await body()
    }

    private var clipboard: String? { NSPasteboard.general.string(forType: .string) }

    @Test("off: a selection leaves the clipboard alone, and Copy still copies it")
    func offSelectsWithoutCopying() async throws {
        try await withSentinel {
            let rig = try await Rig(config: Config())
            defer { rig.window.close() }
            try await rig.select()
            #expect(clipboard == Self.sentinel)

            // ⌘C and Edit › Copy are `copy:` down the responder chain; the
            // right-click Copy item targets the same selector.
            rig.terminal.copy(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(clipboard?.contains("copy me") == true)
        }
    }

    /// Today's behaviour, kept for whoever turns it on — and the proof that the
    /// test above is looking at the right thing: the same selection, with only
    /// the setting different, does replace the clipboard.
    @Test("on: a selection is a copy, as it was")
    func onSelectsAndCopies() async throws {
        try await withSentinel {
            var config = Config()
            config.copyOnSelect = true
            let rig = try await Rig(config: config)
            defer { rig.window.close() }
            try await rig.select()
            #expect(clipboard?.contains("copy me") == true)
        }
    }
}
