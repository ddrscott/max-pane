import AppKit
import LanedCore

/// `s | m | xl`: three absolute sizes a lane can be put at with one click.
///
/// The owner, pointing at `../wiz-term`: *"make 'xl' the double wide standard
/// font size, 'm' phone width standard font size, and 's' smaller 60% font size
/// but compute the columns to be the same number and adjust the width to fit the
/// new number of columns."* wiz-term's `s` changed the font and the width
/// independently, so its column count moved; this one does not.
///
/// | | terminal | web |
/// |---|---|---|
/// | **m** | `laneDefaultPt`, 100% — 80 columns at 13 pt | `laneDefaultPt`, 100% |
/// | **s** | the same columns at 60% font, width *computed* to hold them | 60% of m's width at the zoom that keeps `innerWidth` |
/// | **xl** | twice `laneDefaultPt`, span 2, 100% | the same |
///
/// Absolute, not relative to where the lane is now, and never stored: the lit
/// preset is *derived* from width, span and zoom, which the ledger already
/// keeps, so there is no second copy to disagree with them.
///
/// A docked lane takes the same presets on its *dock* width, clamped into the
/// dock's bounds (`DockGeometry.minPt`...`maxPt`), so `xl` on a dock is 900 pt.
/// Its strip width and span are left for when it goes back.
enum LaneSizePreset: String, CaseIterable, Sendable {
    case s, m, xl

    /// `s`'s font, as a fraction of the configured size.
    static let smallScale: Double = 0.6

    /// What a lane looks like at a preset.
    struct Shape: Equatable {
        var widthPt: UInt32
        var span: UInt32
        /// A terminal pane's zoom: a font size.
        var terminalZoom: Double
        /// A web pane's zoom: a page zoom.
        var webZoom: Double

        /// The zoom a pane of `kind` takes.
        func zoom(for kind: PaneKind) -> Double {
            kind == .pty ? terminalZoom : webZoom
        }
    }

    var title: String {
        switch self {
        case .s: return "Small"
        case .m: return "Medium"
        case .xl: return "Extra Large"
        }
    }

    var command: Command {
        switch self {
        case .s: return .laneSizeSmall
        case .m: return .laneSizeMedium
        case .xl: return .laneSizeLarge
        }
    }

    /// ⌘\: s → m → xl → s. A lane off every preset — dragged, zoomed, or left
    /// at 1800 pt by the Span Lane command this replaced — goes to `m`.
    static func next(after current: LaneSizePreset?) -> LaneSizePreset {
        switch current {
        case .s: return .m
        case .m: return .xl
        case .xl: return .s
        case nil: return .m
        }
    }

    /// The shape of a lane at this preset.
    ///
    /// `docked` clamps the width into the dock's bounds; `span` is then
    /// meaningless (a dock has none) and is not compared.
    ///
    /// `hasTerminal` decides `s`'s width. A terminal needs its columns to fit
    /// exactly, so a lane with one is as wide as those columns at the smaller
    /// cell; a lane of pages alone is 60% of `m`. Either way a web pane's zoom
    /// is width ÷ `laneDefaultPt`, which is what makes the page's `innerWidth`
    /// the one it had at `m` — in a split lane beside a terminal too.
    @MainActor
    static func shape(
        _ preset: LaneSizePreset, hasTerminal: Bool, config: Config, backingScale: CGFloat,
        docked: Bool = false
    ) -> Shape {
        let strip = stripShape(preset, hasTerminal: hasTerminal, config: config, backingScale: backingScale)
        guard docked else { return strip }
        let width = min(max(strip.widthPt, UInt32(DockGeometry.minPt)), UInt32(DockGeometry.maxPt))
        guard width != strip.widthPt else { return strip }
        // Only `s` scales a page, and its zoom is what keeps m's `innerWidth` in
        // whatever width the lane really gets.
        let webZoom = preset == .s ? Double(width) / Double(max(config.laneDefaultPt, 1)) : strip.webZoom
        return Shape(widthPt: width, span: strip.span, terminalZoom: strip.terminalZoom, webZoom: webZoom)
    }

    @MainActor
    private static func stripShape(
        _ preset: LaneSizePreset, hasTerminal: Bool, config: Config, backingScale: CGFloat
    ) -> Shape {
        let base = config.laneDefaultPt
        switch preset {
        case .m:
            return Shape(widthPt: base, span: 1, terminalZoom: 1, webZoom: 1)
        case .xl:
            return Shape(widthPt: base * 2, span: 2, terminalZoom: 1, webZoom: 1)
        case .s:
            let width = hasTerminal
                ? terminalSmallWidth(config: config, backingScale: backingScale)
                : webSmallWidth(config: config)
            return Shape(
                widthPt: width, span: 1, terminalZoom: smallScale,
                webZoom: Double(width) / Double(max(base, 1)))
        }
    }

    /// The preset a lane is at, or nil when it has been dragged or zoomed off
    /// every one of them. A docked lane is asked about its dock's width.
    ///
    /// `zoom` is asked per pane rather than read off the snapshot, because a
    /// pane's zoom is written without publishing one (`StripStore.setPaneZoom`)
    /// and the switch has to go dark the moment ⌘= moves a pane off its preset.
    /// Placeholders are skipped: they draw nothing a zoom applies to.
    @MainActor
    static func current(
        of lane: Lane, zoom: (Pane) -> Double, config: Config, backingScale: CGFloat
    ) -> LaneSizePreset? {
        let panes = lane.panes.filter { $0.kind != .placeholder }
        let hasTerminal = panes.contains { $0.kind == .pty }
        let dock = lane.dock
        return allCases.first { preset in
            let shape = shape(
                preset, hasTerminal: hasTerminal, config: config, backingScale: backingScale, docked: dock != nil)
            return (dock != nil || lane.span == shape.span)
                && (dock?.widthPt ?? lane.widthPt) == shape.widthPt
                && panes.allSatisfy { abs(zoom($0) - shape.zoom(for: $0.kind)) < 0.005 }
        }
    }

    // MARK: - the arithmetic

    /// `s`'s width for a terminal lane: exactly the columns `m` holds, at the
    /// cell the 60% font really has.
    ///
    /// Not `0.6 × laneDefaultPt`. Ghostty's cells are whole pixels, so 60% of an
    /// 8 pt cell is not 4.8 pt: it is 5 pt on a 1× panel (4.68 px rounds up) and
    /// 4.5 pt on Retina (9.36 px rounds down). 80 of the first is 16 pt wider than
    /// the naive figure — three columns lost — and 80 of the second is 12 pt
    /// narrower, which would hand the lane columns it never had at `m`.
    @MainActor
    static func terminalSmallWidth(config: Config, backingScale: CGFloat) -> UInt32 {
        let padding = 2 * TerminalPaneController.terminalPadding.x
        let full = cellWidth(fontName: config.fontName, fontSize: config.fontSize, backingScale: backingScale)
        let small = cellWidth(
            fontName: config.fontName, fontSize: config.fontSize * smallScale, backingScale: backingScale)
        let columns = columns(inWidth: CGFloat(config.laneDefaultPt), cellWidth: full)
        return UInt32((padding + CGFloat(columns) * small).rounded(.up))
    }

    /// `s`'s width for a lane of pages: 60% of `m`, to the nearest point.
    static func webSmallWidth(config: Config) -> UInt32 {
        UInt32((Double(config.laneDefaultPt) * smallScale).rounded())
    }

    /// How many columns a terminal pane `width` points wide shows, the way
    /// Ghostty counts them: what is left inside the padding, in whole cells.
    @MainActor
    static func columns(inWidth width: CGFloat, cellWidth: CGFloat) -> Int {
        let inside = width - 2 * TerminalPaneController.terminalPadding.x
        guard cellWidth > 0, inside > 0 else { return 0 }
        // A hair of tolerance, so a width computed to hold N cells exactly is not
        // read back as N − 1 by a rounding error in the last decimal place.
        return Int((inside / cellWidth + 0.0001).rounded(.down))
    }

    /// Ghostty's cell width, in points, for `fontName` at `fontSize` on a
    /// display of `backingScale`.
    ///
    /// Ghostty takes the widest printable ASCII advance at the font's *pixel*
    /// size and rounds it to the nearest whole pixel, so the cell is a whole
    /// number of device pixels and the answer depends on the panel. Measured the
    /// same way here and checked against real surfaces (`LaneSizePresetTests`):
    /// at 1× a 10.4 pt font draws 6 px cells, not the 7 that rounding *up* would
    /// give.
    ///
    /// One trap, found by that test. When `fontName` is not installed Ghostty
    /// does not fall back to the system monospace the way `NSFont` would — it
    /// draws with the JetBrains Mono it carries inside itself, whose advance is
    /// 0.6 em. Measuring SF Mono instead put `s` at 367 pt and cost nine columns.
    static func cellWidth(fontName: String, fontSize: Double, backingScale: CGFloat) -> CGFloat {
        let scale = max(backingScale, 1)
        let pixels = CGFloat(fontSize) * scale
        let widest: CGFloat
        if let installed = NSFont(name: fontName, size: pixels) {
            let font = installed as CTFont
            var characters = (32...126).map { UniChar($0) }
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
            let present = glyphs.filter { $0 != 0 }
            var advances = [CGSize](repeating: .zero, count: present.count)
            CTFontGetAdvancesForGlyphs(font, .horizontal, present, &advances, present.count)
            widest = advances.map(\.width).max() ?? pixels * Self.builtInAdvance
        } else {
            widest = pixels * Self.builtInAdvance
        }
        return max(1, widest.rounded(.toNearestOrAwayFromZero)) / scale
    }

    /// The advance of Ghostty's built-in face, JetBrains Mono: 600 units of 1000.
    static let builtInAdvance: CGFloat = 0.6
}
