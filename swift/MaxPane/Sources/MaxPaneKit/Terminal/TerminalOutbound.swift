import Foundation
import RelayClient

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
    /// a paste that arrives as four writes should leave as one delivery, and
    /// for a byte stream "all of it, in order" and "each piece, in order" are
    /// the same thing. How it is cut for the wire is decided further down the
    /// road, by `PacedInput`.
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

/// Input on its way to a session, a piece at a time: at most
/// `InputChunks.limit` bytes per message, and at most one message per `gap`.
///
/// **Why pieces.** A pty-host older than relay-tty 1.23 wrote each input
/// message to its non-blocking PTY once and dropped whatever did not fit,
/// which on macOS is everything past 1 022 bytes. A session keeps the pty-host
/// it was started with, and nothing on the wire says which kind it is.
///
/// **Why a gap.** The pieces only help if the program has read the last one
/// before the next arrives. Measured against that old pty-host on this Mac
/// (`spikes/m7-remote-relay`, `m7 paste --chunk 1000 --gap-ms N`): with no gap
/// 20 KB of 64 KB arrived; with 1 ms a reader taking big reads got all of it
/// and one reading a byte at a time, as a line editor does, did not; with 5 ms
/// both did, at 256 KB. So 5 ms: 200 KB/s at best, which is three times
/// iTerm's default paste speed, and a 1 MB paste takes about seven seconds on
/// a new pty-host that would have taken it at once. That is the price of not
/// knowing, and it is only paid by pastes that are large.
///
/// A keystroke pays nothing: the first piece of anything leaves at once, and
/// the gap is only ever waited out by bytes that arrived during it.
///
/// One FIFO, so what is typed during a long paste goes out after it, whole,
/// and never in the middle of it.
///
/// **Paste Slowly is this queue too**, not a second one (`enqueue(_:pace:)`):
/// a stretch of `pending` marked to leave in smaller pieces with a longer gap.
/// A second queue beside this one would have to be interleaved with it by
/// somebody, and the order of a byte stream is its meaning. What came before
/// the slow stretch leaves at the usual pace, what comes after waits its turn,
/// and cancelling removes the unsent part of the stretch and nothing else.
@MainActor
final class PacedInput {
    static let gap: TimeInterval = 0.005

    /// How a slow stretch leaves: at most `chunk` bytes a message, one message
    /// per `gap`. `paste_slow_chunk` and `paste_slow_delay_ms`.
    struct Pace: Equatable {
        var chunk: Int
        var gap: TimeInterval

        init(chunk: Int = 16, gap: TimeInterval = 0.010) {
            // A message is never bigger than any other message may be.
            self.chunk = min(max(chunk, 1), InputChunks.limit)
            self.gap = max(gap, 0)
        }
    }

    /// What became of a slow stretch, said to whoever asked for it.
    enum SlowEvent: Equatable {
        /// So many of its bytes have been handed over.
        case sent(Int, of: Int)
        case finished(Int)
        /// Stopped early. The rest was removed and will never be sent.
        case cancelled(sent: Int, of: Int)
    }

    private struct Slow {
        /// Its bytes are `pending[start..<end]`.
        var start: Int
        var end: Int
        var pace: Pace
        var report: (SlowEvent) -> Void
    }
    /// The slow stretch, while there is one. One at a time.
    private var slow: Slow?

    private var pending: [UInt8] = []
    /// Where the unsent part of `pending` starts. An index rather than a
    /// `removeFirst` per piece, which for a 1 MB paste is a thousand memmoves
    /// of half a megabyte.
    private var head = 0
    /// A gap is being waited out; its end sends the next piece.
    private var isWaiting = false
    private let gap: TimeInterval
    private let after: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let deliver: ([UInt8]) -> Void

    /// `after` is the test seam: how the end of a gap gets back here.
    init(
        gap: TimeInterval = PacedInput.gap,
        after: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, block in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated(block) }
        },
        deliver: @escaping ([UInt8]) -> Void
    ) {
        self.gap = gap
        self.after = after
        self.deliver = deliver
    }

    /// Bytes not yet handed to `deliver`.
    var backlog: Int { pending.count - head }

    func enqueue(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        pending.append(contentsOf: bytes)
        if !isWaiting { sendNext() }
    }

    /// A slow stretch is still going out.
    var isSlow: Bool { slow != nil }

    /// `bytes`, in order behind whatever is already waiting, at `pace`.
    /// `report` hears how it goes, last of all `.finished` or `.cancelled`.
    ///
    /// One at a time: a second while the first is still going is ordinary
    /// input, queued behind it at the usual pace, and says it finished.
    func enqueue(_ bytes: ArraySlice<UInt8>, pace: Pace, report: @escaping (SlowEvent) -> Void) {
        guard !bytes.isEmpty, slow == nil else {
            enqueue(bytes)
            report(.finished(bytes.count))
            return
        }
        slow = Slow(start: pending.count, end: pending.count + bytes.count, pace: pace, report: report)
        pending.append(contentsOf: bytes)
        if !isWaiting { sendNext() }
    }

    /// Stop the slow stretch: what it has not sent is removed, and is never
    /// sent. What was queued behind it (the key that cancelled it) follows at
    /// the usual pace. Nothing to cancel, nothing done.
    func cancelSlow() {
        guard let slow else { return }
        let from = max(head, slow.start)
        pending.removeSubrange(from..<slow.end)
        self.slow = nil
        slow.report(.cancelled(sent: from - slow.start, of: slow.end - slow.start))
    }

    /// Everything not yet sent, handed back. For a wire that has gone: the
    /// adapter holds it as it holds anything typed while disconnected.
    ///
    /// Not the rest of a slow stretch, which is cancelled instead: held input
    /// is flushed at full speed on reconnect, which is the one thing whoever
    /// asked for a slow paste said the far end could not take.
    func takeBacklog() -> [UInt8] {
        cancelSlow()
        let rest = Array(pending[head...])
        pending.removeAll(keepingCapacity: false)
        head = 0
        return rest
    }

    private func sendNext() {
        guard head < pending.count else {
            pending.removeAll(keepingCapacity: false)
            head = 0
            return
        }
        // A piece is all slow or all not: it stops where the stretch starts,
        // and inside the stretch it is the stretch's size and gap.
        var limit = InputChunks.limit
        var wait = gap
        var stop = pending.count
        if let slow {
            if head < slow.start {
                stop = slow.start
            } else {
                limit = slow.pace.chunk
                wait = slow.pace.gap
                stop = slow.end
            }
        }
        let end = min(InputChunks.end(ofPieceAt: head, in: pending, limit: limit), stop)
        let piece = Array(pending[head..<end])
        head = end
        isWaiting = true
        // The pacer is held by its adapter, and a gap that outlives both has
        // nothing left to send.
        after(wait) { [weak self] in
            self?.isWaiting = false
            self?.sendNext()
        }
        deliver(piece)
        guard let slow, end > slow.start else { return }
        if end >= slow.end {
            self.slow = nil
            slow.report(.finished(slow.end - slow.start))
        } else {
            slow.report(.sent(end - slow.start, of: slow.end - slow.start))
        }
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
