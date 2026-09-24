import AppKit

/// What ⌥⌘J lists: every session waiting on a person or finished and not
/// yet looked at, one row each, BLOCKED before DONE and each in strip order
/// (ADR-0037). Pure: the rows, the selection and what ⌫ may do.
struct AttentionList: Equatable {
    struct Row: Equatable {
        let key: SessionKey
        let state: AgentState
        let title: String
        /// `~/code/max-pane`, or `yorkshire:/home/spierce/x`.
        let path: String
        let age: String
        /// Whether a lane holds it; a row with none is attached on ↩.
        let hasLane: Bool
    }

    private(set) var rows: [Row]
    private(set) var selected: Int = 0

    /// BLOCKED first, then DONE; inside each, lanes in strip order and then
    /// sessions with no lane (the sidebar's, newest activity first). A
    /// session that is offline is `.unknown` and never listed (ADR-0023).
    init(sessions: [SessionTelemetry], laneIndex: (SessionKey) -> Int?, now: Date = Date()) {
        let wanted = sessions.filter { $0.isRunning && ($0.state == .blocked || $0.state == .done) }
        let ordered = wanted.map { (t: $0, lane: laneIndex($0.key)) }.sorted { a, b in
            if a.t.state.rank != b.t.state.rank { return a.t.state.rank < b.t.state.rank }
            switch (a.lane, b.lane) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (a.t.lastActivity ?? .distantPast) > (b.t.lastActivity ?? .distantPast)
            }
        }
        rows = ordered.map { entry in
            let t = entry.t
            let title = t.title.trimmingCharacters(in: .whitespaces).isEmpty ? t.command : t.title
            return Row(
                key: t.key, state: t.state, title: title, path: t.groupPath,
                age: t.lastActivity.map { SessionTelemetry.age(since: $0, now: now) } ?? "",
                hasLane: entry.lane != nil)
        }
    }

    var isEmpty: Bool { rows.isEmpty }
    var current: Row? { rows.indices.contains(selected) ? rows[selected] : nil }
    /// `// ATTENTION · 3`.
    var header: String { "ATTENTION · \(rows.count)" }

    mutating func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta % rows.count + rows.count) % rows.count
    }

    mutating func select(_ index: Int) {
        guard rows.indices.contains(index) else { return }
        selected = index
    }

    /// The rows ⌫ and ⌘⌫ may take away: a DONE is dismissed by looking at
    /// it, and this is looking. A BLOCKED is a question, and stays until it
    /// is answered.
    var dismissable: Row? { current.flatMap { $0.state == .done ? $0 : nil } }
    var dismissableAll: [Row] { rows.filter { $0.state == .done } }

    /// The list after the registry changed, keeping the selection on the
    /// same session where it still exists, else where it was, else the end.
    mutating func replace(with next: AttentionList) {
        let keep = current?.key
        rows = next.rows
        if let keep, let at = rows.firstIndex(where: { $0.key == keep }) {
            selected = at
        } else {
            selected = min(selected, max(0, rows.count - 1))
        }
    }
}

/// ⌥⌘J: the ATTENTION list, hung from the status bar's count.
///
/// A `Popup` for the square panel, the fade, Esc and click-away, as the
/// changelog's and the volume's are. ↑ ↓ move, ↩ goes to the row (opening a
/// fold, attaching a lane-less session), ⌫ dismisses a DONE, ⌘⌫ dismisses
/// every DONE; a click on a row goes. Rows are grey; the BLOCKED chip is the
/// filled, breathing one the sidebar draws and DONE is the only orange. The
/// list follows the registry while it is open, so a row answered from a
/// phone leaves it as it leaves the sidebar.
@MainActor
final class AttentionPopup: Popup {
    static let width: CGFloat = 480
    static let rowHeight: CGFloat = 40
    private static let inset: CGFloat = 20
    private static let chromeHeight: CGFloat = 76
    private static let maxRows = 10

    private(set) var list: AttentionList
    private let stack = NSStackView()
    private let header: SectionHeader
    private let hint = NSTextField(labelWithString: "")
    private var rowViews: [AttentionRowView] = []
    private var notice: NSTextField?
    private var keyMonitor: Any?

    var onGo: ((SessionKey) -> Void)?
    var onDismiss: ((SessionKey) -> Void)?

    /// The header as drawn, for tests.
    var headerText: String { header.stringValue }
    /// The row titles as drawn, for tests.
    var rowTitles: [String] { rowViews.map(\.titleText) }
    var selectedIndex: Int { list.selected }
    var noticeText: String? { notice?.stringValue }

    /// The panel's size for `count` rows: the rows, up to ten, then a scroll.
    static func size(rows count: Int) -> NSSize {
        NSSize(width: width, height: chromeHeight + rowHeight * CGFloat(min(max(count, 1), maxRows)))
    }

    /// Non-modal and closes when the keyboard goes elsewhere: it is a place
    /// to go from, and a click on the strip is going.
    init(list: AttentionList) {
        self.list = list
        header = SectionHeader(text: list.header)
        super.init(size: Self.size(rows: list.rows.count), dismissal: .clickAway)

        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        hint.font = Theme.mono(10, weight: .medium)
        hint.textColor = Theme.dimText
        hint.alignment = .right
        let rule = NSBox()
        rule.boxType = .separator

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.wantsLayer = true
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        let document = AttentionFlippedView()
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        for view in [header, hint, rule, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let edge = Theme.borderWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edge),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset - 8),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -(Self.inset - 8)),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        window?.contentView = content
        render()
    }

    /// The registry moved: the same list, re-read. Rows come and go with a
    /// fade of the column rather than a jump.
    func update(_ next: AttentionList) {
        guard next.rows != list.rows else { return }
        list.replace(with: next)
        Motion.fade(stack.layer)
        render()
    }

    private func render() {
        header.setText(list.header)
        hint.stringValue = list.isEmpty ? "esc" : (list.dismissable != nil ? "↩ go · ⌫ dismiss · esc" : "↩ go · esc")
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rowViews = []
        notice = nil
        if list.isEmpty {
            let label = NSTextField(labelWithString: "Nothing needs you.")
            label.font = Theme.mono(11)
            label.textColor = Theme.dimText
            notice = label
            stack.addArrangedSubview(label)
            stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 6, right: 0)
            return
        }
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        for (index, row) in list.rows.enumerated() {
            let view = AttentionRowView(row: row)
            view.onClick = { [weak self] in
                guard let self else { return }
                self.list.select(index)
                self.go()
            }
            rowViews.append(view)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            view.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        markSelection()
    }

    private func markSelection() {
        for (index, view) in rowViews.enumerated() { view.isSelected = index == list.selected }
    }

    func move(by delta: Int) {
        list.moveSelection(by: delta)
        markSelection()
        if let view = rowViews.indices.contains(list.selected) ? rowViews[list.selected] : nil {
            view.scrollToVisible(view.bounds)
        }
    }

    /// ↩, or a click: to the row's session, and the list closes behind it.
    func go() {
        guard let row = list.current else { return }
        closePopup()
        onGo?(row.key)
    }

    /// ⌫: the selected DONE is looked at. A BLOCKED row stays.
    func dismiss() {
        guard let row = list.dismissable else { return }
        onDismiss?(row.key)
    }

    /// ⌘⌫: every DONE.
    func dismissAll() {
        for row in list.dismissableAll { onDismiss?(row.key) }
    }

    override func popupDidPresent() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// The keys, as a function of the event so a test can send one.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 126: move(by: -1); return true            // ↑
        case 125: move(by: 1); return true             // ↓
        case 36, 76: go(); return true                 // ↩, enter
        case 51:                                       // ⌫
            if flags.contains(.command) { dismissAll() } else { dismiss() }
            return true
        default: return false
        }
    }

    override func closePopup(animated: Bool = true, completion: (() -> Void)? = nil) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        super.closePopup(animated: animated, completion: completion)
    }
}

/// One session: its chip, its title, its directory and its age; a
/// full-perimeter outline when it is the one selected.
@MainActor
final class AttentionRowView: NSView {
    var onClick: (() -> Void)?
    private let chip = PulseLabel(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let path = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")

    var titleText: String { title.stringValue }
    var chipText: String { chip.stringValue.trimmingCharacters(in: .whitespaces) }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            layerBorderColor = isSelected ? Theme.accent : NSColor.clear
        }
    }

    init(row: AttentionList.Row) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layerBorderColor = NSColor.clear

        let ink = Theme.agentStateColor(row.state)
        let blocked = row.state == .blocked
        chip.stringValue = " \(row.state.chipText) "
        chip.font = Theme.mono(8, weight: blocked ? .bold : .medium)
        chip.textColor = blocked ? Theme.onBlocked : ink
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 0
        chip.layer?.borderWidth = 1
        chip.layerBorderColor = ink
        chip.layerBackgroundColor = blocked ? ink : NSColor.clear
        chip.isPulsing = blocked
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.stringValue = row.title
        title.font = Theme.mono(11, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        path.stringValue = row.hasLane ? row.path : "\(row.path) · not on the strip"
        path.font = Theme.mono(9)
        path.textColor = Theme.dimText
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        age.stringValue = row.age
        age.font = Theme.mono(9)
        age.textColor = Theme.dimText
        age.alignment = .right
        age.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [chip, title, path, age] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.widthAnchor.constraint(equalToConstant: 58),
            title.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            title.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -8),
            path.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            path.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
            path.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -8),
            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            age.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    @objc private func clicked() { onClick?() }
}

private final class AttentionFlippedView: NSView {
    override var isFlipped: Bool { true }
}
