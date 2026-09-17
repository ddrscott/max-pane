import AppKit
import PDFKit
import Testing
import WebKit
@testable import MaxPaneKit

/// Print and Save as PDF: the commands, and the PDF itself in real WebKit.
///
/// The print panel is macOS's and is not driven here — what is worth a test is
/// that the command exists, lives where a Mac user looks for Print, is dead on
/// a terminal pane and prints the popup's own page from inside a popup. The
/// PDF half is proven on a loopback page taller than the view: `createPDF`
/// with the view's bounds would give one fold of a receipt, and the assertion
/// that the *bottom* line is in the file is the assertion that it does not.
struct WebPrintCommandTests {
    @Test("Print… and Save as PDF… are File-menu commands, and only a page can answer them")
    func commandsExist() {
        #expect(Command.printPage.title == "Print…")
        #expect(Command.savePDF.title == "Save as PDF…")
        #expect(Command.printPage.menu == .file)
        #expect(Command.savePDF.menu == .file)
        // Only a page has a document to print; `canPerform` greys the items
        // out on a terminal through this predicate.
        #expect(Command.printPage.needsWebPane)
        #expect(Command.savePDF.needsWebPane)
        #expect(!Command.reload.needsWebPane)
        #expect(!Command.closePane.needsWebPane)
        #expect(!Command.claimSession.needsWebPane)
    }

    @Test("⌃⌘P, because ⌘P is the palette; Save as PDF ships without a key and is bindable")
    func defaultKeys() {
        #expect(Keymap.defaults.chords(for: .printPage) == [KeyChord(key: "p", modifiers: [.command, .control])])
        #expect(Keymap.defaults.chords(for: .search) == [KeyChord(key: "p", modifiers: [.command])])
        #expect(Keymap.defaults.chords(for: .savePDF).isEmpty)
        #expect(Keymap.defaults.complaints.isEmpty)
        // Save as PDF is not a `⌘` chord's owner by default, so a page keeps
        // every chord it would otherwise have taken; `keys` moves it onto one.
        let map = Keymap(overrides: KeyBindings(["savePDF": ["cmd+shift+e"]]))
        #expect(map.chords(for: .savePDF) == [KeyChord(key: "e", modifiers: [.command, .shift])])
        #expect(map.complaints.isEmpty)
    }

    @Test("inside a popup, Print prints the popup's own page; Save as PDF is aimed at the opener and ignored")
    @MainActor
    func popupRouting() {
        #expect(WebPopupDialog.keyAction(for: .printPage) == .print)
        #expect(WebPopupDialog.keyAction(for: .savePDF) == .ignore)
    }

    @Test("a PDF is named for the page, then its host, then `page`, and always ends in .pdf")
    func naming() {
        #expect(PDFNaming.filename(title: "Boarding pass", url: "https://qantas.com/x") == "Boarding pass.pdf")
        #expect(PDFNaming.filename(title: "  ", url: "https://qantas.com/x") == "qantas.com.pdf")
        #expect(PDFNaming.filename(title: nil, url: nil) == "page.pdf")
        #expect(PDFNaming.filename(title: "Invoice / March", url: nil) == "Invoice - March.pdf")
        #expect(PDFNaming.filename(title: "receipt.pdf", url: nil) == "receipt.pdf")
        #expect(PDFNaming.filename(title: ".hidden:name", url: nil) == "hidden_name.pdf")
    }

    @Test("the print info fits the page to the paper's width")
    func printInfo() {
        let info = WebPrinting.printInfo()
        #expect(info.horizontalPagination == .fit)
        #expect(info.verticalPagination == .automatic)
        #expect(info.paperSize.width > 0 && info.paperSize.height > 0)
    }
}

@Suite("save as PDF, in real WebKit", .serialized)
@MainActor
struct WebPrintRenderTests {
    @Test("every fold of the page is in the PDF, and the saved file is a finished row in the download bar")
    func rendersTheWholePage() async throws {
        try await PrintFixture.with { f in
            try await f.open("/receipt")
            #expect(await f.eventually { f.controller.webView?.title == "Receipt 4471" })
            #expect(await f.eventually { f.controller.webView?.isLoading == false })

            let data = try await f.controller.renderPDF()
            #expect(data.starts(with: Array("%PDF".utf8)))
            let text = try #require(PDFDocument(data: data)?.string)
            #expect(text.contains("Boarding pass QF12"), "the top of the page")
            #expect(text.contains("Gate 47 closes at noon"), "the bottom of the page, well below the fold")

            let url = f.dir.appendingPathComponent("out.pdf")
            await f.controller.writePDF(to: url)
            let saved = try #require(f.controller.downloads.last)
            #expect(saved.state == .finished)
            #expect(saved.name == "out.pdf")
            #expect(saved.destination == url)
            let onDisk = try Data(contentsOf: url)
            #expect(onDisk.starts(with: Array("%PDF".utf8)))
            #expect(saved.received == Int64(onDisk.count))

            // The save panel's suggested name comes from the page.
            #expect(PDFNaming.filename(title: f.controller.webView?.title, url: f.site.origin) == "Receipt 4471.pdf")
        }
    }

    /// The destination's parent is a regular *file*, so the write fails with
    /// ENOTDIR on every filesystem — the fixture forces the failure rather than
    /// hoping a missing directory is noticed. And the page is waited for by
    /// title, as above: `isLoading == false` is true before `load` has started
    /// the navigation, and a `createPDF` issued at that moment is asked of a
    /// page about to be replaced, which is where WebKit drops the completion.
    @Test("a write that cannot land is a failed row, not a silent nothing")
    func failureIsARow() async throws {
        try await PrintFixture.with { f in
            try await f.open("/receipt")
            #expect(await f.eventually { f.controller.webView?.title == "Receipt 4471" })
            let url = try f.blockedDestination("out.pdf")
            await f.controller.writePDF(to: url)
            let row = try #require(f.controller.downloads.last)
            guard case .failed(let why) = row.state else {
                Issue.record("expected a failed row, got \(row.state)")
                return
            }
            #expect(!why.isEmpty)
            #expect(row.name == "out.pdf")
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }
}

/// `createPDF`'s completion is not promised. A render that never calls back
/// used to be a continuation suspended for good — no row, no error, a Save as
/// PDF the user waited on forever (and a test process that hung). The
/// deadline is what turns that into a failed row, so it is pinned on its own,
/// with an operation that provably never returns.
@Suite("the PDF deadline")
@MainActor
struct PDFDeadlineTests {
    @Test("an operation that never calls back is a timeout, with the wait in the reason")
    func neverReturns() async {
        let started = Date()
        do {
            let _: Data = try await PDFDeadline.run(within: 0.2) {
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return Data()
            }
            Issue.record("returned from an operation that never resumes")
        } catch let error as PDFExportError {
            guard case .timedOut(let seconds) = error else {
                Issue.record("expected timedOut, got \(error)")
                return
            }
            #expect(seconds == 0.2)
            #expect(error.localizedDescription == "the page did not render as PDF within 0 s")
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(Date().timeIntervalSince(started) < 5, "the deadline, not some other wait, ended it")
    }

    @Test("an operation that finishes in time returns its value, and one that throws rethrows")
    func inTime() async throws {
        let value = try await PDFDeadline.run(within: 5) { "rendered" }
        #expect(value == "rendered")
        await #expect(throws: PDFExportError.self) {
            let _: String = try await PDFDeadline.run(within: 5) { throw PDFExportError.noPage }
        }
    }

    @Test("the production deadline is long enough for a slow page and short enough to be a deadline")
    func productionValue() {
        #expect(PDFDeadline.seconds >= 10 && PDFDeadline.seconds <= 60)
    }
}

@MainActor
final class PrintFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let controller: WebPaneController
    let window: NSWindow

    /// Skipped outside `./scripts/test.sh` for the reason every real-WebKit
    /// suite is: a test process with no profile names the owner's cookie jars.
    static func with(_ body: (PrintFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED save as PDF in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await PrintFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        site = try await LocalSite(pages: ["/receipt": Self.receipt])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-print-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newWebLane(url: "about:blank", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        controller = WebPaneController(
            pane: pane, lane: lane, store: store, config: Config(),
            blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
        // Off every screen, and never ordered in. 600 pt tall, so a 4 000 pt
        // page has most of itself below the fold.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        window.contentView?.addSubview(controller.view)
    }

    func open(_ path: String) async throws {
        let web = try #require(controller.webView)
        web.load(URLRequest(url: URL(string: site.origin + path)!))
    }

    /// A destination no write can land on: its parent path is a regular file,
    /// so the write fails with ENOTDIR wherever the temporary directory is.
    func blockedDestination(_ name: String) throws -> URL {
        let blocker = dir.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocker)
        return blocker.appendingPathComponent(name)
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// A receipt with its last line 4 000 pt down — six folds below a 600 pt
    /// view.
    static let receipt = """
        <!doctype html><html><head><meta charset="utf-8"><title>Receipt 4471</title></head>
        <body style="margin:0;font:16px sans-serif">
        <h1>Boarding pass QF12</h1>
        <div style="height:4000px"></div>
        <p>Gate 47 closes at noon</p>
        </body></html>
        """
}
