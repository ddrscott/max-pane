import AppKit
import Testing
import Foundation
@testable import MaxPaneKit

/// F1 of the Omarchy critique (ADR-0037): the ring ⌘J walks, the banner an
/// agent posts while nobody is looking, the ⌥⌘J list and the Dock badge.
/// Nothing here reaches `UNUserNotificationCenter`: the poster is a recorder.
@Suite("attention: ⌘J, the notification, the list and the badge")
@MainActor
struct AttentionTests {
    private typealias Entry = AttentionOrder.Entry

    private func telemetry(
        _ id: String, server: String? = nil, title: String = "✳ Fix the tests", cwd: String = "/tmp/x",
        state: AgentState = .idle, running: Bool = true, activity: Date? = nil
    ) -> SessionTelemetry {
        var t = SessionTelemetry(
            sessionId: id, server: server, title: title, cwd: cwd, command: "claude", state: state,
            lastActivity: activity, isRunning: running)
        t.connection = server == nil ? nil : .connected
        return t
    }

    // MARK: - the ring

    @Test("the ring is BLOCKED in strip order, then DONE in strip order")
    func ring() {
        let entries = [
            Entry(key: "d2", state: .done, laneIndex: 5),
            Entry(key: "b2", state: .blocked, laneIndex: 3),
            Entry(key: "d1", state: .done, laneIndex: 1),
            Entry(key: "b1", state: .blocked, laneIndex: 0),
            Entry(key: "w", state: .working, laneIndex: 2),
        ]
        #expect(AttentionOrder.ring(entries) == ["b1", "b2", "d1", "d2"])
    }

    @Test("⌘J from a lane in the ring goes to the one after it, and wraps")
    func nextFromInsideTheRing() {
        let entries = [
            Entry(key: "b1", state: .blocked, laneIndex: 0),
            Entry(key: "b2", state: .blocked, laneIndex: 3),
            Entry(key: "d1", state: .done, laneIndex: 1),
        ]
        #expect(AttentionOrder.next(entries, from: 0, focusedSession: "b1") == "b2")
        #expect(AttentionOrder.next(entries, from: 3, focusedSession: "b2") == "d1")
        #expect(AttentionOrder.next(entries, from: 1, focusedSession: "d1") == "b1")
        // Backwards is the same ring the other way.
        #expect(AttentionOrder.previous(entries, from: 0, focusedSession: "b1") == "d1")
        #expect(AttentionOrder.previous(entries, from: 1, focusedSession: "d1") == "b2")
        #expect(AttentionOrder.previous(entries, from: 3, focusedSession: "b2") == "b1")
    }

    @Test("⌘J from a lane outside the ring: the first BLOCKED to the right, wrapping, then DONE")
    func nextFromOutsideTheRing() {
        let entries = [
            Entry(key: "b1", state: .blocked, laneIndex: 1),
            Entry(key: "b2", state: .blocked, laneIndex: 4),
            Entry(key: "d1", state: .done, laneIndex: 6),
        ]
        #expect(AttentionOrder.next(entries, from: 2, focusedSession: "w") == "b2")
        #expect(AttentionOrder.next(entries, from: 5, focusedSession: "w") == "b1")
        #expect(AttentionOrder.next(entries, from: nil, focusedSession: nil) == "b1")
        // With nothing BLOCKED, DONE the same way.
        let done = [Entry(key: "d1", state: .done, laneIndex: 1), Entry(key: "d2", state: .done, laneIndex: 4)]
        #expect(AttentionOrder.next(done, from: 2, focusedSession: "w") == "d2")
        #expect(AttentionOrder.next(done, from: 4, focusedSession: "w") == "d1")
        // ⇧⌘J: the last DONE to the left, wrapping, then BLOCKED.
        #expect(AttentionOrder.previous(entries, from: 2, focusedSession: "w") == "d1")
        #expect(AttentionOrder.previous(entries, from: 7, focusedSession: "w") == "d1")
        #expect(AttentionOrder.previous(done, from: 3, focusedSession: "w") == "d1")
        #expect(AttentionOrder.previous(done, from: 0, focusedSession: "w") == "d2")
    }

    @Test("the only attention is the focused lane itself: ⌘J stays; none: ⌘J is nil")
    func edges() {
        let one = [Entry(key: "b1", state: .blocked, laneIndex: 2)]
        #expect(AttentionOrder.next(one, from: 2, focusedSession: "b1") == "b1")
        #expect(AttentionOrder.previous(one, from: 2, focusedSession: "b1") == "b1")
        #expect(AttentionOrder.next([], from: 0, focusedSession: nil) == nil)
        #expect(AttentionOrder.previous([Entry(key: "w", state: .working, laneIndex: 0)], from: 0, focusedSession: nil) == nil)
    }

    // MARK: - the badge

    @Test("the Dock badge is the BLOCKED count, and nothing at zero")
    func badge() {
        #expect(AttentionBadge.label(blocked: 0) == nil)
        #expect(AttentionBadge.label(blocked: 1) == "1")
        #expect(AttentionBadge.label(blocked: 12) == "12")
    }

    // MARK: - the notification

    @Test("away posts only while the app is not in front; always spares the focused pane; never posts nothing")
    func whenToPost() {
        typealias N = AgentNotifier
        #expect(N.shouldPost(state: .blocked, mode: .away, appActive: false, isFocused: false))
        #expect(N.shouldPost(state: .done, mode: .away, appActive: false, isFocused: true))
        #expect(!N.shouldPost(state: .blocked, mode: .away, appActive: true, isFocused: false))
        #expect(N.shouldPost(state: .blocked, mode: .always, appActive: true, isFocused: false))
        #expect(!N.shouldPost(state: .blocked, mode: .always, appActive: true, isFocused: true))
        #expect(N.shouldPost(state: .blocked, mode: .always, appActive: false, isFocused: true))
        #expect(!N.shouldPost(state: .blocked, mode: .never, appActive: false, isFocused: false))
        // Only the two states worth interrupting for.
        for state in [AgentState.working, .idle, .unknown, .exited] {
            #expect(!N.shouldPost(state: state, mode: .always, appActive: false, isFocused: false))
        }
    }

    @Test("the banner: title, `STATE · dir` subtitle, last line as body, a fallback body when blank")
    func content() {
        let home = NSHomeDirectory()
        let t = telemetry("0368d543", title: "✳ Post workshop survey", cwd: home + "/code/max-pane", state: .blocked)
        let c = AgentNotifier.content(for: t, state: .blocked, lastLine: "  Do you want to proceed? (y/n)  ")
        #expect(c.title == "✳ Post workshop survey")
        #expect(c.subtitle == "BLOCKED · ~/code/max-pane")
        #expect(c.body == "Do you want to proceed? (y/n)")
        let blank = AgentNotifier.content(for: t, state: .done, lastLine: "   ")
        #expect(blank.subtitle == "DONE · ~/code/max-pane")
        #expect(blank.body == "Finished")
        #expect(AgentNotifier.content(for: t, state: .blocked, lastLine: nil).body == "Waiting on you")
        // No title: the command. Remote: the server's path as the server gave it.
        let remote = telemetry("aa", server: "yorkshire", title: "", cwd: "/home/spierce/x")
        let r = AgentNotifier.content(for: remote, state: .done, lastLine: nil)
        #expect(r.title == "claude")
        #expect(r.subtitle == "DONE · yorkshire:/home/spierce/x")
    }

    @Test("a transition posts once, a later state takes the banner down, and a click goes to the session")
    func lifecycle() {
        let poster = RecordedNotificationPoster()
        let notifier = AgentNotifier(poster: poster) { .away }
        notifier.isAppActive = { false }
        notifier.lastLine = { _ in "❯ 1. Yes" }
        var authorized = 0
        notifier.ensureAuthorized = { authorized += 1 }
        var went: [SessionKey] = []
        notifier.onActivate = { went.append($0) }

        let t = telemetry("0368d543", state: .blocked)
        notifier.stateChanged(t, to: .blocked)
        #expect(poster.posted.count == 1)
        #expect(poster.posted[0].identifier == "maxpane.agent.0368d543")
        #expect(poster.posted[0].subtitle.hasPrefix("BLOCKED · "))
        #expect(poster.posted[0].body == "❯ 1. Yes")
        #expect(poster.posted[0].icon == nil)
        #expect(authorized == 1)

        // Answered: the banner goes, and nothing is posted for WORKING.
        notifier.stateChanged(t, to: .working)
        #expect(poster.posted.count == 1)
        #expect(poster.removed == ["maxpane.agent.0368d543"])
        #expect(notifier.posted.isEmpty)

        // DONE later: one more, under the same identifier, so it replaces.
        notifier.stateChanged(t, to: .done)
        #expect(poster.posted.count == 2)
        #expect(poster.posted[1].identifier == "maxpane.agent.0368d543")
        #expect(authorized == 2, "asked at every post; the centre is what makes it once per process")

        // A swipe-away goes nowhere; a click goes to the session.
        notifier.activated(identifier: "maxpane.agent.0368d543", dismissed: true)
        #expect(went.isEmpty)
        notifier.stateChanged(t, to: .blocked)
        notifier.activated(identifier: "maxpane.agent.0368d543", dismissed: false)
        #expect(went == ["0368d543"])
        notifier.activated(identifier: "maxpane.agent.0368d543", dismissed: false)
        #expect(went.count == 1, "a banner is clicked once")
    }

    @Test("in front, away posts nothing; always posts for every pane but the focused one")
    func inFront() {
        let poster = RecordedNotificationPoster()
        var mode = AgentNotify.away
        let notifier = AgentNotifier(poster: poster) { mode }
        notifier.isAppActive = { true }
        notifier.focusedSession = { "focused" }
        notifier.stateChanged(telemetry("other", state: .blocked), to: .blocked)
        #expect(poster.posted.isEmpty)
        mode = .always
        notifier.stateChanged(telemetry("focused", state: .blocked), to: .blocked)
        #expect(poster.posted.isEmpty, "the pane with the keyboard is the one you are looking at")
        notifier.stateChanged(telemetry("other", state: .done), to: .done)
        #expect(poster.posted.map(\.identifier) == ["maxpane.agent.other"])
        mode = .never
        notifier.isAppActive = { false }
        notifier.stateChanged(telemetry("third", state: .blocked), to: .blocked)
        #expect(poster.posted.count == 1)
    }

    @Test("the offline and the exited never post: their shown state is not an alarm")
    func neverForADeadServer() {
        let poster = RecordedNotificationPoster()
        let notifier = AgentNotifier(poster: poster) { .away }
        notifier.isAppActive = { false }
        var t = telemetry("aa", server: "yorkshire", state: .blocked)
        t.connection = .unreachable
        // What the registry reports for it is `.unknown`; nothing to post.
        #expect(t.state == .unknown)
        notifier.stateChanged(t, to: t.state)
        notifier.stateChanged(telemetry("bb", state: .blocked, running: false), to: .blocked)
        #expect(poster.posted.isEmpty)
    }

    @Test("the registry's transition reaches the notifier through onStateChange, not the first reading")
    func fromTheRegistry() {
        func file(_ id: String, title: String, state: String) -> RelaySessionInfo {
            RelaySessionInfo(
                id: id, command: "claude", args: [], cwd: "/tmp", createdAt: 0, status: "running",
                cols: 80, rows: 24, pid: 1, title: title, lastActivity: 1_000, bps1: 0, agentState: state)
        }
        let poster = RecordedNotificationPoster()
        let notifier = AgentNotifier(poster: poster) { .away }
        notifier.isAppActive = { false }
        let registry = SessionRegistry(files: [file("a", title: "◐ working", state: "active")])
        registry.onStateChange = { t, _, to in notifier.stateChanged(t, to: to) }
        #expect(poster.posted.isEmpty, "a first reading is not a transition")
        registry.adopt([file("a", title: "✳ done now", state: "idle")])
        #expect(poster.posted.map(\.subtitle) == ["DONE · /tmp"])
        registry.adopt([file("a", title: "✳ asking", state: "blocked")])
        #expect(poster.posted.count == 2)
        #expect(poster.posted[1].subtitle == "BLOCKED · /tmp")
        // Looked at: the DONE→idle after a BLOCKED→… takes the banner down.
        registry.adopt([file("a", title: "◐ working", state: "active")])
        #expect(poster.removed.last == "maxpane.agent.a")
    }

    @Test("a click on an agent's banner is routed by the shared centre, past the pages; macOS is asked once")
    func routedThroughTheCentre() {
        let poster = RecordedNotificationPoster()
        let center = WebNotificationCenter(poster: poster)
        center.ensureAuthorized()
        center.ensureAuthorized()
        center.siteGranted()
        #expect(poster.authorizations == 1)
        var seen: [(String, Bool)] = []
        center.addRoute(prefix: AgentNotifier.prefix) { seen.append(($0, $1)) }
        center.activated(identifier: "maxpane.agent.0368d543", dismissed: false)
        center.activated(identifier: "maxpane.pane1.tag.x", dismissed: false)
        #expect(seen.count == 1)
        #expect(seen[0].0 == "maxpane.agent.0368d543")
        #expect(seen[0].1 == false)
    }

    // MARK: - the list

    private func sample(now: Date) -> [SessionTelemetry] {
        [
            telemetry("w", title: "◐ busy", state: .working, activity: now),
            telemetry("d-nolane", title: "✳ finished elsewhere", state: .done, activity: now.addingTimeInterval(-60)),
            telemetry("b2", title: "✳ second prompt", state: .blocked, activity: now),
            telemetry("d1", title: "✳ finished", state: .done, activity: now.addingTimeInterval(-300)),
            telemetry("b1", title: "", state: .blocked, activity: now),
            telemetry("gone", title: "x", state: .blocked, running: false),
        ].map { t in
            // DONE is the registry's: stamp it the way `adopt` would.
            var t = t
            if t.relayState == .done { t.doneSince = now }
            return t
        }
    }

    @Test("rows: BLOCKED then DONE, lanes in strip order, lane-less last, the exited left out")
    func rows() {
        let now = Date()
        let lanes: [SessionKey: Int] = ["b1": 4, "b2": 1, "d1": 2, "w": 0]
        let list = AttentionList(sessions: sample(now: now), laneIndex: { lanes[$0] }, now: now)
        #expect(list.rows.map(\.key) == ["b2", "b1", "d1", "d-nolane"])
        #expect(list.rows.map(\.title) == ["✳ second prompt", "claude", "✳ finished", "✳ finished elsewhere"])
        #expect(list.rows.map(\.hasLane) == [true, true, true, false])
        #expect(list.rows[2].age == "5m ago")
        #expect(list.header == "ATTENTION · 4")
        #expect(list.dismissable == nil, "the selected row is BLOCKED")
        #expect(list.dismissableAll.map(\.key) == ["d1", "d-nolane"])
    }

    @Test("selection moves and wraps, follows a session across a replace, and ⌫ takes only a DONE")
    func selection() {
        let now = Date()
        let lanes: [SessionKey: Int] = ["b1": 4, "b2": 1, "d1": 2]
        var list = AttentionList(sessions: sample(now: now), laneIndex: { lanes[$0] }, now: now)
        list.moveSelection(by: -1)
        #expect(list.current?.key == "d-nolane")
        list.moveSelection(by: 1)
        #expect(list.current?.key == "b2")
        list.select(2)
        #expect(list.dismissable?.key == "d1")
        // d1 is looked at: the selection lands on the row that took its place.
        let after = AttentionList(
            sessions: sample(now: now).filter { $0.sessionId != "d1" }, laneIndex: { lanes[$0] }, now: now)
        list.replace(with: after)
        #expect(list.rows.map(\.key) == ["b2", "b1", "d-nolane"])
        #expect(list.current?.key == "d-nolane")
        // b1 stays selected across a change that keeps it.
        list.select(1)
        list.replace(with: AttentionList(
            sessions: sample(now: now).filter { $0.sessionId != "b2" }, laneIndex: { lanes[$0] }, now: now))
        #expect(list.current?.key == "b1")
        #expect(list.selected == 0)
    }

    @Test("the popup draws the rows and the header, and its keys go, dismiss, and dismiss all")
    func popup() {
        let now = Date()
        let lanes: [SessionKey: Int] = ["b1": 4, "b2": 1, "d1": 2]
        let popup = AttentionPopup(list: AttentionList(sessions: sample(now: now), laneIndex: { lanes[$0] }, now: now))
        var went: [SessionKey] = []
        var dismissed: [SessionKey] = []
        popup.onGo = { went.append($0) }
        popup.onDismiss = { dismissed.append($0) }
        #expect(popup.headerText == "// ATTENTION · 4")
        #expect(popup.rowTitles == ["✳ second prompt", "claude", "✳ finished", "✳ finished elsewhere"])
        #expect(popup.selectedIndex == 0)
        #expect(AttentionPopup.size(rows: 4).height == CGFloat(76 + 4 * 40))
        #expect(AttentionPopup.size(rows: 30).height == CGFloat(76 + 10 * 40), "ten rows, then a scroll")

        popup.handle(key(125))                       // ↓
        popup.handle(key(125))
        #expect(popup.selectedIndex == 2)
        popup.handle(key(51))                        // ⌫ on d1
        #expect(dismissed == ["d1"])
        popup.handle(key(126))                       // ↑ to b1
        popup.handle(key(51))                        // ⌫ on a BLOCKED: nothing
        #expect(dismissed == ["d1"])
        popup.handle(key(51, modifiers: [.command])) // ⌘⌫: every DONE
        #expect(dismissed == ["d1", "d1", "d-nolane"])
        #expect(!popup.handle(key(0)), "a letter is not the popup's")
        popup.handle(key(36))                        // ↩ on b1
        #expect(went == ["b1"])

        // The registry emptied: one line, and the header says zero.
        popup.update(AttentionList(sessions: [], laneIndex: { _ in nil }, now: now))
        #expect(popup.headerText == "// ATTENTION · 0")
        #expect(popup.rowTitles.isEmpty)
        #expect(popup.noticeText == "Nothing needs you.")
    }

    private func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    // MARK: - the setting and the keys

    @Test("agent_notify reads from the file, defaults to away, and is one Settings row")
    func setting() {
        #expect(Config().agentNotify == .away)
        let (config, problems) = ConfigFile.decode(TomlDocument("agent_notify = \"always\"\n"))
        #expect(problems.isEmpty)
        #expect(config.agentNotify == .always)
        #expect(ConfigField.all.contains { $0.key == "agent_notify" && $0.group == .terminals })
    }

    @Test("⌘J, ⇧⌘J and ⌥⌘J are the defaults, under Navigate, and nobody else's")
    func keys() {
        #expect(Command.nextAttention.defaultShortcut! == ("j", [.command]))
        #expect(Command.previousAttention.defaultShortcut! == ("j", [.command, .shift]))
        #expect(Command.showAttention.defaultShortcut! == ("j", [.command, .option]))
        for command in [Command.nextAttention, .previousAttention, .showAttention] {
            #expect(command.menu == .navigate)
        }
        let map = Keymap(overrides: KeyBindings([:]))
        #expect(map.complaints.isEmpty)
    }

    /// The popup as a picture, in both appearances. Gated on `MAXPANE_SHOTS`.
    ///
    ///     ./scripts/test.sh shots /tmp/shots
    @Test("renders the list")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let now = Date()
        let home = NSHomeDirectory()
        let sessions = [
            telemetry("b1", title: "✳ Post workshop survey", cwd: home + "/code/max-pane", state: .blocked, activity: now),
            telemetry("b2", server: "yorkshire", title: "✳ Add the migration", cwd: "/home/spierce/relay", state: .blocked, activity: now.addingTimeInterval(-40)),
            telemetry("d1", title: "✳ Rewrite the README", cwd: home + "/code/blog", state: .done, activity: now.addingTimeInterval(-600)),
            telemetry("d2", title: "✳ Import history", cwd: home + "/code/max-pane", state: .done, activity: now.addingTimeInterval(-3600)),
        ].map { t in var t = t; if t.relayState == .done { t.doneSince = now }; return t }
        let lanes: [SessionKey: Int] = ["b1": 0, SessionKey(server: "yorkshire", id: "b2"): 3, "d1": 1]
        var open: [Popup] = []
        try AppearanceSheet.render(to: dir, named: "attention-popup") {
            let popup = AttentionPopup(list: AttentionList(sessions: sessions, laneIndex: { lanes[$0] }, now: now))
            popup.move(by: 1)
            open.append(popup)
            let panel = try #require(popup.window)
            panel.setContentSize(AttentionPopup.size(rows: 4))
            return try #require(panel.contentView)
        }
        _ = open
    }
}
