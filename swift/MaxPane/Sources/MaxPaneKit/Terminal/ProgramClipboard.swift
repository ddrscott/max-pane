import AppKit

/// A program in a terminal and this Mac's clipboard: OSC 52 (ADR-0028).
///
/// The other direction from `TerminalPaste`. There the person puts the
/// clipboard into a program; here a program reaches for the clipboard itself,
/// to set it (`ESC ] 52 ; c ; <base64> BEL`, what tmux, vim and neovim send to
/// copy, and the only way a yank on a remote machine gets here) or to read it
/// (`ESC ] 52 ; c ; ? BEL`), which hands whatever was last copied, a password
/// as readily as anything, to whatever is running, on whatever machine.
///
/// Two roads lead here and both end at the same two doors on
/// `TerminalPaneController`:
///
/// - **relay's `CLIPBOARD` frame.** pty-host lifts an OSC 52 write out of the
///   output stream and sends the decoded text as a frame of its own, so the
///   escape sequence never reaches the emulator. It also swallows the read
///   query and answers nothing, so through a current pty-host a read cannot
///   be asked at all.
/// - **Ghostty**, for bytes that do reach it: a session whose pty-host predates
///   that lifting. The terminals' configuration says `ask` for both, so every
///   request comes to the pane, which answers from the settings as they are
///   now rather than as they were when the configuration was built.
///
/// Everything that decides is here and pure, with the pasteboard handed in.
enum ProgramClipboard {
    /// The most a program may put on the clipboard. The size both ends of
    /// relay-tty stop at, so a bigger one only ever arrives through Ghostty.
    static let maxBytes = 1 << 20

    enum Write: Equatable {
        /// Nothing happens and nothing is said: `deny`, or nothing to set. An
        /// empty OSC 52 is a request to *clear* the clipboard, which no
        /// program has any business doing to what the person copied.
        case ignore
        /// Refused, with the line the pane says.
        case refuse(String)
        case ask
        case set
    }

    static func write(_ text: String, _ permission: ClipboardPermission) -> Write {
        if permission == .deny || text.isEmpty { return .ignore }
        let bytes = text.utf8.count
        if bytes > maxBytes {
            return .refuse("a program's copy was refused: \(TerminalPaste.size(bytes)) is more than 1 MiB")
        }
        return permission == .ask ? .ask : .set
    }

    /// The one place a program's text lands on a pasteboard, and so the one
    /// place a record of what terminals copied out would be taken.
    static func set(_ text: String, on pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// What the pane says when the header could not (`BLOCKED` or a dead
    /// server holds the chip, or the pane is in no lane).
    static func copiedNotice(_ text: String) -> String {
        "a program copied \(TerminalPaste.size(text.utf8.count)) to the clipboard"
    }

    enum Question: Equatable { case read, write }

    /// Who is asking, as far as anyone knows.
    struct Asker: Equatable {
        /// The lane's title, as its header shows it.
        var lane: String
        /// The session's command, when the registry has one.
        var program: String?
        /// The relay server a remote lane is on; nil on this Mac.
        var server: String?
    }

    /// The sheet's two sentences. The second is the one that matters for a
    /// read: where the text goes.
    static func wording(_ question: Question, _ asker: Asker, text: String) -> (summary: String, detail: String) {
        let who = (asker.program.flatMap { $0.isEmpty ? nil : "`\($0)`" } ?? "A program")
            + " in “\(asker.lane)”" + (asker.server.map { " on \($0)" } ?? "")
        let shape = TerminalPaste.shape(of: text)
        let amount = "\(shape.lines) line\(shape.lines == 1 ? "" : "s") · \(TerminalPaste.size(text.utf8.count))"
        switch question {
        case .read:
            let leaves = asker.server.map { "It leaves this Mac for \($0)." }
                ?? "It goes to whatever is running in that terminal."
            return ("\(who) wants to read the clipboard", "\(amount) would be handed over. \(leaves)")
        case .write:
            return ("\(who) wants to set the clipboard", "\(amount) would replace what is on it.")
        }
    }
}
