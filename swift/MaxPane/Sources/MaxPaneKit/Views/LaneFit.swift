import AppKit
import LanedCore

/// How wide a lane is *drawn*: its own width, or the room the window has left
/// for it, whichever is smaller (ADR-0047).
///
/// A lane's width in the ledger — `width_pt`, set by a preset, a drag or
/// ⌃⌘= — is a **maximum**. On a small window, a half-screen split or beside a
/// dock, an `m` or `xl` lane used to run off the edge, so half a terminal was
/// always one scroll away. Now it fits the room there is, and when the room
/// comes back it is back at its own size, because nothing about the lane was
/// ever changed: this is arithmetic on a copy the strip lays out, never a
/// write. A relaunch, a wider window or a closed dock brings the real size
/// back with nothing to remember.
///
/// Pure, so the rule is testable without a window.
enum LaneFit {
    /// The narrowest the room is ever taken to be. A window can be dragged
    /// smaller than any lane is useful at, and a zero-width lane is a terminal
    /// with no columns — so below this the lane keeps this width and the strip
    /// scrolls, as it always did.
    static let floorPt: CGFloat = 160

    /// The width a lane may take on a strip `viewport` wide, the visible part
    /// with docks already off it.
    ///
    /// With neighbours, less a peek on each side: a lane exactly as wide as
    /// the window leaves nothing to click to get to the next one, and the
    /// carousel (`StripReveal.isCarousel`) is built on the slivers either side
    /// of a centred lane. Alone, the whole viewport.
    ///
    /// Infinite when the viewport is not known yet — the first pass, before
    /// the window has a size — so nothing is clamped against a zero.
    static func room(viewport: CGFloat, laneCount: Int, peek: CGFloat) -> CGFloat {
        guard viewport > 0 else { return .infinity }
        let peeks = laneCount > 1 ? max(0, peek) * 2 : 0
        return max(floorPt, (viewport - peeks).rounded(.down))
    }

    /// The width `lane` is drawn at, in `room`.
    static func width(of lane: Lane, room: CGFloat) -> CGFloat {
        min(CGFloat(lane.widthPt), room)
    }

    /// `lanes` as the strip draws them: every one no wider than `room`. Same
    /// lanes, same order, same count, so every index into the ledger's list
    /// is still an index into this one. Nothing narrower than the room moves,
    /// and nothing ever grows past its own width.
    static func fit(_ lanes: [Lane], room: CGFloat) -> [Lane] {
        guard room.isFinite, lanes.contains(where: { CGFloat($0.widthPt) > room }) else { return lanes }
        let cap = UInt32(max(0, room))
        return lanes.map { lane in
            guard lane.widthPt > cap else { return lane }
            var fitted = lane
            fitted.widthPt = cap
            return fitted
        }
    }

    /// Whether two rooms draw `lanes` differently — the only case a change of
    /// room is worth a frame of motion.
    static func differs(_ lanes: [Lane], _ a: CGFloat, _ b: CGFloat) -> Bool {
        lanes.contains { width(of: $0, room: a) != width(of: $0, room: b) }
    }
}
