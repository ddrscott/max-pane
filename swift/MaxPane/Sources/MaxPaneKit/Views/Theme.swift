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
