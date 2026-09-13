import AppKit
import LanedCore

/// PRD §7.6 — the left edge. A session *browser*, not a list of lanes.
///
/// The thing the RelayTTY web app gets right, and the reason this was rewritten:
/// it shows every session that exists, grouped by project, with enough state per
/// row (dot, agent glyph, throughput, age) that you can tell at a glance which
/// of ten agents is working and which is waiting on you. A list of the lanes you
/// already pulled onto the strip cannot answer either question, because the
/// session you most need to see is exactly the one that is not on the strip yet.
///
/// So the rows come from the registry first and the strip second. A row with a
/// lane scrolls the strip to it; a row without one attaches it. Web lanes have
/// no session at all and file under their project tag beside the agent that
/// opened them.
@MainActor
final class SidebarViewController: NSViewController {
    private let store: StripStore
    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private var rows: [SidebarModel.Row] = []
    private var controls = SidebarModel.Controls()
    private var observer: UUID?
    private var bookmarkObserver: UUID?
    private var bookmarks: [Bookmark] = []

    // Chrome.
    private let header = NSView()
    private let filterBar = NSView()
    private let footer = NSView()
    private let queryField = NSTextField()
    private var sortButton: SidebarButton!
    private var foldButton: SidebarButton!
    private var filterButton: SidebarButton!
    private var chips: [SidebarModel.Scope: SidebarButton] = [:]
    private let countLabel = NSTextField(labelWithString: "")
    private var filterBarHeight: NSLayoutConstraint!
    private var headerTop: NSLayoutConstraint!

    /// How far the window's close/minimise/zoom buttons reach down into the
    /// sidebar, which windowed is far enough to cover `+ NEW` and the sort
    /// controls beside it. `StripWindowController` owns the number because only
    /// the window knows it; see `TitlebarAvoidance`.
    var titlebarInset: CGFloat = 0 {
        didSet {
            guard titlebarInset != oldValue, headerTop != nil else { return }
            headerTop.constant = titlebarInset
        }
    }

    /// Session `createdAt`, which only the session file knows and telemetry does
    /// not carry. Read once per session id — the bar's default sort is by
    /// creation, and re-reading ten JSON files a second to keep it would be a
    /// silly price for a number that never changes.
    private var createdAt: [String: Double] = [:]

    /// Click a lane row → search-to-scroll to it, and hand it the keyboard.
    ///
    /// The pane comes with the lane because the row names a session and a lane
    /// holds a stack of them; the receiver falls back to the lane when it is nil.
    var onSelect: ((_ laneId: String, _ paneId: String?) -> Void)?
    /// The `+ New` action.
    var onNewSession: (() -> Void)?
    /// Click a session that has no lane → attach it.
    var onAttach: ((String) -> Void)?
    /// A kept page was clicked. The sidebar does not know where a page should
    /// go — `StripWindowController.launch` owns that, and it is the same
    /// decision ⌘O makes.
    var onOpenBookmark: ((String) -> Void)?

    /// Every session Relay knows about, attached or not.
    weak var registryBox: AnyObject?
    var registry: SessionRegistry? {
        get { registryBox as? SessionRegistry }
        set { registryBox = newValue }
    }

    /// Latest telemetry for every session.
    private(set) var telemetry: [String: SessionTelemetry] = [:]

    /// New session telemetry arrived.
    func sessionsChanged(_ next: [String: SessionTelemetry]) {
        telemetry = next
        readCreationTimes(for: next)
        rebuild(store.state)
    }

    /// The one fact the session file has that telemetry drops: when a session
    /// was created. Read once per id — it never changes, and the bar's default
    /// sort is by it.
    private func readCreationTimes(for next: [String: SessionTelemetry]) {
        let directory = RelaySessionDirectory()
        for id in next.keys where createdAt[id] == nil {
            if let file = directory.session(id) {
                createdAt[id] = file.createdAt / 1000
            } else {
                // Fall back rather than leave the sort key at zero, which would
                // pin the row to the bottom forever.
                createdAt[id] = next[id]?.lastActivity?.timeIntervalSince1970
                    ?? Date().timeIntervalSince1970
            }
        }
        createdAt = createdAt.filter { next[$0.key] != nil }
    }

    init(store: StripStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - chrome

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        // A sidebar split item is vibrant translucent chrome by default, which
        // is a different material from the strip it indexes. The browser is part
        // of the strip, so it takes the strip's ground.
        view.layer?.backgroundColor = Theme.stripBackground.cgColor

        buildHeader()
        buildFilterBar()
        buildTable()
        buildFooter()

        for v in [header, filterBar, scrollView, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }
        filterBarHeight = filterBar.heightAnchor.constraint(equalToConstant: 0)
        headerTop = header.topAnchor.constraint(equalTo: view.topAnchor, constant: titlebarInset)

        NSLayoutConstraint.activate([
            headerTop,
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 34),

            filterBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            filterBarHeight,

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 24),
        ])

        // A width the browser is actually legible at. Low priority so the split
        // view's own min/max still win when the user drags the divider.
        let width = view.widthAnchor.constraint(equalToConstant: 290)
        width.priority = .defaultLow
        width.isActive = true
    }

    private func buildHeader() {
        let newButton = SidebarButton(
            text: "+ NEW", look: .accent, size: 11,
            action: #selector(newSession), target: self)
        newButton.toolTip = "New session (⌘R)"

        foldButton = SidebarButton(
            text: "⌃⌄", look: .quiet, size: 9,
            action: #selector(toggleFold), target: self)
        foldButton.toolTip = "Collapse all projects"

        filterButton = SidebarButton(
            text: "▽", look: .quiet, size: 11,
            action: #selector(toggleFilter), target: self)
        filterButton.toolTip = "Filter sessions"

        sortButton = SidebarButton(
            text: "↓ CREATED", look: .quiet, size: 9,
            action: #selector(showSortMenu), target: self)
        sortButton.toolTip = "Sort sessions within each project"

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.laneBorder.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        for v: NSView in [newButton, foldButton, filterButton, sortButton, rule] {
            header.addSubview(v)
        }

        NSLayoutConstraint.activate([
            newButton.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 8),
            newButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            newButton.widthAnchor.constraint(equalToConstant: 52),
            newButton.heightAnchor.constraint(equalToConstant: 20),

            foldButton.leadingAnchor.constraint(greaterThanOrEqualTo: newButton.trailingAnchor, constant: 6),
            foldButton.trailingAnchor.constraint(equalTo: filterButton.leadingAnchor, constant: -4),
            foldButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            foldButton.widthAnchor.constraint(equalToConstant: 22),
            foldButton.heightAnchor.constraint(equalToConstant: 20),

            filterButton.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -4),
            filterButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            filterButton.widthAnchor.constraint(equalToConstant: 22),
            filterButton.heightAnchor.constraint(equalToConstant: 20),

            sortButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            sortButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 66),
            sortButton.heightAnchor.constraint(equalToConstant: 20),

            rule.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func buildFilterBar() {
        filterBar.wantsLayer = true
        filterBar.clipsToBounds = true

        // NSSearchField is a rounded capsule with no square variant, and even a
        // square-bezelled NSTextField draws system chrome that is lighter than
        // anything else here. So: no bezel, one hard border, the strip's ground.
        queryField.isBezeled = false
        queryField.drawsBackground = true
        queryField.backgroundColor = Theme.laneBackground
        queryField.wantsLayer = true
        queryField.layer?.cornerRadius = 0
        queryField.layer?.borderWidth = 1
        queryField.layer?.borderColor = Theme.laneBorder.cgColor
        queryField.font = Theme.mono(11)
        queryField.placeholderString = "filter…"
        queryField.focusRingType = .none
        queryField.target = self
        queryField.action = #selector(queryChanged)
        queryField.delegate = self
        queryField.translatesAutoresizingMaskIntoConstraints = false
        filterBar.addSubview(queryField)

        var previous: NSView?
        for scope in SidebarModel.Scope.allCases {
            let chip = SidebarButton(
                text: scope.label, look: .chip, size: 9,
                action: #selector(chipClicked(_:)), target: self)
            chip.isOn = scope == controls.scope
            chips[scope] = chip
            filterBar.addSubview(chip)
            NSLayoutConstraint.activate([
                chip.topAnchor.constraint(equalTo: queryField.bottomAnchor, constant: 5),
                chip.heightAnchor.constraint(equalToConstant: 17),
                chip.leadingAnchor.constraint(
                    equalTo: previous?.trailingAnchor ?? filterBar.leadingAnchor,
                    constant: previous == nil ? 8 : 4),
            ])
            previous = chip
        }

        NSLayoutConstraint.activate([
            queryField.topAnchor.constraint(equalTo: filterBar.topAnchor, constant: 6),
            queryField.leadingAnchor.constraint(equalTo: filterBar.leadingAnchor, constant: 8),
            queryField.trailingAnchor.constraint(equalTo: filterBar.trailingAnchor, constant: -8),
            queryField.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    private func buildTable() {
        table.headerView = nil
        table.rowSizeStyle = .custom
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        table.menu = NSMenu()
        table.menu?.delegate = self
        table.usesAutomaticRowHeights = false
        table.allowsEmptySelection = true

        // Only bookmarks are draggable, and only within this table. A session
        // row has no order to change — the sort control owns that — and a
        // bookmark id on the general pasteboard would mean nothing anywhere
        // else, so the type is private and the mask is `forLocal:` only.
        table.registerForDraggedTypes([.maxPaneBookmark])
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // `.gap` opens a space where the row will land. `.regular` draws a line
        // *and* highlights the row under it, which on a tree reads as "into this
        // folder" whether or not that is what the drop means.
        table.draggingDestinationFeedbackStyle = .gap

        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
    }

    private func buildFooter() {
        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.laneBorder.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false

        let version = NSTextField(labelWithString: "v" + Self.versionString)
        version.font = Theme.mono(9)
        version.textColor = Theme.dimText
        version.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = Theme.mono(9)
        countLabel.textColor = Theme.dimText
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let gear = SidebarButton(
            text: "⚙", look: .quiet, size: 11,
            action: #selector(showSettingsMenu), target: self)
        gear.layer?.borderWidth = 0
        gear.toolTip = "Settings and help"

        for v: NSView in [rule, version, countLabel, gear] { footer.addSubview(v) }

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: footer.topAnchor),
            rule.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            version.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 9),
            version.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            countLabel.leadingAnchor.constraint(equalTo: version.trailingAnchor, constant: 8),
            countLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor),

            gear.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -6),
            gear.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            gear.widthAnchor.constraint(equalToConstant: 20),
            gear.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = store.observe { [weak self] state in self?.rebuild(state) }
        // Its own subscription, because bookmarks are not the strip: a page
        // being starred may not bump `revision` and make 150 lanes diff. See
        // `StripStore.observeBookmarks`.
        bookmarkObserver = store.observeBookmarks { [weak self] in
            guard let self else { return }
            self.bookmarks = self.store.bookmarks()
            self.rebuild(self.store.state)
        }
    }

    deinit {
        // `observer` is only read here; the store outlives the sidebar.
        if let observer { MainActor.assumeIsolated { store.stopObserving(observer) } }
    }

    // MARK: - model

    /// Rebuild and diff. Telemetry ticks once a second so the age stays honest,
    /// and nearly every one of those ticks changes nothing — reloading the table
    /// anyway would drop the selection and fight the scroller for no reason.
    private func rebuild(_ state: StripState) {
        let next = SidebarModel.rows(
            lanes: state.lanes,
            telemetry: telemetry,
            created: createdAt,
            bookmarks: bookmarks,
            controls: controls)
        updateFooter(state)
        guard next != rows else {
            syncSelection(state)
            return
        }
        rows = next
        table.reloadData()
        syncSelection(state)
    }

    /// The footer is the one line that is always on screen, however far the list
    /// is scrolled — so it carries the count, and the alarm.
    private func updateFooter(_ state: StripState) {
        let count = SidebarModel.footerCount(telemetry: telemetry, lanes: state.lanes)
        let blocked = SidebarModel.blockedCount(telemetry)
        let text = NSMutableAttributedString(
            string: count,
            attributes: [.foregroundColor: Theme.dimText, .font: Theme.mono(9)])
        if blocked > 0 {
            text.append(NSAttributedString(
                string: "  \(blocked) BLOCKED",
                attributes: [
                    .foregroundColor: Theme.accent,
                    .font: Theme.mono(9, weight: .bold),
                ]))
        }
        countLabel.attributedStringValue = text
    }

    /// The focused lane is selected in the browser, so the two halves of the
    /// window always agree about where you are.
    private func syncSelection(_ state: StripState) {
        guard let focused = state.focusedPaneId,
              let laneId = store.lane(containing: focused)?.id,
              let index = rows.firstIndex(where: {
                  if case .entry(let e) = $0 { return e.laneId == laneId } else { return false }
              })
        else { return }
        guard table.selectedRow != index else { return }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    private func entry(at row: Int) -> SidebarModel.Entry? {
        guard row >= 0, row < rows.count, case .entry(let e) = rows[row] else { return nil }
        return e
    }

    private func bookmark(at row: Int) -> SidebarModel.BookmarkRow? {
        guard row >= 0, row < rows.count, case .bookmark(let b) = rows[row] else { return nil }
        return b
    }

    private func group(at row: Int) -> SidebarModel.Group? {
        guard row >= 0, row < rows.count, case .group(let g) = rows[row] else { return nil }
        return g
    }

    // MARK: - actions

    @objc private func rowClicked() {
        let row = table.clickedRow
        if let group = group(at: row) {
            if controls.collapsed.contains(group.path) {
                controls.collapsed.remove(group.path)
            } else {
                controls.collapsed.insert(group.path)
            }
            rebuild(store.state)
            return
        }
        if let kept = bookmark(at: row) {
            // A folder opens; a page opens. Same click, and the only two things
            // a row here can be.
            if kept.isFolder {
                if controls.collapsed.contains(kept.id) {
                    controls.collapsed.remove(kept.id)
                } else {
                    controls.collapsed.insert(kept.id)
                }
                rebuild(store.state)
            } else if let url = kept.url {
                onOpenBookmark?(url)
            }
            return
        }
        guard let entry = entry(at: row) else { return }
        if let laneId = entry.laneId {
            onSelect?(laneId, entry.paneId)
        } else if let sessionId = entry.sessionId {
            // The row you most need is the one not on the strip yet, so a click
            // on it does the obvious thing rather than selecting nothing.
            onAttach?(sessionId)
        }
    }

    @objc private func openBookmarkClicked() {
        guard let url = bookmark(at: table.clickedRow)?.url else { return }
        onOpenBookmark?(url)
    }

    @objc private func copyBookmarkAddress() {
        guard let url = bookmark(at: table.clickedRow)?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    /// A page goes without asking — ⌘D on the same address puts it back, and
    /// the confirmation belongs to the delete that cannot be undone. A folder
    /// asks, because it takes everything inside it and nothing puts that back.
    @objc private func removeBookmarkClicked() {
        guard let kept = bookmark(at: table.clickedRow) else { return }
        if kept.isFolder {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete the folder “\(kept.title)”?"
            alert.informativeText =
                "\(kept.detail.lowercased()) go with it. There is no undo."
            // Cancel first, so Return cancels — the rule every destructive
            // dialog in this app follows.
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Delete")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        try? store.removeBookmark(kept.id)
    }

    @objc private func moveBookmarkUp() { nudgeClickedBookmark(down: false) }
    @objc private func moveBookmarkDown() { nudgeClickedBookmark(down: true) }

    private func nudgeClickedBookmark(down: Bool) {
        guard let kept = bookmark(at: table.clickedRow) else { return }
        try? store.nudgeBookmark(kept.id, down: down)
    }

    @objc private func newSession() { onNewSession?() }

    /// Collapse everything, or open everything back up — the bar's second
    /// button, and the only way to get ten projects onto one screen.
    @objc private func toggleFold() {
        let paths = Set(rows.compactMap {
            if case .group(let g) = $0 { return g.path } else { return nil }
        })
        let folding = !paths.isEmpty && !paths.isSubset(of: controls.collapsed)
        controls.collapsed = folding ? controls.collapsed.union(paths) : []
        foldButton.isOn = folding
        foldButton.setText(folding ? "⌄⌃" : "⌃⌄")
        foldButton.toolTip = folding ? "Expand all projects" : "Collapse all projects"
        rebuild(store.state)
    }

    @objc private func toggleFilter() {
        let opening = filterBarHeight.constant == 0
        filterBarHeight.constant = opening ? 52 : 0
        filterButton.isOn = opening
        if opening {
            view.window?.makeFirstResponder(queryField)
        } else {
            // Closing the drawer has to clear the filter, or rows stay missing
            // with nothing on screen explaining why.
            queryField.stringValue = ""
            controls.query = ""
            setScope(.all)
        }
        rebuild(store.state)
    }

    @objc private func queryChanged() {
        controls.query = queryField.stringValue
        rebuild(store.state)
    }

    @objc private func chipClicked(_ sender: SidebarButton) {
        guard let scope = chips.first(where: { $0.value === sender })?.key else { return }
        setScope(scope)
        rebuild(store.state)
    }

    private func setScope(_ scope: SidebarModel.Scope) {
        controls.scope = scope
        for (key, chip) in chips { chip.isOn = key == scope }
    }

    @objc private func showSortMenu() {
        let menu = NSMenu()
        for field in SidebarModel.SortField.allCases {
            let item = menu.addItem(
                withTitle: field.label.capitalized, action: #selector(pickSort(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.rawValue
            item.state = controls.sort == field ? .on : .off
        }
        menu.addItem(.separator())
        let direction = menu.addItem(
            withTitle: controls.descending ? "Newest first" : "Oldest first",
            action: #selector(flipSort), keyEquivalent: "")
        direction.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sortButton.bounds.height + 2), in: sortButton)
    }

    @objc private func pickSort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let field = SidebarModel.SortField(rawValue: raw) else { return }
        controls.sort = field
        refreshSortButton()
        rebuild(store.state)
    }

    @objc private func flipSort() {
        controls.descending.toggle()
        refreshSortButton()
        rebuild(store.state)
    }

    private func refreshSortButton() {
        sortButton.setText("\(controls.descending ? "↓" : "↑") \(controls.sort.label)")
    }

    @objc private func showSettingsMenu(_ sender: SidebarButton) {
        let menu = NSMenu()
        let commands: [Command] = [.showHelp, .showMemory, .openSessions, .exportStrip, .importStrip]
        for command in commands {
            let item = menu.addItem(
                withTitle: command.title, action: #selector(runCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.rawValue
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Max Pane v\(Self.versionString)", action: nil, keyEquivalent: "")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -2), in: sender)
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let command = Command(rawValue: raw) else { return }
        commandHandler?.perform(command)
    }

    private var commandHandler: CommandHandling? {
        view.window?.windowController as? CommandHandling
    }

    // MARK: - context menu (§7.6: pin/unpin, set manual tag, close)

    private func clickedLane() -> Lane? {
        guard let entry = entry(at: table.clickedRow), let laneId = entry.laneId else { return nil }
        return store.state.lanes.first { $0.id == laneId }
    }

    @objc private func attachClicked() {
        guard let entry = entry(at: table.clickedRow), let sessionId = entry.sessionId else { return }
        onAttach?(sessionId)
    }

    @objc private func revealClicked() {
        guard let entry = entry(at: table.clickedRow), let laneId = entry.laneId else { return }
        onSelect?(laneId, entry.paneId)
    }

    @objc private func copySessionId() {
        guard let entry = entry(at: table.clickedRow), let sessionId = entry.sessionId else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionId, forType: .string)
    }

    @objc private func togglePin() {
        guard let lane = clickedLane() else { return }
        try? store.setKeepLive(lane.id, !lane.keepLive)
    }

    @objc private func setTag() {
        guard let lane = clickedLane() else { return }
        let alert = NSAlert()
        alert.messageText = "Project tag for this lane"
        alert.informativeText = "Sticky — the cwd tagger will not overwrite it. Empty clears it."
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = lane.projectRoot ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespaces)
        try? store.setManualTag(lane.id, value.isEmpty ? nil : value)
    }

    @objc private func closeLane() {
        guard let lane = clickedLane() else { return }
        try? store.closeLane(lane.id)
    }

    @objc private func collapseAll() {
        controls.collapsed = Set(rows.compactMap { if case .group(let g) = $0 { return g.path } else { return nil } })
        rebuild(store.state)
    }

    @objc private func expandAll() {
        controls.collapsed.removeAll()
        rebuild(store.state)
    }
}

// MARK: - menu

extension SidebarViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = { (title: String, action: Selector) in
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        if let kept = bookmark(at: table.clickedRow) {
            if !kept.isFolder {
                add("Open", #selector(openBookmarkClicked))
                add("Copy Address", #selector(copyBookmarkAddress))
                menu.addItem(.separator())
            }
            // The order of the bar is the thing the bar is for, and a drag is
            // not always the instrument: eight folders into a deliberate order
            // is eight small moves, and a menu is where you make those without
            // aiming. Offered only in the direction there is somewhere to go.
            if let place = SidebarModel.siblingPlace(rows: rows, id: kept.id) {
                if place.index > 0 { add("Move Up", #selector(moveBookmarkUp)) }
                if place.index < place.count - 1 { add("Move Down", #selector(moveBookmarkDown)) }
                if place.count > 1 { menu.addItem(.separator()) }
            }
            // A folder takes what is in it, which is what the word means and
            // what the confirmation says out loud.
            add(kept.isFolder ? "Delete Folder…" : "Stop Keeping", #selector(removeBookmarkClicked))
            return
        }
        if group(at: table.clickedRow) != nil {
            add("Collapse All", #selector(collapseAll))
            add("Expand All", #selector(expandAll))
            return
        }
        guard let entry = entry(at: table.clickedRow) else {
            add("Expand All", #selector(expandAll))
            return
        }
        if entry.laneId != nil {
            add("Reveal on Strip", #selector(revealClicked))
            add(entry.pinned ? "Stop Keeping Loaded" : Command.toggleKeepLive.title, #selector(togglePin))
            add("Set Project Tag…", #selector(setTag))
        } else if entry.sessionId != nil {
            add("Attach to Strip", #selector(attachClicked))
        }
        if entry.sessionId != nil {
            add("Copy Session ID", #selector(copySessionId))
        }
        if entry.laneId != nil {
            menu.addItem(.separator())
            add("Close Lane", #selector(closeLane))
        }
    }
}

// MARK: - filter field

extension SidebarViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { queryChanged() }
}

// MARK: - table

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        // Not while the query box has something in it. The rows on screen are
        // then a subset of the tree, and every index this drag would produce
        // counts the wrong list — a drop would land somewhere the user has no
        // way of predicting from what they can see.
        guard controls.query.trimmingCharacters(in: .whitespaces).isEmpty,
              let kept = bookmark(at: row)
        else { return nil }
        let item = NSPasteboardItem()
        item.setString(kept.id, forType: .maxPaneBookmark)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation operation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let id = draggedBookmarkId(info) else { return [] }
        var operation = operation
        // A drop *onto* anything but a folder has no meaning here — there is
        // nothing inside a kept page — so it becomes the gap above that row
        // rather than being refused, which is what the pointer was nearest to.
        if operation == .on, bookmark(at: row)?.isFolder != true {
            operation = .above
            tableView.setDropRow(row, dropOperation: .above)
        }
        guard SidebarModel.dropTarget(
            rows: rows, dragging: id, row: row, onto: operation == .on) != nil
        else { return [] }
        return .move
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation operation: NSTableView.DropOperation
    ) -> Bool {
        guard let id = draggedBookmarkId(info),
              let target = SidebarModel.dropTarget(
                  rows: rows, dragging: id, row: row, onto: operation == .on)
        else { return false }
        try? store.moveBookmark(id, to: target.parentId, at: target.index)
        return true
    }

    /// The id being dragged, and only from this table: a bookmark id arriving
    /// from anywhere else names a row in somebody else's ledger.
    private func draggedBookmarkId(_ info: NSDraggingInfo) -> String? {
        guard info.draggingSource as AnyObject? === table else { return nil }
        return info.draggingPasteboard.string(forType: .maxPaneBookmark)
    }
}

extension NSPasteboard.PasteboardType {
    /// Private to this table. Deliberately not a URL type: dropping a kept page
    /// on another app should not be a thing that half works.
    static let maxPaneBookmark = NSPasteboard.PasteboardType("app.maxpane.bookmark-row")
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return SidebarEntryView.height }
        switch rows[row] {
        case .group: return SidebarGroupView.height
        case .entry: return SidebarEntryView.height
        case .bookmark: return SidebarBookmarkView.height
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .group(let g): return SidebarGroupView(group: g)
        case .entry(let e): return SidebarEntryView(entry: e)
        case .bookmark(let b): return SidebarBookmarkView(row: b)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SidebarRowView()
        view.isTargetable = entry(at: row) != nil || bookmark(at: row) != nil
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        entry(at: row) != nil || bookmark(at: row) != nil
    }
}
