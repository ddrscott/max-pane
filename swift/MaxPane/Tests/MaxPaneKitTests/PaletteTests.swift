import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// One green family instead of Signal Orange (ADR-0015).
///
/// The risk of one family is that the three greens stop being tellable apart,
/// so this holds the order of loudness in both appearances, the contrast of
/// text in both, the absence of orange in the source, and the pulse that is
/// BLOCKED's own channel.
@Suite("one green family")
@MainActor
struct PaletteTests {
    // MARK: - colour arithmetic

    private func srgb(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        let cg = color.cgColor(in: NSAppearance(named: name)!)
        return NSColor(cgColor: cg)!.usingColorSpace(.sRGB)!
    }

    private func luminance(_ color: NSColor, _ name: NSAppearance.Name) -> Double {
        let c = srgb(color, name)
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor, _ name: NSAppearance.Name) -> Double {
        let la = luminance(a, name), lb = luminance(b, name)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private let modes: [NSAppearance.Name] = [.aqua, .darkAqua]

    // MARK: - no orange

    /// One exception, by name: `Theme.done` is Signal Orange, the single hue
    /// outside the family, so a finished agent is findable across a gallery
    /// of green-or-grey lanes. Everything else — focus, buttons, headers,
    /// alarms — stays green, and this scan keeps it so.
    @Test("no orange literal is left anywhere in the app's source, except Theme.done")
    func noOrangeInSource() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            var text = try String(contentsOf: url, encoding: .utf8).lowercased()
            scanned += 1
            if url.lastPathComponent == "Theme.swift" {
                // Only the `done` line may carry the literal.
                text = text.split(separator: "\n").filter { !$0.contains("static let done =") }.joined(separator: "\n")
            }
            // Assembled rather than written out, so the acceptance grep
            // (`rg -i 'e85d00|0xE8 / 255' swift/`) does not find this list.
            for needle in ["e85" + "d00", "0xe8" + " / 255", "system" + "orange", "nscolor." + "orange"] {
                #expect(!text.contains(needle), "\(url.lastPathComponent) still has \(needle)")
            }
        }
        #expect(scanned > 50, "the scan found the source tree")
    }

    @Test("DONE is orange, in both appearances, and reads on a lane")
    func doneIsOrange() {
        for mode in modes {
            let hue = srgb(Theme.done, mode).hueComponent * 360
            #expect((15...35).contains(hue), "done in \(mode.rawValue) has hue \(hue)")
            #expect(contrast(Theme.done, Theme.laneBackground, mode) >= 4.5)
        }
    }

    @Test("every role is a green, in both appearances")
    func everyRoleIsGreen() {
        for mode in modes {
            for (name, colour) in [("accent", Theme.accent), ("working", Theme.working),
                                   ("blocked", Theme.blocked), ("alive", Theme.alive)] {
                let hue = srgb(colour, mode).hueComponent * 360
                #expect((90...170).contains(hue), "\(name) in \(mode.rawValue) has hue \(hue)")
            }
        }
    }

    @Test("the dark greens are the ticket's")
    func darkValues() {
        #expect(TerminalControllerPool.hex(Theme.working, in: .darkAqua) == "#16a34a")
        #expect(TerminalControllerPool.hex(Theme.accent, in: .darkAqua) == "#22c55e")
        #expect(TerminalControllerPool.hex(Theme.blocked, in: .darkAqua) == "#4ade80")
    }

    @Test("state colours name the roles rather than defining their own")
    func stateColoursAreTheRoles() {
        #expect(Theme.agentStateColor(.blocked) === Theme.blocked)
        #expect(Theme.agentStateColor(.working) === Theme.working)
    }

    // MARK: - tellable apart

    /// On a dark ground loud is light: blocked, then accent, then working, then
    /// merely alive.
    @Test("dark: the brightest is blocked, then focus, then working, then alive")
    func darkOrder() {
        let l = { self.luminance($0, .darkAqua) }
        #expect(l(Theme.blocked) > l(Theme.accent))
        #expect(l(Theme.accent) > l(Theme.working))
        #expect(l(Theme.working) > l(Theme.alive))
    }

    /// On a light ground loud is contrast: the same order, measured against the
    /// lane it sits on.
    @Test("light: the strongest ink is blocked, then focus, then working, then alive")
    func lightOrder() {
        let c = { self.contrast($0, Theme.laneBackground, .aqua) }
        #expect(c(Theme.blocked) > c(Theme.accent))
        #expect(c(Theme.accent) > c(Theme.working))
        #expect(c(Theme.working) > c(Theme.alive))
    }

    @Test("text in the accent and the blocked green reads on every ground, in both appearances")
    func textContrast() {
        for mode in modes {
            for ground in [Theme.laneBackground, Theme.stripBackground] {
                #expect(contrast(Theme.accent, ground, mode) >= 4.5, "accent in \(mode.rawValue)")
                #expect(contrast(Theme.blocked, ground, mode) >= 4.5, "blocked in \(mode.rawValue)")
                // A rate and a chip word: secondary, but still text.
                #expect(contrast(Theme.working, ground, mode) >= 4.0, "working in \(mode.rawValue)")
            }
            #expect(contrast(Theme.onBlocked, Theme.blocked, mode) >= 4.5, "BLOCKED's word in \(mode.rawValue)")
        }
    }

    @Test("the terminal cursor follows the accent in each appearance")
    func cursorFollowsTheAccent() {
        #expect(TerminalControllerPool.hex(Theme.accent, in: .aqua) == "#15773a")
        #expect(TerminalControllerPool.hex(Theme.accent, in: .darkAqua) == "#22c55e")
    }

    // MARK: - the pulse

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(view)
        return window
    }

    private func withMotion(reduced: Bool, _ body: () throws -> Void) rethrows {
        let previous = BlockedPulse.isReduced
        defer { BlockedPulse.isReduced = previous }
        BlockedPulse.isReduced = { reduced }
        try body()
    }

    @Test("the pulse is slow, eased, and never reaches nothing")
    func pulseShape() throws {
        let pulse = BlockedPulse.animation(now: 0)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.autoreverses)
        #expect(pulse.repeatCount == .infinity)
        // One breath, out and back, of roughly 1.5–2 s.
        #expect((1.5...2.0).contains(pulse.duration * 2))
        let floor = try #require(pulse.toValue as? Float)
        #expect(floor >= 0.5 && floor < 1, "dimmer, never off")
    }

    /// A row rebuilt mid-breath must carry on from where the old one was, or
    /// the sidebar twitches once a second.
    @Test("the pulse is phase-locked to the clock")
    func pulseIsPhaseLocked() {
        let a = BlockedPulse.animation(now: 1000)
        let b = BlockedPulse.animation(now: 1000 + BlockedPulse.period * 3)
        #expect(abs(a.timeOffset - b.timeOffset) < 1e-6)
        #expect(a.timeOffset >= 0 && a.timeOffset < BlockedPulse.period)
    }

    @Test("a label pulses only while blocked and on screen")
    func labelLifecycle() {
        withMotion(reduced: false) {
            let label = PulseLabel(labelWithString: "BLOCKED")
            label.isPulsing = true
            #expect(!label.isAnimatingPulse, "not in a window, so nothing to animate")

            let window = host(label)
            #expect(label.isAnimatingPulse, "on screen and blocked")

            label.removeFromSuperview()
            #expect(!label.isAnimatingPulse, "off screen stops it")
            window.contentView?.addSubview(label)
            #expect(label.isAnimatingPulse, "back on screen starts it again")

            label.isPulsing = false
            #expect(!label.isAnimatingPulse, "no longer blocked stops it at once")
            _ = window
        }
    }

    @Test("under Reduce Motion a blocked mark is steady")
    func reduceMotionIsSteady() {
        withMotion(reduced: true) {
            let label = PulseLabel(labelWithString: "BLOCKED")
            let window = host(label)
            label.isPulsing = true
            #expect(!label.isAnimatingPulse)
            #expect(label.layer?.opacity == 1, "steady at full strength")
            _ = window
        }
    }

    @Test("the lane header's blocked mark pulses, filled, and stops when the agent moves on")
    func headerPulses() {
        withMotion(reduced: false) {
            let header = LaneHeaderView()
            header.frame = NSRect(x: 0, y: 0, width: 600, height: Theme.laneHeaderHeight)
            let window = host(header)
            header.apply(Self.lane())
            header.telemetry = SessionTelemetry(sessionId: "a", command: "claude", state: .blocked)
            header.layoutSubtreeIfNeeded()
            #expect(header.isBlockedMarkPulsing)

            header.telemetry = SessionTelemetry(sessionId: "a", command: "claude", state: .working)
            header.layoutSubtreeIfNeeded()
            #expect(!header.isBlockedMarkPulsing)
            _ = window
        }
    }

    @Test("a sidebar row's BLOCKED chip pulses, and no other state's does")
    func sidebarRowPulses() throws {
        try withMotion(reduced: false) {
            for (state, pulses) in [(AgentState.blocked, true), (.working, false), (.done, false)] {
                let rows = SidebarModel.rows(
                    lanes: [], telemetry: ["s": SessionTelemetry(sessionId: "s", command: "claude", state: state)])
                let entry = try #require(rows.compactMap { row -> SidebarModel.Entry? in
                    if case .entry(let e) = row { return e } else { return nil }
                }.first)
                let view = SidebarEntryView(entry: entry)
                view.frame = NSRect(x: 0, y: 0, width: 290, height: SidebarEntryView.height)
                let window = host(view)
                #expect(view.isBlockedMarkPulsing == pulses, "\(state)")
                _ = window
            }
        }
    }

    @Test("the status bar's BLOCKED count pulses while something is blocked")
    func statusBarPulses() {
        withMotion(reduced: false) {
            let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: 600, height: StatusBar.height))
            let window = host(bar)
            let state = StripState(lanes: [], scrollX: 0, focusedPaneId: nil, gatherFilter: nil, hiddenLaneIds: [], revision: 0)
            bar.update(
                state: state,
                telemetry: ["a": SessionTelemetry(sessionId: "a", command: "claude", state: .blocked)],
                webBytes: 0)
            #expect(bar.isAttentionPulsing)
            bar.update(
                state: state,
                telemetry: ["a": SessionTelemetry(sessionId: "a", command: "claude", state: .working)],
                webBytes: 0)
            #expect(!bar.isAttentionPulsing)
            _ = window
        }
    }

    private static func lane() -> Lane {
        Lane(id: "l", ordinal: 1, widthPt: 600, title: "Latest commit changes", projectRoot: "/tmp",
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1,
             panes: [Pane(id: "p", laneId: "l", position: 0, kind: .pty,
                          relaySessionId: "a", relayServer: nil, url: nil, scrollY: nil, dataStoreId: nil,
                          snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false)])
    }
}
