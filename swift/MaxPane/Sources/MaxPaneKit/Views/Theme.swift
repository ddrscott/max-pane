import AppKit

/// The look. Square corners, monospace, one accent.
///
/// PRD §3 rules out theming beyond a config file, so this is a small set of
/// constants rather than a theme engine. The rule that matters: no rounded
/// "bubble" cards and no single-edge colour rail on a rounded corner — a lane is
/// a column with a hard edge, and status is carried by content, not by a bent
/// stripe.
///
/// **One green family, no orange** (ADR-0015, `docs/decisions/0015-one-green-family.md`).
/// The owner's global signature is Signal Orange; this project overrides it on
/// his instruction, so do not "restore" it. Every highlight and every state is a
/// green, told apart by role and form rather than by hue:
///
/// - `working` — muted. A filled status square, a state chip, a moving rate.
/// - `accent` — mid. Focus outlines, default buttons, `//` slashes, the `$`
///   marker, selection, drop indicators, the cursor, the ⌘P flash.
/// - `blocked` — the loudest, filled, and pulsing (`BlockedPulse`).
///
/// Every colour is dynamic, one value per appearance. The dark values are the
/// ticket's; on a light ground those shades are unreadable (`#4ADE80` is 1.7:1 on
/// white), so light mode keeps the *order of loudness* — contrast and saturation
/// — rather than the order of lightness. Paint a layer with
/// `layerBackgroundColor` / `layerBorderColor`, never
/// `layer.backgroundColor = x.cgColor` — that is a snapshot of whichever mode
/// was current, and it stays wrong after a switch. See `Appearance`.
enum Theme {
    /// Mid green: `#22C55E` dark (7.5:1 on a lane), `#15773A` light (5.5:1 on a
    /// lane, 4.9:1 on the strip — `#15803D` was 4.4:1 there, under the bar).
    static let accent = green(dark: 0x22C55E, light: 0x15773A)

    /// Muted green: `#16A34A` dark (5.2:1), a greyed `#4D7C5F` light (4.7:1).
    static let working = green(dark: 0x16A34A, light: 0x4D7C5F)

    /// The brightest green: `#4ADE80` dark (9.8:1), and in light the strongest
    /// ink of the three, `#166534` (7.0:1). Always carried by a filled mark and,
    /// motion permitting, a slow pulse — see `BlockedPulse`.
    static let blocked = green(dark: 0x4ADE80, light: 0x166534)

    /// Text on a filled `blocked` mark: `#052E16` on `#4ADE80` is 8.6:1, white on
    /// `#166534` is 7.1:1.
    static let onBlocked = green(dark: 0x052E16, light: 0xFFFFFF)

    /// Alive and quiet: a running session with nothing to say. Quieter than
    /// `working`, so a session actually producing output still reads louder.
    static let alive = green(dark: 0x2E8C4F, light: 0x6B9A7A)

    /// The one colour outside the green family that marks a state: DONE, the
    /// agent finished and is waiting to be read. Signal Orange, dark
    /// (5.0:1 on a lane), a deeper cut of it light (5.1:1 on white). Orange because in
    /// a gallery of ten green-or-grey lanes the ones that need a decision
    /// have to be findable without reading a word.
    static let done = green(dark: 0xE85D00, light: 0xB84800)

    /// A remote server's colour (ADR-0025): identity, never state.
    ///
    /// The one exception to the green family, and a bounded one. It is drawn
    /// only by `ServerMark` (the small square), by `ServerChip`'s outline and
    /// text, and by the `//` of that server's sidebar section; never on a
    /// status square, a state chip, a focus outline, a lane border or a
    /// terminal. `slate` is the at-rest grey the chip had before servers had
    /// colours. Every other value is at least ΔE 40 (CIE76) from each green
    /// and from DONE's orange, and ΔE 25 from each of the others, in both
    /// appearances; `ServerColourTests` holds those numbers, and 4.5:1 on a
    /// lane and on the strip, because the chip's name is text in this colour.
    static func server(_ colour: ServerColour) -> NSColor {
        guard let hex = serverPalette[colour] else { return dimText }
        return green(dark: hex.dark, light: hex.light)
    }

    /// `slate` has no entry: it is `dimText`, whatever the system says grey is.
    static let serverPalette: [ServerColour: (dark: UInt32, light: UInt32)] = [
        .cyan: (0x22D3EE, 0x006BA0),
        .blue: (0x60A5FA, 0x1D4ED8),
        .violet: (0x9F85FF, 0x6D28D9),
        .magenta: (0xF06BE0, 0xB5179E),
        .rose: (0xFB7185, 0xBE185D),
        .lemon: (0xFDE047, 0x7A6200),
        .ink: (0xF4F4F5, 0x18181B),
    ]

    private static func green(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
        }
    }

    static let laneBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.11, alpha: 1)
            : NSColor(white: 0.99, alpha: 1)
    }

    static let laneBorder = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1)
            : NSColor(white: 0.85, alpha: 1)
    }

    static let stripBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.07, alpha: 1)
            : NSColor(white: 0.94, alpha: 1)
    }

    static let dimText = NSColor.secondaryLabelColor

    /// The rule down an overlay dock's inner edge.
    ///
    /// Stronger than `laneBorder` on purpose: a lane boundary separates two
    /// things at the same depth, and this one separates a thing in front from a
    /// thing behind. Same hue, more of it — the difference is legible without
    /// spending a colour, and the greens stay on focus and state where a dock
    /// that is on screen all day would have drowned them.
    static let dockEdge = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.40, alpha: 1)
            : NSColor(white: 0.62, alpha: 1)
    }

    /// 2pt: one point reads as a lane border, which is the one thing this must
    /// not be mistaken for.
    static let dockEdgeWidth: CGFloat = 2

    /// 1pt, square. Lanes are columns, not cards.
    static let borderWidth: CGFloat = 1
    static let laneHeaderHeight: CGFloat = 28

    /// The one text-field look: no bezel, one hard border, square.
    ///
    /// `NSSearchField` is a rounded capsule with no square variant, and even a
    /// square-bezelled `NSTextField` draws lighter system chrome with rounded
    /// corners — the sidebar's filter box found that first, and the popups'
    /// fields found it again in a render sheet. `ground` is whatever sets the
    /// field apart from what it sits on: the lane's ground on the sidebar, the
    /// strip's inside a popup.
    ///
    /// It swaps in `SquareFieldCell`, so call it before setting a value or a
    /// placeholder — a new cell starts empty. `height`, when given, is fixed;
    /// without it the field is as tall as its text plus the cell's inset.
    @MainActor
    static func squareField(
        _ field: NSTextField, font: NSFont, ground: NSColor = Theme.stripBackground, height: CGFloat? = nil
    ) {
        let cell = SquareFieldCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        cell.usesSingleLineMode = true
        field.cell = cell
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = ground
        field.wantsLayer = true
        // The whole field, not just the text: the cell paints its ground inside its
        // inset only, which left a lighter ring between the text and the border.
        field.layerBackgroundColor = ground
        field.layer?.cornerRadius = 0
        field.layer?.borderWidth = Theme.borderWidth
        field.layerBorderColor = Theme.laneBorder
        field.font = font
        field.focusRingType = .none
        if let height { field.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The colour of an agent-state chip.
    ///
    /// Three greens that stay tellable apart because they differ in more than
    /// shade: focus (`accent`) is an *outline* around a pane, working a muted
    /// *filled* square, BLOCKED the loudest, filled and *moving*. RelayTTY draws
    /// BLOCKED in orange; this app does not follow it there. DONE stays slate
    /// and EXITED dim, so neither competes with the greens.
    static func agentStateColor(_ state: AgentState) -> NSColor {
        switch state {
        case .blocked: return blocked
        case .working: return working
        case .done: return done
        case .exited: return dimText
        case .idle, .unknown: return .clear
        }
    }

    /// The kind glyph used in the sidebar and on lane headers (PRD §7.6).
    static func glyph(for kind: PaneGlyph) -> String {
        switch kind {
        case .pty: return "$"
        case .web: return "◍"
        case .placeholder: return "◌"
        }
    }
}

enum PaneGlyph { case pty, web, placeholder }

/// A text field cell with room inside its border.
///
/// A borderless `NSTextField` draws its text against its own edge, which is fine
/// with no border and cramped with one: the tag prompt's path sat on the very
/// line that framed it. The inset is applied to every rect the cell hands AppKit
/// — drawing, editing and selecting — so the caret and a selection land exactly
/// where the text is drawn, and the text is centred vertically in a field taller
/// than one line.
final class SquareFieldCell: NSTextFieldCell {
    /// Inside the border, either side.
    static let inset: CGFloat = 6

    private func inner(_ rect: NSRect) -> NSRect {
        var inner = rect.insetBy(dx: Self.inset, dy: 0)
        let line = super.cellSize(forBounds: rect).height
        if line < rect.height {
            inner.origin.y += ((rect.height - line) / 2).rounded(.down)
            inner.size.height = line
        }
        return inner
    }

    override func cellSize(forBounds rect: NSRect) -> NSSize {
        var size = super.cellSize(forBounds: rect)
        size.width += 2 * Self.inset
        size.height += 4
        return size
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        super.drawingRect(forBounds: inner(rect))
    }

    override func edit(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?
    ) {
        super.edit(withFrame: inner(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(
        withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?,
        start selStart: Int, length selLength: Int
    ) {
        super.select(
            withFrame: inner(rect), in: controlView, editor: textObj, delegate: delegate,
            start: selStart, length: selLength)
    }
}
