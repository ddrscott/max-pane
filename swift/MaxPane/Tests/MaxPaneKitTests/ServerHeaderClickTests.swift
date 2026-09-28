import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

// A click on a server's sidebar header folds it, like `// LOCAL` and every
// other header; the server's menu moved behind a `⋯` at the header's right
// end, which takes its own press and never folds (ADR-0023, amended).

@Suite("a click on a server's header folds it; ⋯ holds its menu", .serialized)
@MainActor
struct ServerHeaderClickTests {
    nonisolated static let server = "fold-wsl"

    final class Fixture {
        let dir: URL
        let store: StripStore
        let config: ConfigStore
        let registry: SessionRegistry
        let book: RelayServerBook
        let sidebar: SidebarViewController
        let window: NSWindow
        var opened: [String] = []
        var attached: [SessionKey] = []
        var presented: [NSMenu] = []

        @MainActor
        init(state: AgentState = .idle) throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-fold-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("config.toml")
            try """
                [[servers]]
                name = "\(ServerHeaderClickTests.server)"
                url = "http://127.0.0.1:9"
                color = "violet"

                """.write(to: path, atomically: true, encoding: .utf8)
            config = ConfigStore(path: path, watches: false)
            registry = SessionRegistry(sources: [])
            book = RelayServerBook(
                servers: RelayServers(entries: [], token: { _ in nil }), registry: registry, store: config,
                pollInterval: 3600)
            book.reconcile()
            store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
            sidebar = SidebarViewController(store: store)
            sidebar.serverBook = book
            window = NSWindow(
                contentRect: NSRect(x: -8000, y: 200, width: 280, height: 500),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
            sidebar.view.frame = NSRect(x: 0, y: 0, width: 280, height: 500)
            window.contentView?.addSubview(sidebar.view)
            sidebar.onOpenServer = { [weak self] in self?.opened.append($0) }
            sidebar.onAttach = { [weak self] in self?.attached.append($0) }
            sidebar.presentMenu = { [weak self] menu, _ in self?.presented.append(menu) }

            var t = SessionTelemetry(
                sessionId: "r1", server: ServerHeaderClickTests.server, title: "claude", cwd: "/home/spierce/proj",
                command: "claude", state: state, lastActivity: Date())
            t.connection = .connected
            sidebar.sessionsChanged([t.key: t])
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

        /// The server's header as it is on screen now: the table rebuilds it
        /// on every fold, so ask again after each click.
        @MainActor
        func header() throws -> (row: Int, view: SidebarGroupView) {
            layout()
            let row = try #require(sidebar.row(ofServer: ServerHeaderClickTests.server))
            let view = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarGroupView)
            layout()
            return (row, view)
        }

        @MainActor
        var folded: Bool { store.collapsedGroups.contains(SidebarModel.Group.serverPath(ServerHeaderClickTests.server)) }

        @MainActor
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0)!
        }

        @MainActor
        func tearDown() {
            window.orderOut(nil)
            registry.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    @Test("a click on the triangle, the name or the count folds and opens the server; nothing opens Settings")
    func headerClickFolds() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        #expect(!f.folded)
        var expectFolded = false
        // Triangle, name, then out toward the count: every part is the fold.
        for x: (SidebarGroupView) -> CGFloat in [{ _ in 10 }, { _ in 60 }, { $0.bounds.maxX - 40 }, { _ in 120 }] {
            let (row, view) = try f.header()
            let point = view.convert(NSPoint(x: x(view), y: view.bounds.midY), to: nil)
            // What the window would send the press to: the table, not a mark.
            #expect(!(f.window.contentView?.hitTest(point) is MoreMark))
            f.sidebar.click(row: row, at: point)
            expectFolded.toggle()
            #expect(f.folded == expectFolded, "x = \(x(view))")
        }
        #expect(f.opened.isEmpty, "a header click no longer goes to Settings › Servers")
    }

    @Test("⋯ takes the press: it opens the right-click's menu and never folds")
    func moreOpensTheMenu() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        let (row, view) = try f.header()
        let more = try #require(view.more)
        #expect(more.frame.maxX > view.bounds.maxX - 8, "at the header's right end")
        #expect(more.frame.width >= 18 && more.frame.height >= 18, "a target a pointer can find")

        let point = more.convert(NSPoint(x: more.bounds.midX, y: more.bounds.midY), to: nil)
        let hit = try #require(f.window.contentView?.hitTest(point))
        #expect(hit === more, "the press lands on \(type(of: hit))")
        hit.mouseDown(with: f.event(.leftMouseDown, at: point))
        hit.mouseUp(with: f.event(.leftMouseUp, at: point))
        #expect(!f.folded, "the ⋯ never folds")
        let menu = try #require(f.presented.first)
        #expect(f.presented.count == 1)

        // The same menu a right-click on the header opens, item for item.
        let right = NSMenu()
        f.sidebar.populate(right, forRow: row)
        let titles = ["Color", "", "Rename…", "Disable", "Server Settings…", "", "Collapse All", "Expand All"]
        #expect(right.items.map(\.title) == titles, "the right-click menu is unchanged")
        #expect(menu.items.map(\.title) == titles)

        // Server Settings… is still the one-click way there.
        let settings = try #require(menu.items.first { $0.title == "Server Settings…" })
        _ = (settings.target as? NSObject)?.perform(settings.action, with: settings)
        #expect(f.opened == [Self.server])
    }

    @Test("folded, a click on N BLOCKED still reaches that session; anywhere else opens the fold")
    func foldedReachThrough() throws {
        let f = try Fixture(state: .blocked)
        defer { f.tearDown() }
        var (row, view) = try f.header()
        f.sidebar.click(row: row, at: view.convert(NSPoint(x: 60, y: view.bounds.midY), to: nil))
        #expect(f.folded)

        (row, view) = try f.header()
        #expect(view.blockedText.contains("BLOCKED"))
        let x = try #require(stride(from: 4.0, to: view.bounds.maxX, by: 2).first {
            view.stateHit(at: NSPoint(x: $0, y: view.bounds.midY)) == .blocked
        })
        f.sidebar.click(row: row, at: view.convert(NSPoint(x: x, y: view.bounds.midY), to: nil))
        #expect(f.attached.map(\.id) == ["r1"], "the BLOCKED text goes to the session")
        #expect(f.folded, "the reach-through is the app's to open, not the header's fold")

        f.sidebar.click(row: row, at: view.convert(NSPoint(x: 60, y: view.bounds.midY), to: nil))
        #expect(!f.folded)
        #expect(f.attached.count == 1)
    }

    @Test("⋯ is out on hover and while the server is not answering; only server headers have one")
    func moreShows() throws {
        let rows = SidebarModel.rows(
            lanes: [], telemetry: [:],
            servers: ["show-up": .connected, "show-down": .unreachable])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }

        let up = SidebarGroupView(group: try #require(groups.first { $0.server == "show-up" && $0.isServer }))
        #expect(up.more != nil && !up.isMoreShown, "at rest, out of the way")
        up.setHovered(true)
        #expect(up.isMoreShown)
        up.setHovered(false)
        #expect(!up.isMoreShown)
        #expect(up.toolTip?.contains("click to fold it") == true && up.toolTip?.contains("⋯") == true)
        #expect(up.toolTip?.contains("Settings › Servers") == false)

        let down = SidebarGroupView(group: try #require(groups.first { $0.server == "show-down" && $0.isServer }))
        #expect(down.isMoreShown, "the way to fix it is in sight when it matters")
        down.setHovered(false)
        #expect(down.isMoreShown)
        #expect(down.toolTip?.contains("⋯ › Server Settings…") == true)

        let local = SidebarGroupView(group: try #require(groups.first { $0.isLocalSection }))
        #expect(local.more == nil, "// LOCAL has no ⋯")
    }
}
