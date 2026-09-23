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
    /// Edit › Paste Special. `sender` is an `NSString`: the raw value of the
    /// `TerminalPaste.Special` wanted. One selector rather than five, since
    /// which pane answers is the same question for all of them.
    func pasteSpecialIntoTerminalPane(_ sender: Any?)
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

    /// `text` as `bytes(for:)` sends it, still as text: the trailing line
    /// endings a paste never carries are gone. What paste history keeps.
    static func asSent(_ text: String) -> String {
        var out = Substring(text)
        while let last = out.last, last.isNewline { out.removeLast() }
        return String(out)
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
        /// The pasteboard said this is not to be kept: a password manager's
        /// copy (`isMarkedSecret`). It pastes like anything else and is left
        /// out of paste history (ADR-0031). Read here, at the moment of the
        /// paste, with the rest: a second look later would be at whatever the
        /// pasteboard holds by then.
        var doNotRecord = false

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
        var read = contents(of: pasteboard, images: images)
        read.doNotRecord = isMarkedSecret(pasteboard)
        return read
    }

    private static func contents(of pasteboard: NSPasteboard, images: Bool) -> Clipboard {
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

    /// The types an app puts beside what it copies to say "do not keep this"
    /// (nspasteboard.org). 1Password, Bitwarden and KeePassXC
    /// set the first; the second is a copy meant to be gone in a moment; the
    /// third is one no person made. Only the type's presence matters, never
    /// its data.
    static let secretMarkers: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("org.nspasteboard.AutoGeneratedType"),
    ]

    /// Whether what is on `pasteboard` was marked as not to be kept.
    static func isMarkedSecret(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return secretMarkers.contains(where: types.contains)
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

    /// Whether a ⌃V keystroke is ⌘V's image paste rather than the byte 0x16.
    ///
    /// ⌃V is Claude Code's own paste-image shortcut, and it reads the
    /// clipboard of the machine it runs on. In a remote lane that machine is
    /// the server, which has no picture, so the keystroke reaches Claude Code
    /// and fails honestly. The rule is deliberately narrow: only a remote lane,
    /// only a clipboard holding a picture and neither files nor text, and only
    /// with `paste_images_as_files` on. Every other ⌃V — any text or file on
    /// the clipboard, an empty one, a local lane where Claude Code's own ⌃V
    /// works, the setting off — is the byte, as it always was: literal-next in
    /// a shell, page down in vim.
    static func ctrlVIsImagePaste(isRemote: Bool, clipboard: Clipboard, settings: ImageSettings) -> Bool {
        isRemote && settings.asFiles && clipboard.text == nil && clipboard.image != nil
    }

    /// Whether a key event is ⌃V: control held, no ⌘ ⌥ ⇧ beside it, and the
    /// key is `v` — as the byte the terminal would send (0x16) or as the key
    /// under the modifiers, since a layout may report either.
    static func isControlV(flags: NSEvent.ModifierFlags, characters: String?, charactersIgnoringModifiers: String?) -> Bool {
        guard flags.intersection([.command, .option, .shift, .control]) == [.control] else { return false }
        return characters == "\u{16}" || charactersIgnoringModifiers?.lowercased() == "v"
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

    // MARK: - paste special

    /// The items of Edit › Paste Special that are not plain pastes. The raw
    /// value is the `Command`'s, which is how the menu's one selector says
    /// which (`TerminalPasteTarget.pasteSpecialIntoTerminalPane`).
    ///
    /// Each is a pure function below with a stable name, so that anything else
    /// may compose them: `escaped`, `base64Encoded`, `base64Decoded`,
    /// `base64Heredoc`, `heredocDelimiter`.
    enum Special: String, CaseIterable {
        case escaped = "pasteEscaped"
        case base64 = "pasteAsBase64"
        case base64Decoded = "pasteBase64Decoded"
        case fileAsBase64 = "pasteFileAsBase64"
        case slowly = "pasteSlowly"
        /// Not a transform: the sheet that composes them (`Advanced`).
        case advanced = "advancedPaste"
    }

    /// `text` as one shell word, whatever is in it; nil when there is nothing.
    /// Paste Escaped: text that must arrive as itself and run nothing.
    ///
    /// `shellWord(for:)`'s rule, with its one refusal taken back. A control
    /// character in a *file name* is refused because a path is typed at a
    /// prompt; in copied text a newline or a tab is content. So:
    ///
    /// - Line endings become `\n`, and the ones at the end are dropped: they
    ///   came along with the copy, and a paste never ends in Return.
    /// - **Bare, double quotes, or single quotes on a `!`**, exactly as
    ///   `shellWord(for:)` has it, when the only control characters are
    ///   newlines. **A newline stays a newline inside the quotes.** It goes
    ///   out as Return, the shell sees an open quote and asks for more
    ///   (`dquote>`), and nothing runs. That is why this paste never asks.
    /// - **`$'…'` when there is any other control character** (a tab, an
    ///   escape, a ^C). Inside ordinary quotes those are still keys to a line
    ///   editor: a tab asks for completion, ^C abandons the line. In `$'…'`
    ///   every one is written out (`\t`, `\n`, `\033`, three octal digits so
    ///   the next character cannot join it), so the paste is one line of
    ///   printable text. `!` is `\041` there, since history expansion does not
    ///   respect `$'…'` in every bash. bash, zsh and ksh read `$'…'`; plain
    ///   `sh` and fish do not, which is the price of a tab that stays a tab.
    static func escaped(_ text: String) -> String? {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while body.hasSuffix("\n") { body.removeLast() }
        guard !body.isEmpty else { return nil }
        let scalars = body.unicodeScalars
        let isControl = { (scalar: Unicode.Scalar) in scalar.properties.generalCategory == .control }
        guard scalars.contains(where: { isControl($0) && $0 != "\n" }) else {
            // Nothing in the way of the path rule but the newlines, which it
            // never sees: quoted a line at a time, they would each be a word.
            if scalars.allSatisfy(isBare) { return body }
            if scalars.contains("!") { return "'" + body.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            var out = "\""
            for scalar in scalars {
                if scalar == "\\" || scalar == "\"" || scalar == "$" || scalar == "`" { out.append("\\") }
                out.unicodeScalars.append(scalar)
            }
            return out + "\""
        }
        var out = "$'"
        for scalar in scalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "!": out += "\\041"
            case _ where isControl(scalar):
                for byte in String(scalar).utf8 {
                    let octal = String(byte, radix: 8)
                    out += "\\" + String(repeating: "0", count: 3 - octal.count) + octal
                }
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "'"
    }

    /// `text`'s UTF-8 as standard base64, on one line, padded.
    static func base64Encoded(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    /// Why a Paste Special pasted nothing, as the pane's one line.
    struct Refusal: Error, Equatable {
        var notice: String
    }

    /// The text `base64` encodes, or the line that says why there is none.
    ///
    /// Whitespace anywhere is ignored, since base64 out of a mail or a
    /// terminal is wrapped, and missing `=` padding is supplied. Anything else
    /// outside the standard alphabet refuses, and so does a result that is not
    /// UTF-8: bytes that are not text have no business at a prompt (a file
    /// goes the other way, `base64Heredoc`).
    static func base64Decoded(_ base64: String) -> Result<String, Refusal> {
        var compact = String(base64.unicodeScalars.filter { !$0.properties.isWhitespace })
        let alphabet = { (scalar: Unicode.Scalar) -> Bool in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", "+", "/": return true
            default: return false
            }
        }
        let unpadded = compact.unicodeScalars.prefix(while: { $0 != "=" })
        let padding = compact.unicodeScalars.count - unpadded.count
        guard !unpadded.isEmpty, unpadded.allSatisfy(alphabet), padding <= 2,
              compact.unicodeScalars.dropFirst(unpadded.count).allSatisfy({ $0 == "=" }),
              unpadded.count % 4 != 1
        else { return .failure(Refusal(notice: "not pasted: the clipboard is not base64")) }
        compact = String(String.UnicodeScalarView(unpadded))
        compact += String(repeating: "=", count: (4 - compact.count % 4) % 4)
        guard let data = Data(base64Encoded: compact) else {
            return .failure(Refusal(notice: "not pasted: the clipboard is not base64"))
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failure(Refusal(notice: "not pasted: that base64 is \(size(data.count)) that are not UTF-8 text"))
        }
        return .success(text)
    }

    /// The most a Paste File as Base64 takes, all its files together. A third
    /// more than this goes down the wire, at 200 KB/s at best.
    static let fileLimit = 5 * 1_048_576

    /// The one line that refuses files of `bytes` in all, or nil.
    static func fileRefusal(bytes: Int) -> Refusal? {
        guard bytes > fileLimit else { return nil }
        return Refusal(notice: "not pasted: \(size(bytes)) is more than the 5 MB a file paste takes")
    }

    /// A heredoc delimiter that is not one of `lines`: `EOF`, else `EOF_1`,
    /// `EOF_2`, … A line equal to the delimiter ends the heredoc early, and
    /// what follows it is run as commands.
    ///
    /// Base64 cannot in fact collide with `EOF` (its lines are a multiple of
    /// four characters long) and never holds a `_`. The rule is here anyway
    /// because it is the whole safety of a heredoc, and the next caller's body
    /// may be anything.
    static func heredocDelimiter(notIn lines: [String]) -> String {
        let taken = Set(lines)
        var delimiter = "EOF"
        var attempt = 0
        while taken.contains(delimiter) {
            attempt += 1
            delimiter = "EOF_\(attempt)"
        }
        return delimiter
    }

    /// `base64 -d > NAME <<'EOF'`, `data` as base64 wrapped at `columns`, and
    /// `EOF`, with **no line ending after it**: the file is on the prompt, and
    /// Return is the owner's to press. How a small file gets onto a machine
    /// that has no scp, only a shell.
    ///
    /// `name` is one shell word by `shellWord(for:)`, so `my notes.txt` is
    /// `"my notes.txt"`; nil when it holds a control character, as a path
    /// would be. The delimiter is quoted, so the body is taken literally.
    /// `-d` and not `--decode`: GNU, BusyBox and macOS 13 and later all take it.
    static func base64Heredoc(name: String, data: Data, columns: Int = 76) -> String? {
        guard !name.isEmpty, let word = shellWord(for: name) else { return nil }
        let encoded = Array(data.base64EncodedString().utf8)
        let width = max(columns, 4)
        let lines = stride(from: 0, to: encoded.count, by: width).map {
            String(decoding: encoded[$0..<min($0 + width, encoded.count)], as: UTF8.self)
        }
        let delimiter = heredocDelimiter(notIn: lines)
        return (["base64 -d > \(word) <<'\(delimiter)'"] + lines + [delimiter]).joined(separator: "\n")
    }

    /// What Paste Slowly reads from the config, each time.
    static func slowPace(_ config: Config) -> PacedInput.Pace {
        PacedInput.Pace(chunk: Int(config.pasteSlowChunk), gap: Double(config.pasteSlowDelayMs) / 1000)
    }

    /// The pane's line while a slow paste goes: `pasting slowly · 1.2 KB of
    /// 18.2 KB · Esc cancels`.
    static func slowNotice(_ event: PacedInput.SlowEvent) -> String {
        switch event {
        case .sent(let sent, let total): return "pasting slowly · \(size(sent)) of \(size(total)) · Esc cancels"
        case .finished(let total): return "pasted slowly · \(size(total))"
        case .cancelled(let sent, let total): return "slow paste cancelled · \(size(sent)) of \(size(total)) sent"
        }
    }

    // MARK: - advanced paste

    /// Edit › Paste Special › Advanced Paste…: several of the transforms above
    /// on one paste, and a regular expression (ADR-0032).
    ///
    /// Nothing here transforms anything itself except `substitute`. `compose`
    /// is the functions above, called in `Step`'s order, and that order is the
    /// whole of what this adds.
    struct Advanced: Equatable {
        /// The toggles, **in the order they are applied**, whichever were
        /// switched on first. The regular expression runs between `trimStray`
        /// and `tabsToSpaces`; it has no toggle, an empty pattern being off.
        ///
        /// 1. `base64Decode` unwraps: what comes out is the text the rest is
        ///    for, and nothing textual can be done to base64.
        /// 2. `straighten`, `stripPrompt`, `trimStray`: ⌘V's tidying in ⌘V's
        ///    order (ADR-0029). `straighten` is `straightenPunctuation` with
        ///    no prose guard: here it was asked for by name.
        /// 3. The regular expression, on tidied text that still has its lines
        ///    and its tabs: `^`, `$` and `\t` mean what they say, and a pattern
        ///    with `"` in it meets a straight one.
        /// 4. `tabsToSpaces`, then `oneLine`: layout, after anything that
        ///    reads the text by line. One Line needs the lines trimmed first.
        /// 5. `escape` quotes what is final. Before One Line it would quote
        ///    the newlines; after base64 it would have nothing to do.
        /// 6. `base64Encode` wraps: last, for the reason decode is first.
        enum Step: Int, CaseIterable, Comparable {
            case base64Decode, straighten, stripPrompt, trimStray, tabsToSpaces, oneLine, escape, base64Encode

            static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

            /// The steps the regular expression runs after.
            static let beforeRegex: [Step] = [.base64Decode, .straighten, .stripPrompt, .trimStray]
            static let afterRegex: [Step] = [.tabsToSpaces, .oneLine, .escape, .base64Encode]

            func label(tabWidth: Int) -> String {
                switch self {
                case .base64Decode: return "DECODE BASE64"
                case .straighten: return "STRAIGHTEN PUNCTUATION"
                case .stripPrompt: return "STRIP PROMPT"
                case .trimStray: return "TRIM WHITESPACE"
                case .tabsToSpaces: return "TABS TO \(tabWidth) SPACES"
                case .oneLine: return "ONE LINE"
                case .escape: return "ESCAPE AS ONE SHELL WORD"
                case .base64Encode: return "ENCODE BASE64"
                }
            }
        }

        var steps: Set<Step> = []
        /// `NSRegularExpression` syntax. Empty is off.
        var pattern = ""
        /// A template: `$1` is the first group, `\$` a dollar sign.
        var replacement = ""
        var tabWidth = 4
    }

    /// What an Advanced Paste comes to.
    struct Composed: Equatable {
        /// What would be pasted. Empty when there is a `problem`: a paste that
        /// could not be made as asked is not made some other way.
        var text: String
        /// The pattern does not compile, as one line. The sheet says it
        /// beside the pattern.
        var regexProblem: String?
        /// A step refused (the text is not base64), as the pane would say it.
        var refusal: String?
        /// How many times the pattern matched, or nil when there is none.
        var replacements: Int?

        var problem: String? { regexProblem ?? refusal }
    }

    /// `text` with `advanced`'s steps applied in `Step`'s order, the regular
    /// expression in its place. Pure, total, and the only thing the sheet
    /// shows or sends.
    static func compose(_ text: String, _ advanced: Advanced) -> Composed {
        var out = Composed(text: text)
        func apply(_ step: Advanced.Step) -> Bool {
            guard advanced.steps.contains(step) else { return true }
            switch step {
            case .base64Decode:
                switch base64Decoded(out.text) {
                case .success(let decoded): out.text = decoded
                case .failure(let refusal):
                    out.refusal = refusal.notice.replacingOccurrences(of: "the clipboard", with: "this")
                    return false
                }
            case .straighten: out.text = straightenPunctuation(out.text)
            case .stripPrompt: out.text = stripPrompt(out.text)
            case .trimStray: out.text = trimStray(out.text)
            case .tabsToSpaces: out.text = tabsToSpaces(out.text, width: advanced.tabWidth)
            case .oneLine: out.text = oneLine(out.text)
            case .escape: out.text = escaped(out.text) ?? ""
            case .base64Encode: out.text = base64Encoded(out.text)
            }
            return true
        }
        for step in Advanced.Step.beforeRegex where !apply(step) {
            out.text = ""
            return out
        }
        if !advanced.pattern.isEmpty {
            switch substitute(out.text, pattern: advanced.pattern, replacement: advanced.replacement) {
            case .replaced(let text, let count):
                out.text = text
                out.replacements = count
            case .invalid(let why):
                out.text = ""
                out.regexProblem = why
                return out
            }
        }
        for step in Advanced.Step.afterRegex { _ = apply(step) }
        return out
    }

    enum Substitution: Equatable {
        case replaced(String, count: Int)
        /// The pattern does not compile. One line, fit to show.
        case invalid(String)
    }

    /// Every match of `pattern` in `text` replaced by `replacement`.
    ///
    /// `NSRegularExpression`'s syntax (ICU) and its template: `$0` the match,
    /// `$1`…`$9` its groups, `\$` and `\\` themselves. A group the pattern does
    /// not have is nothing. `^` and `$` match at every line, since what is
    /// pasted into a terminal is lines; `(?s)` and the rest are the pattern's
    /// to set. **Never throws**: a pattern that does not compile is
    /// `.invalid`, and one that matches nothing is the text, zero times.
    static func substitute(_ text: String, pattern: String, replacement: String) -> Substitution {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        } catch {
            return .invalid("not a regular expression: \(printable(pattern))")
        }
        let out = NSMutableString(string: text)
        let count = regex.replaceMatches(
            in: out, options: [], range: NSRange(location: 0, length: out.length), withTemplate: replacement)
        return .replaced(out as String, count: count)
    }

    /// The whole of what would go out, fit to show, and its size: `preview`
    /// and `shape` of the same text, so the numbers are the picture's.
    static func advancedPreview(_ composed: Composed, limit: Int) -> (lines: [String], more: Int, summary: String) {
        let (lines, more) = preview(composed.text, limit: limit)
        let shape = shape(of: composed.text)
        let empty = shape.bytes == 0
        let summary = empty ? "nothing to paste"
            : "\(shape.lines) line\(shape.lines == 1 ? "" : "s") · \(size(shape.bytes))"
        return (empty ? [] : lines, empty ? 0 : more, summary)
    }

    // MARK: - middle click

    /// What a middle click in a terminal pane does.
    enum MiddleClick: Equatable {
        /// The program asked for the mouse, so the click is its own: it goes
        /// down to the emulator, which reports it.
        case program
        /// Nothing, and the emulator is not told. Not handed down, because
        /// Ghostty answers a middle click nobody captured by pasting the
        /// clipboard *itself*, framed by its own guess at bracketed paste:
        /// the path this file's first comment rules out.
        case ignored
        /// Paste this pane's own selection. X11's primary selection, within
        /// one pane, and the clipboard is neither read nor written.
        case selection(String)
        /// Paste the clipboard, as ⌘V would.
        case clipboard
    }

    /// Where a middle click goes.
    ///
    /// - `mouseCaptured`: the program asked for mouse reports (tmux, vim with
    ///   `mouse=a`), so the click is its own, as a left click already is.
    ///   `forced` takes it back: ⌥, the way ⌥ forces a selection here, or ⇧,
    ///   which is xterm's way and the one tmux users' hands know. (⇧ could
    ///   not be handed down anyway: Ghostty reads it as "not the program's"
    ///   and would paste by its own path.)
    /// - `enabled` is `middle_click_paste`. Off, a click the program did not
    ///   capture does nothing.
    /// - `inTile`: an unexpanded gallery tile is a picture of a pane, too
    ///   small to read, and a paste aimed at one is a paste into the unseen.
    ///   ⌘V still works there, since that takes a deliberate click first.
    /// - `selection` is this pane's highlighted text, or nil. One that is
    ///   empty or only whitespace is no selection: the clipboard is what was
    ///   meant.
    static func middleClick(
        enabled: Bool, inTile: Bool = false, mouseCaptured: Bool, forced: Bool, selection: String?
    ) -> MiddleClick {
        if mouseCaptured, !forced { return .program }
        guard enabled, !inTile else { return .ignored }
        if let selection, selection.contains(where: { !$0.isWhitespace }) { return .selection(selection) }
        return .clipboard
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
