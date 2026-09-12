import Foundation

/// Fuzzy matching and row assembly for the palettes.
///
/// Pure and AppKit-free on purpose: the part of a picker that can actually be
/// wrong — which session ranks first when you type `mx`, which group a session
/// lands in, how many of a group are running — is the part that is hardest to
/// see in a screenshot, so it lives here where tests can reach it.
enum Fuzzy {
    /// A hit, plus where it landed so the row can paint the matched characters.
    struct Match: Equatable {
        var score: Int
        /// Offsets into the candidate, in order. Empty for an empty query.
        var indices: [Int]
    }

    /// Characters after which the next one reads as the start of a word. Paths
    /// and session titles are full of them, and a match on a word start is
    /// nearly always the one the user meant.
    ///
    /// `?`, `&`, `=` and `#` join the set that `scan` uses because ⌘O's corpus
    /// is half addresses, where they separate words as plainly as a slash does.
    /// They cost nothing in a path or a session title, which never contain them.
    static let boundaries = Set<Character>(" /-_.:~@?&=#")

    static func isBoundary(_ c: Character) -> Bool { boundaries.contains(c) }

    /// Subsequence match, scored so that `mxp` prefers `max-pane` over a title
    /// that merely happens to contain those letters far apart.
    ///
    /// Greedy from each plausible starting point rather than a full optimal
    /// search: a single greedy pass gets `ask` in `trifecta ask` wrong, because
    /// it seizes the `a` inside `trifecta` and never looks at the word that
    /// actually reads as the match. Trying each occurrence of the first
    /// character and keeping the best fixes that for a handful of scans, which
    /// is what a per-keystroke filter over ten sessions can afford.
    static func match(_ query: String, in candidate: String) -> Match? {
        let q = Array(query.lowercased())
        guard !q.isEmpty else { return Match(score: 0, indices: []) }
        let c = Array(candidate)
        let lower = Array(candidate.lowercased())
        guard !c.isEmpty else { return nil }

        var best: Match?
        // Cap the starts: a query letter that appears thirty times in a path is
        // not worth thirty scans, and the early ones score highest anyway.
        var starts = 0
        for start in 0..<lower.count where lower[start] == q[0] {
            if let m = scan(q, c, lower, from: start), m.score > (best?.score ?? Int.min) {
                best = m
            }
            starts += 1
            if starts >= 12 { break }
        }
        return best
    }

    private static func scan(
        _ q: [Character], _ c: [Character], _ lower: [Character], from start: Int
    ) -> Match? {
        var indices: [Int] = []
        indices.reserveCapacity(q.count)
        var score = 0
        var qi = 0
        var previousMatch = -2

        for ci in start..<lower.count {
            guard qi < q.count, lower[ci] == q[qi] else { continue }
            score += 1
            if ci == previousMatch + 1 {
                // A run is the strongest signal there is: it means the user
                // typed a substring, not a scattering of letters.
                score += 12
            } else if ci == 0 || boundaries.contains(c[ci - 1]) {
                score += 10
            }
            // Letters skipped before this match cost a little, so an early,
            // tight match beats a late, loose one.
            if previousMatch >= 0, ci - previousMatch > 1 {
                score -= min(ci - previousMatch - 1, 6)
            }
            previousMatch = ci
            indices.append(ci)
            qi += 1
        }
        guard qi == q.count else { return nil }
        if indices.first == 0 { score += 6 }
        return Match(score: score, indices: indices)
    }
}

/// How much of a row the query explains.
///
/// # Why ⌘O needs this and `Fuzzy.score` is not enough
///
/// ⌘O ranks four things at once: a command you ran twice today, a page you
/// visited four hundred times last month, a Relay session that is blocked
/// waiting for you, and the literal text you just typed. Their scores are not
/// on one scale and never can be — history is scored in Rust by
/// `history::rank`, sessions and recents are scored here by `Fuzzy`, and the
/// two scorers weight runs and boundaries differently. Adding a per-source
/// multiplier to paper over that is picking a number that is wrong the moment
/// either corpus changes shape, with no way for the user to tell.
///
/// This is the axis that *is* comparable, because it is a property of the match
/// rather than of the corpus or the scorer: did the row literally start with
/// what you typed, did a word inside it, did it merely contain it, or are the
/// letters just in there somewhere. A person reading the list can see which of
/// the four happened without being told, which is the test a ranking rule has
/// to pass.
///
/// The order is deliberately the same ladder as `history::MatchTier` in Rust,
/// and the two are computed separately on purpose: recomputing it here over the
/// ≤80 rows that came back costs nothing, while adding a field to
/// `HistoryEntry` would push a ranking detail through the FFI into a record
/// that three other things already read.
enum MatchQuality: Int, Comparable, Sendable {
    /// The row *is* what was typed. Assigned, never computed: see `OmniRanking`.
    case typed
    /// The row starts with it.
    case prefix
    /// A word inside the row starts with it.
    case wordPrefix
    /// The row contains it, mid-word.
    case substring
    /// The letters are in there, in order, apart. A guess.
    case scattered

    static func < (a: MatchQuality, b: MatchQuality) -> Bool { a.rawValue < b.rawValue }

    /// Anything better than a guess.
    var isLiteral: Bool { self < .scattered }

    /// The best quality `query` reaches anywhere in `candidate`, or nil.
    ///
    /// Every occurrence is weighed, not just the first: `com` is mid-word in
    /// `example.com` and a word start in `/compare`, and taking the first hit
    /// would rank the row by the worse of the two matches it actually has.
    static func of(_ query: String, in candidate: String) -> MatchQuality? {
        guard !query.isEmpty else { return .prefix }
        guard !candidate.isEmpty else { return nil }
        let hay = Array(candidate.lowercased())
        let needle = Array(query.lowercased())
        var best: MatchQuality?
        if needle.count <= hay.count {
            for start in 0...(hay.count - needle.count) {
                guard Array(hay[start..<start + needle.count]) == needle else { continue }
                let here: MatchQuality =
                    start == 0 ? .prefix
                    : Fuzzy.isBoundary(hay[start - 1]) ? .wordPrefix : .substring
                if best == nil || here < best! { best = here }
                if best == .prefix { break }
            }
        }
        if let best { return best }
        return Fuzzy.match(query, in: candidate) == nil ? nil : .scattered
    }

    /// The best quality across several fields — a page's title and its URL, a
    /// session's title and command and directory.
    static func of(_ query: String, inAny fields: [String]) -> MatchQuality? {
        fields.compactMap { of(query, in: $0) }.min()
    }

    /// Which characters of `candidate` to light up, given how the row matched.
    ///
    /// `literal` is the row's own answer, not this field's. A page whose URL is
    /// `doc.rust-lang.org/…` matched the query `doc` outright; asking a
    /// subsequence matcher to explain that in the page's *title* lights the d of
    /// `std`, the o of `collections` and a c further along — three orange
    /// letters that had nothing to do with why the row is on screen. A
    /// highlight exists so a hit can be trusted, so a field with no literal hit
    /// in a row that won on one says nothing at all.
    static func offsets(_ query: String, in candidate: String, literal: Bool) -> [Int] {
        // Whitespace goes first because both scorers treat a space as a gap
        // between terms rather than a character to find — `max pane` matches
        // `maxpane` there, and asking for the literal string back would return
        // nothing for exactly the queries that did match.
        let needle = query.filter { !$0.isWhitespace }
        guard !needle.isEmpty, !candidate.isEmpty else { return [] }
        guard literal else { return Fuzzy.match(needle, in: candidate)?.indices ?? [] }

        let hay = Array(candidate.lowercased())
        let want = Array(needle.lowercased())
        guard want.count <= hay.count else { return [] }
        var best: (start: Int, quality: MatchQuality)?
        for start in 0...(hay.count - want.count) {
            guard Array(hay[start..<start + want.count]) == want else { continue }
            let here: MatchQuality =
                start == 0 ? .prefix
                : Fuzzy.isBoundary(hay[start - 1]) ? .wordPrefix : .substring
            if best == nil || here < best!.quality { best = (start, here) }
            if here == .prefix { break }
        }
        guard let best else { return [] }
        return Array(best.start..<best.start + want.count)
    }
}

/// One line in the session picker: a `// PATH` header, a session, a plain
/// section rule, or a command the user can start on the spot.
enum PaletteEntry: Equatable {
    case group(PaletteGroup)
    case session(PaletteSession)
    case section(title: String, note: String)
    case launch(PaletteLaunch)

    /// Headers are scenery — arrow keys and Return skip over them.
    var isSelectable: Bool {
        switch self {
        case .session, .launch: return true
        case .group, .section: return false
        }
    }
}

/// A session that does not exist yet. RelayTTY's quick-launch is half of why
/// its sidebar is usable every day: when the thing you are looking for is not
/// running, what you want next is to start it, not to close the picker.
struct PaletteLaunch: Equatable {
    var command: String
    var label: String
    var cwd: String
}

enum LaunchCommands {
    /// The agents worth one keystroke, plus whatever `$SHELL` is. Only the ones
    /// actually on `PATH` are offered — a picker that lists `codex` on a machine
    /// without it is worse than one that lists nothing.
    static let candidates = ["claude", "codex", "aider", "gemini", "cursor-agent", "opencode"]

    static let available: [(command: String, label: String)] = discover()

    static func discover(
        env: [String: String] = ProcessInfo.processInfo.environment,
        exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [(command: String, label: String)] {
        let path = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        var out: [(command: String, label: String)] = []
        for candidate in candidates
        where path.contains(where: { exists($0 + "/" + candidate) }) {
            out.append((candidate, candidate))
        }
        let shell = env["SHELL"] ?? "/bin/zsh"
        out.append((shell, (shell as NSString).lastPathComponent))
        return out
    }
}

struct PaletteGroup: Equatable {
    var path: String
    var total: Int
    var running: Int
    /// Sessions in this group waiting on a human. The number that decides
    /// whether you open the group at all.
    var blocked: Int
}

struct PaletteSession: Equatable {
    var telemetry: SessionTelemetry
    /// Offsets in the title to paint orange, when the query matched there.
    var titleMatches: [Int]
}

enum PaletteFilter {
    /// The picker's whole model: sessions grouped by directory, filtered by a
    /// fuzzy query over title, command and path, with a running count per group.
    ///
    /// Weighted, because at ten sessions the directory and the command are what
    /// two sessions share and the title is what tells them apart — so a title
    /// hit outranks a path hit even when the path match scores higher on its own.
    static func entries(
        groups: [(path: String, sessions: [SessionTelemetry])],
        query: String,
        launchable: [(command: String, label: String)] = LaunchCommands.available,
        home: String = NSHomeDirectory()
    ) -> [PaletteEntry] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var out: [PaletteEntry] = []
        var scored: [(group: PaletteGroup, best: Int, rows: [(row: PaletteSession, score: Int)])] = []

        for group in groups {
            var rows: [(row: PaletteSession, score: Int)] = []
            for session in group.sessions {
                guard let hit = score(session, tokens: tokens) else { continue }
                rows.append((PaletteSession(telemetry: session, titleMatches: hit.titleMatches), hit.score))
            }
            guard !rows.isEmpty else { continue }
            if !tokens.isEmpty {
                // Blocked before better-scoring anything else.
                //
                // Typing narrows; it does not re-rank. Once a session is in the
                // result, the question is which of the survivors you meant, and
                // the one that has drawn a prompt and stopped is the answer
                // nearly every time — it is why the picker is open. A blocked
                // session sinking below an idle one because the idle one's
                // title matched more tightly is the one failure this list
                // cannot afford.
                rows.sort {
                    let (a, b) = ($0.row.telemetry, $1.row.telemetry)
                    if a.needsAttention != b.needsAttention { return a.needsAttention }
                    if $0.score != $1.score { return $0.score > $1.score }
                    return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
                }
            }
            // The counts describe the group as it is, not as the filter left
            // it — "1 running" has to mean the same thing while you type.
            let header = PaletteGroup(
                path: group.path,
                total: group.sessions.count,
                running: group.sessions.filter(\.isRunning).count,
                blocked: group.sessions.filter(\.needsAttention).count)
            scored.append((header, rows.map(\.score).max() ?? 0, rows))
        }

        // Groups float by urgency first in both modes: a directory holding a
        // blocked agent comes before one that holds none, and only then does
        // the match score (or the path) decide.
        scored.sort {
            if ($0.group.blocked > 0) != ($1.group.blocked > 0) { return $0.group.blocked > 0 }
            if tokens.isEmpty { return $0.group.path < $1.group.path }
            return $0.best == $1.best ? $0.group.path < $1.group.path : $0.best > $1.best
        }
        for entry in scored {
            out.append(.group(entry.group))
            out.append(contentsOf: entry.rows.map { .session($0.row) })
        }

        // Nothing matched — which used to be an empty box. Offer to start the
        // thing instead, in the directory the query looks most like.
        if out.isEmpty, !launchable.isEmpty {
            let cwd = bestDirectory(for: tokens, among: groups.map(\.path), home: home)
            out.append(.section(
                title: "launch in \(SessionTelemetry.abbreviate(cwd))",
                note: query.isEmpty ? "no sessions" : "no match for “\(query)”"))
            out.append(contentsOf: launchable.map {
                .launch(PaletteLaunch(command: $0.command, label: $0.label, cwd: cwd))
            })
        }
        return out
    }

    /// Where a launched session should start: the existing project directory
    /// the query looks most like, so `mxp cl` lands `claude` in max-pane rather
    /// than in `$HOME`.
    static func bestDirectory(for tokens: [String], among paths: [String], home: String) -> String {
        guard !tokens.isEmpty, !paths.isEmpty else { return home }
        let ranked = paths.compactMap { path -> (String, Int)? in
            var total = 0
            for token in tokens {
                guard let m = Fuzzy.match(token, in: path) else { continue }
                total += m.score
            }
            return total > 0 ? (path, total) : nil
        }
        guard let best = ranked.max(by: { $0.1 < $1.1 })?.0 else { return home }
        // Groups are stored abbreviated; a spawn needs the real path back.
        return best.hasPrefix("~") ? home + best.dropFirst() : best
    }

    /// Every token has to land somewhere; the score is the sum of the best
    /// field for each.
    private static func score(
        _ session: SessionTelemetry,
        tokens: [String]
    ) -> (score: Int, titleMatches: [Int])? {
        guard !tokens.isEmpty else { return (0, []) }
        var total = 0
        var titleMatches: [Int] = []
        for token in tokens {
            var best = Int.min
            if let m = Fuzzy.match(token, in: session.title) {
                best = m.score * 3
                titleMatches.append(contentsOf: m.indices)
            }
            if let m = Fuzzy.match(token, in: session.command) { best = max(best, m.score * 2) }
            if let m = Fuzzy.match(token, in: session.groupPath) { best = max(best, m.score * 2) }
            guard best != Int.min else { return nil }
            total += best
        }
        return (total, Array(Set(titleMatches)).sorted())
    }
}
