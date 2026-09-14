import AppKit
import Testing
@testable import MaxPaneKit

/// The shared dialog frame: where it goes, and how a question is answered.
///
/// "Balanced margins" is tested as a number, because an off-by-one popup looks
/// fine in every screenshot except the one where someone is looking for it.
@Suite("a popup")
@MainActor
struct PopupTests {
    private let window = NSRect(x: 0, y: 0, width: 1600, height: 1000)

    @Test("it is centred, with the same margin either side and above and below")
    func centred() {
        let frame = Popup.frame(size: NSSize(width: 720, height: 420), in: window)
        #expect(frame == NSRect(x: 440, y: 290, width: 720, height: 420))
        #expect(frame.minX - window.minX == window.maxX - frame.maxX)
        #expect(frame.minY - window.minY == window.maxY - frame.maxY)
    }

    @Test("it is centred in the window it is about, wherever that window is on screen")
    func followsTheWindow() {
        let elsewhere = NSRect(x: 2000, y: 300, width: 1200, height: 800)
        let frame = Popup.frame(size: NSSize(width: 460, height: 180), in: elsewhere)
        #expect(abs(frame.midX - elsewhere.midX) <= 0.5)
        #expect(abs(frame.midY - elsewhere.midY) <= 0.5)
    }

    @Test("a popup too big for the window keeps the margin on every side")
    func shrinksToTheMargin() {
        let frame = Popup.frame(size: NSSize(width: 2000, height: 1500), in: window)
        #expect(frame == NSRect(x: Popup.margin, y: Popup.margin,
                                width: window.width - 2 * Popup.margin, height: window.height - 2 * Popup.margin))
    }

    @Test("a minimum size wins over the margin while the window can hold it")
    func minimumSize() {
        let small = NSRect(x: 0, y: 0, width: 600, height: 380)
        let frame = Popup.frame(size: NSSize(width: 960, height: 640), minSize: NSSize(width: 560, height: 320), in: small)
        #expect(frame.width == 560 && frame.height == 320)
    }

    @Test("it lands on whole points, so its one-point border stays one point")
    func wholePoints() {
        let frame = Popup.frame(size: NSSize(width: 461, height: 181), in: NSRect(x: 0.5, y: 0, width: 1001, height: 777))
        #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded())
    }

    @Test("a confirmation answers once, with the button it was given")
    func answersOnce() {
        var answers: [Int?] = []
        let popup = ConfirmPopup(
            title: "Delete the folder?", detail: "Everything in it goes too.",
            choices: [.init(title: "Cancel", isDefault: true), .init(title: "Delete", isDefault: false)]
        ) { choice, _ in answers.append(choice) }
        popup.choose(1)
        popup.choose(0)
        popup.popupCancelled()
        #expect(answers == [1])
    }

    @Test("Esc or a click away is Cancel, which is no answer at all")
    func cancelIsNil() {
        var answers: [Int?] = []
        let popup = ConfirmPopup(title: "Resize?", detail: nil, choices: [.init(title: "OK", isDefault: true)]) { choice, _ in
            answers.append(choice)
        }
        popup.popupCancelled()
        #expect(answers == [nil])
    }

    @Test("a prompt hands back what was typed, trimmed")
    func promptText() {
        var text: String?
        let popup = ConfirmPopup(
            title: "Project tag", detail: nil,
            choices: [.init(title: "Cancel", isDefault: false), .init(title: "Set", isDefault: true)],
            fieldText: "  /src/max-pane "
        ) { _, value in text = value }
        popup.choose(1)
        #expect(text == "/src/max-pane")
    }

    @Test("its height is its content's, not a guess")
    func sizedToContent() {
        let short = ConfirmPopup(title: "OK?", detail: nil, choices: [.init(title: "OK", isDefault: true)]) { _, _ in }
        let long = ConfirmPopup(
            title: "Resize this session to fit the lane?",
            detail: String(repeating: "This changes the terminal's size for everyone attached to it. ", count: 4),
            choices: [.init(title: "Cancel", isDefault: false), .init(title: "Resize Session", isDefault: true)]
        ) { _, _ in }
        let shortHeight = short.window?.frame.height ?? 0
        let longHeight = long.window?.frame.height ?? 0
        #expect(shortHeight > 60)
        #expect(longHeight > shortHeight + 30)
        #expect(short.window?.frame.width == ConfirmPopup.width)
    }
}

/// The popups' insides, rendered so their padding can be looked at rather than
/// assumed — the owner asked for balanced margins, and a number in a test says
/// where a popup goes, not whether its contents breathe. Gated on `MAXPANE_SHOTS`.
@Suite("popup rendering")
@MainActor
struct PopupRenderTests {
    private func write(_ view: NSView, _ name: String, to dir: String) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("popup-\(name).png"))
    }

    @Test("renders a confirmation, a prompt and the shortcuts")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let confirm = ConfirmPopup(
            title: "Resize this session to fit the lane?",
            detail: "This changes the terminal's size for everyone attached to it, including the Relay web client on your phone, and will redraw whatever is running.\n\nMax Pane otherwise never resizes a session — it sizes the lane to the session instead.",
            choices: [.init(title: "Cancel", isDefault: false), .init(title: "Resize Session", isDefault: true)]
        ) { _, _ in }
        let prompt = ConfirmPopup(
            title: "Project tag for this lane",
            detail: "Sticky — the cwd tagger will not overwrite it. Empty clears it.",
            choices: [.init(title: "Cancel", isDefault: false), .init(title: "Set", isDefault: true)],
            fieldText: "/Users/spierce/code/max-pane"
        ) { _, _ in }
        let help = HelpPanel()
        for (popup, name) in [(confirm as Popup, "confirm"), (prompt, "prompt"), (help, "help")] {
            let content = try #require(popup.window?.contentView)
            content.frame = NSRect(origin: .zero, size: popup.window?.frame.size ?? .zero)
            try write(content, name, to: dir)
        }
    }
}
