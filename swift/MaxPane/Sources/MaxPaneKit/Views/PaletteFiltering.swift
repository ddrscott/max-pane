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
    private static let boundaries = Set<Character>(" /-_.:~@")

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
