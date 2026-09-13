import CoreGraphics
import Testing
@testable import MaxPaneKit

/// The gallery's geometry: every lane on one screen, in strip order, as big as
/// that allows, and never anything but the lane itself drawn smaller.
@Suite("gallery layout")
struct GalleryLayoutTests {
    /// Widths the strip really has: default lanes, a narrow one, a spanned one.
    let mixed: [CGFloat] = [656, 656, 420, 1312, 656, 540, 656, 900, 656, 656, 480, 656]
    let laptop = CGSize(width: 1700, height: 1080)
    let ultrawide = CGSize(width: 3550, height: 1570)

    private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.insetBy(dx: 0.01, dy: 0.01).intersects(b.insetBy(dx: 0.01, dy: 0.01))
    }

    @Test("every lane is a tile, all of it inside the gallery, none overlapping")
    func everythingFits() {
        for size in [laptop, ultrawide, CGSize(width: 900, height: 600)] {
            let placement = GalleryLayout.place(widths: mixed, laneHeight: size.height, in: size)
            #expect(placement.rects.count == mixed.count)
            let bounds = CGRect(origin: .zero, size: size)
            for rect in placement.rects {
                #expect(rect.width > 0 && rect.height > 0)
                #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect), "\(rect) is cropped in \(size)")
            }
            for i in placement.rects.indices {
                for j in placement.rects.indices where j > i {
                    #expect(!overlaps(placement.rects[i], placement.rects[j]), "tiles \(i) and \(j) overlap")
                }
            }
        }
    }

    @Test("tiles run in strip order, left to right, wrapping into rows")
    func stripOrder() {
        let placement = GalleryLayout.place(widths: mixed, laneHeight: laptop.height, in: laptop)
        #expect(placement.rows > 1, "twelve lanes on a laptop should need more than one row")
        for i in 1..<placement.rects.count {
            let previous = placement.rects[i - 1], rect = placement.rects[i]
            let sameRow = abs(previous.minY - rect.minY) < 0.01
            #expect(sameRow ? rect.minX > previous.maxX : rect.minY > previous.maxY,
                    "tile \(i) is not after tile \(i - 1)")
        }
    }

    /// The rule that ADR-0007 forces: one scale, applied to the lane's own size.
    @Test("a tile is its lane scaled, never re-flowed")
    func scaledNotReflowed() {
        let height = laptop.height
        let placement = GalleryLayout.place(widths: mixed, laneHeight: height, in: laptop)
        for (width, rect) in zip(mixed, placement.rects) {
            #expect(abs(rect.width - width * placement.scale) < 0.001)
            #expect(abs(rect.height - height * placement.scale) < 0.001)
        }
        // A spanned lane is a tile exactly twice as wide as a default one.
        #expect(abs(placement.rects[3].width - 2 * placement.rects[0].width) < 0.001)
    }

    @Test("the scale is the largest that fits — a hair larger does not")
    func largestScale() {
        for size in [laptop, ultrawide] {
            let placement = GalleryLayout.place(widths: mixed, laneHeight: size.height, in: size)
            #expect(GalleryLayout.fits(widths: mixed, laneHeight: size.height, in: size,
                                       gap: placement.gap, scale: placement.scale))
            #expect(!GalleryLayout.fits(widths: mixed, laneHeight: size.height, in: size,
                                        gap: placement.gap, scale: placement.scale * 1.005))
        }
    }

    @Test("a lane is never drawn bigger than it really is")
    func neverBiggerThanReal() {
        let placement = GalleryLayout.place(widths: [656], laneHeight: 1000, in: CGSize(width: 3800, height: 2000))
        #expect(placement.scale == 1)
        #expect(placement.rects[0].size == CGSize(width: 656, height: 1000))
    }

    @Test("one more lane never makes the tiles bigger")
    func recomputesAsLanesArrive() {
        var previous: CGFloat = .greatestFiniteMagnitude
        for count in 1...40 {
            let widths = Array(repeating: CGFloat(656), count: count)
            let scale = GalleryLayout.place(widths: widths, laneHeight: laptop.height, in: laptop).scale
            #expect(scale <= previous + 1e-9, "\(count) lanes got bigger tiles than \(count - 1)")
            previous = scale
        }
    }

    @Test("a window resize is a fresh answer, not a nudge")
    func recomputesOnResize() {
        let small = GalleryLayout.place(widths: mixed, laneHeight: 600, in: CGSize(width: 900, height: 600))
        let large = GalleryLayout.place(widths: mixed, laneHeight: 1570, in: ultrawide)
        #expect(large.scale > 0 && small.scale > 0)
        // Each is the largest for its own window.
        #expect(!GalleryLayout.fits(widths: mixed, laneHeight: 600, in: CGSize(width: 900, height: 600),
                                    gap: small.gap, scale: small.scale * 1.005))
    }

    @Test("hundreds of lanes still all fit, uncropped")
    func hundredsOfLanes() {
        let widths = Array(repeating: CGFloat(656), count: 400)
        let placement = GalleryLayout.place(widths: widths, laneHeight: laptop.height, in: laptop)
        #expect(placement.scale > 0)
        let bounds = CGRect(origin: .zero, size: laptop).insetBy(dx: -0.01, dy: -0.01)
        #expect(placement.rects.allSatisfy { bounds.contains($0) && $0.width > 0 })
    }

    @Test("no lanes is no tiles")
    func empty() {
        let placement = GalleryLayout.place(widths: [], laneHeight: 1000, in: laptop)
        #expect(placement.rects.isEmpty)
        #expect(placement.rows == 0)
    }

    /// The hold that keeps a terminal's grid across AppKit's rounding.
    @Test("a terminal keeps its size through rounding, and follows a real change")
    func heldSize() {
        let held = CGSize(width: 656, height: 483)
        let tolerance = GalleryLayout.roundingTolerance(scale: 0.4, backingScale: 1)
        // What the tile's rounding did to it in the tile test below.
        #expect(GalleryLayout.heldSize(held, measured: CGSize(width: 655, height: 482.5), tolerance: tolerance) == held)
        // The window got 40 pt taller: the rows change, the columns do not.
        #expect(GalleryLayout.heldSize(held, measured: CGSize(width: 655.5, height: 523), tolerance: tolerance)
                == CGSize(width: 656, height: 523))
        // On a 2× panel at 0.44, a tile pixel is 1.14 pt and a strip pixel 0.5.
        let retina = GalleryLayout.roundingTolerance(scale: 0.44, backingScale: 2)
        #expect(retina > 1.63 && retina < 1.66)
    }

    /// Spike M5's numbers, as a rule: bilinear while each lane point keeps more
    /// than half a device pixel, trilinear once it does not.
    @Test("the minification filter follows device pixels per lane point")
    func filter() {
        #expect(GalleryLayout.minificationFilter(scale: 0.45, backingScale: 2) == .linear)
        #expect(GalleryLayout.minificationFilter(scale: 0.33, backingScale: 2) == .linear)
        #expect(GalleryLayout.minificationFilter(scale: 0.25, backingScale: 2) == .trilinear)
        #expect(GalleryLayout.minificationFilter(scale: 0.75, backingScale: 1) == .linear)
        #expect(GalleryLayout.minificationFilter(scale: 0.4, backingScale: 1) == .trilinear)
    }
}
