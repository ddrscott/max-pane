import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

/// A ⌘C in a web pane (ADR-0041): what it keeps, what it never keeps, and how
/// long it is willing to wait for WebKit's copy to land.
///
/// Every pasteboard here is a private named one. `NSPasteboard.general` is
/// never read or written, and no page is served: what is under test is the
/// pane's decision about what a copy left behind, not WebKit's copy.

@Suite("a web pane's copy: what is kept")
@MainActor
struct WebClipboardReadingTests {
    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: .init("maxpane.tests.web-clipboard.\(UUID().uuidString)"))
        board.clearContents()
        return board
    }

    private func png() -> Data {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    @Test("text is kept as it is")
    func text() {
        let board = board()
        defer { board.releaseGlobally() }
        board.setString("ghp_not_a_real_token", forType: .string)
        #expect(WebClipboard.copied(on: board, imagesAsFiles: true) == .text("ghp_not_a_real_token"))
    }

    @Test("nothing, and whitespace, are nothing")
    func nothing() {
        let board = board()
        defer { board.releaseGlobally() }
        #expect(WebClipboard.copied(on: board, imagesAsFiles: true) == nil)
        board.setString("  \n\t", forType: .string)
        #expect(WebClipboard.copied(on: board, imagesAsFiles: true) == nil)
    }

    @Test("a pasteboard a password manager marked is not kept, though it still pastes")
    func marked() {
        let board = board()
        defer { board.releaseGlobally() }
        board.declareTypes([.string, .init("org.nspasteboard.ConcealedType")], owner: nil)
        board.setString("hunter2", forType: .string)
        #expect(TerminalPaste.clipboard(board).text == "hunter2")
        #expect(WebClipboard.copied(on: board, imagesAsFiles: true) == nil)
    }

    @Test("a picture and nothing else is a picture; with an address beside it the address is what was meant")
    func picture() {
        let board = board()
        defer { board.releaseGlobally() }
        let bytes = png()
        board.declareTypes([.png], owner: nil)
        board.setData(bytes, forType: .png)
        #expect(WebClipboard.copied(on: board, imagesAsFiles: true) == .picture(bytes))
        // Off, a copied picture has no path to keep and so is not kept.
        #expect(WebClipboard.copied(on: board, imagesAsFiles: false) == nil)

        let both = self.board()
        defer { both.releaseGlobally() }
        both.declareTypes([.png, .string], owner: nil)
        both.setData(bytes, forType: .png)
        both.setString("https://example.com/cat.png", forType: .string)
        #expect(WebClipboard.copied(on: both, imagesAsFiles: true) == .text("https://example.com/cat.png"))
    }
}

@Suite("a web pane's copy: waiting for it to land, and never longer")
@MainActor
struct WebClipboardSettleTests {
    @Test("the callback comes when the contents change")
    func lands() async throws {
        let board = NSPasteboard(name: .init("maxpane.tests.web-clipboard.settle.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let before = board.changeCount
        var landed: String?
        // A window far wider than the app's fifth of a second: the suites run
        // beside each other and every wait here takes as long as the main
        // thread is busy for.
        WebClipboard.whenCopyLands(on: board, after: before, within: 30.0, step: 0.01) {
            landed = $0.string(forType: .string)
        }
        // As WebKit does: some turns after the copy was performed.
        try await Task.sleep(nanoseconds: 20_000_000)
        board.clearContents()
        board.setString("from the page", forType: .string)
        for _ in 0..<200 where landed == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(landed == "from the page")
    }

    @Test("past the window nothing is read, however long the main thread was busy")
    func neverLands() async throws {
        let board = NSPasteboard(name: .init("maxpane.tests.web-clipboard.quiet.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("something somebody else copied", forType: .string)
        var looked = false
        WebClipboard.whenCopyLands(on: board, after: board.changeCount, within: 0.05, step: 0.01) { _ in
            looked = true
        }
        // Long past the window — and a busy main thread makes every wait here
        // longer than it asked for, which is exactly the case the deadline is
        // wall clock for. What is on the pasteboard by now is not this copy's.
        try await Task.sleep(nanoseconds: 300_000_000)
        board.clearContents()
        board.setString("and this is what they copied next", forType: .string)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!looked, "nothing is recorded once the copy's own window has passed")
    }
}

@Suite("a web pane's copy: the row it leaves")
@MainActor
struct WebClipboardRecordingTests {
    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let board: NSPasteboard
        var pane: WebPaneController!

        init(private isPrivate: Bool = false) throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-web-clip-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newWebLane(url: "https://example.com/", near: nil, private: isPrivate)
            board = NSPasteboard(name: .init("maxpane.tests.web-clipboard.rig.\(UUID().uuidString)"))
            board.clearContents()
            let lane = store.state.lanes[0]
            // Deferred: this is about what the pane keeps, so it needs no page
            // and builds no web view.
            pane = WebPaneController(
                pane: lane.panes[0], lane: lane, store: store, config: Config(), deferLoad: true,
                blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
            pane.clipPasteboard = board
            pane.pastedImages = PastedImages(directory: dir.appendingPathComponent("paste"))
        }

        var kept: [ClipEntry] { store.clipHistory(Config()) }

        func close() {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("a copy off a page is a copy, from the web, and is listed with the terminals'")
    func text() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.board.setString("npm run dev", forType: .string)
        rig.pane.remember(copiedOn: rig.board)
        let kept = try #require(rig.kept.first)
        #expect(kept.content == "npm run dev")
        #expect(kept.kind == .copy)
        #expect(kept.source == .web)
    }

    @Test("what is shaped like a secret is four characters and ••• here too")
    func secret() throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.board.setString("ghp_abcdefghijklmnopqrstuvwxyz0123456789", forType: .string)
        rig.pane.remember(copiedOn: rig.board)
        let kept = try #require(rig.kept.first)
        #expect(kept.content == "ghp_•••")
        #expect(kept.redacted)
    }

    @Test("a private lane keeps nothing, and the refusal is the ledger's")
    func privateLane() throws {
        let rig = try Rig(private: true)
        defer { rig.close() }
        rig.board.setString("the other account's token", forType: .string)
        rig.pane.remember(copiedOn: rig.board)
        #expect(rig.kept.isEmpty)
    }

    @Test("paste_history off keeps nothing")
    func off() throws {
        let rig = try Rig()
        defer { rig.close() }
        var config = Config()
        config.pasteHistory = false
        rig.pane.liveConfig = { config }
        rig.board.setString("not kept", forType: .string)
        rig.pane.remember(copiedOn: rig.board)
        #expect(rig.kept.isEmpty)
    }

    @Test("a copied picture becomes a file and the row is its path")
    func picture() throws {
        let rig = try Rig()
        defer { rig.close() }
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let bytes = NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!
        rig.board.declareTypes([.png], owner: nil)
        rig.board.setData(bytes, forType: .png)
        rig.pane.remember(copiedOn: rig.board)

        let kept = try #require(rig.kept.first)
        #expect(kept.source == .web)
        let path = kept.content.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        #expect(path.hasSuffix(".png"))
        // Under the pasted-images store, named for what it was.
        #expect(URL(fileURLWithPath: path).lastPathComponent.hasPrefix("copy-"))
        #expect(FileManager.default.contents(atPath: path) == bytes)
        // And swept by the same prune as a pasted picture.
        let images = PastedImages(directory: rig.dir.appendingPathComponent("paste"))
        #expect(images.prune(olderThanDays: 1, now: Date().addingTimeInterval(2 * 86_400)).count == 1)
    }
}
