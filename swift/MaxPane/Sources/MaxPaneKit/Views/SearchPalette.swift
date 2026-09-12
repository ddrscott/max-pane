import AppKit
import LanedCore

/// A floating list over the strip, used by both ⌘P (search) and ⌘O (attach a
/// session). Both are "type, filter, pick one, dismiss".
@MainActor
class PaletteController: NSWindowController, NSTextFieldDelegate {
    let field = NSTextField()
    let table = NSTableView()
    private let scroll = NSScrollView()
    private var monitor: Any?

    init(placeholder: String) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        super.init(window: panel)

        field.placeholderString = placeholder
        field.font = Theme.mono(16)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self

        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(commit)
        let column = NSTableColumn(identifier: .init("hit"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.laneBackground.cgColor
        content.layer?.borderColor = Theme.laneBorder.cgColor
        content.layer?.borderWidth = Theme.borderWidth
        // Square. A rounded palette is the thing this project is not.
        content.layer?.cornerRadius = 0

        let rule = NSBox()
        rule.boxType = .separator

        for v in [field, rule, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        if let parent {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - panel.frame.width / 2,
                y: frame.midY - panel.frame.height / 2 + frame.height * 0.15))
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        installKeyMonitor()
        reload()
    }

    /// Arrow keys move the selection, Return commits, Esc cancels — all while
    /// the text field keeps focus, which `NSTableView` will not do on its own.
    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 125: self.move(by: 1); return nil    // down
            case 126: self.move(by: -1); return nil   // up
            case 36, 76: self.commit(); return nil    // return, enter
            case 53: self.cancel(); return nil        // esc
            default: return event
            }
        }
    }

    private func move(by delta: Int) {
        let count = numberOfRows()
        guard count > 0 else { return }
        let next = max(0, min(count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    func reload() {
        table.reloadData()
        if numberOfRows() > 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc func commit() { dismiss(selected: table.selectedRow) }

    func cancel() { dismiss(selected: -1) }

    func dismiss(selected: Int) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.parent?.removeChildWindow(window!)
        window?.orderOut(nil)
        deliver(selected: selected)
    }

    // MARK: - subclass hooks

    func numberOfRows() -> Int { 0 }
    func view(forRow row: Int) -> NSView? { nil }
    func deliver(selected: Int) {}
}

extension PaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { numberOfRows() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        view(forRow: row)
    }
}

/// ⌘P — PRD §7.5. Fuzzy over titles, project roots, URLs and the last 200 lines
/// of each terminal's scrollback.
@MainActor
final class SearchPaletteController: PaletteController {
    private let store: StripStore
    private var hits: [SearchHit] = []
    private let completion: (SearchHit?) -> Void

    init(store: StripStore, completion: @escaping (SearchHit?) -> Void) {
        self.store = store
        self.completion = completion
        super.init(placeholder: "Search lanes, URLs, output…")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func reload() {
        // Spike M3 measured search at 0.58 ms across 300 lanes and 8 600
        // scrollback lines, so there is no debounce: it runs per keystroke.
        hits = store.search(field.stringValue)
        super.reload()
    }

    override func numberOfRows() -> Int { hits.count }

    override func view(forRow row: Int) -> NSView? {
        guard row < hits.count else { return nil }
        let hit = hits[row]
        let lane = store.lane(hit.laneId)
        return PaletteRow(
            glyph: Self.glyph(hit.field),
            primary: hit.text,
            secondary: lane?.projectRoot.map { ($0 as NSString).lastPathComponent } ?? "")
    }

    override func deliver(selected: Int) {
        completion(selected >= 0 && selected < hits.count ? hits[selected] : nil)
    }

    private static func glyph(_ field: SearchField) -> String {
        switch field {
        case .title: return "▸"
        case .projectRoot: return "/"
        case .url: return "◍"
        case .scrollback: return "$"
        }
    }
}

/// ⌘O — PRD §7.1's picker of Relay sessions not currently attached.
@MainActor
final class SessionPickerController: PaletteController {
    private let all: [RelaySession]
    private var shown: [RelaySession] = []
    private let completion: (RelaySession?) -> Void

    init(sessions: [RelaySession], completion: @escaping (RelaySession?) -> Void) {
        self.all = sessions
        self.shown = sessions
        self.completion = completion
        super.init(placeholder: "Attach a Relay session…")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func reload() {
        let q = field.stringValue.lowercased()
        shown = q.isEmpty ? all : all.filter {
            $0.displayName.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
        }
        super.reload()
    }

    override func numberOfRows() -> Int { shown.count }

    override func view(forRow row: Int) -> NSView? {
        guard row < shown.count else { return nil }
        let s = shown[row]
        return PaletteRow(
            glyph: "$",
            primary: s.displayName,
            secondary: (s.cwd as NSString).lastPathComponent)
    }

    override func deliver(selected: Int) {
        completion(selected >= 0 && selected < shown.count ? shown[selected] : nil)
    }
}

/// One row: an orange marker, the match, and where it lives.
final class PaletteRow: NSTableCellView {
    init(glyph: String, primary: String, secondary: String) {
        super.init(frame: .zero)
        let g = NSTextField(labelWithString: glyph)
        g.font = Theme.mono(12, weight: .medium)
        g.textColor = Theme.accent

        let p = NSTextField(labelWithString: primary)
        p.font = Theme.mono(13)
        p.lineBreakMode = .byTruncatingTail

        let s = NSTextField(labelWithString: secondary)
        s.font = Theme.mono(11)
        s.textColor = Theme.dimText
        s.alignment = .right
        s.lineBreakMode = .byTruncatingHead

        for v in [g, p, s] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            g.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            g.centerYAnchor.constraint(equalTo: centerYAnchor),
            g.widthAnchor.constraint(equalToConstant: 14),

            p.leadingAnchor.constraint(equalTo: g.trailingAnchor, constant: 8),
            p.centerYAnchor.constraint(equalTo: centerYAnchor),

            s.leadingAnchor.constraint(greaterThanOrEqualTo: p.trailingAnchor, constant: 12),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            s.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        p.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
