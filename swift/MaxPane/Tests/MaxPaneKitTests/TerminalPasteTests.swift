import Testing
import AppKit
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

/// ⌘V of a file copied in Finder: its full path, quoted when it has to be.
///
/// Every pasteboard here is a private, uniquely named one. Nothing in this
/// suite may touch `NSPasteboard.general`, which is the owner's clipboard.
@Suite("terminal paste of copied files")
struct TerminalPasteFileTests {
    /// A pasteboard nobody else has, holding what Finder writes for ⌘C: one
    /// item per file, each with the file URL and the display name as a string.
    private func withPasteboard<T>(_ body: (NSPasteboard) throws -> T) rethrows -> T {
        let pasteboard = NSPasteboard(name: .init("maxpane.tests.paste.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        return try body(pasteboard)
    }

    private func finderItem(_ url: URL) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.lastPathComponent, forType: .string)
        return item
    }

    private func pasted(_ paths: [String]) -> TerminalPaste.Clipboard {
        withPasteboard { pasteboard in
            pasteboard.writeObjects(paths.map { finderItem(URL(fileURLWithPath: $0)) })
            return TerminalPaste.clipboard(pasteboard)
        }
    }

    @Test("one file pastes its full path, bare, and the name flavour is ignored")
    func oneFile() {
        let got = pasted(["/Users/spierce/Downloads/report.pdf"])
        #expect(got == .init(text: "/Users/spierce/Downloads/report.pdf"))
    }

    @Test("every character of the bare set stays bare")
    func bareSet() {
        let path = "/tmp/aZ09._-+,:@%/x"
        #expect(TerminalPaste.shellWord(for: path) == path)
    }

    @Test("a space means double quotes")
    func space() {
        #expect(pasted(["/Users/spierce/My File.pdf"]).text == "\"/Users/spierce/My File.pdf\"")
    }

    @Test("the four characters live inside double quotes are escaped")
    func liveCharacters() {
        #expect(TerminalPaste.shellWord(for: "/t/a\\b") == "\"/t/a\\\\b\"")
        #expect(TerminalPaste.shellWord(for: "/t/a\"b") == "\"/t/a\\\"b\"")
        #expect(TerminalPaste.shellWord(for: "/t/a$b") == "\"/t/a\\$b\"")
        #expect(TerminalPaste.shellWord(for: "/t/a`b") == "\"/t/a\\`b\"")
        #expect(pasted(["/t/cost $5 \"final\".txt"]).text == "\"/t/cost \\$5 \\\"final\\\".txt\"")
    }

    @Test("other shell characters need the quotes and nothing more")
    func otherShellCharacters() {
        for ch in ["'", "*", "?", "(", ")", "[", "&", ";", "|", "<", ">", "#", "~", "=", "{"] {
            #expect(TerminalPaste.shellWord(for: "/t/a\(ch)b") == "\"/t/a\(ch)b\"")
        }
    }

    @Test("a ! gets single quotes, the one case that does")
    func bang() {
        #expect(pasted(["/t/wow!.txt"]).text == "'/t/wow!.txt'")
        #expect(TerminalPaste.shellWord(for: "/t/it's $5!") == "'/t/it'\\''s $5!'")
    }

    @Test("a name with a newline is refused, the rest paste, and the notice names it")
    func controlCharacter() {
        let got = pasted(["/t/one.txt", "/t/bad\nname.txt", "/t/two.txt"])
        #expect(got.text == "/t/one.txt /t/two.txt")
        #expect(got.skippedFiles == ["bad?name.txt"])
        #expect(got.notice == "skipped \"bad?name.txt\": a control character in its name")
        for bad in ["a\tb", "a\u{1b}[31m", "a\u{7f}", "a\u{85}", "a\rb"] {
            #expect(TerminalPaste.shellWord(for: bad) == nil)
        }
    }

    @Test("only refused files: nothing is pasted, and the name flavour is not a fallback")
    func onlyRefused() {
        let got = pasted(["/t/a\nb", "/t/c\nd"])
        #expect(got.text == nil)
        #expect(got.notice == "skipped 2 files with control characters in their names")
    }

    @Test("three files, in order, space-separated, no trailing space or newline")
    func threeFiles() {
        let got = pasted(["/t/c.txt", "/t/a b.txt", "/t/b.txt"])
        #expect(got.text == "/t/c.txt \"/t/a b.txt\" /t/b.txt")
        #expect(got.notice == nil)
        #expect(TerminalPaste.bytes(for: got.text ?? "") == Array("/t/c.txt \"/t/a b.txt\" /t/b.txt".utf8))
    }

    @Test("a web URL is not a file: the string wins")
    func webURL() {
        let got = withPasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setString("https://example.com/a b", forType: .URL)
            item.setString("https://example.com/a%20b", forType: .string)
            pasteboard.writeObjects([item])
            return TerminalPaste.clipboard(pasteboard)
        }
        #expect(got == .init(text: "https://example.com/a%20b", isCopiedText: true))
    }

    @Test("plain text is exactly what it was, and an empty pasteboard is nothing")
    func plainText() {
        let text = "echo \"$HOME\" !\n"
        let got = withPasteboard { pasteboard in
            pasteboard.setString(text, forType: .string)
            return TerminalPaste.clipboardText(pasteboard)
        }
        #expect(got == text)
        #expect(withPasteboard { TerminalPaste.clipboard($0) } == .init())
    }

    @Test("non-ASCII letters paste bare, composed or decomposed, and not percent-encoded")
    func nonASCII() {
        #expect(pasted(["/t/café/日本語.txt"]).text == "/t/café/日本語.txt")
        let decomposed = "/t/cafe\u{301}.txt"
        #expect(TerminalPaste.shellWord(for: decomposed) == decomposed)
        // Not letters: an emoji and a no-break space are quoted, harmlessly.
        #expect(TerminalPaste.shellWord(for: "/t/🇺🇸") == "\"/t/🇺🇸\"")
        #expect(TerminalPaste.shellWord(for: "/t/a\u{a0}b") == "\"/t/a\u{a0}b\"")
    }

    @Test("a directory has no trailing slash, and the empty word is still a word")
    func edges() {
        #expect(pasted(["/t/dir/"]).text == "/t/dir")
        #expect(TerminalPaste.shellWord(for: "") == "\"\"")
    }

    @Test("a /.file/id= reference URL pastes the path it refers to")
    func fileReferenceURL() throws {
        // A reference only exists for a real file, so this one test makes one.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane paste \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("shot.png")
        try Data().write(to: file)

        // Swift's `URL` cannot hold a reference (the bridge resolves it), so
        // the reference is fetched and kept as the `NSURL` it is, and written
        // the way Finder writes one: as the item's file-URL string.
        let made = (file as NSURL).perform(#selector(NSURL.fileReferenceURL))?.takeUnretainedValue()
        let reference = try #require((made as? NSURL)?.absoluteString)
        #expect(reference.hasPrefix("file:///.file/id="))
        let got = withPasteboard { pasteboard in
            let item = NSPasteboardItem()
            item.setString(reference, forType: .fileURL)
            item.setString("shot.png", forType: .string)
            pasteboard.writeObjects([item])
            return TerminalPaste.clipboard(pasteboard)
        }
        let text = try #require(got.text)
        #expect(!text.contains("/.file/"))
        #expect(text.hasPrefix("\"/"))
        #expect(text.hasSuffix("/shot.png\""))
        #expect(text.contains((dir.lastPathComponent)))
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
