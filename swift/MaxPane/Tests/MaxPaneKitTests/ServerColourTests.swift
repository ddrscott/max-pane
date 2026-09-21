import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

// A server has a colour (ADR-0025): the palette, the `color` key, how a
// colour is assigned and applied live, what each surface shows, the sidebar
// header's menu, the socket op, and the sheets to look at.
//
// `ServerColours` is one map for the process, so every test here that
// configures a server gives it a name no other test uses.

// MARK: - colour arithmetic

private enum Lab {
    static func srgb(_ color: NSColor, _ mode: NSAppearance.Name) -> (Double, Double, Double) {
        let cg = color.cgColor(in: NSAppearance(named: mode)!)
        let c = NSColor(cgColor: cg)!.usingColorSpace(.sRGB)!
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    static func lab(_ color: NSColor, _ mode: NSAppearance.Name) -> (Double, Double, Double) {
        let (r, g, b) = srgb(color, mode)
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047
        let y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
        let z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? pow(t, 1.0 / 3.0) : 7.787 * t + 16.0 / 116.0 }
        return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// ΔE*ab, CIE76: plain distance in L*a*b*. About 2 is just noticeable;
    /// 25 is "another colour", 40 is "nobody would call these the same".
    static func distance(_ a: NSColor, _ b: NSColor, _ mode: NSAppearance.Name) -> Double {
        let (p, q) = (lab(a, mode), lab(b, mode))
        return sqrt(pow(p.0 - q.0, 2) + pow(p.1 - q.1, 2) + pow(p.2 - q.2, 2))
    }

    static func contrast(_ a: NSColor, _ b: NSColor, _ mode: NSAppearance.Name) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let (r, g, b) = srgb(c, mode)
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

private let modes: [NSAppearance.Name] = [.aqua, .darkAqua]

// MARK: - the palette

@Suite("the server colours")
@MainActor
struct ServerColourPaletteTests {
    /// Every colour that means a state: the greens, and DONE's orange.
    private let states: [(String, NSColor)] = [
        ("accent", Theme.accent), ("working", Theme.working), ("blocked", Theme.blocked),
        ("alive", Theme.alive), ("done", Theme.done),
    ]
    private var hues: [ServerColour] { ServerColour.allCases.filter { $0 != .slate } }

    @Test("eight, slate first and the default; every name is what the file takes")
    func eight() {
        #expect(ServerColour.allCases.count == 8)
        #expect(ServerColour.allCases.first == .slate && ServerColour.fallback == .slate)
        #expect(ServerColour.allCases.map(\.rawValue)
            == ["slate", "cyan", "blue", "violet", "magenta", "rose", "lemon", "ink"])
        #expect(Set(Theme.serverPalette.keys) == Set(ServerColour.allCases.filter { $0 != .slate }))
        #expect(RelayServerEntry(name: "x", url: "https://x").colour == .slate)
        #expect(ServerColour.violet.title == "Violet")
    }

    @Test("none reads as a state: each is ΔE 40 or more from every green and from DONE, in both appearances")
    func notAState() {
        for mode in modes {
            for colour in hues {
                for (name, state) in states {
                    let d = Lab.distance(Theme.server(colour), state, mode)
                    #expect(d >= 40, "\(colour) is ΔE \(Int(d)) from \(name) in \(mode.rawValue)")
                }
            }
        }
    }

    @Test("amber and teal, which the work item suggested, would have failed that bar")
    func whyTwoWereReplaced() {
        func fixed(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        // Tailwind's 400s in dark and 700/800s in light, as the others are.
        #expect(Lab.distance(fixed(0x92400E), Theme.done, .aqua) < 25, "light amber is DONE's burnt orange")
        #expect(Lab.distance(fixed(0x0F766E), Theme.working, .aqua) < 25, "light teal is the working green")
        #expect(Lab.distance(fixed(0x2DD4BF), Theme.blocked, .darkAqua) < 40, "dark teal is near the blocked green")
    }

    @Test("slate is the at-rest grey: no hue at all, so it cannot be mistaken for one")
    func slateIsGrey() {
        #expect(Theme.server(.slate) == Theme.dimText)
        for mode in modes {
            let (r, g, b) = Lab.srgb(Theme.server(.slate), mode)
            #expect(max(r, g, b) - min(r, g, b) < 0.06, "slate has a hue in \(mode.rawValue)")
        }
    }

    @Test("the eight are told apart from each other: ΔE 25 or more between any two hues")
    func apart() {
        for mode in modes {
            for (i, a) in hues.enumerated() {
                for b in hues[(i + 1)...] {
                    let d = Lab.distance(Theme.server(a), Theme.server(b), mode)
                    #expect(d >= 25, "\(a) and \(b) are ΔE \(Int(d)) apart in \(mode.rawValue)")
                }
            }
        }
    }

    @Test("the chip's name is text in the colour: 4.5:1 on a lane and on the strip, in both appearances")
    func readable() {
        for mode in modes {
            for colour in hues {
                for (name, ground) in [("lane", Theme.laneBackground), ("strip", Theme.stripBackground)] {
                    let c = Lab.contrast(Theme.server(colour), ground, mode)
                    #expect(c >= 4.5, "\(colour) is \(c):1 on the \(name) in \(mode.rawValue)")
                }
            }
        }
    }

    @Test("a new server gets the first colour nobody has; slate is never handed out; all seven taken, the least used")
    func firstUnused() {
        #expect(ServerColour.firstUnused(by: []) == .cyan)
        #expect(ServerColour.firstUnused(by: [.slate]) == .cyan)
        #expect(ServerColour.firstUnused(by: [.cyan, .violet]) == .blue)
        let all = ServerColour.allCases.filter { $0 != .slate }
        #expect(ServerColour.firstUnused(by: all) == .cyan)
        #expect(ServerColour.firstUnused(by: all + [.cyan, .blue]) == .violet)
    }
}

// MARK: - the file, and live

@Suite("a server's colour in config.toml", .serialized)
@MainActor
struct ServerColourConfigTests {
    private struct Fixture {
        let dir: URL
        let path: URL
        let store: ConfigStore
        let registry: SessionRegistry
        let servers: RelayServers
        let book: RelayServerBook
        var text: String { (try? String(contentsOf: path, encoding: .utf8)) ?? "" }
    }

    private func fixture(_ text: String) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-colour-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try text.write(to: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path, watches: false)
        let registry = SessionRegistry(sources: [])
        let servers = RelayServers(entries: store.config.enabledServers, token: { _ in nil })
        let book = RelayServerBook(servers: servers, registry: registry, store: store, pollInterval: 3600)
        book.reconcile()
        return Fixture(dir: dir, path: path, store: store, registry: registry, servers: servers, book: book)
    }

    private func tearDown(_ f: Fixture) {
        f.registry.stop()
        try? FileManager.default.removeItem(at: f.dir)
    }

    // Port 9 is discard: nothing listens, so the source the book starts is
    // refused at once and nothing leaves this machine.
    private func table(_ name: String, _ extra: String = "") -> String {
        "[[servers]]\nname = \"\(name)\"   # the box under the desk\nurl = \"http://127.0.0.1:9\"\n\(extra)"
    }

    @Test("color is read, written in place, and the comments around it stay where they were")
    func roundTrip() throws {
        let f = try fixture("# mine\ntheme = \"dark\"\n\n" + table("rt-a", "color = \"violet\"  # purple, for WSL\nenabled = true\n"))
        defer { tearDown(f) }
        #expect(f.store.config.servers.first?.color == .violet)
        #expect(f.store.problems.isEmpty)
        #expect(f.book.setColour("rt-a", .rose) == nil)
        #expect(f.store.config.servers.first?.color == .rose)
        #expect(f.text.contains("color = \"rose\"  # purple, for WSL"), "\(f.text)")
        #expect(f.text.contains("# mine") && f.text.contains("# the box under the desk"))
        #expect(f.text.contains("enabled = true"))
        #expect(f.text.components(separatedBy: "color =").count == 2, "one color line, not two")
        // Read back from nothing but the file.
        #expect(ConfigFile.load(from: f.path).config.servers.first?.color == .rose)
        #expect(f.book.setColour("nobody", .rose) == "no server named nobody")
    }

    @Test("a colour nobody defined is reported on its line and drawn in slate; the server is kept and the text left alone")
    func badValue() throws {
        let f = try fixture(table("bad-a", "color = \"chartreuse\"\n") + "\n" + table("bad-b", "color = 3\n"))
        defer { tearDown(f) }
        #expect(f.store.config.servers.map(\.name) == ["bad-a", "bad-b"])
        #expect(f.store.config.servers.map(\.colour) == [.slate, .slate])
        let problems = f.store.problems
        #expect(problems.count == 2)
        #expect(problems[0].key == "servers[0].color" && problems[0].line == 4)
        #expect(problems[0].reason.contains("chartreuse") && problems[0].reason.contains("violet")
            && problems[0].reason.contains("using slate"))
        #expect(problems[1].key == "servers[1].color" && problems[1].reason.contains("using slate"))
        // Not "missing", so not overwritten: what he typed is still there to fix.
        #expect(f.text.contains("chartreuse"))
        #expect(ServerColours.colour(of: "bad-a") == .slate)
    }

    @Test("a table written before colours existed gets the first unused one, written to the file once")
    func autoAssign() throws {
        let f = try fixture("# servers\n" + table("auto-a") + "\n" + table("auto-b", "color = \"cyan\"\n") + "\n" + table("auto-c"))
        defer { tearDown(f) }
        // cyan is taken by auto-b, so auto-a gets blue and auto-c violet.
        #expect(f.store.config.servers.map(\.color) == [.blue, .cyan, .violet])
        #expect(f.text.contains("# servers") && f.text.contains("# the box under the desk"))
        #expect(ServerColours.colour(of: "auto-a") == .blue && ServerColours.colour(of: "auto-c") == .violet)
        // Once: another reconcile, and another book over the same file, write nothing.
        let written = f.text
        f.book.reconcile()
        let again = RelayServerBook(
            servers: RelayServers(entries: [], token: { _ in nil }), registry: f.registry, store: f.store, pollInterval: 3600)
        again.reconcile()
        #expect(f.text == written)
        // A colour somebody chose is never reassigned, slate included.
        #expect(f.book.setColour("auto-a", .slate) == nil)
        f.book.reconcile()
        #expect(f.store.config.servers.first?.color == .slate)
    }

    @Test("a server added gets the first colour no other server is using")
    func added() throws {
        let f = try fixture(table("add-a", "color = \"cyan\"\n"))
        defer { tearDown(f) }
        let entry = try f.book.add(pasted: "http://127.0.0.1:9", name: "add-b").get()
        #expect(entry.color == .blue)
        #expect(f.store.config.servers.map(\.color) == [.cyan, .blue])
        #expect(f.text.contains("color = \"blue\""))
    }

    @Test("a change reaches every mark without a relaunch: from the book, and from a hand edit of the file")
    func live() throws {
        let f = try fixture(table("live-a", "color = \"cyan\"\n"))
        defer { tearDown(f) }
        var settingsRedraws = 0
        f.book.onChange = { settingsRedraws += 1 }
        var reattached: [String] = []
        f.book.onServerChanged = { reattached.append($0) }

        // What is on screen before the change.
        var t = SessionTelemetry(sessionId: "s1", server: "live-a", title: "bash", cwd: "/home/x", command: "bash",
                                 state: .idle, lastActivity: Date())
        t.connection = .connected
        let rows = SidebarModel.rows(lanes: [], telemetry: [t.key: t], servers: ["live-a": .connected])
        let group = try #require(rows.compactMap { if case .group(let g) = $0, g.isServer { return g } else { return nil } }.first)
        let entry = try #require(rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }.first)
        let row = SidebarEntryView(entry: entry)
        let header = LaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: 620, height: Theme.laneHeaderHeight)
        header.apply(ServerColourSurfaceTests.lane(server: "live-a"))
        header.telemetry = t
        header.layout()
        let omni = OmniPickerRow(
            candidate: try #require(OmniRanking.build(
                query: "", scope: .sessions, recents: [], pages: [], bookmarks: [], sessions: [t], destination: ""
            ).compactMap(\.candidate).first), query: "", shortcut: nil)
        #expect(SidebarGroupView(group: group).slashColour == .cyan)
        #expect(row.serverMarkColour == .cyan && header.serverChipColour == .cyan && omni.serverChipColour == .cyan)

        var posted = 0
        let token = NotificationCenter.default.addObserver(
            forName: ServerColours.didChange, object: nil, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // Through the book: the menu, the swatches and the CLI all end here.
        #expect(f.book.setColour("live-a", .magenta) == nil)
        #expect(posted == 1)
        #expect(row.serverMarkColour == .magenta, "the row's square, in place")
        #expect(header.serverChipColour == .magenta, "the lane header's chip, in place")
        #expect(omni.serverChipColour == .magenta, "an open ⌘O row, in place")
        #expect(SidebarGroupView(group: group).slashColour == .magenta, "the header's slashes, when its cell is made again")
        #expect(settingsRedraws == 1, "Settings redraws its swatches")
        #expect(reattached.isEmpty, "a colour is not an endpoint: no lane re-attaches")

        // By hand, as an editor's save arrives through the watch.
        try f.text.replacingOccurrences(of: "\"magenta\"", with: "\"lemon\"").write(to: f.path, atomically: true, encoding: .utf8)
        f.store.reloadFromDisk()
        #expect(row.serverMarkColour == .lemon && header.serverChipColour == .lemon && omni.serverChipColour == .lemon)
        #expect(reattached.isEmpty)

        // The same colour again is not a change.
        let before = posted
        #expect(f.book.setColour("live-a", .lemon) == nil)
        #expect(posted == before)
    }

    @Test("one set of servers going away does not take another's colours with it")
    func setsDoNotCollide() {
        let a = RelayServers(entries: [RelayServerEntry(name: "col-a", url: "http://127.0.0.1:9", color: .rose)], token: { _ in nil })
        let b = RelayServers(entries: [RelayServerEntry(name: "col-b", url: "http://127.0.0.1:9", color: .ink)], token: { _ in nil })
        b.reload(entries: [], tokenChanged: [])
        #expect(ServerColours.colour(of: "col-a") == .rose)
        #expect(ServerColours.colour(of: "col-b") == .slate, "a server nobody configures is grey")
        a.reload(entries: [], tokenChanged: [])
        #expect(ServerColours.colour(of: "col-a") == .slate)
    }
}

// MARK: - the surfaces

@Suite("where a server's colour shows", .serialized)
@MainActor
struct ServerColourSurfaceTests {
    static func lane(server: String?, title: String = "bash", root: String? = nil) -> Lane {
        Lane(id: "L", ordinal: 1, widthPt: 500, title: title,
             projectRoot: root ?? server.map { "\($0):/home/spierce" } ?? NSHomeDirectory() + "/code",
             projectSource: .cwd, createdAt: 0, lastFocusAt: 0, keepLive: false, dock: nil, span: 1, isPrivate: false,
             panes: [Pane(id: "P", laneId: "L", position: 0, kind: .pty, relaySessionId: "a1", relayServer: server,
                          url: nil, scrollY: nil, dataStoreId: nil, snapshotPath: nil, state: .live,
                          heightWeight: 1, zoom: 1, mobile: false, muted: false, volume: 100)])
    }

    private func t(_ id: String, _ server: String?, _ connection: ServerState? = .connected) -> SessionTelemetry {
        var t = SessionTelemetry(sessionId: id, server: server, title: "bash", cwd: "/home/spierce", command: "bash",
                                 state: .idle, lastActivity: Date())
        t.connection = server == nil ? nil : connection
        return t
    }

    /// Two servers in two colours, held for the length of a test.
    private func servers() -> RelayServers {
        RelayServers(entries: [
            RelayServerEntry(name: "surf-wsl", url: "https://yourslug.relaytty.com", color: .violet),
            RelayServerEntry(name: "surf-york", url: "http://127.0.0.1:9", color: .rose),
        ], token: { _ in nil })
    }

    @Test("sidebar: the header's slashes are the server's colour, its name and state chip as before; // LOCAL keeps the green")
    func sidebarHeader() throws {
        let held = servers()
        defer { held.reload(entries: [], tokenChanged: []) }
        let remote = t("a1", "surf-wsl", .reconnecting), local = t("b1", nil)
        let rows = SidebarModel.rows(
            lanes: [], telemetry: [remote.key: remote, local.key: local],
            servers: ["surf-wsl": .reconnecting, "surf-york": .connected])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        let wsl = SidebarGroupView(group: try #require(groups.first { $0.server == "surf-wsl" && $0.isServer }))
        #expect(wsl.slashColour == .violet && wsl.labelText == "// SURF-WSL")
        #expect(wsl.stateChipText == "RECONNECTING", "the state chip is state, and unchanged")
        let york = SidebarGroupView(group: try #require(groups.first { $0.server == "surf-york" && $0.isServer }))
        #expect(york.slashColour == .rose)
        let localHeader = SidebarGroupView(group: try #require(groups.first { $0.isLocalSection }))
        #expect(localHeader.slashColour == nil && localHeader.labelText == "// LOCAL")
        // A project group under a server has no slashes to colour.
        let project = SidebarGroupView(group: try #require(groups.first { $0.server == "surf-wsl" && !$0.isServer }))
        #expect(project.slashColour == nil && !project.labelText.hasPrefix("//"))
    }

    @Test("sidebar rows: the square and no name under a server; hollow when it is offline; nothing at all on a local row")
    func sidebarRows() throws {
        let held = servers()
        defer { held.reload(entries: [], tokenChanged: []) }
        let live = t("a1", "surf-york"), dead = t("a2", "surf-wsl", .unreachable), local = t("b1", nil)
        let rows = SidebarModel.rows(
            lanes: [], telemetry: [live.key: live, dead.key: dead, local.key: local],
            servers: ["surf-wsl": .unreachable, "surf-york": .connected])
        let entries = rows.compactMap { if case .entry(let e) = $0 { return e } else { return nil } }
        let liveRow = SidebarEntryView(entry: try #require(entries.first { $0.server == "surf-york" }))
        #expect(liveRow.serverChipText == nil, "no text chip: the row is already under // SURF-YORK")
        #expect(liveRow.serverMarkColour == .rose && liveRow.serverMarkIsHollow == false)
        let deadRow = SidebarEntryView(entry: try #require(entries.first { $0.server == "surf-wsl" }))
        #expect(deadRow.serverMarkColour == .violet && deadRow.serverMarkIsHollow == true)
        let localRow = SidebarEntryView(entry: try #require(entries.first { $0.server == nil }))
        #expect(localRow.serverMarkServer == nil && localRow.serverChipText == nil)
        #expect(!localRow.subviews.contains { $0 is ServerMark || $0 is ServerChip })
    }

    @Test("the square: one size, a tooltip that names the server, solid live and hollow offline")
    func mark() {
        let held = servers()
        defer { held.reload(entries: [], tokenChanged: []) }
        let mark = ServerMark(server: "surf-wsl")
        #expect(mark.intrinsicContentSize == NSSize(width: 9, height: 9) && ServerMark.side == 9)
        #expect(mark.toolTip == "surf-wsl — yourslug.relaytty.com")
        #expect(mark.colour == .violet && !mark.isHollow)
        #expect(mark.layer?.cornerRadius == 0 && mark.layer?.borderWidth == 0 && mark.layer?.backgroundColor != nil)
        mark.offline = true
        #expect(mark.isHollow && mark.layer?.borderWidth == 1)
        #expect((mark.layer?.backgroundColor?.alpha ?? 0) == 0, "outline only")
        #expect(ServerMark(server: "somebody-else").colour == .slate)
    }

    @Test("lane header: the chip keeps the name, tinted; offline it dims; too narrow or too small a tile, the square alone")
    func laneHeader() {
        let held = servers()
        defer { held.reload(entries: [], tokenChanged: []) }
        let header = LaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: 620, height: Theme.laneHeaderHeight)
        header.apply(Self.lane(server: "surf-wsl"))
        header.telemetry = t("a1", "surf-wsl")
        header.layout()
        #expect(header.serverChipText == "surf-wsl" && header.serverChipColour == .violet)
        #expect(header.serverChipShowsName && !header.serverChipIsOffline)

        header.telemetry = t("a1", "surf-wsl", .reconnecting)
        header.layout()
        #expect(header.serverChipIsOffline && header.serverChipColour == .violet, "still that server, visibly not live")

        // A gallery tile shrunk past reading: the square alone.
        header.telemetry = t("a1", "surf-wsl")
        header.thumbnailScale = 0.4
        header.layout()
        #expect(!header.serverChipShowsName && header.serverChipColour == .violet)
        header.thumbnailScale = 0.8
        header.layout()
        #expect(header.serverChipShowsName)
        header.thumbnailScale = nil

        // A header too narrow to keep ten characters of title beside the name.
        header.frame.size.width = 150
        header.layout()
        #expect(!header.serverChipShowsName)

        // A local lane has no chip.
        let local = LaneHeaderView()
        local.frame = NSRect(x: 0, y: 0, width: 620, height: Theme.laneHeaderHeight)
        local.apply(Self.lane(server: nil))
        local.telemetry = t("b1", nil)
        local.layout()
        #expect(local.serverChipText == nil && local.serverChipColour == nil)
    }

    @Test("⌘O and ⌘P: the tinted chip with the name, because those lists mix servers; dimmed when offline")
    func pickers() throws {
        let held = servers()
        defer { held.reload(entries: [], tokenChanged: []) }
        let a = t("a1", "surf-wsl"), b = t("a2", "surf-york", .reconnecting), local = t("b1", nil)
        let omni = OmniRanking.build(
            query: "", scope: .sessions, recents: [], pages: [], bookmarks: [], sessions: [a, b, local], destination: "")
        for c in omni.compactMap(\.candidate) {
            let row = OmniPickerRow(candidate: c, query: "", shortcut: nil)
            switch c.action {
            case .attach(a.key):
                #expect(row.serverChipText == "surf-wsl" && row.serverChipColour == .violet && !row.serverChipIsOffline)
            case .attach(b.key):
                #expect(row.serverChipText == "surf-york" && row.serverChipColour == .rose && row.serverChipIsOffline)
            default:
                #expect(row.serverChipText == nil && row.serverChipColour == nil)
            }
        }
        let launch = OmniCandidate(
            action: .run("claude", at: SpawnPlace(server: "surf-york", cwd: "/srv")), kind: .typed,
            headline: "claude", detail: "/srv", quality: .typed, chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil)
        #expect(OmniPickerRow(candidate: launch, query: "claude", shortcut: nil).serverChipColour == .rose)

        let session = PaletteSessionRow(PaletteSession(telemetry: a, titleMatches: []))
        #expect(session.serverChipText == "surf-wsl" && session.serverChipColour == .violet)
        let offline = PaletteSessionRow(PaletteSession(telemetry: b, titleMatches: []))
        #expect(offline.serverChipColour == .rose && offline.serverChipIsOffline)
        #expect(PaletteSessionRow(PaletteSession(telemetry: local, titleMatches: [])).serverChipColour == nil)
    }

    @Test("slate is the chip ADR-0023 drew: the at-rest grey, outlined, never filled")
    func slateIsTheOldChip() {
        let chip = ServerChip(server: "nobody-configured-this")
        #expect(chip.colour == .slate && chip.showsName)
        #expect(chip.layer?.borderWidth == 1 && chip.layer?.cornerRadius == 0)
        #expect((chip.layer?.backgroundColor?.alpha ?? 0) == 0, "identity is an outline; a fill is BLOCKED's")
    }

    @Test("Settings › Servers: eight square swatches, the current one framed, and a press goes through the book")
    func swatches() {
        let row = ServerRow(name: "surf-set")
        var chosen: [ServerColour] = []
        row.onColour = { chosen.append($0) }
        row.update(
            entry: RelayServerEntry(name: "surf-set", url: "http://127.0.0.1:9", color: .lemon),
            status: .init(kind: .connected, word: "connected", sessions: 0, detail: nil, isTunnelled: false, hasToken: true),
            animated: false)
        #expect(row.swatches.selected == .lemon)
        row.swatches.press(.ink)
        #expect(chosen == [.ink])
    }
}

// MARK: - the header's menu

@Suite("the menu on a server's sidebar header", .serialized)
@MainActor
struct ServerHeaderMenuTests {
    private func fixture() throws -> (SidebarViewController, RelayServerBook, ConfigStore, SessionRegistry, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try """
            [[servers]]
            name = "menu-wsl"
            url = "http://127.0.0.1:9"
            color = "violet"

            [[servers]]
            name = "menu-york"
            url = "http://127.0.0.1:9"
            color = "rose"

            """.write(to: path, atomically: true, encoding: .utf8)
        let store = ConfigStore(path: path, watches: false)
        let registry = SessionRegistry(sources: [])
        let book = RelayServerBook(
            servers: RelayServers(entries: [], token: { _ in nil }), registry: registry, store: store, pollInterval: 3600)
        book.reconcile()
        let sidebar = SidebarViewController(store: try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path))
        sidebar.serverBook = book
        return (sidebar, book, store, registry, dir)
    }

    private func press(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    @Test("Color ▸ the eight with a square and a name, the current one ticked; then Rename…, Disable, Server Settings…")
    func items() throws {
        // The sidebar holds the book weakly, as it does the registry: the
        // window controller is what keeps it.
        let (sidebar, book, _, registry, dir) = try fixture()
        defer { withExtendedLifetime(book) {}; registry.stop(); try? FileManager.default.removeItem(at: dir) }
        let items = sidebar.serverMenuItems(for: "menu-wsl")
        #expect(items.map(\.title) == ["Color", "", "Rename…", "Disable", "Server Settings…"])
        let palette = try #require(items[0].submenu)
        #expect(palette.items.map(\.title) == ["Slate", "Cyan", "Blue", "Violet", "Magenta", "Rose", "Lemon", "Ink"])
        #expect(palette.items.allSatisfy { $0.image?.size == NSSize(width: 9, height: 9) }, "a small square swatch each")
        #expect(palette.items.filter { $0.state == .on }.map(\.title) == ["Violet"])
        #expect(sidebar.serverMenuItems(for: "menu-york")[0].submenu?.items.first { $0.state == .on }?.title == "Rose")
        #expect(sidebar.serverMenuItems(for: "nobody").isEmpty)
    }

    @Test("each item goes through the door Settings uses: the book's setColour, rename and setEnabled, and onOpenServer")
    func actions() throws {
        let (sidebar, book, store, registry, dir) = try fixture()
        defer { registry.stop(); try? FileManager.default.removeItem(at: dir) }
        var items = sidebar.serverMenuItems(for: "menu-wsl")

        press(try #require(items[0].submenu?.items.first { $0.title == "Lemon" }))
        #expect(store.config.servers.first?.color == .lemon)
        #expect(ServerColours.colour(of: "menu-wsl") == .lemon)
        items = sidebar.serverMenuItems(for: "menu-wsl")
        #expect(items[0].submenu?.items.filter { $0.state == .on }.map(\.title) == ["Lemon"], "the tick follows")

        var opened: [String] = []
        sidebar.onOpenServer = { opened.append($0) }
        press(items[4])
        #expect(opened == ["menu-wsl"])

        // Rename: the ledger's half first, then the file, as in Settings.
        var ledger: [[String]] = []
        sidebar.onRenameServer = { ledger.append([$0, $1]) }
        #expect(sidebar.renameServer("menu-wsl", to: "menu-york") == "a server is already named menu-york")
        #expect(sidebar.renameServer("menu-wsl", to: "menu-box") == nil)
        #expect(ledger == [["menu-wsl", "menu-box"]])
        #expect(store.config.servers.map(\.name) == ["menu-box", "menu-york"])
        #expect(store.config.servers.first?.color == .lemon, "the colour goes with the server")
        #expect(ServerColours.colour(of: "menu-box") == .lemon && ServerColours.colour(of: "menu-wsl") == .slate)

        press(sidebar.serverMenuItems(for: "menu-box")[3])
        #expect(store.config.servers.first?.enabled == false)
        #expect(book.status(of: store.config.servers[0]).kind == .disabled)
    }
}

// MARK: - the socket

@Suite("maxpane server color")
struct ServerColourSocketTests {
    @Test("server-color parses with a name and a colour, and not without")
    func parse() {
        guard case .colourServer(let name, let colour)? = OpenServer.parse(#"{"op":"server-color","name":"WSL","color":"violet"}"#)
        else { Issue.record("server-color did not parse"); return }
        #expect(name == "WSL" && colour == "violet")
        #expect(OpenServer.parse(#"{"op":"server-color","name":"WSL"}"#) == nil)
        #expect(OpenServer.parse(#"{"op":"server-color","name":"","color":"violet"}"#) == nil)
        // A colour nobody defined still parses: the handler is the one that
        // knows the eight, and says so.
        guard case .colourServer(_, "chartreuse")? = OpenServer.parse(#"{"op":"server-color","name":"WSL","color":"chartreuse"}"#)
        else { Issue.record("an unknown colour should reach the handler"); return }
    }
}

// MARK: - render sheets

/// For looking at. Gated on `MAXPANE_SHOTS` like every sheet.
@Suite("server colour rendering", .serialized)
@MainActor
struct ServerColourRenderTests {
    private func t(_ id: String, _ server: String?, _ cwd: String, _ state: AgentState, _ title: String,
                   _ connection: ServerState?) -> SessionTelemetry {
        var t = SessionTelemetry(
            sessionId: id, server: server, title: title, cwd: cwd, command: "claude", state: state,
            bytesPerSecond: state == .working ? 1740 : 0, lastActivity: Date().addingTimeInterval(-40))
        t.connection = connection
        return t
    }

    private func label(_ text: String, _ size: CGFloat = 10) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.mono(size)
        l.textColor = Theme.dimText
        return l
    }

    @Test("renders the sidebar with two servers in two colours, one connected and one offline")
    func sidebarSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let held = RelayServers(entries: [
            RelayServerEntry(name: "WSL", url: "https://yourslug.relaytty.com", color: .violet),
            RelayServerEntry(name: "yorkshire", url: "http://192.168.68.10:7680", color: .cyan),
        ], token: { _ in nil })
        defer { held.reload(entries: [], tokenChanged: []) }
        let telemetry: [SessionKey: SessionTelemetry] = [
            "0368d543": t("0368d543", nil, NSHomeDirectory() + "/code/max-pane", .working, "◐ Editing SidebarModel.swift", nil),
            "77aa0000": t("77aa0000", nil, NSHomeDirectory() + "/life", .done, "✳ Inbox sweep", nil),
            SessionKey(server: "WSL", id: "0368d543"): t("0368d543", "WSL", "/home/spierce/m7out", .blocked, "Waiting on permission", .connected),
            SessionKey(server: "WSL", id: "4f2a0000"): t("4f2a0000", "WSL", "/home/spierce", .working, "◑ Refactoring the tunnel client", .connected),
            SessionKey(server: "WSL", id: "5b1c0000"): t("5b1c0000", "WSL", "/home/spierce", .idle, "bash", .connected),
            SessionKey(server: "yorkshire", id: "aa000000"): t("aa000000", "yorkshire", "/srv/build", .working, "docker build", .reconnecting),
            SessionKey(server: "yorkshire", id: "bb000000"): t("bb000000", "yorkshire", "/srv/build", .idle, "htop", .reconnecting),
        ]
        let rows = SidebarModel.rows(
            lanes: [], telemetry: telemetry, servers: ["WSL": .connected, "yorkshire": .reconnecting],
            serverErrors: ["yorkshire": "unreachable — 192.168.68.10: The request timed out."])
        let heights = rows.map { row -> CGFloat in
            if case .group = row { return SidebarGroupView.height }
            return SidebarEntryView.height
        }
        for width in [260.0, 320.0] as [CGFloat] {
            try AppearanceSheet.render(to: dir, named: "server-colour-sidebar-\(Int(width))") {
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: width, height: heights.reduce(0, +) + 8))
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
                return sheet
            }
        }
    }

    @Test("renders a lane header in each of the eight, connected, offline and as a small tile's square")
    func headerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let held = RelayServers(entries: ServerColour.allCases.map {
            RelayServerEntry(name: $0.rawValue, url: "http://127.0.0.1:9", color: $0)
        }, token: { _ in nil })
        defer { held.reload(entries: [], tokenChanged: []) }
        let states: [(AgentState, ServerState, CGFloat?)] = [
            (.working, .connected, nil), (.blocked, .connected, nil), (.done, .connected, nil),
            (.idle, .reconnecting, nil), (.working, .connected, 0.4),
        ]
        let width: CGFloat = 440
        try AppearanceSheet.render(to: dir, named: "server-colour-headers") {
            let sheet = NSView(frame: NSRect(
                x: 0, y: 0, width: width * CGFloat(states.count) + 10 * CGFloat(states.count + 1),
                height: CGFloat(ServerColour.allCases.count) * 40 + 8))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBackground
            for (row, colour) in ServerColour.allCases.enumerated() {
                for (column, state) in states.enumerated() {
                    let header = LaneHeaderView()
                    header.frame = NSRect(
                        x: 10 + CGFloat(column) * (width + 10),
                        y: CGFloat(ServerColour.allCases.count - row - 1) * 40 + 10,
                        width: width, height: Theme.laneHeaderHeight)
                    header.apply(ServerColourSurfaceTests.lane(
                        server: colour.rawValue, title: "Refactoring the tunnel", root: "\(colour.rawValue):/home/spierce/m7out"))
                    header.serverState = state.1
                    header.telemetry = t("a1", colour.rawValue, "/home/spierce/m7out", state.0, "", state.1)
                    header.thumbnailScale = state.2
                    header.isFocused = column == 0
                    sheet.addSubview(header)
                    header.layoutSubtreeIfNeeded()
                    header.layout()
                }
            }
            return sheet
        }
    }

    @Test("renders ⌘O's rows across two servers, one of them offline")
    func pickerSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let held = RelayServers(entries: [
            RelayServerEntry(name: "WSL", url: "https://yourslug.relaytty.com", color: .violet),
            RelayServerEntry(name: "yorkshire", url: "http://192.168.68.10:7680", color: .cyan),
        ], token: { _ in nil })
        defer { held.reload(entries: [], tokenChanged: []) }
        let sessions = [
            t("0368d543", nil, NSHomeDirectory() + "/code/max-pane", .working, "◐ Editing SidebarModel.swift", nil),
            t("1368d543", "WSL", "/home/spierce/m7out", .blocked, "Waiting on permission", .connected),
            t("4f2a0000", "WSL", "/home/spierce", .done, "◑ Refactoring the tunnel client", .connected),
            t("aa000000", "yorkshire", "/srv/build", .working, "docker build", .reconnecting),
        ]
        let rows = OmniRanking.build(
            query: "", scope: .sessions, recents: [], pages: [], bookmarks: [],
            sessions: sessions.sorted { $0.key < $1.key }, destination: "→ new lane")
            + [.item(OmniCandidate(
                action: .run("claude", at: SpawnPlace(server: "yorkshire", cwd: "/srv/build")), kind: .typed,
                headline: "claude", detail: "/srv/build", quality: .typed, chosenAt: 0, count: 0,
                telemetry: nil, bookmarkId: nil))]
        let heights = rows.map { $0.isSelectable ? 42.0 : 26.0 as CGFloat }
        try AppearanceSheet.render(to: dir, named: "server-colour-omni") {
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: heights.reduce(0, +)))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBackground
            var y = sheet.bounds.height
            for (row, height) in zip(rows, heights) {
                let view: NSView
                switch row {
                case .item(let c): view = OmniPickerRow(candidate: c, query: "", shortcut: nil)
                case .section(let title, let note), .note(let title, let note): view = PaletteSectionRow(title: title, note: note)
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: 640, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            return sheet
        }
    }

    @Test("renders the palette beside the greens and the orange: squares, hollow squares and chips, on lane and strip")
    func paletteSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let names = ServerColour.allCases.map(\.rawValue)
        let held = RelayServers(entries: ServerColour.allCases.map {
            RelayServerEntry(name: $0.rawValue, url: "http://127.0.0.1:9", color: $0)
        }, token: { _ in nil })
        defer { held.reload(entries: [], tokenChanged: []) }
        let states: [(String, NSColor)] = [
            ("accent", Theme.accent), ("working", Theme.working), ("blocked", Theme.blocked),
            ("alive", Theme.alive), ("DONE", Theme.done),
        ]
        let column: CGFloat = 86
        let count = CGFloat(names.count + states.count)
        try AppearanceSheet.render(to: dir, named: "server-colour-palette") {
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: column * count + 20, height: 200))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBackground
            let strip = NSView(frame: NSRect(x: 0, y: 0, width: sheet.bounds.width, height: 100))
            strip.wantsLayer = true
            strip.layerBackgroundColor = Theme.stripBackground
            sheet.addSubview(strip)
            for band in [0, 100] as [CGFloat] {
                for (index, name) in names.enumerated() {
                    let x = 10 + CGFloat(index) * column
                    let title = label(name)
                    title.frame = NSRect(x: x, y: band + 76, width: column, height: 14)
                    sheet.addSubview(title)
                    let solid = ServerMark(server: name)
                    solid.translatesAutoresizingMaskIntoConstraints = true
                    solid.frame = NSRect(x: x, y: band + 58, width: 9, height: 9)
                    sheet.addSubview(solid)
                    let hollow = ServerMark(server: name, offline: true)
                    hollow.translatesAutoresizingMaskIntoConstraints = true
                    hollow.frame = NSRect(x: x + 16, y: band + 58, width: 9, height: 9)
                    sheet.addSubview(hollow)
                    for (row, offline) in [false, true].enumerated() {
                        let chip = ServerChip(server: name, offline: offline)
                        chip.translatesAutoresizingMaskIntoConstraints = true
                        chip.frame = NSRect(
                            x: x, y: band + 34 - CGFloat(row) * 22, width: chip.fittingWidth, height: chip.fittingHeight)
                        sheet.addSubview(chip)
                    }
                }
                // The states, drawn as the app draws a state: a filled 7 pt
                // status square, and a word in the colour.
                for (index, state) in states.enumerated() {
                    let x = 10 + CGFloat(names.count + index) * column
                    let title = label(state.0)
                    title.frame = NSRect(x: x, y: band + 76, width: column, height: 14)
                    sheet.addSubview(title)
                    let square = NSView(frame: NSRect(x: x, y: band + 59, width: 7, height: 7))
                    square.wantsLayer = true
                    square.layerBackgroundColor = state.1
                    sheet.addSubview(square)
                    let nine = NSView(frame: NSRect(x: x + 16, y: band + 58, width: 9, height: 9))
                    nine.wantsLayer = true
                    nine.layerBackgroundColor = state.1
                    sheet.addSubview(nine)
                    let word = label(state.0.uppercased(), 9)
                    word.font = Theme.mono(9, weight: .bold)
                    word.textColor = state.1
                    word.frame = NSRect(x: x, y: band + 34, width: column, height: 14)
                    sheet.addSubview(word)
                }
            }
            return sheet
        }
    }

    @Test("renders Settings › Servers' swatches")
    func swatchSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        try AppearanceSheet.render(to: dir, named: "server-colour-settings-row") {
            let row = ServerRow(name: "WSL")
            row.update(
                entry: RelayServerEntry(name: "WSL", url: "https://yourslug.relaytty.com", color: .violet),
                status: .init(kind: .connected, word: "connected", sessions: 3, detail: nil, isTunnelled: false, hasToken: true),
                animated: false)
            let sheet = NSView(frame: NSRect(x: 0, y: 0, width: ServersSection.width + 24, height: 90))
            sheet.wantsLayer = true
            sheet.layerBackgroundColor = Theme.laneBackground
            row.translatesAutoresizingMaskIntoConstraints = true
            row.frame = NSRect(x: 12, y: 10, width: ServersSection.width, height: 70)
            sheet.addSubview(row)
            return sheet
        }
    }
}
