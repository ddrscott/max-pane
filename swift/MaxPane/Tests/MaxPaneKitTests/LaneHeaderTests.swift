import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// The lane header is the only chrome a pane has, so what it decides to drop
/// when it runs out of room *is* the feature. These lock the decisions down.
@Suite("lane header path fitting")
struct LaneHeaderPathTests {
    private let home = NSHomeDirectory()

    @Test("a path that fits is printed whole, with $HOME abbreviated")
    func fitsWhole() {
        #expect(LaneHeaderPath.fit(home + "/code/max-pane", maxChars: 40) == "~/code/max-pane")
        #expect(LaneHeaderPath.fit("/etc/nginx", maxChars: 40) == "/etc/nginx")
        #expect(LaneHeaderPath.fit(home, maxChars: 40) == "~")
    }

    @Test("a trailing slash is never worth a cell")
    func stripsTrailingSlash() {
        #expect(LaneHeaderPath.fit(home + "/code/max-pane/", maxChars: 40) == "~/code/max-pane")
    }

    /// The motivating case from the brief: `/Users/spierce/code/trifecta-discovery`
    /// in a 420pt lane, where the path field is worth roughly 25 characters.
    @Test("the long case sheds leading components, never the tail")
    func shedsLeadingComponents() {
        let path = home + "/code/trifecta-discovery"
        #expect(LaneHeaderPath.fit(path, maxChars: 25) == "~/code/trifecta-discovery")
        #expect(LaneHeaderPath.fit(path, maxChars: 24) == "…/trifecta-discovery")
        #expect(LaneHeaderPath.fit(path, maxChars: 20) == "…/trifecta-discovery")
    }

    @Test("below one component it head-truncates, because the tail identifies it")
    func headTruncatesTheLastComponent() {
        let path = home + "/code/trifecta-discovery"
        #expect(LaneHeaderPath.fit(path, maxChars: 19) == "…trifecta-discovery")
        #expect(LaneHeaderPath.fit(path, maxChars: 10) == "…discovery")
        // The two sibling checkouts stay distinguishable at ten characters,
        // which is the whole reason this end is the one that survives.
        #expect(LaneHeaderPath.fit(home + "/code/trifecta-artifacts", maxChars: 10) == "…artifacts")
    }

    @Test("a hopeless width says nothing rather than something false")
    func degradesToNothing() {
        let path = home + "/code/trifecta-discovery"
        #expect(LaneHeaderPath.fit(path, maxChars: 1) == "…")
        #expect(LaneHeaderPath.fit(path, maxChars: 0) == "")
        #expect(LaneHeaderPath.fit("", maxChars: 40) == "")
    }

    @Test("a deep path keeps as many trailing components as fit")
    func keepsAsManyComponentsAsFit() {
        let path = NSHomeDirectory() + "/code/max-pane/swift/MaxPane/Sources"
        #expect(LaneHeaderPath.fit(path, maxChars: 37) == "~/code/max-pane/swift/MaxPane/Sources")
        #expect(LaneHeaderPath.fit(path, maxChars: 36) == "…/max-pane/swift/MaxPane/Sources")
        #expect(LaneHeaderPath.fit(path, maxChars: 25) == "…/swift/MaxPane/Sources")
        #expect(LaneHeaderPath.fit(path, maxChars: 15) == "…/Sources")
    }

    @Test("the result never exceeds the budget it was given", arguments: 1...45)
    func neverOverflows(_ width: Int) {
        for path in [
            NSHomeDirectory() + "/code/trifecta-discovery",
            NSHomeDirectory(),
            "/",
            "/usr/local/share/some-very-long-directory-name-indeed",
            "relative/path/without/a/root",
        ] {
            let fitted = LaneHeaderPath.fit(path, maxChars: width)
            #expect(fitted.count <= width, "\(path) at \(width) produced \(fitted)")
        }
    }
}

/// A lane stands in for the ledger snapshot here: the model's job is choosing
/// between sources that disagree, and that choice does not need a database.
private struct StubLane: LaneHeaderSource {
    var kind: PaneGlyph = .pty
    var title: String?
    var host: String?
    var projectRoot: String?
    var keepLive = false
    var dock: Dock?
    var hasLivePane = false
    var hasRelaySession = false
}

@Suite("lane header model")
struct LaneHeaderModelTests {
    /// The header's one spare column carries both structural facts about a
    /// lane. They have to stay legible together, and the dock's mode has to be
    /// readable without a colour — the greens are spent elsewhere.
    @Test("the markers say which edge, at whose expense, and whether it is kept")
    func markerGlyphs() {
        func marker(_ dock: Dock?, keepLive: Bool = false) -> String {
            LaneHeaderModel(
                lane: StubLane(keepLive: keepLive, dock: dock), telemetry: nil).markerText
        }
        #expect(marker(nil) == "")
        #expect(marker(nil, keepLive: true) == "▪")
        // Filled takes room out of the strip; hollow floats over it.
        #expect(marker(Dock(side: .left, mode: .inset, widthPt: 320)) == "◀")
        #expect(marker(Dock(side: .left, mode: .overlay, widthPt: 320)) == "◁")
        #expect(marker(Dock(side: .right, mode: .inset, widthPt: 320)) == "▶")
        #expect(marker(Dock(side: .right, mode: .overlay, widthPt: 320)) == "▷")
        // Both facts at once: docking does not set `keepLive` and does not
        // hide it (ADR-0010 — protection is derived from the dock, never
        // written beside it).
        #expect(marker(Dock(side: .right, mode: .inset, widthPt: 320), keepLive: true) == "▶▪")
    }

    /// A window too narrow for an inset dock floats it instead
    /// (`DockGeometry`). The header has to follow the screen, not the
    /// preference — a filled marker beside a dock that is visibly covering a
    /// lane is the header arguing with the window.
    @Test("the marker follows the mode the window can afford, not the stored one")
    func markerFollowsTheDrawnMode() {
        let model = LaneHeaderModel(
            lane: StubLane(dock: Dock(side: .left, mode: .inset, widthPt: 560)), telemetry: nil)
        #expect(model.markerText == "◀")
        #expect(model.markerText(drawnMode: .overlay) == "◁")
        // And a lane that is not docked has no marker to degrade.
        let plain = LaneHeaderModel(lane: StubLane(), telemetry: nil)
        #expect(plain.markerText(drawnMode: .overlay) == "")
    }

    @Test("the ledger's title wins, then the session's, then the host")
    func titlePrecedence() {
        let session = SessionTelemetry(sessionId: "s", title: "session name")
        #expect(LaneHeaderModel(
            lane: StubLane(title: "ledger name", host: "example.com"),
            telemetry: session).title == "ledger name")
        #expect(LaneHeaderModel(
            lane: StubLane(title: nil, host: "example.com"),
            telemetry: session).title == "session name")
        #expect(LaneHeaderModel(
            lane: StubLane(kind: .web, title: nil, host: "example.com"),
            telemetry: nil).title == "example.com")
        #expect(LaneHeaderModel(
            lane: StubLane(title: nil, host: nil),
            telemetry: SessionTelemetry(sessionId: "s", command: "htop")).title == "htop")
        #expect(LaneHeaderModel(lane: StubLane(), telemetry: nil).title == "untitled")
    }

    @Test("a session Relay has no opinion about spends no column saying so")
    func quietStatesCarryNoChip() {
        for quiet in [AgentState.unknown, .idle] {
            let model = LaneHeaderModel(
                lane: StubLane(), telemetry: SessionTelemetry(sessionId: "s", state: quiet))
            #expect(model.state == quiet)
            #expect(!(model.state?.hasChip ?? false))
        }
        let blocked = LaneHeaderModel(
            lane: StubLane(), telemetry: SessionTelemetry(sessionId: "s", state: .blocked))
        #expect(blocked.state?.chipText == "BLOCKED")
    }

    @Test("blocked is a state the header must never lose to the badge")
    func blockedSurvivesAQuietSession() {
        // Blocked and silent is the normal case: the agent printed its prompt
        // and stopped, so there is no throughput to notice it by.
        let waiting = SessionTelemetry(
            sessionId: "s", state: .blocked, bytesPerSecond: 0,
            lastActivity: Date().addingTimeInterval(-90))
        let model = LaneHeaderModel(lane: StubLane(), telemetry: waiting)
        #expect(model.state == .blocked)
        #expect(model.badge == "1m")
    }

    @Test("the session's cwd beats the project tag, because it follows cd")
    func cwdWins() {
        let session = SessionTelemetry(sessionId: "s", cwd: "/tmp/inner")
        #expect(LaneHeaderModel(
            lane: StubLane(projectRoot: "/tmp"), telemetry: session).path == "/tmp/inner")
        #expect(LaneHeaderModel(
            lane: StubLane(projectRoot: "/tmp"), telemetry: nil).path == "/tmp")
    }

    @Test("the badge shows throughput while moving and quiet-for how long otherwise")
    func badgeSwitches() {
        let moving = SessionTelemetry(
            sessionId: "s", state: .working, bytesPerSecond: 1740,
            lastActivity: Date().addingTimeInterval(-2))
        let model = LaneHeaderModel(lane: StubLane(), telemetry: moving)
        #expect(model.badge == "1.7KB/s")
        #expect(model.badgeIsThroughput)
        #expect(model.state == .working)

        let quiet = SessionTelemetry(
            sessionId: "s", state: .idle, bytesPerSecond: 0,
            lastActivity: Date().addingTimeInterval(-13 * 3600))
        let idle = LaneHeaderModel(lane: StubLane(), telemetry: quiet)
        // "13h ago" minus the three characters that are not information.
        #expect(idle.badge == "13h")
        #expect(!idle.badgeIsThroughput)
        #expect(idle.state == .idle)
    }

    @Test("liveness comes from the session, or from the pane when there is none")
    func liveness() {
        let dead = SessionTelemetry(sessionId: "s", state: .exited, isRunning: false)
        #expect(!LaneHeaderModel(lane: StubLane(hasLivePane: true), telemetry: dead).isLive)
        #expect(LaneHeaderModel(
            lane: StubLane(kind: .web, hasLivePane: true), telemetry: nil).isLive)
        #expect(!LaneHeaderModel(
            lane: StubLane(kind: .web, hasLivePane: false), telemetry: nil).isLive)
        // A lane still holding a session id Relay no longer lists: gone, and the
        // pane view being alive does not get a vote.
        let orphan = LaneHeaderModel(
            lane: StubLane(hasLivePane: true, hasRelaySession: true), telemetry: nil)
        #expect(!orphan.isLive)
        #expect(orphan.state == .exited)
    }

    @Test("the tip keeps the whole path the header had to truncate")
    func tooltipKeepsEverything() {
        let session = SessionTelemetry(
            sessionId: "s", title: "Latest commit changes",
            cwd: "/Users/someone/code/trifecta-discovery", command: "claude",
            state: .idle, lastActivity: Date().addingTimeInterval(-60))
        let model = LaneHeaderModel(lane: StubLane(), telemetry: session)
        #expect(model.tooltip.contains("/Users/someone/code/trifecta-discovery"))
        #expect(model.tooltip.contains("claude"))
    }
}

/// Rendering the header offscreen, which is the only way to look at it while the
/// machine's screen is locked — `screencapture` returns black then, but a view
/// drawing into a bitmap does not care.
///
/// Skipped unless `MAXPANE_SHOTS` names a directory, so it stays a development
/// tool rather than a test that writes files in CI. One variable for every
/// render sheet, so `./scripts/test.sh shots DIR` gets all of them at once.
@Suite("lane header rendering")
@MainActor
struct LaneHeaderRenderTests {
    @Test("renders at the widths that matter")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        // The pair that has to be distinguishable at a glance is the first
        // two: a blocked lane nobody is looking at, and a focused lane with
        // nothing to say. Both are green somewhere (ADR-0015), so the sheet
        // also has each state focused and not.
        let cases: [(String, Lane, SessionTelemetry?, Bool)] = [
            ("blocked-focused", lane(title: "Latest commit changes",
                                     root: "/Users/spierce/code/trifecta-discovery"),
             SessionTelemetry(sessionId: "a", title: "Latest commit changes",
                              cwd: "/Users/spierce/code/trifecta-discovery", command: "claude",
                              state: .blocked,
                              lastActivity: Date().addingTimeInterval(-90)), true),
            ("working-focused", lane(title: "trifecta ask", root: "/Users/spierce/code/trifecta-discovery"),
             SessionTelemetry(sessionId: "c", cwd: "/Users/spierce/code/trifecta-discovery",
                              command: "claude", state: .working, bytesPerSecond: 1740,
                              lastActivity: Date()), true),
            ("blocked-unfocused", lane(title: "Latest commit changes",
                                       root: "/Users/spierce/code/trifecta-discovery"),
             SessionTelemetry(sessionId: "a", title: "Latest commit changes",
                              cwd: "/Users/spierce/code/trifecta-discovery", command: "claude",
                              state: .blocked,
                              lastActivity: Date().addingTimeInterval(-90)), false),
            ("focused-idle", lane(title: "SSH tunnelling setup for 192.168.68.10",
                                  root: "/Users/spierce/life"),
             SessionTelemetry(sessionId: "b", title: "", cwd: "/Users/spierce/life",
                              state: .idle, lastActivity: Date().addingTimeInterval(-13 * 3600)),
             true),
            ("working", lane(title: "trifecta ask", root: "/Users/spierce/code/trifecta-discovery"),
             SessionTelemetry(sessionId: "c", cwd: "/Users/spierce/code/trifecta-discovery",
                              command: "claude", state: .working, bytesPerSecond: 1740,
                              lastActivity: Date()), false),
            ("done-pinned", lane(title: "htop", root: "/Users/spierce", pinned: true),
             SessionTelemetry(sessionId: "d", cwd: "/Users/spierce", state: .done,
                              lastActivity: Date().addingTimeInterval(-6)), false),
            ("exited", lane(title: "trifecta monitor", root: "/Users/spierce/code/trifecta-discovery"),
             SessionTelemetry(sessionId: "e", cwd: "/Users/spierce/code/trifecta-discovery",
                              state: .exited, lastActivity: Date().addingTimeInterval(-3 * 86_400),
                              isRunning: false), false),
            ("web-lane", webLane(), nil, false),
        ]

        for width in [420.0, 620.0, 900.0] as [CGFloat] {
            try AppearanceSheet.render(to: dir, named: "header-\(Int(width))") {
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(cases.count) * 40))
                sheet.wantsLayer = true
                sheet.layerBackgroundColor = Theme.laneBackground
                for (index, item) in cases.enumerated() {
                    let header = LaneHeaderView()
                    header.frame = NSRect(
                        x: 0, y: CGFloat(cases.count - index - 1) * 40 + 6,
                        width: width, height: Theme.laneHeaderHeight)
                    header.apply(item.1)
                    header.telemetry = item.2
                    header.isFocused = item.3
                    sheet.addSubview(header)
                    header.layoutSubtreeIfNeeded()
                    header.layout()
                }
                return sheet
            }
        }
    }

    private func lane(title: String, root: String, pinned: Bool = false) -> Lane {
        Lane(id: "l", ordinal: 1, widthPt: 420, title: title, projectRoot: root,
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: pinned, dock: nil, span: 1,
             panes: [Pane(id: "p", laneId: "l", position: 0, kind: .pty,
                          relaySessionId: "a", relayServer: nil, url: nil, scrollY: nil, dataStoreId: nil,
                          snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)])
    }

    private func webLane() -> Lane {
        Lane(id: "w", ordinal: 2, widthPt: 420, title: nil, projectRoot: nil,
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1,
             panes: [Pane(id: "wp", laneId: "w", position: 0, kind: .web,
                          relaySessionId: nil, relayServer: nil, url: "https://google.com", scrollY: nil,
                          dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)])
    }
}
