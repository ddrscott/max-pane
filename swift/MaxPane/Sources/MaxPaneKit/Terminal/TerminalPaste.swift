import AppKit

/// ⌘V, as a selector of the terminal's own rather than `paste:`.
///
/// `paste:` is already spoken for. Ghostty's terminal view implements it and
/// answers by asking the *emulator* to paste, which is the one thing a pane
/// attached to somebody else's PTY must not do (`TerminalPaste` says why at
/// length). A separate selector lets the Edit menu offer a terminal its own
/// paste first and fall back to `paste:` for everything else — a web pane, a
/// search field — with neither side knowing the other exists.
@MainActor
@objc public protocol TerminalPasteTarget {
    func pasteIntoTerminalPane(_ sender: Any?)
}

/// What ⌘V actually puts on the wire, given what is on the pasteboard.
///
/// **No bracketed-paste markers, ever.** Ghostty would happily add them: its
/// `paste(text:)` frames the text in `ESC[200~`/`ESC[201~` when *its* emulator
/// believes the program at the far end asked for them (DECSET 2004). Here that
/// belief is a guess and cannot be anything else. Our emulator learns the far
/// end's modes only from bytes that reached it, and three routine things hide
/// the `ESC[?2004h` that would have told it: the mode was set before we
/// attached, the replay that would have carried it was capped at 256 KiB, or
/// the surface was rebuilt — which happens whenever the strip recycles a lane
/// view or the font size changes — and started again from defaults.
///
/// The two ways of being wrong are not symmetric, which is what settles it:
///
/// - Guess "on" when the far end is off, and the markers arrive as text. That
///   is the `[200~PASTE_PROBE_123~` the owner saw on a prompt.
/// - Guess "off" when the far end is on, and the far end receives characters
///   it was ready to receive anyway. Nothing is corrupted.
///
/// So we never guess: the clipboard's own bytes go out, and the only thing
/// this changes is the line endings, for the reasons below.
enum TerminalPaste {
    /// Carriage return — what the Return key sends, and what a line editor in
    /// raw mode is listening for. A pasted `\n` that stayed a `\n` would be
    /// ^J: bound to accept-line in most shells, but not all, and not in less,
    /// vi, or anything that reads keys itself.
    private static let carriageReturn: UInt8 = 0x0d
    private static let lineFeed: UInt8 = 0x0a

    /// The bytes for a paste of `text`.
    ///
    /// Two rules, and nothing else touches the content:
    ///
    /// 1. Every line ending — CRLF, LF, CR — becomes a single CR, because that
    ///    is the byte the Return key produces and pasted text has to arrive as
    ///    if it had been typed.
    /// 2. Trailing line endings are dropped. Copying a command out of a page
    ///    or a README brings its newline along, and with no bracketed paste to
    ///    hold it back that newline *is* the Return key: the pasted line runs
    ///    the instant it lands, before it can be read. Paste puts text in
    ///    front of the user; pressing Return is theirs.
    ///
    /// Interior newlines are left as line endings and will run the lines they
    /// end, exactly as typing them would. That is the honest behaviour of a
    /// terminal without bracketed paste, and the alternative — silently
    /// swallowing them — would mangle the paste instead.
    static func bytes(for text: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.utf8.count)
        var afterReturn = false
        for byte in text.utf8 {
            switch byte {
            case carriageReturn:
                out.append(carriageReturn)
                afterReturn = true
            case lineFeed:
                // The LF half of a CRLF is the same line ending, not a second.
                if !afterReturn { out.append(carriageReturn) }
                afterReturn = false
            default:
                out.append(byte)
                afterReturn = false
            }
        }
        while out.last == carriageReturn { out.removeLast() }
        return out
    }

    /// What a pasteboard amounts to, for a terminal.
    struct Clipboard: Equatable {
        /// The text to paste, or nil when the pasteboard holds nothing a
        /// terminal can take.
        var text: String?
        /// Copied files left out of `text`, by display name, control
        /// characters already replaced. See `shellWord(for:)` for why.
        var skippedFiles: [String] = []

        /// One line for the pane's notice, or nil when nothing was skipped.
        var notice: String? {
            switch skippedFiles.count {
            case 0: return nil
            case 1: return "skipped \"\(skippedFiles[0])\": a control character in its name"
            default: return "skipped \(skippedFiles.count) files with control characters in their names"
            }
        }
    }

    /// What is on `pasteboard`, as a terminal takes it. Every paste — ⌘V, the
    /// Edit menu, a drop of files on a pane — reads the pasteboard through
    /// here and nowhere else.
    ///
    /// **Files win over text.** Finder's ⌘C writes each file as a
    /// `public.file-url` item *and* a string flavour holding only the display
    /// name, and the name is useless anywhere but the file's own directory. So
    /// when there are file URLs the paste is their paths, each a shell word
    /// (`shellWord(for:)`), space-separated in the pasteboard's order with no
    /// trailing space, and the string flavour is ignored. A web URL is not a
    /// file URL and pastes as the text it is.
    ///
    /// Pure apart from the pasteboard it is handed: nothing is stat'ed and no
    /// symlink is resolved. What was copied is what is pasted, and the path is
    /// this Mac's even when the session is on another machine.
    static func clipboard(_ pasteboard: NSPasteboard = .general) -> Clipboard {
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        guard files.isEmpty else { return clipboard(ofFiles: files) }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return Clipboard() }
        return Clipboard(text: text)
    }

    /// The pasteboard's text, or nil when it holds nothing a terminal can take.
    static func clipboardText(_ pasteboard: NSPasteboard = .general) -> String? {
        clipboard(pasteboard).text
    }

    static func clipboard(ofFiles files: [NSURL]) -> Clipboard {
        var words: [String] = []
        var skipped: [String] = []
        for url in files {
            let path = filePath(of: url)
            guard !path.isEmpty else { continue }
            if let word = shellWord(for: path) {
                words.append(word)
            } else {
                skipped.append(printable((path as NSString).lastPathComponent))
            }
        }
        return Clipboard(text: words.isEmpty ? nil : words.joined(separator: " "), skippedFiles: skipped)
    }

    /// The absolute path a file URL names: not percent-encoded, not
    /// `~`-abbreviated, and not the `/.file/id=…` file-reference form Finder
    /// sometimes hands over, which means something only to this boot of this
    /// Mac. Turning a reference into a path is the one place the system looks
    /// at the volume, because nothing else knows the id; an ordinary file URL
    /// is taken at its word. `NSURL` rather than `URL` so that this is said
    /// here and not left to what the bridge happens to do.
    static func filePath(of url: NSURL) -> String {
        if url.isFileReferenceURL(), let resolved = url.filePathURL { return resolved.path }
        return url.path ?? ""
    }

    /// `text` as one word of a POSIX shell command line, or nil when it holds
    /// a control character.
    ///
    /// The quoting is what makes a path safe to land on a prompt, there being
    /// no bracketed paste to do it (see above).
    ///
    /// - **Bare** when every character is one no shell treats specially:
    ///   ASCII letters and digits, `/ . _ - + , : @ %`, and non-ASCII letters,
    ///   digits and the combining marks a decomposed `é` is made of.
    /// - **Double quotes** otherwise, as the owner asked, with the four
    ///   characters that stay live inside them backslash-escaped:
    ///   `\` `"` `$` and the backtick.
    /// - **Single quotes when there is a `!`**, and only then. `!` is history
    ///   expansion in interactive bash and zsh *even inside double quotes*,
    ///   and a backslash there does not remove it cleanly (bash keeps the
    ///   backslash). Inside single quotes nothing is live, so the one
    ///   character to deal with is `'` itself, written `'\''`. It is rare, and
    ///   the alternative is a paste that silently turns into something else.
    /// - **nil for a control character** (a newline, a tab, an escape, DEL,
    ///   C1). Typed into a prompt those are keystrokes, not text — a newline
    ///   in a file name would press Return in the middle of the path, quotes
    ///   or no quotes, since a line editor acts on it before any shell parses
    ///   it. The caller leaves that file out and says so.
    static func shellWord(for text: String) -> String? {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { $0.properties.generalCategory == .control }) { return nil }
        if !text.isEmpty, scalars.allSatisfy(isBare) { return text }

        if scalars.contains("!") {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var out = "\""
        for scalar in scalars {
            if scalar == "\\" || scalar == "\"" || scalar == "$" || scalar == "`" { out.append("\\") }
            out.unicodeScalars.append(scalar)
        }
        return out + "\""
    }

    private static func isBare(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "/", ".", "_", "-", "+", ",", ":", "@", "%": return true
            default: return false
            }
        }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .nonspacingMark, .spacingMark, .enclosingMark, .decimalNumber:
            return true
        default:
            return false
        }
    }

    /// A name fit to show in a notice: each control character as `?`, the way
    /// `ls` prints one.
    private static func printable(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            out.append(scalar.properties.generalCategory == .control ? "?" : scalar)
        }
        return String(out)
    }
}
