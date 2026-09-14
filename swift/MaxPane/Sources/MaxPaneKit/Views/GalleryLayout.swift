import CoreGraphics
import QuartzCore

/// Where every lane goes when the whole strip is on one screen.
///
/// All arithmetic, no views, so the one rule the gallery is built on can be
/// tested on its own: **a tile is its lane drawn smaller, never re-flowed.** One
/// scale for every tile, applied to the width and height the lane already has on
/// the strip — so a lane spanned to twice the width is a tile twice as wide, a
/// stack keeps its proportions, and nothing inside a lane is ever told it got
/// smaller. [Spike M5](../../../../../docs/spikes/05-gallery-scale.md) is why it
/// has to be a scale: a terminal given fewer pixels re-derives its grid, and a
/// grid that changes is a `RESIZE` on the phone too (ADR-0007).
///
/// The scale is the largest one at which every lane fits with nothing scrolled
/// and nothing cropped, capped at the lane's real size. It is recomputed from
/// scratch whenever a lane comes, goes, changes width, or the window resizes —
/// there are no steppers, because "how big" has exactly one right answer.
enum GalleryLayout {
    /// Between tiles, and between the tiles and the edge of the gallery.
    static let gap: CGFloat = 10

    /// Where a tile goes when it is expanded in place.
    ///
    /// Relay TTY's rule, which the owner asked for by name: grow from the
    /// tile's own centre to the lane's real size, then slide inward only as far
    /// as the gallery's edges demand. The lane is never drawn bigger than it
    /// is, and a lane taller or wider than the room shrinks to fit with its
    /// shape kept. Nothing inside is resized either way — a tile's bounds are
    /// always the lane's size, and only the frame changes.
    ///
    /// The height is solved first and the width derived from it, so the common
    /// cases land on exact numbers: a lane that fits is exactly its size, and a
    /// lane taller than the room is exactly the room tall.
    /// The two ends of a tile's move, as values for its layer's `transform`:
    /// drawn at `from` on the first frame, and exactly as laid out on the last.
    ///
    /// The owner: *"nothing in the UI/UX should just 'jank in' like magic."* So a
    /// tile that changes place is laid out at its destination at once and its
    /// layer eased there from where the eye last saw it. Only the layer moves:
    /// the frame is already final, which keeps hit testing honest, and the
    /// bounds stay the lane's size, so no terminal inside sees a resize.
    ///
    /// **Composed with the transform the layer already has.** The first version
    /// animated from a flip to *identity*, which is only right when the layer's
    /// own transform is identity — and a tile whose bounds are the lane's size
    /// and whose frame is a thumbnail is not drawn that way. The owner watched
    /// what that cost: a collapsing tile started several times too big, and
    /// finished at the lane's full size before snapping into its slot. Here the
    /// map from `to` to `from` is built in the superlayer's space, measured from
    /// the layer's real `position`, and applied *after* the layer's own
    /// transform, so the last frame is the layer exactly as AppKit left it.
    static func moveTransforms(
        from: CGRect, to: CGRect, position: CGPoint, model: CATransform3D
    ) -> (start: CATransform3D, end: CATransform3D) {
        guard to.width > 0, to.height > 0 else { return (model, model) }
        let sx = from.width / to.width
        let sy = from.height / to.height
        // A point that is `to`'s origin relative to the layer's position has to
        // land on `from`'s origin relative to the same position.
        let tx = (from.minX - position.x) - sx * (to.minX - position.x)
        let ty = (from.minY - position.y) - sy * (to.minY - position.y)
        let toFrom = CATransform3DConcat(CATransform3DMakeScale(sx, sy, 1), CATransform3DMakeTranslation(tx, ty, 0))
        return (CATransform3DConcat(model, toFrom), model)
    }

    static func expanded(tile: CGRect, laneSize: CGSize, in size: CGSize, gap: CGFloat = gap) -> CGRect {
        guard laneSize.width > 0, laneSize.height > 0 else { return tile }
        let room = CGSize(width: max(0, size.width - 2 * gap), height: max(0, size.height - 2 * gap))
        let height = min(laneSize.height, room.height, room.width * laneSize.height / laneSize.width)
        let width = height * laneSize.width / laneSize.height
        let x = min(max(tile.midX - width / 2, gap), size.width - gap - width)
        let y = min(max(tile.midY - height / 2, gap), size.height - gap - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    struct Placement: Equatable {
        /// The one scale every tile is drawn at. 1 is the lane's real size.
        var scale: CGFloat
        /// One rect per lane, in strip order, in a flipped space whose origin is
        /// the gallery's top-left corner.
        var rects: [CGRect]
        /// How many rows the tiles wrapped into.
        var rows: Int
        /// The gap actually used. Normally `gap`; zero only for a strip so long
        /// that the gaps alone would not fit on the screen.
        var gap: CGFloat
    }

    /// Lay out lanes of these widths, all `laneHeight` tall, inside `size`.
    ///
    /// - Parameters:
    ///   - widths: each lane's width on the strip, in points and in strip
    ///     order. A spanned lane's ledger width already includes its span.
    ///   - laneHeight: how tall a lane is on the strip. Every lane is the same
    ///     height there, and a tile has to be *that* lane, not a taller one.
    ///   - size: the gallery's bounds.
    static func place(
        widths: [CGFloat], laneHeight: CGFloat, in size: CGSize,
        gap: CGFloat = gap, maxScale: CGFloat = 1
    ) -> Placement {
        guard !widths.isEmpty, laneHeight > 0, size.width > 0, size.height > 0,
              widths.allSatisfy({ $0 > 0 })
        else { return Placement(scale: 0, rects: widths.map { _ in .zero }, rows: 0, gap: gap) }

        // Hundreds of lanes: the gaps between them are wider than the screen on
        // their own, so no scale can fit them. Give up the gaps before giving up
        // "every lane on one screen".
        let usedGap = fits(widths: widths, laneHeight: laneHeight, in: size, gap: gap, scale: 1e-4)
            ? gap : 0

        var scale = maxScale
        if !fits(widths: widths, laneHeight: laneHeight, in: size, gap: usedGap, scale: scale) {
            // Feasibility is monotone in the scale — a bigger tile never fits
            // more per row, and every row gets taller — so bisection finds the
            // largest scale that fits to well under a pixel.
            var lo: CGFloat = 0, hi = maxScale
            for _ in 0..<48 {
                let mid = (lo + hi) / 2
                if fits(widths: widths, laneHeight: laneHeight, in: size, gap: usedGap, scale: mid) {
                    lo = mid
                } else {
                    hi = mid
                }
            }
            scale = lo
        }

        let rows = wrap(widths: widths, scale: scale, available: size.width - 2 * usedGap, gap: usedGap)
        let tileHeight = laneHeight * scale
        let blockHeight = CGFloat(rows.count) * tileHeight + CGFloat(max(0, rows.count - 1)) * usedGap
        var y = usedGap + max(0, (size.height - 2 * usedGap - blockHeight) / 2)
        var rects = [CGRect](repeating: .zero, count: widths.count)
        for row in rows {
            let rowWidth = row.reduce(0) { $0 + widths[$1] * scale } + CGFloat(row.count - 1) * usedGap
            var x = usedGap + max(0, (size.width - 2 * usedGap - rowWidth) / 2)
            for index in row {
                let width = widths[index] * scale
                rects[index] = CGRect(x: x, y: y, width: width, height: tileHeight)
                x += width + usedGap
            }
            y += tileHeight + usedGap
        }
        return Placement(scale: scale, rects: rects, rows: rows.count, gap: usedGap)
    }

    /// Whether every lane fits inside `size` at `scale`.
    static func fits(
        widths: [CGFloat], laneHeight: CGFloat, in size: CGSize, gap: CGFloat, scale: CGFloat
    ) -> Bool {
        let availableWidth = size.width - 2 * gap
        let availableHeight = size.height - 2 * gap
        guard availableWidth > 0, availableHeight > 0 else { return false }
        // A lane wider than the gallery at this scale cannot be placed at all —
        // it would be cropped, whatever row it went in.
        guard (widths.max() ?? 0) * scale <= availableWidth else { return false }
        let rows = wrap(widths: widths, scale: scale, available: availableWidth, gap: gap).count
        let height = CGFloat(rows) * laneHeight * scale + CGFloat(max(0, rows - 1)) * gap
        return height <= availableHeight
    }

    /// Strip order, left to right, wrapping when the next tile would not fit.
    /// Greedy is right here rather than merely cheap: the order is the user's,
    /// so a row can only ever end early, never be rearranged to pack better.
    static func wrap(widths: [CGFloat], scale: CGFloat, available: CGFloat, gap: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, raw) in widths.enumerated() {
            let width = raw * scale
            if !current.isEmpty && used + gap + width > available {
                rows.append(current)
                current = []
                used = 0
            }
            used += current.isEmpty ? width : gap + width
            current.append(index)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// How far AppKit's pixel rounding can move a view's size, in lane points,
    /// between the strip and a tile.
    ///
    /// Auto Layout rounds every constrained frame to whole device pixels *in the
    /// window*, and it does it internally — `backingAlignedRect` is never asked.
    /// Under a tile's transform a device pixel is `1 / (backing × scale)` lane
    /// points, so a pane that is 483 pt tall on the strip comes out 482.5 in a
    /// tile at 0.4 on a 1× panel. The two roundings of the same length can
    /// disagree by at most one pixel of each.
    static func roundingTolerance(scale: CGFloat, backingScale: CGFloat) -> CGFloat {
        1 / max(backingScale * scale, 0.01) + 1 / max(backingScale, 0.01) + 0.01
    }

    /// The size a terminal should keep in a tile: the size it held, unless the
    /// space it is given has moved by more than rounding can explain.
    ///
    /// Per dimension, so a window that got taller changes the rows it really
    /// changed and leaves the columns alone. Without this, entering the gallery
    /// can shave a point off a terminal, and a point is sometimes a column —
    /// which is a `RESIZE` on the phone, the one thing a tile must never cause.
    static func heldSize(_ held: CGSize, measured: CGSize, tolerance: CGFloat) -> CGSize {
        CGSize(
            width: abs(measured.width - held.width) <= tolerance ? held.width : measured.width,
            height: abs(measured.height - held.height) <= tolerance ? held.height : measured.height)
    }

    /// How Core Animation should shrink a tile's contents.
    ///
    /// Measured, not chosen (spike M5). What decides it is how many device
    /// pixels each point of the real lane ends up with. Above half a pixel,
    /// plain bilinear is closest to a Lanczos downscale — on a 2× panel it beat
    /// trilinear at every scale down to 0.33. At half a pixel or less, bilinear
    /// starts skipping whole glyph strokes and trilinear's pre-filtered mip
    /// levels win clearly: at 1× and a scale of 0.4 the mean error against
    /// Lanczos was 9.0 for bilinear and 5.8 for trilinear.
    static func minificationFilter(scale: CGFloat, backingScale: CGFloat) -> CALayerContentsFilter {
        scale * backingScale <= 0.5 ? .trilinear : .linear
    }
}
