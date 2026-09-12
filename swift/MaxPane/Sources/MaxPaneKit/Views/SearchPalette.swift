import AppKit
import LanedCore

/// A panel with square corners.
///
/// macOS gives every `.titled` window rounded chrome regardless of what its
/// content layer says, and a rounded card is the one thing the house style
/// prohibits outright. Borderless gets the square edge back; the two overrides
/// get back the focus behaviour `.titled` would otherwise have provided, without
/// which the search field never becomes first responder and the palette is
/// decorative.
final class SquarePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// A floating list over the strip, used by both ⌘P (search) and ⌘O (attach a
/// session). Both are "type, filter, pick one, dismiss".
///
/// The list is not flat: both palettes interleave `// SECTION` headers with
/// rows, so the controller knows which rows can be selected and how tall each
/// one is, and leaves both answers to the subclass.
@MainActor
class PaletteController: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    let field = NSTextField()
    let table = NSTableView()
    /// A status line, the way the bar pins `10 sessions` to its toolbar: what
    /// you are looking at on the left, what the keys do on the right.
    let footerLeft = NSTextField(labelWithString: "")
    let footerRight = NSTextField(labelWithString: "")
    private let scroll = NSScrollView()
    private var monitor: Any?
    /// The palette keeps itself alive while it is on screen.
    ///
    /// `NSTextField.delegate` and `NSTableView.dataSource` are weak, and the
    /// caller is under no obligation to hold a palette it has handed a
    /// completion to. Without this the controller is released the moment
    /// `present` returns: the rows that were already built stay on screen, and
    /// everything that needs the controller afterwards — typing to filter,
    /// Return to choose, the live throughput tick — silently does nothing. A
    /// deliberate cycle, broken in `dismiss`.
    private var whileOpen: PaletteController?

    init(placeholder: String, size: NSSize = NSSize(width: 720, height: 420)) {
        let panel = SquarePanel(
            contentRect: NSRect(origin: .zero, size: size),
            // Borderless, because a `.titled` panel gets macOS's rounded window
            // chrome no matter what its content layer says — and a 10pt rounded
            // card is precisely the house style's one prohibition. `canBecomeKey`
            // is overridden below to get back the focus behaviour `.titled`
            // would have given us for free.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        // A borderless window is transparent by default, so the square edge has
        // to be painted rather than inherited.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = true
        super.init(window: panel)
        panel.delegate = self

        field.placeholderString = placeholder
        field.font = Theme.mono(16)
        field.isBordered = false
        field.focusRingType = .none
        field.drawsBackground = false
        field.delegate = self

        table.headerView = nil
        table.rowHeight = 30
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        // Not `.none`: that stops AppKit asking the row view to draw a
        // selection at all. `PaletteSelectionRowView` overrides the drawing
        // instead, so the stock rounded blue capsule never appears.
        table.selectionHighlightStyle = .regular
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
        scroll.automaticallyAdjustsContentInsets = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.laneBackground.cgColor
        content.layer?.borderColor = Theme.laneBorder.cgColor
        content.layer?.borderWidth = Theme.borderWidth
        // Square. A rounded palette is the thing this project is not.
        content.layer?.cornerRadius = 0

        let rule = NSBox()
        rule.boxType = .separator
        let footerRule = NSBox()
        footerRule.boxType = .separator

        footerRight.alignment = .right
        for label in [footerLeft, footerRight] {
            label.font = Theme.mono(10, weight: .medium)
            label.textColor = Theme.dimText
            label.lineBreakMode = .byTruncatingTail
        }

        for v in [field, rule, scroll, footerRule, footerLeft, footerRight] {
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

            footerRule.topAnchor.constraint(equalTo: scroll.bottomAnchor),
            footerRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footerLeft.topAnchor.constraint(equalTo: footerRule.bottomAnchor, constant: 8),
            footerLeft.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            footerLeft.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -9),

            footerRight.centerYAnchor.constraint(equalTo: footerLeft.centerYAnchor),
            footerRight.leadingAnchor.constraint(
                greaterThanOrEqualTo: footerLeft.trailingAnchor, constant: 12),
            footerRight.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
        ])
        footerLeft.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        panel.contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        whileOpen = self
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
            // Subclasses get first refusal, so a palette with its own keys —
            // ⌘1…⌘0 on the new-pane picker — does not have to install a second
            // monitor and race this one for the event.
            if self.handleKey(event) { return nil }
            switch event.keyCode {
            case 125: self.move(by: 1); return nil    // down
            case 126: self.move(by: -1); return nil   // up
            case 36, 76: self.commit(); return nil    // return, enter
            case 53: self.cancel(); return nil        // esc
            default: return event
            }
        }
    }

    /// Steps over group headers, so holding ↓ never parks on scenery.
    private func move(by delta: Int) {
        let count = numberOfRows()
        guard count > 0 else { return }
        var next = table.selectedRow + delta
        while next >= 0, next < count, !isSelectable(row: next) { next += delta }
        guard next >= 0, next < count else { return }
        select(row: next)
    }

    private func select(row: Int) {
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        // Scroll the header above a group's first row into view with it,
        // otherwise you lose track of which directory you are in.
        let anchor = row > 0 && !isSelectable(row: row - 1) ? row - 1 : row
        table.scrollRowToVisible(anchor)
        table.scrollRowToVisible(row)
    }

    /// What has been typed so far.
    ///
    /// Not `field.stringValue`: while a field is being edited its text lives in
    /// the window's field editor, and the cell's value only catches up when
    /// editing ends — so reading `stringValue` from here filters on the empty
    /// string and the list never changes as you type.
    private(set) var query = ""

    func controlTextDidChange(_ obj: Notification) {
        query = (obj.userInfo?["NSFieldEditor"] as? NSText)?.string ?? field.stringValue
        reload()
    }

    func reload() {
        table.reloadData()
        layOutRows()
        selectFirstSelectableRow()
    }

    /// `reloadData()` alone leaves the rows blank here.
    ///
    /// The palette is a non-activating panel over another window, and AppKit
    /// does not schedule a layout pass for the table inside it, so it never
    /// asks the delegate for a single cell view — 25 correctly sized, entirely
    /// empty rows. Laying out by hand after every reload is the fix; at palette
    /// sizes it costs nothing.
    func layOutRows() {
        table.layoutSubtreeIfNeeded()
    }

    func selectFirstSelectableRow() {
        let count = numberOfRows()
        guard let first = (0..<count).first(where: { isSelectable(row: $0) }) else { return }
        select(row: first)
    }

    /// Redraw with fresh data without losing the user's place — the picker's
    /// throughput and ages tick once a second while it is open, and a selection
    /// that jumps back to the top every second is unusable.
    func refreshKeepingSelection() {
        let row = table.selectedRow
        let identity = row >= 0 ? rowIdentity(row) : nil
        table.reloadData()
        layOutRows()
        let count = numberOfRows()
        if let identity, let found = (0..<count).first(where: { rowIdentity($0) == identity }) {
            table.selectRowIndexes(IndexSet(integer: found), byExtendingSelection: false)
        } else if row >= 0, row < count, isSelectable(row: row) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            selectFirstSelectableRow()
        }
    }

    @objc func commit() {
        let row = table.selectedRow
        guard row >= 0, isSelectable(row: row) else { return }
        dismiss(selected: row)
    }

    func cancel() { dismiss(selected: -1) }

    /// Clicking back into the strip, or switching away from the app, closes the
    /// palette — and, just as importantly, lets go of it, so its live
    /// subscription to the registry stops with it.
    func windowDidResignKey(_ notification: Notification) { cancel() }

    func dismiss(selected: Int) {
        guard whileOpen != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window?.parent?.removeChildWindow(window!)
        window?.orderOut(nil)
        deliver(selected: selected)
        // Last, because `deliver` is the caller's chance to use us.
        whileOpen = nil
    }

    // MARK: - subclass hooks

    /// A key the subclass wants before the palette's own navigation sees it.
    /// Return true to swallow it.
    func handleKey(_ event: NSEvent) -> Bool { false }

    func numberOfRows() -> Int { 0 }
    func view(forRow row: Int) -> NSView? { nil }
    func deliver(selected: Int) {}
    func isSelectable(row: Int) -> Bool { true }
    func height(forRow row: Int) -> CGFloat { table.rowHeight }
    /// Something stable across a refresh — a session id, a lane id — so the
    /// selection can follow its row when the list is rebuilt underneath it.
    func rowIdentity(_ row: Int) -> String? { nil }
}

extension PaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { numberOfRows() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        view(forRow: row)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        height(forRow: row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        isSelectable(row: row)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteSelectionRowView()
    }
}

/// Square selection in Signal Orange: a tinted band with a hard 2pt edge. The
/// row itself has no corner radius, so the edge stays an edge.
final class PaletteSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.accent.withAlphaComponent(0.16).setFill()
        bounds.fill()
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

// MARK: - shared row furniture

@MainActor
enum PaletteStyle {
    /// `// SECTION_HEADER` with the slashes in orange — the house header.
    ///
    /// `shout` is off for paths: `~/CODE/MAX-PANE/.CLAUDE/WORKTREES/AGENT-AD3B`
    /// is harder to read than the path the user typed, and a group header
    /// exists to be read at a glance.
    static func caps(_ text: String, size: CGFloat = 10, shout: Bool = true) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: "",
            attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(size, weight: .bold)])
        out.append(NSAttributedString(
            string: shout ? text.uppercased() : text,
            attributes: [.foregroundColor: Theme.dimText, .font: Theme.mono(size, weight: .bold)]))
        return out
    }

    /// The title with the fuzzy-matched characters lit up, so you can see *why*
    /// a row survived what you typed.
    static func highlighted(
        _ text: String, matches: [Int], size: CGFloat = 13, color: NSColor
    ) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: text,
            attributes: [.foregroundColor: color, .font: Theme.mono(size)])
        guard !matches.isEmpty else { return out }
        let length = (text as NSString).length
        for index in matches where index < length {
            out.addAttributes(
                [.foregroundColor: Theme.accent, .font: Theme.mono(size, weight: .bold)],
                range: NSRange(location: index, length: 1))
        }
        return out
    }

    /// Liveness, not agent state: green while the process exists, grey once it
    /// does not. The state itself is carried by the glyph and the chip.
    static func dotColor(running: Bool) -> NSColor {
        running
            ? NSColor(srgbRed: 0.30, green: 0.74, blue: 0.36, alpha: 1)
            : NSColor(white: 0.45, alpha: 1)
    }

    /// The state glyph's colour. `agentStateColor` is `.clear` for the two
    /// states that deliberately have no chip, and a clear glyph is an invisible
    /// glyph, so those fall back to the dim text colour.
    static func glyphColor(_ state: AgentState) -> NSColor {
        let colour = Theme.agentStateColor(state)
        return colour == .clear ? Theme.dimText : colour
    }

    /// `[BLOCKED]` — a square, full-perimeter chip in the state's colour.
    ///
    /// Only three states get one, so a chip in the corner of the eye always
    /// means something. The outline is the whole rectangle: a single coloured
    /// edge is the bent-rail tell this project does not use.
    static func chip(_ state: AgentState) -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        guard state.hasChip else { return view }
        let colour = Theme.agentStateColor(state)
        view.wantsLayer = true
        view.layer?.cornerRadius = 0
        view.layer?.borderWidth = 1
        view.layer?.borderColor = colour.withAlphaComponent(0.55).cgColor
        view.layer?.backgroundColor = colour.withAlphaComponent(0.14).cgColor
        let text = label(state.chipText, Theme.mono(9, weight: .bold), colour)
        text.alignment = .center
        view.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            view.heightAnchor.constraint(equalToConstant: 15),
        ])
        return view
    }

    static func label(_ string: String, _ font: NSFont, _ color: NSColor) -> NSTextField {
        let f = NSTextField(labelWithString: string)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }
}

/// `// ~/CODE/MAX-PANE   3` … `1 running` — the bar's group header, in this
/// project's vocabulary.
final class PaletteGroupRow: NSTableCellView {
    init(group: PaletteGroup) {
        super.init(frame: .zero)
        let path = NSTextField(
            labelWithAttributedString: PaletteStyle.caps(group.path, shout: false))
        path.lineBreakMode = .byTruncatingHead
        path.translatesAutoresizingMaskIntoConstraints = false

        // The total only earns a chip when some of the group is not running;
        // otherwise it repeats "2 running" two inches to the left.
        let total = PaletteStyle.label(
            group.total == group.running ? "" : "\(group.total)",
            Theme.mono(10, weight: .bold), Theme.dimText.withAlphaComponent(0.7))

        // "1 blocked" displaces "2 running" whenever it is true: the count that
        // decides whether to open a group is the one waiting on you, and it is
        // the only thing in a header worth the accent.
        let blocked = group.blocked > 0
        let running = PaletteStyle.label(
            blocked
                ? "\(group.blocked) blocked"
                : (group.running > 0 ? "\(group.running) running" : "none running"),
            Theme.mono(10, weight: blocked ? .bold : .medium),
            blocked ? Theme.accent : Theme.dimText)
        running.alignment = .right

        for v in [path, total, running] { addSubview(v) }
        NSLayoutConstraint.activate([
            path.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            path.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),

            total.leadingAnchor.constraint(equalTo: path.trailingAnchor, constant: 8),
            total.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),

            running.leadingAnchor.constraint(greaterThanOrEqualTo: total.trailingAnchor, constant: 12),
            running.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            running.firstBaselineAnchor.constraint(equalTo: path.firstBaselineAnchor),
        ])
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// A plain `// LABEL` rule with a right-hand note — the launch section's
/// header, and the one place the picker explains itself.
final class PaletteSectionRow: NSTableCellView {
    init(title: String, note: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithAttributedString: PaletteStyle.caps(title))
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        let hint = PaletteStyle.label(note, Theme.mono(10), Theme.dimText)
        hint.alignment = .right

        for v in [label, hint] { addSubview(v) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            hint.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// `+ claude … ~/code/max-pane` — a session that does not exist yet.
final class PaletteLaunchRow: NSTableCellView {
    init(_ launch: PaletteLaunch) {
        super.init(frame: .zero)
        let plus = PaletteStyle.label("+", Theme.mono(12, weight: .bold), Theme.accent)
        plus.alignment = .center
        let label = PaletteStyle.label(launch.label, Theme.mono(13), .labelColor)
        let cwd = PaletteStyle.label(
            SessionTelemetry.abbreviate(launch.cwd), Theme.mono(11), Theme.dimText)
        cwd.alignment = .right
        cwd.lineBreakMode = .byTruncatingHead

        for v in [plus, label, cwd] { addSubview(v) }
        NSLayoutConstraint.activate([
            plus.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.widthAnchor.constraint(equalToConstant: 10),

            label.leadingAnchor.constraint(equalTo: plus.trailingAnchor, constant: 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            cwd.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            cwd.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            cwd.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        cwd.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// One session: `● ! ▪ title … id · command  [BLOCKED]  idle  6s ago`.
///
/// Every column the bar's sidebar carries, in one line, aligned so ten of them
/// scan as a table rather than as ten sentences. The chip and the throughput
/// readout are separate columns because they answer different questions: does
/// it need me, and is anything still coming out of it.
final class PaletteSessionRow: NSTableCellView {
    init(_ session: PaletteSession) {
        super.init(frame: .zero)
        let t = session.telemetry

        let dot = PaletteStyle.label("●", Theme.mono(9), PaletteStyle.dotColor(running: t.isRunning))
        dot.alignment = .center

        let glyph = PaletteStyle.label(
            t.state.glyph, Theme.mono(12, weight: t.needsAttention ? .bold : .medium),
            PaletteStyle.glyphColor(t.state))
        glyph.alignment = .center

        // Already on the strip: a square orange mark, never a second copy of
        // the session. The footer says what it means.
        let attached = PaletteStyle.label(
            t.isAttached ? "▪" : "", Theme.mono(10, weight: .bold), Theme.accent)
        attached.alignment = .center
        attached.toolTip = t.isAttached ? "already on the strip" : nil

        let title = NSTextField(labelWithAttributedString: PaletteStyle.highlighted(
            t.title.isEmpty ? t.command : t.title,
            matches: session.titleMatches,
            color: t.isRunning ? .labelColor : Theme.dimText))
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false

        // The id is how every other tool on this machine names the session
        // (`relay attach 4f2a…`), and the command only earns its place when the
        // title is not already it — Relay titles fall back to the argv.
        let short = String(t.sessionId.prefix(8))
        let repeats = t.title.hasPrefix(t.command) || t.command.isEmpty
        let command = PaletteStyle.label(
            repeats ? short : "\(short) · \(t.command)",
            Theme.mono(10), Theme.dimText.withAlphaComponent(0.7))

        let chip = PaletteStyle.chip(t.state)

        let badge = PaletteStyle.label(
            t.badgeText, Theme.mono(11, weight: t.badgeIsThroughput ? .medium : .regular),
            t.badgeIsThroughput ? Theme.accent : Theme.dimText)
        badge.alignment = .right

        let age = PaletteStyle.label(t.ageText, Theme.mono(11), Theme.dimText)
        age.alignment = .right

        for v in [dot, glyph, attached, title, command, chip, badge, age] { addSubview(v) }
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: command.trailingAnchor, constant: 8),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),

            glyph.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            attached.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 2),
            attached.centerYAnchor.constraint(equalTo: centerYAnchor),
            attached.widthAnchor.constraint(equalToConstant: 10),

            title.leadingAnchor.constraint(equalTo: attached.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            command.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            command.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            badge.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 78),

            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            age.centerYAnchor.constraint(equalTo: centerYAnchor),
            age.widthAnchor.constraint(equalToConstant: 64),
        ])
        // The title is the last thing to be given up; the command goes first.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        command.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        command.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// One search hit, two lines: the lane and how it is doing on top, what
/// actually matched underneath. A hit in 8 000 lines of scrollback is useless
/// if you cannot see which lane it came from or whether that lane is alive.
final class PaletteSearchRow: NSTableCellView {
    init(hit: SearchHit, laneTitle: String, path: String, telemetry: SessionTelemetry?, isFocused: Bool) {
        super.init(frame: .zero)

        let glyph = PaletteStyle.label(
            Self.glyph(hit.field), Theme.mono(12, weight: .medium), Theme.accent)
        glyph.alignment = .center

        let title = PaletteStyle.label(laneTitle, Theme.mono(13), .labelColor)

        let focus = PaletteStyle.label(
            isFocused ? "▪" : "", Theme.mono(10, weight: .bold), Theme.accent)
        focus.toolTip = isFocused ? "the focused lane" : nil
        focus.alignment = .center

        // A lane the search turned up is only useful if you can see whether it
        // is waiting on you, so the hit row carries the same chip the picker's
        // rows do.
        let chip = PaletteStyle.chip(telemetry?.state ?? .unknown)

        let state = PaletteStyle.label(
            telemetry?.badgeText ?? "",
            Theme.mono(11, weight: .medium),
            telemetry?.badgeIsThroughput == true ? Theme.accent : Theme.dimText)
        state.alignment = .right

        let age = PaletteStyle.label(telemetry?.ageText ?? "", Theme.mono(11), Theme.dimText)
        age.alignment = .right

        let field = PaletteStyle.label(
            Self.fieldLabel(hit.field), Theme.mono(9, weight: .bold),
            Theme.dimText.withAlphaComponent(0.8))

        // A project-root hit's text is the path, which the right-hand column
        // already carries; printing it twice buys nothing and costs the line
        // where the actual match would go.
        let matched = Self.oneLine(hit.text)
        let excerpt = PaletteStyle.label(
            matched == laneTitle || hit.field == .projectRoot ? "" : matched,
            Theme.mono(11), Theme.dimText)

        let where_ = PaletteStyle.label(path, Theme.mono(10), Theme.dimText.withAlphaComponent(0.8))
        where_.alignment = .right
        where_.lineBreakMode = .byTruncatingHead

        for v in [glyph, focus, title, chip, state, age, field, excerpt, where_] { addSubview(v) }
        NSLayoutConstraint.activate([
            chip.trailingAnchor.constraint(equalTo: state.leadingAnchor, constant: -10),
            chip.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            chip.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10),

            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            focus.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 2),
            focus.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),
            focus.widthAnchor.constraint(equalToConstant: 10),

            title.leadingAnchor.constraint(equalTo: focus.trailingAnchor, constant: 6),
            title.firstBaselineAnchor.constraint(equalTo: glyph.firstBaselineAnchor),

            state.trailingAnchor.constraint(equalTo: age.leadingAnchor, constant: -12),
            state.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            age.widthAnchor.constraint(equalToConstant: 64),
            age.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            field.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            field.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            excerpt.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
            excerpt.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),

            where_.leadingAnchor.constraint(greaterThanOrEqualTo: excerpt.trailingAnchor, constant: 12),
            where_.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            where_.firstBaselineAnchor.constraint(equalTo: field.firstBaselineAnchor),
        ])
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        excerpt.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        where_.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        state.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Scrollback arrives with its whitespace intact — newlines, tabs and the
    /// column padding of whatever printed it. A row is one line tall, so runs
    /// collapse; otherwise a hit inside a table of output shows as a gap.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
    }

    static func glyph(_ field: SearchField) -> String {
        switch field {
        case .title: return "▸"
        case .projectRoot: return "/"
        case .url: return "◍"
        case .scrollback: return "$"
        }
    }

    static func fieldLabel(_ field: SearchField) -> String {
        switch field {
        case .title: return "TITLE"
        case .projectRoot: return "PROJECT"
        case .url: return "URL"
        case .scrollback: return "OUTPUT"
        }
    }
}

/// ⌘P — PRD §7.5. Fuzzy over titles, project roots, URLs and the last 200 lines
/// of each terminal's scrollback.
@MainActor
final class SearchPaletteController: PaletteController {
    private let store: StripStore
    private let registry: SessionRegistry
    private var hits: [SearchHit] = []
    private let completion: (SearchHit?) -> Void

    init(store: StripStore, registry: SessionRegistry, completion: @escaping (SearchHit?) -> Void) {
        self.store = store
        self.registry = registry
        self.completion = completion
        super.init(placeholder: "Search lanes, URLs, output…",
                   size: NSSize(width: 760, height: 460))
    }

    /// The palette needs telemetry to say anything about the lane a hit came
    /// from, and the registry is the only thing that has it.
    @available(*, unavailable,
        message: "pass the SessionRegistry too: SearchPaletteController(store: store, registry: sessions) { … }")
    init(store: StripStore, completion: @escaping (SearchHit?) -> Void) { fatalError("unavailable") }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func reload() {
        // Spike M3 measured search at 0.58 ms across 300 lanes and 8 600
        // scrollback lines, so there is no debounce: it runs per keystroke.
        //
        // The core scores each field separately, so one lane can come back
        // several times with the same text — its title and its project root
        // both matching, say. Identical lines are noise in a list you scan.
        var seen = Set<String>()
        hits = store.search(query).filter { seen.insert("\($0.laneId)\u{1}\($0.text)").inserted }
        super.reload()
        updateFooter()
    }

    override func numberOfRows() -> Int { hits.count }

    override func height(forRow row: Int) -> CGFloat { 44 }

    override func rowIdentity(_ row: Int) -> String? {
        row < hits.count ? hits[row].paneId + hits[row].text : nil
    }

    override func view(forRow row: Int) -> NSView? {
        guard row < hits.count else { return nil }
        let hit = hits[row]
        let lane = store.lane(hit.laneId)
        let pane = store.pane(hit.paneId)
        let telemetry = pane?.relaySessionId.flatMap { registry.telemetry(for: $0) }
        let path = telemetry?.groupPath
            ?? lane?.projectRoot.map(SessionTelemetry.abbreviate)
            ?? ""
        // What the lane is called, in the order that identifies it fastest.
        // Never the hit text as a last resort: a project-root hit's text is the
        // path, and a row whose headline is a path repeated underneath it tells
        // you nothing twice.
        let name = [
            lane?.title,
            telemetry?.title,
            pane?.url.flatMap { URL(string: $0)?.host },
            telemetry?.command,
            lane?.projectRoot.map { ($0 as NSString).lastPathComponent },
        ].compactMap { $0 }.first { !$0.isEmpty } ?? "untitled"
        return PaletteSearchRow(
            hit: hit,
            laneTitle: name,
            path: path,
            telemetry: telemetry,
            isFocused: store.state.focusedPaneId == hit.paneId)
    }

    override func deliver(selected: Int) {
        completion(selected >= 0 && selected < hits.count ? hits[selected] : nil)
    }

    private func updateFooter() {
        let summary = query.isEmpty
            ? "\(store.state.lanes.count) lanes · titles, urls, output"
            : "\(hits.count) \(hits.count == 1 ? "hit" : "hits") · \(store.state.lanes.count) lanes"
        footerLeft.attributedStringValue = PaletteStyle.caps(summary)
        footerRight.stringValue = "▪ focused    ↩ jump    esc"
    }
}

/// ⌘O — PRD §7.1's picker of Relay sessions, grouped the way the bar groups
/// them: every session Relay knows about, under its directory, with the ones
/// already on the strip marked rather than hidden. Hiding them is what made the
/// old picker lie about how many sessions there are.
@MainActor
final class SessionPickerController: PaletteController {
    /// What ⌘O can hand back. Two cases, because "the session I want is not
    /// running" is the other half of finding one.
    enum Choice {
        /// An existing session — already attached or not; the caller decides
        /// whether that means reveal or attach.
        case attach(SessionTelemetry)
        /// Start `command` in `cwd` and put the new session on the strip.
        case launch(command: String, cwd: String)
    }

    private let registry: SessionRegistry
    private var entries: [PaletteEntry] = []
    private var token: UUID?
    private let completion: (Choice?) -> Void

    init(registry: SessionRegistry, completion: @escaping (Choice?) -> Void) {
        self.registry = registry
        self.completion = completion
        super.init(placeholder: "Attach a Relay session…",
                   size: NSSize(width: 760, height: 520))
    }

    /// The old picker took a pre-filtered `[RelaySessionInfo]`, which is why it
    /// could not say what was already attached, how fast anything was running
    /// or how long ago it last moved. Taking the registry is the whole point.
    @available(*, unavailable,
        message: "pass the SessionRegistry instead: SessionPickerController(registry: sessions) { choice in switch choice { case .attach(let t): … case .launch(let command, let cwd): … } }")
    init(sessions: [RelaySessionInfo], completion: @escaping (RelaySessionInfo?) -> Void) {
        fatalError("unavailable")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func present(over parent: NSWindow?) {
        // Throughput and ages are live while the picker is open: the session
        // that starts moving while you are looking for it is the one you want.
        token = registry.observe { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.rebuild()
            self.refreshKeepingSelection()
            self.updateFooter()
        }
        super.present(over: parent)
    }

    override func dismiss(selected: Int) {
        if let token { registry.stopObserving(token) }
        token = nil
        super.dismiss(selected: selected)
    }

    override func reload() {
        rebuild()
        super.reload()
        updateFooter()
    }

    private func rebuild() {
        entries = PaletteFilter.entries(groups: registry.grouped(), query: query)
    }

    override func numberOfRows() -> Int { entries.count }

    override func isSelectable(row: Int) -> Bool {
        row < entries.count && entries[row].isSelectable
    }

    override func height(forRow row: Int) -> CGFloat {
        guard row < entries.count else { return 30 }
        switch entries[row] {
        case .group, .section: return 26
        case .session, .launch: return 30
        }
    }

    override func rowIdentity(_ row: Int) -> String? {
        guard row < entries.count else { return nil }
        switch entries[row] {
        case .session(let s): return s.telemetry.sessionId
        case .launch(let l): return "launch:" + l.command
        default: return nil
        }
    }

    override func view(forRow row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        switch entries[row] {
        case .group(let group): return PaletteGroupRow(group: group)
        case .session(let session): return PaletteSessionRow(session)
        case .section(let title, let note): return PaletteSectionRow(title: title, note: note)
        case .launch(let launch): return PaletteLaunchRow(launch)
        }
    }

    override func deliver(selected: Int) {
        guard selected >= 0, selected < entries.count else { return completion(nil) }
        switch entries[selected] {
        case .session(let picked): completion(.attach(picked.telemetry))
        case .launch(let launch): completion(.launch(command: launch.command, cwd: launch.cwd))
        case .group, .section: completion(nil)
        }
    }

    private func updateFooter() {
        let all = registry.sessions.values
        let attached = all.filter(\.isAttached).count
        var summary = "\(all.count) sessions · \(registry.runningCount) running · \(attached) on strip"
        var keys = "▪ on strip    ↩ attach    esc"
        let sessionRows = entries.filter { if case .session = $0 { return true } else { return false } }
        if sessionRows.count != all.count {
            summary = "\(sessionRows.count) of \(summary)"
        }
        if sessionRows.isEmpty, entries.contains(where: { if case .launch = $0 { return true } else { return false } }) {
            keys = "↩ launch    esc"
        }
        let line = PaletteStyle.caps(summary)
        // The blocked count is the one number here that is an instruction
        // rather than a statistic, so it is the only one in the accent.
        if registry.blockedCount > 0 {
            let mutable = NSMutableAttributedString(attributedString: line)
            mutable.append(NSAttributedString(
                string: "  ·  \(registry.blockedCount) BLOCKED",
                attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(10, weight: .bold)]))
            footerLeft.attributedStringValue = mutable
        } else {
            footerLeft.attributedStringValue = line
        }
        footerRight.stringValue = keys
    }
}

/// The plain row — an orange marker, a line, and where it lives. The memory
/// dashboard still lists panes this way; the palettes outgrew it.
final class PaletteRow: NSTableCellView {
    init(glyph: String, primary: String, secondary: String) {
        super.init(frame: .zero)
        let g = PaletteStyle.label(glyph, Theme.mono(12, weight: .medium), Theme.accent)
        g.alignment = .center
        let p = PaletteStyle.label(primary, Theme.mono(13), .labelColor)
        let s = PaletteStyle.label(secondary, Theme.mono(11), Theme.dimText)
        s.alignment = .right
        s.lineBreakMode = .byTruncatingHead

        for v in [g, p, s] { addSubview(v) }
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
