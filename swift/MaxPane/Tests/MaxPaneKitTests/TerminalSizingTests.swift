import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// ADR-0007: the lane is sized to the session, never the other way round.
///
/// The table below is M2's, measured at 12 pt Menlo (a 7 pt cell). It is here so
/// that a change to the sizing rule has to argue with the measurement rather
/// than just recompiling.
@Suite("lane sized to session")
@MainActor
struct LaneSizingTests {
    private let cell12pt = 7.0

    @Test("real session widths all fit inside the PRD's lane range", arguments: [
        (cols: 52, fits: true),   // the narrowest real session on this machine
        (cols: 73, fits: true),   // a Claude Code session
        (cols: 100, fits: true),
        (cols: 126, fits: true),  // the very top of the range, chrome included
        (cols: 128, fits: false), // M2's 896pt is the grid alone; the gutter tips it over
        (cols: 160, fits: false), // needs the font to shrink
    ])
    func realWidthsFit(_ c: (cols: Int, fits: Bool)) {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: c.cols, cellWidth: 7.0)
        #expect((needed <= config.widthRange.upperBound) == c.fits,
                "\(c.cols) cols wanted \(needed)pt")
    }

    @Test("the measured widths match M2's table")
    func matchesSpikeTable() {
        // 73 × 7 + 16 gutter = 527. M2 quotes 511 for the grid alone; the
        // difference is the lane's own chrome, and both sit well inside 900.
        #expect(TerminalPaneController.laneWidth(forCols: 73, cellWidth: 7.0) == 527)
        // 912 — which is *past* LANE_MAX. M2's 896 counts the grid only, so the
        // true ceiling at 12 pt is 126 columns, not 128.
        #expect(TerminalPaneController.laneWidth(forCols: 128, cellWidth: 7.0) == 912)
        #expect(TerminalPaneController.laneWidth(forCols: 126, cellWidth: 7.0) == 898)
        #expect(TerminalPaneController.laneWidth(forCols: 52, cellWidth: 7.0) == 380)
    }

    @Test("a narrow session clamps up to LANE_MIN rather than making a sliver")
    func narrowSessionClampsToMinimum() {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 52, cellWidth: 7.0)
        #expect(needed < config.widthRange.lowerBound)
        #expect(config.clampWidth(needed) == config.laneMinPt)
    }

    @Test("a very wide session clamps down to LANE_MAX, which is what triggers font scaling")
    func wideSessionClampsToMaximum() {
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 200, cellWidth: 7.0)
        #expect(needed > config.widthRange.upperBound)
        #expect(config.clampWidth(needed) == config.laneMaxPt)
    }

    @Test("the font floor still shows a usable number of columns")
    func fontFloorIsUsable() {
        // M2: at 9 pt a cell is 5 pt, so LANE_MIN holds 84 columns and LANE_MAX
        // holds 180. Below this the text stops being readable and we clip.
        let config = Config()
        let atMin = (Double(config.laneMinPt) - TerminalPaneController.gutter) / 5.0
        let atMax = (Double(config.laneMaxPt) - TerminalPaneController.gutter) / 5.0
        #expect(Int(atMin) >= 80, "only \(Int(atMin)) columns at the floor")
        #expect(Int(atMax) >= 170)
        #expect(TerminalPaneController.minimumFontSize == 9)
    }

    @Test("the Swift and Rust defaults agree")
    func defaultsAgree() {
        // `laned-core` stamps LANE_DEFAULT_PT onto every new lane; Config is
        // what the user can override. They drift silently if nobody checks,
        // and the symptom is a web lane that opens at a different width than
        // the one the config file says.
        let core = try! Core.openInMemory()
        let state = try! core.createLane(
            placement: .end, kind: .web, relaySessionId: nil,
            url: "https://example.com", inheritTagFromLane: nil)
        #expect(state.lanes[0].widthPt == Config().laneDefaultPt)
    }

    @Test("the default lane width holds 80 columns at the default font size")
    func defaultHolds80Columns() {
        // The common case — an agent TUI assuming 80 columns — should not open
        // already clipped. At 13 pt a cell is 8 pt.
        let config = Config()
        let needed = TerminalPaneController.laneWidth(forCols: 80, cellWidth: 8.0)
        #expect(needed <= config.laneDefaultPt, "80 cols wants \(needed)pt, default is \(config.laneDefaultPt)")
    }
}

/// The search index holds text, not formatting.
@Suite("scrollback text extraction")
@MainActor
struct ScrollbackTextTests {
    @Test("strips CSI colour and cursor sequences")
    func stripsCSI() {
        let input = "\u{1b}[32mok\u{1b}[0m done\u{1b}[2K"
        #expect(TerminalPaneController.stripEscapes(input) == "ok done")
    }

    @Test("strips OSC sequences with either terminator")
    func stripsOSC() {
        #expect(TerminalPaneController.stripEscapes("a\u{1b}]0;a title\u{07}b") == "ab")
        #expect(TerminalPaneController.stripEscapes("a\u{1b}]7;file://h/p\u{1b}\\b") == "ab")
    }

    @Test("keeps the text an agent actually prints, emoji included")
    func keepsRealOutput() {
        // M2 caught `translateToString` silently dropping astral-plane scalars,
        // which is most of what agent output decorates itself with.
        let input = "\u{1b}[1m✳ Latest commit\u{1b}[0m 😀 日本 🇺🇸"
        #expect(TerminalPaneController.stripEscapes(input) == "✳ Latest commit 😀 日本 🇺🇸")
    }

    @Test("drops carriage returns, which would otherwise split one line into two")
    func dropsCarriageReturns() {
        #expect(TerminalPaneController.stripEscapes("progress\rdone") == "progressdone")
    }

    @Test("survives a sequence truncated at the end of a frame")
    func survivesTruncation() {
        // A frame boundary can land anywhere; nothing here may hang or trap.
        #expect(TerminalPaneController.stripEscapes("text\u{1b}[") == "text")
        #expect(TerminalPaneController.stripEscapes("text\u{1b}") == "text")
        #expect(TerminalPaneController.stripEscapes("text\u{1b}]0;unterminated") == "text")
    }

    @Test("leaves plain text exactly alone")
    func leavesPlainTextAlone() {
        let plain = "error: could not compile laned-core (lib) due to 2 previous errors"
        #expect(TerminalPaneController.stripEscapes(plain) == plain)
    }
}
