import AppKit
import LanedCore

/// What ⇧⌘H lists, and how: everything that decides is here and pure
/// (ADR-0031). The list is at most a few hundred short strings, so filtering
/// is a substring test over all of them per keystroke; there is no index.
enum PasteHistory {
    /// The entries that contain every word typed, in the order given, which
    /// is newest first. That is the whole ranking: the thing wanted back is
    /// nearly always the last one or two of its kind, and a score that moved
    /// an older, "better" match above a newer one would be wrong here.
    /// Case is ignored. A redacted entry matches on the four characters it
    /// shows, since those are all there is.
    static func filter(_ entries: [ClipEntry], query: String) -> [ClipEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let text = entry.content.lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    /// An entry as one line: its first line with anything on it, or, when
    /// something was typed, the first line that has the first word in it, so
    /// the row shows why it is there. Control characters are made visible the
    /// way the paste sheet makes them.
    static func headline(_ entry: ClipEntry, query: String = "") -> String {
        let lines = entry.content.split(whereSeparator: \.isNewline)
            .map { $0.drop(while: \.isWhitespace) }
            .filter { !$0.isEmpty }
        let word = query.lowercased().split(whereSeparator: \.isWhitespace).first.map(String.init)
        let line = word.flatMap { w in lines.first { $0.lowercased().contains(w) } } ?? lines.first ?? ""
        return TerminalPaste.preview(String(line), limit: 1, width: 200).lines.first ?? ""
    }

    /// UTF-16 offsets of `headline` that the typed words cover, for
    /// `PaletteStyle.highlighted`.
    static func matches(in headline: String, query: String) -> [Int] {
        let text = headline as NSString
        var lit = IndexSet()
        for word in query.split(whereSeparator: \.isWhitespace) {
            var from = 0
            while from < text.length {
                let found = text.range(
                    of: String(word), options: .caseInsensitive,
                    range: NSRange(location: from, length: text.length - from))
                guard found.location != NSNotFound, found.length > 0 else { break }
                lit.insert(integersIn: found.location..<(found.location + found.length))
                from = found.location + found.length
            }
        }
        return Array(lit)
    }

    /// `pasted · 3 lines · 1.2 KB · 5m ago`. The counts are the original's,
    /// for a redacted entry too.
    static func detail(_ entry: ClipEntry, now: Date = Date()) -> String {
        let way = entry.kind == .paste ? "pasted" : "copied"
        let lines = "\(entry.lineCount) line\(entry.lineCount == 1 ? "" : "s")"
        let age = SessionTelemetry.age(since: Date(timeIntervalSince1970: Double(entry.at) / 1000), now: now)
        return [entry.redacted ? "looked like a secret, not kept" : nil, way, lines,
                TerminalPaste.size(Int(entry.byteCount)), age]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// What the confirmation before a delete says, in full: a row shows one
    /// truncated line, and two rows can show the same one.
    static func deletePrompt(_ entry: ClipEntry) -> (title: String, detail: String) {
        let preview = TerminalPaste.preview(entry.content, limit: 4, width: 120)
        let more = preview.more > 0 ? "\n… \(preview.more) more line\(preview.more == 1 ? "" : "s")" : ""
        return ("Delete this from paste history?", preview.lines.joined(separator: "\n") + more)
    }
}

/// ⇧⌘H: what was pasted into and copied out of terminals lately.
///
/// ↩ pastes the row into the terminal that had the keyboard, through the
/// pane's own door: untidied (it is kept as it was sent) and asked about in
/// the sheet when it is risky. ⌘C puts it back on the clipboard. ⌘⌫, or ⌫
/// with nothing typed, deletes it after asking. A redacted row can be seen
/// and deleted; there is nothing in it to paste or copy.
@MainActor
final class PasteHistoryController: PaletteController {
    private let store: StripStore
    private let config: () -> Config
    private let canPaste: Bool
    private let pasteboard: NSPasteboard
    private let completion: (ClipEntry?) -> Void
    private var all: [ClipEntry] = []
    private(set) var visible: [ClipEntry] = []
    /// The footer's left side, when it is saying something other than a count.
    private var said: String?

    /// - Parameters:
    ///   - canPaste: a terminal pane has the keyboard. Without one the list
    ///     still opens, for ⌘C.
    ///   - pasteboard: where ⌘C writes. The general one, except in a test.
    ///   - completion: the entry to paste, or nil for anything else.
    init(
        store: StripStore, config: @escaping () -> Config, canPaste: Bool,
        pasteboard: NSPasteboard = .general, completion: @escaping (ClipEntry?) -> Void
    ) {
        self.store = store
        self.config = config
        self.canPaste = canPaste
        self.pasteboard = pasteboard
        self.completion = completion
        super.init(placeholder: "Paste history…", size: NSSize(width: 760, height: 460))
        all = store.clipHistory(config())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func reload() {
        visible = PasteHistory.filter(all, query: query)
        said = nil
        super.reload()
        updateFooter()
    }

    override func numberOfRows() -> Int { visible.count }
    override func height(forRow row: Int) -> CGFloat { 44 }
    override func rowIdentity(_ row: Int) -> String? { row < visible.count ? String(visible[row].id) : nil }

    override func view(forRow row: Int) -> NSView? {
        guard row < visible.count else { return nil }
        return PasteHistoryRow(entry: visible[row], query: query)
    }

    /// ↩. A redacted row, or no terminal to paste into, keeps the list open
    /// and says why, rather than closing on nothing.
    override func commit() {
        let row = table.selectedRow
        guard row >= 0, row < visible.count else { return }
        if let refusal = pasteRefusal(visible[row]) {
            say(refusal)
            return
        }
        super.commit()
    }

    func pasteRefusal(_ entry: ClipEntry) -> String? {
        if entry.redacted { return "it looked like a secret and was not kept: nothing to paste" }
        if !canPaste { return "no terminal has the keyboard · ⌘C copies it" }
        return nil
    }

    override func deliver(selected: Int) {
        guard selected >= 0, selected < visible.count, pasteRefusal(visible[selected]) == nil else {
            completion(nil)
            return
        }
        completion(visible[selected])
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)
        if command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            // The field's own ⌘C wins while some of the query is selected.
            if let editor = field.currentEditor(), editor.selectedRange.length > 0 { return false }
            if copy(row: table.selectedRow) { dismiss(selected: -1) }
            return true
        }
        // ⌘⌫ always; plain ⌫ only with nothing typed, where it cannot be a
        // correction to the query.
        if event.keyCode == 51, command || query.isEmpty {
            askToDelete(row: table.selectedRow)
            return true
        }
        return false
    }

    /// ⌘C: the row back on the clipboard. False when there was nothing to copy.
    @discardableResult
    func copy(row: Int) -> Bool {
        guard row >= 0, row < visible.count else { return false }
        guard !visible[row].redacted else {
            say("it looked like a secret and was not kept: nothing to copy")
            return false
        }
        pasteboard.clearContents()
        pasteboard.setString(visible[row].content, forType: .string)
        return true
    }

    private func askToDelete(row: Int) {
        guard row >= 0, row < visible.count else { return }
        let entry = visible[row]
        // Off the key monitor, and with ↩ on Cancel: a ⌫ typed by reflex
        // should not be confirmable by a ↩ typed by reflex a beat later.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let prompt = PasteHistory.deletePrompt(entry)
            ConfirmPopup.confirm(
                over: self.window, title: prompt.title, detail: prompt.detail,
                action: "Delete", returnConfirms: false
            ) { [weak self] yes in
                if yes { self?.delete(entry) }
            }
        }
    }

    /// The row goes, from the ledger and from the list, and the selection
    /// stays where it was.
    func delete(_ entry: ClipEntry) {
        store.deleteClip(entry.id)
        all.removeAll { $0.id == entry.id }
        visible = PasteHistory.filter(all, query: query)
        refreshKeepingSelection()
        updateFooter()
    }

    private func say(_ text: String) {
        said = text
        updateFooter()
    }

    private func updateFooter() {
        let live = config()
        let summary: String
        if let said {
            summary = said
        } else if !live.pasteHistory || live.pasteHistoryKeep == 0 {
            summary = "paste history is off · paste_history in settings"
        } else if all.isEmpty {
            summary = "nothing yet · what you paste into or copy out of a terminal is listed here"
        } else if query.isEmpty {
            summary = "\(all.count) kept · newest first · terminals only, never the clipboard at large"
        } else {
            summary = "\(visible.count) of \(all.count)"
        }
        footerLeft.attributedStringValue = PaletteStyle.caps(summary)
        footerRight.stringValue = (canPaste ? "↩ paste    " : "") + "⌘C copy    ⌘⌫ delete    esc"
    }
}

/// One entry: an arrow for which way it went, the line, and the rest under it.
final class PasteHistoryRow: NSTableCellView {
    init(entry: ClipEntry, query: String, now: Date = Date()) {
        super.init(frame: .zero)
        // Into a terminal, or out of one. Grey: it is a fact about the row,
        // not a state.
        let glyph = PaletteStyle.label(entry.kind == .paste ? "↓" : "↑", Theme.mono(12, weight: .medium), Theme.dimText)
        glyph.alignment = .center
        let headline = PasteHistory.headline(entry, query: query)
        let line = PaletteStyle.label("", Theme.mono(13), .labelColor)
        line.attributedStringValue = PaletteStyle.highlighted(
            headline, matches: PasteHistory.matches(in: headline, query: query),
            color: entry.redacted ? Theme.dimText : .labelColor)
        line.lineBreakMode = .byTruncatingTail
        let detail = PaletteStyle.label(PasteHistory.detail(entry, now: now), Theme.mono(10), Theme.dimText)
        detail.lineBreakMode = .byTruncatingTail

        for v in [glyph, line, detail] { addSubview(v) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            glyph.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            line.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            line.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),

            detail.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
        ])
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
