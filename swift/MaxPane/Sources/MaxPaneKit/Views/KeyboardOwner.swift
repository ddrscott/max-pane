import AppKit
import ObjectiveC

/// Whether the keyboard is in `view`: its window is the key window, and that
/// window's first responder is `view` itself or something inside it.
///
/// The one question a pane asks before it takes an Edit-menu action routed to
/// it (`TerminalPasteTarget`, `TerminalCopyTarget`, `WebCopyTarget`). The
/// window clause is the half that was missing. AppKit answers a nil-targeted
/// action by searching the key window's responder chain and then the **main**
/// window's, so with the ⌘O picker in front — a key panel over the strip — a
/// ⌘V that the picker's field did not claim went on to the strip window, whose
/// first responder was still the terminal, and the terminal took it. The strip
/// window's first responder does not change when a panel takes the keyboard;
/// only which window is key does. See ADR-0045.
@MainActor
func keyboardIsIn(_ view: NSView?) -> Bool {
    guard let view, let window = view.window, window.isKeyWindow,
          let first = window.firstResponder as? NSView else { return false }
    return first === view || first.isDescendant(of: view)
}

/// Whether `selector` is a required instance method of `routed`. Lets a pane
/// container recognise its routed actions by protocol, so a method added to the
/// protocol later is covered without a list of selectors to keep in step.
nonisolated func isRoutedAction(_ selector: Selector, of routed: Protocol) -> Bool {
    protocol_getMethodDescription(routed, selector, true, true).name != nil
}
