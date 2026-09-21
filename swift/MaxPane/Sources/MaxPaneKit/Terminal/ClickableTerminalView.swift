import AppKit
import GhosttyTerminal

/// A terminal view that reports ⌘-clicks instead of passing them down.
///
/// Ghostty recognises its own hyperlinks — OSC 8, and URLs it matches in the
/// text — and those arrive through `TerminalSurfaceOpenURLDelegate`. What it
/// does not know about is a *file path*, which is most of what an agent
/// actually prints: `src/foo.ts:42:10`, a test that failed, a file it just
/// wrote. Those are the ones worth opening in the next lane.
///
/// ⌘-click rather than a plain click, because a plain click belongs to the
/// program: htop moves its cursor with it, vim positions the caret, and a
/// terminal that swallowed those to guess at paths would be worse at being a
/// terminal. ⌘-click is also what iTerm2 and Terminal.app use for the same
/// gesture, so it is already in the fingers.
@MainActor
final class ClickableTerminalView: TerminalView {
    /// A ⌘-click, in this view's coordinates.
    var onCommandClick: ((CGPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let handler = onCommandClick else {
            super.mouseDown(with: event)
            return
        }
        handler(convert(event.locationInWindow, from: nil))
    }

    /// A middle click, with whether ⌥ or ⇧ was down. True when the pane dealt
    /// with it (a paste, or deliberately nothing); false hands it to the
    /// emulator for a program that asked for the mouse. The decision is
    /// `TerminalPaste.middleClick`.
    var onMiddleClick: ((_ forced: Bool) -> Bool)?

    /// The press was dealt with here, so its release is not the program's
    /// either: a release with no press is a button event nobody asked for.
    private var middleClickTaken = false

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let handler = onMiddleClick,
              handler(!event.modifierFlags.isDisjoint(with: [.option, .shift]))
        else {
            super.otherMouseDown(with: event)
            return
        }
        middleClickTaken = true
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2, middleClickTaken {
            middleClickTaken = false
            return
        }
        super.otherMouseUp(with: event)
    }

    /// Tell Ghostty's surface whether it is focused, without moving the keyboard.
    ///
    /// The library reaches `ghostty_surface_set_focus` from its responder
    /// overrides and its window-key observers and from nowhere else, and its
    /// coordinator is internal. So a surface that was never first responder is
    /// never told anything, and Ghostty's surfaces are born believing they are
    /// focused: a fresh one answers `CSI ? 1004 h` with `CSI I`. Those two
    /// overrides are `super`, the surface call, and a SwiftUI bridge that is nil
    /// here; and `NSView`'s own do nothing but return true. Calling one
    /// directly is therefore the surface call alone: `window.firstResponder`
    /// is not touched, which is the point. `TerminalPaneController` is the
    /// only caller and decides the value. See `syncSurfaceFocus`.
    func tellSurface(focused: Bool) {
        _ = focused ? becomeFirstResponder() : resignFirstResponder()
    }

    /// Turn a point into a grid position.
    ///
    /// The cell size is worked back out of the grid rather than taken from the
    /// font, because the grid is the only thing both sides agree on: Ghostty
    /// reports columns and rows, and its resize callback carries a cell size of
    /// zero on the first report and then goes quiet while nothing changes.
    ///
    /// Dividing the text area by the column count overstates a cell by up to a
    /// rounding remainder, since Ghostty floored the division to get the count
    /// in the first place. The drift accumulates leftward-to-right and tops out
    /// near one cell at the far edge — which is why the caller expands the hit
    /// to word boundaries: being a character off inside `src/components/x.ts`
    /// still selects the path.
    static func cell(
        at point: CGPoint,
        columns: Int,
        rows: Int,
        viewSize: CGSize,
        padding: CGPoint
    ) -> (row: Int, column: Int)? {
        guard columns > 0, rows > 0 else { return nil }
        let textWidth = viewSize.width - padding.x * 2
        let textHeight = viewSize.height - padding.y * 2
        guard textWidth > 0, textHeight > 0 else { return nil }

        // AppKit's origin is bottom-left and the grid's is top-left.
        let x = point.x - padding.x
        let y = viewSize.height - point.y - padding.y
        guard x >= 0, y >= 0, x < textWidth, y < textHeight else { return nil }

        return (row: Int(y / (textHeight / CGFloat(rows))),
                column: Int(x / (textWidth / CGFloat(columns))))
    }
}
