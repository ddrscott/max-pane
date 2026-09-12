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

    /// System Settings › Accessibility › Display › Reduce motion.
    ///
    /// Read per transition rather than cached: it is a live preference, and
    /// someone who turns it on mid-session has said what they want *now*. With
    /// it on, every transition below runs its final frame immediately and calls
    /// its completion — so the result is identical, it simply has no middle.
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
