import Testing
import AppKit
@testable import MaxPaneKit

/// The arithmetic behind a seam.
///
/// Tested here rather than through a view because none of these failures look
/// like anything. A drag that moves the wrong pair, a floor honoured for two
/// panes out of three, a stack that adds up to a point more than the lane — on
/// screen every one of them is "the divider is a bit off", and in a test every
/// one of them is a number that is wrong.
@Suite("dividing a lane's height between its panes")
@MainActor
struct PaneSplitTests {
    /// A lane with room to spare, so nothing is up against the floor and the
    /// shares are the only thing deciding anything.
    private let roomy: CGFloat = 900

    // MARK: - resolving weights into heights

    @Test("equal weights split the lane equally — the layout that existed before this did")
    func equalWeightsAreAnEqualSplit() {
        let heights = PaneSplit.heights(weights: [1, 1], available: 800)
        #expect(heights == [400, 400])
    }

    @Test("heights sum to exactly the space they were given")
    func heightsAreExact() {
        // Not "about": these become constraint constants inside a stack pinned
        // top and bottom, so a point of slack is a conflict, not a gap.
        for weights in [[1.0, 1], [1, 2, 3], [0.7, 0.3], [1, 1, 1, 1, 1, 1, 1]] {
            for available in [roomy, 1000, 733, 641.5] {
                let heights = PaneSplit.heights(weights: weights, available: available)
                #expect(abs(heights.reduce(0, +) - available) < 0.0001)
            }
        }
    }

    @Test("a pane's height is its share, whatever the lane's height is")
    func heightIsAShare() {
        // The reason the ledger stores a weight: the same split has to come out
        // right on a laptop screen and on a 6K display, with no write between.
        for available in [400.0, 800, 1600, 733] as [CGFloat] {
            let heights = PaneSplit.heights(weights: [3, 1], available: available)
            // Within a point: heights are rounded to whole points so the seam
            // lands on a pixel boundary, and 733 does not divide by four.
            #expect(abs(heights[0] - available * 0.75) <= 1)
            #expect(abs(heights[1] - available * 0.25) <= 1)
        }
    }

    @Test("a pane that leaves hands its room to the survivors in their own proportions")
    func aDepartingPaneIsAbsorbedProportionally() {
        // The rule with no code: shares are relative, so dropping one weight is
        // the whole of the redistribution. Asserted anyway, because "we did
        // nothing" is exactly the kind of rule that gets a special case bolted
        // onto it later.
        let before = PaneSplit.heights(weights: [3, 1, 4], available: roomy)
        let after = PaneSplit.heights(weights: [3, 4], available: roomy)
        #expect(after[0] > before[0])
        #expect(after[1] > before[1])
        #expect(abs(after[0] / after[1] - before[0] / before[2]) < 0.01)
    }

    @Test("weights the ledger should never hold do not poison the whole lane")
    func anImpossibleWeightIsNotContagious() {
        // One NaN in the sum and every sibling's height is NaN — a lane of
        // panes with no size at all. The core refuses to store one; this is the
        // same refusal on the read side, for a ledger an older build wrote.
        let heights = PaneSplit.heights(weights: [1, .nan, -3, 0], available: 800)
        #expect(heights.allSatisfy { $0.isFinite && $0 > 0 })
        #expect(abs(heights.reduce(0, +) - 800) < 0.0001)
    }

    // MARK: - the floor

    @Test("a pane is never laid out shorter than the floor")
    func theFloorIsHonoured() {
        let heights = PaneSplit.heights(weights: [50, 1], available: 800)
        #expect(heights[1] == PaneSplit.minPaneHeight)
        #expect(abs(heights.reduce(0, +) - 800) < 0.0001)
    }

    @Test("two panes at the floor still leave the third the rest")
    func theFloorIsHonouredRepeatedly() {
        let heights = PaneSplit.heights(weights: [100, 1, 1], available: 800)
        #expect(heights[1] == PaneSplit.minPaneHeight)
        #expect(heights[2] == PaneSplit.minPaneHeight)
        #expect(abs(heights[0] - (800 - 2 * PaneSplit.minPaneHeight)) < 0.0001)
    }

    @Test("a lane too short for everyone's floor gives it to nobody, not to some")
    func anImpossibleFloorIsAbandonedForEveryone() {
        // The alternative squeezes the last pane to nothing: a lane that looks
        // unsplit, with a pane you cannot see and cannot drag back. Three panes
        // that are all too small is the honest rendering, and it is one window
        // resize from being right.
        let heights = PaneSplit.heights(weights: [1, 1, 1], available: 120)
        #expect(heights.allSatisfy { $0 > 0 })
        #expect(heights.allSatisfy { $0 < PaneSplit.minPaneHeight })
        #expect(abs(heights.reduce(0, +) - 120) < 0.0001)
    }

    // MARK: - dragging a seam

    @Test("dragging down grows the pane above by what the pointer travelled")
    func dragMovesTheBoundary() {
        let next = PaneSplit.drag(weights: [1, 1], divider: 0, delta: 100, available: 800)
        let heights = PaneSplit.heights(weights: next, available: 800)
        #expect(abs(heights[0] - 500) < 0.0001)
        #expect(abs(heights[1] - 300) < 0.0001)
    }

    @Test("dragging up grows the pane below")
    func dragTheOtherWay() {
        let next = PaneSplit.drag(weights: [1, 1], divider: 0, delta: -150, available: 800)
        let heights = PaneSplit.heights(weights: next, available: 800)
        #expect(abs(heights[0] - 250) < 0.0001)
        #expect(abs(heights[1] - 550) < 0.0001)
    }

    @Test("a seam moves exactly the two panes it is between")
    func aSeamMovesOnlyItsPair() {
        // The invariant that makes a four-pane stack usable: nudging one seam
        // must not quietly re-proportion the panes on the other side of the
        // lane. Bit-identical, not approximately — the untouched weights are
        // never recomputed at all.
        let before: [Double] = [1, 2, 3, 4]
        let after = PaneSplit.drag(weights: before, divider: 1, delta: 40, available: roomy)
        #expect(after[0] == before[0])
        #expect(after[3] == before[3])
        #expect(after[1] != before[1])
        #expect(abs((after[1] + after[2]) - (before[1] + before[2])) < 1e-12)
    }

    @Test("a seam at the top of the stack is seam zero, not seam one")
    func seamIndexing() {
        // Divider `i` sits below pane `i`. Off by one here and the top seam
        // resizes the bottom pair, which is the whole reason this is a function
        // and not four lines inside a mouse handler.
        let after = PaneSplit.drag(weights: [1, 1, 1], divider: 0, delta: 30, available: roomy)
        #expect(after[2] == 1)
        #expect(after[0] > after[1])
    }

    @Test("a pane cannot be dragged past the floor, in either direction")
    func dragStopsAtTheFloor() {
        for delta in [-10_000.0, 10_000] as [CGFloat] {
            let after = PaneSplit.drag(weights: [1, 1], divider: 0, delta: delta, available: 800)
            let heights = PaneSplit.heights(weights: after, available: 800)
            #expect(heights.allSatisfy { $0 >= PaneSplit.minPaneHeight - 0.0001 })
        }
    }

    @Test("a pane squeezed to the floor comes back")
    func theFloorIsNotATrap() {
        // A floor that a drag cannot return from would be a pane the user has
        // permanently lost, which is why the seam stays where it is rather than
        // refusing to move once something is against the stop.
        let squeezed = PaneSplit.drag(weights: [1, 1], divider: 0, delta: 10_000, available: 800)
        let recovered = PaneSplit.drag(weights: squeezed, divider: 0, delta: -300, available: 800)
        let heights = PaneSplit.heights(weights: recovered, available: 800)
        #expect(heights[1] > PaneSplit.minPaneHeight + 200)
    }

    @Test("a drag on a lane with no room for two floors does nothing rather than something wrong")
    func noRoomMeansNoMovement() {
        let before: [Double] = [1, 1]
        #expect(PaneSplit.drag(weights: before, divider: 0, delta: 50, available: 100) == before)
    }

    @Test("a seam index that is not there is not a crash")
    func outOfRangeSeamsAreInert() {
        #expect(PaneSplit.drag(weights: [1, 1], divider: 1, delta: 50, available: roomy) == [1, 1])
        #expect(PaneSplit.drag(weights: [1], divider: 0, delta: 50, available: roomy) == [1])
        #expect(PaneSplit.drag(weights: [], divider: 0, delta: 50, available: roomy) == [])
    }

    @Test("a drag that travelled nowhere changes nothing")
    func azeroDragIsFree() {
        // Every mouse-up sends one, as the signal to commit.
        let before: [Double] = [1.3, 0.7]
        let after = PaneSplit.drag(weights: before, divider: 0, delta: 0, available: roomy)
        #expect(abs(after[0] - before[0]) < 1e-9)
        #expect(abs(after[1] - before[1]) < 1e-9)
    }

    // MARK: - a pane joining

    @Test("a pane joining an untouched lane makes an equal split")
    func joiningAnEqualLane() {
        #expect(PaneSplit.weightForJoining([1]) == 1)
        #expect(PaneSplit.weightForJoining([1, 1]) == 1)
    }

    @Test("the first pane of a lane is not a special case")
    func joiningAnEmptyLane() {
        #expect(PaneSplit.weightForJoining([]) == 1)
    }

    @Test("a pane joining a lane you arranged takes an equal share and moves nobody's ratio")
    func joiningATunedLane() {
        // ⇧⌘D on a lane already dragged to 70/30. The newcomer gets a third of
        // the lane; the two panes the user arranged are still 70/30 of what is
        // left of them.
        let existing: [Double] = [0.7, 0.3]
        let weights = existing + [PaneSplit.weightForJoining(existing)]
        let heights = PaneSplit.heights(weights: weights, available: roomy)
        #expect(abs(heights[2] - roomy / 3) < 0.0001)
        #expect(abs(heights[0] / heights[1] - 7.0 / 3.0) < 0.0001)
    }

    @Test("splitting the same lane four times keeps every pane an equal share")
    func repeatedSplitsStayEven() {
        // The compounding case. `weightForJoining` returning the mean is what
        // makes this hold; a constant 1.0 would give the fourth pane a quarter
        // of a lane whose other panes had already been shrunk, and the stack
        // would drift further out of true with every split.
        var weights: [Double] = [1]
        for _ in 0..<3 { weights.append(PaneSplit.weightForJoining(weights)) }
        let heights = PaneSplit.heights(weights: weights, available: roomy)
        for height in heights { #expect(abs(height - roomy / 4) < 0.0001) }
    }
}
