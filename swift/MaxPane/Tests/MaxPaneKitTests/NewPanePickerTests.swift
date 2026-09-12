import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// What ⌘T offers, given what you typed and what you have run before.
///
/// The rules that matter are about *not* being clever: a picker that decides
/// `make` is a website, or that renumbers its rows while you look at them, is
/// worse than a prompt.
@Suite("new pane picker")
struct NewPanePickerTests {
    private func recent(_ kind: RecentKind, _ value: String, cwd: String? = nil) -> Recent {
        Recent(kind: kind, value: value, cwd: cwd, lastUsedAt: 0, useCount: 1)
    }

    // MARK: - what is offered

    @Test("an empty query offers the history and nothing else")
    func emptyQueryIsJustHistory() {
        let entries = NewPaneEntries.build(
            query: "", recents: [recent(.command, "htop"), recent(.url, "https://example.com")])
        #expect(entries.count == 3)
        #expect(entries[0] == .section("RECENT"))
        // No LAUNCH rows: there is nothing typed to launch.
        #expect(!entries.contains { if case .action = $0 { return true } else { return false } })
    }

    @Test("an empty picker with no history has no rows at all")
    func nothingToShow() {
        #expect(NewPaneEntries.build(query: "", recents: []).isEmpty)
    }

    @Test("typing always offers both a command and a URL")
    func bothAreAlwaysReachable() {
        // Guessing wrong must never make the other one unreachable.
        for query in ["make", "example.com", "localhost:3000", "git status"] {
            let actions = NewPaneEntries.build(query: query, recents: []).compactMap { entry -> NewPaneChoice? in
                if case .action(let c) = entry { return c } else { return nil }
            }
            #expect(actions.count == 2, "\(query) offered \(actions.count) actions")
        }
    }

    @Test("a command comes first for something you would type at a shell")
    func commandsLeadForCommands() {
        let entries = NewPaneEntries.build(query: "npm test", recents: [])
        #expect(entries[1] == .action(.command("npm test", cwd: nil)))
    }

    @Test("a URL comes first for something that looks like an address")
    func urlsLeadForURLs() {
        let entries = NewPaneEntries.build(query: "github.com/anthropics", recents: [])
        #expect(entries[1] == .action(.url("github.com/anthropics")))
    }

    @Test("surrounding whitespace is not part of what gets launched")
    func queryIsTrimmed() {
        let entries = NewPaneEntries.build(query: "  htop  ", recents: [])
        #expect(entries[1] == .action(.command("htop", cwd: nil)))
    }

    // MARK: - what counts as a URL

    @Test("addresses are recognised", arguments: [
        "https://example.com", "http://localhost:8080", "example.com", "docs.rs/tokio",
        "localhost:3000", "127.0.0.1:5173", "news.ycombinator.com/item?id=1",
    ])
    func recognisesAddresses(_ text: String) {
        #expect(NewPaneEntries.looksLikeURL(text))
    }

    @Test("commands are not mistaken for addresses", arguments: [
        "make", "npm test", "git status", "./configure", "cargo build --release",
        "vim src/main.rs", "cat README.md", ".zshrc", "ls",
    ])
    func leavesCommandsAlone(_ text: String) {
        #expect(!NewPaneEntries.looksLikeURL(text))
    }

    @Test("a source file is a file, not a site")
    func sourceFilesAreNotSites() {
        // `main.rs` and `Cargo.toml` have the shape of a domain and are not one.
        #expect(!NewPaneEntries.looksLikeURL("main.rs"))
        #expect(!NewPaneEntries.looksLikeURL("Cargo.toml"))
        #expect(!NewPaneEntries.looksLikeURL("package.json"))
    }

    // MARK: - filtering

    @Test("typing filters the history without losing the launch rows")
    func filteringKeepsTheEscapeHatch() {
        let recents = [
            recent(.command, "npm test"),
            recent(.command, "htop"),
            recent(.url, "https://news.ycombinator.com"),
        ]
        let entries = NewPaneEntries.build(query: "npm", recents: recents)
        let shown = entries.compactMap { entry -> String? in
            if case .recent(let r) = entry { return r.value } else { return nil }
        }
        #expect(shown == ["npm test"])
        // And "npm" is still launchable as typed, which is the point of a
        // filter that cannot find what you meant.
        #expect(entries.contains(.action(.command("npm", cwd: nil))))
    }

    @Test("a history section appears only when something matched")
    func noEmptySection() {
        let entries = NewPaneEntries.build(query: "zzz", recents: [recent(.command, "htop")])
        #expect(!entries.contains(.section("RECENT")))
    }

    // MARK: - numbering

    @Test("every row that can be launched gets a number, and headings do not")
    func numbersSkipHeadings() {
        let recents = (1...4).map { recent(.command, "cmd \($0)") }
        let entries = NewPaneEntries.build(query: "", recents: recents)
        let shortcuts = NewPaneEntries.shortcuts(for: entries)

        for (index, entry) in entries.enumerated() {
            #expect(entry.isSelectable == (shortcuts[index] != nil),
                    "row \(index) numbering disagrees with whether it can be launched")
        }
        #expect(shortcuts.count == 4)
    }

    @Test("numbers run 1…9 then 0, and stop")
    func numberingRunsOutAtTen() {
        let recents = (1...14).map { recent(.command, "cmd \($0)") }
        let entries = NewPaneEntries.build(query: "", recents: recents)
        let shortcuts = NewPaneEntries.shortcuts(for: entries)

        #expect(shortcuts.count == 10, "there are only ten digits")
        #expect(NewPaneEntries.label(forShortcut: 0) == "1")
        #expect(NewPaneEntries.label(forShortcut: 8) == "9")
        #expect(NewPaneEntries.label(forShortcut: 9) == "0")
    }

    @Test("numbers follow the rows on screen, not the underlying history")
    func numbersFollowWhatIsVisible() {
        // The third thing you can see is ⌘3 whatever it happens to be — the
        // alternative is a number that means something different depending on
        // what you have typed, which nobody can use.
        let recents = [recent(.command, "alpha"), recent(.command, "beta"), recent(.command, "gamma")]
        let entries = NewPaneEntries.build(query: "beta", recents: recents)
        let shortcuts = NewPaneEntries.shortcuts(for: entries)

        let numbered = entries.enumerated()
            .compactMap { index, entry in shortcuts[index].map { ($0, entry) } }
            .sorted { $0.0 < $1.0 }
        #expect(numbered.count == 3)      // run, open, and the one match
        #expect(numbered.last?.1 == .recent(recents[1]))
    }

    // MARK: - what a row launches

    @Test("a remembered command launches with the directory it ran in")
    func recentCommandsCarryTheirDirectory() {
        let entry = NewPaneEntry.recent(recent(.command, "npm test", cwd: "/src/web"))
        #expect(entry.choice == .command("npm test", cwd: "/src/web"))
    }

    @Test("a remembered page launches as a URL")
    func recentURLsOpen() {
        let entry = NewPaneEntry.recent(recent(.url, "https://example.com"))
        #expect(entry.choice == .url("https://example.com"))
    }

    @Test("a heading launches nothing")
    func headingsAreInert() {
        #expect(NewPaneEntry.section("RECENT").choice == nil)
        #expect(!NewPaneEntry.section("RECENT").isSelectable)
    }
}
