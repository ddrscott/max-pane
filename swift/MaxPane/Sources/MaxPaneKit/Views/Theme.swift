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

    /// 1pt, square. Lanes are columns, not cards.
    static let borderWidth: CGFloat = 1
    static let laneHeaderHeight: CGFloat = 28

    static func mono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: "JetBrains Mono", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
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
