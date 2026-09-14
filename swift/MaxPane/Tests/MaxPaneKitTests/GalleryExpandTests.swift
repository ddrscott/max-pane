import AppKit
import Testing
@testable import MaxPaneKit

/// Where an expanded tile goes.
///
/// The owner: *"When expanding a gallery thumbnail it should expand in place.
/// not go to lanes view so it behaves like RelayTTY."* A tile is already the real
/// lane with scaled bounds, so expanding is only a bigger frame — no terminal is
/// resized. What has to be right is *where*: over its own place in the grid, at
/// the lane's real size, pushed inward only as far as the gallery's edges demand.
/// Flipped space, origin top-left, like every other gallery rect.
@Suite("an expanded gallery tile")
@MainActor
struct GalleryExpandTests {
    private let gallery = CGSize(width: 2000, height: 1000)
    private let gap = GalleryLayout.gap

    @Test("it is the lane's real size when the gallery has room")
    func realSizeWhenItFits() {
        let lane = CGSize(width: 656, height: 900)
        let tile = CGRect(x: 700, y: 50, width: 164, height: 225)
        let rect = GalleryLayout.expanded(tile: tile, laneSize: lane, in: gallery)
        #expect(rect.size == lane)
    }

    @Test("it grows around its own tile, not the middle of the screen")
    func centredOnItsTile() {
        let lane = CGSize(width: 656, height: 900)
        let tile = CGRect(x: 700, y: 50, width: 164, height: 225)
        let rect = GalleryLayout.expanded(tile: tile, laneSize: lane, in: gallery)
        #expect(rect.midX == tile.midX)
    }

    @Test("a tile at the right edge expands leftward, kept inside the gallery")
    func clampedAtTheEdge() {
        let lane = CGSize(width: 656, height: 900)
        let tile = CGRect(x: 1830, y: 520, width: 164, height: 225)
        let rect = GalleryLayout.expanded(tile: tile, laneSize: lane, in: gallery)
        #expect(rect.maxX == gallery.width - gap)
        #expect(rect.minY >= gap)
        #expect(rect.maxY <= gallery.height - gap)
    }

    @Test("a lane taller than the gallery shrinks to fit, keeping its shape")
    func shrinksWhenTooTall() {
        let lane = CGSize(width: 656, height: 1400)
        let tile = CGRect(x: 100, y: 100, width: 100, height: 213)
        let rect = GalleryLayout.expanded(tile: tile, laneSize: lane, in: gallery)
        #expect(rect.height == gallery.height - 2 * gap)
        #expect(abs(rect.width / rect.height - lane.width / lane.height) < 0.001)
    }

    @Test("it never draws a lane bigger than it really is")
    func neverAboveRealSize() {
        let lane = CGSize(width: 420, height: 500)
        let tile = CGRect(x: 900, y: 400, width: 210, height: 250)
        let rect = GalleryLayout.expanded(tile: tile, laneSize: lane, in: gallery)
        #expect(rect.size == lane)
    }
}
