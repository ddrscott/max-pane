import AppKit
import Testing
@testable import MaxPaneKit

/// ⌘L, and what the address bar does once it has the keyboard.
///
/// Reported as *"⌘L is dead"* and diagnosed, correctly, as the same root cause
/// as "⌘O opens with no rows": a focused `WKWebView` answers YES to every
/// ⌘-chord in `performKeyEquivalent`, which `NSWindow` walks before the main
/// menu. The difference is that ⌘O was declared in `Commands.swift` and only
/// needed rescuing, and ⌘L was declared nowhere — so `Command.claims` had
/// nothing to rescue and there was no menu item behind it to reach anyway.
///
/// The rest is the sentence the owner actually wrote: *"cmd-l in a webview
/// should focus on it's address bar for easily modifying the url and
/// copy/paste."* Two requirements, and the second is the one that is easy to
/// half-build.
@Suite("the address bar and ⌘L")
@MainActor
struct AddressBarTests {
    private func chord(
        _ characters: String, _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0)!
    }

    /// A window a field editor can actually live in. `currentEditor()` is nil
    /// for a field that is not in one, and every selection assertion below is
    /// about the editor rather than the field.
    private func hosted(_ field: AddressField) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 600, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        field.frame = NSRect(x: 0, y: 0, width: 600, height: 26)
        window.contentView?.addSubview(field)
        return window
    }

    @Test("⌘L is declared, so the app claims it back from the page")
    func commandLIsClaimed() {
        #expect(Command.editAddress.defaultShortcut.0 == "l")
        #expect(Command.editAddress.defaultShortcut.1 == [.command])
        // The point of declaring it: `claims` only rescues what this file
        // names, so a ⌘L handled anywhere else would still die in the web view.
        #expect(Command.claims(chord("l")))
    }

    /// One key, one meaning. A second command reaching for ⌘L is the failure
    /// `Commands.swift` exists to make impossible to miss.
    @Test("no two commands claim the same chord")
    func chordsAreUnique() {
        var seen: [String: Command] = [:]
        for command in Command.allCases {
            for (key, modifiers) in command.chords.map(\.pair) {
                let id = "\(modifiers.intersection(.deviceIndependentFlagsMask).rawValue):\(key)"
                #expect(seen[id] == nil, "\(command.rawValue) and \(seen[id]?.rawValue ?? "?") share a key")
                seen[id] = command
            }
        }
    }

    /// The whole address, scheme and all — the chrome strips `https://` and
    /// `www.` for *reading*, and a copy that silently omits the scheme is a
    /// copy that does not paste back.
    @Test("editing opens the full URL, selected")
    func editingOpensTheFullURLSelected() {
        let field = AddressField()
        let window = hosted(field)
        defer { window.orderOut(nil) }
        field.fullURL = "https://en.wikipedia.org/wiki/Whale"
        field.show(NSAttributedString(string: "en.wikipedia.org/wiki/Whale"), fade: false)

        field.beginEditing(with: field.fullURL)
        #expect(field.isEditingAddress)
        #expect(field.stringValue == "https://en.wikipedia.org/wiki/Whale")
        // Selected, so ⌘C copies it whole and the next keystroke replaces it.
        #expect(field.currentEditor()?.selectedRange
            == NSRange(location: 0, length: field.stringValue.count))
    }

    /// Pressed twice by reflex. Browsers re-select; they do not toggle back out
    /// to the page, and they do not throw away what you have typed.
    @Test("⌘L again re-selects rather than toggling away")
    func secondPressReselects() {
        let field = AddressField()
        let window = hosted(field)
        defer { window.orderOut(nil) }
        field.fullURL = "https://example.com/one"
        field.beginEditing(with: field.fullURL)
        field.currentEditor()?.selectedRange = NSRange(location: 8, length: 0)
        field.stringValue = "https://example.com/two"

        field.beginEditing(with: field.fullURL)
        #expect(field.isEditingAddress)
        #expect(field.stringValue == "https://example.com/two")
        #expect(field.currentEditor()?.selectedRange
            == NSRange(location: 0, length: field.stringValue.count))
    }

    /// Escape abandons a half-typed address without navigating, puts the real
    /// one back, and tells the pane to take the keyboard again — the field
    /// itself can only give first responder up, and a window holding it is a
    /// window where typing reaches nothing.
    @Test("escape restores the real address and hands the keyboard back")
    func escapeRestoresAndReleases() {
        let field = AddressField()
        let window = hosted(field)
        defer { window.orderOut(nil) }
        let drawn = NSAttributedString(string: "example.com/one")
        field.fullURL = "https://example.com/one"
        field.show(drawn, fade: false)

        var handedBack = 0
        var committed: [String] = []
        field.onEndEditing = { handedBack += 1 }
        field.onCommit = { committed.append($0) }

        field.beginEditing(with: field.fullURL)
        field.stringValue = "https://example.com/half-typed"
        _ = field.control(field, textView: NSTextView(),
                          doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        #expect(field.isEditingAddress == false)
        #expect(field.stringValue == drawn.string)
        #expect(handedBack == 1)
        // Abandoning is not navigating.
        #expect(committed.isEmpty)
    }

    /// Clicking away is a cancel too, and it has to hand the keyboard back by
    /// the same path — otherwise the pane the ledger says is focused is deaf.
    @Test("clicking away ends editing without navigating")
    func clickingAwayIsACancel() {
        let field = AddressField()
        let window = hosted(field)
        defer { window.orderOut(nil) }
        field.fullURL = "https://example.com"
        field.show(NSAttributedString(string: "example.com"), fade: false)

        var handedBack = 0
        var committed: [String] = []
        field.onEndEditing = { handedBack += 1 }
        field.onCommit = { committed.append($0) }

        field.beginEditing(with: field.fullURL)
        field.stringValue = "https://elsewhere.example"
        field.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field))

        #expect(field.isEditingAddress == false)
        #expect(handedBack == 1)
        #expect(committed.isEmpty)
    }

    /// The chrome bar hands the field its *unabbreviated* address, not the row
    /// it is drawing. This is the one that would pass a review by eye and fail
    /// on the clipboard.
    @Test("the chrome bar opens editing on the unabbreviated address")
    func chromeBarEditsTheFullURL() {
        let bar = WebChromeBar(frame: NSRect(x: 0, y: 0, width: 600, height: WebChromeBar.height))
        let window = NSWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 600, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(bar)
        defer { window.orderOut(nil) }

        bar.setURL("https://www.example.com/deep/path?q=1")
        #expect(bar.isEditingAddress == false)
        bar.beginEditingAddress()
        #expect(bar.isEditingAddress)
        #expect(bar.editedText == "https://www.example.com/deep/path?q=1")
    }
}
