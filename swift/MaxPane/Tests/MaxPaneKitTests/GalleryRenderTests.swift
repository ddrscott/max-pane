import AppKit
import LanedCore
import Metal
import QuartzCore
import Testing
@testable import MaxPaneKit

private func pane(_ id: String, _ lane: String, _ position: UInt32,
                  kind: PaneKind = .pty, url: String? = nil, state: PaneState = .live) -> Pane {
    Pane(id: id, laneId: lane, position: position, kind: kind,
         relaySessionId: kind == .pty ? id : nil, relayServer: nil, url: url, scrollY: nil, dataStoreId: nil,
         snapshotPath: nil, state: state, heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)
}

private func lane(_ id: String, _ title: String, width: UInt32, span: UInt32 = 1, _ panes: [Pane]) -> Lane {
    Lane(id: id, ordinal: 0, widthPt: width, title: title, projectRoot: "/Users/x/code/\(id)",
         projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false,
         dock: nil, span: span, panes: panes)
}

/// The rule the gallery rests on, at the view level: a tile is the lane at its
/// real size, and only the frame around it is small.
@Suite("gallery tiles")
@MainActor
struct GalleryTileTests {
    /// The lane keeps its exact size. The panes inside it are Auto Layout's, and
    /// AppKit rounds those to the *tile's* pixels — measured here moving a pane
    /// from 483 to 482.5 pt. That is bounded by `roundingTolerance`, and it is
    /// what `TerminalPaneController`'s hold absorbs so a terminal's grid does
    /// not move with it.
    @Test("a tile lays its lane out at the lane's size; panes move by rounding at most")
    func tileKeepsTheLaneSize() {
        let model = lane("a", "claude", width: 656, [pane("a1", "a", 0), pane("a2", "a", 1)])
        let laneView = LaneView(lane: model, widthBounds: 420...900)
        let top = NSView(), bottom = NSView()
        laneView.setPaneView(top, for: "a1", at: 0)
        laneView.setPaneView(bottom, for: "a2", at: 1)
        let size = CGSize(width: 656, height: 1000)

        // As the strip lays it out.
        laneView.frame = CGRect(origin: .zero, size: size)
        laneView.layoutSubtreeIfNeeded()
        let onStrip = (top.bounds.size, bottom.bounds.size)
        #expect(onStrip.0.height > 0 && onStrip.1.height > 0)

        // As a tile at 0.4.
        let tile = GalleryTileView(frame: .zero)
        tile.show(laneView, frame: CGRect(x: 10, y: 10, width: 656 * 0.4, height: 1000 * 0.4), laneSize: size)
        laneView.thumbnailScale = 0.4
        tile.layoutSubtreeIfNeeded()

        func near(_ a: CGSize, _ b: CGSize, _ tolerance: CGFloat = 0.001) -> Bool {
            abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
        }
        #expect(near(tile.frame.size, CGSize(width: 262.4, height: 400)))
        #expect(near(tile.bounds.size, size))
        #expect(laneView.frame.size == size, "the lane itself was resized by becoming a tile")
        let rounding = GalleryLayout.roundingTolerance(scale: 0.4, backingScale: 1)
        #expect(near(top.bounds.size, onStrip.0, rounding))
        #expect(near(bottom.bounds.size, onStrip.1, rounding))

        // Resizing the tile — the window got smaller — still resizes the lane not at all.
        tile.show(laneView, frame: CGRect(x: 0, y: 0, width: 656 * 0.25, height: 1000 * 0.25), laneSize: size)
        laneView.thumbnailScale = 0.25
        tile.layoutSubtreeIfNeeded()
        #expect(near(tile.bounds.size, size))
        #expect(laneView.frame.size == size)
        #expect(near(top.bounds.size, onStrip.0, GalleryLayout.roundingTolerance(scale: 0.25, backingScale: 1)))
    }

    /// A click lands on the cell under the pointer because AppKit converts
    /// through the same transform the compositor draws with.
    @Test("a point in a tile is the matching point in the lane")
    func pointsConvertThroughTheTile() {
        let model = lane("a", "claude", width: 656, [pane("a1", "a", 0)])
        let laneView = LaneView(lane: model, widthBounds: 420...900)
        let gallery = GalleryView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let size = CGSize(width: 656, height: 1000)
        gallery.place(laneView, laneId: "a", frame: CGRect(x: 100, y: 50, width: 262.4, height: 400), laneSize: size)

        // A quarter of the way across and halfway down the tile, in the
        // gallery's coordinates. The gallery is flipped and the lane is not, so
        // halfway is halfway either way.
        let point = gallery.convert(NSPoint(x: 100 + 65.6, y: 50 + 200), to: laneView)
        #expect(abs(point.x - 164) < 0.01)
        #expect(abs(point.y - 500) < 0.01)
    }
}

/// A gallery of mixed lanes, rendered so a human can check it — the tiles'
/// order and wrapping, the split lane's proportions, the placeholder, the accent
/// outline around the focused pane, and how sharp text survives.
///
///     MAXPANE_SHOTS=build/shots ./scripts/test.sh shots build/shots
///
/// **How it is drawn matters more than usual here.** Each lane is rendered at
/// its full size and the panel's backing scale, then shrunk into its tile by
/// Core Animation with the minification filter the app would choose — the same
/// full-size-surface-then-transform path a live tile takes, through the same
/// renderer spike M5 measured. Drawing the lanes straight into a small bitmap
/// would re-rasterise the text at the small size and look sharper than the app
/// ever will. The terminal text is AppKit's, not Ghostty's; the spike's PNGs in
/// `spikes/m5-gallery-scale/out` are real Ghostty surfaces.
///
/// Gated on `MAXPANE_SHOTS` like every other sheet.
@Suite("gallery rendering")
@MainActor
struct GalleryRenderTests {
    private func terminal(_ lines: [(String, NSColor)]) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.laneBackground.cgColor
        let text = NSMutableAttributedString()
        for (index, (line, color)) in lines.enumerated() {
            text.append(NSAttributedString(
                string: line + (index == lines.count - 1 ? "" : "\n"),
                attributes: [.font: Theme.mono(13), .foregroundColor: color]))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            label.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -6),
        ])
        return view
    }

    private func agent(_ project: String, asking: Bool) -> NSView {
        let dim = NSColor(white: 0.55, alpha: 1)
        let text = NSColor(white: 0.85, alpha: 1)
        var lines: [(String, NSColor)] = [
            ("✻ Claude Code   \(project)", Theme.accent),
            ("", text),
        ]
        for i in 0..<14 {
            switch i % 4 {
            case 0: lines.append(("+    let tiles = GalleryLayout.place(widths)", .systemGreen))
            case 1: lines.append(("-    let visible = visibleLaneRange(in: lanes)", .systemRed))
            case 2: lines.append(("⏺ Update(StripViewController.swift) · 42 lines", .systemTeal))
            default: lines.append(("  ⎿  12 lanes, 1 docked, 1 evicted", dim))
            }
        }
        if asking {
            lines += [("", text), ("Do you want to make this edit?", text),
                      ("❯ 1. Yes", Theme.accent), ("  2. Yes, and don't ask again", text),
                      ("  3. No  (esc)", dim)]
        } else {
            lines += [("", text), ("✢ Compiling… (38s · esc to interrupt)", dim)]
        }
        return terminal(lines)
    }

    private func shell(_ lines: [String]) -> NSView {
        terminal(lines.map { ($0, NSColor(white: 0.85, alpha: 1)) })
    }

    private func page(_ title: String) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        let heading = NSTextField(labelWithString: title)
        heading.font = NSFont.systemFont(ofSize: 26, weight: .semibold)
        heading.textColor = NSColor(white: 0.1, alpha: 1)
        let body = NSTextField(wrappingLabelWithString: String(
            repeating: "A tile is its lane drawn smaller, never re-flowed. The page keeps its layout. ", count: 12))
        body.font = NSFont.systemFont(ofSize: 15)
        body.textColor = NSColor(white: 0.25, alpha: 1)
        for label in [heading, body] {
            label.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(label)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            heading.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
        ])
        return view
    }

    /// One lane, drawn at its full size and `backing`× — what a live surface is.
    /// `expanded` draws it as the tile raised over the grid, seams and grips live.
    private func renderLane(_ model: Lane, views: [String: NSView], focused: String?,
                            height: CGFloat, scale: CGFloat, backing: CGFloat,
                            expanded: Bool = false) -> CGImage? {
        let laneView = LaneView(lane: model, widthBounds: 420...1800)
        for (index, p) in model.panes.enumerated() {
            let view = views[p.id] ?? PlaceholderView(pane: p)
            laneView.setPaneView(view, for: p.id, at: index)
        }
        laneView.isFocused = model.panes.contains { $0.id == focused }
        laneView.focusedPaneId = focused
        laneView.thumbnailScale = scale
        laneView.isExpandedTile = expanded
        let size = CGSize(width: CGFloat(model.widthPt), height: height)
        laneView.frame = CGRect(origin: .zero, size: size)
        laneView.layoutSubtreeIfNeeded()

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * backing), pixelsHigh: Int(size.height * backing),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        laneView.cacheDisplay(in: laneView.bounds, to: rep)
        return rep.cgImage
    }

    /// A lane's picture and where it is drawn: its tile's frame in the gallery
    /// and the scale that shrinks it there. The expanded tile is one of these
    /// too, last so it is drawn over the rest.
    private struct Tile {
        var image: CGImage
        var frame: CGRect
        var scale: CGFloat
    }

    /// Shrink every lane into its tile through Core Animation, as the window
    /// server would draw a transformed layer.
    private func composite(_ tiles: [Tile], size: CGSize, backing: CGFloat,
                           appearance: NSAppearance.Name) -> CGImage? {
        let w = Int(size.width * backing), h = Int(size.height * backing)
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let root = CALayer()
        root.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        root.anchorPoint = .zero
        root.position = .zero
        root.isGeometryFlipped = true
        root.backgroundColor = Theme.stripBackground.cgColor(in: NSAppearance(named: appearance)!)
        for tile in tiles {
            let layer = CALayer()
            layer.contents = tile.image
            layer.contentsGravity = .resize
            layer.bounds = CGRect(x: 0, y: 0, width: tile.image.width, height: tile.image.height)
            layer.anchorPoint = .zero
            layer.position = CGPoint(x: tile.frame.minX * backing, y: tile.frame.minY * backing)
            layer.transform = CATransform3DMakeScale(tile.scale, tile.scale, 1)
            layer.minificationFilter = GalleryLayout.minificationFilter(scale: tile.scale, backingScale: backing)
            root.addSublayer(layer)
        }
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.commit()
        CATransaction.flush()

        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        let fence = queue.makeCommandBuffer()
        fence?.commit()
        fence?.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// `CARenderer` hands its texture back with the first row at the bottom.
    private func flippedVertically(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Both panel densities, and each in both appearances. The split lane `a`
    /// is drawn twice: in its slot as an ordinary tile, seam inert and grips
    /// hidden, and again raised over the grid as the expanded tile, where the
    /// seam is a handle and the grips are back — clamped in both sheets, since
    /// the lane is as tall as the gallery, so the handles are drawn through the
    /// scale the pointer will be mapped through.
    @Test("renders a gallery of mixed lanes, with an expanded stacked tile, at both panel densities and in both appearances")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }

        let lanes: [Lane] = [
            lane("a", "claude — max-pane", width: 656, [pane("a1", "a", 0), pane("a2", "a", 1)]),
            lane("b", "ghostty.org — docs", width: 656, [pane("b1", "b", 0, kind: .web, url: "https://ghostty.org/docs")]),
            lane("c", "github.com — pull 42", width: 656, [
                pane("c1", "c", 0, kind: .placeholder, url: "https://github.com/ddrscott/max-pane/pull/42", state: .evicted)]),
            lane("d", "claude — relay-tty", width: 1312, span: 2, [pane("d1", "d", 0)]),
            lane("e", "cargo test", width: 540, [pane("e1", "e", 0)]),
            lane("f", "claude — laned-core", width: 656, [pane("f1", "f", 0)]),
            lane("g", "localhost:3000", width: 900, [pane("g1", "g", 0, kind: .web, url: "http://localhost:3000")]),
            lane("h", "claude — dotfiles", width: 656, [pane("h1", "h", 0)]),
            lane("i", "htop", width: 420, [pane("i1", "i", 0)]),
            lane("j", "claude — pretty-good-ai", width: 656, [pane("j1", "j", 0)]),
        ]
        let focused = "a2"
        func views() -> [String: NSView] {
            [
                "a1": agent("max-pane · feat/gallery-layout", asking: false),
                "a2": shell(["~/code/max-pane $ ./scripts/test.sh", "==> laned-core", "test result: ok. 39 passed", "==> MaxPane", "✔ gallery layout (10 tests)"]),
                "b1": page("Ghostty docs"),
                "d1": agent("relay-tty · main", asking: true),
                "e1": shell(["$ cargo test -p laned-core", "   Compiling laned-core v0.1.0", "    Finished test [unoptimized]", "     Running tests/durability.rs", "test the_layout_survives_an_unclean_exit ... ok"]),
                "f1": agent("laned-core · eviction", asking: true),
                "g1": page("localhost:3000"),
                "h1": agent("dotfiles · chezmoi", asking: false),
                "i1": shell(["  PID USER      %CPU  COMMAND", "  812 spierce   38.0  MaxPane", "  901 spierce   12.4  relay-pty-host", "  344 spierce    3.1  WebContent"]),
                "j1": agent("pretty-good-ai · web", asking: true),
            ]
        }

        let panels: [(String, CGSize, CGFloat)] = [
            ("laptop-2x", CGSize(width: 1728, height: 1080), 2),
            ("ultrawide-1x", CGSize(width: 3840, height: 1570), 1),
        ]
        let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
        for (mode, appearance) in appearances {
            app.appearance = NSAppearance(named: appearance)
            for (name, size, backing) in panels {
                let placement = GalleryLayout.place(
                    widths: lanes.map { CGFloat($0.widthPt) }, laneHeight: size.height, in: size)
                let filter = GalleryLayout.minificationFilter(scale: placement.scale, backingScale: backing)
                let stubs = views()
                var tiles: [Tile] = []
                for (index, lane) in lanes.enumerated() {
                    guard let image = renderLane(lane, views: stubs, focused: focused, height: size.height,
                                                 scale: placement.scale, backing: backing)
                    else { continue }
                    let slot = placement.rects[index]
                    let laneSize = CGSize(width: CGFloat(lane.widthPt), height: size.height)
                    tiles.append(Tile(
                        image: image,
                        frame: CGRect(x: slot.minX, y: slot.minY,
                                      width: laneSize.width * placement.scale, height: laneSize.height * placement.scale),
                        scale: placement.scale))
                }
                #expect(tiles.count == lanes.count)

                // The split lane, expanded over its own slot as `layoutGallery`
                // would draw it: real size clamped to the gallery, seams live.
                let laneSize = CGSize(width: CGFloat(lanes[0].widthPt), height: size.height)
                let expanded = GalleryLayout.expanded(tile: tiles[0].frame, laneSize: laneSize, in: size)
                let expandedScale = expanded.width / laneSize.width
                if let image = renderLane(lanes[0], views: views(), focused: focused, height: size.height,
                                          scale: expandedScale, backing: backing, expanded: true) {
                    tiles.append(Tile(image: image, frame: expanded, scale: expandedScale))
                }
                #expect(expandedScale >= PaneSplit.minimumLiveScale,
                        "the sheet's expanded tile must be one whose seams are live, or it shows nothing")

                guard let upsideDown = composite(tiles, size: size, backing: backing, appearance: appearance),
                      let sheet = flippedVertically(upsideDown)
                else { continue }
                let png = try #require(NSBitmapImageRep(cgImage: sheet).representation(using: .png, properties: [:]))
                let file = "gallery-\(name)-scale\(String(format: "%.2f", placement.scale))-\(filter.rawValue)-\(mode).png"
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
            }
        }
    }
}
