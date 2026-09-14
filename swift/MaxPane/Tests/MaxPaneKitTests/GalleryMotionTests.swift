import AppKit
import LanedCore
import CoreGraphics
import QuartzCore
import Testing
@testable import MaxPaneKit

/// Where a layer with these properties is drawn, in its superlayer's space —
/// Core Animation's own geometry, written out so a transform can be checked by
/// the rect it produces.
private func drawn(bounds: CGRect, position: CGPoint, anchor: CGPoint, _ m: CATransform3D) -> CGRect {
    let corners = [
        CGPoint(x: -anchor.x * bounds.width, y: -anchor.y * bounds.height),
        CGPoint(x: (1 - anchor.x) * bounds.width, y: -anchor.y * bounds.height),
        CGPoint(x: -anchor.x * bounds.width, y: (1 - anchor.y) * bounds.height),
        CGPoint(x: (1 - anchor.x) * bounds.width, y: (1 - anchor.y) * bounds.height),
    ].map { q in
        CGPoint(x: position.x + m.m11 * q.x + m.m21 * q.y + m.m41,
                y: position.y + m.m12 * q.x + m.m22 * q.y + m.m42)
    }
    let xs = corners.map(\.x), ys = corners.map(\.y)
    return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
}

private func close(_ a: CGRect, _ b: CGRect, within tolerance: CGFloat = 0.01) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// The two ends of a tile's move, as arithmetic.
///
/// The owner: *"The contraction seems to get significantly bigger before
/// contracting and it doesn't even contract back to its natural thumbnail
/// position. … Check your math."* The math assumed a layer's own transform was
/// identity. These pin both ends against a layer that is *not* identity — a
/// lane-sized layer scaled into a thumbnail — which is the case that broke.
@Suite("a gallery tile's motion")
struct GalleryMotionTests {
    private let thumbnail = CGRect(x: 1830, y: 520, width: 164, height: 225)
    private let expanded = CGRect(x: 1334, y: 90, width: 656, height: 900)
    private let lane = CGRect(x: 0, y: 0, width: 656, height: 900)

    @Test("expanding, with an identity layer, starts on the thumbnail and ends expanded",
          arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0)])
    func expansion(anchor: CGPoint) {
        let position = CGPoint(x: expanded.minX + anchor.x * expanded.width,
                               y: expanded.minY + anchor.y * expanded.height)
        let ends = GalleryLayout.moveTransforms(
            from: thumbnail, to: expanded, position: position, model: CATransform3DIdentity)
        #expect(close(drawn(bounds: lane, position: position, anchor: anchor, ends.start), thumbnail))
        #expect(close(drawn(bounds: lane, position: position, anchor: anchor, ends.end), expanded))
    }

    /// The case the owner saw: the layer is lane-sized and scaled a quarter to
    /// sit in its slot. Animating to identity drew it at 656 × 900 on the last
    /// frame; composing keeps it on the thumbnail.
    @Test("collapsing, with a scaled layer, starts expanded and ends exactly on the thumbnail",
          arguments: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5)])
    func collapse(anchor: CGPoint) {
        let scale = thumbnail.width / lane.width
        let model = CATransform3DMakeScale(scale, scale, 1)
        let position = CGPoint(x: thumbnail.minX + anchor.x * thumbnail.width,
                               y: thumbnail.minY + anchor.y * thumbnail.height)
        #expect(close(drawn(bounds: lane, position: position, anchor: anchor, model), thumbnail),
                "the fixture itself is wrong: the model layer is not on the thumbnail")

        let ends = GalleryLayout.moveTransforms(from: expanded, to: thumbnail, position: position, model: model)
        #expect(close(drawn(bounds: lane, position: position, anchor: anchor, ends.start), expanded))
        #expect(close(drawn(bounds: lane, position: position, anchor: anchor, ends.end), thumbnail))
        // Never larger than the larger of its two ends, on either end.
        #expect(drawn(bounds: lane, position: position, anchor: anchor, ends.start).width <= expanded.width + 0.01)
    }

    @Test("a tile that did not move is left on its own transform")
    func stillIsItsOwnTransform() {
        let model = CATransform3DMakeScale(0.25, 0.25, 1)
        let ends = GalleryLayout.moveTransforms(from: thumbnail, to: thumbnail, position: thumbnail.origin, model: model)
        #expect(CATransform3DEqualToTransform(ends.start, model))
        #expect(CATransform3DEqualToTransform(ends.end, model))
    }

    @Test("a zero-sized destination is left alone rather than divided by")
    func degenerateDestination() {
        let ends = GalleryLayout.moveTransforms(from: thumbnail, to: .zero, position: .zero, model: CATransform3DIdentity)
        #expect(CATransform3DIsIdentity(ends.start) && CATransform3DIsIdentity(ends.end))
    }
}

/// The same two ends against a real tile's layer, however AppKit chose to draw
/// lane-sized bounds into a thumbnail — which is the thing the first version
/// guessed at and got wrong. Its layer geometry is printed, so the answer is on
/// the record rather than assumed a second time.
@Suite("a gallery tile's layer")
@MainActor
struct GalleryTileLayerTests {
    private let size = CGSize(width: 656, height: 900)
    private let thumbnail = CGRect(x: 1830, y: 520, width: 164, height: 225)
    private let expanded = CGRect(x: 1334, y: 90, width: 656, height: 900)

    private func tile() -> (GalleryView, LaneView) {
        let gallery = GalleryView(frame: NSRect(x: 0, y: 0, width: 2000, height: 1000))
        let lane = Lane(id: "l", ordinal: 1, widthPt: 656, title: "t", projectRoot: nil,
                        projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false,
                        dock: nil, span: 1, panes: [])
        return (gallery, LaneView(lane: lane, widthBounds: 420...900))
    }

    @Test("has its new frame as soon as the tile is placed, so a motion has two ends")
    func layerFrameFollowsPlacementAtOnce() throws {
        let (gallery, laneView) = tile()
        gallery.place(laneView, laneId: "l", frame: thumbnail, laneSize: size)
        let small = try #require(gallery.tile(for: "l")?.layer?.frame)
        gallery.place(laneView, laneId: "l", frame: expanded, laneSize: size)
        let big = try #require(gallery.tile(for: "l")?.layer?.frame)
        #expect(small.size == thumbnail.size)
        #expect(big.size == expanded.size)
    }

    @Test("collapsing a real tile starts where it was drawn and ends on its slot", arguments: [false, true])
    func realTileEnds(collapsing: Bool) throws {
        let (gallery, laneView) = tile()
        let (first, second) = collapsing ? (expanded, thumbnail) : (thumbnail, expanded)
        gallery.place(laneView, laneId: "l", frame: first, laneSize: size)
        let layer = try #require(gallery.tile(for: "l")?.layer)
        let from = layer.frame
        gallery.place(laneView, laneId: "l", frame: second, laneSize: size)
        let to = layer.frame
        print("[gallery tile layer] \(collapsing ? "collapsed" : "expanded"): bounds \(layer.bounds) position \(layer.position) anchor \(layer.anchorPoint) frame \(to) transform-identity \(CATransform3DIsIdentity(layer.transform)) m11 \(layer.transform.m11) sublayer-identity \(CATransform3DIsIdentity(layer.sublayerTransform))")

        let ends = GalleryLayout.moveTransforms(from: from, to: to, position: layer.position, model: layer.transform)
        let start = drawn(bounds: layer.bounds, position: layer.position, anchor: layer.anchorPoint, ends.start)
        let end = drawn(bounds: layer.bounds, position: layer.position, anchor: layer.anchorPoint, ends.end)
        #expect(close(start, from, within: 0.5), "starts at \(start), was drawn at \(from)")
        #expect(close(end, to, within: 0.5), "ends at \(end), laid out at \(to)")
    }
}
