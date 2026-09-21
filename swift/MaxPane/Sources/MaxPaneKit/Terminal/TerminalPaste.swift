import AppKit
import RelayClient

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
    /// ⌥⌘V, Paste Without Asking: the same paste, with the sheet skipped once.
    func pasteIntoTerminalPaneWithoutAsking(_ sender: Any?)
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

    // MARK: - asking first

    /// When a paste asks before it goes. The config's four `paste_` keys, as
    /// the pure functions below take them.
    struct ConfirmSettings: Equatable {
        var multiline = true
        var tabs = true
        /// 0 never asks about size.
        var bytes = 16_384
        var tabWidth = 4

        init(multiline: Bool = true, tabs: Bool = true, bytes: Int = 16_384, tabWidth: Int = 4) {
            self.multiline = multiline
            self.tabs = tabs
            self.bytes = bytes
            self.tabWidth = tabWidth
        }

        init(_ config: Config) {
            self.init(
                multiline: config.pasteConfirmMultiline, tabs: config.pasteConfirmTabs,
                bytes: Int(config.pasteConfirmBytes), tabWidth: max(Int(config.pasteTabWidth), 1))
        }
    }

    /// What is unusual about a paste, measured on the bytes that would go out
    /// (`bytes(for:)`), not on the clipboard: a trailing newline is dropped
    /// before anyone counts it, so a single copied line is one line and asks
    /// nothing.
    struct Shape: Equatable {
        /// Lines as the far end will see them: interior line endings, plus one.
        var lines: Int
        var bytes: Int
        var tabs: Int

        var isMultiline: Bool { lines > 1 }

        /// What the sheet says is unusual, one line each. Everything that is
        /// true of the paste, whichever of them the settings ask about.
        func reasons(_ settings: ConfirmSettings) -> [String] {
            var out: [String] = []
            if isMultiline {
                out.append("\(lines - 1) of its \(lines) lines end in Return, and each runs as it lands")
            }
            if tabs > 0 {
                out.append("\(tabs) tab\(tabs == 1 ? "" : "s"): at a shell prompt a tab asks for completion")
            }
            if settings.bytes > 0, bytes > settings.bytes {
                out.append("\(TerminalPaste.size(bytes)): more than the \(TerminalPaste.size(settings.bytes)) a paste may be without asking")
            }
            return out
        }
    }

    static func shape(of text: String) -> Shape {
        let out = bytes(for: text)
        var lines = 1
        var tabs = 0
        for byte in out {
            if byte == carriageReturn { lines += 1 }
            if byte == 0x09 { tabs += 1 }
        }
        return Shape(lines: lines, bytes: out.count, tabs: tabs)
    }

    /// The predicate: does this paste ask first? An interior line ending, a
    /// tab, or more bytes than `paste_confirm_bytes`, each under its own
    /// setting. An empty paste asks nothing, there being nothing to send.
    static func asksFirst(_ text: String, _ settings: ConfirmSettings) -> Bool {
        let shape = shape(of: text)
        guard shape.bytes > 0 else { return false }
        if settings.multiline, shape.isMultiline { return true }
        if settings.tabs, shape.tabs > 0 { return true }
        if settings.bytes > 0, shape.bytes > settings.bytes { return true }
        return false
    }

    /// Paste as One Line: the lines joined with one space, so nothing in the
    /// paste presses Return.
    ///
    /// A line ending in a backslash is a shell continuation, and is joined the
    /// way the shell would join it: the backslash and the line ending both go,
    /// and no space is put in their place. `\\` at the end of a line is an
    /// escaped backslash, not a continuation, so it is the odd count that
    /// decides. Empty lines are dropped rather than turned into runs of
    /// spaces, and the last line keeps a trailing backslash it may have: there
    /// is nothing after it to continue onto.
    static func oneLine(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
        var out = ""
        var continues = false
        for (index, line) in lines.enumerated() {
            if index > 0, !continues { out.append(" ") }
            let trailing = line.reversed().prefix(while: { $0 == "\\" }).count
            continues = trailing % 2 == 1 && index < lines.count - 1
            out.append(contentsOf: continues ? line.dropLast() : line)
        }
        return out
    }

    /// Tabs to Spaces: each tab becomes `width` spaces. Not tab stops: what
    /// column a paste lands at is the prompt's business, and a fixed width is
    /// what the person agreeing to it can predict.
    static func tabsToSpaces(_ text: String, width: Int) -> String {
        text.replacingOccurrences(of: "\t", with: String(repeating: " ", count: max(width, 0)))
    }

    /// The first `limit` lines of what would go out, fit to show: control
    /// characters as their Unicode control pictures (a tab is `␉`, an escape
    /// `␛`, DEL `␡`), C1 controls as `<U+0085>`, and a long line cut short.
    /// `more` is how many lines were left off.
    static func preview(_ text: String, limit: Int = 8, width: Int = 240) -> (lines: [String], more: Int) {
        let out = String(decoding: bytes(for: text), as: UTF8.self)
        let all = out.split(separator: "\r", omittingEmptySubsequences: false)
        let shown = all.prefix(limit).map { line -> String in
            var visible = String.UnicodeScalarView()
            for scalar in line.unicodeScalars.prefix(width) {
                switch scalar.value {
                case 0x00...0x1f: visible.append(Unicode.Scalar(0x2400 + scalar.value)!)
                case 0x7f: visible.append("\u{2421}")
                case 0x80...0x9f: visible.append(contentsOf: "<U+00\(String(scalar.value, radix: 16, uppercase: true))>".unicodeScalars)
                default: visible.append(scalar)
                }
            }
            if line.unicodeScalars.count > width { visible.append("…") }
            return String(visible)
        }
        return (shown, all.count - shown.count)
    }

    /// `312 bytes`, `18.2 KB`, `1.0 MB`.
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) byte\(bytes == 1 ? "" : "s")" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    // MARK: - sending

    /// The bytes of a paste, cut for the wire: at most `InputChunks.limit`
    /// each, never in the middle of a character. Every paste leaves this way,
    /// and so does everything else (`PacedInput`), with no setting: a pty-host
    /// older than relay-tty 1.23 drops what does not fit its PTY in one write,
    /// and nothing says which kind a session is on.
    static func chunks(of bytes: [UInt8]) -> [ArraySlice<UInt8>] {
        InputChunks.split(bytes)
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
