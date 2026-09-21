import AppKit
import CryptoKit
import Foundation
import Testing
@testable import MaxPaneKit
@testable import RelayClient

/// A small picture, as the bytes a pasteboard would hold.
private enum Picture {
    static func rep(_ side: Int = 4) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<side { for y in 0..<side {
            rep.setColor(NSColor(deviceRed: CGFloat(x) / CGFloat(side), green: CGFloat(y) / CGFloat(side), blue: 0.5, alpha: 1), atX: x, y: y)
        } }
        return rep
    }
    static var png: Data { rep().representation(using: .png, properties: [:])! }
    static var tiff: Data { rep().tiffRepresentation! }
    static var jpeg: Data { rep().representation(using: .jpeg, properties: [:])! }

    static func isPNG(_ data: Data?) -> Bool {
        data?.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    }
}

/// A pasteboard nobody else has. Never `NSPasteboard.general`.
private func privatePasteboard() -> NSPasteboard {
    let pasteboard = NSPasteboard(name: .init("maxpane.tests.paste-image.\(UUID().uuidString)"))
    pasteboard.clearContents()
    return pasteboard
}

private func scratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-paste-image-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("what a pasteboard with a picture on it amounts to")
struct PasteImageClipboardTests {
    @Test("files win over text, text wins over an image, and an image alone is an image")
    func precedence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }

        // All three: a file URL, a string, a PNG.
        let item = NSPasteboardItem()
        item.setString(dir.appendingPathComponent("a.txt").absoluteString, forType: .fileURL)
        item.setString("a.txt", forType: .string)
        item.setData(Picture.png, forType: .png)
        pasteboard.writeObjects([item])
        let files = TerminalPaste.clipboard(pasteboard)
        #expect(files.text?.hasSuffix("/a.txt") == true)
        #expect(files.image == nil)

        // Text and a picture, as a browser's Copy Image leaves them.
        pasteboard.clearContents()
        let both = NSPasteboardItem()
        both.setString("https://example.com/cat.png", forType: .string)
        both.setData(Picture.png, forType: .png)
        pasteboard.writeObjects([both])
        #expect(TerminalPaste.clipboard(pasteboard) == .init(text: "https://example.com/cat.png", isCopiedText: true))

        // A screenshot: a picture and nothing else.
        pasteboard.clearContents()
        pasteboard.setData(Picture.png, forType: .png)
        let image = TerminalPaste.clipboard(pasteboard)
        #expect(image.text == nil)
        #expect(image.image == Picture.png, "public.png is taken as it is, byte for byte")
        #expect(TerminalPaste.clipboardText(pasteboard) == nil)
    }

    @Test("TIFF and JPEG come out as PNG; an empty pasteboard is nothing")
    func formats() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        #expect(TerminalPaste.clipboard(pasteboard) == .init())

        pasteboard.setData(Picture.tiff, forType: .tiff)
        #expect(Picture.isPNG(TerminalPaste.clipboard(pasteboard).image))

        pasteboard.clearContents()
        pasteboard.setData(Picture.jpeg, forType: .init("public.jpeg"))
        #expect(Picture.isPNG(TerminalPaste.clipboard(pasteboard).image))
    }

    @Test("paste_images_as_files = false: an image-only clipboard is nothing, as it was")
    func settingOff() {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(Picture.png, forType: .png)
        #expect(TerminalPaste.clipboard(pasteboard, images: false) == .init())
    }

    @Test("more than paste_image_max_mb is refused in one line; exactly that much is not; 0 refuses nothing")
    func tooBig() {
        let settings = TerminalPaste.ImageSettings(maxMB: 2)
        #expect(TerminalPaste.imageRefusal(bytes: 2 * 1_048_576, settings) == nil)
        #expect(TerminalPaste.imageRefusal(bytes: 3 * 1_048_576, settings)
            == "image not pasted: 3.0 MB is more than paste_image_max_mb = 2")
        #expect(TerminalPaste.imageRefusal(bytes: 300 * 1_048_576, .init(maxMB: 0)) == nil)
    }

    @Test("the three settings: defaults, and their place in the schema")
    func settings() {
        let config = Config()
        #expect(config.pasteImagesAsFiles)
        #expect(config.pasteImageKeepDays == 7)
        #expect(config.pasteImageMaxMb == 25)
        #expect(TerminalPaste.ImageSettings(config) == .init(asFiles: true, maxMB: 25))
        for key in ["paste_images_as_files", "paste_image_keep_days", "paste_image_max_mb"] {
            #expect(ConfigField.all.contains { $0.key == key }, "\(key) is not a setting")
        }
    }
}

@Suite("where a pasted picture is written")
struct PastedImagesTests {
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("the PNG on disk is the PNG that was on the clipboard, under paste-YYYYMMDD-HHMMSS.png")
    func roundTrip() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = PastedImages(directory: dir.appendingPathComponent("paste"))
        let url = try images.save(Picture.png, at: noon)
        #expect(try Data(contentsOf: url) == Picture.png)
        #expect(NSBitmapImageRep(data: try Data(contentsOf: url))?.pixelsWide == 4)
        #expect(url.deletingLastPathComponent().path == images.directory.path)
        #expect(PastedImages.stem(at: noon, timeZone: TimeZone(identifier: "UTC")!) == "paste-20260921-141320")
        #expect(url.lastPathComponent.wholeMatch(of: /paste-\d{8}-\d{6}\.png/) != nil)
    }

    @Test("two in one second never collide, and a file already there is never replaced")
    func naming() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = PastedImages(directory: dir)
        let first = try images.save(Data("one".utf8), at: noon)
        let second = try images.save(Data("two".utf8), at: noon)
        let third = try images.save(Data("three".utf8), at: noon)
        let stem = PastedImages.stem(at: noon)
        #expect([first, second, third].map(\.lastPathComponent) == ["\(stem).png", "\(stem)-2.png", "\(stem)-3.png"])
        #expect(try Data(contentsOf: first) == Data("one".utf8))
        #expect(try Data(contentsOf: second) == Data("two".utf8))
    }

    @Test("the default profile's directory is Caches/app.ljs.maxpane/paste; another profile's is its own")
    func perProfile() {
        let caches = URL(fileURLWithPath: "/tmp/Caches")
        #expect(PastedImages.directory(for: Profile(name: "default"), caches: caches).path
            == "/tmp/Caches/app.ljs.maxpane/paste")
        #expect(PastedImages.directory(for: Profile(name: "probe"), caches: caches).path
            == "/tmp/Caches/app.ljs.maxpane/profiles/probe/paste")
    }

    @Test("pruning takes paste-*.png older than the days kept, and nothing else; 0 keeps everything")
    func pruning() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = PastedImages(directory: dir)
        let fm = FileManager.default
        func touch(_ name: String, daysOld: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: noon.addingTimeInterval(-daysOld * 86_400)], ofItemAtPath: url.path)
            return url
        }
        let old = try touch("paste-20260901-010101.png", daysOld: 8)
        let fresh = try touch("paste-20260920-010101.png", daysOld: 6)
        let stranger = try touch("holiday.png", daysOld: 400)
        let nested = dir.appendingPathComponent("profiles")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: noon.addingTimeInterval(-400 * 86_400)], ofItemAtPath: nested.path)

        #expect(images.prune(olderThanDays: 0, now: noon).isEmpty)
        #expect(fm.fileExists(atPath: old.path))

        let removed = images.prune(olderThanDays: 7, now: noon)
        #expect(removed.map(\.lastPathComponent) == [old.lastPathComponent])
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
        #expect(fm.fileExists(atPath: stranger.path))
        #expect(fm.fileExists(atPath: nested.path))

        // A directory that was never made is nothing to prune, not an error.
        #expect(PastedImages(directory: dir.appendingPathComponent("never")).prune(olderThanDays: 7).isEmpty)
    }
}

@Suite("the upload, against the fake relay server")
@MainActor
struct RelayUploadTests {
    private func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    @Test("POST /api/upload: the bytes as the body, the name in X-Filename, the cookie; the answer is the server's path")
    func uploads() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.home = "/home/spierce"
        let endpoint = RelayServer(baseURL: server.baseURL, token: server.token)
        // Bigger than one TCP read, so the fake has to read to Content-Length.
        let body = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0) })
        var result: Result<String, RelayUpload.UploadError>?
        // Held by nobody, as the pane calls it.
        RelayUpload(name: "yorkshire", endpoint: endpoint).upload(body, filename: "paste-20260920-120000.png") { result = $0 }
        #expect(await spin(5) { result != nil }, "the completion was never called")
        #expect(try result?.get() == "/home/spierce/.relay-tty/uploads/paste-20260920-120000.png")
        #expect(server.requestLines == ["POST /api/upload HTTP/1.1"])
        #expect(server.uploads.count == 1)
        #expect(server.uploads.first?.sent == "paste-20260920-120000.png")
        #expect(server.uploads.first?.body == body)

        // The same name again: the server renames, and its name is the one that comes back.
        var again: Result<String, RelayUpload.UploadError>?
        RelayUpload(name: "yorkshire", endpoint: endpoint).upload(body, filename: "paste-20260920-120000.png") { again = $0 }
        #expect(await spin(5) { again != nil })
        let second = try #require(try again?.get())
        #expect(second != "/home/spierce/.relay-tty/uploads/paste-20260920-120000.png")
        #expect(second.hasPrefix("/home/spierce/.relay-tty/uploads/paste-20260920-120000-"))
    }

    @Test("a refusal, a wrong token, a dead server and a pathless answer are each one line naming the server")
    func failures() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        func attempt(_ endpoint: RelayServer) async -> RelayUpload.UploadError? {
            var result: Result<String, RelayUpload.UploadError>?
            RelayUpload(name: "yorkshire", endpoint: endpoint).upload(Data("x".utf8), filename: "a.png") { result = $0 }
            _ = await spin(5) { result != nil }
            if case .failure(let error)? = result { return error }
            return nil
        }
        server.uploadRefusal = (status: 500, error: "Write failed: ENOSPC")
        let refused = await attempt(RelayServer(baseURL: server.baseURL, token: server.token))
        #expect(refused?.errorDescription == "yorkshire: could not upload the image — HTTP 500: Write failed: ENOSPC")

        let wrongToken = await attempt(RelayServer(baseURL: server.baseURL, token: "nope"))
        #expect(wrongToken == .refused(server: "yorkshire", status: 401, body: ""))

        let dead = await attempt(RelayServer(baseURL: URL(string: "http://127.0.0.1:1")!, token: "t"))
        #expect(dead?.errorDescription?.hasPrefix("yorkshire: could not upload the image — ") == true)

        #expect(RelayUpload.path(in: Data(#"{"ok":true,"path":"/home/s/a.png"}"#.utf8)) == "/home/s/a.png")
        #expect(RelayUpload.path(in: Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(RelayUpload.path(in: Data(#"{"path":"relative.png"}"#.utf8)) == nil)
        #expect(RelayUpload.path(in: Data("<html>".utf8)) == nil)
    }
}

/// The owner's by-hand check, runnable: the real `RelayUpload` against a real
/// relay-tty server. It prints the path the server answered with and the
/// sha256 of what was sent, so whoever runs it can compare the file over ssh
/// and then delete it; relay-tty has no endpoint that removes an upload.
@Suite("uploading to the real server, when MAXPANE_REMOTE_VERIFY names it")
@MainActor
struct LiveRelayUploadTests {
    @Test("a PNG goes up through POST /api/upload and the answer is an absolute path over there")
    func upload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MAXPANE_REMOTE_VERIFY"].flatMap(URL.init(string:)), let token = env["MAXPANE_REMOTE_TOKEN"], !token.isEmpty else {
            print("SKIPPED live upload check — set MAXPANE_REMOTE_VERIFY=<base url> and MAXPANE_REMOTE_TOKEN to run it")
            return
        }
        let png = Picture.rep(256).representation(using: .png, properties: [:])!
        let filename = PastedImages.name(stem: PastedImages.stem(at: Date()), attempt: 1)
        var result: Result<String, RelayUpload.UploadError>?
        let started = Date()
        RelayUpload(name: "live", endpoint: RelayServer(baseURL: base, token: token)).upload(png, filename: filename) { result = $0 }
        let end = Date().addingTimeInterval(60)
        while result == nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        let path = try #require(try result?.get())
        #expect(path.hasPrefix("/"))
        #expect(path.hasSuffix(".png"))
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        print("live upload: \(png.count) bytes in \(String(format: "%.2f", Date().timeIntervalSince(started))) s → \(path) sha256 \(digest)")

        // And what a wrong token gets: a line, not a path.
        var refused: Result<String, RelayUpload.UploadError>?
        RelayUpload(name: "live", endpoint: RelayServer(baseURL: base, token: "nope")).upload(png, filename: filename) { refused = $0 }
        while refused == nil, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        guard case .failure(let error)? = refused else { Issue.record("a wrong token uploaded"); return }
        print("live upload, wrong token: \(error.localizedDescription)")
    }
}

/// ⌘V itself, through the pane, with a wire that records what reached it.
@Suite("⌘V of a picture pastes a path", .serialized)
@MainActor
struct PasteImagePaneTests {
    private final class Wire: RelayAttachment {
        let sessionId = "paste-image-test"
        var onData: ((ArraySlice<UInt8>) -> Void)?
        var onHostResize: ((Int, Int) -> Void)?
        var onTitle: ((String) -> Void)?
        var onExit: ((Int32) -> Void)?
        var onConnectionChange: ((Bool) -> Void)?
        var onRefused: ((String) -> Void)?
        var onReplaceScreen: (() -> Void)?
        var sent: [UInt8] = []
        func connect() {}
        func disconnect() {}
        func send(_ bytes: ArraySlice<UInt8>) { sent.append(contentsOf: bytes) }
        func claimSize(cols: Int, rows: Int) {}
        var text: String { String(decoding: sent, as: UTF8.self) }
    }

    @MainActor
    private final class Rig {
        let dir: URL
        let store: StripStore
        let window: NSWindow
        let pane: TerminalPaneController
        let wire = Wire()
        let pasteboard = privatePasteboard()
        var images: PastedImages { PastedImages(directory: dir.appendingPathComponent("paste dir")) }

        init(config: Config = Config(), server: String? = nil) throws {
            dir = try scratch()
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newTerminalLane(session: SessionKey(server: server, id: "paste-image"), near: nil)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 700, height: 600),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            pane = TerminalPaneController(
                pane: store.state.lanes[0].panes[0], store: store, config: config,
                controller: TerminalControllerPool.makeController(for: config))
            pane.pasteboard = pasteboard
            // Never the owner's ~/Library/Caches. A space in it, so the path
            // that is pasted has to be quoted.
            pane.pastedImages = images
            pane.attach(wire)
            pane.view.frame = NSRect(x: 0, y: 0, width: 656, height: 600)
            window.contentView?.addSubview(pane.view)
        }

        func settle() async throws { try await Task.sleep(nanoseconds: 120_000_000) }

        func spin(_ seconds: TimeInterval, _ cond: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if cond() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return cond()
        }

        var saved: [URL] {
            (try? FileManager.default.contentsOfDirectory(at: images.directory, includingPropertiesForKeys: nil)) ?? []
        }

        func close() {
            pane.tearDown()
            pasteboard.releaseGlobally()
            window.close()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("local: the PNG is written, its quoted path is what goes out, with no Return and no markers, and the pane says what it saved")
    func local() async throws {
        let rig = try Rig()
        defer { rig.close() }
        rig.pasteboard.setData(Picture.png, forType: .png)
        let target = try #require(rig.pane.view as? TerminalPasteTarget)
        target.pasteIntoTerminalPane(nil)
        try await rig.settle()

        let file = try #require(rig.saved.first)
        #expect(rig.saved.count == 1)
        #expect(try Data(contentsOf: file) == Picture.png)
        // The directory as the pane was handed it, not as the listing
        // resolved it (`/var` is `/private/var`): nothing resolves a symlink.
        #expect(rig.wire.text == "\"\(rig.images.directory.path)/\(file.lastPathComponent)\"")
        #expect(rig.pane.pasteSheet == nil)
        #expect(rig.pane.noticeText == "saved \(file.lastPathComponent), \(TerminalPaste.size(Picture.png.count))")
    }

    @Test("text beside the picture is what is pasted, and nothing is written")
    func textWins() async throws {
        let rig = try Rig()
        defer { rig.close() }
        let item = NSPasteboardItem()
        item.setString("cat.png", forType: .string)
        item.setData(Picture.png, forType: .png)
        rig.pasteboard.writeObjects([item])
        rig.pane.pasteFromClipboard()
        try await rig.settle()
        #expect(rig.wire.text == "cat.png")
        #expect(rig.saved.isEmpty)
    }

    @Test("the setting off, or an image over the limit: nothing is written and nothing is sent")
    func refusals() async throws {
        var off = Config()
        off.pasteImagesAsFiles = false
        let quiet = try Rig(config: off)
        defer { quiet.close() }
        quiet.pasteboard.setData(Picture.png, forType: .png)
        quiet.pane.pasteFromClipboard()
        try await quiet.settle()
        #expect(quiet.wire.sent.isEmpty)
        #expect(quiet.saved.isEmpty)
        #expect(quiet.pane.noticeText == nil)

        let rig = try Rig()
        defer { rig.close() }
        // The limit is whole megabytes, so the picture has to be a real one.
        var small = Config()
        small.pasteImageMaxMb = 1
        rig.pane.liveConfig = { small }
        rig.pane.paste(.init(image: Data(count: 1_048_577)))
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.saved.isEmpty)
        #expect(rig.pane.noticeText == "image not pasted: 1.0 MB is more than paste_image_max_mb = 1")
    }

    @Test("remote: uploaded through the relay API, the server's path is what goes out, and nothing is written here")
    func remote() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.home = "/home/spierce"
        server.uploadDelay = 0.3
        let rig = try Rig(server: "yorkshire")
        defer { rig.close() }
        let endpoint = RelayServer(baseURL: server.baseURL, token: server.token)
        rig.pane.uploadEndpoint = { endpoint }
        rig.pasteboard.setData(Picture.png, forType: .png)
        rig.pane.pasteFromClipboard()

        // While it goes up: a notice that stays, and nothing on the prompt.
        #expect(rig.pane.isUploadingImage)
        #expect(rig.pane.noticeText == "uploading \(TerminalPaste.size(Picture.png.count)) to yorkshire…")
        #expect(rig.wire.sent.isEmpty)
        // A second ⌘V meanwhile is not a second upload.
        rig.pane.pasteFromClipboard()

        #expect(await rig.spin(5) { !rig.pane.isUploadingImage })
        try await rig.settle()
        let upload = try #require(server.uploads.first)
        #expect(server.uploads.count == 1)
        #expect(upload.body == Picture.png)
        #expect(upload.sent.wholeMatch(of: /paste-\d{8}-\d{6}\.png/) != nil)
        #expect(rig.wire.text == "/home/spierce/.relay-tty/uploads/\(upload.stored)")
        #expect(rig.saved.isEmpty, "a remote paste leaves nothing on this Mac")
        #expect(rig.pane.noticeText?.hasPrefix("uploaded \(upload.stored), ") == true)
        #expect(rig.pane.noticeText?.hasSuffix(", to yorkshire") == true)
    }

    @Test("remote, and it fails: one line naming the server, and the prompt gets nothing")
    func remoteFailure() async throws {
        let server = try FakeRelayServer()
        defer { server.stop() }
        server.uploadRefusal = (status: 413, error: "File too large (max 100MB)")
        let rig = try Rig(server: "yorkshire")
        defer { rig.close() }
        let endpoint = RelayServer(baseURL: server.baseURL, token: server.token)
        rig.pane.uploadEndpoint = { endpoint }
        rig.pasteboard.setData(Picture.png, forType: .png)
        rig.pane.pasteFromClipboard()
        #expect(await rig.spin(5) { !rig.pane.isUploadingImage })
        try await rig.settle()
        #expect(rig.wire.sent.isEmpty)
        #expect(rig.pane.noticeText == "yorkshire: could not upload the image — HTTP 413: File too large (max 100MB)")
        #expect(rig.saved.isEmpty)

        // A server the file no longer has: said at once, nothing sent anywhere.
        rig.pane.uploadEndpoint = { nil }
        rig.pane.pasteFromClipboard()
        #expect(!rig.pane.isUploadingImage)
        #expect(rig.pane.noticeText == "yorkshire: could not upload the image — the server is not in config.toml")
        #expect(rig.wire.sent.isEmpty)
    }
}
