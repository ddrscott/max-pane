import Testing
import Foundation
@testable import MaxPaneKit

/// What ⌘V puts on the wire.
///
/// The bug these exist for was visible on the owner's prompt as
/// `[200~PASTE_PROBE_123~`: the local emulator framed a paste in
/// bracketed-paste markers because *it* believed DECSET 2004 was on, and the
/// shell at the far end of the socket had never heard of it. Nothing in here
/// may ever produce an ESC that the clipboard did not contain.
@Suite("terminal paste bytes")
struct TerminalPasteTests {
    @Test("plain text goes out unchanged")
    func plainText() {
        #expect(TerminalPaste.bytes(for: "echo hi") == Array("echo hi".utf8))
    }

    @Test("no escape byte is ever added")
    func neverFramesThePaste() {
        for text in ["ls", "echo one\ntwo\n", "a\tb", "café 日本 🇺🇸"] {
            #expect(!TerminalPaste.bytes(for: text).contains(0x1b), "added an escape to \(text)")
        }
    }

    @Test("a trailing newline does not press Return")
    func dropsTrailingNewline() {
        // Copying a command out of a README brings its newline. Without
        // bracketed paste that newline runs the line before it can be read.
        #expect(TerminalPaste.bytes(for: "rm -rf build\n") == Array("rm -rf build".utf8))
        #expect(TerminalPaste.bytes(for: "rm -rf build\r\n") == Array("rm -rf build".utf8))
        #expect(TerminalPaste.bytes(for: "rm -rf build\n\n\n") == Array("rm -rf build".utf8))
        #expect(TerminalPaste.bytes(for: "\n").isEmpty)
    }

    @Test("interior line endings become the byte Return sends")
    func interiorNewlinesBecomeCarriageReturns() {
        #expect(TerminalPaste.bytes(for: "one\ntwo") == Array("one\rtwo".utf8))
        #expect(TerminalPaste.bytes(for: "one\r\ntwo") == Array("one\rtwo".utf8))
        #expect(TerminalPaste.bytes(for: "one\rtwo") == Array("one\rtwo".utf8))
        // A blank line between two commands is one blank line, not two.
        #expect(TerminalPaste.bytes(for: "one\r\n\r\ntwo") == Array("one\r\rtwo".utf8))
    }

    @Test("multi-byte text survives byte for byte")
    func multiByteSurvives() {
        let text = "echo '✳ 日本 🇺🇸'"
        #expect(TerminalPaste.bytes(for: text) == Array(text.utf8))
    }

    @Test("control bytes in the clipboard are the clipboard's business")
    func passesThroughWhatWasCopied() {
        // Copying coloured terminal output copies its escapes. They are what
        // the user put on the clipboard; inventing new ones is the bug.
        let coloured = "\u{1b}[32mok\u{1b}[0m"
        #expect(TerminalPaste.bytes(for: coloured) == Array(coloured.utf8))
    }
}

/// Ordering of the outgoing byte stream.
///
/// The implementation this replaced started a `Task { @MainActor in … }` per
/// write. Unstructured tasks are ordered with respect to nothing, so these
/// tests are about the property, not the timing: whatever went in comes out in
/// that order, in one piece.
@Suite("outbound byte ordering")
@MainActor
struct TerminalOutboundTests {
    /// Collects the drains instead of scheduling them, so a test can decide
    /// when the main queue gets its turn.
    final class Scheduler: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [@Sendable () -> Void] = []

        func schedule(_ block: @escaping @Sendable () -> Void) {
            lock.lock(); work.append(block); lock.unlock()
        }

        func runAll() {
            lock.lock(); let pending = work; work.removeAll(); lock.unlock()
            for block in pending { block() }
        }

        var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
    }

    @Test("writes arrive in the order they were made")
    func preservesOrder() {
        let scheduler = Scheduler()
        let delivered = Delivered()
        let outbound = TerminalOutbound(schedule: scheduler.schedule) { delivered.append($0) }

        for byte in Array("PASTE_PROBE_123".utf8) { outbound.enqueue([byte]) }
        scheduler.runAll()

        #expect(delivered.all == Array("PASTE_PROBE_123".utf8))
    }

    @Test("writes made before the queue gets a turn leave together")
    func coalescesUntilDrained() {
        let scheduler = Scheduler()
        let delivered = Delivered()
        let outbound = TerminalOutbound(schedule: scheduler.schedule) { delivered.append($0) }

        outbound.enqueue(Data("one".utf8))
        outbound.enqueue(Data("two".utf8))
        // One drain in flight, not two: the first carries everything that
        // arrived while it waited.
        #expect(scheduler.count == 1)

        scheduler.runAll()
        #expect(delivered.batches == [Array("onetwo".utf8)])
    }

    @Test("a drained queue schedules again for the next write")
    func schedulesAgainAfterDraining() {
        let scheduler = Scheduler()
        let delivered = Delivered()
        let outbound = TerminalOutbound(schedule: scheduler.schedule) { delivered.append($0) }

        outbound.enqueue(Data("a".utf8))
        scheduler.runAll()
        outbound.enqueue(Data("b".utf8))
        scheduler.runAll()

        #expect(delivered.batches == [Array("a".utf8), Array("b".utf8)])
    }

    @Test("an empty write is not a turn of the main queue")
    func ignoresEmptyWrites() {
        let scheduler = Scheduler()
        let outbound = TerminalOutbound(schedule: scheduler.schedule) { _ in }
        outbound.enqueue(Data())
        #expect(scheduler.count == 0)
    }

    @MainActor
    final class Delivered {
        private(set) var batches: [[UInt8]] = []
        var all: [UInt8] { batches.flatMap { $0 } }
        func append(_ bytes: [UInt8]) { batches.append(bytes) }
    }
}

/// Input typed at a pane whose socket was not up yet.
///
/// A paste into a lane seconds old used to vanish: the attachment's `send` was
/// `session?.sendInput(...)`, and a nil session took the bytes with it.
@Suite("input held while disconnected")
struct PendingInputTests {
    @Test("held input comes back in order")
    func holdsAndReturnsInOrder() {
        var pending = PendingInput()
        pending.hold(Array("echo ".utf8)[...])
        pending.hold(Array("hi".utf8)[...])
        #expect(pending.take() == Array("echo hi".utf8))
        // Taken once, gone: a reconnect must not run it a second time.
        #expect(pending.take() == nil)
    }

    @Test("past the cap the whole buffer goes, not either end of it")
    func dropsEverythingOverTheCap() {
        var pending = PendingInput()
        pending.hold(Array("rm -rf ".utf8)[...])
        // Trimming the front would leave `~/work` as a command; trimming the
        // back would leave `rm -rf ` to take whatever is typed next.
        let heldEverything = pending.hold(ArraySlice([UInt8](repeating: 0x61, count: PendingInput.limit)))
        #expect(!heldEverything)
        #expect(pending.isEmpty)
        #expect(pending.take() == nil)
    }

    @Test("input a person has stopped expecting is not run late")
    func dropsStaleInput() {
        var pending = PendingInput()
        let typedAt = Date()
        pending.hold(Array("deploy prod".utf8)[...], now: typedAt)
        let tooLate = typedAt.addingTimeInterval(PendingInput.maxAge + 1)
        #expect(pending.take(now: tooLate) == nil)
        #expect(pending.isEmpty)
    }

    @Test("a reconnect inside the window still delivers")
    func deliversAfterAQuickReconnect() {
        var pending = PendingInput()
        let typedAt = Date()
        pending.hold(Array("ls".utf8)[...], now: typedAt)
        // The reconnect backoff starts at 0.5s; this is the common case.
        #expect(pending.take(now: typedAt.addingTimeInterval(0.6)) == Array("ls".utf8))
    }

    @Test("age is the oldest byte's, so one buffer is one decision")
    func ageIsTheOldestBytes() {
        var pending = PendingInput()
        let start = Date()
        pending.hold(Array("a".utf8)[...], now: start)
        pending.hold(Array("b".utf8)[...], now: start.addingTimeInterval(PendingInput.maxAge))
        // The second chunk is fresh, but it is the tail of something stale —
        // delivering it alone would send `b` as a command of its own.
        #expect(pending.take(now: start.addingTimeInterval(PendingInput.maxAge + 0.1)) == nil)
    }
}
