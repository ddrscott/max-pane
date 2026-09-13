import AppKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Who sees a ⌘-chord first when a web pane has the keyboard.
///
/// This is the bug "⌘O sometimes opens with no rows" turned out to be. The
/// picker was never empty — it never opened. `NSWindow` walks the view tree
/// with `performKeyEquivalent` *before* the main menu, the `WKWebView` is one of
/// the views in that walk, and a focused web view answers YES to every ⌘-chord
/// so it can forward the key to the page. ⌘O, ⌘T and ⌘Y all died there.
///
/// It only happened with a web pane focused, which is why it never showed up
/// from a freshly launched instance with the strip focused — the state both
/// earlier reproductions were run in.
@Suite("web pane key routing")
@MainActor
struct WebPaneKeyRoutingTests {
    /// A view that claims one chord, standing in for the find and address
    /// fields — the subviews "first refusal" was actually written for.
    private final class ClaimingView: NSView {
        var claim: String = ""
        private(set) var claimed = false
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.charactersIgnoringModifiers == claim else { return false }
            claimed = true
            return true
        }
    }

    private func chord(
        _ characters: String, _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    /// A container with a real web view in it, and a window to hold first
    /// responder — the web view only swallows keys while it *has* the keyboard.
    private func pane() -> (WebPaneContainer, WKWebView, NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 900, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = WebPaneContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        let web = WKWebView(frame: container.bounds, configuration: .init())
        container.addSubview(web)
        window.contentView?.addSubview(container)
        return (container, web, window)
    }

    @Test("a focused page never gets the app's own keys")
    func appKeysSurviveAFocusedPage() {
        let (container, web, window) = pane()
        defer { window.orderOut(nil) }
        container.onKeyEquivalent = { _ in false }
        window.makeFirstResponder(web)
        #expect(window.firstResponder === web)

        // ⌘O is the reported one. The rest share its fate exactly, and a fix
        // that only rescued ⌘O would leave the strip's own navigation dead
        // under the same condition.
        for key in ["o", "t", "y", "r", "w", "b", "p", "[", "]", "="] {
            #expect(
                container.performKeyEquivalent(with: chord(key)) == false,
                "⌘\(key.uppercased()) was swallowed before the menu could see it")
        }
        // ⌥⌘O — Attach a Session — is claimed by mask, not by letter alone.
        #expect(container.performKeyEquivalent(with: chord("o", [.command, .option])) == false)
    }

    /// The half of the walk that must not change: the pane's own keys and the
    /// two text fields still come before the app's menu.
    @Test("a pane key and a field key still beat the menu")
    func paneAndFieldKeysAreUntouched() {
        let (container, _, window) = pane()
        defer { window.orderOut(nil) }
        let field = ClaimingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        field.claim = "a"
        container.addSubview(field)

        var seen: [String] = []
        container.onKeyEquivalent = { event in
            guard let key = event.charactersIgnoringModifiers, key == "f" else { return false }
            seen.append(key)
            return true
        }

        // ⌘F is the pane's, not the app's — it is not in `Commands.swift`.
        #expect(container.performKeyEquivalent(with: chord("f")) == true)
        #expect(seen == ["f"])
        // ⌘A belongs to whatever is editing, and still reaches it.
        #expect(container.performKeyEquivalent(with: chord("a")) == true)
        #expect(field.claimed)
    }

    @Test("every ⌘-chord the app declares is one the app claims")
    func theTableAndTheClaimAgree() {
        for command in Command.allCases {
            for (key, modifiers) in command.chords.map(\.pair)
            where modifiers.contains(.command) {
                // As the event will spell it: shift is the one modifier
                // `charactersIgnoringModifiers` does not ignore.
                let typed = modifiers.contains(.shift) ? shiftedSpelling(key) : key
                #expect(
                    Command.claims(chord(typed, modifiers)),
                    "\(command.rawValue) declares a key the web pane would hand to the page")
            }
        }
    }

    @Test("esc, and keys the app never declared, stay with the page")
    func thePageKeepsItsOwn() {
        // Esc leaves a fullscreen video and closes a modal. `.ungather` uses it
        // with no ⌘, and taking it from every page would be the worse bug.
        #expect(Command.claims(chord("\u{1b}", [])) == false)
        // ⌘C, ⌘V, ⌘A, ⌘Z: editing keys, declared nowhere, so nothing here
        // touches them.
        for key in ["c", "v", "a", "z", "x"] {
            #expect(Command.claims(chord(key)) == false)
        }
        // ⌘F is the web pane's own, handled past the claim.
        #expect(Command.claims(chord("f")) == false)
        // A ⌘-chord that is not a binding at all.
        #expect(Command.claims(chord("j", [.command, .control, .option])) == false)
    }

    private func shiftedSpelling(_ key: String) -> String {
        let map = [
            "[": "{", "]": "}", "=": "+", "-": "_", "\\": "|", "/": "?",
            ",": "<", ".": ">", ";": ":", "'": "\"", "`": "~",
        ]
        return map[key] ?? key.uppercased()
    }
}
