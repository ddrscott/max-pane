import AppKit
import LanedCore

/// PRD §13 Phase 2's memory dashboard: per-lane cost and evicted count.
///
/// It exists because the eviction policy is otherwise invisible. Spike M1 found
/// that WebKit's footprint can swing 57% in three and a half minutes with nobody
/// touching anything, which means "the app feels heavy" and "the app is actually
/// heavy" are different questions, and without a number you cannot tell them
/// apart.
///
/// **Per-lane cost is deliberately not claimed.** M1 established one
/// `WebContent` process per `WKWebView`, but attributing a process to a pane
/// needs `_webProcessIdentifier`, which is private API this app does not use
/// (ADR-0003). So this shows what is actually knowable — the total, the marks it
/// is measured against, and what state every pane is in — rather than a
/// convincing per-lane number that would be a guess.
@MainActor
public final class MemoryDashboard: NSPanel {
    private let store: StripStore
    private let config: Config
    private let summary = NSTextField(labelWithString: "")
    private let bar = BudgetBar()
    private let table = NSTableView()
    private var timer: Timer?
    private var rows: [Row] = []

    private struct Row {
        let lane: Lane
        let state: String
        let distance: String
    }

    public init(store: StripStore, config: Config) {
        self.store = store
        self.config = config
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        title = "Memory"
        isFloatingPanel = true
        hidesOnDeactivate = false

        summary.font = Theme.mono(11)
        summary.maximumNumberOfLines = 0

        table.headerView = nil
        table.rowHeight = 22
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        let column = NSTableColumn(identifier: .init("lane"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        for v in [summary, bar, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            summary.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            summary.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            bar.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 10),

            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
        refresh()
    }

    public override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        // Match the eviction sampler's cadence: a faster dashboard would show
        // numbers the policy is not acting on.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: config.memorySampleSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    public override func close() {
        timer?.invalidate()
        timer = nil
        super.close()
    }

    private func refresh() {
        let state = store.state
        let used = WebProcessMemory.currentBytes()

        var live = 0, evicted = 0, pty = 0
        rows = state.lanes.map { lane in
            var stateText = "—"
            for pane in lane.panes {
                switch (pane.kind, pane.state) {
                case (.pty, _):
                    pty += 1
                    stateText = "pty"
                case (_, .evicted), (.placeholder, _):
                    evicted += 1
                    stateText = "evicted"
                default:
                    live += 1
                    stateText = "live"
                }
            }
            return Row(lane: lane, state: stateText, distance: lane.keepLive ? "kept" : "")
        }

        bar.update(used: used, soft: config.webMemorySoftBytes,
                   hard: config.webMemoryHardBytes, target: config.webMemoryTargetBytes)

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(
            string: "// WEBKIT\n",
            attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(10, weight: .bold)]))
        text.append(NSAttributedString(
            string: """
                \(Self.mb(used)) resident across every WebKit helper
                soft \(Self.mb(config.webMemorySoftBytes))   hard \(Self.mb(config.webMemoryHardBytes))   \
                evict down to \(Self.mb(config.webMemoryTargetBytes))

                \(state.lanes.count) lanes   \(live) live web   \(evicted) evicted   \(pty) terminals

                Per-lane cost is not shown: attributing a WebKit process to a \
                pane needs private API (ADR-0003).
                """,
            attributes: [.foregroundColor: NSColor.labelColor, .font: Theme.mono(11)]))
        summary.attributedStringValue = text

        table.reloadData()
    }

    static func mb(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024
            ? String(format: "%.1f GB", mb / 1024)
            : String(format: "%.0f MB", mb)
    }
}

extension MemoryDashboard: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let r = rows[row]
        return PaletteRow(
            glyph: r.state == "pty" ? "$" : (r.state == "evicted" ? "◌" : "◍"),
            primary: r.lane.title ?? r.lane.panes.first?.url ?? "untitled",
            secondary: [r.distance, r.state].filter { !$0.isEmpty }.joined(separator: " · "))
    }
}

/// Where the current footprint sits between the soft and hard marks.
///
/// Square, because everything here is. The orange band is the range in which
/// eviction is armed but waiting for three consecutive samples; past the hard
/// mark it acts immediately.
@MainActor
final class BudgetBar: NSView {
    private var used: UInt64 = 0
    private var soft: UInt64 = 1
    private var hard: UInt64 = 1
    private var target: UInt64 = 0

    func update(used: UInt64, soft: UInt64, hard: UInt64, target: UInt64) {
        self.used = used
        self.soft = soft
        self.hard = hard
        self.target = target
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The full scale is a little past the hard mark, so the bar has
        // somewhere to show an overshoot.
        let scale = Double(hard) * 1.2
        guard scale > 0 else { return }

        Theme.laneBorder.withAlphaComponent(0.35).setFill()
        bounds.fill()

        func x(_ value: UInt64) -> CGFloat { bounds.width * CGFloat(min(Double(value) / scale, 1)) }

        let fill = Double(used) > Double(hard)
            ? NSColor.systemRed
            : (Double(used) > Double(soft) ? Theme.accent : NSColor.systemGreen)
        fill.setFill()
        NSRect(x: 0, y: 0, width: x(used), height: bounds.height).fill()

        // Marks.
        for (value, colour) in [(target, Theme.dimText), (soft, Theme.accent), (hard, NSColor.systemRed)] {
            colour.setFill()
            NSRect(x: x(value) - 1, y: 0, width: 2, height: bounds.height).fill()
        }
    }
}
