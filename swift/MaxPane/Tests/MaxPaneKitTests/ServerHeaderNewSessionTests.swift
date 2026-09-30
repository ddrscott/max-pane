import AppKit
import Foundation
import LanedCore
import Testing
@testable import MaxPaneKit

// An open section header — a server's, or `// LOCAL` — shows `+ NEW`, which
// opens the picker with `@<server> ` typed. It takes its own press and never
// folds; a folded header and a project group have none.

@Suite("an open server header's + NEW opens the picker aimed at that server", .serialized)
@MainActor
struct ServerHeaderNewSessionTests {
    typealias Fixture = ServerHeaderClickTests.Fixture
    static let server = ServerHeaderClickTests.server

    @Test("open, the header has + NEW at its right end; folded, it has none")
    func showsOnlyWhenOpen() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        var (row, view) = try f.header()
        let button = try #require(view.newSession)
        #expect(button.isEnabled)
        let more = try #require(view.more)
        #expect(button.frame.maxX <= more.frame.minX, "left of the ⋯")
        #expect(button.frame.maxX > view.bounds.maxX - 40, "at the header's right end")
        #expect(button.toolTip == "New session on \(Self.server) (⌘R, then @\(Self.server))")
        #expect(button.layer?.cornerRadius == 0, "square, no bubble")

        f.sidebar.click(row: row, at: view.convert(NSPoint(x: 60, y: view.bounds.midY), to: nil))
        #expect(f.folded)
        (row, view) = try f.header()
        #expect(view.newSession == nil, "a folded header has no + NEW")
    }

    @Test("a press on + NEW hands the sidebar the server's word and never folds")
    func pressOpensPickerNotFold() throws {
        let f = try Fixture()
        defer { f.tearDown() }
        var asked: [String] = []
        f.sidebar.onNewSessionOn = { asked.append($0) }
        let (row, view) = try f.header()
        let button = try #require(view.newSession)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        let hit = try #require(f.window.contentView?.hitTest(point))
        #expect(hit === button || hit.isDescendant(of: button), "the press lands on \(type(of: hit))")

        // The table's row action, should it fire too, leaves the fold alone.
        f.sidebar.click(row: row, at: point)
        #expect(!f.folded, "+ NEW never folds")
        #expect(f.presented.isEmpty, "and never opens the ⋯ menu")

        button.performClick(nil)
        #expect(asked == [Self.server])
        #expect(!f.folded)

        // What the window controller types into the picker: the server,
        // chosen, with nothing after it yet.
        let text = OmniServerPrefix.prefill(asked[0])
        #expect(text == "@\(Self.server) ")
        let parsed = OmniServerPrefix.parse(text, servers: [Self.server])
        #expect(parsed.choice == .server(Self.server))
        #expect(parsed.line.isEmpty)
    }

    @Test("// LOCAL gets + NEW aimed at @local; project groups get none; a quiet server's is greyed and says why")
    func whichHeadersHaveIt() throws {
        var t = SessionTelemetry(
            sessionId: "p1", server: nil, title: "zsh", cwd: "/Users/me/life",
            command: "zsh", state: .idle, lastActivity: Date())
        t.connection = .connected
        let rows = SidebarModel.rows(
            lanes: [], telemetry: [t.key: t],
            servers: ["new-up": .connected, "new-down": .unreachable])
        let groups = rows.compactMap { if case .group(let g) = $0 { return g } else { return nil } }

        let local = SidebarGroupView(group: try #require(groups.first { $0.isLocalSection }))
        let localButton = try #require(local.newSession)
        #expect(localButton.isEnabled)
        #expect(localButton.toolTip?.contains("@local") == true)
        #expect(OmniServerPrefix.parse(OmniServerPrefix.prefill(OmniServerPrefix.localWord), servers: []).choice == .local)

        let projects = groups.filter { !$0.isSection }
        #expect(!projects.isEmpty)
        for g in projects {
            #expect(SidebarGroupView(group: g).newSession == nil, "\(g.path) is a project, not a server")
        }

        let down = SidebarGroupView(group: try #require(groups.first { $0.server == "new-down" && $0.isServer }))
        let downButton = try #require(down.newSession)
        #expect(!downButton.isEnabled, "never starts something that silently fails")
        #expect(downButton.toolTip?.contains("nothing can start there") == true)

        let up = SidebarGroupView(group: try #require(groups.first { $0.server == "new-up" && $0.isServer }))
        #expect(up.newSession?.isEnabled == true)
    }
}
