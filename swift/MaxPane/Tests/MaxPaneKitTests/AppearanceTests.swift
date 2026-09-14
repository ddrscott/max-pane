import Testing
import AppKit
import WebKit
import GhosttyTerminal
@testable import MaxPaneKit

/// Light and dark, followed live. See `Appearance`.
///
/// Every test that moves `NSApp.appearance` does it synchronously and puts it
/// back before returning, because it is process-wide: an `await` in between
/// would let another suite render in the wrong mode. The two tests that must
/// wait — a page and a terminal — flip their *window's* appearance instead,
/// which reaches a view by exactly the same path an app-wide change takes.
@Suite("light and dark")
@MainActor
struct AppearanceTests {
    private func window(_ size: CGFloat = 200) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root.wantsLayer = true
        window.contentView = root
        return window
    }

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> CGColor {
        color.cgColor(in: NSAppearance(named: name)!)
    }

    private func withApp(_ name: NSAppearance.Name?, _ body: () throws -> Void) rethrows {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = name.flatMap(NSAppearance.init(named:))
        try body()
    }

    @Test("the two modes really are different colours, or nothing below proves anything")
    func theModesDiffer() {
        #expect(resolved(Theme.laneBackground, .aqua) != resolved(Theme.laneBackground, .darkAqua))
        #expect(resolved(Theme.laneBorder, .aqua) != resolved(Theme.laneBorder, .darkAqua))
        // Signal Orange is the same in both.
        #expect(resolved(Theme.accent, .aqua) == resolved(Theme.accent, .darkAqua))
    }

    @Test("a painted layer repaints when the app switches, in the same turn")
    func followsTheApp() {
        withApp(.aqua) {
            let window = window()
            let lane = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            lane.wantsLayer = true
            window.contentView?.addSubview(lane)
            lane.layerBackgroundColor = Theme.laneBackground
            lane.layerBorderColor = Theme.laneBorder
            #expect(lane.layer?.backgroundColor == resolved(Theme.laneBackground, .aqua))

            NSApp.appearance = NSAppearance(named: .darkAqua)
            #expect(lane.layer?.backgroundColor == resolved(Theme.laneBackground, .darkAqua))
            #expect(lane.layer?.borderColor == resolved(Theme.laneBorder, .darkAqua))

            NSApp.appearance = NSAppearance(named: .aqua)
            #expect(lane.layer?.backgroundColor == resolved(Theme.laneBackground, .aqua))
        }
    }

    /// The case a registry of views would miss: a lane recycled out of the
    /// strip, or a tile between two parents, while the switch happened.
    @Test("a view away from any window during the switch is right when it comes back")
    func followsOnAttach() {
        withApp(.aqua) {
            let window = window()
            let away = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            away.wantsLayer = true
            window.contentView?.addSubview(away)
            away.layerBackgroundColor = Theme.stripBackground
            away.removeFromSuperview()

            NSApp.appearance = NSAppearance(named: .darkAqua)
            window.contentView?.addSubview(away)
            #expect(away.layer?.backgroundColor == resolved(Theme.stripBackground, .darkAqua))
        }
    }

    @Test("a local appearance wins over the app's, for the views under it")
    func followsAnAncestor() {
        withApp(.darkAqua) {
            let window = window()
            let pinned = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
            window.contentView?.addSubview(pinned)
            let inner = NSView(frame: pinned.bounds)
            inner.wantsLayer = true
            pinned.addSubview(inner)
            inner.layerBackgroundColor = Theme.laneBackground
            pinned.appearance = NSAppearance(named: .aqua)
            #expect(inner.layer?.backgroundColor == resolved(Theme.laneBackground, .aqua))
        }
    }

    @Test("a hook runs with the view's appearance current")
    func hookResolvesInTheView() {
        withApp(.aqua) {
            let window = window()
            let view = NSView(frame: .zero)
            window.contentView?.addSubview(view)
            var seen: [CGColor] = []
            view.onAppearanceChange { _ in seen.append(Theme.laneBackground.cgColor) }
            NSApp.appearance = NSAppearance(named: .darkAqua)
            #expect(seen.first == resolved(Theme.laneBackground, .aqua))
            #expect(seen.last == resolved(Theme.laneBackground, .darkAqua))
        }
    }

    @Test("the theme setting pins the app, and system lets go")
    func applyPinsAndReleases() {
        withApp(nil) {
            Appearance.apply(.dark)
            #expect(NSApp.appearance?.name == .darkAqua)
            Appearance.apply(.light)
            #expect(NSApp.appearance?.name == .aqua)
            Appearance.apply(.system)
            #expect(NSApp.appearance == nil)
        }
    }

    @Test("a switch crossfades every window on the lane clock, and not under Reduce Motion")
    func crossfades() throws {
        try withApp(.aqua) {
            Appearance.watchApp()
            let window = window()
            let layer = try #require(window.contentView?.layer)
            layer.removeAllAnimations()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            let fade = layer.animation(forKey: Appearance.fadeKey) as? CATransition
            if Motion.isReduced {
                #expect(fade == nil)
            } else {
                #expect(fade?.type == .fade)
                #expect(fade?.duration == Motion.lane)
            }
            // Setting the same appearance again is not a switch.
            layer.removeAllAnimations()
            NSApp.appearance = NSAppearance(named: .darkAqua)
            #expect(layer.animation(forKey: Appearance.fadeKey) == nil)
        }
    }

    /// The bug the icon cache had: one bitmap per colour *name*, and a dynamic
    /// colour's name is the same in both modes.
    @Test("an icon is inked in the appearance it is drawn in, from one cached image")
    func iconsFollow() {
        IconImage.resetCacheForTesting()
        let image = IconImage.make(.x, points: 24, colour: SidebarInk.gone)
        #expect(image === IconImage.make(.x, points: 24, colour: SidebarInk.gone))
        guard let image else { Issue.record("no icon"); return }

        func ink(_ name: NSAppearance.Name) -> CGFloat {
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 24, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            }
            NSGraphicsContext.restoreGraphicsState()
            var total: CGFloat = 0
            var count = 0
            for x in 0..<24 {
                for y in 0..<24 {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.95 else { continue }
                    total += c.redComponent
                    count += 1
                }
            }
            return count == 0 ? -1 : total / CGFloat(count)
        }
        let dark = ink(.darkAqua)
        let light = ink(.aqua)
        let again = ink(.darkAqua)
        #expect(dark > 0 && light > 0)
        // `gone` is 0.42 white in dark and 0.60 in light.
        #expect(light - dark > 0.1)
        #expect(abs(again - dark) < 0.01)
    }

    /// "One mechanism, not 54 hand edits" only holds while nobody writes the
    /// 55th. A `.cgColor` is a snapshot; the only ones left are the mechanism's
    /// own, an animation's endpoints taken on purpose, and a mask, whose colour
    /// is only ever its alpha.
    @Test("no view converts a theme colour to a CGColor by hand")
    func noHandConversions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MaxPaneKit")
        let allowed = [
            "mask.backgroundColor = NSColor.black.cgColor",
        ]
        var offenders: [String] = []
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            guard url.lastPathComponent != "Appearance.swift" else { continue }
            let source = try String(contentsOf: url, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), code.contains(".cgColor"),
                      !code.contains(".cgColor(in:"), !allowed.contains(code)
                else { continue }
                offenders.append("\(url.lastPathComponent):\(number + 1): \(code)")
            }
        }
        #expect(offenders.isEmpty, "\(offenders.joined(separator: "\n"))")
    }

    /// Proven against WebKit, not assumed: a real page loaded from disk, its
    /// stylesheet's media query and a `matchMedia` listener, across two live
    /// switches with no reload.
    @Test("a page sees prefers-color-scheme, and its matchMedia listener hears a live switch")
    func pagesFollow() async throws {
        let window = window(300)
        window.appearance = NSAppearance(named: .aqua)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 300), configuration: .init())
        window.contentView?.addSubview(web)
        web.onAppearanceChange { view in
            (view as? WKWebView)?.underPageBackgroundColor = NSColor(cgColor: Theme.laneBackground.cgColor)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = dir.appendingPathComponent("page.html")
        try """
        <!doctype html>
        <style>
          body { background: rgb(255, 255, 255) }
          @media (prefers-color-scheme: dark) { body { background: rgb(0, 0, 0) } }
        </style>
        <script>
          window.changes = [];
          matchMedia('(prefers-color-scheme: dark)')
            .addEventListener('change', e => window.changes.push(e.matches));
        </script>
        <body>appearance</body>
        """.write(to: page, atomically: true, encoding: .utf8)
        web.loadFileURL(page, allowingReadAccessTo: dir)

        struct Seen: Decodable, Equatable { let dark: Bool; let ground: String; let changes: [Bool] }
        func read() async -> Seen? {
            let script = """
            document.readyState === 'complete' && Array.isArray(window.changes)
              ? JSON.stringify({dark: matchMedia('(prefers-color-scheme: dark)').matches,
                                ground: getComputedStyle(document.body).backgroundColor,
                                changes: window.changes})
              : null
            """
            guard let json = try? await web.evaluateJavaScript(script) as? String else { return nil }
            return try? JSONDecoder().decode(Seen.self, from: Data(json.utf8))
        }
        func wait(until done: (Seen) -> Bool) async throws -> Seen? {
            for _ in 0..<200 {
                if let seen = await read(), done(seen) { return seen }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            return await read()
        }

        let light = try await wait { _ in true }
        #expect(light == Seen(dark: false, ground: "rgb(255, 255, 255)", changes: []))
        let lightGutter = web.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? -1

        window.appearance = NSAppearance(named: .darkAqua)
        let dark = try await wait { $0.changes.count == 1 }
        #expect(dark == Seen(dark: true, ground: "rgb(0, 0, 0)", changes: [true]))
        let darkGutter = web.underPageBackgroundColor.usingColorSpace(.sRGB)?.redComponent ?? -1
        #expect(lightGutter - darkGutter > 0.5)

        window.appearance = NSAppearance(named: .aqua)
        let back = try await wait { $0.changes.count == 2 }
        #expect(back == Seen(dark: false, ground: "rgb(255, 255, 255)", changes: [true, false]))
    }

    /// Ghostty's own view already follows its appearance; what is ours to prove
    /// is that the shared controller carries both palettes and that a switch is a
    /// recolour — the grid the session was told about does not move.
    @Test("a terminal changes palette without changing its grid")
    func terminalsFollow() async throws {
        final class Sizes: @unchecked Sendable {
            private let lock = NSLock()
            private var seen: [String] = []
            func add(_ v: InMemoryTerminalViewport) {
                lock.withLock { seen.append("\(v.columns)x\(v.rows)") }
            }
            var all: [String] { lock.withLock { seen } }
        }
        let sizes = Sizes()
        let session = InMemoryTerminalSession(
            write: { _ in }, resize: { sizes.add($0) }, suppressesPixelOnlyResizes: true)

        let window = window(400)
        window.appearance = NSAppearance(named: .aqua)
        let controller = TerminalControllerPool.shared.controller(for: Config())
        let terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        terminal.controller = controller
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        window.contentView?.addSubview(terminal)
        terminal.layoutSubtreeIfNeeded()
        // A new surface reports more than once while it settles on its cell
        // size, which has nothing to do with appearance. The baseline is taken
        // once it has been quiet for a while.
        // `fitToSize` each step is what the pane's container does on every
        // layout pass; without it a test surface can sit on a grid measured
        // before its cell size was final, and the first config reload of any
        // kind corrects it — which would read as the switch resizing.
        var quiet = 0
        var last = sizes.all.count
        for _ in 0..<200 where quiet < 12 {
            terminal.fitToSize()
            try await Task.sleep(nanoseconds: 25_000_000)
            let now = sizes.all.count
            quiet = (now == last && now > 0) ? quiet + 1 : 0
            last = now
        }
        session.receive("light and dark\r\n")
        session.waitForPendingOutput()
        #expect(controller.effectiveColorScheme == .light)
        let before = sizes.all
        let text = session.readViewportText()

        window.appearance = NSAppearance(named: .darkAqua)
        #expect(controller.effectiveColorScheme == .dark)
        try await Task.sleep(nanoseconds: 300_000_000)
        window.appearance = NSAppearance(named: .aqua)
        #expect(controller.effectiveColorScheme == .light)
        terminal.fitToSize()
        try await Task.sleep(nanoseconds: 300_000_000)

        // Whatever size the surface settled on, two switches added none, and
        // what was on screen is still on screen: a recolour, not a restart.
        #expect(Set(sizes.all) == Set(before))
        #expect(text?.contains("light and dark") == true)
        #expect(session.readViewportText() == text)
    }
}

@Suite("the theme key")
@MainActor
struct ThemeConfigTests {
    private func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test("follows the system unless told otherwise")
    func defaultsToSystem() throws {
        #expect(Config().theme == .system)
        #expect(try decode("{}").theme == .system)
    }

    @Test("reads light and dark")
    func readsAChoice() throws {
        #expect(try decode(#"{"theme": "dark"}"#).theme == .dark)
        #expect(try decode(#"{"theme": "light"}"#).theme == .light)
    }

    @Test("a value it does not know is skipped, and takes nothing else with it")
    func skipsNonsense() throws {
        let config = try decode(#"{"theme": "sepia", "fontSize": 15}"#)
        #expect(config.theme == .system)
        #expect(config.fontSize == 15)
    }

    /// Both ways an editor saves, and the file appearing where there was none.
    @Test("a saved config file is read again, however it was saved")
    func watchSeesSaves() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml")

        var seen: [ThemeChoice] = []
        let watch = ConfigWatch(path: path) { seen.append($0.theme) }
        func settle(_ count: Int) async throws {
            for _ in 0..<120 where seen.count < count {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        // Created where there was none, as an atomic save does.
        try Data(#"theme = "dark""#.utf8).write(to: path, options: .atomic)
        try await settle(1)
        #expect(seen.last == .dark)

        // Replaced atomically.
        let count = seen.count
        try Data(#"theme = "light""#.utf8).write(to: path, options: .atomic)
        try await settle(count + 1)
        #expect(seen.last == .light)

        // Written in place, the way `vim` with `backupcopy=yes` does.
        let inPlace = seen.count
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"theme = "system""#.utf8))
        try handle.close()
        try await settle(inPlace + 1)
        #expect(seen.last == .system)
        _ = watch
    }
}

/// Render sheets in both appearances, the way the app gets there: built in
/// light, then the *app* switched to dark with the same views still standing,
/// so the dark sheet is a picture of the live repaint and not of a view that
/// was simply born dark.
@MainActor
enum AppearanceSheet {
    static func render(to dir: String, named name: String, build: () throws -> NSView) throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        app.appearance = NSAppearance(named: .aqua)

        let view = try build()
        // A sheet has to be in a window to hear a switch at all; a popup's
        // content already is.
        var host: NSWindow?
        if view.window == nil {
            let window = NSWindow(
                contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: view.bounds)
            window.contentView?.addSubview(view)
            view.setFrameOrigin(.zero)
            host = window
        }
        try write(view, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-light.png"))
        app.appearance = NSAppearance(named: .darkAqua)
        try write(view, to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-dark.png"))
        _ = host
    }

    private static func write(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}
