import AppKit
import QuartzCore
import Testing
@testable import MaxPaneKit

/// ⌘G in and ⌘G out are rearrangements, not replacements.
///
/// The owner: *"when entering and exiting gallery the thumbs should have a
/// transition, otherwise we break the spatial relationship."* So a tile starts
/// where its lane stood on the strip and a lane starts where its tile was, and
/// the test reads the start rect back out of the animation rather than trusting
/// that one was added.
@MainActor
@Suite("entering and leaving the gallery", .serialized)
struct GalleryLayoutTransitionTests {
    /// Where a `galleryMove` begins, in `space`'s coordinates: the inverse of
    /// `GalleryLayout.moveTransforms`, which maps the layer's frame onto `from`
    /// after the layer's own transform.
    private func startRect(of layer: CALayer) -> CGRect? {
        guard let move = layer.animation(forKey: "galleryMove") as? CABasicAnimation,
              let start = (move.fromValue as? NSValue)?.caTransform3DValue else { return nil }
        let toFrom = CATransform3DConcat(CATransform3DInvert(layer.transform), start)
        let to = layer.frame
        let p = layer.position
        return CGRect(
            x: toFrom.m41 + toFrom.m11 * (to.minX - p.x) + p.x,
            y: toFrom.m42 + toFrom.m22 * (to.minY - p.y) + p.y,
            width: toFrom.m11 * to.width, height: toFrom.m22 * to.height)
    }

    private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test("a tile grows out of its lane's place on the strip, and a lane out of its tile's")
    func bothWays() async throws {
        try await MaximizeRig.with { rig in
            try rig.store.focusPane(rig.splitTop)
            await rig.settle()
            let lanes = [rig.leftLane, rig.splitLane, rig.rightLane]
            // In the window's own coordinates, which both layouts share.
            @MainActor func drawn(_ laneId: String) throws -> CGRect {
                let motion = try #require(rig.strip.layoutMotionLayer(laneId: laneId))
                return motion.space.convert(motion.layer.frame, to: nil)
            }
            @MainActor func begins(_ laneId: String) throws -> CGRect? {
                let motion = try #require(rig.strip.layoutMotionLayer(laneId: laneId))
                return startRect(of: motion.layer).map { motion.space.convert($0, to: nil) }
            }
            let onStrip = try Dictionary(uniqueKeysWithValues: lanes.map { ($0, try drawn($0)) })

            #expect(rig.strip.setLayout(.gallery))
            let tiles = try Dictionary(uniqueKeysWithValues: lanes.map { ($0, try drawn($0)) })
            for lane in lanes {
                #expect(tiles[lane]!.width < onStrip[lane]!.width)
                guard !Motion.isReduced else {
                    #expect(try begins(lane) == nil)
                    continue
                }
                let start = try #require(try begins(lane), "no motion into the gallery for \\(lane)")
                // Same size as the lane had: a lane past the window's edge is
                // brought in to the edge, so only its x may differ.
                #expect(abs(start.width - onStrip[lane]!.width) < 1)
                #expect(abs(start.height - onStrip[lane]!.height) < 1)
            }
            // The lane with the keyboard was on screen: its tile starts exactly there.
            if !Motion.isReduced {
                #expect(near(try #require(try begins(rig.splitLane)), onStrip[rig.splitLane]!))
            }

            await rig.settle()
            // Leaving takes each tile from where it is *drawn*, so a ⌘G pressed
            // twice quickly turns round in mid-air. With the suite running flat
            // out the way in can still be in flight here; end it, so "where it
            // is drawn" is the tile's slot and the comparison below means something.
            for lane in lanes {
                try #require(rig.strip.layoutMotionLayer(laneId: lane)).layer.removeAnimation(forKey: "galleryMove")
            }
            CATransaction.flush()
            let settled = try Dictionary(uniqueKeysWithValues: lanes.map { ($0, try drawn($0)) })
            #expect(rig.strip.setLayout(.lanes))
            for lane in lanes {
                // Every lane still has a view for the length of the motion, the
                // ones bound for beyond the window's edge included.
                let back = try drawn(lane)
                #expect(abs(back.width - onStrip[lane]!.width) < 1)
                guard !Motion.isReduced else { continue }
                let start = try #require(try begins(lane), "no motion out of the gallery for \\(lane)")
                #expect(near(start, settled[lane]!))
            }
            // And the strip is the strip again once it lands: the lane at its
            // own size. Not its old x — leaving the gallery reveals the focused
            // lane with the smallest scroll that shows it, which is its own rule.
            await rig.settle()
            let landed = try drawn(rig.splitLane)
            #expect(abs(landed.width - onStrip[rig.splitLane]!.width) < 1)
            #expect(abs(landed.height - onStrip[rig.splitLane]!.height) < 1)
        }
    }
}
