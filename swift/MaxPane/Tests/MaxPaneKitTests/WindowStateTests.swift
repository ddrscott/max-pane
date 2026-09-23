import AppKit
import Foundation
import Testing
@testable import MaxPaneKit

// The window comes back where you left it (ADR-0036): fullscreen or a frame,
// in the ledger, clamped onto a screen that still exists. First launch is
// fullscreen, as PRD §5.2 asked.

// Two displays as the rules see them: a 1440×900 laptop at the origin with a
// 25 pt menu bar, and a 2560×1440 external to its right with its own.
private let laptop = WindowState.Screen(id: "1", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))
private let external = WindowState.Screen(id: "2", visibleFrame: CGRect(x: 1440, y: 0, width: 2560, height: 1415))
private let both = [laptop, external]

@Suite("window state: the encoding")
struct WindowStateEncodingTests {
    @Test("fullscreen is one key, and reads back")
    func fullscreen() {
        let state = WindowState.fullscreen
        #expect(state.encoded == #"{"fullscreen":true}"#)
        #expect(WindowState.decode(state.encoded) == state)
    }

    @Test("a frame and its display round-trip, in the shape the doc promises")
    func windowed() {
        let state = WindowState(fullscreen: false, frame: CGRect(x: 100, y: 50, width: 1600, height: 1000), screen: "2")
        #expect(state.encoded == #"{"fullscreen":false,"frame":[100,50,1600,1000],"screen":"2"}"#)
        #expect(WindowState.decode(state.encoded) == state)
    }

    @Test("a fractional frame keeps its fraction")
    func fractional() {
        let state = WindowState(fullscreen: false, frame: CGRect(x: 0.5, y: 0, width: 800, height: 600), screen: nil)
        #expect(WindowState.decode(state.encoded) == state)
    }

    @Test("anything else reads as nothing remembered, not a crash")
    func garbage() {
        #expect(WindowState.decode("") == nil)
        #expect(WindowState.decode("nonsense") == nil)
        #expect(WindowState.decode(#"{"frame":[1,2,3,4]}"#) == nil)
        #expect(WindowState.decode(#"{"fullscreen":false,"frame":[1,2,3]}"#) == nil)
        #expect(WindowState.decode(#"{"fullscreen":false,"frame":["a","b","c","d"]}"#) == nil)
    }
}

@Suite("window state: where the window goes at launch")
struct WindowStatePlacementTests {
    @Test("nothing remembered — the first launch — is fullscreen")
    func firstLaunch() {
        #expect(WindowState.placement(for: nil, screens: both) == .fullscreen(on: nil))
    }

    @Test("a remembered fullscreen is fullscreen, on its display when that is still there")
    func rememberedFullscreen() {
        let onExternal = WindowState(fullscreen: true, screen: "2")
        #expect(WindowState.placement(for: onExternal, screens: both) == .fullscreen(on: external))
        #expect(WindowState.placement(for: onExternal, screens: [laptop]) == .fullscreen(on: nil))
        #expect(WindowState.placement(for: .fullscreen, screens: both) == .fullscreen(on: nil))
    }

    @Test("a frame that fits on its display comes back exactly")
    func fits() {
        let frame = CGRect(x: 1500, y: 100, width: 1600, height: 1000)
        let state = WindowState(fullscreen: false, frame: frame, screen: "2")
        #expect(WindowState.placement(for: state, screens: both) == .windowed(frame))
    }

    @Test("partly off its display, it is pushed back on, same size")
    func partlyOff() {
        // Hanging off the external's right and top edges.
        let frame = CGRect(x: 3000, y: 900, width: 1600, height: 1000)
        let clamped = WindowState.clamp(frame, remembered: "2", onto: both)
        #expect(clamped == CGRect(x: 2400, y: 415, width: 1600, height: 1000))
    }

    @Test("the display it was on is gone: it lands on the one it overlaps most, shrunk to fit")
    func displayGone() {
        // Remembered on the external, which is unplugged. The frame overlaps
        // the laptop a little; it is the only screen, and too small for it.
        let frame = CGRect(x: 1000, y: 100, width: 1600, height: 1000)
        let clamped = WindowState.clamp(frame, remembered: "2", onto: [laptop])
        #expect(clamped.width == 1440)
        #expect(clamped.height == 875)
        #expect(laptop.visibleFrame.contains(clamped))
    }

    @Test("off every screen: the nearest one, and never under the menu bar")
    func offEveryScreen() {
        // Far above and to the right of both displays, from a display that
        // no longer exists. The external is nearer.
        let frame = CGRect(x: 5000, y: 3000, width: 1200, height: 800)
        let clamped = WindowState.clamp(frame, remembered: "9", onto: both)
        #expect(clamped.size == CGSize(width: 1200, height: 800))
        #expect(external.visibleFrame.contains(clamped))
        #expect(clamped.maxY <= external.visibleFrame.maxY)
        // And with only the laptop, the laptop.
        let alone = WindowState.clamp(frame, remembered: "9", onto: [laptop])
        #expect(laptop.visibleFrame.contains(alone))
    }

    @Test("with no screens at all, the frame is left alone")
    func headless() {
        let frame = CGRect(x: -8000, y: 0, width: 800, height: 600)
        #expect(WindowState.clamp(frame, remembered: nil, onto: []) == frame)
    }

    @Test("MAXPANE_WINDOWED writes nothing")
    func windowedWritesNothing() {
        #expect(WindowState.writesEnabled(environment: ["MAXPANE_WINDOWED": "1"]) == false)
        #expect(WindowState.writesEnabled(environment: [:]) == true)
    }
}

/// The keeper on a real window, off screen at x: -8000 like every other
/// window in this suite. The fullscreen transition is driven by posting the
/// window's own notifications: the keeper listens to those, and an off-screen
/// test window cannot honestly enter fullscreen.
@Suite("window state: what the keeper writes")
@MainActor
struct WindowStateKeeperTests {
    private func window() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: -8000, y: 0, width: 800, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        // Never ordered front: AppKit posts the move and resize notifications
        // for a hidden window too, and ordering one front constrains it onto
        // a real screen, which is exactly where a test window must not go.
        return w
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func post(_ name: Notification.Name, _ w: NSWindow) {
        NotificationCenter.default.post(name: name, object: w)
    }

    @Test("a move or resize is written once, after the quiet, as the frame it ended at")
    func moveIsDebounced() {
        let w = window()
        var writes: [WindowState] = []
        let keeper = WindowStateKeeper(window: w) { writes.append($0) }
        defer { keeper.stop() }

        w.setFrameOrigin(NSPoint(x: -8100, y: 10))
        w.setFrameOrigin(NSPoint(x: -8200, y: 20))
        w.setFrame(NSRect(x: -8200, y: 20, width: 900, height: 700), display: false)
        #expect(writes.isEmpty)

        pump(WindowStateKeeper.quiet + 0.2)
        #expect(writes.count == 1)
        #expect(writes.first?.fullscreen == false)
        #expect(writes.first?.frame == NSRect(x: -8200, y: 20, width: 900, height: 700))
    }

    @Test("entering and leaving fullscreen each write, and nothing is written in between")
    func fullscreenTransitions() {
        let w = window()
        var writes: [WindowState] = []
        let keeper = WindowStateKeeper(window: w) { writes.append($0) }
        defer { keeper.stop() }

        post(NSWindow.willEnterFullScreenNotification, w)
        // AppKit resizes the window several times on the way in.
        w.setFrame(NSRect(x: -8000, y: 0, width: 1000, height: 800), display: false)
        pump(WindowStateKeeper.quiet + 0.2)
        #expect(writes.isEmpty)
        #expect(keeper.transitioning)

        post(NSWindow.didEnterFullScreenNotification, w)
        #expect(writes.count == 1)
        #expect(!keeper.transitioning)

        post(NSWindow.willExitFullScreenNotification, w)
        w.setFrame(NSRect(x: -8000, y: 0, width: 800, height: 600), display: false)
        pump(WindowStateKeeper.quiet + 0.2)
        #expect(writes.count == 1)

        post(NSWindow.didExitFullScreenNotification, w)
        #expect(writes.count == 2)
        #expect(writes.last?.frame == NSRect(x: -8000, y: 0, width: 800, height: 600))
    }

    @Test("flush — quit — writes what the debounce was still holding")
    func flushOnQuit() {
        let w = window()
        var writes: [WindowState] = []
        let keeper = WindowStateKeeper(window: w) { writes.append($0) }
        defer { keeper.stop() }

        w.setFrameOrigin(NSPoint(x: -8300, y: 30))
        keeper.flush()
        #expect(writes.count == 1)
        #expect(writes.first?.frame?.origin == NSPoint(x: -8300, y: 30))
        // And the debounce was cancelled, not doubled.
        pump(WindowStateKeeper.quiet + 0.2)
        #expect(writes.count == 1)
    }

    @Test("flush mid-transition writes nothing")
    func flushMidTransition() {
        let w = window()
        var writes: [WindowState] = []
        let keeper = WindowStateKeeper(window: w) { writes.append($0) }
        defer { keeper.stop() }

        post(NSWindow.willEnterFullScreenNotification, w)
        keeper.flush()
        #expect(writes.isEmpty)
    }
}
