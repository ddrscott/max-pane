import AppKit
import Testing
import Foundation
import LanedCore
@testable import MaxPaneKit

/// The comparable axis. Everything ⌘O does rests on this being right, because
/// it is the only thing a command, a page and a session can be compared on.
@Suite("match quality")
struct MatchQualityTests {
    @Test("where the match landed is what decides the band")
    func theLadder() {
        #expect(MatchQuality.of("deploy", in: "deployment") == .prefix)
        #expect(MatchQuality.of("notes", in: "deployment-notes") == .wordPrefix)
        #expect(MatchQuality.of("ploy", in: "deployment") == .substring)
        #expect(MatchQuality.of("dpm", in: "deployment") == .scattered)
        #expect(MatchQuality.of("zzq", in: "deployment") == nil)
    }

    @Test("the best occurrence decides, not the first")
    func bestOccurrenceWins() {
        // `com` is mid-word in `example.com` and a word start in `/compare`.
        // Taking the first hit would rank the row by the worse of the two
        // matches it actually has.
        #expect(MatchQuality.of("com", in: "example.com/compare") == .wordPrefix)
    }

    @Test("an address's punctuation separates words")
    func urlPunctuationIsABoundary() {
        #expect(MatchQuality.of("id", in: "news.example.com/item?id=42") == .wordPrefix)
        #expect(MatchQuality.of("inbox", in: "mail.example.com/#/inbox") == .wordPrefix)
    }

    @Test("nothing typed is uniform, so nothing is ranked by it")
    func emptyIsUniform() {
        #expect(MatchQuality.of("", in: "anything") == .prefix)
        #expect(MatchQuality.of("", in: "something else") == .prefix)
    }

    @Test("the best of several fields is the row's band")
    func acrossFields() {
        // A page whose title barely matches but whose URL starts with the query
        // is a prefix match, not a scattered one.
        #expect(MatchQuality.of("docs", inAny: ["Dangerous Occasional Cats", "docs.rs/tokio"]) == .prefix)
        #expect(MatchQuality.of("zzq", inAny: ["a", "b"]) == nil)
    }

    @Test("a row that won on a literal hit never paints a scattered one")
    func highlightsExplainTheRow() {
        // The measured wart: `doc` matched `doc.rust-lang.org` outright, and the
        // row's *title* then lit the d of `std`, an o in `collections` and a c
        // further along — three green letters that had nothing to do with why
        // the row was on screen.
        #expect(MatchQuality.offsets("doc", in: "doc.rust-lang.org/std", literal: true) == [0, 1, 2])
        #expect(MatchQuality.offsets("doc", in: "HashMap in std::collections", literal: true) == [])
        // And when the row *did* win on a guess, the guess is what to paint.
        #expect(!MatchQuality.offsets("mxp", in: "max-pane", literal: false).isEmpty)
    }

    @Test("the painted occurrence is the one that won the band")
    func highlightsTheBestOccurrence() {
        // `com` is buried inside `welcome` and is a word start after the dot;
        // the row is on screen because of the second one, so that is the one
        // lit rather than the first one encountered.
        #expect(MatchQuality.offsets("com", in: "welcome.com/x", literal: true) == [8, 9, 10])
    }

    @Test("a multi-word query still highlights something")
    func spacesDoNotKillTheHighlight() {
        #expect(MatchQuality.offsets("max pane", in: "maxpane", literal: true) == [0, 1, 2, 3, 4, 5, 6])
    }

    @Test("a literal hit and a guess are never the same band")
    func literalIsNotAGuess() {
        #expect(MatchQuality.prefix.isLiteral)
        #expect(MatchQuality.substring.isLiteral)
        #expect(!MatchQuality.scattered.isLiteral)
        #expect(MatchQuality.typed < .prefix)
    }
}

/// What ⌘O offers, given what you typed and everything you have ever started.
///
/// The rules that can actually be wrong live here: which of four incomparable
/// sources leads, whether a wrong guess about `localhost:3000` hides the other
/// reading, and whether the row you meant is in the top three.
@Suite("omni picker")
struct OmniPickerTests {
    private func recent(
        _ kind: RecentKind, _ value: String, cwd: String? = nil, at: Int64 = 0, count: UInt32 = 1
    ) -> Recent {
        Recent(kind: kind, value: value, cwd: cwd, lastUsedAt: at, useCount: count)
    }

    private func page(
        _ url: String, _ title: String? = nil, at: Int64 = 0, count: UInt32 = 1
    ) -> HistoryEntry {
        HistoryEntry(
            url: url, title: title, firstVisitAt: 0, lastVisitAt: at,
            visitCount: count, matchedField: .url, score: 0)
    }

    private func session(
        _ id: String, _ title: String, command: String = "zsh", cwd: String = "/tmp",
        state: AgentState = .idle, attached: Bool = false, at: TimeInterval = 0
    ) -> SessionTelemetry {
        SessionTelemetry(
            sessionId: id, title: title, cwd: cwd, command: command, state: state,
            lastActivity: Date(timeIntervalSince1970: at), isRunning: true, isAttached: attached)
    }

    private func build(
        _ query: String, scope: OmniScope = .everything,
        recents: [Recent] = [], pages: [HistoryEntry] = [],
        bookmarks: [BookmarkHit] = [], sessions: [SessionTelemetry] = []
    ) -> [OmniRow] {
        OmniRanking.build(
            query: query, scope: scope, recents: recents, pages: pages,
            bookmarks: bookmarks, sessions: sessions, destination: "→ new lane")
    }

    /// A kept page, as the core hands it over.
    private func kept(
        _ url: String, _ title: String, folder: String? = nil, at: Int64 = 0
    ) -> BookmarkHit {
        BookmarkHit(
            bookmark: Bookmark(
                id: "bm-" + url, parentId: folder, isFolder: false, url: url, title: title,
                position: 0, addedAt: at, depth: folder == nil ? 0 : 1),
            folderPath: folder, matchedField: .title, score: 0)
    }

    private func actions(_ rows: [OmniRow]) -> [OmniAction] {
        rows.compactMap { $0.candidate?.action }
    }

    // MARK: - rows one and two

    @Test("the LAUNCH row says when a line is going through a shell")
    func launchRowNamesTheShell() {
        // A pipeline is not started the way `htop` is, and the row is the only
        // place to say so before Return rather than after.
        let rows = OmniRanking.build(
            query: "yes | head", scope: .commands, recents: [], pages: [],
            bookmarks: [], sessions: [], destination: "→ new lane", shellName: "zsh")
        let typed = rows.compactMap(\.candidate).first { $0.kind == .typed }
        #expect(typed?.action == .run("yes | head", at: .local))
        #expect(typed?.detail == "through zsh")
    }

    @Test("a plain command line says nothing extra, because nothing extra is true")
    func launchRowIsQuietForAProgram() {
        let rows = OmniRanking.build(
            query: "npm run build", scope: .commands, recents: [], pages: [],
            bookmarks: [], sessions: [], destination: "→ new lane", shellName: "zsh")
        #expect(rows.compactMap(\.candidate).first { $0.kind == .typed }?.detail == "")
    }

    @Test("typing always offers both readings, and they are always first")
    func bothReadingsLead() {
        // Guessing wrong about `localhost:3000` must never make the other one
        // unreachable, and a corpus row must never push either off the top.
        for query in ["make", "example.com", "localhost:3000", "git status"] {
            let rows = build(
                query,
                recents: [recent(.command, query + " extra", at: 9_999)],
                pages: [page("https://" + query.replacingOccurrences(of: " ", with: "-"), query)])
            let typed = rows.compactMap(\.candidate).prefix(2)
            #expect(typed.allSatisfy { $0.kind == .typed }, "\(query) did not lead with what was typed")
            #expect(typed.contains { $0.action == .run(query, at: .local) },
                    "\(query) lost its command reading")
            #expect(typed.contains { $0.action == .open(query) },
                    "\(query) lost its address reading")
        }
    }

    @Test("a command leads for something you would type at a shell")
    func commandsLeadForCommands() {
        #expect(actions(build("npm test")).first == .run("npm test", at: .local))
    }

    @Test("a URL leads for something that looks like an address")
    func urlsLeadForURLs() {
        #expect(actions(build("github.com/anthropics")).first == .open("github.com/anthropics"))
    }

    @Test("what gets launched is not what you typed with the spaces on")
    func queryIsTrimmed() {
        #expect(actions(build("  htop  ")).first == .run("htop", at: .local))
    }

    // MARK: - the ranking rule

    @Test("a literal hit is never below a scattered one")
    func literalBeatsScattered() {
        // The measured failure in the palette this replaced: `hop` led with
        // titles whose h, o and p are three unrelated letters.
        let rows = build(
            "hop",
            recents: [recent(.command, "helm operator push", at: 9_999)],
            pages: [page("https://shop.example.com/hoppers", "Hoppers", at: 1)])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.first?.action == .open("https://shop.example.com/hoppers"))
    }

    @Test("a guess never shares the list with a literal hit")
    func guessesAreDroppedWhenSomethingRealMatched() {
        let rows = build(
            "git",
            recents: [recent(.command, "go install ./tools", at: 9_999)],
            pages: [page("https://github.com", "GitHub", at: 1)])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.count == 1, "a coincidence was listed beside a real match")
        #expect(corpus[0].action == .open("https://github.com"))
    }

    @Test("when nothing matched literally, the guesses are all there is")
    func guessesSurviveAlone() {
        // `mxp` finding `max-pane` is the whole reason the last band exists.
        let rows = build("mxp", recents: [recent(.command, "cd max-pane", at: 9)])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.map(\.action) == [.run("cd max-pane", at: .local)])
    }

    @Test("inside a band, the thing you chose most recently leads")
    func recencyIsTheTieBreak() {
        let rows = build(
            "test",
            recents: [
                recent(.command, "test-old", at: 100),
                recent(.command, "test-new", at: 900),
            ])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.first?.action == .run("test-new", at: .local))
    }

    @Test("a page and a command compete on the same ladder, not by source")
    func sourcesDoNotOutrankEachOther() {
        // A strict "commands before pages" order would put `gitk` above the page
        // you actually meant; a strict "pages first" would do the reverse. The
        // band decides, and here the page's title starts with the query.
        let rows = build(
            "git",
            recents: [recent(.command, "cargo build --git", at: 5_000)],
            pages: [page("https://github.com/anthropics", "Git — everything", at: 1)])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.first?.kind == .page)
    }

    // MARK: - sessions

    @Test("a session already on the strip is not offered")
    func attachedSessionsAreNotStartable() {
        let rows = build(
            "claude",
            sessions: [
                session("aaaa1111", "claude in max-pane", attached: true),
                session("bbbb2222", "claude in trifecta", attached: false),
            ])
        let attaches = actions(rows).compactMap { action -> String? in
            if case .attach(let key) = action { return key.id } else { return nil }
        }
        #expect(attaches == ["bbbb2222"], "⌘O offered to start something that already exists")
    }

    @Test("a blocked session leads its band, but never the list")
    func blockedLeadsItsBand() {
        let rows = build(
            "claude",
            sessions: [
                session("aaaa1111", "claude idle", at: 900),
                session("bbbb2222", "claude blocked", state: .blocked, at: 100),
            ])
        let all = rows.compactMap(\.candidate)
        // Rows one and two are still what was typed: ⌘O ↩ cannot change
        // meaning because an agent stopped five seconds ago.
        #expect(all[0].kind == .typed)
        let corpus = all.filter { $0.kind != .typed }
        #expect(corpus.first?.action == .attach("bbbb2222"))
    }

    @Test("a session is found by its directory as well as its name")
    func sessionsMatchOnPath() {
        let rows = build("maxpane", sessions: [session("cccc3333", "agent", cwd: "/x/maxpane")])
        #expect(actions(rows).contains(.attach("cccc3333")))
    }

    // MARK: - nothing typed

    @Test("with nothing typed the list is what you last started, newest first")
    func emptyQueryIsRecency() {
        let rows = build(
            "",
            recents: [recent(.command, "htop", at: 500)],
            pages: [page("https://a.example", "A", at: 900)])
        #expect(rows.first == .section(title: "RECENT", note: "→ new lane"))
        let corpus = rows.compactMap(\.candidate)
        #expect(corpus[0].action == .open("https://a.example"))
        #expect(corpus[1].action == .run("htop", at: .local))
    }

    @Test("nothing typed means no LAUNCH rows to launch")
    func emptyQueryHasNoTypedRows() {
        let rows = build("", recents: [recent(.command, "htop", at: 1)])
        #expect(!rows.contains { $0.candidate?.kind == .typed })
    }

    @Test("sessions stay out of the recency list and get their own headers")
    func emptyQuerySeparatesSessions() {
        // A session's only timestamp is the last time it made a noise, which is
        // an agent talking to itself. Merged into the recency order, a chatty
        // background agent would reshuffle the top of the list every second.
        let rows = build(
            "",
            recents: [recent(.command, "htop", at: 1)],
            sessions: [
                session("aaaa1111", "idle one", at: 9_000_000),
                session("bbbb2222", "stuck one", state: .blocked, at: 1),
            ])
        #expect(rows.first == .section(title: "RECENT", note: "→ new lane"))
        // What ↩ does is still "the last thing I launched".
        #expect(rows.compactMap(\.candidate).first?.action == .run("htop", at: .local))
        let headers = rows.compactMap { row -> String? in
            if case .section(let title, _) = row { return title } else { return nil }
        }
        #expect(headers == ["RECENT", "WAITING ON YOU", "NOT ON THE STRIP"])
    }

    @Test("an empty everything says so rather than showing an empty box")
    func nothingAtAll() {
        #expect(build("") == [.note(title: "EVERYTHING", detail: "nothing started yet")])
    }

    @Test("a query with no corpus match still leaves the launch rows")
    func noMatchKeepsTheEscapeHatch() {
        let rows = build("zzqq", recents: [recent(.command, "htop", at: 1)])
        #expect(rows.compactMap(\.candidate).allSatisfy { $0.kind == .typed })
        #expect(rows.contains { if case .note = $0 { return true } else { return false } })
    }

    // MARK: - scope

    @Test("a scope narrows both the corpus and what typing offers")
    func scopesNarrow() {
        let recents = [recent(.command, "htop", at: 1), recent(.url, "https://h.example", at: 2)]
        let pages = [page("https://hn.example", "Hacker news", at: 3)]
        let sessions = [session("dddd4444", "htop watcher")]

        let onlyPages = build("h", scope: .pages, recents: recents, pages: pages, sessions: sessions)
        #expect(actions(onlyPages).allSatisfy { if case .open = $0 { return true } else { return false } })

        let onlyCommands = build("h", scope: .commands, recents: recents, pages: pages, sessions: sessions)
        #expect(actions(onlyCommands).allSatisfy { if case .run = $0 { return true } else { return false } })

        let onlySessions = build("h", scope: .sessions, recents: recents, pages: pages, sessions: sessions)
        // Plus the typed row, which in this scope means "start it, since it is
        // not running" — the old attach picker's launch rows, kept.
        #expect(actions(onlySessions) == [.run("h", at: .local), .attach("dddd4444")])
    }

    @Test("⇥ walks every scope and comes back")
    func scopeCycles() {
        var scope = OmniScope.everything
        var seen: [OmniScope] = []
        for _ in OmniScope.allCases {
            seen.append(scope)
            scope = scope.next
        }
        #expect(scope == .everything)
        #expect(Set(seen).count == OmniScope.allCases.count)
    }

    // MARK: - one row per thing

    @Test("a page you launched from a terminal is one row, not two")
    func dedupe() {
        // `maxpane open x` writes a Recent *and* a visit. Without the merge the
        // same page appears twice, each taking a numeric shortcut.
        let rows = build(
            "example",
            recents: [recent(.url, "https://www.example.com/en", at: 900)],
            pages: [page("https://www.example.com/en", "Example Domain", at: 100, count: 12)])
        let corpus = rows.compactMap(\.candidate).filter { $0.kind != .typed }
        #expect(corpus.count == 1)
        // The richer description survives, and the later of the two timestamps.
        #expect(corpus[0].headline == "Example Domain")
        #expect(corpus[0].count == 12)
        #expect(corpus[0].chosenAt == 900)
    }

    @Test("the scheme is not part of what makes two rows the same page")
    func dedupeIgnoresScheme() {
        let rows = build(
            "example",
            recents: [recent(.url, "example.com", at: 900)],
            pages: [page("https://example.com", "Example", at: 100)])
        #expect(rows.compactMap(\.candidate).filter { $0.kind != .typed }.count == 1)
    }

    // MARK: - numbering

    @Test("every row that can be launched gets a number, and headings do not")
    func numbersSkipHeadings() {
        let rows = build("", recents: (1...4).map { recent(.command, "cmd \($0)", at: Int64($0)) })
        let shortcuts = OmniRanking.shortcuts(for: rows)
        for (index, row) in rows.enumerated() {
            #expect(row.isSelectable == (shortcuts[index] != nil),
                    "row \(index) numbering disagrees with whether it can be launched")
        }
        #expect(shortcuts.count == 4)
    }

    @Test("numbers run 1…9 then 0, and stop")
    func numberingRunsOutAtTen() {
        let rows = build("", recents: (1...14).map { recent(.command, "cmd \($0)", at: Int64($0)) })
        let shortcuts = OmniRanking.shortcuts(for: rows)
        #expect(shortcuts.count == 10, "there are only ten digits")
        #expect(OmniRanking.label(forShortcut: 0) == "1")
        #expect(OmniRanking.label(forShortcut: 9) == "0")
    }

    @Test("numbers follow the rows on screen, not the underlying history")
    func numbersFollowWhatIsVisible() {
        // Whatever is third on screen is ⌘3 — the alternative is a number that
        // means something different depending on what you have typed.
        let rows = build("beta", recents: [
            recent(.command, "alpha", at: 3),
            recent(.command, "beta", at: 2),
            recent(.command, "gamma", at: 1),
        ])
        let shortcuts = OmniRanking.shortcuts(for: rows)
        let numbered = rows.enumerated()
            .compactMap { index, row in shortcuts[index].map { ($0, row) } }
            .sorted { $0.0 < $1.0 }
        #expect(numbered.count == 3)      // run, open, and the one match
        #expect(numbered.last?.1.candidate?.action == .run("beta", at: .local))
    }

    // MARK: - what counts as a URL

    @Test("addresses are recognised", arguments: [
        "https://example.com", "http://localhost:8080", "example.com", "docs.rs/tokio",
        "localhost:3000", "127.0.0.1:5173", "news.ycombinator.com/item?id=1",
    ])
    func recognisesAddresses(_ text: String) {
        #expect(OmniText.looksLikeURL(text))
    }

    @Test("commands are not mistaken for addresses", arguments: [
        "make", "npm test", "git status", "./configure", "cargo build --release",
        "vim src/main.rs", "cat README.md", ".zshrc", "ls", "main.rs", "Cargo.toml",
    ])
    func leavesCommandsAlone(_ text: String) {
        #expect(!OmniText.looksLikeURL(text))
    }

    @Test("a URL's handle is the part a person would type")
    func handles() {
        #expect(OmniText.handle("https://www.example.com/en") == "example.com/en")
        #expect(OmniText.handle("example.com") == "example.com")
        #expect(OmniText.handle("http://localhost:3000/x") == "localhost:3000/x")
    }
}

/// The seam: Swift calls the core, the core writes SQLite, and the picker
/// builds real views out of what comes back.
///
/// The Rust tests prove the record is right. This proves the app can reach it —
/// a wrapper that marshals the wrong way, or a row that crashes on a page with
/// no title, is invisible to both the Rust suite and a screenshot.
@Suite("omni picker through the store")
@MainActor
struct OmniStoreTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-omni-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    @Test("a visit recorded through the store is found by title and by URL")
    func roundTrip() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id

        store.recordVisit(
            paneId: pane, url: "https://www.example.com/en", title: "Example Domain",
            redirectChain: ["https://example.com"])

        #expect(store.historyCount == 1)
        #expect(store.history("domain").first?.url == "https://www.example.com/en")
        #expect(store.history("www.example").first?.title == "Example Domain")
        // The address that was typed, which a redirect would otherwise lose.
        #expect(store.history("example.com").count == 1)
    }

    @Test("a late title reaches the record without counting a second visit")
    func lateTitle() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id

        store.recordVisit(paneId: pane, url: "https://example.com/a", title: nil)
        store.noteVisitTitle(url: "https://example.com/a", title: "Arrived Late")
        #expect(store.history("").first?.title == "Arrived Late")
        #expect(store.history("").first?.visitCount == 1)
        // A nil URL is what a pane that has not loaded anything hands over.
        store.noteVisitTitle(url: nil, title: "Nowhere")
        #expect(store.historyCount == 1)
    }

    @Test("forgetting a page removes it from what the picker would show")
    func forget() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        store.recordVisit(paneId: pane, url: "https://a.example", title: "A")
        store.recordVisit(paneId: pane, url: "https://b.example", title: "B")

        store.forgetVisit("https://a.example")
        #expect(store.history("").map(\.url) == ["https://b.example"])
        store.clearHistory()
        #expect(store.historyCount == 0)
    }

    @Test("the footer's page count describes the search, not the table")
    func searchableCountIsHonest() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        store.recordVisit(paneId: pane, url: "https://a.example", title: "A")
        // The two agree now and always: the scan cap is gone, so every page on
        // record is a page a query can reach.
        #expect(store.searchableHistoryCount == store.historyCount)
        #expect(store.searchableHistoryCount == 1)
    }

    @Test("every row the picker can produce builds a real view")
    func rowsRender() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.newWebLane(url: "https://example.com", near: nil)
        let pane = store.state.lanes[0].panes[0].id
        store.recordVisit(paneId: pane, url: "https://titled.example/x", title: "A Titled Page")
        // No title, and a long URL — the row that has the least to work with.
        store.recordVisit(
            paneId: pane,
            url: "https://untitled.example/" + String(repeating: "a/", count: 60), title: nil)
        store.noteRecent(.command, "cargo test --workspace", cwd: "/tmp")

        let sessions = [SessionTelemetry(
            sessionId: "eeee5555", title: "claude", cwd: "/tmp", command: "claude",
            state: .blocked, lastActivity: Date())]

        for scope in OmniScope.allCases {
            for query in ["", "titled", "zzqq"] {
                let rows = OmniRanking.build(
                    query: query, scope: scope,
                    recents: store.recents(limit: 60),
                    pages: scope.wantsPages ? store.history(query, limit: 80) : [],
                    bookmarks: scope.wantsPages ? store.searchBookmarks(query) : [],
                    sessions: sessions,
                    destination: "→ new lane")
                #expect(!rows.isEmpty, "“\(query)” in \(scope.title) produced no rows at all")
                for (index, row) in rows.enumerated() {
                    let view: NSView
                    switch row {
                    case .section(let title, let note):
                        view = PaletteSectionRow(title: title, note: note)
                    case .note(let title, let detail):
                        view = PaletteSectionRow(title: title, note: detail)
                    case .item(let candidate):
                        view = OmniPickerRow(candidate: candidate, query: query, shortcut: "\(index)")
                    }
                    view.frame = NSRect(x: 0, y: 0, width: 780, height: 42)
                    view.layoutSubtreeIfNeeded()
                    #expect(!view.subviews.isEmpty)
                }
            }
        }
    }
}

/// A picture of the picker, for the same reason `LaneHeaderRenderTests` takes
/// one: the rules about what a row says are testable, and whether the result is
/// legible is not. Gated on an environment variable so it costs nothing in a
/// normal run.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("omni picker rendering")
@MainActor
struct OmniPickerRenderTests {
    @Test("renders the rows that have the least to work with")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        let pages: [HistoryEntry] = [
            HistoryEntry(url: "https://doc.rust-lang.org/std/collections/struct.HashMap.html",
                         title: "HashMap in std::collections - Rust",
                         firstVisitAt: 0, lastVisitAt: nowMs(-42), visitCount: 12,
                         matchedField: .title, score: 300),
            HistoryEntry(url: "https://github.com/anthropics/claude-code/pull/4821/files#diff-9f2a",
                         title: nil, firstVisitAt: 0, lastVisitAt: nowMs(-3600 * 5),
                         visitCount: 1, matchedField: .url, score: 60),
        ]
        let recents = [
            Recent(kind: .command, value: "cargo test --workspace -- --nocapture",
                   cwd: NSHomeDirectory() + "/code/max-pane",
                   lastUsedAt: nowMs(-120), useCount: 31),
        ]
        let sessions = [
            SessionTelemetry(
                sessionId: "9f2ab7c10000", title: "claude · gauntlet piece 9",
                cwd: NSHomeDirectory() + "/code/max-pane", command: "claude",
                state: .blocked, bytesPerSecond: 0, lastActivity: Date(timeIntervalSinceNow: -9)),
        ]
        // A kept page in a folder: the row whose detail line has to carry two
        // things in a column that fits one.
        let bookmarks = [
            BookmarkHit(
                bookmark: Bookmark(
                    id: "bm1", parentId: "f1", isFolder: false,
                    url: "https://doc.rust-lang.org/std/collections/struct.HashMap.html",
                    title: "HashMap — the one I always reopen",
                    position: 0, addedAt: nowMs(-3600 * 24 * 90), depth: 1),
                folderPath: "Rust/Standard Library", matchedField: .title, score: 30_000),
        ]

        for width in [600.0, 780.0] as [CGFloat] {
            let rows = OmniRanking.build(
                query: "ha", scope: .everything, recents: recents, pages: pages,
                bookmarks: bookmarks, sessions: sessions, destination: "→ new lane")
            let shortcuts = OmniRanking.shortcuts(for: rows)
            let heights = rows.map { $0.isSelectable ? 42.0 : 26.0 as CGFloat }
            let sheet = NSView(frame: NSRect(
                x: 0, y: 0, width: width, height: heights.reduce(0, +) + 12))
            sheet.wantsLayer = true
            sheet.layer?.backgroundColor = Theme.laneBackground.cgColor

            var y = sheet.bounds.height - 6
            for (index, (row, height)) in zip(rows, heights).enumerated() {
                let view: NSView
                switch row {
                case .section(let title, let note): view = PaletteSectionRow(title: title, note: note)
                case .note(let title, let detail): view = PaletteSectionRow(title: title, note: detail)
                case .item(let candidate):
                    view = OmniPickerRow(
                        candidate: candidate, query: "ha",
                        shortcut: shortcuts[index].map(OmniRanking.label(forShortcut:)))
                }
                y -= height
                view.frame = NSRect(x: 0, y: y, width: width, height: height)
                sheet.addSubview(view)
                view.layoutSubtreeIfNeeded()
            }
            guard let rep = sheet.bitmapImageRepForCachingDisplay(in: sheet.bounds) else { return }
            sheet.cacheDisplay(in: sheet.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("omni-\(Int(width)).png"))
        }
    }

    private func nowMs(_ secondsAgo: Double) -> Int64 {
        Int64((Date().timeIntervalSince1970 + secondsAgo) * 1000)
    }
}


// MARK: - kept pages in the one door

/// A bookmark is a page, so it is offered by the door pages are offered by —
/// and it outranks the visit of the same address, because the title on it is
/// the one the user chose.
@Suite("⌘O offers what you have kept")
@MainActor
struct OmniBookmarkTests {
    private func kept(_ url: String, _ title: String, folder: String? = nil, at: Int64 = 0)
        -> BookmarkHit
    {
        BookmarkHit(
            bookmark: Bookmark(
                id: "bm-" + url, parentId: folder, isFolder: false, url: url, title: title,
                position: 0, addedAt: at, depth: folder == nil ? 0 : 1),
            folderPath: folder, matchedField: .title, score: 0)
    }

    private func page(_ url: String, _ title: String?, at: Int64 = 0) -> HistoryEntry {
        HistoryEntry(
            url: url, title: title, firstVisitAt: at, lastVisitAt: at,
            visitCount: 1, matchedField: .url, score: 0)
    }

    private func build(
        _ query: String, scope: OmniScope = .everything,
        pages: [HistoryEntry] = [], bookmarks: [BookmarkHit] = []
    ) -> [OmniRow] {
        OmniRanking.build(
            query: query, scope: scope, recents: [], pages: pages,
            bookmarks: bookmarks, sessions: [], destination: "→ new lane")
    }

    @Test("a kept page is a row, marked as kept")
    func keptPagesAreOffered() {
        let rows = build("board", bookmarks: [kept("https://board.example.com/x", "The board")])
        let hit = rows.compactMap(\.candidate).first { $0.kind == .bookmark }
        #expect(hit != nil)
        #expect(hit?.headline == "The board")
        // The star is the mark. The tag column says what Return costs, and a
        // kept page costs what any page costs.
        #expect(OmniPickerRow.glyph(hit!) == "★")
        #expect(OmniPickerRow.tag(hit!) == "")
    }

    /// The merge that matters: the same address is in both corpora, and one row
    /// comes back carrying the name the user gave it.
    @Test("a page that is both kept and visited is one row, and it is the bookmark")
    func keptBeatsVisited() {
        let rows = build(
            "board",
            pages: [page("https://board.example.com/x", "board.example.com | Sign in")],
            bookmarks: [kept("https://board.example.com/x", "The board", folder: "Work")])
        let hits = rows.compactMap(\.candidate).filter {
            if case .open(let u) = $0.action { return u.contains("board.example") }
            return false
        }
        #expect(hits.count == 1, "the same address was offered twice")
        #expect(hits[0].headline == "The board")
        #expect(hits[0].detail.hasPrefix("Work · "), "which folder it is in is half of the row")
    }

    /// `notes` twice is exactly the case a bare address cannot answer.
    @Test("two bookmarks with the same name are told apart by their folder")
    func folderIsTheDisambiguator() {
        let rows = build(
            "notes",
            bookmarks: [
                kept("https://a.example/notes", "Notes", folder: "Work/Rust"),
                kept("https://b.example/notes", "Notes"),
            ])
        let details = rows.compactMap(\.candidate).filter { $0.kind == .bookmark }.map(\.detail)
        #expect(details.contains { $0.hasPrefix("Work/Rust · ") })
        #expect(details.contains { $0 == "https://b.example/notes" })
    }

    @Test("the commands scope does not offer pages you have kept")
    func scopeIsRespected() {
        let rows = build(
            "board", scope: .commands,
            bookmarks: [kept("https://board.example.com/x", "The board")])
        #expect(!rows.compactMap(\.candidate).contains { $0.kind == .bookmark })
    }
}
