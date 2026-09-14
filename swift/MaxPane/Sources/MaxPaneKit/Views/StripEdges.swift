import AppKit
import LanedCore

/// What the two ends of the screen are allowed to look like.
///
/// The owner's report: *"The widths of the vertical panes seem too evenly
/// distributed. i can't tell if there are more panes to the right or left."*
/// The strip is a row of uniform columns, and uniform columns have exactly one
/// failure mode — when a whole number of them fits the window, the viewport
/// stops flush with a lane boundary and both edges go clean. A clean edge is
/// indistinguishable from the end of the strip, so a strip of twenty lanes and a
/// strip of three look the same from the middle of either.
///
/// Uniformity is not the bug and is not up for negotiation: *"a messy desk isn't
/// perfect, but pages on a desk are usually uniform."* Randomising widths would
/// answer the question by destroying the thing he asked for. What a desk
/// actually gives you is the *corner of the next page*, and that is a fact about
/// alignment, not about width.
///
/// So the evidence comes from two places, and they cover each other's gaps:
///
/// 1. **A sliver.** [`LanePeek`] moves the resting offset by at most
///    `lanePeekPt` so the screen never ends flush with a lane boundary while
///    lanes continue past it. Free, honest, and it is the lane itself — nothing
///    to learn.
/// 2. **A count.** A sliver cannot say *how many*, and at the ends of the strip
///    there is nothing to show a sliver of. [`StripEdgeRail`] puts a number on
///    each edge, and a solid wall when that direction is finished.
///
/// All of the arithmetic is here rather than in the view because it is where an
/// off-by-a-lane hides — the same reason `LaneSnap` was pulled out of
/// `StripViewController`.
enum StripEdges {
    /// A lane's place in the row: where it starts and how wide it is.
    struct Slot: Equatable {
        var origin: CGFloat
        var width: CGFloat
        var end: CGFloat { origin + width }
    }

    /// Less lane than this showing at an edge is not a sliver, it is a rounding
    /// error — a fraction of a point left over from a snap, or the lane's own
    /// 1 pt border. Everything here treats it as nothing, so that "flush" and
    /// "0.4 pt of the next lane" are the same case and get the same fix.
    static let hairline: CGFloat = 1

    /// Where each lane sits, in strip coordinates.
    ///
    /// `StripGeometry.origins` answers a different question — it keys by id and
    /// is used for *deltas* between two snapshots, where the border cancels out.
    /// The edges need the widths as well and need them in order, and they need
    /// the trailing border counted, because that is what the document view is
    /// actually sized to.
    static func slots(of lanes: [Lane]) -> [Slot] {
        var slots: [Slot] = []
        slots.reserveCapacity(lanes.count)
        var x: CGFloat = 0
        for lane in lanes {
            let width = CGFloat(lane.widthPt)
            slots.append(Slot(origin: x, width: width))
            x += width + Theme.borderWidth
        }
        return slots
    }

    /// The width of the whole strip, matching what `StripContentView` lays out —
    /// every lane plus the border that follows it.
    static func contentWidth(of lanes: [Lane]) -> CGFloat {
        lanes.reduce(0) { $0 + CGFloat($1.widthPt) + Theme.borderWidth }
    }

    /// How many lanes are entirely off each side of the viewport.
    ///
    /// "Entirely" is the point: a lane with a sliver showing is not hidden, it
    /// is the evidence. Counting it in the rail as well would say *2 more* about
    /// a strip where one of the two is already on screen.
    static func hidden(lanes: [Lane], offset: CGFloat, viewport: CGFloat) -> (left: Int, right: Int) {
        let slots = slots(of: lanes)
        let right = offset + viewport
        return (
            left: slots.filter { $0.end <= offset + hairline }.count,
            right: slots.filter { $0.origin >= right - hairline }.count)
    }
}

/// The rule that keeps a sliver on screen.
///
/// The invariant, stated once: **no edge of the screen is ever flush with a lane
/// boundary while the strip continues past it.** Every edge that has more behind
/// it is cutting through a lane, and a cut lane is a page with its corner
/// showing.
///
/// One degree of freedom — the scroll offset — against two edges, so the two
/// guarantees can in principle fight. In practice a single shift fixes both:
/// moving right by 28 pt to uncover the next lane moves the left edge 28 pt
/// *into* the lane it was flush with, which is the same evidence pointing the
/// other way. The scoring below exists for the case where that is not true — a
/// lane narrower than the peek itself — and makes it degrade to fixing the side
/// with more behind it rather than oscillating.
///
/// **Rejected: choosing a lane width that does not divide the window.** It is
/// the closest reading of *"a high unlikelihood of even full width
/// distribution"*, and it is wrong here for a reason that outlives the window:
/// a width is durable, per-lane state, and the window is neither. A width
/// picked against today's window is wrong the moment the window is resized, and
/// re-picking it would have to overwrite every width the user dragged — the one
/// thing this piece must not do. Phase is the free variable; width is not.
enum LanePeek {
    /// Nudge a resting offset until each edge that has lanes beyond it is
    /// cutting through one.
    ///
    /// Never moves more than `minimum` plus a border and a hairline, ever: a
    /// candidate is `want - shown` away from where it started, `want ≤ minimum`,
    /// and `shown` only goes negative by the gap between two lanes. That bound
    /// is the whole argument for doing this in the snap rather than in the
    /// layout — at 28 pt it is below the threshold where a settle reads as the
    /// strip arguing with you, and it is the same 28 pt whatever the window.
    ///
    /// An offset outside the strip is clamped rather than refused, and the
    /// clamp is not covered by that bound: a caller handing this an impossible
    /// scroll position gets a possible one back.
    static func adjust(
        offset: CGFloat, viewport: CGFloat, lanes: [Lane], minimum: CGFloat
    ) -> CGFloat {
        guard minimum > 0, !lanes.isEmpty, viewport > 0 else { return offset }
        let slots = StripEdges.slots(of: lanes)
        let limit = max(0, StripEdges.contentWidth(of: lanes) - viewport)
        // The whole strip fits: there is nothing beyond either edge to hint at,
        // and scrolling to prove it would be a lie.
        guard limit > 0 else { return offset }

        func clamped(_ x: CGFloat) -> CGFloat { min(max(0, x), limit) }
        let start = clamped(offset)

        var candidates: [CGFloat] = []
        if let r = rightward(from: start, viewport: viewport, slots: slots, minimum: minimum) {
            candidates.append(clamped(r))
        }
        if let l = leftward(from: start, slots: slots, minimum: minimum) {
            candidates.append(clamped(l))
        }

        // At either end of the strip, the end wins.
        //
        // Nudging right at offset 0 would hide the first 28 pt of the first lane
        // — and hide it *permanently*, because the snap would pull straight back
        // here every time the user scrolled left to look. Content you cannot
        // reach is a worse bug than the one this is fixing, and at a terminus
        // the rail is already saying, positively, that there is nothing that
        // way. Same in the mirror at the far end.
        if start <= 0 { candidates = candidates.filter { $0 <= start } }
        if start >= limit { candidates = candidates.filter { $0 >= start } }
        guard !candidates.isEmpty else { return start }

        // When both edges are flush — the exact-tiling case — only one of them
        // can be fixed. Take the side with more lanes hidden behind it, because
        // that is the side the user is more likely to be wrong about; a tie goes
        // rightward, where the strip grows and where ⌘T puts things.
        let hidden = StripEdges.hidden(lanes: lanes, offset: start, viewport: viewport)
        if hidden.left > hidden.right { candidates.reverse() }

        var best = start
        var bestScore = score(start, viewport: viewport, slots: slots, minimum: minimum)
        for candidate in candidates {
            let s = score(candidate, viewport: viewport, slots: slots, minimum: minimum)
            // Strictly greater, so the first candidate — the preferred side —
            // keeps a tie.
            if s > bestScore {
                best = candidate
                bestScore = s
            }
        }
        return best
    }

    /// How many of the two edges are telling the truth about what is past them.
    /// An edge with nothing beyond it counts as satisfied: the end of the strip
    /// is a fact, not a failure.
    private static func score(
        _ offset: CGFloat, viewport: CGFloat, slots: [StripEdges.Slot], minimum: CGFloat
    ) -> Int {
        var satisfied = 0
        if rightward(from: offset, viewport: viewport, slots: slots, minimum: minimum) == nil { satisfied += 1 }
        if leftward(from: offset, slots: slots, minimum: minimum) == nil { satisfied += 1 }
        return satisfied
    }

    /// The offset at which the right edge cuts `minimum` into the first lane it
    /// does not already clear — or nil if it already does, or if there is no
    /// such lane because this is the end of the strip.
    private static func rightward(
        from offset: CGFloat, viewport: CGFloat, slots: [StripEdges.Slot], minimum: CGFloat
    ) -> CGFloat? {
        let edge = offset + viewport
        // The first lane the edge does not clear. A lane the edge falls inside
        // is already cut, which is exactly the evidence wanted — the question is
        // only whether enough of it shows.
        guard let slot = slots.first(where: { $0.end > edge + StripEdges.hairline }) else { return nil }
        // A lane narrower than the peek can only ever show all of itself.
        let want = min(minimum, slot.width)
        let shown = edge - slot.origin
        guard shown < want - StripEdges.hairline else { return nil }
        return slot.origin + want - viewport
    }

    /// The mirror image, for the left edge: the last lane that starts before it.
    /// The sliver there is the *tail* of that lane.
    private static func leftward(
        from offset: CGFloat, slots: [StripEdges.Slot], minimum: CGFloat
    ) -> CGFloat? {
        guard let slot = slots.last(where: { $0.origin < offset - StripEdges.hairline }) else { return nil }
        let want = min(minimum, slot.width)
        let shown = slot.end - offset
        guard shown < want - StripEdges.hairline else { return nil }
        return slot.end - want
    }
}

/// A thin column at each end of the strip that says how much is past it.
///
/// It takes its 18 pt from the lanes rather than floating over them, and that is
/// deliberate: an overlay would sit on top of the sliver the snap works to keep,
/// which is the one thing on screen it must not cover.
///
/// Square, hairlined on the inner side, no fill of its own — it reads as the
/// wall of the window, not as a widget. The greens are spent on focus and
/// BLOCKED (see `Theme`) and a permanent green number at both edges would spend
/// it on something that is true all the time, so the count is plain text.
@MainActor
final class StripEdgeRail: NSView {
    enum Side { case leading, trailing }

    static let width: CGFloat = 18

    private let side: Side
    private let arrow = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    /// Nothing beyond this edge. Drawn as a filled wall, because "no number" is
    /// the absence of a signal and the end of the strip deserves a positive one.
    private var isTerminus = true

    init(side: Side) {
        self.side = side
        super.init(frame: .zero)
        wantsLayer = true

        arrow.stringValue = side == .leading ? "◀" : "▶"
        arrow.font = Theme.mono(9)
        arrow.textColor = Theme.dimText
        arrow.alignment = .center
        // 11, semibold: the count is the answer to the owner's actual question
        // and it is being read out of the corner of an eye. Two digits of 11 pt
        // mono is 13 pt wide, which still clears the 18 pt rail.
        count.font = Theme.mono(11, weight: .semibold)
        count.textColor = NSColor.labelColor
        count.alignment = .center

        let stack = NSStackView(views: [arrow, count])
        stack.orientation = .vertical
        stack.spacing = 3
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// `hidden` is how many lanes are entirely off this side.
    func update(hidden: Int) {
        let terminus = hidden <= 0
        // Only touch the tree when the answer changed: this runs on every
        // scroll event.
        guard terminus != isTerminus || count.stringValue != "\(hidden)" else { return }
        isTerminus = terminus
        count.stringValue = terminus ? "" : "\(hidden)"
        arrow.isHidden = terminus
        count.isHidden = terminus
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Theme.stripBackground.setFill()
        bounds.fill()

        // The wall: at the end of the strip the rail fills with the same colour
        // a lane's border uses, so "there is nothing that way" is something you
        // see rather than something you notice is missing.
        if isTerminus {
            // Measured against a dark lane, which is the hard case: at 0.55 the
            // wall was a shade of the same black and only showed up beside a
            // white page. 0.7 reads as a wall in both.
            Theme.laneBorder.withAlphaComponent(0.7).setFill()
            bounds.fill()
        }

        Theme.laneBorder.setFill()
        let inner = side == .leading ? bounds.maxX - Theme.borderWidth : 0
        NSRect(x: inner, y: 0, width: Theme.borderWidth, height: bounds.height).fill()
    }
}
