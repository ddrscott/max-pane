import AppKit
import Testing
@testable import MaxPaneKit

/// A dialog in front owns the keyboard (ADR-0045).
///
/// The owner: *"When using ⌘O and then ⌘V the paste goes to the background
/// pane instead of the foreground dialog! I think this is a fundamental issue
/// with all dialogs where input is missed by the dialog."* It was. AppKit
/// answers a nil-targeted action by searching the key window's responder chain
/// and then the main window's, and a pane's container answered its routed
/// Edit-menu actions whenever it was asked — from behind a picker (a key panel
/// over the strip) and from under a sheet laid over the pane alike.
///
/// Test windows are never really key, so these use `KeyableWindow`, which
/// says it is when told to. That is what makes each half of the rule — the
/// right window is key, *and* the pane's own view has the keyboard — provable
/// on its own; in an ordinary test window the first half would decline for
/// every case and the second would never be exercised.
@MainActor
@Suite("a dialog in front owns the keyboard")
struct KeyboardOwnerTests {
    /// A window that reports key when told to, standing in for the strip's
    /// window and for a picker's panel.
    final class KeyableWindow: NSWindow {
        var reportsKey = false
        override var isKeyWindow: Bool { reportsKey }
        convenience init() {
            self.init(contentRect: NSRect(x: -8000, y: 200, width: 600, height: 400),
                      styleMask: [.borderless], backing: .buffered, defer: false)
            isReleasedWhenClosed = false
            contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        }
    }

    /// Something that can hold the keyboard: a terminal, a web view, a
    /// sheet's control, a picker's field.
    final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The order AppKit searches for a nil-targeted action: the key window's
    /// responder chain, then the main window's.
    private func firstTaker(of action: Selector, key: NSWindow, main: NSWindow) -> NSResponder? {
        for window in [key, main] {
            var responder: NSResponder? = window.firstResponder
            while let next = responder {
                if next.responds(to: action) { return next }
                responder = next.nextResponder
            }
        }
        return nil
    }

    private static let terminalActions: [Selector] = [
        #selector(TerminalPasteTarget.pasteIntoTerminalPane(_:)),
        #selector(TerminalPasteTarget.pasteIntoTerminalPaneWithoutAsking(_:)),
        #selector(TerminalPasteTarget.pasteSpecialIntoTerminalPane(_:)),
        #selector(TerminalCopyTarget.copyWithStylesFromTerminalPane(_:)),
        #selector(TerminalCopyTarget.toggleCopyModeInTerminalPane(_:)),
    ]

    @Test("the keyboard is in a view only when its window is key and it, or something in it, has the focus")
    func keyboardIsInAView() {
        let window = KeyableWindow()
        let outer = Focusable(frame: .zero)
        let inner = Focusable(frame: .zero)
        let sibling = Focusable(frame: .zero)
        outer.addSubview(inner)
        window.contentView?.addSubview(outer)
        window.contentView?.addSubview(sibling)

        #expect(window.makeFirstResponder(outer))
        #expect(!keyboardIsIn(outer), "a window that is not key holds nobody's keyboard")
        window.reportsKey = true
        #expect(keyboardIsIn(outer))
        #expect(window.makeFirstResponder(inner))
        #expect(keyboardIsIn(outer), "something inside the view counts")
        #expect(window.makeFirstResponder(sibling))
        #expect(!keyboardIsIn(outer), "a sibling is not inside")
        #expect(!keyboardIsIn(nil))
    }

    @Test("⌘O then ⌘V: with a picker in front, no terminal behind it takes the paste")
    func thePickerCase() {
        // The strip's window, with a terminal pane whose terminal has the focus.
        let strip = KeyableWindow()
        let container = TerminalPaneContainer(frame: .zero)
        let terminal = Focusable(frame: .zero)
        container.addSubview(terminal)
        container.keyboardView = terminal
        strip.contentView?.addSubview(container)
        #expect(strip.makeFirstResponder(terminal))

        // Nothing in front: the terminal has the keyboard and takes every one.
        strip.reportsKey = true
        for action in Self.terminalActions {
            #expect(firstTaker(of: action, key: strip, main: strip) === container, "\(action)")
        }

        // The ⌘O picker comes up: a key panel over the strip. The strip's
        // first responder is still the terminal — only which window is key
        // has changed, which is exactly what went unchecked.
        let picker = KeyableWindow()
        let field = Focusable(frame: .zero)
        picker.contentView?.addSubview(field)
        #expect(picker.makeFirstResponder(field))
        strip.reportsKey = false
        picker.reportsKey = true
        #expect(strip.firstResponder === terminal)
        for action in Self.terminalActions {
            #expect(firstTaker(of: action, key: picker, main: strip) == nil,
                    "\(action) reached the terminal behind the picker")
        }

        // The picker goes: the terminal has it back.
        picker.reportsKey = false
        strip.reportsKey = true
        #expect(firstTaker(of: Self.terminalActions[0], key: strip, main: strip) === container)
    }

    @Test("a sheet over the pane: its own control has the keyboard, so the pane's container does not take the action")
    func theSheetCase() {
        let strip = KeyableWindow()
        strip.reportsKey = true
        let container = TerminalPaneContainer(frame: .zero)
        let terminal = Focusable(frame: .zero)
        let sheet = Focusable(frame: .zero)
        container.addSubview(terminal)
        container.addSubview(sheet)
        container.keyboardView = terminal
        strip.contentView?.addSubview(container)

        // The sheet's box has the keyboard. The container is up the chain from
        // it — which is why it used to answer — and now declines.
        #expect(strip.makeFirstResponder(sheet))
        for action in Self.terminalActions {
            #expect(firstTaker(of: action, key: strip, main: strip) == nil, "\(action)")
        }
        // The terminal takes the keyboard back, and the actions with it.
        #expect(strip.makeFirstResponder(terminal))
        for action in Self.terminalActions {
            #expect(firstTaker(of: action, key: strip, main: strip) === container, "\(action)")
        }
    }

    @Test("a pane with no keyboard view takes nothing, and every other selector answers as before")
    func onlyTheRoutedActionsAreGated() {
        let strip = KeyableWindow()
        strip.reportsKey = true
        let container = TerminalPaneContainer(frame: .zero)
        strip.contentView?.addSubview(container)
        #expect(!container.responds(to: Self.terminalActions[0]), "no keyboard view: never the keyboard's owner")
        #expect(container.responds(to: #selector(NSView.layout)))
        #expect(container.responds(to: #selector(NSView.viewDidMoveToWindow)))
    }

    @Test("⌘C in a web pane: the page is copied from only while it has the keyboard in the key window")
    func theWebPane() {
        let action = #selector(WebCopyTarget.copyFromWebPane(_:))
        let strip = KeyableWindow()
        let container = WebPaneContainer(frame: .zero)
        let page = Focusable(frame: .zero)
        let address = Focusable(frame: .zero)
        container.addSubview(page)
        container.addSubview(address)
        container.keyboardView = page
        strip.contentView?.addSubview(container)
        #expect(strip.makeFirstResponder(page))
        strip.reportsKey = true
        #expect(firstTaker(of: action, key: strip, main: strip) === container)

        // The address field has it: the field copies, not the page.
        #expect(strip.makeFirstResponder(address))
        #expect(firstTaker(of: action, key: strip, main: strip) == nil)

        // A picker in front, the page still the strip's first responder.
        #expect(strip.makeFirstResponder(page))
        let picker = KeyableWindow()
        let field = Focusable(frame: .zero)
        picker.contentView?.addSubview(field)
        #expect(picker.makeFirstResponder(field))
        strip.reportsKey = false
        picker.reportsKey = true
        #expect(firstTaker(of: action, key: picker, main: strip) == nil,
                "⌘C in the picker copied from the page behind it")
    }

    @Test("from the menu, a strip command needs the strip's window to have the keyboard; app and Help commands do not")
    func menuReach() {
        for command in Command.allCases {
            let appLevel = command.menu == .app || command.menu == .help
            #expect(command.isAppLevel == appLevel, "\(command)")
            #expect(StripWindowController.menuMayReach(command, stripHasKeyboard: true), "\(command)")
            #expect(StripWindowController.menuMayReach(command, stripHasKeyboard: false) == appLevel,
                    "\(command) with a dialog in front")
        }
        // The ones that bit: ⌘W with the picker up closed the lane behind it.
        for command in [Command.closePane, .closeLane, .focusLeft, .nextAttention, .toggleGallery, .splitRight] {
            #expect(!StripWindowController.menuMayReach(command, stripHasKeyboard: false), "\(command)")
        }
        for command in [Command.showSettings, .showHelp, .showChangelog, .checkForUpdates] {
            #expect(StripWindowController.menuMayReach(command, stripHasKeyboard: false), "\(command)")
        }
    }
}
