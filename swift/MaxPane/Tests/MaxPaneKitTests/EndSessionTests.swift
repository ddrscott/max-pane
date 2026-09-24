import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit
@testable import RelayClient

// MARK: - the commands

/// ⌃⌘W End Session, ⌘K Clear Scrollback, ⌃⌘R Rename Lane (Omarchy F10,
/// ADR-0039): three commands, each with a key, a menu and a row in ⌘/.
@Suite("End Session, Clear Scrollback and Rename Lane as commands")
struct EndSessionCommandTests {
    @Test("each ships with its key, on a chord nothing else has")
    func chords() {
        let expected: [(Command, KeyChord)] = [
            (.endSession, KeyChord(key: "w", modifiers: [.command, .control])),
            (.clearScrollback, KeyChord(key: "k", modifiers: [.command])),
            (.renameLane, KeyChord(key: "r", modifiers: [.command, .control])),
        ]
        for (command, chord) in expected {
            #expect(Keymap.defaults.chords(for: command) == [chord], "\(command.rawValue)")
            #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [command],
                    "\(chord.text) is held by more than one command")
            // None of the three is a chord macOS or the Edit menu owns.
            #expect(!Keymap.reserved.contains { $0.0 == chord }, "\(chord.text) is reserved")
        }
        #expect(Keymap.defaults.complaints.isEmpty)
    }

    @Test("⌘K is the page's in a web pane; ⌃⌘W and ⌃⌘R are the app's everywhere")
    func claims() {
        #expect(Command.clearScrollback.yieldsToPage)
        #expect(!Keymap.defaults.claimed.contains(KeyChord(key: "k", modifiers: [.command])), "Slack's ⌘K is Slack's")
        #expect(Keymap.defaults.claimed.contains(KeyChord(key: "w", modifiers: [.command, .control])))
        #expect(Keymap.defaults.claimed.contains(KeyChord(key: "r", modifiers: [.command, .control])))
        #expect(!Command.endSession.yieldsToPage && !Command.renameLane.yieldsToPage)
    }

    @Test("they sit where a Mac user looks: File under Close Lane, Edit with the other Clear, View with the lane's shape")
    func menus() {
        #expect(Command.endSession.menu == .file)
        #expect(Command.clearScrollback.menu == .edit && Command.clearScrollback.submenu == nil)
        #expect(Command.renameLane.menu == .view)
        let file = Command.allCases.filter { $0.menu == .file }
        #expect(file.firstIndex(of: .endSession) == file.firstIndex(of: .closeLane).map { $0 + 1 })
        #expect(Command.endSession.title == "End Session…" && Command.renameLane.title == "Rename Lane…")
        #expect(Command.clearScrollback.title == "Clear Scrollback")
        #expect(!Command.endSession.needsWebPane && !Command.clearScrollback.needsWebPane && !Command.renameLane.needsWebPane)
    }
}

// MARK: - the sheet

@Suite("the End Session sheet")
struct EndSessionSheetTests {
    @Test("names the session, its program and its machine, and defaults to Cancel")
    func names() {
        let local = EndSessionSheet(name: "✳ Claude Code", command: "claude", server: nil)
        #expect(local.title == "End this session?")
        #expect(local.detail.hasPrefix("✳ Claude Code — claude, on this Mac, will be killed and its pane will close."))
        #expect(local.detail.contains("the Relay web client on your phone included"))
        let remote = EndSessionSheet(name: "htop", command: "htop", server: "yorkshire")
        #expect(remote.detail.hasPrefix("htop, on yorkshire, will be killed"), "the program is not said twice")
        let bare = EndSessionSheet(name: "", command: "", server: nil)
        #expect(bare.detail.hasPrefix("The session, on this Mac, will be killed"))
        #expect(EndSessionSheet.action == "End Session")
    }

    @Test("the popup itself puts ↩ on Cancel")
    @MainActor
    func returnIsCancel() {
        var answers: [Bool] = []
        let sheet = EndSessionSheet(name: "claude", command: "claude", server: nil)
        let popup = ConfirmPopup(
            title: sheet.title, detail: sheet.detail,
            choices: [.init(title: "Cancel", isDefault: true), .init(title: EndSessionSheet.action, isDefault: false)]
        ) { choice, _ in answers.append(choice == 1) }
        // What ↩ presses is the default choice, which `confirm(returnConfirms:
        // false)` makes Cancel — the same shape `confirmClearPasteHistory` uses.
        popup.choose(0)
        #expect(answers == [false])
    }
}

// MARK: - ending a local session

/// The local ender is `kill(pid, SIGTERM)` on pty-host's pid. Proved on a
/// process the test owns, never on a session in `~/.relay-tty`.
@Suite("ending a session on this Mac")
struct LocalSessionEnderTests {
    @Test("SIGTERM reaches the pid the session file names, and the process ends by it")
    func terminates() async throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["300"]
        try sleep.run()
        defer { if sleep.isRunning { sleep.terminate() } }
        let pid = sleep.processIdentifier
        #expect(LocalSessionEnder.terminate(sessionId: "s1", pid: pid) == nil)
        let end = Date().addingTimeInterval(5)
        while sleep.isRunning, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!sleep.isRunning, "sleep survived SIGTERM")
        #expect(sleep.terminationReason == .uncaughtSignal && sleep.terminationStatus == SIGTERM)
    }

    @Test("a session already gone is ended, and one with no pid is refused by name")
    func edges() async throws {
        // A pid nothing holds: a process the test ran and reaped.
        let short = Process()
        short.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try short.run()
        short.waitUntilExit()
        let gone = short.processIdentifier
        #expect(LocalSessionEnder.terminate(sessionId: "s2", pid: gone) == nil, "ESRCH is success: the session ended first")
        #expect(LocalSessionEnder.terminate(sessionId: "s3", pid: nil) == .noPid(sessionId: "s3"))
        #expect(LocalSessionEnder.terminate(sessionId: "s4", pid: 0) == .noPid(sessionId: "s4"))
        #expect(SessionEndError.noPid(sessionId: "s3").errorDescription == "could not end s3 — its session file names no process")
    }

    @Test("the ender reads the pid through the lookup it was given, once, on the main actor")
    @MainActor
    func lookup() async throws {
        let sleep = Process()
        sleep.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleep.arguments = ["300"]
        try sleep.run()
        defer { if sleep.isRunning { sleep.terminate() } }
        var asked: [String] = []
        let ender = LocalSessionEnder { id in asked.append(id); return sleep.processIdentifier }
        var answers: [Error?] = []
        ender.end(sessionId: "abc12345") { answers.append($0) }
        #expect(asked == ["abc12345"])
        #expect(answers.count == 1 && answers[0] == nil)
        let end = Date().addingTimeInterval(5)
        while sleep.isRunning, Date() < end { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(!sleep.isRunning)
    }
}

// MARK: - ending a remote session

/// `DELETE /api/sessions/:id` with the cookie, against the fake server.
@Suite("ending a session on a remote server", .serialized)
@MainActor
struct RemoteSessionEnderTests {
    private func spin(_ seconds: TimeInterval, until cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    @Test("a 200 ends it: the request is a DELETE with the cookie, and the server drops the row")
    func deletes() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("c0ffee11"), FakeRelayServer.session("c0ffee12")]
        let ender = RemoteSessionEnder(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: server.token))
        var answers: [Error?] = []
        ender.end(sessionId: "c0ffee11") { answers.append($0) }
        #expect(await spin(5) { !answers.isEmpty }, "the completion was never called")
        #expect(answers.count == 1 && answers[0] == nil, "\(String(describing: answers))")
        #expect(server.deletedIds == ["c0ffee11"])
        #expect(server.requestLines.contains("DELETE /api/sessions/c0ffee11 HTTP/1.1"))
        #expect(server.sessions.map { $0["id"] as? String } == ["c0ffee12"])
    }

    @Test("a 404 and a refused token are errors naming the server, and the pane is not to close")
    func refusals() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.sessions = [FakeRelayServer.session("c0ffee21")]
        let good = RemoteSessionEnder(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: server.token))
        var answers: [Error?] = []
        good.end(sessionId: "nope0000") { answers.append($0) }
        #expect(await spin(5) { !answers.isEmpty })
        #expect(answers.first.flatMap { $0.map(StripWindowController.describe) }
                == "yorkshire: could not end the session — HTTP 404: Session not found")

        let guest = RemoteSessionEnder(name: "yorkshire", endpoint: RelayServer(baseURL: server.baseURL, token: "wrong"))
        answers.removeAll()
        guest.end(sessionId: "c0ffee21") { answers.append($0) }
        #expect(await spin(5) { !answers.isEmpty })
        #expect(answers.first.flatMap { $0.map(StripWindowController.describe) }
                == "yorkshire: could not end the session — HTTP 401")
        #expect(server.deletedIds.isEmpty, "nothing was ended")
    }

    @Test("a server that is not there is unreachable, not a hang")
    func unreachable() async throws {
        let server = try FakeRelayServer()
        let endpoint = RelayServer(baseURL: server.baseURL, token: server.token)
        server.stop()
        let ender = RemoteSessionEnder(name: "yorkshire", endpoint: endpoint)
        var answers: [Error?] = []
        ender.end(sessionId: "c0ffee31") { answers.append($0) }
        #expect(await spin(10) { !answers.isEmpty })
        let text = answers.first.flatMap { $0.map(StripWindowController.describe) } ?? ""
        #expect(text.hasPrefix("yorkshire: could not end the session — "), Comment(rawValue: text))
    }

    @Test("RelayServers hands out the local ender for nil, the remote one for a name it has, nothing for a stranger")
    func byServer() {
        let servers = RelayServers(entries: [
            RelayServerEntry(name: "yorkshire", url: "http://127.0.0.1:7680", enabled: true),
        ]) { _ in "tok" }
        #expect(servers.ender(for: nil) is LocalSessionEnder)
        #expect(servers.ender(for: "yorkshire") is RemoteSessionEnder)
        #expect(servers.ender(for: "elsewhere") == nil)
    }
}

// MARK: - rename

@Suite("renaming a lane")
@MainActor
struct RenameLaneTests {
    private final class Wire: RelayAttachment {
        let sessionId: String
        init(_ id: String) { sessionId = id }
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var titles: [String] = []
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) {}
        func claimSize(cols: Int, rows: Int) {}
        func setTitle(_ title: String) { titles.append(title) }
    }

    @Test("SET_TITLE is 0x24 and the UTF-8, empty to unpin — relay-tty's encodeSetTitle")
    func encoding() {
        #expect(encodeSetTitle("docs") == [0x24, 0x64, 0x6f, 0x63, 0x73])
        #expect(encodeSetTitle("") == [0x24])
        #expect(encodeSetTitle("é") == [0x24, 0xc3, 0xa9])
    }

    @Test("a terminal lane's name goes to the ledger and, pinned, to the session; empty unpins and clears")
    func terminalLane() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "rename01", near: nil)
        try store.newWebLane(url: "https://example.com/", near: store.state.lanes[0].id)
        let terminalLane = store.state.lanes[0]
        let webLane = store.state.lanes[1]
        let config = Config()
        let strip = StripViewController(store: store, config: config)
        var wires: [String: Wire] = [:]
        strip.controllerFactory = { pane, _ in
            if pane.kind == .pty {
                let controller = TerminalPaneController(
                    pane: pane, store: store, config: config,
                    controller: TerminalControllerPool.makeController(for: config))
                let wire = Wire(pane.relaySessionId ?? "")
                wires[pane.id] = wire
                controller.attach(wire)
                return controller
            }
            return StubPane(pane)
        }
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1600, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        strip.view.frame = window.contentView!.bounds
        window.contentView?.addSubview(strip.view)
        for _ in 0..<3 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let wire = try #require(wires[terminalLane.panes[0].id])
        let terminal = try #require(strip.paneController(terminalLane.panes[0].id) as? TerminalPaneController)

        strip.applyRename(terminalLane.id, to: "docs", on: terminal)
        #expect(store.lane(terminalLane.id)?.title == "docs")
        #expect(wire.titles == ["docs"], "pinned on the session, so the program's next OSC title does not take it back")
        // What the header reads: the ledger's title beats the session's.
        let telemetry = SessionTelemetry(sessionId: "rename01", title: "◐ Claude Code", command: "claude")
        #expect(LaneHeaderModel(lane: try #require(store.lane(terminalLane.id)), telemetry: telemetry).title == "docs")

        strip.applyRename(terminalLane.id, to: "", on: terminal)
        #expect(store.lane(terminalLane.id)?.title == nil)
        #expect(wire.titles == ["docs", ""], "empty is the unpin")
        #expect(LaneHeaderModel(lane: try #require(store.lane(terminalLane.id)), telemetry: telemetry).title == "◐ Claude Code")

        // A web lane has no session: the ledger alone.
        strip.applyRename(webLane.id, to: "The docs", on: nil)
        #expect(store.lane(webLane.id)?.title == "The docs")
        #expect(wire.titles.count == 2)

        // The ⋯ menu: Rename Lane… on both, End Session… on the terminal only, last.
        let terminalMenu = try #require(strip.laneView(for: terminalLane.id)).overflowMenu.items
        let webMenu = try #require(strip.laneView(for: webLane.id)).overflowMenu.items
        #expect(terminalMenu.contains { $0.title == "Rename Lane…" && $0.isEnabled })
        #expect(webMenu.contains { $0.title == "Rename Lane…" && $0.isEnabled })
        #expect(terminalMenu.last?.title == "End Session…")
        #expect(terminalMenu.last?.isEnabled == true)
        #expect(terminalMenu.last?.keyEquivalent == "w" && terminalMenu.last?.keyEquivalentModifierMask == [.command, .control])
        #expect(!webMenu.contains { $0.title == "End Session…" })
        #expect(terminalMenu.first { $0.title == "Rename Lane…" }?.keyEquivalent == "r")
        strip.view.removeFromSuperview()
    }
}

// MARK: - ⌘K

/// ⌘K against a real libghostty surface: what was printed above the cursor
/// is gone from the viewport, and nothing was sent to the session.
@Suite("clearing a real terminal", .serialized)
@MainActor
struct ClearScrollbackSurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "clear-test"
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

    @Test("⌘K empties the viewport above the cursor and touches the wire not at all")
    func clears() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "clear-test", near: nil)
        let config = Config()
        let pane = TerminalPaneController(
            pane: store.state.lanes[0].panes[0], store: store, config: config,
            controller: TerminalControllerPool.makeController(for: config))
        let wire = Wire()
        pane.attach(wire)
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 700, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { pane.tearDown(); window.close() }
        pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 400)
        window.contentView?.addSubview(pane.view)
        window.contentView?.layoutSubtreeIfNeeded()
        // Until the surface has settled on a size.
        var quiet = 0
        var last = -1
        for _ in 0..<240 where quiet < 12 {
            try await Task.sleep(nanoseconds: 25_000_000)
            quiet = (wire.claims == last && wire.claims > 0) ? quiet + 1 : 0
            last = wire.claims
        }
        wire.sent.removeAll()

        wire.onData?(ArraySlice(Array("one apple\r\ntwo pears\r\nthree plums\r\n".utf8)))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(pane.viewportText.contains("two pears"), "the lines never reached the surface: \(pane.viewportText)")

        pane.clearScrollback()
        try await Task.sleep(nanoseconds: 250_000_000)
        let after = pane.viewportText
        #expect(!after.contains("one apple") && !after.contains("two pears") && !after.contains("three plums"), Comment(rawValue: after))
        #expect(wire.sent.isEmpty, "⌘K is local; the session was not told")
        // And the pane is still a terminal: what comes next lands.
        wire.onData?(ArraySlice(Array("four figs\r\n".utf8)))
        try await Task.sleep(nanoseconds: 250_000_000)
        #expect(pane.viewportText.contains("four figs"))
    }
}
