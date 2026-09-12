import Testing
import AppKit
import LanedCore
@testable import MaxPaneKit

/// Which pane views a lane should be holding.
///
/// This is the arithmetic behind the ⇧⌘D bug: the pane was created, the session
/// was running, and nothing ever worked out that the lane on screen was one view
/// short. It is tested here rather than through a view because the failure was
/// never visual — it was a diff that did not exist.
@Suite("reconciling a lane's panes")
@MainActor
struct PaneStackPlanTests {
    /// Every plan has to *arrive* somewhere: applying the steps to what is
    /// installed must produce exactly the snapshot's order, or the stack and the
    /// ledger disagree and the next reconcile inherits the mess.
    private func check(_ installed: [String], _ wanted: [String]) -> [PaneStackPlan.Step] {
        let steps = PaneStackPlan.steps(installed: installed, wanted: wanted)
        #expect(PaneStackPlan.applying(steps, to: installed) == wanted)
        return steps
    }

    @Test("a lane already on screen that gains a pane installs it — the ⇧⌘D fix")
    func splitDownInstallsTheNewPane() {
        let steps = check(["a"], ["a", "b"])
        #expect(steps == [.insert("b", at: 1)])
    }

    @Test("splitting again gives a third, in position order")
    func splittingTwiceKeepsOrder() {
        let steps = check(["a", "b"], ["a", "b", "c"])
        #expect(steps == [.insert("c", at: 2)])
    }

    @Test("closing one pane of a stack removes that pane and leaves the others")
    func closingOnePaneOfAStack() {
        let steps = check(["a", "b", "c"], ["a", "c"])
        #expect(steps == [.remove("b")])
    }

    @Test("a snapshot that changed nothing produces no work at all")
    func unchangedSnapshotIsFree() {
        // The whole reason this is a diff: `apply` runs after every mutation,
        // and rebuilding here would destroy a WKWebView per snapshot.
        #expect(PaneStackPlan.steps(installed: ["a", "b"], wanted: ["a", "b"]).isEmpty)
    }

    @Test("a recycled lane view holding another lane's panes swaps all of them")
    func recycledViewIsFullyReplaced() {
        let steps = check(["x", "y"], ["a"])
        #expect(steps.contains(.remove("x")))
        #expect(steps.contains(.remove("y")))
        #expect(steps.contains(.insert("a", at: 0)))
    }

    @Test("a pane inserted at the top does not disturb the ones below it")
    func insertAtTheTop() {
        let steps = check(["b", "c"], ["a", "b", "c"])
        #expect(steps == [.insert("a", at: 0)])
    }

    @Test("panes that only changed order move rather than being rebuilt")
    func reorderIsAMove() {
        let steps = check(["a", "b"], ["b", "a"])
        // Not a remove-and-insert: taking a pane view out to put it back costs
        // a WKWebView its content process.
        #expect(!steps.contains { if case .insert = $0 { return true } else { return false } })
        #expect(!steps.contains { if case .remove = $0 { return true } else { return false } })
    }

    @Test("removals, insertions and a reorder all at once still land correctly")
    func theAwkwardOne() {
        _ = check(["a", "b", "c"], ["c", "d", "a"])
        _ = check([], ["a", "b", "c"])
        _ = check(["a", "b", "c"], [])
    }

    @Test("a pane still animating out keeps the slot it is in")
    func departingPaneHoldsItsPlace() {
        // `b` has left the ledger but its view is still fading. Reconciling
        // against the raw snapshot would yank it out mid-animation; reconciling
        // against the held order leaves it exactly where the eye last saw it.
        let held = PaneStackPlan.holding(["b"], wanted: ["a", "c"], installed: ["a", "b", "c"])
        #expect(held == ["a", "b", "c"])
        #expect(PaneStackPlan.steps(installed: ["a", "b", "c"], wanted: held).isEmpty)
    }

    @Test("a departing pane does not block a new one arriving beside it")
    func departingAndArrivingTogether() {
        let held = PaneStackPlan.holding(["b"], wanted: ["a", "c"], installed: ["a", "b"])
        let steps = PaneStackPlan.steps(installed: ["a", "b"], wanted: held)
        #expect(PaneStackPlan.applying(steps, to: ["a", "b"]) == held)
        #expect(held.contains("b"))
        #expect(held.contains("c"))
    }

    @Test("nothing is held once the departing pane's view is gone")
    func nothingDepartingIsIdentity() {
        #expect(PaneStackPlan.holding([], wanted: ["a", "c"], installed: ["a", "b", "c"]) == ["a", "c"])
    }
}

/// What the strip decides to animate.
///
/// The trap this exists for: after inserting a lane at index 2, *every* lane
/// after it has a new index. None of them moved — the column that opened between
/// them moved them, and that motion is already on screen. Sliding them as well
/// shows the same displacement twice and reads as a glitch.
@Suite("what changed between two snapshots")
@MainActor
struct StripDiffTests {
    @Test("a new lane is an arrival and nothing else")
    func insertDoesNotMoveItsNeighbours() {
        let diff = StripDiff.between(["a", "b", "c"], ["a", "new", "b", "c"])
        #expect(diff.inserted == ["new"])
        #expect(diff.removed.isEmpty)
        #expect(diff.moved.isEmpty)
    }

    @Test("a closed lane is a departure, remembered at the slot it held")
    func removeRemembersItsIndex() {
        let diff = StripDiff.between(["a", "b", "c"], ["a", "c"])
        #expect(diff.removed == [StripDiff.Departure(id: "b", index: 1)])
        #expect(diff.inserted.isEmpty)
        #expect(diff.moved.isEmpty)
    }

    @Test("⇧⌘→ moves both lanes that swapped, and only those two")
    func nudgeMovesTheTwoThatCrossed() {
        let diff = StripDiff.between(["a", "b", "c", "d"], ["b", "a", "c", "d"])
        #expect(Set(diff.moved) == ["a", "b"])
        #expect(diff.inserted.isEmpty)
        #expect(diff.removed.isEmpty)
    }

    @Test("an identical snapshot asks for no motion")
    func noChangeNoMotion() {
        #expect(StripDiff.between(["a", "b"], ["a", "b"]).isEmpty)
    }

    @Test("a cold launch is every lane arriving at once")
    func coldLaunchIsAllArrivals() {
        // Which is exactly why the controller suppresses transitions until the
        // strip has settled: animating this would be a wave of columns opening
        // for a strip that was simply restored.
        let diff = StripDiff.between([], ["a", "b", "c"])
        #expect(diff.inserted == ["a", "b", "c"])
        #expect(diff.moved.isEmpty)
    }

    @Test("a move and an arrival in the same snapshot stay separate")
    func moveAndInsertTogether() {
        let diff = StripDiff.between(["a", "b", "c"], ["new", "b", "a", "c"])
        #expect(diff.inserted == ["new"])
        #expect(Set(diff.moved) == ["a", "b"])
    }
}

@Suite("strip geometry and easing")
@MainActor
struct StripMotionGeometryTests {
    private func lanes(_ widths: [UInt32]) -> [Lane] {
        widths.enumerated().map { index, width in
            Lane(id: "lane-\(index)", ordinal: Double(index), widthPt: width, title: nil,
                 projectRoot: nil, projectSource: .cwd, createdAt: 0, lastFocusAt: 0,
                 keepLive: false, dock: nil, span: 1, panes: [])
        }
    }

    @Test("a lane's origin is the sum of what is left of it, borders included")
    func originsSumWidths() {
        let origins = StripGeometry.origins(of: lanes([600, 400, 500]))
        #expect(origins["lane-0"] == CGFloat(0))
        #expect(origins["lane-1"] == CGFloat(600) + Theme.borderWidth)
        #expect(origins["lane-2"] == CGFloat(1000) + Theme.borderWidth * 2)
    }

    @Test("a lane that swaps with its neighbour slides exactly its neighbour's width")
    func swapDistanceIsTheNeighbourWidth() {
        // What the eye has to follow, and therefore what the slide has to cover:
        // measured in points between the two snapshots, not in indices.
        let before = lanes([600, 400, 500])
        var after = before
        after.swapAt(0, 1)
        let was = StripGeometry.origins(of: before)
        let now = StripGeometry.origins(of: after)
        #expect(now["lane-0"]! - was["lane-0"]! == CGFloat(400) + Theme.borderWidth)
        #expect(now["lane-1"]! - was["lane-1"]! == -(CGFloat(600) + Theme.borderWidth))
    }

    @Test("easing starts fast, ends settled, and stays inside 0…1")
    func easeOutShape() {
        #expect(Motion.easeOut(0) == 0)
        #expect(Motion.easeOut(1) == 1)
        // Over half the travel in the first fifth of the time: the point of
        // ease-out here is that the change registers immediately and only the
        // settling takes the rest of the 0.22s.
        #expect(Motion.easeOut(0.2) > 0.48)
        // Clamped, because a timer can be handed a t past 1 when a frame is late.
        #expect(Motion.easeOut(1.4) == 1)
        #expect(Motion.easeOut(-0.2) == 0)
    }

    @Test("nothing takes longer than the collapse that was already there")
    func nothingIsSlowerThanTheOriginal() {
        // The bar the owner set is "subtle": anything you would wait for is a
        // failure, so 0.22s is a ceiling, not a starting point.
        #expect(Motion.lane == 0.22)
        #expect(Motion.pane <= Motion.lane)
    }
}
