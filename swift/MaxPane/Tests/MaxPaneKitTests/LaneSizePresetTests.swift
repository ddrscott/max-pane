import AppKit
import GhosttyTerminal
import LanedCore
import Testing
import WebKit
@testable import MaxPaneKit

/// `s | m | xl`. What has to hold is arithmetic that Ghostty agrees with, a lit
/// preset that follows width, span and zoom rather than a stored copy, and a
/// terminal that keeps its columns through `m → s → m` without the far end
/// hearing about a shape nobody chose.
@Suite("lane size presets")
@MainActor
struct LaneSizePresetTests {
    // MARK: - the arithmetic

    /// The whole point of `s`: the same columns in less width. Checked tight —
    /// one point narrower loses a column — at several font sizes and on both
    /// kinds of panel, because a whole-pixel cell is a different number of
    /// points on each.
    @Test("s holds exactly m's columns at 60% text", arguments: [10.0, 12.0, 13.0, 14.0, 16.0])
    func smallHoldsTheColumns(_ fontSize: Double) {
        for backing in [1.0, 2.0] as [CGFloat] {
            var config = Config()
            config.fontSize = fontSize
            let full = LaneSizePreset.cellWidth(fontName: config.fontName, fontSize: fontSize, backingScale: backing)
            let small = LaneSizePreset.cellWidth(
                fontName: config.fontName, fontSize: fontSize * 0.6, backingScale: backing)
            let columns = LaneSizePreset.columns(inWidth: CGFloat(config.laneDefaultPt), cellWidth: full)
            let width = LaneSizePreset.terminalSmallWidth(config: config, backingScale: backing)
            let at = "\(fontSize) pt @\(backing)x: cells \(full)/\(small), \(columns) columns, s = \(width) pt"

            #expect(LaneSizePreset.columns(inWidth: CGFloat(width), cellWidth: small) == columns, "\(at)")
            #expect(LaneSizePreset.columns(inWidth: CGFloat(width) - 1, cellWidth: small) == columns - 1, "\(at)")
            #expect(width < config.laneDefaultPt, "\(at)")
        }
    }

    /// 13 pt JetBrains Mono in numbers: an 8 pt cell and 80 columns at `m`, and
    /// at 60% a cell that is a whole number of *pixels* — 5 pt on a 1× panel,
    /// 4.5 pt on Retina — so `s` is 412 pt or 372 pt, and never `0.6 × 656`.
    /// The config names JetBrains Mono whether or not it is installed; Ghostty
    /// has its own copy, so the answer is the same either way.
    @Test("the default case: 80 columns in 412 pt at 1×, 372 pt on Retina, never 0.6 × 656")
    func theOwnersNumbers() {
        let config = Config()
        for (backing, cell, width) in [(1.0, 5.0, 412), (2.0, 4.5, 372)] as [(CGFloat, CGFloat, UInt32)] {
            #expect(LaneSizePreset.cellWidth(fontName: config.fontName, fontSize: 13, backingScale: backing) == 8)
            #expect(LaneSizePreset.cellWidth(fontName: config.fontName, fontSize: 7.8, backingScale: backing) == cell)
            #expect(LaneSizePreset.terminalSmallWidth(config: config, backingScale: backing) == width)
        }
        #expect(LaneSizePreset.webSmallWidth(config: config) == 394)
    }

    @Test("m is the default, xl is double wide, both at actual size")
    func mediumAndLarge() {
        let config = Config()
        #expect(LaneSizePreset.shape(.m, hasTerminal: true, config: config, backingScale: 2)
            == .init(widthPt: 656, span: 1, terminalZoom: 1, webZoom: 1))
        #expect(LaneSizePreset.shape(.xl, hasTerminal: false, config: config, backingScale: 2)
            == .init(widthPt: 1312, span: 2, terminalZoom: 1, webZoom: 1))
    }

    /// A page at `s` lays out exactly as at `m`: width over zoom is m's width,
    /// in a lane of pages and beside a terminal alike.
    @Test("a web pane at s keeps m's layout width, alone or beside a terminal")
    func webKeepsItsLayoutWidth() {
        let config = Config()
        for hasTerminal in [false, true] {
            let shape = LaneSizePreset.shape(.s, hasTerminal: hasTerminal, config: config, backingScale: 2)
            #expect(abs(Double(shape.widthPt) / shape.webZoom - Double(config.laneDefaultPt)) < 1e-9)
            #expect(shape.terminalZoom == 0.6)
        }
    }

    // MARK: - which one is lit

    @Test("the lit preset is derived from width, span and zoom")
    func derivation() {
        let config = Config()
        func lit(_ width: UInt32, span: UInt32 = 1, _ panes: [(PaneKind, Double)]) -> LaneSizePreset? {
            let lane = Self.lane(width: width, span: span, panes: panes)
            return LaneSizePreset.current(of: lane, zoom: \.zoom, config: config, backingScale: 2)
        }
        let sTerm = LaneSizePreset.terminalSmallWidth(config: config, backingScale: 2)
        let sWeb = LaneSizePreset.webSmallWidth(config: config)

        #expect(lit(656, [(.pty, 1)]) == .m)
        #expect(lit(1312, span: 2, [(.pty, 1)]) == .xl)
        #expect(lit(sTerm, [(.pty, 0.6)]) == .s)
        #expect(lit(sWeb, [(.web, Double(sWeb) / 656)]) == .s)
        // A split lane: the terminal decides the width, the page follows it.
        #expect(lit(sTerm, [(.pty, 0.6), (.web, Double(sTerm) / 656)]) == .s)

        // Dragged off, zoomed off, spanned off: nothing lit.
        #expect(lit(700, [(.pty, 1)]) == nil)
        #expect(lit(656, [(.pty, 1.1)]) == nil)
        #expect(lit(656, [(.pty, 1), (.web, 0.9)]) == nil)
        #expect(lit(1312, span: 1, [(.pty, 1)]) == nil)
        #expect(lit(1800, span: 2, [(.pty, 1)]) == nil, "the old Span Lane's 1800 pt is not xl")
        #expect(lit(sTerm, [(.pty, 1)]) == nil, "s's width at full size is not s")
    }

    // MARK: - docked

    /// A dock takes the presets on its own width, inside its own bounds, and
    /// the tick follows that width. The strip width and span are not asked.
    @Test("a dock's preset width is clamped into 240...900, and the tick follows the dock width")
    func dockedShapes() {
        let config = Config()
        func docked(_ preset: LaneSizePreset, _ config: Config = Config(), terminal: Bool = true) -> LaneSizePreset.Shape {
            LaneSizePreset.shape(preset, hasTerminal: terminal, config: config, backingScale: 2, docked: true)
        }
        let sTerm = LaneSizePreset.terminalSmallWidth(config: config, backingScale: 2)
        #expect(docked(.m).widthPt == 656)
        #expect(docked(.s) == LaneSizePreset.shape(.s, hasTerminal: true, config: config, backingScale: 2))
        #expect(docked(.xl).widthPt == 900, "xl is wider than a dock may be")
        #expect(docked(.xl).terminalZoom == 1 && docked(.xl).webZoom == 1)

        // A default narrower than a dock may be: s clamps up to the floor, and a
        // page's zoom follows the width it really gets.
        var narrow = Config()
        narrow.laneDefaultPt = 380
        let small = docked(.s, narrow, terminal: false)
        #expect(small.widthPt == 240)
        #expect(abs(small.webZoom - 240.0 / 380.0) < 1e-9)

        func lit(dock width: UInt32, strip: UInt32 = 700, span: UInt32 = 1, _ panes: [(PaneKind, Double)]) -> LaneSizePreset? {
            var lane = Self.lane(width: strip, span: span, panes: panes)
            lane.dock = Dock(side: .left, mode: .overlay, widthPt: width)
            return LaneSizePreset.current(of: lane, zoom: \.zoom, config: config, backingScale: 2)
        }
        #expect(lit(dock: 900, [(.pty, 1)]) == .xl)
        #expect(lit(dock: 656, [(.pty, 1)]) == .m)
        #expect(lit(dock: 656, strip: 1800, span: 2, [(.pty, 1)]) == .m, "a dock has no span to compare")
        #expect(lit(dock: sTerm, [(.pty, 0.6)]) == .s)
        #expect(lit(dock: 500, strip: 656, [(.pty, 1)]) == nil, "the strip width is not the dock's")
    }

    /// The store path the menu and switch take, on a docked lane: the dock's
    /// width, clamped, in one revision, and the strip's width left for later.
    @Test("a preset on a docked lane writes the dock width and keeps the strip width")
    func dockedStoreWrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-dock-preset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "dock-preset", near: nil)
        let before = try #require(store.state.lanes.first)
        try store.dockLane(before.id, side: .right, mode: .inset)
        let config = Config()

        let xl = LaneSizePreset.shape(.xl, hasTerminal: true, config: config, backingScale: 2, docked: true)
        try store.setLaneSize(before.id, widthPt: xl.widthPt, span: xl.span, zooms: [])
        var after = try #require(store.lane(before.id))
        #expect(after.dock?.widthPt == 900)
        #expect(after.widthPt == before.widthPt && after.span == before.span)
        #expect(LaneSizePreset.current(of: after, zoom: \.zoom, config: config, backingScale: 2) == .xl)

        // Asked for wider than a dock may be, the core clamps too.
        try store.setLaneSize(before.id, widthPt: 1312, span: 2, zooms: [])
        after = try #require(store.lane(before.id))
        #expect(after.dock?.widthPt == 900 && after.span == before.span)
    }

    // MARK: - the commands

    @Test("three presets in the View menu with no keys, and ⌘\\ cycles them")
    func commands() {
        let commands: [Command] = [.laneSizeSmall, .laneSizeMedium, .laneSizeLarge]
        #expect(LaneSizePreset.allCases.map(\.command) == commands)
        for command in commands {
            #expect(command.menu == .view)
            #expect(Keymap.defaults.chords(for: command).isEmpty, "\(command) ships with a key")
            #expect(command.title.hasPrefix("Lane Size: "))
        }
        #expect(Command.laneSizeCycle.menu == .view)
        #expect(Keymap.defaults.chords(for: .laneSizeCycle) == [KeyChord(key: "\\", modifiers: [.command])])
        // Rebindable like any other: the config names it by its raw value.
        #expect(Command(rawValue: "laneSizeCycle") == .laneSizeCycle)
    }

    @Test("Span Lane is gone: no command, no title, and ⌘\\ belongs to the cycle")
    func spanIsGone() {
        #expect(Command(rawValue: "toggleSpan") == nil)
        #expect(!Command.allCases.contains { $0.title.localizedCaseInsensitiveContains("span") })
        let chord = KeyChord(key: "\\", modifiers: [.command])
        #expect(Command.allCases.filter { Keymap.defaults.chords(for: $0).contains(chord) } == [.laneSizeCycle])
    }

    @Test("⌘\\ cycles s → m → xl → s, and a lane off every preset goes to m")
    func cycleOrder() {
        #expect(LaneSizePreset.next(after: .s) == .m)
        #expect(LaneSizePreset.next(after: .m) == .xl)
        #expect(LaneSizePreset.next(after: .xl) == .s)
        #expect(LaneSizePreset.next(after: nil) == .m)

        // Three presses from m come back to m.
        var preset = LaneSizePreset.m
        for _ in 0..<3 { preset = LaneSizePreset.next(after: preset) }
        #expect(preset == .m)

        // A lane the old Span Lane left at 1800 pt is off every preset: m first.
        let old = Self.lane(width: 1800, span: 2, panes: [(.pty, 1)])
        let current = LaneSizePreset.current(of: old, zoom: \.zoom, config: Config(), backingScale: 2)
        #expect(current == nil)
        #expect(LaneSizePreset.next(after: current) == .m)
    }

    // MARK: - the menu

    /// The acceptance test in the ticket's own terms: three items, always, with
    /// the tick on the current preset and none off every preset — on a wide
    /// lane, one too narrow for the switch, and a docked one.
    @Test("every lane's menu lists Small, Medium and Extra Large: wide, narrow and docked")
    func menuListsThePresets() {
        let titles = LaneSizePreset.allCases.map(\.title)
        func sizeItems(_ view: LaneView) -> [NSMenuItem] {
            view.overflowMenu.items.filter { titles.contains($0.title) }
        }
        func ticked(_ view: LaneView) -> [String] {
            sizeItems(view).filter { $0.state == .on }.map(\.title)
        }

        var lane = Self.lane(width: 656, panes: [(.pty, 1)])
        let view = LaneView(lane: lane, widthBounds: 420...900)
        var picked: [LaneSizePreset] = []
        view.onSizePreset = { picked.append($0) }
        func size(_ width: CGFloat) {
            view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            view.layoutSubtreeIfNeeded()
        }

        // Wide: the switch shows, and the menu has all three anyway.
        size(656)
        view.sizePreset = .m
        #expect(view.sizeSwitchIsVisible)
        #expect(sizeItems(view).map(\.title) == titles)
        #expect(sizeItems(view).allSatisfy { $0.isEnabled })
        #expect(ticked(view) == ["Medium"])
        view.sizePreset = nil
        #expect(sizeItems(view).count == 3 && ticked(view).isEmpty, "off every preset ticks nothing")

        // Narrow: no room for the switch, and the menu does not care.
        size(260)
        view.sizePreset = .s
        #expect(!view.sizeSwitchIsVisible)
        #expect(sizeItems(view).map(\.title) == titles)
        #expect(sizeItems(view).allSatisfy { $0.isEnabled })
        #expect(ticked(view) == ["Small"])

        // Docked: the presets, the tick, and the switch when there is room.
        lane.dock = Dock(side: .right, mode: .inset, widthPt: 900)
        view.apply(lane)
        view.sizePreset = .xl
        size(900)
        #expect(view.showsSizeSwitch && view.sizeSwitchIsVisible)
        #expect(sizeItems(view).map(\.title) == titles)
        #expect(sizeItems(view).allSatisfy { $0.isEnabled })
        #expect(ticked(view) == ["Extra Large"])

        // Choosing one goes where the switch goes.
        for item in sizeItems(view).reversed() {
            _ = (item.target as? NSObject)?.perform(item.action, with: item)
        }
        #expect(picked == [.xl, .m, .s])

        // A gallery tile lists them but greys them out: it writes nothing.
        view.thumbnailScale = 0.4
        #expect(sizeItems(view).count == 3)
        #expect(sizeItems(view).allSatisfy { !$0.isEnabled })
    }

    // MARK: - the switch

    @Test("the switch lights one preset or none, and says which was pressed")
    func switchLights() {
        let control = LaneSizeSwitch()
        var picked: [LaneSizePreset] = []
        control.onPick = { picked.append($0) }
        #expect(control.buttons.values.allSatisfy { !$0.isOn })

        control.selected = .s
        #expect(control.buttons[.s]!.isOn && !control.buttons[.m]!.isOn && !control.buttons[.xl]!.isOn)
        control.selected = nil
        #expect(control.buttons.values.allSatisfy { !$0.isOn })

        for preset in [LaneSizePreset.xl, .m, .s] {
            let button = control.buttons[preset]!
            _ = (button.target as? NSObject)?.perform(button.action, with: button)
        }
        #expect(picked == [.xl, .m, .s])
        #expect(control.buttons[.xl]!.title == "xl")
    }

    @Test("the switch is square and one border wide between segments")
    func switchGeometry() {
        let control = LaneSizeSwitch()
        control.frame = NSRect(x: 0, y: 0, width: control.fittingWidth, height: LaneSizeSwitch.height)
        control.layoutSubtreeIfNeeded()
        #expect(control.buttons[.m]!.frame.minX == control.buttons[.s]!.frame.maxX - Theme.borderWidth)
        #expect(control.buttons[.xl]!.frame.maxX == control.fittingWidth)
        #expect(control.buttons.values.allSatisfy { $0.layer?.cornerRadius == 0 })
    }

    /// Offered on the strip and on a dock; hidden on a gallery tile, which
    /// writes nothing.
    @Test("the header offers the switch on the strip and on a dock, not on a tile")
    func switchVisibility() {
        var lane = Self.lane(width: 656, panes: [(.pty, 1)])
        let view = LaneView(lane: lane, widthBounds: 420...900)
        #expect(view.showsSizeSwitch)

        view.thumbnailScale = 0.4
        #expect(!view.showsSizeSwitch)
        view.thumbnailScale = nil
        #expect(view.showsSizeSwitch)

        lane.dock = Dock(side: .right, mode: .inset, widthPt: 400)
        view.apply(lane)
        #expect(view.showsSizeSwitch)
    }

    // MARK: - against a real Ghostty surface

    /// The cell metric above is a prediction of Ghostty's; this is Ghostty
    /// answering. The surface's own font-size actions put it at each size, and
    /// the cell it reports has to be the one `cellWidth` said.
    @Test("Ghostty's reported cell is the one the arithmetic predicts, at several sizes")
    func ghosttyAgreesOnTheCell() async throws {
        let rig = try await GhosttyRig(width: 656)
        defer { rig.close() }
        let config = Config()
        for zoom in [1.0, 0.6, 0.8, 1.25, 1.5] {
            rig.setZoom(zoom)
            let viewport = try await rig.settled()
            let metrics = try #require(rig.grid.last, "the surface reported no metrics")
            let predicted = LaneSizePreset.cellWidth(
                fontName: config.fontName, fontSize: config.fontSize * zoom, backingScale: rig.backing)
            #expect(
                CGFloat(metrics.cellWidthPixels) == predicted * rig.backing,
                "zoom \(zoom) @\(rig.backing)x: \(metrics), \(viewport)")
            // And the grid agrees with the cell: the columns are whole cells of it.
            let columns = LaneSizePreset.columns(inWidth: rig.terminal.frame.width, cellWidth: predicted)
            #expect(Int(viewport.columns) == columns, "zoom \(zoom): \(viewport)")
        }
    }

    /// The acceptance test in the ticket's own terms: Ghostty reports the same
    /// column count at `s` as at `m`.
    @Test("Ghostty reports m's columns at s's width and 60% text")
    func ghosttyAgreesOnTheColumns() async throws {
        let rig = try await GhosttyRig(width: 656)
        defer { rig.close() }
        let atMedium = try await rig.settled()

        rig.setZoom(0.6)
        rig.setWidth(CGFloat(LaneSizePreset.terminalSmallWidth(config: Config(), backingScale: rig.backing)))
        let atSmall = try await rig.settled()
        #expect(atSmall.columns == atMedium.columns, "m \(atMedium), s \(atSmall)")
        #expect(atSmall.rows > atMedium.rows, "a smaller font fits more rows in the same height")

        // And one point narrower really is a column fewer: the width is tight.
        rig.setWidth(CGFloat(LaneSizePreset.terminalSmallWidth(config: Config(), backingScale: rig.backing)) - 1)
        let tooNarrow = try await rig.settled()
        #expect(tooNarrow.columns == atMedium.columns - 1)
    }

    /// `m → s → m` through the pane's own transition, with an attachment that
    /// records every size sent to the far end. The columns are never changed,
    /// nothing is sent mid-ease, and the round trip ends where it started.
    @Test("m → s → m keeps the columns and sends no size it only passed through")
    func roundTripSendsNoIntermediateSize() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        try store.newTerminalLane(relaySessionId: "preset-test", near: nil)
        let pane = try #require(store.state.lanes.first?.panes.first)

        let config = Config()
        // Its own Ghostty controller: the shared one follows the appearance of
        // every surface it minted, and another suite is waiting on it.
        let controller = TerminalPaneController(
            pane: pane, store: store, config: config,
            controller: TerminalControllerPool.makeController(for: config))
        let attachment = RecordingAttachment()
        controller.attach(attachment)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = controller.view
        container.frame = NSRect(x: 0, y: 0, width: 656, height: 500)
        window.contentView?.addSubview(container)
        let backing = window.backingScaleFactor

        try await quiet { attachment.claims.count }
        let start = try #require(attachment.claims.last, "the pane never claimed a size")
        attachment.claims.removeAll()

        /// One preset, eased the way the strip eases it. Returns what it sent.
        func ease(to width: CGFloat, zoom: Double) async throws -> [RecordingAttachment.Size] {
            let before = attachment.claims.count
            let from = container.frame.width
            controller.beginSizeTransition(toZoom: zoom, backingScale: backing)
            for frame in 1...12 {
                let eased = Motion.easeOut(CGFloat(frame) / 12)
                container.setFrameSize(NSSize(width: from + (width - from) * eased, height: 500))
                container.layoutSubtreeIfNeeded()
                controller.stepSizeTransition(eased)
                try await Task.sleep(nanoseconds: 16_000_000)
                #expect(
                    attachment.claims.count == before,
                    "a size went out mid-ease: \(attachment.claims.dropFirst(before))")
            }
            controller.endSizeTransition()
            try await Task.sleep(nanoseconds: UInt64((TerminalPaneController.settleDelay + 0.5) * 1e9))
            return Array(attachment.claims.dropFirst(before))
        }

        let small = CGFloat(LaneSizePreset.terminalSmallWidth(config: config, backingScale: backing))
        let toSmall = try await ease(to: small, zoom: 0.6)
        // Rows may change — a smaller font fits more of them in the same height
        // — and that is one size, sent once, with every column where it was.
        #expect(toSmall.count <= 1, "m → s: \(toSmall)")
        #expect(toSmall.allSatisfy { $0.cols == start.cols }, "m → s moved the columns: \(toSmall)")
        #expect(controller.zoom == 0.6)

        let toMedium = try await ease(to: 656, zoom: 1)
        #expect(toMedium.count <= 1, "s → m: \(toMedium)")
        #expect(toMedium.allSatisfy { $0.cols == start.cols }, "s → m moved the columns: \(toMedium)")
        // Back where it began: whatever went out on the way there came back.
        #expect((attachment.claims.last ?? start) == start, "the round trip ended elsewhere: \(attachment.claims)")
        controller.tearDown()
    }

    // MARK: - against real WebKit

    /// A page at `s` shows at 60% in 60% of m's width, and the page itself sees
    /// no change: `innerWidth` is m's. At `xl` it gets the whole double width.
    @Test("a page's innerWidth at s is its innerWidth at m; at xl it doubles")
    func webInnerWidth() async throws {
        let config = Config()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 656, height: 400), configuration: .init())
        window.contentView?.addSubview(web)
        web.loadHTMLString(
            "<!doctype html><meta name=viewport content='width=device-width'><body>lane</body>", baseURL: nil)

        func innerWidth(expecting expected: Int? = nil) async throws -> Int? {
            var last: Int?
            for _ in 0..<200 {
                let script = "document.readyState === 'complete' ? window.innerWidth : null"
                last = try? await web.evaluateJavaScript(script) as? Int
                if let last, expected == nil || last == expected { return last }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            return last
        }

        let medium = try #require(try await innerWidth())
        #expect(medium == 656)

        let s = LaneSizePreset.shape(.s, hasTerminal: false, config: config, backingScale: window.backingScaleFactor)
        web.setFrameSize(NSSize(width: CGFloat(s.widthPt), height: 400))
        web.pageZoom = CGFloat(s.webZoom)
        #expect(try await innerWidth(expecting: medium) == medium, "s at \(s.widthPt) pt, zoom \(s.webZoom)")

        let xl = LaneSizePreset.shape(.xl, hasTerminal: false, config: config, backingScale: 2)
        web.setFrameSize(NSSize(width: CGFloat(xl.widthPt), height: 400))
        web.pageZoom = CGFloat(xl.webZoom)
        #expect(try await innerWidth(expecting: 1312) == 1312)
    }

    // MARK: - the sheet

    /// Gated on `MAXPANE_SHOTS` like every other sheet: the switch in a header at
    /// each preset's width, lit, and a dragged lane with nothing lit.
    @Test("renders the header switch at each preset, on the strip and on docks")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let rows: [(preset: LaneSizePreset?, width: CGFloat, focused: Bool, dock: DockSide?, title: String)] = [
            (.s, 412, false, nil, "claude — s"), (.m, 656, true, nil, "claude — m"),
            (.xl, 1312, false, nil, "claude — xl"), (nil, 700, false, nil, "dragged to 700 pt"),
            (.s, 372, true, .right, "docked right — s"), (.xl, 900, false, .left, "docked left — xl"),
            (.m, 656, false, .right, "docked right — m"), (nil, 280, false, .left, "docked, 280 pt: no room"),
        ]
        try AppearanceSheet.render(to: dir, named: "lane-size-switch") {
            let width: CGFloat = 1312
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * 40))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            for (index, row) in rows.enumerated() {
                // A whole lane rather than a bare header, so the switch's
                // visibility comes from the same place it does in the app.
                var lane = Self.lane(width: UInt32(row.width), panes: [(.pty, 1)], title: row.title)
                lane.dock = row.dock.map { Dock(side: $0, mode: .inset, widthPt: UInt32(row.width)) }
                let view = LaneView(lane: lane, widthBounds: 240...1800)
                view.frame = NSRect(
                    x: 0, y: CGFloat(rows.count - index - 1) * 40 + 6, width: row.width, height: Theme.laneHeaderHeight)
                view.applyTelemetry(["a": SessionTelemetry(
                    sessionId: "a", cwd: "/Users/spierce/code/max-pane", command: "claude",
                    state: .working, bytesPerSecond: 1740, lastActivity: Date())])
                view.isFocused = row.focused
                view.sizePreset = row.preset
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            return sheet
        }
    }

    /// The `⋯` menu's own items, drawn as rows: what the menu holds on a docked
    /// lane and on one too narrow for the switch. An `NSMenu` draws in its own
    /// window during tracking and cannot be cached to a bitmap, so this is its
    /// contents — titles, ticks, keys, enabled state, separators — not the
    /// system's chrome around them.
    @Test("renders the lane menu on a docked lane and a narrow one")
    func renderMenuSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        var docked = Self.lane(width: 700, panes: [(.pty, 1)], title: "docked")
        docked.dock = Dock(side: .right, mode: .inset, widthPt: 372)
        let narrow = Self.lane(width: 260, panes: [(.web, 1)], title: "narrow")
        let cases: [(Lane, CGFloat, LaneSizePreset?)] = [(docked, 372, .s), (narrow, 260, nil)]

        try AppearanceSheet.render(to: dir, named: "lane-size-menu") {
            let columnWidth: CGFloat = 330
            let rowHeight: CGFloat = 22
            let menus = cases.map { lane, width, preset -> NSMenu in
                let view = LaneView(lane: lane, widthBounds: 240...900)
                view.frame = NSRect(x: 0, y: 0, width: width, height: 300)
                view.onSizePreset = { _ in }
                view.onTogglePin = {}
                view.onDockLeft = {}
                view.onDockRight = {}
                view.onToggleDockMode = {}
                view.onCloseLane = {}
                view.sizePreset = preset
                return view.overflowMenu
            }
            let tallest = menus.map { CGFloat($0.items.count) * rowHeight }.max() ?? 0
            let sheet = NSView(frame: NSRect(
                x: 0, y: 0, width: CGFloat(menus.count) * (columnWidth + 16) + 16, height: tallest + 56))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            for (column, menu) in menus.enumerated() {
                let x = 16 + CGFloat(column) * (columnWidth + 16)
                let caption = NSTextField(labelWithString: column == 0 ? "docked right, 372 pt, at s" : "260 pt, off every preset")
                caption.font = Theme.mono(11)
                caption.textColor = .secondaryLabelColor
                caption.frame = NSRect(x: x, y: sheet.bounds.height - 26, width: columnWidth, height: 16)
                sheet.addSubview(caption)
                let panel = NSView(frame: NSRect(
                    x: x, y: sheet.bounds.height - 34 - CGFloat(menu.items.count) * rowHeight,
                    width: columnWidth, height: CGFloat(menu.items.count) * rowHeight))
                panel.wantsLayer = true
                panel.layerBackgroundColor = Theme.laneBackground
                panel.layerBorderColor = Theme.laneBorder
                panel.layer?.borderWidth = Theme.borderWidth
                sheet.addSubview(panel)
                for (index, item) in menu.items.enumerated() {
                    let y = panel.bounds.height - CGFloat(index + 1) * rowHeight
                    if item.isSeparatorItem {
                        let rule = NSView(frame: NSRect(x: 8, y: y + rowHeight / 2, width: columnWidth - 16, height: 1))
                        rule.wantsLayer = true
                        rule.layerBackgroundColor = Theme.laneBorder
                        panel.addSubview(rule)
                        continue
                    }
                    let colour = item.isEnabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
                    let tick = NSTextField(labelWithString: item.state == .on ? "✓" : "")
                    let title = NSTextField(labelWithString: item.title)
                    let key = NSTextField(labelWithString: item.keyEquivalent.isEmpty ? "" : KeyChord(
                        key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask).text)
                    for (field, frame) in [
                        (tick, NSRect(x: 6, y: y + 3, width: 16, height: 16)),
                        (title, NSRect(x: 24, y: y + 3, width: 220, height: 16)),
                        (key, NSRect(x: 244, y: y + 3, width: columnWidth - 252, height: 16)),
                    ] {
                        field.font = Theme.mono(12)
                        field.textColor = colour
                        field.frame = frame
                        panel.addSubview(field)
                    }
                    key.alignment = .right
                }
            }
            return sheet
        }
    }

    // MARK: - helpers

    static func lane(
        width: UInt32, span: UInt32 = 1, panes: [(PaneKind, Double)], title: String = "lane"
    ) -> Lane {
        Lane(id: "l", ordinal: 1, widthPt: width, title: title, projectRoot: "/Users/spierce/code/max-pane",
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: span,
             panes: panes.enumerated().map { index, pane in
                 Pane(id: "p\(index)", laneId: "l", position: UInt32(index), kind: pane.0,
                      relaySessionId: pane.0 == .pty ? "a" : nil,
                      url: pane.0 == .web ? "https://example.com" : nil, scrollY: nil, dataStoreId: nil,
                      snapshotPath: nil, state: .live, heightWeight: 1, zoom: pane.1)
             })
    }

    /// Wait until `count` has been non-zero and unchanged for a while.
    private func quiet(_ count: () -> Int) async throws {
        var quiet = 0
        var last = count()
        for _ in 0..<240 where quiet < 12 {
            try await Task.sleep(nanoseconds: 25_000_000)
            let now = count()
            quiet = (now == last && now > 0) ? quiet + 1 : 0
            last = now
        }
    }
}

/// Every size a pane sends to the far end, and nothing else.
@MainActor
private final class RecordingAttachment: RelayAttachment {
    struct Size: Equatable { let cols: Int; let rows: Int }
    let sessionId = "preset-test"
    var onData: ((ArraySlice<UInt8>) -> Void)?
    var onHostResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var claims: [Size] = []

    func connect() {}
    func disconnect() {}
    func send(_ bytes: ArraySlice<UInt8>) {}
    func claimSize(cols: Int, rows: Int) { claims.append(Size(cols: cols, rows: rows)) }
}

/// A bare Ghostty surface in a window, the way `AppearanceTests` builds one, with
/// its last reported viewport to hand.
@MainActor
private final class GhosttyRig {
    final class Viewports: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [InMemoryTerminalViewport] = []
        func add(_ v: InMemoryTerminalViewport) { lock.withLock { seen.append(v) } }
        var count: Int { lock.withLock { seen.count } }
        var last: InMemoryTerminalViewport? { lock.withLock { seen.last } }
    }

    /// The surface's own metrics, which — unlike the in-memory viewport — carry
    /// the cell size in pixels. The view holds its delegate weakly, so this rig
    /// holds it.
    final class GridRecorder: TerminalSurfaceGridResizeDelegate {
        var seen: [TerminalGridMetrics] = []
        func terminalDidResize(_ size: TerminalGridMetrics) { seen.append(size) }
    }

    let viewports = Viewports()
    private let recorder = GridRecorder()
    let session: InMemoryTerminalSession
    let terminal: ClickableTerminalView
    let window: NSWindow
    var backing: CGFloat { window.backingScaleFactor }
    var grid: [TerminalGridMetrics] { recorder.seen }

    init(width: CGFloat) async throws {
        let viewports = self.viewports
        session = InMemoryTerminalSession(
            write: { _ in }, resize: { viewports.add($0) }, suppressesPixelOnlyResizes: false)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        terminal = ClickableTerminalView(frame: NSRect(x: 0, y: 0, width: width, height: 500))
        // Not the shared controller — see `TerminalControllerPool.makeController`.
        terminal.controller = TerminalControllerPool.makeController(for: Config())
        terminal.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminal.delegate = recorder
        window.contentView?.addSubview(terminal)
        terminal.layoutSubtreeIfNeeded()
        _ = try await settled()
    }

    /// The pane's own zoom, the pane's own way: reset, then one relative step.
    func setZoom(_ zoom: Double) {
        let size = Config().fontSize
        terminal.performBindingAction("reset_font_size")
        let delta = size * (zoom - 1)
        guard abs(delta) > 0.01 else { return }
        terminal.performBindingAction(delta > 0 ? "increase_font_size:\(delta)" : "decrease_font_size:\(-delta)")
    }

    func setWidth(_ width: CGFloat) {
        terminal.setFrameSize(NSSize(width: width, height: 500))
    }

    /// The viewport once reports have stopped arriving.
    func settled() async throws -> InMemoryTerminalViewport {
        var quiet = 0
        var last = viewports.count
        for _ in 0..<240 where quiet < 12 {
            terminal.fitToSize()
            try await Task.sleep(nanoseconds: 25_000_000)
            let now = viewports.count
            quiet = (now == last && now > 0) ? quiet + 1 : 0
            last = now
        }
        return try #require(viewports.last, "the surface never reported a grid")
    }

    func close() { window.close() }
}
