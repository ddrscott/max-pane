import AppKit

/// The look. Square corners, monospace, one accent.
///
/// PRD §3 rules out theming beyond a config file, so this is a small set of
/// constants rather than a theme engine. The rule that matters: no rounded
/// "bubble" cards and no single-edge colour rail on a rounded corner — a lane is
/// a column with a hard edge, and status is carried by content, not by a bent
/// stripe.
enum Theme {
    static let accent = NSColor(srgbRed: 0xE8 / 255, green: 0x5D / 255, blue: 0x00 / 255, alpha: 1)

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
    /// spending a second colour, and Signal Orange stays on focus and BLOCKED
    /// where a dock that is on screen all day would have drowned it.
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
        field.layer?.backgroundColor = ground.cgColor
        field.layer?.cornerRadius = 0
        field.layer?.borderWidth = Theme.borderWidth
        field.layer?.borderColor = Theme.laneBorder.cgColor
        field.font = font
        field.focusRingType = .none
        if let height { field.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// Throughput and other "this is moving" readouts.
    ///
    /// Green, not the accent. Signal Orange has to mean one thing — *this one
    /// needs you* — and a strip of ten lanes where the byte counters are all
    /// orange is a strip where BLOCKED arrives and changes nothing. The accent
    /// is now spent on exactly two things: focus, and blocked. They are told
    /// apart by form, not hue — focus is a hairline around a column, blocked is
    /// a filled chip inside it.
    static let flowing = NSColor(srgbRed: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255, alpha: 1)

    /// The colour of an agent-state chip.
    ///
    /// RelayTTY renders BLOCKED in `#E85D00` — which is, by coincidence or good
    /// taste, exactly Signal Orange. So the most important signal in the app
    /// already arrives in the house accent, and the other two stay muted so it
    /// keeps that meaning.
    static func agentStateColor(_ state: AgentState) -> NSColor {
        switch state {
        case .blocked: return accent
        case .working: return NSColor(srgbRed: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255, alpha: 1)
        case .done: return NSColor(srgbRed: 0x94 / 255, green: 0xa3 / 255, blue: 0xb8 / 255, alpha: 1)
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
