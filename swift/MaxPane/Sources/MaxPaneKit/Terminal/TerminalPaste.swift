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

    /// The pasteboard's text, or nil when it holds nothing a terminal can take.
    static func clipboardText(_ pasteboard: NSPasteboard = .general) -> String? {
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }
}
