import AppKit
import LanedCore

/// PRD §7.6 — the left-edge list of lanes in strip order.
///
/// Ordinal order, always. The sidebar may *visually* group past 50 lanes, but it
/// never implies the strip is grouped, and clicking a row scrolls the strip
/// rather than rearranging it.
@MainActor
final class SidebarViewController: NSViewController {
    private let store: StripStore
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private var rows: [Row] = []
    private var observer: UUID?

    /// Click → search-to-scroll.
    var onSelect: ((String) -> Void)?

    /// A group header only exists once the list is long enough to need one.
    private enum Row {
        case group(String, count: Int)
        case lane(Lane)
    }

    init(store: StripStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = 26
        outline.indentationPerLevel = 0
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.menu = contextMenu()

        let column = NSTableColumn(identifier: .init("lane"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observer = store.observe { [weak self] state in self?.rebuild(state) }
    }

    deinit {
        // `observer` is only read here; the store outlives the sidebar.
        if let observer { MainActor.assumeIsolated { store.stopObserving(observer) } }
    }

    /// Past 50 lanes the flat list stops being scannable, so rows get grouped by
    /// project tag — visually, in the sidebar, and nowhere else.
    private func rebuild(_ state: StripState) {
        let lanes = state.lanes
        if lanes.count <= 50 {
            rows = lanes.map { .lane($0) }
        } else {
            var built: [Row] = []
            var lastGroup: String? = nil
            var counts: [String: Int] = [:]
            for lane in lanes {
                counts[lane.projectRoot ?? "", default: 0] += 1
            }
            for lane in lanes {
                let key = lane.projectRoot ?? ""
                if key != lastGroup {
                    let label = key.isEmpty ? "Untagged" : (key as NSString).lastPathComponent
                    built.append(.group(label, count: counts[key] ?? 0))
                    lastGroup = key
                }
                built.append(.lane(lane))
            }
            rows = built
        }
        outline.reloadData()

        if let focused = state.focusedPaneId,
           let laneId = store.lane(containing: focused)?.id,
           let index = rows.firstIndex(where: { if case .lane(let l) = $0 { return l.id == laneId } else { return false } }) {
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    @objc private func rowClicked() {
        guard outline.clickedRow >= 0, outline.clickedRow < rows.count else { return }
        if case .lane(let lane) = rows[outline.clickedRow] { onSelect?(lane.id) }
    }

    // MARK: - context menu (§7.6: pin/unpin, set manual tag, close)

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Pin", action: #selector(togglePin), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Set Project Tag…", action: #selector(setTag), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Lane", action: #selector(closeLane), keyEquivalent: "").target = self
        return menu
    }

    private func clickedLane() -> Lane? {
        guard outline.clickedRow >= 0, outline.clickedRow < rows.count,
              case .lane(let lane) = rows[outline.clickedRow] else { return nil }
        return lane
    }

    @objc private func togglePin() {
        guard let lane = clickedLane() else { return }
        try? store.setPinned(lane.id, !lane.pinned)
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
}

extension SidebarViewController: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        index
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }
}

extension SidebarViewController: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let index = item as? Int, index < rows.count else { return nil }
        switch rows[index] {
        case .group(let label, let count):
            return SidebarGroupView(label: label, count: count)
        case .lane(let lane):
            return SidebarLaneView(lane: lane, isLive: lane.panes.contains { $0.state == .live })
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        guard let index = item as? Int, index < rows.count else { return false }
        if case .group = rows[index] { return true }
        return false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !self.outlineView(outlineView, isGroupItem: item)
    }
}
