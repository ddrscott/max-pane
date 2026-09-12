import Testing
import Foundation
@testable import MaxPaneKit

/// Clicking a path or a URL in terminal output.
///
/// The failure mode to guard against is not "misses one" — it is "fires on
/// everything". Agent output is mostly prose with the occasional path in it, so
/// a tokenizer that thinks every word is clickable turns a useful gesture into
/// noise and makes ordinary clicks open random panes.
@Suite("terminal tokens")
struct TerminalTokenTests {
    /// A stand-in filesystem, so these never touch the disk.
    private func existing(_ paths: Set<String>) -> (String) -> Bool {
        { paths.contains($0) }
    }

    // MARK: - finding the word

    @Test("takes the word under the column, not the whole line")
    func findsWordUnderColumn() {
        let line = "  error in src/foo.ts at line 42"
        #expect(TerminalTokenizer.word(in: line, column: 14) == "src/foo.ts")
        #expect(TerminalTokenizer.word(in: line, column: 2) == "error")
    }

    @Test("a click on whitespace selects nothing")
    func whitespaceIsNotAWord() {
        #expect(TerminalTokenizer.word(in: "a  b", column: 1) == nil)
        #expect(TerminalTokenizer.word(in: "", column: 0) == nil)
        #expect(TerminalTokenizer.word(in: "abc", column: 99) == nil)
        #expect(TerminalTokenizer.word(in: "abc", column: -1) == nil)
    }

    @Test("quotes and brackets end a word, because output wraps paths in them")
    func quotesAndBracketsAreBoundaries() {
        #expect(TerminalTokenizer.word(in: #"see "src/foo.ts" now"#, column: 6) == "src/foo.ts")
        #expect(TerminalTokenizer.word(in: "(see docs/x.md)", column: 6) == "docs/x.md")
        #expect(TerminalTokenizer.word(in: "[src/a.ts]", column: 3) == "src/a.ts")
    }

    // MARK: - classifying

    @Test("an http(s) URL is a URL")
    func recognisesURLs() {
        #expect(TerminalTokenizer.classify("https://example.com/a?b=c", cwd: "/tmp", exists: existing([]))
            == .url("https://example.com/a?b=c"))
        #expect(TerminalTokenizer.classify("http://localhost:8080", cwd: "/tmp", exists: existing([]))
            == .url("http://localhost:8080"))
    }

    @Test("a scheme we will not open in a pane is not a token", arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "ftp://example.com", "mailto:a@b.c",
    ])
    func refusesOtherSchemes(_ text: String) {
        #expect(TerminalTokenizer.classify(text, cwd: "/tmp", exists: existing([])) == nil)
    }

    @Test("a relative path resolves against the session's directory")
    func resolvesRelativePaths() {
        let fs = existing(["/Users/s/code/max-pane/src/foo.ts"])
        #expect(TerminalTokenizer.classify("src/foo.ts", cwd: "/Users/s/code/max-pane", exists: fs)
            == .file(path: "/Users/s/code/max-pane/src/foo.ts", line: nil, column: nil))
    }

    @Test("line and column suffixes are where to go, not part of the name")
    func splitsLineAndColumn() {
        let fs = existing(["/w/src/foo.ts"])
        #expect(TerminalTokenizer.classify("src/foo.ts:42:10", cwd: "/w", exists: fs)
            == .file(path: "/w/src/foo.ts", line: 42, column: 10))
        #expect(TerminalTokenizer.classify("src/foo.ts:42", cwd: "/w", exists: fs)
            == .file(path: "/w/src/foo.ts", line: 42, column: nil))
    }

    @Test("~ expands")
    func expandsHome() {
        let home = NSHomeDirectory()
        let fs = existing([home + "/notes.md"])
        #expect(TerminalTokenizer.classify("~/notes.md", cwd: "/anywhere", exists: fs)
            == .file(path: home + "/notes.md", line: nil, column: nil))
    }

    @Test("an absolute path ignores the session's directory")
    func absolutePathsWin() {
        let fs = existing(["/etc/hosts"])
        #expect(TerminalTokenizer.classify("/etc/hosts", cwd: "/somewhere/else", exists: fs)
            == .file(path: "/etc/hosts", line: nil, column: nil))
    }

    // MARK: - the important half: not firing

    @Test("a path that does not exist is not clickable")
    func existenceIsTheGate() {
        #expect(TerminalTokenizer.classify("src/ghost.ts", cwd: "/w", exists: existing([])) == nil)
    }

    @Test("ordinary prose is not clickable", arguments: [
        "error", "the", "Reading", "TypeScript", "42", "--flag", "npm",
    ])
    func proseIsNotClickable(_ word: String) {
        // Nothing exists, so nothing resolves — this is the common case and it
        // must produce nothing at all.
        #expect(TerminalTokenizer.classify(word, cwd: "/w", exists: existing([])) == nil)
    }

    @Test("a word that happens to name a real file still resolves")
    func bareFilenamesWork() {
        // The flip side: `README.md` on its own is a legitimate click target
        // when it is really there.
        let fs = existing(["/w/README.md"])
        #expect(TerminalTokenizer.classify("README.md", cwd: "/w", exists: fs)
            == .file(path: "/w/README.md", line: nil, column: nil))
    }

    @Test("sentence punctuation is trimmed, but a dotted filename survives")
    func trimsTrailingPunctuation() {
        #expect(TerminalTokenizer.trimTrailingPunctuation("src/foo.ts.") == "src/foo.ts")
        #expect(TerminalTokenizer.trimTrailingPunctuation("docs/x.md,") == "docs/x.md")
        #expect(TerminalTokenizer.trimTrailingPunctuation("path:") == "path")
        #expect(TerminalTokenizer.trimTrailingPunctuation("foo.ts") == "foo.ts")
    }

    @Test("a colon that is not a line number is left alone")
    func doesNotMangleNonNumericColons() {
        let (path, line, column) = TerminalTokenizer.splitLineAndColumn("host:name")
        #expect(path == "host:name")
        #expect(line == nil)
        #expect(column == nil)
    }

    @Test("the whole path survives when it has no suffix")
    func noSuffixKeepsPath() {
        let (path, line, _) = TerminalTokenizer.splitLineAndColumn("src/foo.ts")
        #expect(path == "src/foo.ts")
        #expect(line == nil)
    }
}
