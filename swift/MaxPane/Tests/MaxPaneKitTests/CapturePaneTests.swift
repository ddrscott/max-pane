import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

private func pane(_ id: String, _ position: UInt32, kind: PaneKind = .pty) -> Pane {
    Pane(id: id, laneId: "L", position: position, kind: kind,
         relaySessionId: kind == .pty ? id : nil, relayServer: nil, url: nil, scrollY: nil,
         dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1,
         mobile: false, muted: false, volume: 100)
}

/// A bitmap with a known amount of nothing in it.
private func image(width: Int, height: Int, drawing: ((CGContext) -> Void)? = nil) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    drawing?(context)
    return context.makeImage()!
}

// MARK: - the commands

/// ⌃⌘S Capture Pane and ⇧⌃⌘S Capture Full Page (Omarchy F6, ADR-0040).
@Suite("Capture Pane as a command")
struct CapturePaneCommandTests {
    @Test("both ship with their key, on chords nothing else and no system has")
    func chords() {
        let visible = KeyChord(key: "s", modifiers: [.command, .control])
        let full = KeyChord(key: "s", modifiers: [.command, .control, .shift])
        #expect(Keymap.defaults.chords(for: .capturePane) == [visible])
        #expect(Keymap.defaults.chords(for: .captureFullPage) == [full])
        for (command, chord) in [(Command.capturePane, visible), (.captureFullPage, full)] {
            #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [command],
                    "\(chord.text) is held by more than one command")
            #expect(!Keymap.reserved.contains { $0.0 == chord }, "\(chord.text) is reserved")
        }
        // ⇧⌘S is Export Strip and stays Export Strip: the capture is on ⌃,
        // beside ⌃⌘P, and the two must not have collapsed into one chord.
        #expect(Keymap.defaults.chords(for: .exportStrip) == [KeyChord(key: "s", modifiers: [.command, .shift])])
        #expect(Keymap.defaults.complaints.isEmpty)
    }

    @Test("both are the app's in a web pane: a page has no ⌃⌘S of its own")
    func claims() {
        #expect(!Command.capturePane.yieldsToPage && !Command.captureFullPage.yieldsToPage)
        #expect(Keymap.defaults.claimed.contains(KeyChord(key: "s", modifiers: [.command, .control])))
        #expect(Keymap.defaults.claimed.contains(KeyChord(key: "s", modifiers: [.command, .control, .shift])))
    }

    @Test("under File with Print and Save as PDF, and only the full-page one needs a page")
    func menus() {
        #expect(Command.capturePane.menu == .file && Command.captureFullPage.menu == .file)
        let file = Command.allCases.filter { $0.menu == .file }
        #expect(file.firstIndex(of: .capturePane) == file.firstIndex(of: .savePDF).map { $0 + 1 })
        #expect(Command.capturePane.title == "Capture Pane")
        #expect(Command.captureFullPage.title == "Capture Full Page")
        // A terminal captures too, so ⌃⌘S is live on both kinds; a terminal
        // has no fold, so ⇧⌃⌘S is greyed there.
        #expect(!Command.capturePane.needsWebPane)
        #expect(Command.captureFullPage.needsWebPane)
    }

    @MainActor
    @Test("a sign-in popup ignores both: nobody captures somebody's password field")
    func popup() {
        #expect(WebPopupDialog.keyAction(for: .capturePane) == .ignore)
        #expect(WebPopupDialog.keyAction(for: .captureFullPage) == .ignore)
    }
}

// MARK: - which prompt gets the path

@Suite("where a captured path is typed")
struct CaptureTargetTests {
    @Test("a lone terminal captures into itself")
    func itself() {
        let panes = [pane("t", 0)]
        #expect(PaneCapture.nearestTerminal(to: "t", among: panes)?.id == "t")
    }

    @Test("a page over a terminal types into the terminal under it")
    func below() {
        let panes = [pane("w", 0, kind: .web), pane("t", 1)]
        #expect(PaneCapture.nearestTerminal(to: "w", among: panes)?.id == "t")
    }

    @Test("a page under a terminal types into the terminal over it")
    func above() {
        let panes = [pane("t", 0), pane("w", 1, kind: .web)]
        #expect(PaneCapture.nearestTerminal(to: "w", among: panes)?.id == "t")
    }

    @Test("with a terminal on each side, the one below wins")
    func belowFirst() {
        let panes = [pane("up", 0), pane("w", 1, kind: .web), pane("down", 2)]
        #expect(PaneCapture.nearestTerminal(to: "w", among: panes)?.id == "down",
                "equal distance is settled downward, where ⌘D puts the new terminal")
    }

    @Test("distance beats direction: a terminal two below loses to one one above")
    func nearestNotLowest() {
        let panes = [pane("up", 0), pane("w", 1, kind: .web), pane("x", 2, kind: .web), pane("down", 3)]
        #expect(PaneCapture.nearestTerminal(to: "w", among: panes)?.id == "up")
    }

    @Test("a lane of pages has nowhere to type, and says so with nil")
    func none() {
        let panes = [pane("a", 0, kind: .web), pane("b", 1, kind: .web)]
        #expect(PaneCapture.nearestTerminal(to: "a", among: panes) == nil)
    }

    @Test("ledger order is not stack order: position decides, whatever order the panes arrive in")
    func sortsByPosition() {
        let panes = [pane("down", 2), pane("w", 1, kind: .web), pane("up", 0)]
        #expect(PaneCapture.nearestTerminal(to: "w", among: panes)?.id == "down")
    }
}

// MARK: - how much page

@Suite("how tall a full-page capture is")
struct CaptureHeightTests {
    @Test("a page taller than the fold is captured to its own height")
    func taller() {
        #expect(PaneCapture.fullPageHeight(document: 4200, viewport: 900) == 4200)
    }

    @Test("a page that fits gets the viewport, never less")
    func shorter() {
        #expect(PaneCapture.fullPageHeight(document: 200, viewport: 900) == 900)
        #expect(PaneCapture.fullPageHeight(document: 0, viewport: 900) == 900)
    }

    @Test("an endless page stops at the ceiling rather than asking for a bitmap that does not fit")
    func ceiling() {
        #expect(PaneCapture.fullPageHeight(document: 5_000_000, viewport: 900) == PaneCapture.fullPageCeiling)
    }

    @Test("a pane with no height captures nothing")
    func noViewport() {
        #expect(PaneCapture.fullPageHeight(document: 4200, viewport: 0) == 0)
    }

    @Test("\"full page\" is only claimed when the capture actually passed the fold")
    func claim() {
        #expect(PaneCapture.isFullPage(captured: 4200, viewport: 900))
        #expect(!PaneCapture.isFullPage(captured: 900, viewport: 900))
    }
}

// MARK: - is it a picture

@Suite("a capture that is not a picture")
struct CaptureBlanknessTests {
    @Test("a flat image is blank, and a drawn one is not")
    func blankness() {
        #expect(PaneCapture.isBlank(image(width: 400, height: 300)))
        let drawn = image(width: 400, height: 300) { context in
            context.setFillColor(CGColor(red: 0.6, green: 0.9, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 150))
        }
        #expect(!PaneCapture.isBlank(drawn))
    }

    @Test("a blank capture is a reason, not a PNG: a pane that has not drawn writes no file")
    func encodeRefusesBlank() {
        #expect(PaneCapture.encode(nil) == .failure(.noPane))
        #expect(PaneCapture.encode(image(width: 40, height: 30)) == .failure(.blank))
        #expect(PaneCapture.Failure.blank.errorDescription == "the pane has not drawn anything yet")
    }

    @Test("a drawn capture encodes as a real PNG")
    func encodesPNG() {
        let drawn = image(width: 64, height: 48) { context in
            context.setFillColor(CGColor(red: 1, green: 0.36, blue: 0, alpha: 1))
            context.fill(CGRect(x: 8, y: 8, width: 20, height: 20))
        }
        guard case .success(let data) = PaneCapture.encode(drawn) else {
            Issue.record("a drawn image did not encode")
            return
        }
        #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "PNG magic")
        let read = NSBitmapImageRep(data: data)
        #expect(read?.pixelsWide == 64 && read?.pixelsHigh == 48)
    }
}

// MARK: - the file

@Suite("a captured file beside the pasted ones")
struct CaptureFileTests {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a capture says so in its name, and a paste still says paste")
    func names() {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let zone = TimeZone(identifier: "UTC")!
        #expect(PastedImages.stem(at: when, prefix: "capture", timeZone: zone) == "capture-20231114-221320")
        #expect(PastedImages.stem(at: when, timeZone: zone) == "paste-20231114-221320",
                "the default is still a paste, so ⌘V's names are unchanged")
    }

    @Test("two captures in one second do not overwrite each other")
    func collision() throws {
        let images = PastedImages(directory: directory())
        let when = Date()
        let first = try images.save(Data([1, 2, 3]), at: when, prefix: "capture")
        let second = try images.save(Data([4, 5, 6]), at: when, prefix: "capture")
        #expect(first != second)
        #expect(first.lastPathComponent.hasPrefix("capture-"))
        #expect(second.lastPathComponent.hasSuffix("-2.png"))
        #expect(try Data(contentsOf: first) == Data([1, 2, 3]), "the first was not replaced")
    }

    @Test("the same prune sweeps captures and pastes, and nothing else")
    func prune() throws {
        let dir = directory()
        let images = PastedImages(directory: dir)
        let old = Date().addingTimeInterval(-10 * 86_400)
        var written: [URL] = []
        for name in ["paste-old.png", "capture-old.png", "notes.png", "capture-old.txt"] {
            let url = dir.appendingPathComponent(name)
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            written.append(url)
        }
        let fresh = try images.save(Data([0]), prefix: "capture")

        let removed = Set(images.prune(olderThanDays: 3).map(\.lastPathComponent))
        #expect(removed == ["paste-old.png", "capture-old.png"],
                "a capture is kept on the same clock as a paste, and somebody else's file is not touched")
        #expect(FileManager.default.fileExists(atPath: written[2].path), "notes.png is not ours")
        #expect(FileManager.default.fileExists(atPath: fresh.path), "today's capture stays")
        #expect(images.prune(olderThanDays: 0).isEmpty, "0 keeps everything")
    }
}

// MARK: - the CLI op

@Suite("maxpane capture on the socket")
struct CaptureCLITests {
    @Test("the op carries a lane and how much of it")
    func parses() {
        guard case .capture(let lane, let full)? =
            OpenServer.parse(#"{"op":"capture","lane":"2","full":true}"#)
        else {
            Issue.record("capture did not parse")
            return
        }
        #expect(lane == "2" && full)

        guard case .capture("focused", false)? = OpenServer.parse(#"{"op":"capture","lane":"","full":false}"#)
        else {
            Issue.record("an empty lane is not the focused pane")
            return
        }
        // `full` left out is the visible pane, so an older shim asking
        // plainly gets the ordinary capture rather than a refusal.
        guard case .capture("focused", false)? = OpenServer.parse(#"{"op":"capture"}"#) else {
            Issue.record("a bare capture is the focused pane, visible")
            return
        }
    }

    @Test("the reply carries the path, which is what an agent asked for")
    func replies() {
        let encoded = OpenServer.encode(OpenServer.Reply(ok: true, lanes: "/tmp/capture-1.png\n"))
        #expect(encoded == #"{"ok":true,"lanes":"/tmp/capture-1.png\n"}"#)
        #expect(OpenServer.encode(.refused("the pane has not drawn anything yet"))
            == #"{"ok":false,"error":"the pane has not drawn anything yet"}"#)
    }
}

// MARK: - a real terminal surface

/// The measurement this whole feature rests on (ADR-0040): a Ghostty pane is
/// drawn by Metal, and the question was whether its pixels can be read from
/// inside the process at all — without Screen Recording, which
/// `CGWindowListCreateImage` would have needed.
@Suite("capturing a real terminal", .serialized)
@MainActor
struct TerminalCaptureSurfaceTests {
    private final class Wire: RelayAttachment {
        let sessionId = "capture-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        var claims = 0
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) { claims += 1 }
        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let wire = Wire()

        init() async throws {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-capture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(relaySessionId: "capture", near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let config = Config()
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.attach(wire)
            // Its own directory, so a test never writes into the owner's cache.
            pane.pastedImages = PastedImages(directory: dir.appendingPathComponent("paste"))
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 400)
            window.contentView?.addSubview(pane.view)
            window.contentView?.layoutSubtreeIfNeeded()
            // The surface reports its viewport several times while it settles
            // on a cell size; assert before that and the grid is not final.
            var quiet = 0, last = -1
            for _ in 0..<240 where quiet < 12 {
                try await Task.sleep(nanoseconds: 25_000_000)
                quiet = (wire.claims == last && wire.claims > 0) ? quiet + 1 : 0
                last = wire.claims
            }
            wire.sent.removeAll()
        }

        func prints(_ text: String) async throws {
            wire.onData?(ArraySlice(Array(text.utf8)))
            try await Task.sleep(nanoseconds: 300_000_000)
        }

        func capture() async -> Result<Data, Error> {
            await withCheckedContinuation { continuation in
                pane.capture(fullPage: false) { continuation.resume(returning: $0) }
            }
        }

        func close() {
            pane.tearDown()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("what the program printed is in the PNG: the pixels come back, and no Screen Recording was asked for")
    func capturesText() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        // Bright green on the dark ground, so "did anything draw" is a
        // question about colours and not about anti-aliasing.
        try await rig.prints("\u{1b}[1;32mCAPTURE_ME\u{1b}[0m the quick brown fox\r\n")
        #expect(rig.pane.viewportText.contains("CAPTURE_ME"), "the surface has the text")

        guard case .success(let png) = await rig.capture() else {
            Issue.record("a drawn terminal did not capture")
            return
        }
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
        let image = try #require(rep.cgImage)
        #expect(!PaneCapture.isBlank(image), "the capture is flat: Metal's pixels did not come back")

        // Not merely "not one colour": a terminal that drew text has many.
        var colours = Set<UInt32>()
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for i in stride(from: 0, to: pixels.count, by: 4) {
            colours.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
        #expect(colours.count > 20, "only \(colours.count) colours: this does not look like drawn text")
    }

    @Test("the path lands at the prompt, quoted, and the file beside the pasted ones")
    func typesThePath() async throws {
        let rig = try await Rig()
        defer { rig.close() }
        try await rig.prints("ready\r\n")
        guard case .success(let png) = await rig.capture() else {
            Issue.record("nothing captured")
            return
        }
        let landed: String = await withCheckedContinuation { continuation in
            rig.pane.typeCapturedPath(png) { result in
                continuation.resume(returning: (try? result.get()) ?? "")
            }
        }
        #expect(landed.hasSuffix(".png"))
        #expect((landed as NSString).lastPathComponent.hasPrefix("capture-"),
                "a capture is named a capture, not a paste")
        #expect(FileManager.default.fileExists(atPath: landed), "the file is really there")
        #expect(rig.pane.pastedImages.directory.path == (landed as NSString).deletingLastPathComponent,
                "it goes where a pasted picture goes")

        // What the program at the prompt actually receives. The send is
        // paced, so the bytes arrive a little after the path is known.
        try await Task.sleep(nanoseconds: 300_000_000)
        let typed = rig.wire.text
        #expect(typed == TerminalPaste.shellWord(for: landed),
                "the prompt got \(typed.debugDescription), not the quoted path")
        #expect(!typed.contains("\n") && !typed.contains("\r"), "a path is typed, never entered")
    }
}

// MARK: - a real page

/// ⌃⌘S and ⇧⌃⌘S over a real page: the fold, and past it (ADR-0040).
///
/// The claim worth pinning is the ⇧ one. `takeSnapshot` will not reach below
/// the fold on its own — `rect` is clipped to the view — so the capture grows
/// the web view for one snapshot. This checks that it really did grow, that
/// what came back is the whole document, and that the pane was put back the
/// size it was.
@Suite("capturing a real page, in real WebKit", .serialized)
@MainActor
struct WebCaptureTests {
    @MainActor
    final class Fixture {
        let site: LocalSite
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let controller: WebPaneController

        /// 4 000 pt of page under a 600 pt viewport, with something
        /// unmistakable at the very bottom.
        static let tall = """
            <!doctype html><html><head><meta charset="utf-8"><title>Tall Page</title></head>
            <body style="margin:0;background:#101010;color:#eee;font:16px sans-serif">
            <div style="height:300px;background:#E85D00">TOP OF THE PAGE</div>
            <div style="height:3400px"></div>
            <div style="height:300px;background:#4CAF50">BOTTOM OF THE PAGE</div>
            </body></html>
            """

        /// A page that fits: nothing below the fold to reach for.
        static let short = """
            <!doctype html><html><head><meta charset="utf-8"><title>Short Page</title></head>
            <body style="margin:0;background:#202020"><div style="height:120px;background:#E85D00">ALL OF IT</div>
            </body></html>
            """

        /// Skipped outside `./scripts/test.sh` for the reason every
        /// real-WebKit suite is: a test process with no profile names the
        /// owner's cookie jars.
        static func with(_ body: (Fixture) async throws -> Void) async throws {
            guard !Profile.current.dataSalt.isEmpty else {
                print("SKIPPED capturing a page in real WebKit: run through ./scripts/test.sh, which names a profile")
                return
            }
            let fixture = try await Fixture()
            do { try await body(fixture) } catch { fixture.tearDown(); throw error }
            fixture.tearDown()
        }

        private init() async throws {
            site = try await LocalSite(pages: ["/tall": Self.tall, "/short": Self.short])
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("maxpane-webcapture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newWebLane(url: "about:blank", near: nil)
            let lane = try #require(store.state.lanes.first)
            let pane = try #require(lane.panes.first)
            controller = WebPaneController(
                pane: pane, lane: lane, store: store, config: Config(),
                blocker: ContentBlocker(directory: dir.appendingPathComponent("content-rules")))
            // Off every screen, never ordered in. 600 pt tall, so a 4 000 pt
            // page has most of itself below the fold.
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 600, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
            window.contentView?.addSubview(controller.view)
        }

        func open(_ path: String, titled title: String) async throws {
            let web = try #require(controller.webView)
            web.load(URLRequest(url: URL(string: site.origin + path)!))
            // The title first, never `isLoading`: `isLoading == false` is true
            // before `load` has started the navigation (see `WebPrintTests`).
            #expect(await eventually { self.controller.webView?.title == title })
            #expect(await eventually { self.controller.webView?.isLoading == false })
        }

        func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return await condition()
        }

        func capture(fullPage: Bool) async -> Result<Data, Error> {
            await withCheckedContinuation { continuation in
                controller.capture(fullPage: fullPage) { continuation.resume(returning: $0) }
            }
        }

        func tearDown() {
            controller.tearDown()
            window.orderOut(nil)
            site.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func size(_ png: Data) throws -> (width: Int, height: Int) {
        let rep = try #require(NSBitmapImageRep(data: png))
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    @Test("⌃⌘S is the fold and ⇧⌃⌘S is the whole document, and the pane is the size it was afterwards")
    func visibleAndFull() async throws {
        try await Fixture.with { f in
            try await f.open("/tall", titled: "Tall Page")
            let web = try #require(f.controller.webView)
            let before = web.frame

            let visibleResult = await f.capture(fullPage: false)
            guard case .success(let visible) = visibleResult else {
                Issue.record("the visible capture failed: \(visibleResult)")
                return
            }
            let fold = try self.size(visible)
            #expect(fold.width > 0 && fold.height > 0)
            // The viewport, not the document: 600 pt of a 4 000 pt page.
            #expect(Double(fold.height) / Double(fold.width) < 1.5,
                    "a 600×600 viewport did not come back square-ish: \(fold)")

            let fullResult = await f.capture(fullPage: true)
            guard case .success(let full) = fullResult else {
                Issue.record("the full-page capture failed: \(fullResult)")
                return
            }
            let whole = try self.size(full)
            #expect(whole.width == fold.width, "the width is the lane's either way")
            #expect(whole.height > fold.height * 4,
                    "⇧ reached \(whole.height) px against the fold's \(fold.height): it did not pass the fold")
            // 4 000 pt of document under a 600 pt viewport is about 6.7× —
            // the exact number is WebKit's business, the order is not.
            #expect(Double(whole.height) / Double(fold.height) > 5)
            // Measured 2026-09-23: 1200×1148 px for the fold (a 600 pt lane
            // at 2×, less the chrome bar) and 1200×8000 for the page (4 000
            // pt at 2×) — 32 KB against 205 KB.
            #expect(whole.height == 8000, "the document is 4 000 pt; at 2× that is 8 000 px, not \(whole.height)")
            let wholeImage = try #require(NSBitmapImageRep(data: full)?.cgImage)
            #expect(!PaneCapture.isBlank(wholeImage), "the full page came back empty")

            #expect(web.frame == before, "the web view was left the size the capture made it")
            #expect(await f.eventually { f.controller.webView?.frame == before })
        }
    }

    @Test("a page that fits gets one screen from both, and ⇧ claims nothing more")
    func shortPage() async throws {
        try await Fixture.with { f in
            try await f.open("/short", titled: "Short Page")
            let visibleResult = await f.capture(fullPage: false)
            let fullResult = await f.capture(fullPage: true)
            guard case .success(let visible) = visibleResult, case .success(let full) = fullResult else {
                Issue.record("a short page did not capture: \(visibleResult) / \(fullResult)")
                return
            }
            let fold = try self.size(visible), whole = try self.size(full)
            #expect(whole == fold, "⇧ grew a page that had nowhere to grow: \(whole) against \(fold)")
            #expect(!PaneCapture.isFullPage(captured: Double(whole.height), viewport: Double(fold.height)))
        }
    }
}
