import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// "Green only while an agent is actually working." Measured on the owner's live
/// sessions (2026-09-13): every running session showed a green 181–615 B/s on
/// agents idle for minutes to hours. Three faults, each pinned here — the
/// registry never let a rate fall, `bps1` is a sixty-second average, and
/// relay's own WORKING/idle is wrong in both directions.
@Suite("session status tells the truth")
@MainActor
struct SessionStatusTests {
    /// A session file as pty-host writes it.
    private func file(
        _ id: String, title: String?, agentState: String?, bps1: Double,
        status: String = "running"
    ) -> RelaySessionInfo {
        RelaySessionInfo(
            id: id, command: "claude", args: [], cwd: NSHomeDirectory(), createdAt: 0,
            status: status, cols: 80, rows: 24, pid: 1, title: title,
            lastActivity: 1_000, bps1: bps1, agentState: agentState)
    }

    // MARK: - the derivation table

    @Test("title glyph × relay state: BLOCKED and EXITED win, then the glyph, then relay")
    func derivationTable() {
        let spinner = "◑ IDE file viewer"
        let star = "✳ Post workshop survey"
        let plain = "spierce@mbp:~/code"

        let expected: [(String, AgentState, AgentState)] = [
            (spinner, .idle, .working),
            (spinner, .working, .working),
            (spinner, .blocked, .blocked),
            (spinner, .done, .working),
            (spinner, .exited, .exited),
            (spinner, .unknown, .working),

            (star, .idle, .idle),
            (star, .working, .idle),
            (star, .blocked, .blocked),
            (star, .done, .done),
            (star, .exited, .exited),
            (star, .unknown, .idle),

            (plain, .idle, .idle),
            (plain, .working, .working),
            (plain, .blocked, .blocked),
            (plain, .done, .done),
            (plain, .exited, .exited),
            (plain, .unknown, .unknown),
        ]
        for (title, relay, want) in expected {
            #expect(AgentState.derived(title: title, relay: relay) == want,
                    "\(title) × \(relay)")
        }
    }

    @Test("every quarter of Claude Code's spinner reads as working")
    func everySpinnerFrame() {
        for glyph in ["◐", "◓", "◑", "◒"] {
            #expect(AgentState.derived(title: "\(glyph) task", relay: .idle) == .working)
        }
        // An empty title and a glyph that is not the first character say nothing.
        #expect(AgentState.derived(title: "", relay: .working) == .working)
        #expect(AgentState.derived(title: "build ◑", relay: .idle) == .idle)
    }

    // MARK: - the measured cases

    @Test("a redraw burst on an idle Claude session stays idle and dim")
    func redrawBurstStaysIdle() {
        // What a relaunch does to every session: a reattach repaints, bps1 holds
        // the burst for a minute, and relay files it as WORKING.
        let t = SessionTelemetry(file("burst", title: "✳ Post workshop survey",
                                      agentState: "working", bps1: 615))
        #expect(t.relayState == .working)
        #expect(t.state == .idle)
        #expect(t.badgeText == "idle")
        #expect(!t.badgeIsThroughput)
        #expect(!t.state.hasChip)

        let row = SidebarModel.rows(lanes: [], telemetry: ["burst": t])
            .compactMap { if case .entry(let e) = $0 { return e } else { return nil } }.first!
        #expect(row.badge == "idle")
        #expect(SidebarEntryView.badgeInk(row) == Theme.dimText)
        #expect(row.chip.isEmpty)

        let header = LaneHeaderModel(lane: StubHeaderLane(), telemetry: t)
        #expect(!header.badgeIsThroughput)
        #expect(header.state == .idle)
        #expect(!header.tooltip.contains("B/s"), "no trickle numbers in the tooltip either")
    }

    @Test("a spinner title is working and green even when relay's file says idle (a7ab2d3b)")
    func spinnerBeatsRelayIdle() {
        let t = SessionTelemetry(file("a7ab2d3b", title: "◑ IDE file viewer and editor integration",
                                      agentState: "idle", bps1: 492))
        #expect(t.state == .working)
        #expect(t.badgeText == "492B/s")
        #expect(t.badgeIsThroughput)

        let row = SidebarModel.rows(lanes: [], telemetry: ["a7ab2d3b": t])
            .compactMap { if case .entry(let e) = $0 { return e } else { return nil } }.first!
        #expect(row.chip == "", "WORKING has no chip; the green mark and the rate say it")
        #expect(SidebarEntryView.badgeInk(row) == SidebarInk.flow)
        #expect(LaneHeaderModel(lane: StubHeaderLane(), telemetry: t).badgeIsThroughput)
    }

    @Test("BLOCKED stays BLOCKED whatever the title says, and its rate is not green")
    func blockedWinsOverTheTitle() {
        for title in ["◑ asking permission", "✳ asking permission", "plain"] {
            let t = SessionTelemetry(file("b", title: title, agentState: "blocked", bps1: 300))
            #expect(t.state == .blocked, "\(title)")
            #expect(t.needsAttention)
            #expect(t.badgeText == "idle")
            #expect(!t.badgeIsThroughput)
        }
    }

    @Test("badge text and colour per derived state")
    func badgePerState() {
        for state in [AgentState.blocked, .working, .done, .idle, .unknown, .exited] {
            let t = SessionTelemetry(sessionId: "s", title: "x", state: state, bytesPerSecond: 1740)
            let row = SidebarModel.rows(lanes: [], telemetry: ["s": t])
                .compactMap { if case .entry(let e) = $0 { return e } else { return nil } }.first!
            if state == .working {
                #expect(t.badgeText == "1.7KB/s")
                #expect(SidebarEntryView.badgeInk(row) == SidebarInk.flow)
            } else {
                #expect(t.badgeText == "idle", "\(state)")
                #expect(SidebarEntryView.badgeInk(row) == Theme.dimText, "\(state)")
            }
        }
        // Working with nothing moving has no number to print.
        let still = SessionTelemetry(sessionId: "s", state: .working, bytesPerSecond: 0)
        #expect(still.badgeText == "idle" && !still.badgeIsThroughput)
    }

    // MARK: - the registry

    @Test("adopt lets a rate and a state fall on the very next file")
    func adoptDecays() {
        let registry = SessionRegistry(files: [
            file("s", title: "◑ building", agentState: "working", bps1: 615),
            file("r", title: "htop", agentState: "working", bps1: 900),
        ])
        #expect(registry.telemetry(for: "s")?.state == .working)
        #expect(registry.telemetry(for: "s")?.bytesPerSecond == 615)
        #expect(registry.telemetry(for: "r")?.state == .working)

        registry.adopt([
            file("s", title: "✳ building", agentState: "idle", bps1: 3),
            // No title glyph: relay's own state and rate, falling the same way.
            file("r", title: "htop", agentState: "idle", bps1: 0),
        ])
        let s = registry.telemetry(for: "s")
        #expect(s?.bytesPerSecond == 3, "the larger stale rate was carried forward")
        #expect(s?.relayState == .idle, "the stale state was carried forward")
        // Fell out of WORKING, so it is DONE — ours, see `doneOnFinish` — and
        // not a rate either way.
        #expect(s?.state == .done)
        #expect(s?.badgeIsThroughput == false)
        let r = registry.telemetry(for: "r")
        #expect(r?.bytesPerSecond == 0)
        #expect(r?.state == .done)
    }

    // MARK: - DONE is ours

    /// pty-host's DONE exists only while no client is attached, and a lane is
    /// a client, so for a session on the strip the file goes WORKING → idle
    /// with nothing between. The registry has to notice the finish itself.
    @Test("WORKING then idle is DONE, and stays DONE while the file keeps saying idle")
    func doneOnFinish() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let registry = SessionRegistry(files: [file("s", title: "◑ building", agentState: "working", bps1: 615)])
        var seen: [(AgentState, AgentState)] = []
        registry.onStateChange = { _, from, to in seen.append((from, to)) }

        registry.adopt([file("s", title: "✳ building", agentState: "idle", bps1: 3)], now: t0)
        #expect(registry.telemetry(for: "s")?.state == .done)
        #expect(registry.telemetry(for: "s")?.doneSince == t0)
        #expect(registry.doneCount == 1)
        #expect(seen.map(\.1) == [.done])

        // Five seconds later the file is unchanged — so is the verdict.
        registry.adopt([file("s", title: "✳ building", agentState: "idle", bps1: 0)], now: t0 + 5)
        #expect(registry.telemetry(for: "s")?.state == .done)
        #expect(registry.telemetry(for: "s")?.doneSince == t0, "the start is when it finished, not the last poll")
        #expect(seen.count == 1, "no change, no event")
    }

    @Test("idle that was never WORKING is just idle")
    func idleFromTheStartIsNotDone() {
        let registry = SessionRegistry(files: [file("s", title: "✳ waiting", agentState: "idle", bps1: 0)])
        registry.adopt([file("s", title: "✳ waiting", agentState: "idle", bps1: 0)])
        #expect(registry.telemetry(for: "s")?.state == .idle)
        #expect(registry.doneCount == 0)
    }

    @Test("focusing the pane clears DONE; working, blocked or exiting clears it without a hold")
    func doneClears() {
        func finished() -> SessionRegistry {
            let r = SessionRegistry(files: [file("s", title: "◑ b", agentState: "working", bps1: 9)])
            r.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)])
            #expect(r.telemetry(for: "s")?.state == .done)
            return r
        }
        let looked = finished()
        looked.acknowledge("s")
        #expect(looked.telemetry(for: "s")?.state == .idle)
        #expect(looked.telemetry(for: "s")?.doneSince == nil)
        // A second look is a no-op, and looking at a session that is not DONE
        // changes nothing.
        looked.acknowledge("s")
        looked.acknowledge("nobody")
        #expect(looked.telemetry(for: "s")?.state == .idle)

        let working = finished()
        working.adopt([file("s", title: "◑ b", agentState: "working", bps1: 400)])
        #expect(working.telemetry(for: "s")?.state == .working)
        // ...and finishing again is DONE again.
        working.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)])
        #expect(working.telemetry(for: "s")?.state == .done)

        let blocked = finished()
        blocked.adopt([file("s", title: "✳ b", agentState: "blocked", bps1: 0)])
        #expect(blocked.telemetry(for: "s")?.state == .blocked)
        blocked.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)])
        #expect(blocked.telemetry(for: "s")?.state == .idle, "answering a prompt is not a finish")

        let exited = finished()
        exited.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0, status: "exited")])
        #expect(exited.telemetry(for: "s")?.state == .exited)
    }

    @Test("DONE lapses to idle after the hold, and never with a hold of zero")
    func doneLapses() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let registry = SessionRegistry(files: [file("s", title: "◑ b", agentState: "working", bps1: 9)])
        registry.doneHold = 600
        registry.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)], now: t0)
        var seen: [AgentState] = []
        registry.onStateChange = { _, _, to in seen.append(to) }

        #expect(registry.lapseDone(now: t0 + 599) == false)
        #expect(registry.telemetry(for: "s")?.state == .done)
        #expect(registry.lapseDone(now: t0 + 600) == true)
        #expect(registry.telemetry(for: "s")?.state == .idle)
        #expect(seen == [.idle])
        #expect(registry.lapseDone(now: t0 + 601) == false, "nothing left to lapse")

        let held = SessionRegistry(files: [file("s", title: "◑ b", agentState: "working", bps1: 9)])
        held.doneHold = 0
        held.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)], now: t0)
        #expect(held.lapseDone(now: t0 + 86_400 * 30) == false)
        #expect(held.telemetry(for: "s")?.state == .done)
    }

    @Test("pty-host's own DONE, for a session with no lane, lapses on the same hold")
    func relayDoneLapsesToo() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let registry = SessionRegistry(files: [])
        registry.doneHold = 60
        registry.adopt([file("s", title: "✳ b", agentState: "done", bps1: 0)], now: t0)
        #expect(registry.telemetry(for: "s")?.state == .done)
        registry.lapseDone(now: t0 + 60)
        #expect(registry.telemetry(for: "s")?.state == .idle, "the file still says done; the hold wins")
    }

    // MARK: - motion

    @Test("the sidebar fades when a row's status changes, and not on an age tick")
    func sidebarFadesOnlyOnStatus() {
        func rows(_ state: AgentState, bps: Double, age: TimeInterval) -> [SidebarModel.Row] {
            let t = SessionTelemetry(sessionId: "s", title: "x", cwd: NSHomeDirectory(),
                                     state: state, bytesPerSecond: bps,
                                     lastActivity: Date(timeIntervalSince1970: age))
            return SidebarModel.rows(lanes: [], telemetry: ["s": t])
        }
        let working = rows(.working, bps: 500, age: 10)
        #expect(SidebarModel.statusChanged(from: working, to: rows(.idle, bps: 0, age: 10)))
        #expect(SidebarModel.statusChanged(from: working, to: rows(.working, bps: 0, age: 10)))
        #expect(!SidebarModel.statusChanged(from: working, to: rows(.working, bps: 700, age: 20)))
        #expect(!SidebarModel.statusChanged(from: [], to: working), "a new row is not a change")
    }
}

private struct StubHeaderLane: LaneHeaderSource {
    var kind: PaneGlyph = .pty
    var title: String? = nil
    var host: String? = nil
    var projectRoot: String? = nil
    var keepLive = false
    var dock: Dock? = nil
    var hasRelaySession = true
    var hasLivePane = true
}

/// Every state a sidebar row can be in, drawn in light and dark, because
/// "green only while working" is a claim about colour that an assertion on
/// `NSColor` equality only half makes. Gated on `MAXPANE_SHOTS`.
@Suite("session status rendering")
@MainActor
struct SessionStatusRenderTests {
    @Test("renders a sidebar row in every derived state")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let home = NSHomeDirectory()
        let now = Date().timeIntervalSince1970
        let cases: [(String, String, AgentState, Double, Bool)] = [
            ("1", "◑ working, relay agrees", .working, 1740, true),
            ("2", "◑ working, relay said idle", .idle, 492, true),
            ("3", "✳ redraw burst, relay said working", .working, 615, true),
            ("4", "✳ idle for hours", .idle, 0, true),
            ("5", "◑ blocked on a prompt", .blocked, 120, true),
            ("6", "✳ done while unwatched", .done, 0, true),
            ("7", "zsh, nothing known", .unknown, 40, true),
            ("8", "✳ exited", .exited, 0, false),
        ]
        var telemetry: [String: SessionTelemetry] = [:]
        for (id, title, relay, bps, running) in cases {
            telemetry[id] = SessionTelemetry(
                sessionId: id, title: title, cwd: home, command: "claude", state: relay,
                bytesPerSecond: bps, lastActivity: Date(timeIntervalSince1970: now - 30),
                isRunning: running)
        }
        let entries = SidebarModel.rows(lanes: [], telemetry: telemetry)
            .compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
            .sorted { $0.sessionId ?? "" < $1.sessionId ?? "" }

        let width: CGFloat = 290
        try AppearanceSheet.render(to: dir, named: "session-status") {
            let height = SidebarEntryView.height * CGFloat(entries.count) + 8
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            var y = height - 4
            for entry in entries {
                let view = SidebarEntryView(entry: entry)
                y -= SidebarEntryView.height
                view.frame = NSRect(x: 0, y: y, width: width, height: SidebarEntryView.height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            return sheet
        }
    }
}
