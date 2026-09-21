import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

private func pane(_ id: String, lane: String, kind: PaneKind = .web, muted: Bool = false, volume: UInt32 = 100) -> Pane {
    Pane(id: id, laneId: lane, position: 0, kind: kind, relaySessionId: kind == .pty ? "s-" + id : nil,
         relayServer: nil, url: kind == .web ? "https://example.com/" + id : nil, scrollY: nil,
         dataStoreId: nil, snapshotPath: nil, state: .live, heightWeight: 1, zoom: 1, mobile: false,
         muted: muted, volume: volume)
}

private func lane(_ id: String, _ panes: [Pane], title: String? = nil, project: String? = nil, focus: Int64 = 0) -> Lane {
    Lane(id: id, ordinal: 1, widthPt: 420, title: title ?? id, projectRoot: project, projectSource: .cwd,
         createdAt: 0, lastFocusAt: focus, keepLive: false, dock: nil, span: 1, panes: panes)
}

/// Which pane is making sound, and what every surface says about it
/// (ADR-0035): the models, with no WebKit. `WebPaneAudioTests` is the half
/// that needs a page.
@Suite("pane audio: the models")
@MainActor
struct PaneAudioModelTests {
    /// A centre over fixed lanes, with what it wrote through.
    private func centre(_ lanes: [Lane]) -> (PaneAudioCenter, () -> [String]) {
        let centre = PaneAudioCenter()
        var written: [String] = []
        centre.lookup = { id in lanes.flatMap(\.panes).first { $0.id == id } }
        centre.persist = { id, muted, volume in written.append("\(id):\(muted):\(volume)") }
        return (centre, { written })
    }

    @Test("audible is playing and not muted; muted shows whether or not anything plays; audible wins a lane that has both")
    func marks() {
        let mixed = lane("L", [pane("a", lane: "L"), pane("b", lane: "L"), pane("t", lane: "L", kind: .pty)])
        let (audio, _) = centre([mixed])
        #expect(audio.mark(of: mixed) == .silent)
        audio.report("a", playing: true)
        #expect(audio.mark(of: mixed) == .audible, "one audible pane of two is an audible lane")
        #expect(audio.mark(of: "b") == .silent)
        audio.setMuted(true, pane: "a")
        // `_isPlayingAudio` stays true under the pane's mute (ADR-0034), so
        // "audible" cannot be "playing".
        #expect(audio.state(of: "a").playing && !audio.state(of: "a").isAudible)
        #expect(audio.mark(of: mixed) == .muted)
        audio.report("b", playing: true)
        #expect(audio.mark(of: mixed) == .audible, "the pane making noise is the one a click has to reach")
        #expect(audio.audiblePanes(in: [mixed]) == ["b"])
        #expect(audio.volumePane(of: mixed) == "b")
        #expect(AudioMark.audible.icon == .volume2 && AudioMark.muted.icon == .volumeX && AudioMark.silent.icon == nil)
    }

    @Test("a click on a lane's speaker mutes what is audible, then unmutes what is muted; on a quiet lane it mutes its pages")
    func toggle() {
        let l = lane("L", [pane("a", lane: "L"), pane("b", lane: "L"), pane("t", lane: "L", kind: .pty)])
        let (audio, written) = centre([l])
        audio.report("a", playing: true)
        audio.toggleMute(lane: l)
        #expect(audio.state(of: "a").muted && !audio.state(of: "b").muted, "only the one making sound")
        audio.toggleMute(lane: l)
        #expect(!audio.state(of: "a").muted)
        audio.report("a", playing: false)
        audio.hold = 0
        #expect(written() == ["a:true:100", "a:false:100"])
        let quiet = lane("Q", [pane("q", lane: "Q")])
        let (other, _) = centre([quiet])
        other.toggleMute(lane: quiet)
        #expect(other.mark(of: quiet) == .muted)
    }

    @Test("the indicator outlives the sound by the hold, and sound inside the hold cancels the clearing")
    func hold() async {
        let l = lane("L", [pane("a", lane: "L")])
        let (audio, _) = centre([l])
        audio.hold = 0.15
        audio.report("a", playing: true)
        audio.report("a", playing: false)
        #expect(audio.mark(of: l) == .audible, "a blip does not flicker")
        audio.report("a", playing: true)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(audio.mark(of: l) == .audible, "playing again cancelled it")
        audio.report("a", playing: false)
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(audio.mark(of: l) == .silent)
        #expect(PaneAudioCenter().hold == 2, "two seconds, in the app")
    }

    @Test("volume: zero is mute and keeps the level to come back to; any other level unmutes; the ledger's copy seeds it")
    func volume() {
        let l = lane("L", [pane("a", lane: "L", muted: true, volume: 40)])
        let (audio, written) = centre([l])
        #expect(audio.state(of: "a") == PaneAudio(playing: false, muted: true, volume: 40), "muted yesterday, muted at launch")
        #expect(audio.state(of: "a").effectiveVolume == 0)
        audio.setVolume(70, pane: "a")
        #expect(audio.state(of: "a") == PaneAudio(playing: false, muted: false, volume: 70))
        audio.setVolume(0, pane: "a")
        #expect(audio.state(of: "a") == PaneAudio(playing: false, muted: true, volume: 70))
        audio.setMuted(false, pane: "a")
        #expect(audio.state(of: "a").effectiveVolume == 70)
        audio.setVolume(1, pane: "a")
        audio.setVolume(0, pane: "a", restoring: 70)
        #expect(audio.state(of: "a").volume == 70, "not the 1 % the drag passed on the way down")
        audio.setVolume(250, pane: "a")
        #expect(audio.state(of: "a").volume == 100)
        #expect(written().last == "a:false:100")
        #expect(!written().contains { $0.hasSuffix(":0") }, "the ledger never holds a zero: \(written())")
    }

    @Test("the pane's controller hears a mute or a level, not a change in what is playing; a closed pane is forgotten")
    func sinksAndPruning() {
        let l = lane("L", [pane("a", lane: "L")])
        let (audio, _) = centre([l])
        var heard: [PaneAudio] = []
        audio.attach("a") { heard.append($0) }
        #expect(heard == [PaneAudio()], "told at once, so a web view is muted as it is built")
        audio.report("a", playing: true)
        #expect(heard.count == 1)
        audio.setVolume(30, pane: "a")
        #expect(heard.last == PaneAudio(playing: true, muted: false, volume: 30))
        audio.detach("a")
        #expect(!audio.state(of: "a").playing, "nothing is left to say it stopped")
        audio.prune(keeping: [])
        audio.lookup = { _ in nil }
        #expect(audio.state(of: "a") == PaneAudio())
    }

    @Test("Mute All and Mute Other Panes silence what is audible and leave quiet pages unmarked")
    func muteAudible() {
        let lanes = [lane("A", [pane("a", lane: "A")]), lane("B", [pane("b", lane: "B")]), lane("C", [pane("c", lane: "C")])]
        let (audio, _) = centre(lanes)
        audio.report("a", playing: true)
        audio.report("b", playing: true)
        #expect(audio.muteAudible(in: lanes, except: "a") == 1)
        #expect(audio.state(of: "b").muted && !audio.state(of: "a").muted && !audio.state(of: "c").muted)
        #expect(audio.muteAudible(in: lanes) == 1)
        #expect(audio.audiblePanes(in: lanes).isEmpty)
    }

    @Test("the lane header's model carries the mark, and a change of mark is a change of model")
    func header() {
        let l = lane("L", [pane("a", lane: "L")])
        var model = LaneHeaderModel(lane: l, telemetry: nil)
        #expect(model.audio == .silent)
        let quiet = model
        model.audio = .audible
        #expect(model != quiet)
    }

    @Test("sidebar: a web row carries its lane's mark; a session's row never does; a folded header lists what it hides that is audible")
    func sidebarRows() {
        let home = NSHomeDirectory()
        let web = lane("W", [pane("w", lane: "W")], project: home + "/code/site")
        let hiddenWeb = lane("H", [pane("h", lane: "H")], project: home + "/life")
        let term = lane("T", [pane("t", lane: "T", kind: .pty), pane("tw", lane: "T")], project: home + "/code/site")
        let telemetry: [SessionKey: SessionTelemetry] = [
            "s-t": SessionTelemetry(sessionId: "s-t", title: "shell", cwd: home + "/code/site", command: "zsh",
                                    state: .idle, bytesPerSecond: 0, lastActivity: Date(), isRunning: true),
        ]
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let rows = SidebarModel.rows(
            lanes: [web, hiddenWeb, term], telemetry: telemetry, controls: controls,
            hiddenLanes: ["H"], audio: ["W": .muted, "H": .audible, "T": .audible])
        let entries = rows.compactMap { row -> SidebarModel.Entry? in if case .entry(let e) = row { return e } else { return nil } }
        #expect(entries.first { $0.laneId == "W" }?.audio == .muted)
        #expect(entries.first { $0.laneId == "T" }?.audio == .silent, "its square is agent state, and stays")
        let groups = rows.compactMap { row -> SidebarModel.Group? in if case .group(let g) = row { return g } else { return nil } }
        #expect(groups.first { $0.path == "~/life" }?.audibleLanes == ["H"])
        #expect(groups.first { $0.path == "~/code/site" }?.audibleLanes == [], "an open group's rows say it themselves")

        let silent = SidebarModel.rows(
            lanes: [web, hiddenWeb, term], telemetry: telemetry, controls: controls, hiddenLanes: ["H"])
        #expect(SidebarModel.statusChanged(from: silent, to: rows), "the swap fades")
        #expect(!SidebarModel.statusChanged(from: rows, to: rows))
    }

    @Test("status bar: the speaker and a count while panes are audible, nothing at all when none are")
    func statusBar() {
        let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: 900, height: StatusBar.height))
        #expect(bar.soundText == "")
        bar.setAudible(2)
        #expect(bar.soundText == "2")
        bar.setAudible(0)
        #expect(bar.soundText == "")
    }

    @Test("⌘P: `audio` or `sound` lists the lanes with a speaker, audible first; the row carries the glyph")
    func palette() {
        #expect(SearchPaletteController.asksForSound(" Audio "))
        #expect(SearchPaletteController.asksForSound("sound"))
        #expect(!SearchPaletteController.asksForSound("sounds"))
        let lanes = [
            lane("quiet", [pane("q", lane: "quiet")], focus: 9),
            lane("muted", [pane("m", lane: "muted")], focus: 8),
            lane("old", [pane("o", lane: "old")], focus: 1),
            lane("new", [pane("n", lane: "new")], focus: 5),
        ]
        let marks: [String: AudioMark] = ["muted": .muted, "old": .audible, "new": .audible]
        let hits = SearchPaletteController.soundHits(lanes: lanes, focusedPaneId: nil) { marks[$0.id] ?? .silent }
        #expect(hits.map(\.laneId) == ["new", "old", "muted"])
        let row = PaletteSearchRow(
            hit: hits[0], laneTitle: "new", path: "", telemetry: nil, isFocused: false, audio: .audible)
        #expect(row.audio == .audible)
    }

    @Test("the socket's ops parse, a LANE is what `maxpane ls` prints, and `ls` marks audible, muted and a level other than 100")
    func socket() {
        guard case .mute(let lane, let muted)? = OpenServer.parse(#"{"op":"mute","lane":"3"}"#) else {
            Issue.record("mute did not parse")
            return
        }
        #expect(lane == "3" && muted)
        guard case .mute("all", false)? = OpenServer.parse(#"{"op":"unmute"}"#) else {
            Issue.record("unmute with no lane is all")
            return
        }
        guard case .volume("left", 40)? = OpenServer.parse(#"{"op":"volume","lane":"left","percent":40}"#) else {
            Issue.record("volume did not parse")
            return
        }
        #expect(OpenServer.parse(#"{"op":"volume","lane":"1","percent":101}"#) == nil)
        #expect(OpenServer.parse(#"{"op":"volume","percent":40}"#) == nil)

        var docked = MaxPaneKitTests_lane("D", [pane("d", lane: "D")])
        docked.dock = Dock(side: .left, mode: .inset, widthPt: 300)
        let strip = [MaxPaneKitTests_lane("A", [pane("a", lane: "A")]), docked, MaxPaneKitTests_lane("B", [pane("b", lane: "B")])]
        #expect(StripWindowController.lanes(named: "1", in: strip)?.map(\.id) == ["B"], "a dock has no number, as in ls")
        #expect(StripWindowController.lanes(named: "left", in: strip)?.map(\.id) == ["D"])
        #expect(StripWindowController.lanes(named: "right", in: strip) == nil)
        #expect(StripWindowController.lanes(named: "all", in: strip)?.count == 3)
        #expect(StripWindowController.lanes(named: "7", in: strip) == nil)

        #expect(StripWindowController.lsSound(PaneAudio()) == "")
        #expect(StripWindowController.lsSound(PaneAudio(playing: true, muted: false, volume: 100)) == "[audible]")
        #expect(StripWindowController.lsSound(PaneAudio(playing: true, muted: true, volume: 40)) == "[muted 40%]")
        #expect(StripWindowController.lsSound(PaneAudio(playing: false, muted: false, volume: 40)) == "[40%]")
    }

    @Test("Mute Pane is ⌃⌘M, in the View menu, with its other name; Mute Others and Mute All have no key")
    func commands() {
        #expect(Command.toggleMute.chords.first?.key == "m")
        #expect(Command.toggleMute.chords.first?.modifiers == [.command, .control])
        #expect(Command.toggleMute.activeTitle == "Unmute Pane")
        #expect(Command.muteOthers.chords.isEmpty && Command.muteAll.chords.isEmpty)
        #expect([Command.toggleMute, .muteOthers, .muteAll].allSatisfy { $0.menu == .view })
        // Nothing else holds the chord, and it is not the system's ⌘M or ⌥⌘M.
        let holders = Command.allCases.filter { $0.chords.contains { $0.key == "m" } }
        #expect(holders == [.toggleMute])
    }
}

private func MaxPaneKitTests_lane(_ id: String, _ panes: [Pane]) -> Lane { lane(id, panes) }

/// The sidebar row's leading mark, as the owner specified it: the square
/// becomes the speaker; a click mutes and selects nothing; a right-click on it
/// is the slider, and a right-click anywhere else is the row's own menu.
@Suite("the sidebar's speaker", .serialized)
@MainActor
struct SidebarSpeakerTests {
    final class Fixture {
        let dir: URL
        let store: StripStore
        let sidebar: SidebarViewController
        let window: NSWindow
        var selected: [String] = []

        @MainActor
        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-speaker-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            try store.newWebLane(url: "https://example.com/one", near: nil)
            try store.newWebLane(url: "https://example.com/two", near: nil)
            sidebar = SidebarViewController(store: store)
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 280, height: 500),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
            sidebar.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
            window.contentView?.addSubview(sidebar.view)
            sidebar.onSelect = { [weak self] laneId, _ in self?.selected.append(laneId) }
            layout()
        }

        @MainActor
        func layout() {
            window.contentView?.layoutSubtreeIfNeeded()
            table.layoutSubtreeIfNeeded()
        }

        @MainActor
        var table: NSTableView {
            func find(_ view: NSView) -> NSTableView? {
                if let table = view as? NSTableView { return table }
                for sub in view.subviews { if let hit = find(sub) { return hit } }
                return nil
            }
            return find(sidebar.view)!
        }

        /// The row view for a lane, built if the table had not got to it.
        @MainActor
        func row(_ laneId: String) -> (index: Int, view: SidebarEntryView)? {
            layout()
            guard let index = sidebar.row(ofLane: laneId),
                  let view = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? SidebarEntryView
            else { return nil }
            layout()
            return (index, view)
        }

        @MainActor
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown || type == .rightMouseDown ? 1 : 0)!
        }

        @MainActor
        func tearDown() {
            VolumePopup.current?.closePopup(animated: false)
            window.orderOut(nil)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("square when silent, volume-2 when audible, volume-x while muted whether or not it is playing; the grid does not move")
    func theMark() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let lane = try #require(f.store.state.lanes.first)
        let paneId = try #require(lane.panes.first?.id)
        var row = try #require(f.row(lane.id)).view
        #expect(row.showsStatusSquare && row.speaker.mark == .silent)
        let globeX = row.subviews.compactMap { $0 as? NSImageView }.first?.frame.minX

        f.store.audio.report(paneId, playing: true)
        row = try #require(f.row(lane.id)).view
        #expect(!row.showsStatusSquare && row.speaker.mark == .audible)
        #expect(row.speaker.frame.width >= 18 && row.speaker.frame.height >= 18, "a target a pointer can find")
        #expect(row.subviews.compactMap { $0 as? NSImageView }.first?.frame.minX == globeX, "same slot, same grid")
        #expect(row.speaker.toolTip == "Mute")
        // Grey at rest, and not a state colour.
        #expect(row.speaker.ink == SidebarInk.gone)

        f.store.audio.setMuted(true, pane: paneId)
        row = try #require(f.row(lane.id)).view
        #expect(row.speaker.mark == .muted && row.speaker.toolTip == "Unmute")
        f.store.audio.hold = 0
        f.store.audio.detach(paneId)
        row = try #require(f.row(lane.id)).view
        #expect(row.speaker.mark == .muted, "muted and silent still shows: a lane you would forget you muted")

        f.store.audio.setMuted(false, pane: paneId)
        row = try #require(f.row(lane.id)).view
        #expect(row.showsStatusSquare && row.speaker.mark == .silent)
        // The other row never changed.
        let other = try #require(f.store.state.lanes.last)
        #expect(try #require(f.row(other.id)).view.showsStatusSquare)
    }

    @Test("a click on the mark toggles mute and does not select or reveal the row; a click beside it still does")
    func click() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        // The lane that does NOT have the keyboard, so a selection would show.
        let focused = f.store.state.focusedPaneId
        let lane = try #require(f.store.state.lanes.first { !$0.panes.contains { $0.id == focused } })
        let paneId = try #require(lane.panes.first?.id)
        f.store.audio.report(paneId, playing: true)
        let (index, row) = try #require(f.row(lane.id))
        let selectedBefore = f.table.selectedRow
        #expect(selectedBefore != index)

        let point = row.speaker.convert(NSPoint(x: row.speaker.bounds.midX, y: row.speaker.bounds.midY), to: nil)
        // What the window would send the press to: the mark itself, not the
        // table, which is what would select the row and run its action.
        let hit = try #require(f.window.contentView?.hitTest(point))
        #expect(hit === row.speaker, "the press lands on \(type(of: hit))")
        hit.mouseDown(with: f.event(.leftMouseDown, at: point))
        hit.mouseUp(with: f.event(.leftMouseUp, at: point))
        #expect(f.store.audio.state(of: paneId).muted)
        #expect(f.selected.isEmpty, "nothing was selected or revealed")
        #expect(f.table.selectedRow == selectedBefore)
        #expect(f.store.state.focusedPaneId == focused)

        // Again: unmutes. The row was rebuilt, so ask for it again.
        let again = try #require(f.row(lane.id)).view
        #expect(again.speaker.mark == .muted)
        again.speaker.mouseDown(with: f.event(.leftMouseDown, at: point))
        again.speaker.mouseUp(with: f.event(.leftMouseUp, at: point))
        #expect(!f.store.audio.state(of: paneId).muted)

        // A silent row's slot is not a button: the press goes to the row.
        let quiet = try #require(f.store.state.lanes.first { $0.id != lane.id })
        let quietRow = try #require(f.row(quiet.id)).view
        let quietPoint = quietRow.speaker.convert(
            NSPoint(x: quietRow.speaker.bounds.midX, y: quietRow.speaker.bounds.midY), to: nil)
        #expect(f.window.contentView?.hitTest(quietPoint) !== quietRow.speaker)
    }

    @Test("a right-click on the mark opens the slider, not the row's menu; a right-click elsewhere is the row's menu, with Mute and Volume… in it")
    func rightClick() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let lane = try #require(f.store.state.lanes.first)
        let paneId = try #require(lane.panes.first?.id)
        f.store.audio.report(paneId, playing: true)
        let (index, row) = try #require(f.row(lane.id))

        let onMark = row.speaker.convert(NSPoint(x: row.speaker.bounds.midX, y: row.speaker.bounds.midY), to: nil)
        let hit = try #require(f.window.contentView?.hitTest(onMark))
        #expect(hit === row.speaker)
        #expect(VolumePopup.current == nil)
        hit.rightMouseDown(with: f.event(.rightMouseDown, at: onMark))
        let popup = try #require(VolumePopup.current)
        #expect(popup.paneId == paneId && popup.isOpen)
        #expect(popup.readoutText == "100%")
        // Hung from the mark, not centred in the window.
        let anchor = f.window.convertToScreen(row.speaker.convert(row.speaker.bounds, to: nil))
        let frame = try #require(popup.window?.frame)
        #expect(abs(frame.minX - anchor.minX) <= 8 || frame.maxX <= (f.window.screen?.visibleFrame.maxX ?? .infinity))

        // Live while dragging: every step is applied and written at once.
        popup.slider.onChange?(35)
        #expect(f.store.audio.state(of: paneId).volume == 35)
        #expect(popup.readoutText == "35%")
        popup.slider.onChange?(0)
        #expect(f.store.audio.state(of: paneId).muted && popup.readoutText == "0%")
        popup.mute.onClick?()
        #expect(f.store.audio.state(of: paneId) == PaneAudio(playing: true, muted: false, volume: 35))
        #expect(popup.slider.value == 35)
        popup.closePopup(animated: false)

        // Elsewhere on the row: the table's own menu, for that row.
        let elsewhere = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        #expect(f.window.contentView?.hitTest(elsewhere) !== row.speaker)
        // The press goes up the responder chain to the table, whose menu is
        // the sidebar's, built for the row that was clicked.
        let menu = try #require(f.table.menu)
        #expect(menu.delegate === f.sidebar)
        f.sidebar.populate(menu, forRow: index)
        let titles = menu.items.map(\.title)
        #expect(titles.contains("Reveal on Strip") && titles.contains("Close Lane"), "the row's menu, unchanged: \(titles)")
        #expect(titles.contains("Mute") && titles.contains("Volume…"))
    }

    @Test("the slider: a square knob that follows the pointer and the arrow keys, 0 to 100")
    func slider() {
        let slider = VolumeSlider(frame: NSRect(x: 0, y: 0, width: 206, height: 22))
        var heard: [Int] = []
        slider.onChange = { heard.append($0) }
        #expect(slider.value(at: NSPoint(x: 3, y: 11)) == 0)
        #expect(slider.value(at: NSPoint(x: 203, y: 11)) == 100)
        #expect(slider.value(at: NSPoint(x: 103, y: 11)) == 50)
        slider.value = 50
        #expect(abs(slider.knobRect.midX - 103) <= 1)
        #expect(slider.knobRect.width == VolumeSlider.knob.width, "a square-cornered knob, not a circle")
        slider.value = 400
        #expect(slider.value == 100)
        #expect(heard.isEmpty, "setting it from outside is not the person moving it")
    }
}

/// The same speaker on a lane's header, which is also a gallery tile's.
@Suite("the lane header's speaker", .serialized)
@MainActor
struct LaneHeaderSpeakerTests {
    private func host(_ laneView: LaneView, width: CGFloat = 520) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: width, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        laneView.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        window.contentView?.addSubview(laneView)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func press(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test("beside the title while the lane is audible or muted, and the title has the room back when it is neither")
    func appearsAndLeaves() {
        let laneView = LaneView(lane: lane("L", [pane("p", lane: "L")], title: "Lo-fi beats"), widthBounds: 420...900)
        let window = host(laneView)
        defer { window.orderOut(nil) }
        #expect(laneView.speaker.mark == .silent && laneView.speaker.frame.width == 0)
        laneView.setAudio(.audible)
        window.contentView?.layoutSubtreeIfNeeded()
        laneView.speaker.superview?.layout()
        #expect(laneView.speaker.mark == .audible)
        #expect(laneView.speaker.frame.width >= SpeakerMark.minimumHit)
        laneView.setAudio(.muted)
        #expect(laneView.speaker.mark == .muted)
        laneView.setAudio(.silent)
        laneView.speaker.superview?.layout()
        #expect(laneView.speaker.frame.width == 0)
    }

    @Test("a click mutes and is not a drag or a double click on the header; a right-click is the slider's, not the header's menu")
    func clicks() throws {
        let laneView = LaneView(lane: lane("L", [pane("p", lane: "L")], title: "Lo-fi beats"), widthBounds: 420...900)
        let window = host(laneView)
        defer { window.orderOut(nil) }
        var toggled = 0, volume = 0, grabbed = 0
        laneView.onToggleMute = { toggled += 1 }
        laneView.onVolume = { _ in volume += 1 }
        laneView.onLaneGrab = { _, _ in grabbed += 1 }
        laneView.setAudio(.audible)
        laneView.speaker.superview?.layout()
        let speaker = laneView.speaker
        let point = speaker.convert(NSPoint(x: speaker.bounds.midX, y: speaker.bounds.midY), to: nil)
        let hit = try #require(window.contentView?.hitTest(point))
        #expect(hit === speaker)
        hit.mouseDown(with: press(.leftMouseDown, at: point, in: window))
        hit.mouseUp(with: press(.leftMouseUp, at: point, in: window))
        hit.rightMouseDown(with: press(.rightMouseDown, at: point, in: window))
        #expect(toggled == 1 && volume == 1 && grabbed == 0)
    }

    @Test("on a gallery tile the speaker is still the thing under the pointer, drawn larger in lane points")
    func galleryTile() throws {
        let gallery = GalleryView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 1200, height: 800),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = gallery
        defer { window.orderOut(nil) }
        let laneView = LaneView(lane: lane("L", [pane("p", lane: "L")], title: "Lo-fi beats"), widthBounds: 420...900)
        gallery.place(laneView, laneId: "L", frame: NSRect(x: 100, y: 100, width: 262, height: 360),
                      laneSize: CGSize(width: 656, height: 900))
        laneView.thumbnailScale = 0.4
        laneView.setAudio(.audible)
        gallery.layoutSubtreeIfNeeded()
        laneView.speaker.superview?.layout()
        let speaker = laneView.speaker
        #expect(speaker.points > 12, "about its strip size on screen, not 5 pt")
        let point = speaker.convert(NSPoint(x: speaker.bounds.midX, y: speaker.bounds.midY), to: nil)
        #expect(window.contentView?.hitTest(point) === speaker)
    }

    @Test("the ⋯ menu has Mute Pane with its key, Mute Other Panes and Mute All; Mute Pane is grey on a terminal lane")
    func menu() throws {
        let web = LaneView(lane: lane("L", [pane("p", lane: "L")]), widthBounds: 420...900)
        web.mobileLayout = { false }
        web.onToggleMute = {}
        web.onMuteOthers = {}
        web.onMuteAll = {}
        let items = web.overflowMenu.items
        let mute = try #require(items.first { $0.title == "Mute Pane" })
        #expect(mute.isEnabled && mute.keyEquivalent == "m" && mute.keyEquivalentModifierMask == [.command, .control])
        #expect(items.contains { $0.title == "Mute Other Panes" && $0.isEnabled })
        #expect(items.contains { $0.title == "Mute All" && $0.isEnabled })
        web.setAudio(.muted)
        #expect(web.overflowMenu.items.contains { $0.title == "Unmute Pane" })

        let terminal = LaneView(lane: lane("T", [pane("t", lane: "T", kind: .pty)]), widthBounds: 420...900)
        terminal.mobileLayout = { nil }
        terminal.onToggleMute = {}
        terminal.onMuteAll = {}
        let greyed = try #require(terminal.overflowMenu.items.first { $0.title == "Mute Pane" })
        #expect(!greyed.isEnabled, "a terminal has no page to silence")
        #expect(terminal.overflowMenu.items.contains { $0.title == "Mute All" && $0.isEnabled })
    }
}

/// The speaker in each state, on each surface, light and dark. Look at them.
@Suite("pane audio rendering")
@MainActor
struct PaneAudioRenderTests {
    @Test("renders sidebar rows silent, audible and muted, a folded header with sound under it, and the status bar's count")
    func sidebarSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED pane audio sidebar sheet: set MAXPANE_SHOTS")
            return
        }
        let home = NSHomeDirectory()
        let lanes = [
            lane("silent", [pane("a", lane: "silent")], title: "Hacker News", project: home + "/code/site"),
            lane("audible", [pane("b", lane: "audible")], title: "Lo-fi beats to refactor to", project: home + "/code/site"),
            lane("muted", [pane("c", lane: "muted")], title: "Standup recording", project: home + "/code/site"),
            lane("hidden", [pane("d", lane: "hidden")], title: "Podcast", project: home + "/life"),
        ]
        var controls = SidebarModel.Controls()
        controls.collapsed = ["~/life"]
        let rows = SidebarModel.rows(
            lanes: lanes, telemetry: [:], controls: controls, hiddenLanes: ["hidden"],
            audio: ["audible": .audible, "muted": .muted, "hidden": .audible])
        let width: CGFloat = 280
        try AppearanceSheet.render(to: dir, named: "audio-sidebar") {
            let heights = rows.map { row -> CGFloat in
                if case .group = row { return SidebarGroupView.height }
                return SidebarEntryView.height
            }
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width + 300, height: heights.reduce(0, +) + 8 + StatusBar.height))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            var y = sheet.bounds.height - 4
            for (row, height) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .group(let g): view = SidebarGroupView(group: g)
                case .entry(let e): view = SidebarEntryView(entry: e)
                case .bookmark: continue
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: width + 300, height: StatusBar.height))
            bar.update(
                state: StripState(lanes: lanes, scrollX: 0, focusedPaneId: nil, gatherFilter: nil,
                                  hiddenLaneIds: ["hidden"], revision: 1),
                telemetry: [:], webBytes: 0)
            bar.setAudible(2)
            sheet.addSubview(bar)
            bar.layoutSubtreeIfNeeded()
            return sheet
        }
    }

    @Test("renders the lane header silent, audible and muted, at two widths and as a gallery tile's header")
    func headerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED pane audio header sheet: set MAXPANE_SHOTS")
            return
        }
        try AppearanceSheet.render(to: dir, named: "audio-header") {
            let cases: [(AudioMark, CGFloat, CGFloat?)] = [
                (.silent, 520, nil), (.audible, 520, nil), (.muted, 520, nil),
                (.audible, 300, nil), (.muted, 300, nil), (.audible, 520, 0.45),
            ]
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: CGFloat(cases.count) * 36 + 8))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.stripBackground
            var y = sheet.bounds.height - 4
            for (mark, width, scale) in cases {
                let header = LaneHeaderView()
                header.apply(lane("L", [pane("p", lane: "L")], title: "Lo-fi beats to refactor to", project: NSHomeDirectory() + "/code/site"))
                header.thumbnailScale = scale
                header.audio = mark
                y -= 36
                header.frame = NSRect(x: 8, y: y + 4, width: width, height: 28)
                sheet.addSubview(header)
                header.layout()
            }
            return sheet
        }
    }

    @Test("renders the volume popup: at a level, and muted")
    func popupSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED pane audio popup sheet: set MAXPANE_SHOTS")
            return
        }
        for (name, muted) in [("level", false), ("muted", true)] {
            let l = lane("L", [pane("p", lane: "L", muted: muted, volume: 65)])
            let centre = PaneAudioCenter()
            centre.lookup = { id in l.panes.first { $0.id == id } }
            let popup = VolumePopup(paneId: "p", title: "Lo-fi beats to refactor to", center: centre)
            let content = try #require(popup.window?.contentView)
            try AppearanceSheet.render(to: dir, named: "audio-volume-\(name)") { content }
        }
    }
}
