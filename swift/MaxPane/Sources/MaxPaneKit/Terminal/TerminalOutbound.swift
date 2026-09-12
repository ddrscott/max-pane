import Foundation

/// The one road out of a terminal pane: bytes the emulator produced, delivered
/// in the order it produced them.
///
/// Ghostty hands a write over on whichever thread its surface was parsing on,
/// and the Relay client writes its frames from one thread only — so the bytes
/// have to change hands somewhere. The hand-over this replaces was a
/// `Task { @MainActor in … }` per write, and that was never safe: unstructured
/// tasks are ordered with respect to nothing, so two writes handed over back to
/// back can reach the PTY the wrong way round, or interleaved. It survived
/// because a keystroke is one write and nobody types fast enough to catch it.
/// Anything the emulator emits in more than one piece — a paste, a mouse
/// report, a reply to a device query — is a byte stream whose order *is* its
/// meaning, and a reordered one is not a slower paste but a different one.
///
/// So: a lock-guarded FIFO, drained on the main queue, which is itself FIFO.
/// Ordering is a property of the structure rather than of scheduling luck.
final class TerminalOutbound: @unchecked Sendable {
    /// Bytes waiting for their turn on the main queue. Coalesced on purpose —
    /// a paste that arrives as four writes should leave as one frame, and for
    /// a byte stream "all of it, in order" and "each piece, in order" are the
    /// same thing.
    private var pending: [UInt8] = []
    private var isDrainScheduled = false
    private let lock = NSLock()
    private let deliver: @MainActor @Sendable ([UInt8]) -> Void
    /// Test seam: how a drain gets onto the main queue.
    private let schedule: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(
        schedule: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.main.async(execute: $0)
        },
        deliver: @escaping @MainActor @Sendable ([UInt8]) -> Void
    ) {
        self.schedule = schedule
        self.deliver = deliver
    }

    /// Queue bytes for the PTY. Safe from any thread.
    func enqueue(_ data: Data) {
        enqueue([UInt8](data))
    }

    func enqueue(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        lock.lock()
        pending.append(contentsOf: bytes)
        let needsSchedule = !isDrainScheduled
        isDrainScheduled = true
        lock.unlock()
        // One drain in flight at a time: a second would find nothing and the
        // first already carries everything that arrived while it waited.
        guard needsSchedule else { return }
        schedule { [weak self] in
            MainActor.assumeIsolated { self?.drain() }
        }
    }

    @MainActor
    private func drain() {
        lock.lock()
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        isDrainScheduled = false
        lock.unlock()
        guard !bytes.isEmpty else { return }
        deliver(bytes)
    }
}

/// Input that had nowhere to go yet.
///
/// A lane exists before its attachment does: `maxpane run` focuses the pane in
/// the ledger a run loop or two before Relay's socket answers, and every
/// reconnect reopens the same window. Sends during that window used to go on
/// the floor with no trace — no error, no log, a pane that looks entirely
/// alive. Holding the bytes costs a few kilobytes and makes the first paste
/// into a fresh lane behave like the tenth.
///
/// Two rules keep held input from becoming a surprise:
///
/// - **All or nothing.** Past the cap the whole buffer is dropped rather than
///   trimmed at either end. Half a command is worse than no command: a prefix
///   can be a shorter valid command, and a suffix can be an argument to
///   whatever the shell had already.
/// - **Fresh or nothing.** Input is meant for the prompt that was in front of
///   the user when they typed it. Delivered minutes later it is a command
///   arriving out of nowhere, so a stale buffer is dropped too.
struct PendingInput {
    /// Enough for any paste a person makes by hand, and far more than anyone
    /// types into an unresponsive pane before giving up.
    static let limit = 64 * 1024
    /// A reconnect is measured in fractions of a second; a session that took
    /// this long to come back is a different moment in the user's day.
    static let maxAge: TimeInterval = 5

    private(set) var bytes: [UInt8] = []
    /// When the *oldest* held byte was written. One stamp for the buffer, not
    /// per chunk, so staleness can only ever drop the whole thing.
    private(set) var since: Date?

    var isEmpty: Bool { bytes.isEmpty }

    /// Hold bytes until there is somewhere to send them. Returns false when
    /// the buffer was dropped instead, which the caller logs.
    @discardableResult
    mutating func hold(_ incoming: ArraySlice<UInt8>, now: Date = Date()) -> Bool {
        guard !incoming.isEmpty else { return true }
        if bytes.isEmpty { since = now }
        guard bytes.count + incoming.count <= Self.limit else {
            clear()
            return false
        }
        bytes.append(contentsOf: incoming)
        return true
    }

    /// Everything held, if it is still worth sending. Empties the buffer either
    /// way — a flush that decides against the bytes must not leave them to be
    /// considered again on the next reconnect.
    mutating func take(now: Date = Date()) -> [UInt8]? {
        guard !bytes.isEmpty else { return nil }
        let held = bytes
        let age = since.map { now.timeIntervalSince($0) } ?? 0
        clear()
        return age <= Self.maxAge ? held : nil
    }

    mutating func clear() {
        bytes.removeAll(keepingCapacity: false)
        since = nil
    }
}
