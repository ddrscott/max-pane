import AppKit
import LanedCore

/// One line in the history palette.
enum HistoryRow: Equatable {
    case section(String)
    /// A page, with the offsets to paint orange in each of its two lines.
    case entry(HistoryEntry, titleMatches: [Int], urlMatches: [Int])
    /// Scenery that says why the list is empty. An empty box is the one thing
    /// a palette must never be: it looks identical to a broken one.
    ///
    /// The reason goes in the right-hand note rather than the header, because
    /// the header is shouted — and a query echoed back in capitals is not the
    /// string the user typed.
    case note(title: String, detail: String)

    var isSelectable: Bool {
        if case .entry = self { return true }
        return false
    }

    var url: String? {
        if case .entry(let e, _, _) = self { return e.url }
        return nil
    }
}

/// The rows, given what has been typed and what the core ranked.
///
/// Pure, so the part that can actually be wrong — what a query with no hits
/// says, whether a page with no `<title>` still has a name — is testable
/// without a window.
///
/// Ranking is not here. It happened in Rust, over a corpus that never crosses
/// the FFI; see `crates/laned-core/src/history.rs`. What is left for `Fuzzy` is
/// the ≤60 rows that came back, and only to find the characters to light up —
/// so the user can see *why* a row survived what they typed.
enum HistoryRows {
    static func build(query: String, entries: [HistoryEntry], total: UInt32) -> [HistoryRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard total > 0 else {
            return [.note(title: "history", detail: "nothing visited yet")]
        }
        guard !entries.isEmpty else {
            return [.note(title: "history", detail: "no page matches “\(trimmed)”")]
        }
        // Whitespace is dropped before asking for offsets because the core's
        // scorer treats a space as a gap between terms rather than a character
        // to find — `max pane` matches `maxpane` there. Asking Swift's matcher
        // for the literal string would return no offsets for exactly the
        // queries that did match, and a row with no highlight reads as a row
        // that matched for no reason.
        let needle = trimmed.filter { !$0.isWhitespace }
        var rows: [HistoryRow] = [.section(trimmed.isEmpty ? "RECENTLY VISITED" : "MATCHES")]
        for entry in entries {
            rows.append(.entry(
                entry,
                titleMatches: needle.isEmpty ? [] : offsets(needle, in: entry.title ?? ""),
                urlMatches: needle.isEmpty ? [] : offsets(needle, in: entry.url)))
        }
        return rows
    }

    private static func offsets(_ needle: String, in candidate: String) -> [Int] {
        guard !candidate.isEmpty else { return [] }
        return Fuzzy.match(needle, in: candidate)?.indices ?? []
    }

    /// What a page is called when it never produced a `<title>`.
    ///
    /// The host, not the whole URL: the second line already carries the URL,
    /// and a row whose headline repeats the line underneath it tells you
    /// nothing twice — the same rule the ⌘P rows follow.
    static func name(_ entry: HistoryEntry) -> String {
        if let title = entry.title, !title.isEmpty { return title }
        return URL(string: entry.url)?.host ?? entry.url
    }

    /// `×7`, or nothing for a page seen once. A count of one is the default and
    /// printing it on nearly every row makes the column noise.
    static func countText(_ entry: HistoryEntry) -> String {
        entry.visitCount > 1 ? "×\(entry.visitCount)" : ""
    }
}

/// ⌘Y — everywhere you have been, searchable by title and by URL.
///
/// Hands back a URL and opens nothing. Where a page should go — a new lane,
/// the focused pane, a split — is a decision the strip makes, and a palette
/// that made it would be the second place in the app that knows how to open a
/// page.
@MainActor
final class HistoryPaletteController: PaletteController {
    private let store: StripStore
    private let completion: (String?) -> Void
    private var rows: [HistoryRow] = []
    /// How many pages are on record, regardless of the filter — so the footer
    /// says the same thing while you type, the way the session picker's group
    /// counts do.
    private var total: UInt32

    init(store: StripStore, completion: @escaping (String?) -> Void) {
        self.store = store
        self.completion = completion
        self.total = store.historyCount
        super.init(placeholder: "Search history by title or URL…",
                   size: NSSize(width: 760, height: 460))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// The whole of the ⌘Y hook, so wiring it is one line at the call site.
    static func present(
        store: StripStore, over parent: NSWindow?, onChoose: @escaping (String) -> Void
    ) {
        HistoryPaletteController(store: store) { url in
            guard let url else { return }
            onChoose(url)
        }.present(over: parent)
    }

    override func reload() {
        // No debounce, for the reason ⌘P has none: the ranking is a bounded
        // scan in Rust and only the rows that survive it cross the FFI, so a
        // keystroke costs a query rather than a corpus.
        rows = HistoryRows.build(query: query, entries: store.history(query), total: total)
        super.reload()
        updateFooter()
    }

    override func numberOfRows() -> Int { rows.count }

    override func isSelectable(row: Int) -> Bool {
        row < rows.count && rows[row].isSelectable
    }

    override func height(forRow row: Int) -> CGFloat {
        guard row < rows.count else { return 30 }
        switch rows[row] {
        case .section: return 26
        case .note: return 30
        case .entry: return 44
        }
    }

    override func rowIdentity(_ row: Int) -> String? {
        row < rows.count ? rows[row].url : nil
    }

    override func view(forRow row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .section(let title):
            return PaletteSectionRow(title: title, note: "")
        case .note(let title, let detail):
            return PaletteSectionRow(title: title, note: detail)
        case .entry(let entry, let titleMatches, let urlMatches):
            return HistoryPaletteRow(
                entry: entry, titleMatches: titleMatches, urlMatches: urlMatches)
        }
    }

    /// ⌘⌫ forgets the selected page.
    ///
    /// History is the one list in the app the user did not choose to write, so
    /// it needs a way to unwrite a line of it without a preferences pane. Plain
    /// ⌫ is left alone: it is how you fix a typo in the query, and a list that
    /// deletes rows while you are editing your search is a trap.
    override func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), event.keyCode == 51 else { return false }
        let row = table.selectedRow
        guard row >= 0, row < rows.count, let url = rows[row].url else { return true }
        store.forgetVisit(url)
        total = store.historyCount
        rows = HistoryRows.build(query: query, entries: store.history(query), total: total)
        refreshKeepingSelection()
        updateFooter()
        return true
    }

    override func deliver(selected: Int) {
        guard selected >= 0, selected < rows.count else { return completion(nil) }
        completion(rows[selected].url)
    }

    private func updateFooter() {
        let shown = rows.filter(\.isSelectable).count
        let pages = "\(total) \(total == 1 ? "page" : "pages")"
        footerLeft.attributedStringValue = PaletteStyle.caps(
            query.trimmingCharacters(in: .whitespaces).isEmpty
                ? "\(pages) · title, url, redirects"
                : "\(shown) of \(pages)")
        footerRight.stringValue = total == 0 ? "esc" : "↩ open    ⌘⌫ forget    esc"
    }
}

/// One page, two lines: what it was called on top, where it actually is
/// underneath. Both are searchable, so both are shown with their matched
/// characters lit — a hit you cannot explain is a hit you do not trust.
final class HistoryPaletteRow: NSTableCellView {
    init(entry: HistoryEntry, titleMatches: [Int], urlMatches: [Int]) {
        super.init(frame: .zero)

        let glyph = PaletteStyle.label(
            PaletteSearchRow.glyph(entry.matchedField), Theme.mono(12, weight: .medium), Theme.accent)
        glyph.alignment = .center

        let name = HistoryRows.name(entry)
        let title = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
            name,
            // A page with no title is headlined by its host, which is a slice
            // of the URL — so the URL's offsets would land in the wrong string.
            matches: entry.title?.isEmpty == false ? titleMatches : [],
            color: .labelColor))
        // Both lines are one line. An attributed label wraps by default, and a
        // wrapped title at a narrow palette width pushes the URL out of the
        // bottom of a fixed-height row — the line that says *where* the page
        // is, lost to the line that says what it is called.
        title.usesSingleLineMode = true
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        let count = PaletteStyle.label(
            HistoryRows.countText(entry), Theme.mono(10, weight: .bold),
            Theme.dimText.withAlphaComponent(0.8))
        count.alignment = .right

        let age = PaletteStyle.label(
            SessionTelemetry.age(since: Date(timeIntervalSince1970: Double(entry.lastVisitAt) / 1000)),
            Theme.mono(11), Theme.dimText)
        age.alignment = .right

        let url = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
            entry.url, matches: urlMatches, size: 11, color: Theme.dimText))
        url.usesSingleLineMode = true
        // Head-truncating would hide the host, which is the half of a URL you
        // recognise; the tail is a path you have already matched on.
        url.lineBreakMode = .byTruncatingTail
        url.translatesAutoresizingMaskIntoConstraints = false

        for v in [glyph, title, count, age, url] { addSubview(v) }
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 8),
            title.firstBaselineAnchor.constraint(equalTo: glyph.firstBaselineAnchor),

            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),
            count.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -12),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            age.widthAnchor.constraint(equalToConstant: 64),
            age.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            url.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            url.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            url.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        count.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
