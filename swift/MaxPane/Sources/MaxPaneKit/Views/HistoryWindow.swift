import AppKit
import LanedCore

/// ⇧⌘Y — history with room in it.
///
/// The palette (⌘Y) and this window read the same ledger and rank a query with
/// the same code, and they are deliberately not the same surface. The palette is
/// a door: three characters, Return, the page opens, it is gone. This is a
/// record you read — which needs the four things a 26-point row over the strip
/// cannot give, and which round 2's critic listed in this order:
///
/// * **a list that does not stop at 60.** Pages of 120, asked for as you reach
///   them, and the footer says how many of how many are loaded.
/// * **the whole address.** The URL wraps instead of truncating. Two CloudWatch
///   rows differing only in a trailing `stream-a`/`stream-b` are what made this
///   a bug rather than a nicety; ⌘C copies the one under the selection.
/// * **a day you can find.** `// TODAY`, `// TUE 9 SEP`, each carrying the
///   number of pages that day holds *in the record*, not the number that
///   happen to be loaded.
/// * **a delete you agreed to.** ⌘⌫ asks first, and names the full address in
///   the asking, because the old one deleted one of two identical-looking rows
///   instantly with no way to tell which. And there is finally a way to clear.
///
/// It does not hide on deactivate the way a palette does. A palette that loses
/// focus has lost a query worth one second of typing; this has a scroll position
/// four hundred rows down, and ⌘-Tab to read something is not a decision to
/// close it.
@MainActor
final class HistoryWindow: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    /// Internal so a test can drive the list without a window server.
    private(set) var model = HistoryBrowseModel()

    private let store: StripStore
    private let onOpen: (String) -> Void

    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let footerLeft = NSTextField(labelWithString: "")
    private let footerRight = NSTextField(labelWithString: "")

    private var rows: [HistoryBrowseModel.Row] = []
    /// Per-day totals, asked of the ledger once each. Dropped whole whenever
    /// anything is deleted: a stale count on a header is the precise failure
    /// this window exists to stop printing.
    private var dayCounts: [Date: UInt32] = [:]
    /// Guards against a second page being asked for while the first is in
    /// flight, which would append the same 120 rows twice.
    private var isLoading = false
    private var heightCache: [String: CGFloat] = [:]
    private var measuredWidth: CGFloat = 0

    private var whileOpen: HistoryWindow?
    private var monitor: Any?

    private enum Layout {
        /// Where both lines of a row start. One column, so the title and the
        /// address it belongs to share an edge.
        static let textLeading: CGFloat = 18
        static let textTrailing: CGFloat = 118
        static let dayHeight: CGFloat = 30
        /// The title line plus the padding above and below both lines.
        static let chrome: CGFloat = 34
        /// A page that never produced a `<title>` has one line, not two: its
        /// address *is* its name, and printing it twice was a row that looked
        /// like a bug in the list.
        static let untitledChrome: CGFloat = 16
        /// Four lines of address. At 11pt JetBrains Mono across this window that
        /// is around 440 characters — past the longest thing in the owner's
        /// record, which is a Grafana dashboard link at 212. Bounded rather than
        /// unbounded so one pathological row cannot become the whole screen;
        /// ⌘C is the way out of that case.
        static let urlLines = 4
    }

    init(store: StripStore, onOpen: @escaping (String) -> Void) {
        self.store = store
        self.onOpen = onOpen
        let panel = SquarePanel(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            // Resizable, unlike every other panel here: the one complaint this
            // window answers is "no room", so how much room it gets is the
            // reader's call. Borderless for the square edge — see `SquarePanel`.
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.minSize = NSSize(width: 560, height: 320)
        super.init(window: panel)
        panel.delegate = self
        panel.contentView = buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - building

    private func buildContent() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.laneBackground.cgColor
        content.layer?.borderColor = Theme.laneBorder.cgColor
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        let header = SectionHeader(text: "HISTORY")

        field.placeholderString = "Search every page you have been to…"
        field.font = Theme.mono(13)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self

        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected)
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        let clear = AskButton(label: "Clear…", isDefault: false)
        clear.onClick = { [weak self, weak clear] in
            guard let self, let clear else { return }
            self.offerClear(from: clear)
        }

        footerRight.alignment = .right
        for label in [footerLeft, footerRight] {
            label.font = Theme.mono(10, weight: .medium)
            label.textColor = Theme.dimText
            label.lineBreakMode = .byTruncatingTail
            label.usesSingleLineMode = true
        }
        footerRight.stringValue = "↩ open   ⌘C copy   ⌘⌫ forget   esc"

        let rule = NSBox()
        rule.boxType = .separator
        let footerRule = NSBox()
        footerRule.boxType = .separator

        for v in [header, field, rule, scroll, footerRule, footerLeft, footerRight, clear] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),

            field.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            clear.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            clear.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 8),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),

            footerLeft.leadingAnchor.constraint(equalTo: clear.trailingAnchor, constant: 14),
            footerLeft.centerYAnchor.constraint(equalTo: clear.centerYAnchor),

            footerRight.centerYAnchor.constraint(equalTo: clear.centerYAnchor),
            footerRight.leadingAnchor.constraint(
                greaterThanOrEqualTo: footerLeft.trailingAnchor, constant: 12),
            footerRight.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
        footerLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return content
    }

    // MARK: - showing and hiding

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        whileOpen = self
        if let parent {
            let f = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: f.midX - panel.frame.width / 2,
                y: f.midY - panel.frame.height / 2 + f.height * 0.06))
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        installKeyMonitor()
        restart()
    }

    func dismiss() {
        guard whileOpen != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        whileOpen = nil
    }

    /// Losing focus is not closing. See the type's note.
    func windowDidResignKey(_ notification: Notification) {}

    /// A wider window fits more of an address on a line, so every measured
    /// height is wrong until it is measured again.
    func windowDidResize(_ notification: Notification) {
        guard table.bounds.width != measuredWidth else { return }
        heightCache.removeAll()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            let command = event.modifierFlags.contains(.command)
            switch event.keyCode {
            case 53: self.dismiss(); return nil                          // esc
            case 36, 76: self.openSelected(); return nil                 // return
            case 125: self.move(by: 1); return nil                       // down
            case 126: self.move(by: -1); return nil                      // up
            // ⌘⌫, never plain ⌫: the field above is where you fix a typo in the
            // search, and a list that deletes rows while you edit the query is
            // a trap. Same rule the palette follows.
            case 51 where command: self.forgetSelected(); return nil
            case 8 where command: self.copySelected(); return nil        // ⌘C
            default: return event
            }
        }
    }

    // MARK: - loading

    /// Throw the list away and read the first page. Every keystroke does this.
    ///
    /// Internal rather than private so the render sheet can fill the table
    /// without a window server — presenting is the one thing a test cannot do,
    /// and it is not the thing worth looking at.
    func restart() {
        model.restart(query: query)
        dayCounts.removeAll()
        heightCache.removeAll()
        isLoading = false
        loadNextPage()
    }

    private var query: String {
        // Not `field.stringValue`: while a field is being edited its text lives
        // in the window's field editor and the cell catches up only when editing
        // ends, so reading it here searches for the empty string forever.
        (window?.fieldEditor(false, for: field) as? NSText)?.string ?? field.stringValue
    }

    func controlTextDidChange(_ obj: Notification) { restart() }

    private func loadNextPage() {
        guard !isLoading, !model.exhausted else { return }
        isLoading = true
        let limit = HistoryBrowseModel.pageSize
        model.append(store.historyPage(model.query, offset: model.nextOffset, limit: limit),
                     limit: limit)
        isLoading = false
        rebuild()
    }

    private func rebuild() {
        let previous = table.selectedRow
        rows = model.rows { [weak self] start, end in
            guard let self else { return 0 }
            if let known = self.dayCounts[start] { return known }
            let count = self.store.historyDayCount(from: start, to: end)
            self.dayCounts[start] = count
            return count
        }
        table.reloadData()
        if previous >= 0, previous < rows.count {
            table.selectRowIndexes(IndexSet(integer: previous), byExtendingSelection: false)
        } else if let first = rows.firstIndex(where: { isSelectable($0) }) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
        }
        updateFooter()
    }

    /// One sentence, and it may only claim what is true of the list under it.
    ///
    /// A footer that counts the table while describing a list that cannot reach
    /// all of it is the failure round 2 fixed in the palette, so the numbers here
    /// are deliberately about two different things and say which is which: how
    /// much has been read, and how much there is. The `+` on a search is the
    /// same honesty — the ranking is over everything, but only the rows asked for
    /// have been counted, so "12 matches" would be a number about the paging
    /// rather than about the corpus.
    private func updateFooter() {
        let total = Self.thousands(store.historyCount)
        let loaded = Self.thousands(UInt32(model.loadedCount))
        let text: String
        if model.query.isEmpty {
            text = model.exhausted
                ? "\(total) pages"
                : "\(loaded) of \(total) pages loaded"
        } else {
            // "in", not "of": the search reached all of them, and only this many
            // have been read back. `of` would read as a search that stopped.
            text = "\(loaded)\(model.exhausted ? "" : "+") matches in \(total) pages"
        }
        footerLeft.attributedStringValue = PaletteStyle.caps(text)
    }

    // MARK: - the table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return Layout.dayHeight }
        switch rows[row] {
        case .day: return Layout.dayHeight
        case .page(let entry):
            return (HistoryEntryRow.name(of: entry) == nil
                ? Layout.untitledChrome : Layout.chrome) + urlHeight(entry.url)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        row < rows.count && isSelectable(rows[row])
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        // The trigger for the next page: asking for a row near the end means the
        // reader is near the end. A scroll observer would be the other way to do
        // it and would miss the case that matters — a window tall enough that
        // one page does not fill it, where nothing ever scrolls.
        if row >= rows.count - 12 { Task { @MainActor [weak self] in self?.loadNextPage() } }
        switch rows[row] {
        case .day(let day):
            return HistoryDayRow(day: day)
        case .page(let entry):
            return HistoryEntryRow(
                entry: entry, query: model.query, urlLines: Layout.urlLines,
                leading: Layout.textLeading, trailing: Layout.textTrailing)
        }
    }

    private func isSelectable(_ row: HistoryBrowseModel.Row) -> Bool {
        if case .page = row { return true }
        return false
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        var next = table.selectedRow + delta
        while next >= 0, next < rows.count, !isSelectable(rows[next]) { next += delta }
        guard next >= 0, next < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        // Bring the day header above a day's first row into view with it, or the
        // reader loses which day they are in at exactly the moment it changes.
        if next > 0, !isSelectable(rows[next - 1]) { table.scrollRowToVisible(next - 1) }
        table.scrollRowToVisible(next)
    }

    private var selectedEntry: HistoryEntry? {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .page(let entry) = rows[row] else { return nil }
        return entry
    }

    /// Four lines at most, and the width is the one the table actually has.
    ///
    /// A URL has no spaces, so the default word-wrapping measurement reports one
    /// very long line and every row would be 34 points tall with the address cut
    /// off — which is the bug, drawn differently.
    private func urlHeight(_ url: String) -> CGFloat {
        let width = max(200, table.bounds.width - Layout.textLeading - Layout.textTrailing)
        if width != measuredWidth {
            measuredWidth = width
            heightCache.removeAll()
        }
        if let cached = heightCache[url] { return cached }
        let font = Theme.mono(11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let line = ceil(font.ascender - font.descender + font.leading)
        let measured = (url as NSString).boundingRect(
            with: NSSize(width: width, height: line * CGFloat(Layout.urlLines)),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph]).height
        let height = min(ceil(measured), line * CGFloat(Layout.urlLines))
        heightCache[url] = height
        return height
    }

    // MARK: - what the keys do

    @objc private func openSelected() {
        guard let entry = selectedEntry else { return }
        onOpen(entry.url)
    }

    private func copySelected() {
        guard let entry = selectedEntry else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
    }

    /// ⌘⌫, which used to be instant and is now a question with the address in it.
    ///
    /// The alert is put off to the next turn of the run loop rather than opened
    /// from inside the key monitor: a modal loop started during event dispatch
    /// re-enters the monitor with the alert's own keystrokes, so the ⌫ that
    /// opened the question can arrive again inside it.
    private func forgetSelected() {
        guard let entry = selectedEntry else { return }
        Task { @MainActor [weak self] in self?.confirmForget(entry) }
    }

    private func confirmForget(_ entry: HistoryEntry) {
        guard confirm(HistoryBrowseModel.forgetPrompt(entry), action: "Forget") else { return }
        store.forgetVisit(entry.url)
        // Also the recents list, for the reason the palette gives: a page
        // launched from a terminal is in both, and forgetting one of them leaves
        // the row on screen.
        store.forgetRecent(.url, entry.url)
        model.forget(url: entry.url)
        dayCounts.removeAll()
        rebuild()
    }

    private func offerClear(from anchor: NSView) {
        let menu = NSMenu()
        for range in HistoryClearRange.allCases {
            let item = NSMenuItem(
                title: range.title, action: #selector(clearRange(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = range
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func clearRange(_ sender: NSMenuItem) {
        guard let range = sender.representedObject as? HistoryClearRange else { return }
        let cutoff = range.cutoff()
        // The count comes from the ledger before the dialog opens, so the
        // sentence the user agrees to is about the pages that will actually go.
        let pages = store.historyDayCount(from: cutoff, to: Date(timeIntervalSince1970: 4e9))
        guard pages > 0 else {
            // Saying so beats a confirmation for a no-op, which teaches people
            // to click through confirmations.
            let alert = NSAlert()
            alert.messageText = "Nothing to forget in \(range.phrase)."
            alert.alertStyle = .informational
            alert.beginSheetModal(for: window!, completionHandler: nil)
            return
        }
        guard confirm(HistoryBrowseModel.clearPrompt(range, pages: pages), action: "Forget")
        else { return }
        store.clearHistory(since: cutoff)
        restart()
    }

    /// A destructive confirmation, with Cancel as the default button.
    ///
    /// Return therefore cancels. That is the right way round for a dialog that
    /// appears on a ⌘⌫ someone may have typed by reflex, and it is the only
    /// place in this app where ↩ does not mean "go ahead".
    private func confirm(_ prompt: (message: String, detail: String), action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action)
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func thousands(_ n: UInt32) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

/// `// TUE 9 SEP ………… 41 PAGES`
///
/// The count is on the header rather than nowhere because paging makes the
/// alternative dishonest: a reader who has loaded 12 of a day's 41 pages and is
/// told nothing concludes the day had 12.
final class HistoryDayRow: NSTableCellView {
    init(day: HistoryBrowseModel.Day) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithAttributedString: PaletteStyle.caps(day.title, size: 11))
        let count = PaletteStyle.label(
            "\(HistoryWindow.thousands(day.count)) \(day.count == 1 ? "page" : "pages")",
            Theme.mono(10, weight: .bold), Theme.dimText.withAlphaComponent(0.8))
        count.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        for v in [title, count] { addSubview(v) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            title.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            count.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// One page: what it was called, when you were last there, how many times — and
/// the whole address, wrapped rather than cut.
///
/// A page with no `<title>` gets one line instead of two. Its address is its
/// name, and a row that printed the same URL twice — once as a headline, once as
/// the detail under it — read as a rendering bug rather than as an untitled page.
final class HistoryEntryRow: NSTableCellView {
    /// What to call this page, or `nil` when the only name it has is its address.
    static func name(of entry: HistoryEntry) -> String? {
        guard let title = entry.title, !title.isEmpty, title != entry.url else { return nil }
        return title
    }

    init(
        entry: HistoryEntry, query: String, urlLines: Int,
        leading: CGFloat, trailing: CGFloat
    ) {
        super.init(frame: .zero)
        let name = Self.name(of: entry)

        let when = Date(timeIntervalSince1970: Double(entry.lastVisitAt) / 1000)
        let stamp = PaletteStyle.label(HistoryClock.stamp(when), Theme.mono(11), Theme.dimText)
        stamp.alignment = .right

        let count = PaletteStyle.label(
            entry.visitCount > 1 ? "×\(entry.visitCount)" : "",
            Theme.mono(10, weight: .bold), Theme.dimText.withAlphaComponent(0.8))
        count.alignment = .right

        // The whole point of the row. Word wrapping has nothing to break on in a
        // URL, so it would report one long line and truncate it — which is the
        // failure being fixed, with extra steps.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let address = NSTextField(labelWithString: "")
        let painted = NSMutableAttributedString(attributedString: PaletteStyle.highlighted(
            entry.url, matches: MatchQuality.offsets(query, in: entry.url, literal: true),
            size: 11, color: name == nil ? .labelColor : Theme.dimText))
        painted.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: 0, length: painted.length))
        address.attributedStringValue = painted
        address.maximumNumberOfLines = urlLines
        address.lineBreakMode = .byCharWrapping
        address.usesSingleLineMode = false
        address.cell?.wraps = true
        // The escape hatch for the row long enough that even four lines cut it.
        address.toolTip = entry.url

        var views: [NSView] = [stamp, count, address]
        let title = name.map { text -> NSTextField in
            let f = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
                text, matches: MatchQuality.offsets(query, in: text, literal: true),
                color: .labelColor))
            f.usesSingleLineMode = true
            f.lineBreakMode = .byTruncatingTail
            return f
        }
        if let title { views.append(title) }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Whichever line is first carries the stamp and the visit count, so the
        // right-hand column lines up with the top of the row either way.
        let head: NSView = title ?? address
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            count.trailingAnchor.constraint(equalTo: stamp.leadingAnchor, constant: -12),
            count.topAnchor.constraint(equalTo: head.topAnchor),

            stamp.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stamp.widthAnchor.constraint(equalToConstant: 84),
            stamp.topAnchor.constraint(equalTo: head.topAnchor),

            address.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            address.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
        ])
        if let title {
            NSLayoutConstraint.activate([
                title.trailingAnchor.constraint(equalTo: count.leadingAnchor, constant: -10),
                address.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            ])
            title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        count.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
