import AppKit
import CoreImage
import Foundation
import GhosttyTerminal
import IOSurface
import Metal
import QuartzCore
import WebKit

// Spike M5 — a lane as a gallery thumbnail.
//
// The question the gallery rests on: a tile must be the lane's real layout drawn
// smaller, never a re-flowed grid (ADR-0007: a PTY's size is shared with every
// client, the phone included). Two ways to draw a view smaller:
//
//   transform  the view keeps its bounds; its frame in the parent shrinks
//              (`setBoundsSize` on a host view). The renderer draws at full
//              size and the compositor minifies.
//   backing    the view renders into fewer pixels: a smaller content scale.
//              Ghostty's `scaleFactor` is internal to libghostty-spm, but pixel
//              size = points × scale and font pixels = font points × scale, so a
//              frame of lane×s at font×s is the same arithmetic Ghostty would do
//              at content scale×s. That is how it is measured here.
//
// Phases, each writing into results.json:
//   grid    does either approach change the grid Ghostty reports?
//   pixels  what does each look like, against a Lanczos reference?
//   cost    CPU and memory for 12 terminals, idle and streaming
//   web     what does a WKWebView lay out at under each approach?

// MARK: - options

struct Options {
    var out = FileManager.default.currentDirectoryPath
    var phases: Set<String> = ["all"]
    var laneWidth: CGFloat = 656     // Config.laneDefaultPt
    var laneHeight: CGFloat = 1000
    var fontName = "JetBrains Mono"  // Config.fontName
    var fontSize = 13.0              // Config.fontSize
    var costSeconds = 10.0
    var tiles = 12
    var scales: [CGFloat] = [1.0, 0.75, 0.6, 0.5, 0.45, 0.4, 0.33, 0.25]
    /// Pretend the window is on a display of this backing scale. Ghostty reads
    /// its content scale from `window.backingScaleFactor` and nothing else, so
    /// this is exactly what it would do on that display — which is how 2× is
    /// measured on a machine whose only connected panel is 1×.
    var backing: CGFloat?

    func wants(_ phase: String) -> Bool { phases.contains("all") || phases.contains(phase) }
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let key = args.removeFirst()
        let value = args.isEmpty ? "" : args.removeFirst()
        switch key {
        case "--out": o.out = value
        case "--phases": o.phases = Set(value.split(separator: ",").map(String.init))
        case "--seconds": o.costSeconds = Double(value) ?? o.costSeconds
        case "--tiles": o.tiles = Int(value) ?? o.tiles
        case "--backing": o.backing = Double(value).map { CGFloat($0) }
        default: break
        }
    }
    return o
}

let options = parseOptions()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[m5] \(message)\n".utf8))
    let line = Data("\(message)\n".utf8)
    let path = URL(fileURLWithPath: options.out).appendingPathComponent("run.log")
    if let handle = try? FileHandle(forWritingTo: path) {
        handle.seekToEndOfFile(); handle.write(line); try? handle.close()
    } else {
        try? line.write(to: path)
    }
}

// MARK: - process metrics (as spike M4 measured them)

func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

func cpuSeconds() -> Double {
    var ru = rusage()
    guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
    return Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1e6
        + Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1e6
}

@MainActor
func pause(_ seconds: Double) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
}

// MARK: - a terminal under test

/// A Ghostty surface with an in-memory session, recording every grid it reports.
///
/// Two reports matter and they are different callbacks: the view delegate's
/// `terminalDidResize` is Ghostty's local grid; the session's `resize` is the
/// one the app turns into `claimSize` — a RESIZE to RelayTTY. Both are counted.
@MainActor
final class Probe: NSObject, TerminalSurfaceGridResizeDelegate {
    let view: TerminalView
    let session: InMemoryTerminalSession
    private(set) var viewGrids: [TerminalGridMetrics] = []
    private(set) var sessionGrids: [(Int, Int)] = []

    init(controller: TerminalController, frame: NSRect) {
        view = TerminalView(frame: frame)
        var sink: ((Int, Int) -> Void)?
        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { viewport in
                let cols = Int(viewport.columns), rows = Int(viewport.rows)
                Task { @MainActor in sink?(cols, rows) }
            },
            suppressesPixelOnlyResizes: true)
        super.init()
        sink = { [weak self] c, r in self?.sessionGrids.append((c, r)) }
        view.controller = controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.delegate = self
    }

    func terminalDidResize(_ size: TerminalGridMetrics) { viewGrids.append(size) }

    var grid: (cols: Int, rows: Int)? {
        viewGrids.last.map { (Int($0.columns), Int($0.rows)) }
    }
    var marks: (view: Int, session: Int) { (viewGrids.count, sessionGrids.count) }
}

@MainActor
var controllers: [Double: TerminalController] = [:]

@MainActor
func controller(fontSize: Double) -> TerminalController {
    if let c = controllers[fontSize] { return c }
    let made = TerminalController(
        theme: .default,
        terminalConfiguration: TerminalConfiguration { b in
            b.withFontFamily(options.fontName)
            b.withFontSize(Float(fontSize))
            b.withCustom("keybind", "clear")
            b.withWindowPaddingX(6)
            b.withWindowPaddingY(4)
        })
    controllers[fontSize] = made
    return made
}

/// A host whose bounds stay the lane's size while its frame shrinks: the view
/// inside never learns it is smaller.
@MainActor
final class ScaledHost: NSView {
    override var isFlipped: Bool { true }
    func scale(to s: CGFloat, full: NSSize) {
        setFrameSize(NSSize(width: full.width * s, height: full.height * s))
        setBoundsSize(full)
    }
}

@MainActor
final class ScaledWindow: NSWindow {
    var forcedScale: CGFloat?
    override var backingScaleFactor: CGFloat { forcedScale ?? super.backingScaleFactor }
}

// MARK: - fixture

/// What a tile is for: an agent that has stopped to ask. Colour, box drawing, a
/// diff, and a prompt — the shapes you recognise a waiting session by.
func fixture(lines: Int = 60) -> String {
    var s = "\u{1b}[2J\u{1b}[H"
    s += "\u{1b}[38;5;208m╭──────────────────────────────────────────────────────────╮\u{1b}[0m\r\n"
    s += "\u{1b}[38;5;208m│\u{1b}[0m \u{1b}[1m✻ Claude Code\u{1b}[0m   max-pane · feat/gallery-layout          \u{1b}[38;5;208m│\u{1b}[0m\r\n"
    s += "\u{1b}[38;5;208m╰──────────────────────────────────────────────────────────╯\u{1b}[0m\r\n\r\n"
    for i in 0..<lines {
        switch i % 6 {
        case 0: s += "\u{1b}[32m+    let tiles = GalleryLayout.rects(for: lanes, in: bounds)\u{1b}[0m\r\n"
        case 1: s += "\u{1b}[31m-    let visible = visibleLaneRange(in: store.stripLanes)\u{1b}[0m\r\n"
        case 2: s += "  \u{1b}[2m\(String(format: "%4d", i * 7))\u{1b}[0m │ func distanceFromViewport(laneId: String) -> UInt32 {\r\n"
        case 3: s += "\u{1b}[36m⏺ Update\u{1b}[0m(Views/StripViewController.swift) \u{1b}[2m· 42 lines\u{1b}[0m\r\n"
        case 4: s += "  ⎿  Found 12 lanes, 3 docked, 1 evicted — ~/code/relay-tty/app\r\n"
        default: s += "\u{1b}[1;33mwarning\u{1b}[0m: `ungather` holds Esc; the gallery must not swallow it\r\n"
        }
    }
    s += "\r\n\u{1b}[1mDo you want to make this edit to StripViewController.swift?\u{1b}[0m\r\n"
    s += "\u{1b}[38;5;208m❯ 1. Yes\u{1b}[0m\r\n  2. Yes, and don't ask again this session\r\n  3. No, and tell Claude what to do differently \u{1b}[2m(esc)\u{1b}[0m\r\n"
    return s
}

// MARK: - pixels

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let metalDevice = MTLCreateSystemDefaultDevice()!

/// Ghostty renders into an IOSurface and hangs it on a layer as `contents`.
/// Walk the tree for it rather than assume which layer: libghostty-spm swaps
/// the view's own layer for an IOSurfaceLayer once it renders.
func findSurface(_ layer: CALayer?) -> (IOSurfaceRef, String)? {
    guard let layer else { return nil }
    if let contents = layer.contents {
        let cf = contents as CFTypeRef
        if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
            return (unsafeBitCast(cf, to: IOSurfaceRef.self), String(describing: type(of: layer)))
        }
    }
    for sub in layer.sublayers ?? [] {
        if let found = findSurface(sub) { return found }
    }
    return nil
}

func cgImage(from surface: IOSurfaceRef) -> CGImage? {
    let image = CIImage(ioSurface: surface)
    return ciContext.createCGImage(image, from: image.extent)
}

func writePNG(_ image: CGImage, _ name: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: options.out).appendingPathComponent(name))
}

/// Straight RGBA8 bytes, so two images can be compared pixel for pixel.
func rgba(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int) {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (bytes, w, h)
}

/// Mean absolute difference per channel, 0–255, over the common area.
func meanAbsoluteError(_ a: CGImage, _ b: CGImage) -> Double {
    let x = rgba(a), y = rgba(b)
    let w = min(x.width, y.width), h = min(x.height, y.height)
    var total = 0, n = 0
    for row in 0..<h {
        for col in 0..<w {
            let i = (row * x.width + col) * 4, j = (row * y.width + col) * 4
            for c in 0..<3 { total += abs(Int(x.bytes[i + c]) - Int(y.bytes[j + c])); n += 1 }
        }
    }
    return n == 0 ? 0 : Double(total) / Double(n)
}

/// Mean gradient magnitude of luminance: how much edge a text image still has.
/// Blur lowers it; so does a stroke that sampling skipped entirely.
func edgeEnergy(_ image: CGImage) -> Double {
    let p = rgba(image)
    func lum(_ x: Int, _ y: Int) -> Double {
        let i = (y * p.width + x) * 4
        return 0.2126 * Double(p.bytes[i]) + 0.7152 * Double(p.bytes[i + 1]) + 0.0722 * Double(p.bytes[i + 2])
    }
    var sum = 0.0, n = 0
    for y in 1..<(p.height - 1) {
        for x in 1..<(p.width - 1) {
            let gx = lum(x + 1, y) - lum(x - 1, y), gy = lum(x, y + 1) - lum(x, y - 1)
            sum += (gx * gx + gy * gy).squareRoot(); n += 1
        }
    }
    return n == 0 ? 0 : sum / Double(n)
}

/// The best a downscale can do: Lanczos, which is what "as sharp as the pixels
/// allow" means for a picture that has to lose pixels.
func lanczos(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let filter = CIFilter(name: "CILanczosScaleTransform")!
    filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    filter.setValue(scale, forKey: kCIInputScaleKey)
    filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
    guard let out = filter.outputImage else { return nil }
    return ciContext.createCGImage(out, from: out.extent.integral)
}

/// Composite `contents` at `scale` through Core Animation's own renderer, with
/// the given minification filter — the in-process stand-in for WindowServer
/// drawing a layer whose view's frame is smaller than its bounds.
func caComposite(contents: Any, fullPixels: CGSize, scale: CGFloat,
                 filter: CALayerContentsFilter) -> CGImage? {
    let w = Int((fullPixels.width * scale).rounded()), h = Int((fullPixels.height * scale).rounded())
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    desc.usage = [.renderTarget, .shaderRead]
    desc.storageMode = .shared
    guard let texture = metalDevice.makeTexture(descriptor: desc),
          let queue = metalDevice.makeCommandQueue() else { return nil }
    let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    let root = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    root.anchorPoint = .zero
    root.position = .zero
    root.backgroundColor = CGColor(gray: 0, alpha: 1)
    let child = CALayer()
    child.contents = contents
    child.contentsGravity = .resize
    child.bounds = CGRect(origin: .zero, size: fullPixels)
    child.anchorPoint = .zero
    child.position = .zero
    child.transform = CATransform3DMakeScale(scale, scale, 1)
    child.minificationFilter = filter
    root.addSublayer(child)
    renderer.layer = root
    renderer.bounds = root.bounds
    CATransaction.commit()
    CATransaction.flush()

    renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()
    // Same queue, so waiting on an empty buffer waits on the render too.
    let fence = queue.makeCommandBuffer()!
    fence.commit()
    fence.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

/// CARenderer's origin is bottom-left; whichever orientation is closer to the
/// reference is the right one. Flipping costs nothing and guessing wrong would
/// make every error number garbage.
func oriented(_ image: CGImage, like reference: CGImage) -> CGImage {
    let w = image.width, h = image.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let flipped = ctx.makeImage() else { return image }
    return meanAbsoluteError(flipped, reference) < meanAbsoluteError(image, reference) ? flipped : image
}

func crop(_ image: CGImage, width: Int, height: Int) -> CGImage {
    image.cropping(to: CGRect(x: 0, y: 0, width: min(width, image.width), height: min(height, image.height))) ?? image
}

// MARK: - the run

@MainActor
final class Spike: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var results: [String: Any] = [:]
    var laneSize: NSSize { NSSize(width: options.laneWidth, height: options.laneHeight) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await run() }
    }

    /// One window, on a 2× screen if there is one, below the desktop picture —
    /// so it is composited nowhere anyone can see, and it never becomes key.
    func makeWindow(size: NSSize) {
        let screen = NSScreen.screens.first { $0.backingScaleFactor >= 2 } ?? NSScreen.main!
        let frame = NSRect(origin: screen.frame.origin, size: size)
        let scaled = ScaledWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        scaled.forcedScale = options.backing
        window = scaled
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let content = ScaledHost(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        window.orderFrontRegardless()
    }

    func run() async {
        try? FileManager.default.createDirectory(atPath: options.out, withIntermediateDirectories: true)
        makeWindow(size: NSSize(width: 3400, height: 2100))
        await pause(0.5)
        results["environment"] = [
            "rendererScale": window.backingScaleFactor,
            "screenBackingScaleFactor": window.screen?.backingScaleFactor ?? 0,
            "backingForced": options.backing != nil,
            "connectedScreens": NSScreen.screens.map { "\($0.localizedName) @\($0.backingScaleFactor)×" },
            "screen": window.screen?.localizedName ?? "none",
            "laneWidthPt": options.laneWidth,
            "laneHeightPt": options.laneHeight,
            "font": "\(options.fontName) \(options.fontSize)pt",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        log("window on \(window.screen?.localizedName ?? "none") at \(window.backingScaleFactor)×")

        if options.wants("grid") { await gridPhase() }
        if options.wants("pixels") { await pixelsPhase() }
        if options.wants("cost") { await costPhase() }
        if options.wants("web") { await webPhase() }

        let data = try! JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try! data.write(to: URL(fileURLWithPath: options.out).appendingPathComponent("results.json"))
        log("done")
        NSApp.terminate(nil)
    }

    func clear() {
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }

    // MARK: grid

    func gridPhase() async {
        log("grid phase")
        clear()
        var rows: [[String: Any]] = []

        // Baseline: the lane as the strip draws it.
        let host = ScaledHost(frame: NSRect(origin: .zero, size: laneSize))
        window.contentView!.addSubview(host)
        let probe = Probe(controller: controller(fontSize: options.fontSize),
                          frame: NSRect(origin: .zero, size: laneSize))
        host.addSubview(probe.view)
        await pause(1.0)
        probe.session.receive(fixture())
        await pause(0.5)
        guard let base = probe.grid else {
            results["grid"] = ["error": "the baseline surface never reported a grid"]
            log("no baseline grid")
            return
        }
        log("baseline grid \(base.cols)x\(base.rows)")

        for s in options.scales {
            // transform: same view, host frame shrinks, bounds stay.
            let before = probe.marks
            host.scale(to: s, full: laneSize)
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            probe.view.fitToSize()
            await pause(0.6)
            let during = probe.marks
            let gridDuring = probe.grid
            host.scale(to: 1, full: laneSize)
            host.layoutSubtreeIfNeeded()
            probe.view.fitToSize()
            await pause(0.4)
            let after = probe.marks

            // backing: a fresh surface at lane×s with the font at ×s.
            let small = Probe(controller: controller(fontSize: options.fontSize * Double(s)),
                              frame: NSRect(x: 0, y: 0, width: laneSize.width * s, height: laneSize.height * s))
            window.contentView!.addSubview(small.view)
            await pause(0.8)
            let backingGrid = small.grid
            small.view.removeFromSuperview()

            // control: the same surface's frame shrunk with nothing compensating,
            // proving the detector sees a change when there is one.
            let control = Probe(controller: controller(fontSize: options.fontSize),
                                frame: NSRect(origin: .zero, size: laneSize))
            window.contentView!.addSubview(control.view)
            await pause(0.8)
            let controlBefore = control.grid
            control.view.setFrameSize(NSSize(width: laneSize.width * s, height: laneSize.height * s))
            control.view.fitToSize()
            await pause(0.6)
            let controlAfter = control.grid
            control.view.removeFromSuperview()

            func g(_ x: (cols: Int, rows: Int)?) -> String { x.map { "\($0.cols)x\($0.rows)" } ?? "none" }
            let row: [String: Any] = [
                "scale": s,
                "baseline": g(base),
                "transform_grid": g(gridDuring),
                "transform_view_reports": during.view - before.view,
                "transform_session_reports": during.session - before.session,
                "transform_reports_on_return": (after.view - during.view) + (after.session - during.session),
                "backing_grid": g(backingGrid),
                "control_before": g(controlBefore),
                "control_after": g(controlAfter),
            ]
            log("s=\(s) \(row)")
            rows.append(row)
        }
        probe.view.removeFromSuperview()
        results["grid"] = rows
    }

    // MARK: pixels

    func pixelsPhase() async {
        log("pixels phase")
        clear()
        var rows: [[String: Any]] = []
        let host = ScaledHost(frame: NSRect(origin: .zero, size: laneSize))
        window.contentView!.addSubview(host)
        let probe = Probe(controller: controller(fontSize: options.fontSize),
                          frame: NSRect(origin: .zero, size: laneSize))
        host.addSubview(probe.view)
        await pause(1.0)
        probe.session.receive(fixture())
        await pause(1.0)

        guard let (surface, layerClass) = findSurface(probe.view.layer), let full = cgImage(from: surface) else {
            results["pixels"] = ["error": "no IOSurface found in the terminal's layer tree",
                                 "layer": String(describing: probe.view.layer)]
            log("no IOSurface")
            return
        }
        let fullPixels = CGSize(width: full.width, height: full.height)
        writePNG(full, "terminal-full.png")
        log("surface \(full.width)x\(full.height) on \(layerClass)")
        var pixelsInfo: [String: Any] = [
            "surface_layer_class": layerClass,
            "surface_pixels_full": "\(full.width)x\(full.height)",
        ]

        for s in options.scales where s < 1 {
            // The drawable under a transform: is it still full size?
            host.scale(to: s, full: laneSize)
            host.layoutSubtreeIfNeeded()
            probe.view.fitToSize()
            probe.session.receive("\u{1b}[H")  // a byte, so a frame is owed
            await pause(0.5)
            let transformed = findSurface(probe.view.layer).map { "\(IOSurfaceGetWidth($0.0))x\(IOSurfaceGetHeight($0.0))" } ?? "none"
            host.scale(to: 1, full: laneSize)
            host.layoutSubtreeIfNeeded()

            guard let reference = lanczos(full, scale: s) else { continue }
            let tag = String(format: "%.2f", s)
            writePNG(reference, "s\(tag)-lanczos.png")

            var row: [String: Any] = [
                "scale": s,
                "tile_pixels": "\(reference.width)x\(reference.height)",
                "surface_pixels_under_transform": transformed,
                "lanczos_edge_energy": edgeEnergy(reference),
            ]
            for (name, filter) in [("linear", CALayerContentsFilter.linear),
                                   ("trilinear", CALayerContentsFilter.trilinear),
                                   ("nearest", CALayerContentsFilter.nearest)] {
                // IOSurface contents first: it is what the live layer holds.
                if let raw = caComposite(contents: surface, fullPixels: fullPixels, scale: s, filter: filter) {
                    let img = oriented(raw, like: reference)
                    writePNG(img, "s\(tag)-ca-\(name).png")
                    row["ca_\(name)_mae_vs_lanczos"] = meanAbsoluteError(img, reference)
                    row["ca_\(name)_edge_energy"] = edgeEnergy(img)
                }
            }

            // backing: Ghostty drawing into the tile's own pixels.
            let small = Probe(controller: controller(fontSize: options.fontSize * Double(s)),
                              frame: NSRect(x: 0, y: 0, width: laneSize.width * s, height: laneSize.height * s))
            window.contentView!.addSubview(small.view)
            await pause(0.8)
            small.session.receive(fixture())
            await pause(0.8)
            if let (smallSurface, _) = findSurface(small.view.layer), let img = cgImage(from: smallSurface) {
                writePNG(img, "s\(tag)-backing.png")
                row["backing_surface_pixels"] = "\(img.width)x\(img.height)"
                row["backing_edge_energy"] = edgeEnergy(img)
                row["backing_grid"] = small.grid.map { "\($0.cols)x\($0.rows)" } ?? "none"
            }
            small.view.removeFromSuperview()
            log("s=\(s) \(row)")
            rows.append(row)
        }
        probe.view.removeFromSuperview()
        pixelsInfo["scales"] = rows
        results["pixels"] = pixelsInfo
    }

    // MARK: cost

    func costPhase() async {
        log("cost phase")
        var out: [String: Any] = [:]
        let s: CGFloat = 0.4
        for variant in ["full", "transform", "backing"] {
            clear()
            await pause(0.5)
            let baseFootprint = physFootprintBytes()
            var probes: [Probe] = []
            let perRow = 6
            for i in 0..<options.tiles {
                let col = CGFloat(i % perRow), row = CGFloat(i / perRow)
                switch variant {
                case "full":
                    // The strip's cost, if every lane were on screen at once.
                    let w = laneSize.width * 0.5, h = laneSize.height * 0.5  // placement only
                    let host = ScaledHost(frame: NSRect(x: col * w, y: row * h, width: laneSize.width, height: laneSize.height))
                    window.contentView!.addSubview(host)
                    let p = Probe(controller: controller(fontSize: options.fontSize), frame: NSRect(origin: .zero, size: laneSize))
                    host.addSubview(p.view); probes.append(p)
                case "transform":
                    let host = ScaledHost(frame: NSRect(x: col * laneSize.width * s, y: row * laneSize.height * s,
                                                        width: laneSize.width, height: laneSize.height))
                    window.contentView!.addSubview(host)
                    let p = Probe(controller: controller(fontSize: options.fontSize), frame: NSRect(origin: .zero, size: laneSize))
                    host.addSubview(p.view)
                    host.scale(to: s, full: laneSize)
                    probes.append(p)
                default:
                    let p = Probe(controller: controller(fontSize: options.fontSize * Double(s)),
                                  frame: NSRect(x: col * laneSize.width * s, y: row * laneSize.height * s,
                                                width: laneSize.width * s, height: laneSize.height * s))
                    window.contentView!.addSubview(p.view); probes.append(p)
                }
            }
            await pause(1.5)
            for p in probes { p.session.receive(fixture()) }
            await pause(1.0)

            // Idle: nothing arriving. Ghostty releases its display link after a
            // run of idle frames, so this should be close to nothing.
            var cpu0 = cpuSeconds(), t0 = CACurrentMediaTime()
            await pause(options.costSeconds / 2)
            let idleCores = (cpuSeconds() - cpu0) / (CACurrentMediaTime() - t0)

            // Streaming: every tile printing ~30 lines a second, which is a busy
            // agent rather than `yes`.
            var counter = 0
            let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
                MainActor.assumeIsolated {
                    counter += 1
                    let line = "\u{1b}[3\(counter % 7 + 1)m\(counter)\u{1b}[0m ⏺ Update(Views/Gallery.swift) · the tile is \(Int(s * 100))% of the lane\r\n"
                    for p in probes { p.session.receive(line) }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            cpu0 = cpuSeconds(); t0 = CACurrentMediaTime()
            await pause(options.costSeconds)
            let streamCores = (cpuSeconds() - cpu0) / (CACurrentMediaTime() - t0)
            timer.invalidate()

            var surfaceBytes = 0
            var surfaceSizes: Set<String> = []
            for p in probes {
                if let (surf, _) = findSurface(p.view.layer) {
                    surfaceBytes += IOSurfaceGetAllocSize(surf)
                    surfaceSizes.insert("\(IOSurfaceGetWidth(surf))x\(IOSurfaceGetHeight(surf))")
                }
            }
            let row: [String: Any] = [
                "tiles": options.tiles,
                "idle_cpu_cores": idleCores,
                "streaming_cpu_cores": streamCores,
                "footprint_delta_mb": Double(Int64(physFootprintBytes()) - Int64(baseFootprint)) / 1_048_576,
                "iosurface_mb": Double(surfaceBytes) / 1_048_576,
                "iosurface_sizes": Array(surfaceSizes),
                "grids": Array(Set(probes.compactMap { $0.grid.map { "\($0.cols)x\($0.rows)" } })),
            ]
            log("cost \(variant) \(row)")
            out[variant] = row
            for p in probes { p.view.removeFromSuperview() }
            probes.removeAll()
        }
        out["scale"] = s
        results["cost"] = out
    }

    // MARK: web

    func webPhase() async {
        log("web phase")
        clear()
        var rows: [[String: Any]] = []
        let html = """
        <!doctype html><meta name=viewport content="width=device-width">
        <body style="margin:0;font:14px -apple-system;background:#111;color:#ddd">
        <h1 style="margin:8px">Gallery probe</h1>
        <p style="margin:8px">\(String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 40))</p>
        </body>
        """
        let script = """
        JSON.stringify({innerWidth: innerWidth, innerHeight: innerHeight, dpr: devicePixelRatio,
          vvScale: visualViewport ? visualViewport.scale : null, clientWidth: document.documentElement.clientWidth})
        """

        func build() async -> (ScaledHost, WKWebView) {
            let host = ScaledHost(frame: NSRect(origin: .zero, size: laneSize))
            window.contentView!.addSubview(host)
            let web = WKWebView(frame: NSRect(origin: .zero, size: laneSize))
            web.allowsMagnification = true
            host.addSubview(web)
            web.loadHTMLString(html, baseURL: nil)
            for _ in 0..<50 where web.isLoading { await pause(0.1) }
            await pause(0.5)
            return (host, web)
        }

        func measure(_ web: WKWebView, _ label: String, _ s: CGFloat) async -> [String: Any] {
            await pause(0.5)
            var row: [String: Any] = ["variant": label, "scale": s]
            if let json = try? await web.evaluateJavaScript(script) as? String,
               let data = json.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                row.merge(dict) { a, _ in a }
            }
            row["web_frame"] = "\(Int(web.frame.width))x\(Int(web.frame.height))"
            row["on_screen_pt"] = { () -> String in
                let r = web.convert(web.bounds, to: nil)
                return "\(Int(r.width))x\(Int(r.height))"
            }()
            row["backing_pixels_of_view"] = { () -> String in
                let r = web.convertToBacking(web.bounds)
                return "\(Int(r.width))x\(Int(r.height))"
            }()
            if let snap = try? await web.takeSnapshot(configuration: nil),
               let cg = snap.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                row["snapshot_pixels"] = "\(cg.width)x\(cg.height)"
            }
            return row
        }

        let (h0, w0) = await build()
        rows.append(await measure(w0, "plain", 1))
        for s in [CGFloat(0.5), 0.33] {
            h0.scale(to: s, full: laneSize)
            h0.layoutSubtreeIfNeeded()
            rows.append(await measure(w0, "transform", s))
            h0.scale(to: 1, full: laneSize)
            h0.layoutSubtreeIfNeeded()

            w0.pageZoom = s
            rows.append(await measure(w0, "pageZoom", s))
            w0.pageZoom = 1

            w0.setMagnification(s, centeredAt: .zero)
            let row = await measure(w0, "magnification", s)
            rows.append(row.merging(["magnification_after_set": w0.magnification]) { a, _ in a })
            w0.setMagnification(1, centeredAt: .zero)
        }
        h0.removeFromSuperview()
        for row in rows { log("web \(row)") }
        results["web"] = rows
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let spike = Spike()
    app.delegate = spike
    app.run()
}
