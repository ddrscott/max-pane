import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

// A folded sidebar header rolls up the activity of the rows it hides
// (ADR-0024, amended): BLOCKED, DONE and WORKING each as their own segment in
// front of the grey count, the triangle in the brightest of them, and a click
// on BLOCKED or DONE going to that session.

private let home = NSHomeDirectory()

private func telemetry(
    _ id: String, server: String? = nil, cwd: String, state: AgentState = .idle, created: Double = 0
) -> SessionTelemetry {
    SessionTelemetry(
        sessionId: id, server: server, title: id, cwd: cwd, command: "claude", state: state,
        bytesPerSecond: state == .working ? 900 : 0, lastActivity: Date(timeIntervalSince1970: created))
}

private func pane(_ id: String, lane: String, session: String, server: String? = nil) -> Pane {
    Pane(id: id, laneId: lane, position: 0, kind: .pty,
         relaySessionId: session, relayServer: server, url: nil, scrollY: nil, dataStoreId: nil,
         snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)
}

private func lane(_ id: String, tag: String? = nil, panes: [Pane]) -> Lane {
    Lane(id: id, ordinal: 1, widthPt: 500, title: nil, projectRoot: tag, projectSource: .cwd,
         createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1, isPrivate: false, panes: panes)
}

private func groups(_ rows: [SidebarModel.Row]) -> [SidebarModel.Group] {
    rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
}

// MARK: - the model

@Suite("what a folded sidebar header says about what is under it")
struct FoldedHeaderModelTests {
    // ~/life: one blocked, two done, one working, one idle. Two of them have
    // lanes; the others are sessions not on the strip.
    private let life: [SessionKey: SessionTelemetry] = [
        "b1": telemetry("b1", cwd: home + "/life", state: .blocked, created: 10),
        "d1": telemetry("d1", cwd: home + "/life", state: .done, created: 20),
        "d2": telemetry("d2", cwd: home + "/life", state: .done, created: 30),
        "w1": telemetry("w1", cwd: home + "/life", state: .working, created: 40),
        "i1": telemetry("i1", cwd: home + "/life", state: .idle, created: 50),
    ]
    private let lanes: [Lane] = [
        lane("L-d2", tag: home + "/life", panes: [pane("p-d2", lane: "L-d2", session: "d2")]),
        lane("L-w1", tag: home + "/life", panes: [pane("p-w1", lane: "L-w1", session: "w1")]),
    ]

    private func folded(_ t: [SessionKey: SessionTelemetry], _ paths: Set<String>, hidden: Set<String> = [],
                        servers: [String: ServerState] = [:]) -> [SidebarModel.Group] {
        var controls = SidebarModel.Controls()
        controls.collapsed = paths
        return groups(SidebarModel.rows(lanes: lanes, telemetry: t, controls: controls, servers: servers, hiddenLanes: hidden))
    }

    @Test("open, the header says what it always said; folded, every state under it rolls up, loudest first")
    func rollUp() {
        let open = folded(life, []).first { $0.path == "~/life" }!
        #expect(open.rollUpText == "1 BLOCKED")
        #expect(open.countText == "1 BLOCKED" && open.blockedText == nil && open.doneText == nil && open.workingText == nil)
        #expect(open.markState == nil)

        let fold = folded(life, ["~/life"], hidden: ["L-d2", "L-w1"]).first { $0.path == "~/life" }!
        #expect(fold.rollUpText == "1 BLOCKED · 2 DONE · 1 WORKING · 2 LANES HIDDEN")
        #expect(fold.rollUp.map(\.state) == [.blocked, .done, .working, nil])
        #expect(fold.blockedText == "1 BLOCKED" && fold.doneText == "2 DONE" && fold.workingText == "1 WORKING")
        #expect(fold.countText == "2 LANES HIDDEN")
        #expect(fold.markState == .blocked)
    }

    @Test("each state on its own: DONE in front of the count, WORKING in front of the count, idle is the count alone")
    func eachAlone() {
        var only = life
        only["b1"] = telemetry("b1", cwd: home + "/life", state: .idle)
        only["w1"] = telemetry("w1", cwd: home + "/life", state: .idle)
        let done = folded(only, ["~/life"], hidden: ["L-d2", "L-w1"]).first { $0.path == "~/life" }!
        #expect(done.rollUpText == "2 DONE · 2 LANES HIDDEN" && done.markState == .done)

        only["d1"] = telemetry("d1", cwd: home + "/life", state: .idle)
        only["d2"] = telemetry("d2", cwd: home + "/life", state: .idle)
        only["w1"] = telemetry("w1", cwd: home + "/life", state: .working)
        let working = folded(only, ["~/life"], hidden: ["L-d2", "L-w1"]).first { $0.path == "~/life" }!
        #expect(working.rollUpText == "1 WORKING · 2 LANES HIDDEN" && working.markState == .working)

        only["w1"] = telemetry("w1", cwd: home + "/life", state: .idle)
        let idle = folded(only, ["~/life"], hidden: ["L-d2", "L-w1"]).first { $0.path == "~/life" }!
        #expect(idle.rollUpText == "2 LANES HIDDEN" && idle.markState == nil)
        // With the setting off nothing is hidden, and the tail is the count.
        let unhidden = folded(only, ["~/life"]).first { $0.path == "~/life" }!
        #expect(unhidden.rollUpText == "5 RUNNING" && unhidden.markState == nil)
    }

    @Test("a section rolls up every project under it: // LOCAL and a server's header alike")
    func sections() {
        var t = life
        t[SessionKey(server: "wsl", id: "r1")] = telemetry("r1", server: "wsl", cwd: "/home/a", state: .done)
        t[SessionKey(server: "wsl", id: "r2")] = telemetry("r2", server: "wsl", cwd: "/home/b", state: .working)
        t["m1"] = telemetry("m1", cwd: home + "/code", state: .working)
        let servers: [String: ServerState] = ["wsl": .connected]
        let folds = folded(t, [SidebarModel.localSection, "wsl:"], servers: servers)
        let local = folds.first { $0.isLocalSection }!
        #expect(local.rollUpText == "1 BLOCKED · 2 DONE · 2 WORKING · 6 SESSIONS")
        #expect(local.markState == .blocked)
        let wsl = folds.first { $0.path == "wsl:" }!
        #expect(wsl.rollUpText == "1 DONE · 1 WORKING · 2 SESSIONS")
        #expect(wsl.markState == .done)
        // Open, a section's line is what it was.
        let open = folded(t, [], servers: servers)
        #expect(open.first { $0.isLocalSection }!.rollUpText == "1 BLOCKED")
        #expect(open.first { $0.path == "wsl:" }!.rollUpText == "2 SESSIONS")
    }

    @Test("a click target: the first BLOCKED and the first DONE under the fold, in the rows' own order, lane or session")
    func targets() {
        let fold = folded(life, ["~/life"], hidden: ["L-d2", "L-w1"]).first { $0.path == "~/life" }!
        // b1 has no lane: the click attaches it.
        #expect(fold.blockedTarget == SidebarModel.Target(laneId: nil, paneId: nil, sessionKey: "b1"))
        // Created, descending: d2 (30) comes before d1 (20), and d2 has a lane.
        #expect(fold.doneTarget == SidebarModel.Target(laneId: "L-d2", paneId: "p-d2", sessionKey: "d2"))
        // Open, there is nothing to click.
        let open = folded(life, []).first { $0.path == "~/life" }!
        #expect(open.blockedTarget == nil && open.doneTarget == nil)
        // A section's target is the first across its projects.
        var t = life
        t["m1"] = telemetry("m1", cwd: home + "/code", state: .done, created: 99)
        let local = folded(t, [SidebarModel.localSection], servers: ["wsl": .connected]).first { $0.isLocalSection }!
        #expect(local.doneTarget?.sessionKey == "m1", "~/code sorts before ~/life")
    }

    @Test("a DONE that is acknowledged clears from the fold, the way it clears from a row")
    @MainActor
    func doneClears() {
        func file(_ id: String, title: String, agentState: String, bps1: Double) -> RelaySessionInfo {
            RelaySessionInfo(
                id: id, command: "claude", args: [], cwd: home + "/life", createdAt: 0,
                status: "running", cols: 80, rows: 24, pid: 1, title: title,
                lastActivity: 1_000, bps1: bps1, agentState: agentState)
        }
        let registry = SessionRegistry(files: [file("s", title: "◑ b", agentState: "working", bps1: 9)])
        registry.adopt([file("s", title: "✳ b", agentState: "idle", bps1: 0)])
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let before = groups(SidebarModel.rows(lanes: [], telemetry: registry.sessions, controls: controls)).first!
        #expect(before.rollUpText == "1 DONE · 1 RUNNING" && before.markState == .done)
        registry.acknowledge("s")
        let after = groups(SidebarModel.rows(lanes: [], telemetry: registry.sessions, controls: controls)).first!
        #expect(after.rollUpText == "1 RUNNING" && after.markState == nil && after.doneTarget == nil)
    }

    @Test("a state appearing on or clearing from a fold is a change the table fades for")
    func fadeOnChange() {
        let calm = SidebarModel.rows(lanes: lanes, telemetry: ["i1": life["i1"]!], controls: {
            var c = SidebarModel.Controls(); c.collapsed = ["~/life"]; return c
        }())
        let loud = SidebarModel.rows(lanes: lanes, telemetry: ["i1": life["i1"]!, "d1": life["d1"]!], controls: {
            var c = SidebarModel.Controls(); c.collapsed = ["~/life"]; return c
        }())
        #expect(SidebarModel.statusChanged(from: calm, to: loud))
        #expect(SidebarModel.statusChanged(from: loud, to: calm))
        #expect(!SidebarModel.statusChanged(from: loud, to: loud))
    }
}

// MARK: - the header as drawn

@Suite("the folded header as drawn")
@MainActor
struct FoldedHeaderViewTests {
    private func group(blocked: Int = 0, done: Int = 0, working: Int = 0, hidden: Int = 3, collapsed: Bool = true)
        -> SidebarModel.Group {
        var g = SidebarModel.Group(
            path: "~/code/max-pane", running: 4, blocked: blocked, total: 4, collapsed: collapsed,
            countOverride: nil, serverState: nil, hiddenLanes: hidden)
        g.done = done
        g.working = working
        return g
    }

    private func host(_ view: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: width, height: 26), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 26)
        window.contentView?.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test("every segment in its colour: BLOCKED breathing, DONE orange, WORKING green, the count grey; the triangle takes the brightest")
    func segments() {
        BlockedPulse.isReduced = { false }
        defer { BlockedPulse.isReduced = { Motion.isReduced } }
        let mixed = SidebarGroupView(group: group(blocked: 1, done: 2, working: 1))
        let window = host(mixed, width: 360)
        defer { window.close() }
        #expect(mixed.shownRollUp == ["1 BLOCKED", "2 DONE", "1 WORKING", "3 LANES HIDDEN"])
        #expect(mixed.isBlockedPulsing && mixed.isMarkPulsing)
        #expect(mixed.markColour == Theme.blocked)

        let done = SidebarGroupView(group: group(done: 1))
        #expect(done.shownRollUp == ["1 DONE", "3 LANES HIDDEN"])
        #expect(!done.isBlockedPulsing && !done.isMarkPulsing && done.markColour == Theme.done)

        let working = SidebarGroupView(group: group(working: 2))
        #expect(working.shownRollUp == ["2 WORKING", "3 LANES HIDDEN"])
        #expect(working.markColour == Theme.working)

        let idle = SidebarGroupView(group: group())
        #expect(idle.shownRollUp == ["3 LANES HIDDEN"] && idle.markColour == Theme.dimText)

        // Open, with a blocked row on show: the count is the alarm, as it was,
        // and the triangle stays grey because the row underneath is the mark.
        let open = SidebarGroupView(group: group(blocked: 1, hidden: 0, collapsed: false))
        #expect(open.countText == "1 BLOCKED" && open.isBlockedPulsing && open.markColour == Theme.dimText)
    }

    @Test("short of room, the grey tail goes first and the states stay")
    func tailDropsFirst() {
        let wide = SidebarGroupView(group: group(blocked: 1, done: 2))
        let w1 = host(wide, width: 320)
        defer { w1.close() }
        #expect(wide.shownRollUp == ["1 BLOCKED", "2 DONE", "3 LANES HIDDEN"])

        let narrow = SidebarGroupView(group: group(blocked: 1, done: 2))
        let w2 = host(narrow, width: 200)
        defer { w2.close() }
        #expect(narrow.shownRollUp == ["1 BLOCKED", "2 DONE"])

        // Narrower still, the quietest state goes next; BLOCKED never does.
        let mixed = SidebarGroupView(group: group(blocked: 1, done: 2, working: 1))
        let w4 = host(mixed, width: 200)
        defer { w4.close() }
        #expect(mixed.shownRollUp == ["1 BLOCKED", "2 DONE"])
        let tiny = SidebarGroupView(group: group(blocked: 1, done: 2, working: 1))
        let w5 = host(tiny, width: 130)
        defer { w5.close() }
        #expect(tiny.shownRollUp == ["1 BLOCKED"])

        // With nothing in front of it the count is all there is, and stays.
        let alone = SidebarGroupView(group: group())
        let w3 = host(alone, width: 120)
        defer { w3.close() }
        #expect(alone.shownRollUp == ["3 LANES HIDDEN"])
    }

    @Test("a point on BLOCKED or DONE is that state; anywhere else is the fold")
    func hits() {
        let view = SidebarGroupView(group: group(blocked: 1, done: 2))
        let window = host(view, width: 320)
        defer { window.close() }
        // Walk the row: the state text is at the right, the path at the left.
        var seen: [SidebarGroupView.StateHit?] = []
        for x in stride(from: 4.0, to: 320.0, by: 4) {
            let hit = view.stateHit(at: NSPoint(x: x, y: 13))
            if seen.last != hit { seen.append(hit) }
        }
        #expect(seen == [nil, .blocked, .done, nil], "\(seen)")
        // The tail and an open header are never a target.
        let open = SidebarGroupView(group: group(blocked: 1, hidden: 0, collapsed: false))
        let w2 = host(open, width: 320)
        defer { w2.close() }
        #expect((0..<80).allSatisfy { open.stateHit(at: NSPoint(x: CGFloat($0) * 4, y: 13)) == nil })
    }
}

// MARK: - render sheet

@Suite("folded header rendering")
@MainActor
struct FoldedHeaderRenderTests {
    @Test("renders a folded header in each state, mixed, on a section, with a speaker, and cramped")
    func sheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED: set MAXPANE_SHOTS=<dir> to render the folded header sheet")
            return
        }
        BlockedPulse.isReduced = { true }
        defer { BlockedPulse.isReduced = { Motion.isReduced } }
        func g(_ path: String, blocked: Int = 0, done: Int = 0, working: Int = 0, hidden: Int = 3,
               total: Int = 4, audible: [String] = [], server: ServerState? = nil, collapsed: Bool = true) -> SidebarModel.Group {
            var g = SidebarModel.Group(
                path: path, running: total, blocked: blocked, total: total, collapsed: collapsed,
                countOverride: nil, serverState: server, hiddenLanes: hidden, audibleLanes: audible)
            g.done = done
            g.working = working
            return g
        }
        let cases: [SidebarModel.Group] = [
            g("~/code/max-pane", hidden: 3),
            g("~/code/max-pane", working: 2),
            g("~/code/max-pane", done: 1),
            g("~/code/max-pane", blocked: 1),
            g("~/code/max-pane", blocked: 1, done: 2, working: 1),
            g("~/life", done: 1, working: 1, audible: ["L-1"]),
            g(SidebarModel.localSection, blocked: 1, done: 1, hidden: 0, total: 6),
            g("wsl:", done: 2, working: 1, hidden: 2, total: 3, server: .connected),
            g("wsl:", blocked: 1, hidden: 0, total: 3, server: .reconnecting),
            g("~/code/max-pane", blocked: 1, hidden: 0, collapsed: false),
        ]
        for width in [200.0, 300.0] as [CGFloat] {
            try AppearanceSheet.render(to: dir, named: "folded-header-\(Int(width))") {
                let height = SidebarGroupView.height
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height * CGFloat(cases.count) + 8))
                sheet.wantsLayer = true
                sheet.layerBackgroundColor = Theme.stripBackground
                var y = sheet.bounds.height - 4
                for group in cases {
                    let view = SidebarGroupView(group: group)
                    y -= height
                    view.frame = NSRect(x: 0, y: y, width: width, height: height)
                    sheet.addSubview(view)
                    view.layoutSubtreeIfNeeded()
                }
                return sheet
            }
        }
    }
}
