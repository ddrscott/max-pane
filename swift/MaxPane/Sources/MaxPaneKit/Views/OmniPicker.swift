import AppKit
import LanedCore

/// What a row does when you press Return. Three verbs, because there are three
/// ways a thing can start existing on the strip and no more.
enum OmniAction: Equatable {
    /// Run this command line in a new terminal.
    case run(String, cwd: String?)
    /// Open this in a web pane. The scheme is optional here and added later —
    /// `StripWindowController.normalizeURL` is the one place that decides.
    case open(String)
    /// Put an already-running Relay session on the strip.
    case attach(String)
}

/// Which corpora ⌘O is looking at.
///
/// A scope, not a separate palette. ⌘Y and ⌥⌘O are the same window with a
/// different scope pre-selected, and ⇥ cycles — because "pages only" is a
/// narrowing of one question, not a second question, and the old ⌘Y and ⌘O were
/// two windows that looked alike and answered overlapping questions.
enum OmniScope: CaseIterable, Sendable {
    case everything
    case pages
    case commands
    case sessions

    var title: String {
        switch self {
        case .everything: return "EVERYTHING"
        case .pages: return "PAGES"
        case .commands: return "COMMANDS"
        case .sessions: return "SESSIONS"
        }
    }

    var placeholder: String {
        switch self {
        case .everything: return "Run, open, or find anything…"
        case .pages: return "Open a page, or search history…"
        case .commands: return "Run a command…"
        case .sessions: return "Attach a Relay session…"
        }
    }

    var next: OmniScope {
        let all = OmniScope.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    var wantsPages: Bool { self == .everything || self == .pages }
    var wantsCommands: Bool { self == .everything || self == .commands }
    var wantsSessions: Bool { self == .everything || self == .sessions }

    /// What the typed text launches, in the order it is offered.
    ///
    /// Both readings are always reachable in `.everything` — the rule
    /// `NewPanePicker` established and the reason a wrong guess about
    /// `localhost:3000` costs nothing. A narrowed scope offers only the reading
    /// it is about, because in `.pages` the user has already said which one they
    /// meant; and `.sessions` offers the command, because "the session I want is
    /// not running" is answered by starting it, which is what the old attach
    /// picker's launch rows were for.
    func typedActions(_ text: String) -> [OmniAction] {
        switch self {
        case .pages: return [.open(text)]
        case .commands, .sessions: return [.run(text, cwd: nil)]
        case .everything:
            return OmniText.looksLikeURL(text)
                ? [.open(text), .run(text, cwd: nil)]
                : [.run(text, cwd: nil), .open(text)]
        }
    }
}

/// One thing ⌘O can start, with everything the ranking and the row need.
struct OmniCandidate: Equatable {
    enum Kind: Equatable { case typed, command, page, session }

    var action: OmniAction
    var kind: Kind
    /// The line you read first: a command line, a page title, a session title.
    var headline: String
    /// The line underneath: a URL, the directory, the session id and argv.
    var detail: String
    var quality: MatchQuality
    /// Epoch ms of the last time the user *chose* this. See `OmniRanking`.
    var chosenAt: Int64
    /// How many times, or 0 for "do not print a number".
    var count: UInt32
    /// Sessions only; carries the chip and the liveness dot.
    var telemetry: SessionTelemetry?

    var urgent: Bool { telemetry.map { $0.isRunning && $0.needsAttention } ?? false }

    /// One row per thing, however many sources describe it. `maxpane open x`
    /// writes a `Recent` *and* a visit, so without this every page you launched
    /// from a terminal appears twice.
    var identity: String {
        switch action {
        case .open(let url): return "url:" + OmniText.handle(url).lowercased()
        case .run(let line, _): return "cmd:" + line
        case .attach(let id): return "ses:" + id
        }
    }
}

/// A line in the picker.
enum OmniRow: Equatable {
    case section(title: String, note: String)
    case item(OmniCandidate)
    /// Scenery that says why the list is empty — never an empty box, which
    /// looks exactly like a broken one.
    case note(title: String, detail: String)

    var isSelectable: Bool {
        if case .item = self { return true }
        return false
    }

    var candidate: OmniCandidate? {
        if case .item(let c) = self { return c }
        return nil
    }
}

/// The rule, and the whole of it.
///
/// # What the owner is reaching for
///
/// ⌘O is a verb. He pressed it because he decided to start something, and the
/// question the list has to answer is "which of the things I have started
/// before did I mean". That decides everything below.
///
/// # The rule
///
/// 1. **What you typed, as typed, is rows one and two, and is never ranked.**
///    It is the only row the picker cannot get wrong, and pinning it is what
///    makes ⌘O ↩ mean the same thing every time. A corpus row can be first only
///    when you have typed nothing at all.
/// 2. **Everything else is ordered by `MatchQuality`** — prefix, then word
///    start, then substring, then a scattered guess. That axis is a property of
///    the match, so it means the same thing for a command, a page and a session,
///    which is exactly what a raw score cannot do across three scorers.
/// 3. **A guess never shares the list with a literal hit.** If anything matched
///    properly, the coincidences are dropped outright — over two thousand pages
///    there are always dozens of them, and they are what made the old history
///    palette read as noise. When nothing matched properly they are all there
///    is, which is what keeps `mxp` finding `max-pane`.
/// 4. **Inside a band, ties break by when you last chose it.** Timestamps are
///    the one number every source honestly has: `last_used_at`, `last_visit_at`,
///    and for a session the last time it moved.
/// 5. **A session waiting on a human leads its band** — the rule
///    `PaletteFilter` already applies to the sidebar's picker, kept here so the
///    two cannot disagree.
///
/// # What was rejected
///
/// - **One weighted score across sources.** History is scored in Rust, sessions
///   and recents by `Fuzzy` here; the weights that make them comparable are
///   invented numbers that go wrong silently as the corpora grow at different
///   rates, and "why is this ninth" becomes unanswerable.
/// - **Strict source priority** (sessions, then recents, then history). With ten
///   sessions open, typing `git` puts three irrelevant sessions above the page
///   you wanted. It manufactures the exact failure it was meant to avoid.
/// - **Frecency.** Every browser's omnibox does it and nobody can explain any
///   individual result. `Recent` and `history::rank` both refused it already;
///   refusing it a third time keeps the app's one story about ordering.
/// - **Blocked sessions pinned to the very top.** Tempting — a blocked agent is
///   the most urgent thing in this app. But it would mean ⌘O ↩ does something
///   different depending on what an agent did five seconds ago, and the sidebar
///   already carries that signal permanently, in colour, with a BLOCKED chip.
///   Urgency is the sidebar's job; intent is ⌘O's. Blocked still leads its band
///   once you have typed something that matches it, and the footer counts it.
///
/// # Where the ranking runs
///
/// Split, and deliberately. Rust filters — it decides which eighty of two
/// thousand pages are even candidates, because that corpus never crosses the
/// FFI (`history.rs` explains why). Swift merges — it decides how those eighty
/// interleave with forty recents and a dozen sessions, which are already in
/// memory here and whose telemetry is a `@MainActor` thing Rust cannot see.
/// Nothing is ranked twice: the Rust score is never compared against anything
/// computed here. Only `MatchQuality`, recomputed over the rows that came back,
/// crosses the boundary — eighty short strings per keystroke, which is nothing.
enum OmniRanking {
    /// How many rows carry a numeric shortcut: 1…9 then 0.
    static let numbered = 10

    /// How many corpus rows to show. Past this the list is a scroll, not a
    /// choice, and the numbers have run out anyway.
    static let shown = 24

    static func build(
        query: String,
        scope: OmniScope,
        recents: [Recent],
        pages: [HistoryEntry],
        sessions: [SessionTelemetry],
        destination: String
    ) -> [OmniRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [OmniRow] = []

        if !trimmed.isEmpty {
            rows.append(.section(title: "LAUNCH", note: destination))
            rows.append(contentsOf: scope.typedActions(trimmed).map {
                .item(OmniCandidate(
                    action: $0, kind: .typed,
                    headline: trimmed, detail: "",
                    quality: .typed, chosenAt: 0, count: 0, telemetry: nil))
            })
        }

        var corpus = candidates(query: trimmed, scope: scope, recents: recents, pages: pages)
        // Attached sessions are not offered. ⌘O starts things; a session already
        // on the strip has started, and finding it again is ⌘P's question. The
        // footer still counts them, because hiding them *and* miscounting them
        // is what made the picker before last lie about how many sessions exist.
        let startable = sessions.filter { !$0.isAttached }

        guard !trimmed.isEmpty else {
            return rows + emptyQueryRows(
                corpus: corpus, sessions: startable, scope: scope, destination: destination)
        }

        if scope.wantsSessions {
            corpus += startable.compactMap { session(trimmed, $0) }
        }
        corpus = dedupe(corpus)
        // Rule 3.
        if corpus.contains(where: { $0.quality.isLiteral }) {
            corpus.removeAll { !$0.quality.isLiteral }
        }
        // Rules 2, 5, 4 — in that order, which is the order of the tuple.
        corpus.sort {
            if $0.quality != $1.quality { return $0.quality < $1.quality }
            if $0.urgent != $1.urgent { return $0.urgent }
            return $0.chosenAt > $1.chosenAt
        }
        corpus = Array(corpus.prefix(shown))

        if corpus.isEmpty {
            rows.append(.note(
                title: scope.title,
                detail: "nothing you have started matches “\(trimmed)”"))
        } else {
            rows.append(.section(title: "MATCHES", note: destination))
            rows.append(contentsOf: corpus.map(OmniRow.item))
        }
        return rows
    }

    /// With nothing typed there is no evidence, so the picker does not pretend
    /// to rank: it lists what you last started, newest first, whatever kind it
    /// is. ⌘O ⌘1 is then always "the last thing I launched".
    ///
    /// Sessions are held out of that list rather than merged into it. Their only
    /// timestamp is the last time they produced output, which is an agent
    /// talking to itself rather than the user choosing anything — merged in, a
    /// chatty background agent would reshuffle the top of the list every second.
    private static func emptyQueryRows(
        corpus: [OmniCandidate], sessions: [SessionTelemetry], scope: OmniScope,
        destination: String
    ) -> [OmniRow] {
        var rows: [OmniRow] = []
        let recent = Array(dedupe(corpus).sorted { $0.chosenAt > $1.chosenAt }.prefix(shown))
        if !recent.isEmpty {
            rows.append(.section(title: "RECENT", note: destination))
            rows.append(contentsOf: recent.map(OmniRow.item))
        }
        guard scope.wantsSessions else {
            if rows.isEmpty {
                rows.append(.note(title: scope.title, detail: "nothing started yet"))
            }
            return rows
        }

        // Blocked first and under their own header, so a session that has
        // stopped to ask you something is not a grey line among twelve others —
        // but below RECENT, so what ↩ does never depends on an agent's timing.
        let ordered = sessions.sorted {
            if $0.state.rank != $1.state.rank { return $0.state.rank < $1.state.rank }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
        let blocked = ordered.filter { $0.isRunning && $0.needsAttention }
        let rest = ordered.filter { !($0.isRunning && $0.needsAttention) }
        if !blocked.isEmpty {
            rows.append(.section(title: "WAITING ON YOU", note: "\(blocked.count) blocked"))
            rows.append(contentsOf: blocked.compactMap { session("", $0) }.map(OmniRow.item))
        }
        if !rest.isEmpty {
            rows.append(.section(title: "NOT ON THE STRIP", note: "\(rest.count) sessions"))
            rows.append(contentsOf: rest.compactMap { session("", $0) }.map(OmniRow.item))
        }
        if rows.isEmpty {
            rows.append(.note(title: scope.title, detail: "nothing started yet"))
        }
        return rows
    }

    /// Pages and commands, scored. Sessions are added separately because they
    /// are the one source with no timestamp of a user's choice.
    private static func candidates(
        query: String, scope: OmniScope, recents: [Recent], pages: [HistoryEntry]
    ) -> [OmniCandidate] {
        var out: [OmniCandidate] = []
        if scope.wantsPages {
            // Already ranked and cut in Rust; what is recomputed here is only
            // the quality band, so a page can be compared with a command.
            out += pages.compactMap { page(query, $0) }
        }
        for recent in recents {
            switch recent.kind {
            case .command where scope.wantsCommands:
                guard let quality = MatchQuality.of(query, inAny: [recent.value]) else { continue }
                out.append(OmniCandidate(
                    action: .run(recent.value, cwd: recent.cwd),
                    kind: .command,
                    headline: recent.value,
                    detail: recent.cwd.map(OmniText.tilde) ?? "",
                    quality: quality,
                    chosenAt: recent.lastUsedAt,
                    count: recent.useCount,
                    telemetry: nil))
            case .url where scope.wantsPages:
                guard let quality = MatchQuality.of(query, inAny: [OmniText.handle(recent.value)])
                else { continue }
                out.append(OmniCandidate(
                    action: .open(recent.value),
                    kind: .page,
                    headline: OmniText.handle(recent.value),
                    detail: recent.value,
                    quality: quality,
                    chosenAt: recent.lastUsedAt,
                    count: recent.useCount,
                    telemetry: nil))
            default:
                continue
            }
        }
        return out
    }

    private static func page(_ query: String, _ entry: HistoryEntry) -> OmniCandidate? {
        let name = entry.title.flatMap { $0.isEmpty ? nil : $0 } ?? OmniText.handle(entry.url)
        // The URL is matched without its scheme, for the reason `search_handle`
        // gives in Rust: `http` is otherwise a prefix of the entire table.
        guard let quality = MatchQuality.of(query, inAny: [name, OmniText.handle(entry.url)])
        else { return nil }
        return OmniCandidate(
            action: .open(entry.url),
            kind: .page,
            headline: name,
            detail: entry.url,
            quality: quality,
            chosenAt: entry.lastVisitAt,
            count: entry.visitCount,
            telemetry: nil)
    }

    private static func session(_ query: String, _ t: SessionTelemetry) -> OmniCandidate? {
        let name = t.title.isEmpty ? t.command : t.title
        guard let quality = MatchQuality.of(query, inAny: [name, t.command, t.groupPath])
        else { return nil }
        let short = String(t.sessionId.prefix(8))
        let repeats = name.hasPrefix(t.command) || t.command.isEmpty
        return OmniCandidate(
            action: .attach(t.sessionId),
            kind: .session,
            headline: name.isEmpty ? short : name,
            detail: repeats ? "\(short) · \(t.groupPath)" : "\(short) · \(t.command)",
            quality: quality,
            chosenAt: Int64((t.lastActivity?.timeIntervalSince1970 ?? 0) * 1000),
            count: 0,
            telemetry: t)
    }

    /// Merge rows that start the same thing, keeping the richer description.
    ///
    /// A page beats a bare recent URL because it carries a title and a visit
    /// count; the timestamps are maxed, because the later of "you launched it"
    /// and "you visited it" is when you last chose it either way.
    static func dedupe(_ candidates: [OmniCandidate]) -> [OmniCandidate] {
        var order: [String] = []
        var best: [String: OmniCandidate] = [:]
        for candidate in candidates {
            let key = candidate.identity
            guard let existing = best[key] else {
                order.append(key)
                best[key] = candidate
                continue
            }
            var merged = hasName(candidate) && !hasName(existing) ? candidate : existing
            merged.chosenAt = max(existing.chosenAt, candidate.chosenAt)
            merged.quality = min(existing.quality, candidate.quality)
            merged.count = max(existing.count, candidate.count)
            best[key] = merged
        }
        return order.compactMap { best[$0] }
    }

    /// True when the headline says something the detail line does not — a page
    /// with a `<title>`, as against a URL printed twice.
    private static func hasName(_ candidate: OmniCandidate) -> Bool {
        !candidate.detail.isEmpty && candidate.headline != OmniText.handle(candidate.detail)
    }

    /// The digit that launches a row, or nil past the tenth.
    ///
    /// Numbers follow the *visible* rows, so filtering renumbers: whatever is
    /// third on screen is ⌘3, which is the only rule that survives typing.
    static func shortcuts(for rows: [OmniRow]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var next = 0
        for (index, row) in rows.enumerated() where row.isSelectable {
            guard next < numbered else { break }
            map[index] = next
            next += 1
        }
        return map
    }

    /// `1`…`9`, then `0` for the tenth.
    static func label(forShortcut index: Int) -> String {
        index == 9 ? "0" : String(index + 1)
    }
}

/// Text rules shared by the picker, the ranking and the rows.
enum OmniText {
    /// Is this more likely an address than a command?
    ///
    /// Deliberately conservative, and unchanged from the ⌘T picker it came
    /// from — `git status` is not a URL, `example.com` is, and `make` is a
    /// command because a single bare word with no dot is overwhelmingly
    /// something you run. Getting it wrong is cheap anyway: the other reading is
    /// always the row underneath.
    static func looksLikeURL(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return true }
        // A dot with something either side, and no leading dot: `foo.com`,
        // but not `./configure` or `.zshrc`.
        guard let dot = text.firstIndex(of: "."), dot != text.startIndex else { return false }
        guard text.index(after: dot) < text.endIndex else { return false }

        // The first segment is the part that would be a host.
        let head = text.split(separator: "/").first.map(String.init) ?? text
        let hasPath = text.contains("/")

        // `docs.rs/tokio` is a site and `main.rs` is a file, and the extension
        // alone cannot tell them apart — `.rs` is both a crate's docs and a
        // Rust source file. What separates them is the path: a dotted name
        // followed by more path is an address, a dotted name on its own is a
        // file if its extension says so.
        if hasPath { return head.contains(".") }
        let ext = head.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return !Self.fileExtensions.contains(ext)
    }

    /// Extensions that mean "a file in this repo", not "a site".
    private static let fileExtensions: Set<String> = [
        "rs", "swift", "ts", "tsx", "js", "jsx", "py", "go", "rb", "c", "h", "cpp", "hpp",
        "java", "kt", "sh", "zsh", "bash", "json", "toml", "yaml", "yml", "md", "txt",
        "lock", "sql", "html", "css", "png", "jpg", "svg", "pdf",
    ]

    /// A URL with the parts nobody types stripped off. The Swift half of
    /// `history::search_handle`, and it must agree with it: `http` as a query
    /// would otherwise be a prefix match against every page on record.
    static func handle(_ url: String) -> String {
        var rest = url
        if let range = rest.range(of: "://") { rest = String(rest[range.upperBound...]) }
        if rest.hasPrefix("www.") { rest = String(rest.dropFirst(4)) }
        return rest
    }

    /// `/Users/me/code/x` reads as `~/code/x`, which is how it is said out loud.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// ⌘O — the one place anything starts.
///
/// # Why this replaced three pickers
///
/// ⌘T opened a new-pane picker, ⌘Y a history palette, ⌘O a session picker.
/// All three answered "bring something new in" and each could only see a third
/// of the answer: ⌘T + `zebra` offered to run `zebra` and to open `zebra`, and
/// said nothing about the page titled *Quilted Zebra Almanac* you read
/// yesterday — which, in a browser, is how history gets used nearly all of the
/// time. Three doors to one room, and the room was different behind each door.
///
/// # Why ⌘P is still its own thing
///
/// A reader will ask why ⌘P was not folded in too, since it also has a text
/// field and a list. Because it answers a different question. ⌘O is "start
/// something"; ⌘P is "where is the thing that is already on the strip" — every
/// one of its hits is a lane that exists, and choosing one scrolls to it rather
/// than creating anything. Merging them would mean a list where Return
/// sometimes spends a WebView and a Relay session and sometimes just scrolls,
/// with nothing in the row to tell you which, and that is exactly the
/// indistinguishable-verbs problem this consolidation exists to remove.
@MainActor
final class OmniPicker: PaletteController {
    private let store: StripStore
    private let registry: SessionRegistry
    private let destination: String
    private let completion: (OmniAction?) -> Void
    private var scope: OmniScope
    private var rows: [OmniRow] = []
    private var shortcuts: [Int: Int] = [:]
    /// Read once, for the reason the ⌘T picker read them once: the list cannot
    /// change while the picker is open and re-reading would hit SQLite for every
    /// character. History is *not* cached here — that corpus stays in Rust and
    /// only the rows that survive a query cross the FFI.
    private var recents: [Recent]
    private var pageCount: UInt32
    private var searchable: UInt32
    private var token: UUID?

    init(
        store: StripStore,
        registry: SessionRegistry,
        scope: OmniScope = .everything,
        destination: String,
        completion: @escaping (OmniAction?) -> Void
    ) {
        self.store = store
        self.registry = registry
        self.scope = scope
        self.destination = destination
        self.completion = completion
        self.recents = store.recents(limit: 60)
        self.pageCount = store.historyCount
        self.searchable = store.searchableHistoryCount
        super.init(placeholder: scope.placeholder, size: NSSize(width: 780, height: 520))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func present(over parent: NSWindow?) {
        // A session that starts blocking while the picker is open is the one you
        // want; the old attach picker watched for that and losing it would be a
        // regression in the half of ⌘O that came from there.
        token = registry.observe { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.rebuild()
            self.refreshKeepingSelection()
            self.updateFooter()
        }
        super.present(over: parent)
    }

    override func dismiss(selected: Int) {
        if let token { registry.stopObserving(token) }
        token = nil
        super.dismiss(selected: selected)
    }

    override func reload() {
        rebuild()
        super.reload()
        updateFooter()
    }

    private func rebuild() {
        // No debounce, for the reason ⌘P and ⌘Y have none: Rust scores a bounded
        // window and hands back a bounded list, and everything else in the merge
        // is already in memory. A keystroke costs a query, not a corpus.
        //
        // 80 rather than the old 60: Swift re-bands what comes back and then
        // drops the scattered guesses, so the list has to arrive with enough
        // literal matches in it to survive that.
        let pages = scope.wantsPages ? store.history(query, limit: 80) : []
        rows = OmniRanking.build(
            query: query,
            scope: scope,
            recents: recents,
            pages: pages,
            sessions: Array(registry.sessions.values),
            destination: destination)
        shortcuts = OmniRanking.shortcuts(for: rows)
    }

    override func numberOfRows() -> Int { rows.count }

    override func isSelectable(row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    override func height(forRow row: Int) -> CGFloat {
        guard row < rows.count else { return 30 }
        switch rows[row] {
        case .section, .note: return 26
        // One height for every kind of thing, which is most of what makes this
        // read as one list rather than three lists stacked up.
        case .item: return 42
        }
    }

    override func rowIdentity(_ row: Int) -> String? {
        row < rows.count ? rows[row].candidate?.identity : nil
    }

    override func view(forRow row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .section(let title, let note):
            return PaletteSectionRow(title: title, note: note)
        case .note(let title, let detail):
            return PaletteSectionRow(title: title, note: detail)
        case .item(let candidate):
            return OmniPickerRow(
                candidate: candidate,
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                shortcut: shortcuts[row].map(OmniRanking.label(forShortcut:)))
        }
    }

    /// ⌘1…⌘0 launches a row; ⇥ changes scope; ⌘⌫ forgets one.
    override func handleKey(_ event: NSEvent) -> Bool {
        // Tab, unmodified. It does nothing else in a palette, and a scope that
        // needs a chord would never be found.
        if event.keyCode == 48, !event.modifierFlags.contains(.command) {
            scope = event.modifierFlags.contains(.shift)
                ? scope.next.next.next : scope.next
            field.placeholderString = scope.placeholder
            reload()
            return true
        }
        guard event.modifierFlags.contains(.command) else { return false }

        // ⌘⌫ unwrites a line of a list the user never chose to write. Plain ⌫ is
        // left alone: it is how you fix a typo in the query, and a list that
        // deletes rows while you are editing your search is a trap.
        if event.keyCode == 51 {
            forgetSelected()
            return true
        }
        // Plain digits are left alone: `7z` and `2fa` are commands.
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1, let digit = Int(characters)
        else { return false }
        let wanted = digit == 0 ? 9 : digit - 1
        guard let row = shortcuts.first(where: { $0.value == wanted })?.key else { return true }
        dismiss(selected: row)
        return true
    }

    private func forgetSelected() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, let candidate = rows[row].candidate else { return }
        switch candidate.action {
        case .open(let url):
            // Both stores, because a page launched from a terminal is in both
            // and forgetting one of them leaves the row on screen.
            store.forgetVisit(url)
            store.forgetRecent(.url, url)
        case .run(let line, _):
            store.forgetRecent(.command, line)
        case .attach:
            // A live session is not a memory. `relay stop` is elsewhere and on
            // purpose: nothing in a launcher should be able to kill work.
            return
        }
        recents = store.recents(limit: 60)
        pageCount = store.historyCount
        searchable = store.searchableHistoryCount
        rebuild()
        refreshKeepingSelection()
        updateFooter()
    }

    override func deliver(selected: Int) {
        guard selected >= 0, selected < rows.count else { return completion(nil) }
        completion(rows[selected].candidate?.action)
    }

    /// What the footer may claim.
    ///
    /// Only what is true of the thing being labelled. The page count is the
    /// number a query can actually *reach* — the table holds more than one
    /// search scans, and a footer reading "0 of 5013 pages" over a corpus whose
    /// two-thousandth row is unfindable is a label lying about its own list.
    private func updateFooter() {
        let matches = rows.filter(\.isSelectable).count
        // The two LAUNCH rows are what you typed, not what was found; counting
        // them as matches would claim "1 of 0 pages" over an empty ledger.
        let found = rows.filter { $0.candidate.map { $0.kind != .typed } ?? false }.count
        let startable = registry.sessions.values.filter { !$0.isAttached }.count
        let onStrip = registry.sessions.count - startable
        let commands = recents.filter { $0.kind == .command }.count

        var parts: [String] = []
        // A narrowed scope names itself and then says how much of one corpus is
        // showing; the wide scope has three corpora and so has to size them
        // separately. Either way the page number is the *reachable* count, not
        // the table's: "0 of 5013 pages" over a search that cannot see past the
        // newest couple of thousand is a footer lying about its own list.
        let pages = searchable == pageCount
            ? "\(pageCount)"
            : "\(searchable) of \(pageCount) reachable"
        switch scope {
        case .everything:
            if matches > 0, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append("\(matches) \(matches == 1 ? "row" : "rows")")
            }
            parts.append("\(pages) pages")
            parts.append("\(commands) commands")
            parts.append("\(startable) sessions")
            if onStrip > 0 { parts.append("\(onStrip) on strip") }
        case .pages:
            parts = ["pages", "\(found) of \(pages)"]
        case .commands:
            parts = ["commands", "\(found) of \(commands)"]
        case .sessions:
            parts = ["sessions", "\(found) of \(startable)"]
            if onStrip > 0 { parts.append("\(onStrip) on strip") }
        }

        let line = PaletteStyle.caps(parts.joined(separator: " · "))
        // The blocked count is the one number here that is an instruction rather
        // than a statistic, so it is the only one in the accent.
        let blocked = registry.sessions.values.filter {
            !$0.isAttached && $0.isRunning && $0.needsAttention
        }.count
        if blocked > 0 {
            let mutable = NSMutableAttributedString(attributedString: line)
            mutable.append(NSAttributedString(
                string: "  ·  \(blocked) BLOCKED",
                attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(10, weight: .bold)]))
            footerLeft.attributedStringValue = mutable
        } else {
            footerLeft.attributedStringValue = line
        }
        footerRight.stringValue = "⇥ scope   ⌘1–⌘0   ⌘⌫ forget   ↩   esc"
    }
}

/// One row, whatever it is: a number, a glyph, what it is called, what it will
/// do, and where it is.
///
/// Every kind of thing gets the same shape — the same columns at the same
/// x-positions, the same two lines. That is not decoration: a list whose rows
/// change shape by source is three lists stacked up, and the whole point of ⌘O
/// is that it is one.
final class OmniPickerRow: NSTableCellView {
    init(candidate: OmniCandidate, query: String, shortcut: String?) {
        super.init(frame: .zero)

        // The number reads as a key, not as an ordinal: its own column, dim,
        // right-aligned so 1 and 10 share an edge.
        let key = PaletteStyle.label(shortcut ?? "", Theme.mono(11, weight: .medium), Theme.dimText)
        key.alignment = .right

        let glyph = PaletteStyle.label(
            Self.glyph(candidate),
            Theme.mono(12, weight: candidate.urgent ? .bold : .medium),
            candidate.telemetry.map { PaletteStyle.glyphColor($0.state) } ?? Theme.accent)
        glyph.alignment = .center

        let literal = candidate.quality.isLiteral
        let headline = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
            candidate.headline,
            matches: MatchQuality.offsets(query, in: candidate.headline, literal: literal),
            color: candidate.telemetry.map { $0.isRunning ? .labelColor : Theme.dimText }
                ?? .labelColor))
        headline.usesSingleLineMode = true
        headline.lineBreakMode = .byTruncatingTail
        headline.translatesAutoresizingMaskIntoConstraints = false

        let tag = PaletteStyle.label(
            Self.tag(candidate), Theme.mono(9, weight: .bold),
            candidate.kind == .typed ? Theme.accent : Theme.dimText.withAlphaComponent(0.8))

        // Sessions borrow the sidebar's chip rather than inventing a second
        // vocabulary for the same state.
        let chip = PaletteStyle.chip(candidate.telemetry?.state ?? .unknown)

        let count = PaletteStyle.label(
            candidate.count > 1 ? "×\(candidate.count)" : "",
            Theme.mono(10, weight: .bold), Theme.dimText.withAlphaComponent(0.8))
        count.alignment = .right

        let age = PaletteStyle.label(
            candidate.chosenAt > 0
                ? SessionTelemetry.age(
                    since: Date(timeIntervalSince1970: Double(candidate.chosenAt) / 1000))
                : "",
            Theme.mono(11), Theme.dimText)
        age.alignment = .right

        let detail = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
            candidate.detail,
            matches: MatchQuality.offsets(query, in: candidate.detail, literal: literal),
            size: 11, color: Theme.dimText))
        detail.usesSingleLineMode = true
        // Head-truncating would hide the host, which is the half of a URL you
        // recognise; the tail is a path you have already matched on.
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false

        for v in [key, glyph, headline, tag, chip, count, age, detail] { addSubview(v) }
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            key.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            key.widthAnchor.constraint(equalToConstant: 16),

            glyph.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 10),
            glyph.firstBaselineAnchor.constraint(equalTo: headline.firstBaselineAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            headline.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            headline.firstBaselineAnchor.constraint(equalTo: key.firstBaselineAnchor),

            tag.leadingAnchor.constraint(equalTo: headline.trailingAnchor, constant: 10),
            tag.firstBaselineAnchor.constraint(equalTo: headline.firstBaselineAnchor),

            chip.leadingAnchor.constraint(greaterThanOrEqualTo: tag.trailingAnchor, constant: 10),
            chip.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: headline.centerYAnchor),

            count.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -12),
            count.firstBaselineAnchor.constraint(equalTo: headline.firstBaselineAnchor),

            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            age.widthAnchor.constraint(equalToConstant: 64),
            age.firstBaselineAnchor.constraint(equalTo: headline.firstBaselineAnchor),

            detail.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 3),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
        headline.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tag.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        count.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// `$` runs, `◍` opens, and a session wears the state glyph the sidebar
    /// gives it — so the one row in the list that is already alive looks alive.
    static func glyph(_ candidate: OmniCandidate) -> String {
        switch candidate.action {
        case .run: return "$"
        case .open: return "◍"
        case .attach: return candidate.telemetry?.state.glyph ?? "▸"
        }
    }

    /// What Return will do, spelled out, because the three verbs cost very
    /// different things — a Relay session, a WebView, or neither.
    static func tag(_ candidate: OmniCandidate) -> String {
        switch (candidate.kind, candidate.action) {
        case (.typed, .run): return "RUN"
        case (.typed, .open): return "OPEN"
        case (_, .attach): return "ATTACH"
        default: return ""
        }
    }

}
