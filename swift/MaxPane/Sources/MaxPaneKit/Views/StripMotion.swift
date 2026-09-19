import AppKit
import LanedCore

/// The strip's motion vocabulary, and the arithmetic behind it.
///
/// Motion here exists for one reason, in the owner's words: *"otherwise the
/// user loses spatial recognition."* A column that appears by being cut in
/// tells you nothing about where it came from, and on a strip that is wider
/// than the screen, "where" is the only thing you have. So every transition in
/// this file answers exactly one question — **where did that go, or come
/// from** — and anything that does not answer it is not worth a frame.
///
/// The numbers live together because the danger is not any one of them, it is
/// disagreement: a 0.22s collapse beside a 0.4s insert reads as two different
/// applications. 0.22 is not chosen here, it is inherited — it is what a
/// finished lane already took to collapse before any of this existed.
enum Motion {
    /// A whole column arriving or leaving. Matches the collapse that
    /// `paneDidExit` has always used, because the user sees both.
    static let lane: TimeInterval = 0.22
    /// A pane inside a stack. Shorter, because the column around it does not
    /// move: the event is smaller, so the motion is smaller.
    static let pane: TimeInterval = 0.16
    /// Cubic ease-out: most of the travel is over in the first third, so the eye
    /// reads "that one left" rather than watching a column shrink. The tail is
    /// what makes it feel like settling; the head is what keeps it from feeling
    /// like a wait.
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    /// `easeOut` for Core Animation: the cubic-bezier that traces `1 − (1 − t)³`.
    ///
    /// For motion that really is a layer property — a gallery tile's transform —
    /// so it runs on the render server rather than on `run`'s timer, and still
    /// moves on the same curve as everything the timer drives. Computed rather
    /// than stored, because a static `CAMediaTimingFunction` is shared mutable
    /// state as far as Swift's concurrency checking is concerned.
    static var easeOutTiming: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    }

    /// Fade a layer's contents from what it last drew to what it draws next.
    ///
    /// For a readout changing its meaning in place — a badge going dim, a chip
    /// changing — where the text and colour are not animatable properties and
    /// a cut is exactly the jank this app does not do. Nothing under Reduce
    /// Motion: the new frame simply lands.
    static func fade(_ layer: CALayer?, duration: TimeInterval = Motion.pane) {
        guard let layer, !isReduced else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = easeOutTiming
        layer.add(fade, forKey: kCATransition)
    }

    /// System Settings › Accessibility › Display › Reduce motion.
    ///
    /// Read per transition rather than cached: it is a live preference, and
    /// someone who turns it on mid-session has said what they want *now*. With
    /// it on, every transition below runs its final frame immediately and calls
    /// its completion — so the result is identical, it simply has no middle.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Run `step` with linear progress 0…1 over `duration`, then `completion`.
    ///
    /// A timer rather than Core Animation because none of what this file
    /// animates is a view property: the strip's layout is computed by summing
    /// lane widths and a lane's stack by resolving weights, and both have to run
    /// through their own layout pass or the things *beside* the animated one
    /// would not move with it.
    ///
    /// It lives here rather than in either of its two callers because they have
    /// to agree: a column opening and a pane opening inside it are the same
    /// clock at two scales, and two hand-rolled timers is how they stop being.
    @MainActor
    @discardableResult
    static func run(
        duration: TimeInterval,
        step: @escaping @MainActor (CGFloat) -> Void,
        completion: @escaping @MainActor () -> Void
    ) -> MotionTimer {
        let start = CACurrentMediaTime()
        let running = MotionTimer()
        // Scheduled on the main run loop in `.common`, so the block is already
        // on the main thread — `assumeIsolated` states that rather than hopping
        // through a Task, which would deliver frames a run loop late and let the
        // timer fire again before the last frame drew.
        running.timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let t = min(1, (CACurrentMediaTime() - start) / duration)
                step(CGFloat(t))
                if t >= 1 {
                    running.timer?.invalidate()
                    running.timer = nil
                    completion()
                }
            }
        }
        RunLoop.main.add(running.timer!, forMode: .common)
        return running
    }
}

/// A transition in flight, and the handle that stops it.
///
/// The timer is held here rather than captured by the block that runs it: the
/// block's own `Timer` argument is not main-actor isolated, so it cannot stop
/// the thing calling it without this.
@MainActor
final class MotionTimer {
    var timer: Timer?
    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// A lane drawn differently from what the ledger says, for as long as something
/// is animating it.
///
/// The two cases are genuinely different and the flag is not a shortcut. A live
/// edge-drag *is* a resize — the user is making the lane narrower and expects
/// the pane inside to reflow. A column opening or closing is not: the lane keeps
/// its real width behind a mask and only its slot in the row moves, because the
/// pane inside it has a far end, and a terminal walked down to one column and
/// back is a PTY reshaped for every client attached to it (ADR-0007).
struct LaneOverride: Equatable {
    /// The width this lane takes up in the row.
    var slot: CGFloat
    /// Whether the lane keeps its real width and is revealed through a mask, or
    /// is genuinely drawn at `slot`.
    var masked: Bool
}

/// What a lane's stack of panes must do to match a snapshot.
///
/// Extracted from the view for the same reason `LaneSnap` was: it is all
/// bookkeeping, it is where an off-by-one hides, and it is the exact thing that
/// was missing when ⇧⌘D created a pane nobody could see.
///
/// **Reconcile, do not rebuild.** These steps only ever touch panes that
/// actually changed. Rebuilding a lane's stack on every snapshot would destroy
/// a `WKWebView` — 27–95 MB and an OS process each, per spike M1 — and drop a
/// terminal's scrollback, on every keystroke that publishes.
enum PaneStackPlan {
    enum Step: Equatable {
        /// Installed, and the snapshot no longer has it.
        case remove(String)
        /// In the snapshot with no view yet, wanted at this index.
        case insert(String, at: Int)
        /// Installed, but not where the snapshot puts it.
        case move(String, to: Int)
    }

    /// The steps that turn `installed` (top to bottom, as the stack has it) into
    /// `wanted` (the snapshot's order).
    ///
    /// Removals come first, so every index afterwards is an index in the
    /// finished stack rather than in some intermediate one — which is the
    /// off-by-one this returns steps instead of a target order to avoid.
    static func steps(installed: [String], wanted: [String]) -> [Step] {
        let wantedSet = Set(wanted)
        var steps: [Step] = []
        var current: [String] = []
        for id in installed {
            if wantedSet.contains(id) { current.append(id) } else { steps.append(.remove(id)) }
        }
        for (index, id) in wanted.enumerated() {
            if index < current.count, current[index] == id { continue }
            if let from = current.firstIndex(of: id) {
                current.remove(at: from)
                current.insert(id, at: min(index, current.count))
                steps.append(.move(id, to: index))
            } else {
                current.insert(id, at: min(index, current.count))
                steps.append(.insert(id, at: index))
            }
        }
        return steps
    }

    /// The stack order after `steps`. The view applies them to an `NSStackView`;
    /// this applies them to an array, so a test can assert the two agree.
    static func applying(_ steps: [Step], to installed: [String]) -> [String] {
        var current = installed
        for step in steps {
            switch step {
            case .remove(let id):
                current.removeAll { $0 == id }
            case .insert(let id, let index):
                current.insert(id, at: min(index, current.count))
            case .move(let id, let index):
                guard let from = current.firstIndex(of: id) else { continue }
                current.remove(at: from)
                current.insert(id, at: min(index, current.count))
            }
        }
        return current
    }

    /// `wanted`, with panes that are on their way out held at the index they
    /// already occupy.
    ///
    /// A pane closed by hand leaves the ledger immediately — PRD §6 commits
    /// before anything animates — but its view has to stay put for the length of
    /// its exit, or the stack would redistribute under it and the thing the
    /// animation is showing you would already be gone. Reconciling against this
    /// order rather than the raw snapshot is what keeps the two from fighting.
    static func holding(_ departing: Set<String>, wanted: [String], installed: [String]) -> [String] {
        guard !departing.isEmpty else { return wanted }
        var held = wanted
        for (index, id) in installed.enumerated() where departing.contains(id) {
            guard !held.contains(id) else { continue }
            held.insert(id, at: min(index, held.count))
        }
        return held
    }
}

/// What changed between two snapshots of the strip, in the terms motion cares
/// about: what arrived, what left, and what genuinely changed place.
struct StripDiff: Equatable {
    /// Lane ids in the new snapshot that were not in the old one.
    var inserted: [String] = []
    /// Lane ids that left, each with the index it held in the old snapshot —
    /// which is the slot its column has to keep until it finishes closing.
    var removed: [Departure] = []
    /// Lanes present in both whose position *relative to the other lanes*
    /// changed. Deliberately not "lanes whose index changed": inserting a lane
    /// at index 2 changes the index of everything after it, but those lanes did
    /// not move — the column that opened between them moved them, and that
    /// motion is already on screen. Sliding them as well would show the same
    /// displacement twice.
    var moved: [String] = []

    struct Departure: Equatable {
        var id: String
        var index: Int
    }

    var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && moved.isEmpty }

    static func between(_ before: [String], _ after: [String]) -> StripDiff {
        let beforeSet = Set(before)
        let afterSet = Set(after)

        var diff = StripDiff()
        diff.inserted = after.filter { !beforeSet.contains($0) }
        diff.removed = before.enumerated()
            .filter { !afterSet.contains($0.element) }
            .map { Departure(id: $0.element, index: $0.offset) }

        // Order among the survivors, with arrivals and departures taken out of
        // the comparison. If that is unchanged, nothing was reordered.
        let keptBefore = before.filter { afterSet.contains($0) }
        let keptAfter = after.filter { beforeSet.contains($0) }
        if keptBefore != keptAfter {
            var wasAt: [String: Int] = [:]
            for (index, id) in keptBefore.enumerated() { wasAt[id] = index }
            diff.moved = keptAfter.enumerated()
                .filter { wasAt[$0.element] != $0.offset }
                .map(\.element)
        }
        return diff
    }
}

/// Where the strip has to come to rest for a given lane to be readable.
///
/// **Every number here comes from the ledger's lanes. There is deliberately no
/// view in this file**, and that is the whole fix rather than a style
/// preference. The reveal used to clamp its target against
/// `content.frame.width` — the *document view's* width — and a lane's column
/// opens from zero, so at the instant a lane is inserted the document view does
/// not yet contain it. `setBoundsOrigin` is clamped by that width, so the strip
/// was told to go somewhere it could not yet reach and stopped short by up to a
/// whole lane. On a strip already wider than the window that put the newest,
/// focused lane off the right edge: measured at 66 pt of scroll with 26 pt of a
/// 654 pt lane showing, and in a window that fits a whole number of lanes, no
/// scroll at all.
///
/// Computing against the post-insert lanes makes the target right. Running the
/// scroll on the *insert's own* timer (see `StripViewController.arrivalScroll`)
/// is what makes it reachable: the document view grows over those same frames,
/// and an eased scroll toward a target that is `d` inside the final limit is
/// `d·(1-eased)` inside the growing one at every step — never clamped, ending
/// exactly on target.
enum StripReveal {
    /// Centre `laneId`, clamped to the strip, then let `LanePeek` keep a sliver
    /// of the next lane showing. What ⌘P and an arriving lane both want.
    static func centred(
        on laneId: String, lanes: [Lane], viewport: CGFloat, peek: CGFloat
    ) -> CGFloat? {
        guard viewport > 0, let index = lanes.firstIndex(where: { $0.id == laneId }) else { return nil }
        let slots = StripEdges.slots(of: lanes)
        let centred = exactCentre(slots[index], lanes: lanes, viewport: viewport)
        // A carousel is centred exactly: both neighbours already peek by equal
        // widths, and a nudge toward one of them is a lane off centre for no
        // gain — the thing the next click on a sliver would have to undo.
        if isCarousel(around: index, slots: slots, viewport: viewport) { return centred }
        return LanePeek.adjust(offset: centred, viewport: viewport, lanes: lanes, minimum: peek)
    }

    /// How many whole lanes have to fit across the strip before it stops being
    /// a carousel. Three is the smallest number that shows the focused lane and
    /// a whole neighbour on each side.
    static let carouselLanes = 3

    /// Whether the strip is too narrow, around the lane at `index`, to show it
    /// with a whole lane either side — and so focus centres it, with both
    /// neighbours peeking, and a click on either sliver pages one lane.
    ///
    /// Measured against the lanes *around* this one, because s, m and xl lanes
    /// differ: the three consecutive lanes centred on it, shifted inward at the
    /// two ends of the strip. A strip of fewer than three lanes is a carousel
    /// by definition, which costs nothing: when it all fits, every centring
    /// clamps to zero.
    ///
    /// A lane at least as wide as the window is not: nothing can peek past it,
    /// and centring it would hide its leading edge, where its header is.
    static func isCarousel(around index: Int, slots: [StripEdges.Slot], viewport: CGFloat) -> Bool {
        guard viewport > 0, slots.indices.contains(index) else { return false }
        guard slots[index].width < viewport else { return false }
        guard slots.count >= carouselLanes else { return true }
        let first = min(max(0, index - 1), slots.count - carouselLanes)
        let last = first + carouselLanes - 1
        return slots[last].end - slots[first].origin > viewport
    }

    /// Where the strip rests with `laneId` focused when the strip is a
    /// carousel around it, or nil when it is not.
    static func carousel(on laneId: String, lanes: [Lane], viewport: CGFloat) -> CGFloat? {
        guard viewport > 0, let index = lanes.firstIndex(where: { $0.id == laneId }) else { return nil }
        let slots = StripEdges.slots(of: lanes)
        guard isCarousel(around: index, slots: slots, viewport: viewport) else { return nil }
        return exactCentre(slots[index], lanes: lanes, viewport: viewport)
    }

    /// Where focus landing on `laneId` moves the strip: centred when the strip
    /// is a carousel around it, and otherwise the least movement, exactly as
    /// before. Every door focus comes in by — a click, ⌘[ / ⌘], the sidebar,
    /// ⌘P, a new lane — goes through here or through `centred`, and the two
    /// agree whenever this is a carousel.
    static func focused(
        from offset: CGFloat, to laneId: String, lanes: [Lane], viewport: CGFloat
    ) -> CGFloat? {
        carousel(on: laneId, lanes: lanes, viewport: viewport)
            ?? minimal(from: offset, to: laneId, lanes: lanes, viewport: viewport)
    }

    private static func exactCentre(_ slot: StripEdges.Slot, lanes: [Lane], viewport: CGFloat) -> CGFloat {
        let margins = margins(lanes: lanes, viewport: viewport)
        let limit = max(0, StripEdges.contentWidth(of: lanes) - viewport)
        return min(max(-margins.left, slot.origin - (viewport - slot.width) / 2), limit + margins.right)
    }

    /// How far past each end the strip may rest, so the first and last lanes
    /// centre like every other lane instead of stopping at the wall.
    ///
    /// A carousel centres the focused lane, and an end lane that could not be
    /// centred sat flush against its edge with a whole neighbour showing on
    /// the other side — which reads exactly like a middle lane, so nothing
    /// said *this is the end*. Empty strip past the lane says it. The margin
    /// is what centring the end lane needs and nothing more, per end, and it
    /// is zero when the whole strip fits (nothing scrolls) or when the strip
    /// is not a carousel around that lane (focus moves as little as it can,
    /// and the end of the strip is where it stops).
    ///
    /// The view turns these into content insets, so a drag can reach the same
    /// empty space a focus does and the snap settles there.
    static func margins(lanes: [Lane], viewport: CGFloat) -> (left: CGFloat, right: CGFloat) {
        guard viewport > 0, !lanes.isEmpty,
              StripEdges.contentWidth(of: lanes) > viewport
        else { return (0, 0) }
        let slots = StripEdges.slots(of: lanes)
        func margin(_ index: Int) -> CGFloat {
            guard isCarousel(around: index, slots: slots, viewport: viewport) else { return 0 }
            return max(0, (viewport - slots[index].width) / 2)
        }
        return (margin(0), margin(slots.count - 1))
    }

    /// The least movement that brings `laneId` fully on screen, and no peek.
    ///
    /// Arrow-key focus moves the strip as little as it can, and shaving 28 pt
    /// off the lane you just focused to prove another one exists is worse than
    /// the ambiguity it fixes. The snap after the next scroll picks it up.
    static func minimal(
        from offset: CGFloat, to laneId: String, lanes: [Lane], viewport: CGFloat
    ) -> CGFloat? {
        guard viewport > 0, let index = lanes.firstIndex(where: { $0.id == laneId }) else { return nil }
        let slot = StripEdges.slots(of: lanes)[index]
        // Left edge first, so a lane wider than the viewport shows its start
        // rather than its end — the header, the address and the top of the page
        // are all there.
        var x = offset
        if slot.origin < offset {
            x = slot.origin
        } else if slot.end > offset + viewport {
            x = slot.end - viewport
        }
        return clamp(x, lanes: lanes, viewport: viewport)
    }

    /// The lane a `near:` write just created — the one immediately right of the
    /// lane it was placed beside.
    ///
    /// `newWebLane(near:)` and `newTerminalLane(near:)` both land at `index + 1`
    /// and the reconcile has already run by the time either returns, so the new
    /// lane is found by position rather than by diffing pane ids.
    ///
    /// `lanes.last` is the tempting wrong answer and it looks right for months:
    /// it names the new lane only when the source lane happened to be the
    /// rightmost one on the strip, and silently reveals somebody else's lane
    /// otherwise.
    static func newest(rightOf laneId: String, in lanes: [Lane]) -> String? {
        guard let index = lanes.firstIndex(where: { $0.id == laneId }),
              lanes.indices.contains(index + 1)
        else { return nil }
        return lanes[index + 1].id
    }

    /// Inside the strip, measured from the lanes rather than from a view. The
    /// least-movement paths use this; a carousel centre uses `margins` too.
    private static func clamp(_ x: CGFloat, lanes: [Lane], viewport: CGFloat) -> CGFloat {
        min(max(0, x), max(0, StripEdges.contentWidth(of: lanes) - viewport))
    }
}

/// Where each lane's left edge sits, by summing widths — the strip's layout,
/// without a view.
///
/// Motion needs this twice over: a lane that moved has to start at the x it had
/// in the *previous* snapshot and slide to the one it has now, and neither
/// number is available from a view whose frame has already been set.
enum StripGeometry {
    static func origins(of lanes: [Lane]) -> [String: CGFloat] {
        var origins: [String: CGFloat] = [:]
        var x: CGFloat = 0
        for lane in lanes {
            origins[lane.id] = x
            x += CGFloat(lane.widthPt) + Theme.borderWidth
        }
        return origins
    }
}

/// The lane held still while lanes a sidebar fold hides leave the strip or
/// come back to it (ADR-0024).
///
/// A close or an arrival happens beside the lane you are in, by construction.
/// A fold does not: it takes a whole project, wherever its lanes sit, and any
/// of them left of the window would pull everything you can see sideways by
/// their width. So one lane is chosen and kept at the same place in the
/// window, and the strip scrolls under it by exactly what came or went.
struct StripAnchor: Equatable {
    var laneId: String
    /// Its left edge, measured from the left of the visible window.
    var x: CGFloat

    /// The focused lane when it is on screen and staying; otherwise the first
    /// lane on screen that is staying; nil when nothing on screen survives,
    /// and then focus moving to its heir is what brings the strip to rest.
    static func pick(
        before: [Lane], after: [Lane], focusedLaneId: String?, offset: CGFloat, width: CGFloat
    ) -> StripAnchor? {
        let staying = Set(after.map(\.id))
        let origins = StripGeometry.origins(of: before)
        let onScreen = before.filter { lane in
            guard staying.contains(lane.id), let x = origins[lane.id] else { return false }
            return x + CGFloat(lane.widthPt) > offset && x < offset + width
        }
        guard let lane = onScreen.first(where: { $0.id == focusedLaneId }) ?? onScreen.first,
              let x = origins[lane.id] else { return nil }
        return StripAnchor(laneId: lane.id, x: x - offset)
    }

    /// Where `laneId` starts in a layout whose columns may be part-way open
    /// or shut: `slots` is each such lane's current width.
    static func origin(of laneId: String, in lanes: [Lane], slots: [String: CGFloat]) -> CGFloat? {
        var x: CGFloat = 0
        for lane in lanes {
            if lane.id == laneId { return x }
            x += (slots[lane.id] ?? CGFloat(lane.widthPt)) + Theme.borderWidth
        }
        return nil
    }
}
