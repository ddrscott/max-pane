import AppKit
import LanedCore

/// How much of the window the docks take, once the window has had its say.
///
/// Pulled out of the view for the same reason `LaneSnap` and `LanePeek` were:
/// it is all arithmetic, it is where an off-by-a-dock hides, and the case that
/// matters most — a window too narrow to afford two docks — is one nobody will
/// reproduce by hand often enough to trust a screenshot of it.
///
/// **The view clamps and never writes the clamp back.** A dock dragged to
/// 500 pt is 500 pt; opening it in an 800 pt window narrows what is *drawn* and
/// leaves the ledger alone, so it is 500 again the moment the window grows.
/// ADR-0007 settled the same rule for lanes and session sizes, and the failure
/// it prevents is the one where a laptop screen permanently rewrites a layout
/// built on a desk monitor.
enum DockGeometry {
    /// Mirrors `DOCK_MIN_PT` / `DOCK_MAX_PT` in `laned-core/src/lib.rs`.
    ///
    /// Duplicated rather than sent over the FFI because these are the bounds
    /// the *layout* argues with, and the layout has to answer "can this window
    /// afford a dock at all" without a ledger call on every resize. The core
    /// clamps what it stores; this clamps what it draws, and neither is allowed
    /// to overwrite the other.
    static let minPt: CGFloat = 240
    static let maxPt: CGFloat = 900

    /// The narrowest strip an overlay is allowed to leave showing.
    ///
    /// A judgement, not a measurement, and a deliberately smaller one than
    /// `laneMinPt`: overlay's whole claim is that the lane underneath is still
    /// *there* and still moving, and this is how much of it has to stay visible
    /// for that claim to be checkable by eye. Below this an overlay is a window
    /// with a dock in it, which is a different app.
    static let stripFloorPt: CGFloat = 160

    /// One dock, as it will actually be drawn.
    struct Placement: Equatable {
        /// Points, already clamped against the window.
        var width: CGFloat
        /// What this dock does to the strip **right now** — not necessarily
        /// what the ledger says. An inset dock the window cannot afford is
        /// drawn as an overlay until the window grows.
        var mode: DockMode
    }

    /// Both edges, resolved.
    struct Layout: Equatable {
        var left: Placement?
        var right: Placement?

        static let none = Layout(left: nil, right: nil)

        var isEmpty: Bool { left == nil && right == nil }

        /// Room taken *out of* the strip's viewport, per edge. The clip view is
        /// made genuinely this much narrower, so nothing downstream subtracts.
        var insetLeft: CGFloat { width(of: left, mode: .inset) }
        var insetRight: CGFloat { width(of: right, mode: .inset) }

        /// Room drawn *over* the strip, per edge. The strip keeps its width and
        /// scrolls underneath; what shrinks is how much of it can be seen.
        var overlayLeft: CGFloat { width(of: left, mode: .overlay) }
        var overlayRight: CGFloat { width(of: right, mode: .overlay) }

        private func width(of placement: Placement?, mode: DockMode) -> CGFloat {
            guard let placement, placement.mode == mode else { return 0 }
            return placement.width
        }
    }

    /// Resolve what the ledger asked for against the window there actually is.
    ///
    /// `viewport` is the room the strip and the docks share — the window less
    /// the edge rails, which sit outside both (see `StripViewController`).
    ///
    /// The degradation rule, in one sentence: **an inset dock that cannot leave
    /// a readable lane beside it floats instead.** Overlay costs occlusion,
    /// which is visible and recoverable and which the rails and the peek now
    /// count; an inset dock in an 800 pt window costs a strip too narrow to
    /// read a lane in, which is neither.
    ///
    /// Both inset docks share one `share`, so *which* of them degrades never
    /// depends on the order they are considered in — with two of them the
    /// answer is the same for both, which is what makes "under about 900 pt,
    /// both float" a sentence rather than a coin toss.
    static func resolve(
        left: Dock?, right: Dock?, viewport: CGFloat, laneMinPt: CGFloat
    ) -> Layout {
        let docks = [left, right]
        let insetCount = docks.compactMap { $0 }.filter { $0.mode == .inset }.count
        let share = insetCount > 0
            ? (viewport - laneMinPt) / CGFloat(insetCount)
            : 0
        let insetAffordable = share >= minPt

        func wanted(_ dock: Dock) -> CGFloat {
            min(max(CGFloat(dock.widthPt), minPt), maxPt)
        }

        // Pass one: the inset docks, which get first claim because they are the
        // mode that promises nothing is hidden.
        var insetTotal: CGFloat = 0
        var overlayCount = 0
        for dock in docks.compactMap({ $0 }) {
            if dock.mode == .inset && insetAffordable {
                insetTotal += min(wanted(dock), share)
            } else {
                overlayCount += 1
            }
        }

        // Pass two: what is left over, shared by whatever is floating. An
        // overlay narrower than `minPt` is accepted rather than refused — there
        // is nothing else to give, and a dock you can still see is a better
        // answer than a window with no strip in it.
        let overlayShare = overlayCount > 0
            ? max(0, viewport - insetTotal - stripFloorPt) / CGFloat(overlayCount)
            : 0

        func place(_ dock: Dock?) -> Placement? {
            guard let dock else { return nil }
            if dock.mode == .inset && insetAffordable {
                return Placement(width: min(wanted(dock), share), mode: .inset)
            }
            return Placement(width: min(wanted(dock), overlayShare), mode: .overlay)
        }

        return Layout(left: place(left), right: place(right))
    }

    /// The strip's visible window, in the document's own coordinates.
    ///
    /// Inset is already gone from `clipWidth` — the clip view was made
    /// narrower, which is the whole of contract position 1 — so only the
    /// overlays are subtracted here, and they are subtracted in exactly one
    /// place. Everything downstream (`LaneSnap`, `LanePeek`, `StripEdges`,
    /// `StripReveal`, the materialisation window, the eviction `Viewport`)
    /// takes an offset and a width and needs to know nothing about docks.
    ///
    /// That is the argument with the contract's position 2, and it is an
    /// argument about *where*, not *whether*: an overlay does count as an edge,
    /// and it counts because the strip's visible window genuinely stops there —
    /// not because `LanePeek` was taught a special case for it.
    static func visible(
        clipOffset: CGFloat, clipWidth: CGFloat, layout: Layout
    ) -> (offset: CGFloat, width: CGFloat) {
        (offset: clipOffset + layout.overlayLeft,
         width: max(0, clipWidth - layout.overlayLeft - layout.overlayRight))
    }
}

/// The shadow an overlay dock casts on the strip it covers.
///
/// Drawn rather than set as `CALayer.shadowOpacity`, which produced nothing at
/// all here — measured, not assumed: the pixels immediately right of a floating
/// dock's edge came back flat at the page's own `#f0f0f0` with no ramp. Rather
/// than work out which of AppKit's layer-backing rules ate it, the strip draws
/// the fourteen points itself, where a screenshot can check it.
///
/// It is a sibling of the dock and lands *outside* it, which is why it is the
/// strip's to own: a shadow drawn inside the dock's own bounds would be a
/// gradient at the edge of a page, which is a completely different thing to
/// look at.
@MainActor
final class DockShadowView: NSView {
    static let width: CGFloat = 14

    var edge: DockSide = .left {
        didSet {
            guard edge != oldValue else { return }
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Black rather than a tinted colour: this is depth, and depth is the
        // absence of light in both appearances. 0.30 is enough to read against
        // a white page and not enough to look like a border on a dark one.
        guard let gradient = NSGradient(
            colors: [NSColor.black.withAlphaComponent(0.30), NSColor.black.withAlphaComponent(0)])
        else { return }
        // Angle 0 runs left to right, so a dock on the left casts to the right.
        gradient.draw(in: bounds, angle: edge == .left ? 0 : 180)
    }

    /// The strip underneath keeps the clicks. A shadow that swallowed a
    /// mouse-down would be fourteen points of lane you cannot focus, for no
    /// reason the user could ever see.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
