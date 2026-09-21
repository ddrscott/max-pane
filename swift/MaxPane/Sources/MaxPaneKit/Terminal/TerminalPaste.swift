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
        /// `text` is text somebody copied, as opposed to paths this app made
        /// out of copied files. Only that is tidied (`tidy(_:)`): a path is
        /// already quoted, and a `’` in a file's name is the file's name.
        var isCopiedText = false
        /// A picture, as PNG bytes, when the pasteboard held one and neither
        /// files nor text. Never set alongside `text`: the pane turns it into
        /// a file first and pastes that file's path (`PastedImages`).
        var image: Data?

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
    /// **Text wins over an image, and an image is last.** A browser's Copy
    /// Image often carries the picture *and* a string (its address, its alt
    /// text), and a copy out of a document carries its words and a rendering
    /// of them; in both the text is what was meant for a prompt. Only a
    /// pasteboard with a picture and nothing else to say — a screenshot taken
    /// to the clipboard, a bare Copy Image — is an image paste, and then only
    /// when `images` says the setting (`paste_images_as_files`) is on. Off, it
    /// is nothing, as it was before there was such a thing.
    ///
    /// Pure apart from the pasteboard it is handed: nothing is stat'ed and no
    /// symlink is resolved. What was copied is what is pasted, and the path is
    /// this Mac's even when the session is on another machine.
    static func clipboard(_ pasteboard: NSPasteboard = .general, images: Bool = true) -> Clipboard {
        let files = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []
        guard files.isEmpty else { return clipboard(ofFiles: files) }
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return Clipboard(text: text, isCopiedText: true)
        }
        guard images, let png = png(on: pasteboard) else { return Clipboard() }
        return Clipboard(image: png)
    }

    /// The picture on `pasteboard` as PNG bytes, or nil when there is none.
    ///
    /// `public.png` is taken as it is: that is what ⇧⌃⌘4 writes, and
    /// re-encoding it would only change its bytes. TIFF and JPEG are decoded
    /// and written out as PNG, and anything else `NSImage` can read off a
    /// pasteboard (a PDF from Preview, a PICT from the past) is rendered and
    /// written the same way. One format on disk, so whatever reads the path
    /// is never surprised by its extension.
    static func png(on pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .png), !data.isEmpty { return data }
        for type in [NSPasteboard.PasteboardType.tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            if let data = pasteboard.data(forType: type), let rep = NSBitmapImageRep(data: data),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        guard NSImage.canInit(with: pasteboard), let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// What an image paste reads from the config, each time.
    struct ImageSettings: Equatable {
        var asFiles = true
        /// 0 refuses nothing.
        var maxMB = 25

        init(asFiles: Bool = true, maxMB: Int = 25) {
            self.asFiles = asFiles
            self.maxMB = maxMB
        }

        init(_ config: Config) {
            self.init(asFiles: config.pasteImagesAsFiles, maxMB: Int(config.pasteImageMaxMb))
        }
    }

    /// The one line that refuses an image of `bytes`, or nil when it may go.
    /// Measured on the PNG that would be written, in the MB `size(_:)` prints.
    static func imageRefusal(bytes: Int, _ settings: ImageSettings) -> String? {
        guard settings.maxMB > 0, bytes > settings.maxMB * 1_048_576 else { return nil }
        return "image not pasted: \(size(bytes)) is more than paste_image_max_mb = \(settings.maxMB)"
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

    // MARK: - tidying

    /// What tidying did to a paste, and the text it left (ADR-0029).
    ///
    /// Three transforms, each its own pure function so that anything else may
    /// compose them (`straightenPunctuation`, `stripPrompt`, `trimStray`), and
    /// `tidy(_:)`, which is the three in the order ⌘V applies them, with the
    /// counts the pane's notice is made of.
    ///
    /// **Only copied text is tidied.** Paths built from copied files, a dropped
    /// file, a saved or uploaded picture's path are this app's own words,
    /// already quoted, and a `’` in a file name is the file's name.
    struct Tidied: Equatable {
        var text: String
        var quotes = 0
        var dashes = 0
        var ellipses = 0
        /// Non-breaking and other Unicode spaces made into a space.
        var spaces = 0
        /// Zero-width characters removed.
        var invisibles = 0
        /// The prompt taken off every line, `"$ "`, or nil.
        var prompt: String?
        /// Lines that lost trailing whitespace, plus leading blank lines dropped.
        var trimmed = 0

        var changed: Bool {
            quotes + dashes + ellipses + spaces + invisibles + trimmed > 0 || prompt != nil
        }

        /// What was done, without the leading `pasted`: `straightened 4 quotes
        /// · removed "$ "`. Nil when nothing was. The sheet says it as well.
        var summary: String? {
            guard changed else { return nil }
            func count(_ n: Int, _ one: String, _ many: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? one : many)" }
            var parts: [String] = []
            let straightened = [
                count(quotes, "quote", "quotes"), count(dashes, "dash", "dashes"),
                count(ellipses, "ellipsis", "ellipses"), count(spaces, "odd space", "odd spaces"),
            ].compactMap { $0 }
            if !straightened.isEmpty { parts.append("straightened " + straightened.joined(separator: ", ")) }
            if let text = count(invisibles, "invisible character", "invisible characters") { parts.append("removed \(text)") }
            if let prompt { parts.append("removed \"\(prompt)\"") }
            if trimmed > 0 { parts.append("trimmed whitespace") }
            return parts.joined(separator: " · ")
        }

        /// The pane's one line: `pasted · straightened 4 quotes · removed "$ "`.
        var notice: String? { summary.map { "pasted · \($0)" } }
    }

    /// ⌘V's tidying, in its order: punctuation (unless the text is clearly
    /// prose), then the copied prompt, then stray whitespace. Idempotent:
    /// tidying what this returns changes nothing and reports nothing.
    static func tidy(_ text: String) -> Tidied {
        var out = Tidied(text: text)
        if !isClearlyProse(text) { out = straightening(text) }
        let (stripped, prompt) = strippingPrompt(out.text)
        out.text = stripped
        out.prompt = prompt
        let (trimmed, count) = trimmingStray(out.text)
        out.text = trimmed
        out.trimmed = count
        return out
    }

    /// Does this one line look like a command, rather than a sentence?
    ///
    /// The predicate, in full. Indentation and one leading prompt (`$`, `%` or
    /// `#`, then a space) are set aside first. Then:
    ///
    /// 1. A line starting with `#` does: a comment or a root prompt, and
    ///    either way it came out of a script.
    /// 2. Otherwise its **first word** decides. It must be `NAME=…` (an
    ///    assignment), or start with a lowercase ASCII letter or one of
    ///    `. / ~ $ _ ( ) { } [ | & !`; it must not be a bare `$` or hold a
    ///    letter that is not ASCII (`café`); it must not end in `,` `:` `?`,
    ///    or in a letter followed by `.` or `!`; and it must not be one of
    ///    `proseWords` (`the`, `this`, `please`, …), none of which is a
    ///    command or a shell keyword.
    /// 3. And the line must not **end like a sentence**: a letter followed by
    ///    `.` `?` `!` or `,`. (`git add .` and `cd ..` end in a dot that
    ///    follows no letter.)
    ///
    /// It errs toward "not a command": a capitalised program (`Rscript`,
    /// `VBoxManage`) fails it, and the cost is only that a multi-line paste
    /// holding one is left as it was copied.
    static func looksLikeCommand(_ line: String) -> Bool {
        var rest = Substring(line).drop(while: { $0.isWhitespace })
        if let first = rest.first, "$%#".contains(first), rest.dropFirst().first?.isWhitespace == true {
            if first == "#" { return true }
            rest = rest.dropFirst(2).drop(while: { $0.isWhitespace })
        }
        if rest.first == "#" { return true }
        return isCommandShaped(rest)
    }

    /// Rules 2 and 3 of `looksLikeCommand`, on a line whose prompt is already
    /// off. What a prompt is stripped on the strength of, so a `#` comment and
    /// a second prompt (`$ $ ls`) do not pass.
    private static func isCommandShaped(_ line: Substring) -> Bool {
        let body = line.drop(while: { $0.isWhitespace })
        guard let word = body.split(whereSeparator: { $0.isWhitespace }).first, let first = word.first else { return false }
        if !isAssignment(word) {
            guard first.isASCII, first.isLowercase || "./~$_(){}[|&!".contains(first) else { return false }
        }
        if word == "$" || word.contains(where: { !$0.isASCII && $0.isLetter }) { return false }
        if let last = word.last, ",:?".contains(last) { return false }
        if endsLikeASentence(word, marks: ".!") { return false }
        let plain = word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        if proseWords.contains(plain) { return false }
        var end = body
        while end.last?.isWhitespace == true { end.removeLast() }
        return !endsLikeASentence(end, marks: ".?!,")
    }

    private static func endsLikeASentence(_ text: Substring, marks: String) -> Bool {
        guard let last = text.last, marks.contains(last), let before = text.dropLast().last else { return false }
        return before.isLetter
    }

    /// `NAME=`, `_x1=`: a shell assignment at the front of a command.
    private static func isAssignment(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isASCII, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// First words that start a sentence and never a command. No shell
    /// keyword (`if`, `for`, `then`, `in`) and nothing on a PATH (`as`, `at`,
    /// `who`, `which`, `yes`, `time`, `last`, `more`, `next`) is here.
    static let proseWords: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those", "it", "its", "it's", "i", "i'm", "i've",
        "we", "you", "he", "she", "they", "there", "here", "and", "but", "or", "so", "because",
        "however", "also", "just", "not", "is", "are", "was", "were", "be", "to", "of", "on", "my",
        "our", "your", "their", "his", "her", "please", "note", "when", "what", "why", "how", "where",
        "can", "could", "should", "would", "will", "some", "all", "any", "each", "once", "after",
        "before", "finally", "with",
    ]

    /// The prose guard: several lines, and at least one that does not look
    /// like a command. One line is never "clearly prose" — it is what a
    /// copied command is — and neither is text whose every line passes.
    ///
    /// Empty lines are not judged, and neither is a line that continues the
    /// one before it (that one ended in an odd number of `\`): `--rm \` is
    /// part of a command, not a line of its own.
    static func isClearlyProse(_ text: String) -> Bool {
        let judged = lines(of: text).enumerated().filter { !$0.element.isBlank && !$0.element.continues }
        guard judged.count > 1 else { return false }
        return !judged.allSatisfy { looksLikeCommand($0.element.text) }
    }

    /// Straighten smart punctuation, whatever the text is. `tidy` asks
    /// `isClearlyProse` first; this does not.
    ///
    /// - `“ ” „ ‟` become `"`, and `‘ ’ ‚ ‛` become `'`.
    /// - **The dash rule.** A long dash (`–` en, `—` em, `―` bar) becomes `--`
    ///   when it *starts a word* (the start of the text, or whitespace before
    ///   it) *and an ASCII letter or digit follows it*: `—force` is `--force`
    ///   and `git commit –amend` is `git commit --amend`, because a long dash
    ///   there is what macOS, Word and WordPress make of a typed `--`.
    ///   Anywhere else it is one `-`: `a — b`, `2020–2024`, `foo—bar`, and
    ///   `–-flag`, where one hyphen survived and the pair is already `--`. The
    ///   hyphen look-alikes (`‐ ‑ ‒ −`) are always one `-`.
    /// - `…` becomes `...`.
    /// - A non-breaking or other Unicode space becomes a space.
    /// - Zero-width characters go: `U+200B`, `U+2060`, `U+FEFF` and the soft
    ///   hyphen always; a joiner or a direction mark (`U+200C–U+200F`) only
    ///   with ASCII or nothing on both sides, so an emoji family and Persian
    ///   text keep what holds them together.
    static func straightenPunctuation(_ text: String) -> String { straightening(text).text }

    private static func straightening(_ text: String) -> Tidied {
        var out = Tidied(text: "")
        let scalars = Array(text.unicodeScalars)
        var view = String.UnicodeScalarView()
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x201C, 0x201D, 0x201E, 0x201F:
                view.append("\""); out.quotes += 1
            case 0x2018, 0x2019, 0x201A, 0x201B:
                view.append("'"); out.quotes += 1
            case 0x2013, 0x2014, 0x2015:
                let startsWord = index == 0 || scalars[index - 1].properties.isWhitespace
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                let option = startsWord && next.map { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) } == true
                view.append(contentsOf: (option ? "--" : "-").unicodeScalars); out.dashes += 1
            case 0x2010, 0x2011, 0x2012, 0x2212:
                view.append("-"); out.dashes += 1
            case 0x2026:
                view.append(contentsOf: "...".unicodeScalars); out.ellipses += 1
            case 0x00A0, 0x1680, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                view.append(" "); out.spaces += 1
            case 0x200B, 0x2060, 0xFEFF, 0x00AD:
                out.invisibles += 1
            case 0x200C...0x200F:
                let before = index == 0 || scalars[index - 1].isASCII
                let after = index + 1 >= scalars.count || scalars[index + 1].isASCII
                if before && after { out.invisibles += 1 } else { view.append(scalar) }
            default:
                view.append(scalar)
            }
        }
        out.text = String(view)
        return out
    }

    /// Take a copied prompt off the front of every line: `$ `, `% ` or `# `,
    /// with its space. **Never `> `**, which is a quote, a redirect and a
    /// continuation prompt before it is anything worth removing.
    ///
    /// Only when *every* non-empty line starts with the same one, at column 0,
    /// and what is left of each is shaped like a command (`looksLikeCommand`'s
    /// rules 2 and 3): so `# A heading` and `# a comment, in words.` keep their
    /// `#`, `$ 5 each` keeps its `$`, and a transcript with output in it (one
    /// line without the prompt) is left alone. A line that continues the one
    /// before it has no prompt to have, and is kept as it is.
    static func stripPrompt(_ text: String) -> String { strippingPrompt(text).text }

    private static func strippingPrompt(_ text: String) -> (text: String, prompt: String?) {
        let all = lines(of: text)
        let judged = all.filter { !$0.isBlank && !$0.continues }
        guard let first = judged.first, let prompt = ["$ ", "% ", "# "].first(where: { first.text.hasPrefix($0) }),
              judged.allSatisfy({ $0.text.hasPrefix(prompt) && isCommandShaped($0.text.dropFirst(2)) })
        else { return (text, nil) }
        let out = all.map { $0.isBlank || $0.continues ? $0.text : String($0.text.dropFirst(2)) }
        return (out.joined(separator: "\n"), prompt)
    }

    /// Drop leading blank lines and the whitespace at the end of each line.
    /// **Indentation is kept**: it is a heredoc's body, or Python. A line that
    /// ends in an escaped space (`\ `) keeps it, being a word and not a stray.
    static func trimStray(_ text: String) -> String { trimmingStray(text).text }

    private static func trimmingStray(_ text: String) -> (text: String, count: Int) {
        var count = 0
        var out: [String] = []
        for line in lines(of: text) {
            if out.isEmpty, line.isBlank {
                // The last line of all-blank text is nothing, not a blank line.
                count += line.text.isEmpty && line.isLast ? 0 : 1
                continue
            }
            var kept = Substring(line.text)
            while kept.last?.isWhitespace == true { kept.removeLast() }
            if kept.count < line.text.count, trailingBackslashes(kept) % 2 == 1 {
                out.append(line.text)
                continue
            }
            if kept.count < line.text.count { count += 1 }
            out.append(String(kept))
        }
        guard count > 0 else { return (text, 0) }
        return (out.joined(separator: "\n"), count)
    }

    private struct Line {
        var text: String
        /// The line before this one ended in an odd number of backslashes.
        var continues: Bool
        var isLast: Bool
        var isBlank: Bool { text.allSatisfy { $0.isWhitespace } }
    }

    /// `text` by lines, whichever line ending it has. What is put back
    /// together is joined with `\n`; `bytes(for:)` makes every kind the same
    /// Return in any case.
    private static func lines(of text: String) -> [Line] {
        let parts = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var continues = false
        return parts.enumerated().map { index, part in
            defer { continues = trailingBackslashes(part) % 2 == 1 }
            return Line(text: String(part), continues: continues, isLast: index == parts.count - 1)
        }
    }

    private static func trailingBackslashes(_ text: Substring) -> Int {
        text.reversed().prefix(while: { $0 == "\\" }).count
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
