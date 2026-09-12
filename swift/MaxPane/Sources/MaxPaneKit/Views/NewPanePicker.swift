import AppKit
import LanedCore

/// What ⌘T (and ⌘D) can produce: a terminal running something, or a page.
enum NewPaneChoice: Equatable {
    /// Run this command line in a new terminal lane.
    case command(String, cwd: String?)
    /// Open this in a new web lane.
    case url(String)
}

/// One row of the picker.
enum NewPaneEntry: Equatable {
    case section(String)
    /// Launch what has been typed, as a command or as a URL.
    case action(NewPaneChoice)
    /// Something launched before.
    case recent(Recent)

    var isSelectable: Bool {
        if case .section = self { return false }
        return true
    }

    var choice: NewPaneChoice? {
        switch self {
        case .action(let choice): return choice
        case .recent(let recent):
            switch recent.kind {
            case .command: return .command(recent.value, cwd: recent.cwd)
            case .url: return .url(recent.value)
            }
        case .section: return nil
        }
    }
}

/// The rows, given what has been typed and what has been run before.
///
/// Pure, so the ordering rules — which is offered first, what a bare word
/// means, what gets a number — are testable without a window.
enum NewPaneEntries {
    /// How many rows can carry a numeric shortcut: 1…9 then 0.
    static let numbered = 10

    static func build(query: String, recents: [Recent]) -> [NewPaneEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var entries: [NewPaneEntry] = []

        if !trimmed.isEmpty {
            // Both are always offered: guessing wrong about `localhost:3000` or
            // a bare `make` would otherwise leave the other one unreachable.
            // Order is the guess; the second one is one arrow key away.
            let asURL = NewPaneEntry.action(.url(trimmed))
            let asCommand = NewPaneEntry.action(.command(trimmed, cwd: nil))
            entries.append(.section("LAUNCH"))
            entries.append(contentsOf: looksLikeURL(trimmed) ? [asURL, asCommand] : [asCommand, asURL])
        }

        let matches = recents.filter { trimmed.isEmpty || Fuzzy.match(trimmed, in: $0.value) != nil }
        if !matches.isEmpty {
            entries.append(.section("RECENT"))
            entries.append(contentsOf: matches.map(NewPaneEntry.recent))
        }
        return entries
    }

    /// The digit that launches a row, or nil past the tenth.
    ///
    /// Numbers follow the *visible* rows, so filtering renumbers: whatever is
    /// third on screen is ⌘3, which is the only rule that survives typing.
    static func shortcuts(for entries: [NewPaneEntry]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        var next = 0
        for (index, entry) in entries.enumerated() where entry.isSelectable {
            guard next < numbered else { break }
            map[index] = next
            next += 1
        }
        return map
    }

    /// `1`…`9`, then `0` for the tenth.
    static func label(forShortcut index: Int) -> String {
        index == 9 ? "0" : String(index + 1)
    }

    /// Is this more likely an address than a command?
    ///
    /// Deliberately conservative. `git status` is not a URL, `example.com` is,
    /// and `make` is a command because a single bare word with no dot is
    /// overwhelmingly something you run.
    static func looksLikeURL(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        if text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") { return true }
        // A dot with something either side, and no leading dot: `foo.com`,
        // but not `./configure` or `.zshrc`.
        guard let dot = text.firstIndex(of: "."), dot != text.startIndex else { return false }
        guard text.index(after: dot) < text.endIndex else { return false }

        // The first segment is the part that would be a host.
        let head = text.split(separator: "/").first.map(String.init) ?? text
        let hasPath = text.contains("/")

        // `docs.rs/tokio` is a site and `main.rs` is a file, and the extension
        // alone cannot tell them apart — `.rs` is both a crate's docs and a
        // Rust source file. What separates them is the path: a dotted name
        // followed by more path is an address, a dotted name on its own is a
        // file if its extension says so.
        if hasPath { return head.contains(".") }
        let ext = head.split(separator: ".").last.map(String.init)?.lowercased() ?? ""
        return !Self.fileExtensions.contains(ext)
    }

    /// Extensions that mean "a file in this repo", not "a site".
    private static let fileExtensions: Set<String> = [
        "rs", "swift", "ts", "tsx", "js", "jsx", "py", "go", "rb", "c", "h", "cpp", "hpp",
        "java", "kt", "sh", "zsh", "bash", "json", "toml", "yaml", "yml", "md", "txt",
        "lock", "sql", "html", "css", "png", "jpg", "svg", "pdf",
    ]
}

/// ⌘T / ⌘D — what goes in the new lane.
///
/// One picker for both halves of the strip, because the decision is one
/// decision: the next thing you need beside what you are looking at is
/// sometimes a shell and sometimes a page, and having to know which before you
/// press a key is the part that makes you not bother.
///
/// The list is what you launched last, most recent first, each with a number.
/// Reaching for the fourth thing you ran today should be ⌘T ⌘4, not typing it
/// out again.
@MainActor
final class NewPanePicker: PaletteController {
    private let store: StripStore
    private let completion: (NewPaneChoice?) -> Void
    private var entries: [NewPaneEntry] = []
    private var shortcuts: [Int: Int] = [:]
    private let recents: [Recent]

    init(store: StripStore, completion: @escaping (NewPaneChoice?) -> Void) {
        self.store = store
        self.completion = completion
        // Read once: the list cannot change while the picker is open, and
        // re-reading per keystroke would hit SQLite for every character.
        self.recents = store.recents(limit: 40)
        super.init(placeholder: "Run a command, or open a URL…",
                   size: NSSize(width: 720, height: 440))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func reload() {
        entries = NewPaneEntries.build(query: query, recents: recents)
        shortcuts = NewPaneEntries.shortcuts(for: entries)
        super.reload()
        updateFooter()
    }

    override func numberOfRows() -> Int { entries.count }

    override func isSelectable(row: Int) -> Bool {
        row < entries.count && entries[row].isSelectable
    }

    override func height(forRow row: Int) -> CGFloat {
        guard row < entries.count else { return 30 }
        if case .section = entries[row] { return 26 }
        return 32
    }

    override func rowIdentity(_ row: Int) -> String? {
        guard row < entries.count else { return nil }
        switch entries[row] {
        case .recent(let r): return "recent:\(r.kind):\(r.value)"
        case .action(let c): return "action:\(c)"
        case .section: return nil
        }
    }

    override func view(forRow row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        let key = shortcuts[row].map(NewPaneEntries.label(forShortcut:))
        switch entries[row] {
        case .section(let title):
            return PaletteSectionRow(title: title, note: "")
        case .action(let choice):
            return NewPaneRow(choice: choice, shortcut: key, isNew: true)
        case .recent(let recent):
            return NewPaneRow(recent: recent, shortcut: key)
        }
    }

    /// ⌘1…⌘9, ⌘0 — launch a row without leaving the keyboard's home row for
    /// the arrow keys. Plain digits are left alone: `7z` and `2fa` are commands.
    override func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let characters = event.charactersIgnoringModifiers,
              characters.count == 1,
              let digit = Int(characters)
        else { return false }

        let wanted = digit == 0 ? 9 : digit - 1
        guard let row = shortcuts.first(where: { $0.value == wanted })?.key else { return true }
        dismiss(selected: row)
        return true
    }

    override func deliver(selected: Int) {
        guard selected >= 0, selected < entries.count else { return completion(nil) }
        completion(entries[selected].choice)
    }

    private func updateFooter() {
        let commands = recents.filter { $0.kind == .command }.count
        footerLeft.attributedStringValue = PaletteStyle.caps(
            "\(commands) commands · \(recents.count - commands) pages")
        footerRight.stringValue = entries.isEmpty
            ? "type a command or a URL    esc"
            : "⌘1–⌘0 launch    ↩ launch    esc"
    }
}

/// A row in the new-pane picker: what it is, what it will do, and its number.
final class NewPaneRow: NSTableCellView {
    convenience init(recent: Recent, shortcut: String?) {
        self.init(
            glyph: recent.kind == .url ? "◍" : "$",
            primary: recent.value,
            secondary: recent.kind == .url ? "" : (recent.cwd.map(Self.tilde) ?? ""),
            shortcut: shortcut,
            tag: nil)
    }

    convenience init(choice: NewPaneChoice, shortcut: String?, isNew: Bool) {
        switch choice {
        case .command(let line, _):
            self.init(glyph: "$", primary: line, secondary: "", shortcut: shortcut, tag: "RUN")
        case .url(let url):
            self.init(glyph: "◍", primary: url, secondary: "", shortcut: shortcut, tag: "OPEN")
        }
    }

    init(glyph: String, primary: String, secondary: String, shortcut: String?, tag: String?) {
        super.init(frame: .zero)

        // The number is the point of the row, so it reads as a key rather than
        // as an ordinal: monospaced, dim, and in its own column on the left.
        let key = PaletteStyle.label(shortcut ?? "", Theme.mono(11, weight: .medium), Theme.dimText)
        key.alignment = .right

        let g = PaletteStyle.label(glyph, Theme.mono(12, weight: .medium), Theme.accent)
        g.alignment = .center

        let p = PaletteStyle.label(primary, Theme.mono(13), .labelColor)
        p.lineBreakMode = .byTruncatingTail

        let t = PaletteStyle.label(tag ?? "", Theme.mono(9, weight: .bold), Theme.dimText)

        let s = PaletteStyle.label(secondary, Theme.mono(11), Theme.dimText)
        s.alignment = .right
        s.lineBreakMode = .byTruncatingHead

        for v in [key, g, p, t, s] { addSubview(v) }
        NSLayoutConstraint.activate([
            key.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            key.centerYAnchor.constraint(equalTo: centerYAnchor),
            key.widthAnchor.constraint(equalToConstant: 16),

            g.leadingAnchor.constraint(equalTo: key.trailingAnchor, constant: 10),
            g.centerYAnchor.constraint(equalTo: centerYAnchor),
            g.widthAnchor.constraint(equalToConstant: 14),

            p.leadingAnchor.constraint(equalTo: g.trailingAnchor, constant: 8),
            p.centerYAnchor.constraint(equalTo: centerYAnchor),

            t.leadingAnchor.constraint(equalTo: p.trailingAnchor, constant: 10),
            t.firstBaselineAnchor.constraint(equalTo: p.firstBaselineAnchor),

            s.leadingAnchor.constraint(greaterThanOrEqualTo: t.trailingAnchor, constant: 12),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        p.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// `/Users/me/code/x` reads as `~/code/x`, which is how it is said out loud.
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
