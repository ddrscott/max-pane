import Foundation

/// Where a ⌘-clicked token belongs.
///
/// Two lanes, one rule:
///
/// ```
/// .url                          → web lane
/// .file, ext in MEDIA           → web lane on file://   (WKWebView renders it)
/// .file, anything else          → terminal lane running $EDITOR
/// ```
///
/// A `WKWebView` on `file:///…/foo.ts` is the worst of both readings: no
/// highlighting, no editing, and the `:42` the tokenizer worked to parse is
/// thrown away on the way in. A terminal running `$EDITOR +42` is the thing you
/// were reaching for when you clicked a path in a stack trace — and for a PDF
/// or a screenshot it is the web pane that already knows how to draw it.
///
/// Pure by construction: no AppKit, no `FileManager`, nothing that reads a byte
/// off the disk. `TerminalTokenizer.classify` has already gated on the file
/// existing, so by the time a token arrives here the only open question is
/// which lane it goes to.
public enum FileOpen: Equatable, Sendable {
    /// A web lane on this address — an `http(s)` URL, or a `file://` URL for
    /// something WebKit renders.
    case web(url: String)
    /// A terminal lane running this line, read by the user's login shell.
    case editor(shellLine: String)
}

extension FileOpen {
    /// Extensions a `WKWebView` renders as well as any native viewer would,
    /// which is the entire bar for keeping a file out of the editor.
    ///
    /// Matched lowercased — `REPORT.PDF` comes off a Windows share and out of
    /// half the scanners in the world.
    ///
    /// `.svg` is here although it is text, because the `.svg` an agent prints is
    /// nearly always a diagram it just drew, and the question is what it looks
    /// like. `.html` and `.md` are deliberately *not*: clicking one in terminal
    /// output is a request to read the file, and the one thing a web pane cannot
    /// then do is let you fix the line you were looking at.
    static let mediaExtensions: Set<String> = [
        "pdf",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "tiff", "ico",
        "mp4", "mov", "m4v", "webm",
        "mp3", "wav", "m4a", "aac", "flac", "ogg",
    ]

    /// The editor line used when nothing is configured.
    ///
    /// `$VISUAL`, then `$EDITOR`, then `vi` — the order `git` and `crontab` use,
    /// since `VISUAL` is the variable that names a full-screen editor and
    /// `EDITOR` is its line-editor elder. Both are left for the login shell to
    /// read, which is the whole reason the session is `$SHELL -li -c`: the ones
    /// that matter are what the user.s rc file exports, and this process cannot
    /// see them.
    ///
    /// **An alias does not count.** Aliases expand at parse time, on a literal
    /// command word, and the result of a parameter expansion is never scanned
    /// again — so `EDITOR=vim` with `alias vim=nvim` runs `/usr/bin/vim` here,
    /// with none of the neovim config, exactly as `git commit` already did.
    /// Measured, not reasoned: that pair opened a stock vim with syntax off.
    /// The fix is `EDITOR=nvim`, not an `eval` that would make this the one
    /// program on the machine that disagrees with git about what the editor is.
    ///
    /// **Deliberately no `exec`.** An exec'd child becomes the session leader,
    /// pty-host then reports `foreground_process` as None, and the classifier's
    /// first rule turns every such session into `idle` forever — which is the
    /// signal the sidebar exists to carry. See `RelaySessionSpawner.buildArgs`
    /// for the long version. `shellWrapped` appends `; exit $?`, so the lane
    /// still goes away when the editor quits.
    static let defaultEditorTemplate = "${VISUAL:-${EDITOR:-vi}} +%l -- %f"

    /// Which lane `token` goes to, and what to put in it.
    ///
    /// `editor` is `Config.editor` — nil means `defaultEditorTemplate`.
    public static func plan(for token: TerminalToken, editor: String?) -> FileOpen {
        switch token {
        case .url(let text):
            return .web(url: text)
        case .file(let path, let line, let column):
            let ext = (path as NSString).pathExtension.lowercased()
            if mediaExtensions.contains(ext) {
                return .web(url: fileURL(path))
            }
            return .editor(shellLine: expand(
                editor ?? defaultEditorTemplate, path: path, line: line, column: column))
        }
    }

    /// `file://` plus a percent-encoded path.
    ///
    /// Built by hand rather than with `URL(fileURLWithPath:)`, which stats the
    /// path to decide whether to write a trailing slash — a disk read, in the
    /// one type in this feature that is supposed to have none.
    static func fileURL(_ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return "file://" + encoded
    }

    /// Expand our three placeholders in `template`, and only ours.
    ///
    /// One left-to-right pass rather than three `replacingOccurrences` calls,
    /// because a path is data: `/tmp/%l/a.ts` substituted into `%f` must not
    /// then be scanned again for `%l`. Anything else after a `%` — and every
    /// bit of shell syntax, `${VISUAL:-${EDITOR:-vi}}` included — comes
    /// through untouched for the login shell to read.
    ///
    /// `%l` and `%c` fall back to **1** rather than to nothing, which is what
    /// keeps a template unconditional: no "drop the `+` when there is no line"
    /// branch, and no editor handed a bare `+`. Line 1 is where it would have
    /// opened anyway.
    static func expand(_ template: String, path: String, line: Int?, column: Int?) -> String {
        let file = RelaySessionSpawner.shellEscape(path)
        var out = ""
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            out += rest[rest.startIndex..<percent]
            let next = rest.index(after: percent)
            guard next < rest.endIndex else {
                out.append("%")
                rest = rest[rest.endIndex...]
                break
            }
            switch rest[next] {
            case "f": out += file
            case "l": out += String(line ?? 1)
            case "c": out += String(column ?? 1)
            default: out += rest[percent...next]
            }
            rest = rest[rest.index(after: next)...]
        }
        return out + rest
    }
}
