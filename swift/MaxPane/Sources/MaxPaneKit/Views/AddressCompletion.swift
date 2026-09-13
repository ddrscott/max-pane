import AppKit
import LanedCore

/// One row under the address field: somewhere you have been that starts the way
/// you are typing.
struct AddressSuggestion: Equatable, Sendable {
    /// The full address, scheme and all. What Return navigates to.
    var url: String
    /// The address with the parts nobody types taken off — `OmniText.handle`.
    /// What the row shows, and what the typing is compared against.
    var handle: String
    /// The page's own title, or nil for a page that never produced one.
    var title: String?
}

/// What the address bar offers while you type, and what it refuses to offer.
///
/// ## Why this is not ⌘O
///
/// ⌘O has the same corpus and answers a different question. Its header reads
/// "→ new lane" because it *adds* a lane; this retargets the one you are
/// reading. Reported as *"`en.wik` offers nothing"* — and the substitute, ⌘O,
/// gets you to the page in a **different lane**, which is the opposite of what
/// someone editing this lane's address is asking for.
///
/// ## Why the list opens upward
///
/// Every browser's omnibox drops down because its address bar is at the top of
/// the window. This one is at the *foot* of the pane (`WebChromeBar` explains
/// why), so a dropdown would open off the bottom of the lane. It opens upward,
/// over the page, and the row nearest the field is the best match — so the
/// distance the eye travels from the text you typed to the row you want is the
/// same as it is anywhere else.
///
/// ## Why the ranking is not touched here
///
/// `history.rs` ranks, and it says why: ⌘P and this would otherwise disagree
/// about which of two URLs is the better match for the same typing, with no way
/// for the user to tell which rules they were under. So the core's order is the
/// order, and everything below is about what to *drop* and what to complete
/// inline — never about what to promote.
enum AddressCompletion {
    /// How many rows fit before the list stops being a glance.
    ///
    /// Six, at 20 pt, is 120 pt of page covered — about a fifth of a lane at the
    /// portrait height this app is built around, and low enough that the list
    /// never reaches the lane header. Chrome shows eight in a window four times
    /// as tall.
    static let maxRows = 6

    /// How many rows to ask the ledger for.
    ///
    /// More than are shown, because `rows` drops some of what comes back and a
    /// list that goes short because two entries were duplicates is a list that
    /// looks like history is missing.
    static let fetch: UInt32 = 16

    /// The rows to show for what has been typed, from what the ledger returned.
    static func rows(query: String, from history: [HistoryEntry],
                     limit: Int = maxRows) -> [AddressSuggestion] {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing typed, nothing offered. An empty field is ⌘L a moment ago,
        // and covering the page with "places you have been" for someone who has
        // not yet said anything is what ⌘O is for — on purpose, and with a
        // header saying so.
        guard !typed.isEmpty else { return [] }
        let typedHandle = OmniText.handle(typed).lowercased()

        var seen = Set<String>()
        var out: [AddressSuggestion] = []
        for entry in history {
            let handle = OmniText.handle(entry.url)
            // The page you are already looking at, or the address you have
            // finished typing. A row that offers you exactly what is in the
            // field is a row whose only effect is to be in the way of Return.
            if handle.lowercased() == typedHandle { continue }
            // Deduped on the handle rather than the URL: `http://x/a` and
            // `https://x/a` are one place to the person reading the list, and
            // the ledger keeps both because a scheme change is a real visit.
            guard seen.insert(handle.lowercased()).inserted else { continue }
            out.append(AddressSuggestion(
                url: entry.url, handle: handle,
                title: entry.title?.isEmpty == false ? entry.title : nil))
            if out.count == limit { break }
        }
        return out
    }

    /// The rest of the top row's address, when finishing the typing is safe.
    ///
    /// Returns the whole completed handle — `en.wik` → `en.wikipedia.org/wiki/Rust`
    /// — for the caller to put in the field with everything past the typing
    /// selected, so the next keystroke replaces it and nothing has been decided
    /// on the user's behalf.
    ///
    /// **Prefix only.** A fuzzy or substring hit is a perfectly good *row*, and
    /// a terrible thing to write into the field: the characters you typed would
    /// stop being the characters in front of you, which is the one thing a text
    /// field must not do. Chrome draws the same line for the same reason.
    ///
    /// **Never while deleting.** Backspace is otherwise impossible — the field
    /// re-completes the character you just removed, and the address can only be
    /// escaped by selecting all and starting again. This is the bug that makes
    /// naive inline completion unusable, and `deleting` is the whole fix.
    static func inlineCompletion(for query: String, suggestion: AddressSuggestion?,
                                 deleting: Bool) -> String? {
        guard !deleting, let suggestion else { return nil }
        // Not trimmed: a trailing space is someone typing a search phrase, and
        // completing it to a URL would turn a question into an address.
        guard !query.isEmpty, query.last?.isWhitespace != true else { return nil }
        let handle = suggestion.handle
        guard handle.count > query.count else { return nil }
        guard handle.lowercased().hasPrefix(query.lowercased()) else { return nil }
        // The typed characters are kept exactly as typed and the completion is
        // appended, rather than handing back the stored URL's own casing: a
        // field that rewrites `GitHub.com` to `github.com` under the cursor has
        // moved text the user is still editing.
        return query + handle.dropFirst(query.count)
    }

    /// One row, drawn: the address, with the letters that matched it in the
    /// accent, then the page's title in the dim grey.
    ///
    /// The address leads because the address is what is being completed. The
    /// title follows because on this owner's corpus — AWS console, GitHub diffs,
    /// Grafana — half the URLs differ only in a tail, and the title is often the
    /// only thing that distinguishes two rows that look identical for sixty
    /// characters.
    static func attributed(_ suggestion: AddressSuggestion, query: String) -> NSAttributedString {
        let out = NSMutableAttributedString(string: suggestion.handle, attributes: [
            .font: Theme.mono(11),
            .foregroundColor: NSColor.labelColor,
        ])
        // `literal: true` — the same rule the history palette highlights under.
        // A subsequence highlight on a row that won on a substring lights
        // letters that had nothing to do with why the row is there.
        let needle = OmniText.handle(query)
        for offset in MatchQuality.offsets(needle, in: suggestion.handle, literal: true)
        where offset < out.length {
            out.addAttribute(.foregroundColor, value: Theme.accent,
                             range: NSRange(location: offset, length: 1))
        }
        if let title = suggestion.title {
            out.append(NSAttributedString(string: "  " + title, attributes: [
                .font: Theme.mono(11),
                .foregroundColor: Theme.dimText,
            ]))
        }
        return AddressField.clipped(out)
    }
}

/// The list itself: rows above the address field, over the page.
///
/// Drawn rather than tabulated. An `NSTableView` brings a scroll view, a
/// delegate, cell reuse and its own first-responder appetite — and this shows at
/// most six rows that never scroll, over a web view, while a text field two
/// points below it must keep the keyboard. Six `drawRow` calls is the smaller
/// thing by a wide margin, and it cannot steal focus because there is nothing in
/// it that accepts any.
@MainActor
final class AddressCompletionList: NSView {
    static let rowHeight: CGFloat = 20

    /// A row was clicked. The pane navigates.
    var onPick: ((AddressSuggestion) -> Void)?
    /// The highlighted row changed — by arrow key or by the pointer. The pane
    /// writes it into the field, so Return needs no special case: it commits
    /// whatever the field holds, exactly as it does when nothing is highlighted.
    var onHighlight: ((AddressSuggestion?) -> Void)?

    private(set) var suggestions: [AddressSuggestion] = []
    private var query = ""
    private var tracking: NSTrackingArea?

    /// Which row is chosen, or nil for "none — the field holds what was typed".
    ///
    /// Nil is a real state and not a stand-in for zero. Opening with row 0
    /// already chosen would mean the first ↓ skips a row, and — worse — that
    /// Return after typing navigates somewhere the user never selected.
    private(set) var highlighted: Int?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    var height: CGFloat { CGFloat(suggestions.count) * Self.rowHeight }

    func show(_ rows: [AddressSuggestion], query: String) {
        suggestions = rows
        self.query = query
        highlighted = nil
        isHidden = rows.isEmpty
        needsDisplay = true
    }

    func hide() {
        guard !suggestions.isEmpty || !isHidden else { return }
        suggestions = []
        highlighted = nil
        isHidden = true
        needsDisplay = true
    }

    var isShowing: Bool { !isHidden && !suggestions.isEmpty }

    /// Walk the selection. `direction` is +1 for ↓ and -1 for ↑.
    ///
    /// Off either end is "nothing chosen" rather than a wrap. The list is a
    /// short menu attached to a field you are still editing, and walking off the
    /// top has to give you your own typing back — a wrap would take you from the
    /// first row to the last and leave no way back to what you wrote except
    /// Escape.
    func move(_ direction: Int) {
        guard isShowing else { return }
        let next: Int?
        switch highlighted {
        case nil:
            next = direction > 0 ? 0 : suggestions.count - 1
        case let current?:
            let candidate = current + direction
            next = (0..<suggestions.count).contains(candidate) ? candidate : nil
        }
        highlighted = next
        needsDisplay = true
        onHighlight?(next.map { suggestions[$0] })
    }

    // MARK: - pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let row = rowIndex(at: convert(event.locationInWindow, from: nil))
        guard row != highlighted else { return }
        highlighted = row
        needsDisplay = true
        onHighlight?(row.map { suggestions[$0] })
    }

    override func mouseExited(with event: NSEvent) {
        guard highlighted != nil else { return }
        highlighted = nil
        needsDisplay = true
        onHighlight?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = rowIndex(at: convert(event.locationInWindow, from: nil)) else { return }
        onPick?(suggestions[row])
    }

    /// Rows are laid out top-down in a bottom-up coordinate system: row 0 is
    /// nearest the field, which is at the *bottom* of this view.
    func rowIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point), !suggestions.isEmpty else { return nil }
        let fromBottom = Int(point.y / Self.rowHeight)
        guard (0..<suggestions.count).contains(fromBottom) else { return nil }
        return fromBottom
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        // The strip's own background, not the lane's: this is a surface in front
        // of the page, and it has to stop being mistaken for part of it.
        Theme.stripBackground.setFill()
        bounds.fill()

        for (index, suggestion) in suggestions.enumerated() {
            let row = NSRect(x: 0, y: CGFloat(index) * Self.rowHeight,
                             width: bounds.width, height: Self.rowHeight)
            if index == highlighted {
                Theme.laneBorder.setFill()
                row.fill()
                // A square 2 pt accent tab on the leading edge — the same
                // "the keyboard is here" the address field's outline means.
                // Square, and against a square row: the rule this app's Theme
                // sets out is that a colour rail never bends around a radius.
                Theme.accent.setFill()
                NSRect(x: 0, y: row.minY, width: 2, height: row.height).fill()
            }
            let text = AddressCompletion.attributed(suggestion, query: query)
            text.draw(in: NSRect(x: 8, y: row.minY + 3,
                                 width: max(0, row.width - 14), height: row.height - 4))
        }

        // A hairline along the top, so the list reads as a thing in front of the
        // page rather than as the page having grown a grey band.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: bounds.height - Theme.borderWidth,
               width: bounds.width, height: Theme.borderWidth).fill()
    }
}
