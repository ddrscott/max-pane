import Foundation

/// Something in terminal output worth clicking.
///
/// Agents emit paths and URLs constantly — `src/foo.ts:42:10`, a docs link, a
/// PR — and the whole point of a strip that holds web panes beside terminals is
/// that you can open the thing next to the thing that mentioned it.
public enum TerminalToken: Equatable, Sendable {
    /// An `http`/`https` URL.
    case url(String)
    /// A file that exists, with the line and column if the text carried them.
    case file(path: String, line: Int?, column: Int?)

    /// What to open it as.
    public var openURL: URL? {
        switch self {
        case .url(let text):
            return URL(string: text)
        case .file(let path, _, _):
            return URL(fileURLWithPath: path)
        }
    }
}

/// Finds the token under a click in a line of terminal text.
public enum TerminalTokenizer {
    /// Characters that end a token.
    ///
    /// Quotes and brackets are separators because output wraps paths in them
    /// constantly — `"src/foo.ts"`, `(see docs/x.md)` — and a path with a
    /// trailing quote resolves to nothing.
    private static let boundaries = Set(" \t\u{0}\"'`<>|(){}[]".unicodeScalars.map(Character.init))

    /// The raw word around `column` in `line`, or nil if the click landed on
    /// whitespace.
    public static func word(in line: String, column: Int) -> String? {
        let chars = Array(line)
        guard column >= 0, column < chars.count, !boundaries.contains(chars[column]) else { return nil }

        var start = column
        while start > 0, !boundaries.contains(chars[start - 1]) { start -= 1 }
        var end = column
        while end + 1 < chars.count, !boundaries.contains(chars[end + 1]) { end += 1 }

        let word = String(chars[start...end])
        return word.isEmpty ? nil : word
    }

    /// Classify a word, resolving relative paths against `cwd`.
    ///
    /// `exists` is injected so this stays testable without touching the disk —
    /// and because the honest answer for a path is "does it exist *on the host
    /// running the session*", which for a remote session is not this machine.
    public static func classify(
        _ word: String,
        cwd: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> TerminalToken? {
        let trimmed = trimTrailingPunctuation(word)
        guard !trimmed.isEmpty else { return nil }

        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .url(trimmed)
        }

        // `src/foo.ts:42:10` — the suffix is where to go, not part of the name.
        let (path, line, column) = splitLineAndColumn(trimmed)
        guard !path.isEmpty else { return nil }

        let expanded = expand(path, cwd: cwd)
        // Existence is the gate. Without it every bare word in a stack trace
        // looks clickable and the feature becomes noise.
        guard exists(expanded) else { return nil }
        return .file(path: expanded, line: line, column: column)
    }

    /// Trailing punctuation that belongs to the sentence, not the token.
    /// A trailing `:` is dropped too — `see src/foo.ts:` is a path.
    static func trimTrailingPunctuation(_ word: String) -> String {
        var out = word
        while let last = out.last, ".,;:!?".contains(last) {
            out.removeLast()
        }
        return out
    }

    /// `path:line:col` → its parts. Only trailing all-digit segments count, so
    /// a Windows-ish `C:\x` or a URL-ish `host:8080` is not mangled.
    static func splitLineAndColumn(_ text: String) -> (path: String, line: Int?, column: Int?) {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return (text, nil, nil) }

        var column: Int? = nil
        var line: Int? = nil
        if let last = parts.last, let n = Int(last), parts.count > 1, !last.isEmpty {
            column = n
            parts.removeLast()
            if let next = parts.last, let m = Int(next), parts.count > 1, !next.isEmpty {
                line = m
                parts.removeLast()
            } else {
                // Only one number: it was the line, not the column.
                line = column
                column = nil
            }
        }
        return (parts.joined(separator: ":"), line, column)
    }

    /// Absolute, `~`-expanded, or resolved against the session's directory.
    static func expand(_ path: String, cwd: String) -> String {
        if path.hasPrefix("/") { return path }
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + String(path.dropFirst(1)) }
        guard !cwd.isEmpty else { return path }
        return (cwd as NSString).appendingPathComponent(path)
    }
}
