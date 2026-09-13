import Foundation

/// Which panes are currently waiting on a person, in the order they started
/// waiting.
///
/// This is the answer to *what happens when the asking lane is scrolled off
/// screen*. The sheet itself is inside the lane and cannot be seen from the
/// other end of a strip; without this, a page 15 lanes back would stop dead and
/// the only evidence would be a pane you were not looking at.
///
/// **It never moves the viewport by itself.** That is the whole point: a
/// background page that can scroll the strip to itself is the freeze bug with
/// extra steps — a `setTimeout` firing `confirm()` would yank you out of the
/// terminal you are typing in. It raises a signal and waits to be clicked.
///
/// The signal is the one this app already has for *this one needs you*: the
/// status bar's Signal Orange count, beside `N BLOCKED`, which is the same
/// sentence about an agent. `next()` walks the queue oldest-first so clicking
/// it repeatedly visits every waiting lane exactly once and comes back round.
@MainActor
final class WebAskCenter {
    static let shared = WebAskCenter()

    /// Pane ids with at least one ask on screen, oldest first.
    private(set) var waiting: [String] = []
    /// Where `next()` has got to. An index rather than a rotation of the array,
    /// because the array's order is *when the page asked* and rotating it would
    /// make the oldest question drift to the back of the queue for no reason
    /// other than someone having looked at it.
    private var cursor = 0

    private var observers: [UUID: () -> Void] = [:]

    var count: Int { waiting.count }

    func observe(_ block: @escaping () -> Void) -> UUID {
        let token = UUID()
        observers[token] = block
        return token
    }

    func stopObserving(_ token: UUID) { observers[token] = nil }

    func began(paneId: String) {
        guard !waiting.contains(paneId) else { return }
        waiting.append(paneId)
        publish()
    }

    /// Called when a pane's last ask is answered, and when a pane is torn down
    /// with asks outstanding. Both are "this pane is no longer waiting", and a
    /// pane that stayed in the list after it died would leave a count on the
    /// status bar that nothing could ever clear.
    func ended(paneId: String) {
        guard let index = waiting.firstIndex(of: paneId) else { return }
        waiting.remove(at: index)
        if cursor > index { cursor -= 1 }
        publish()
    }

    /// The next pane to show someone, cycling.
    func next() -> String? {
        guard !waiting.isEmpty else { return nil }
        if cursor >= waiting.count { cursor = 0 }
        let paneId = waiting[cursor]
        cursor = (cursor + 1) % waiting.count
        return paneId
    }

    private func publish() {
        for block in observers.values { block() }
    }
}
