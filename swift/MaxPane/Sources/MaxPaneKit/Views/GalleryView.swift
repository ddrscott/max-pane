import AppKit

/// The gallery: every lane on the strip on one screen, each a live thumbnail of
/// itself.
///
/// Holds no lanes of its own. The strip's `LaneView`s — the same objects, with
/// the same Ghostty surfaces and `WKWebView`s inside them — are reparented into
/// tiles and back, which within one window never takes a view out of it: a
/// terminal keeps its surface and a page keeps playing. See ADR-0011.
@MainActor
final class GalleryView: NSView {
    override var isFlipped: Bool { true }

    private var tiles: [String: GalleryTileView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.stripBackground.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Put a lane in its tile, at `frame` in the gallery, drawn at `laneSize`.
    func place(_ laneView: LaneView, laneId: String, frame: CGRect, laneSize: CGSize) {
        let tile: GalleryTileView
        if let existing = tiles[laneId] {
            tile = existing
        } else {
            tile = GalleryTileView(frame: frame)
            tiles[laneId] = tile
            addSubview(tile)
        }
        tile.show(laneView, frame: frame, laneSize: laneSize)
    }

    /// Drop the tiles of lanes that are no longer shown. The lane views inside
    /// them have already gone back to the strip or been retired; a tile is only
    /// the frame around one.
    func removeTiles(except keep: Set<String>) {
        for (id, tile) in tiles where !keep.contains(id) {
            tile.removeFromSuperview()
            tiles[id] = nil
        }
    }

    /// Draw one tile over the rest: the expanded one.
    ///
    /// Reordered rather than given a `zPosition`, because AppKit hit-tests
    /// subviews in order and a layer drawn on top would still hand the click to
    /// the neighbour underneath. Within one window, so the lane inside keeps its
    /// surface and its page, the same as every other reparenting in here.
    func raise(_ laneId: String) {
        guard let tile = tiles[laneId], subviews.last !== tile else { return }
        addSubview(tile, positioned: .above, relativeTo: nil)
    }

    func tile(for laneId: String) -> GalleryTileView? { tiles[laneId] }
    var tileIds: Set<String> { Set(tiles.keys) }
}

/// One tile: a lane at its real size, drawn smaller.
///
/// The whole trick is `bounds` versus `frame`. The frame is the tile's place in
/// the gallery; the bounds are the lane's own width and height. Everything
/// inside lays out against the bounds, so a terminal measures exactly the view
/// it measured on the strip and never reports a new grid — spike M5 measured
/// zero resizes at every scale from 1 down to 0.25 — while the compositor draws
/// the result into the frame. AppKit converts every point through the same
/// transform, so a click or a selection lands on the cell under the pointer.
@MainActor
final class GalleryTileView: NSView {
    override var isFlipped: Bool { true }

    /// Layer-backed by its own say-so rather than by inheriting it from the
    /// gallery: its layer is what moves when it expands, and a tile that came
    /// up without one would change place with no motion at all.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func show(_ laneView: LaneView, frame newFrame: CGRect, laneSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame != newFrame { frame = newFrame }
        // After the frame: resizing a view with scaled bounds scales its bounds
        // along with it, so the lane's size is asserted every time rather than
        // trusted to have survived.
        if bounds.size != laneSize || bounds.origin != .zero {
            setBoundsOrigin(.zero)
            setBoundsSize(laneSize)
        }
        if laneView.superview !== self { addSubview(laneView) }
        let laneFrame = CGRect(origin: .zero, size: laneSize)
        if laneView.frame != laneFrame { laneView.frame = laneFrame }
        CATransaction.commit()
    }
}
