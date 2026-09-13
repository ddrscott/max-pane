import AppKit

/// Lucide icons, as `NSImage`s the views can drop in.
///
/// `NSImage` reads SVG natively — the representation comes back as
/// `_NSSVGImageRep` and draws at whatever size it is asked for — so the icons
/// stay sharp on any display without shipping @1x/@2x pairs. The SVG source is
/// embedded in `LucideIcon` rather than living in a resource bundle; see
/// `scripts/gen-icons.py` for why.
///
/// Every icon is a **template** image: the SVG's own black stroke supplies the
/// shape through the alpha channel, and the colour comes from the caller. That
/// is what lets one globe be dim in a closed row, full strength in a live one,
/// and accent-coloured in a selected one without three files.
@MainActor
enum IconImage {
    /// Rendering an SVG is not free and a table redraws its rows constantly, so
    /// the result is kept. Keyed by everything that changes the pixels.
    private struct Key: Hashable {
        let icon: LucideIcon
        let points: CGFloat
        let colour: String
    }

    private static var cache: [Key: NSImage] = [:]

    /// `icon` at `points` square, stroked in `colour`.
    ///
    /// `@MainActor` on the enum, so the cache needs no lock: every caller is a
    /// view, and Swift 6 will not let that assumption stay implicit.
    static func make(_ icon: LucideIcon, points: CGFloat, colour: NSColor) -> NSImage? {
        let key = Key(icon: icon, points: points, colour: colour.description)
        if let hit = cache[key] { return hit }

        guard let data = icon.svg.data(using: .utf8),
              let source = NSImage(data: data)
        else { return nil }

        let size = NSSize(width: points, height: points)
        let out = NSImage(size: size)
        out.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        // `.sourceAtop` paints the colour only where the stroke already put
        // pixels, which is the whole trick: the SVG decides the shape and the
        // caller decides the ink.
        colour.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        out.unlockFocus()

        cache[key] = out
        return out
    }

    /// Only for the tests, which would otherwise measure each other's cache.
    static func resetCacheForTesting() { cache.removeAll() }
}
