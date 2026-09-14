import AppKit
import QuartzCore

/// Every setting in `config.toml`, and every key, in one window. ⌘,.
///
/// The owner: *"all custom settings should have a UI to edit them along with the
/// setting getting stored in plain text in the standard Unix/linux config
/// directory."* So this is a view of the file, not a store of its own: each
/// change is one line edit written the moment it is made, and a save from a
/// text editor refreshes whatever is on screen here. `ConfigStore` is the one
/// place either side goes through.
///
/// A `Popup`, like every other dialog: square, centred, rising in and fading
/// out. It closes on Esc or ⌘, and not on a click away — someone who opens the
/// file in a lane to edit it by hand is still using this window.
@MainActor
final class SettingsWindow: Popup {
    /// Wide enough for the widest row — a key's field and its four buttons —
    /// beside its text, with a legacy scroller showing. A test holds the
    /// content's fitting width to this.
    static let size = NSSize(width: 920, height: 680)
    /// Room for "Terminals & sessions" behind the `$` marker, untruncated.
    static let navWidth: CGFloat = 200
    /// The width of a row's explanation, fixed so a wrapped line does not make
    /// the layout chase its own tail.
    static let textWidth: CGFloat = 320

    private let store: ConfigStore
    private let onOpenInEditor: (URL) -> Void

    private let scroll = NSScrollView()
    private let documentView = SettingsDocumentView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let keyboardNote = NSTextField(wrappingLabelWithString: "")
    private var rows: [SettingRow] = []
    private var keyRows: [KeyRow] = []
    private var headers: [(group: ConfigGroup, view: NSView)] = []
    private var navItems: [ConfigGroup: NavItem] = [:]
    private var selected: ConfigGroup = .lanes
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private weak var recording: KeyRow?

    init(store: ConfigStore, onOpenInEditor: @escaping (URL) -> Void) {
        self.store = store
        self.onOpenInEditor = onOpenInEditor
        super.init(
            size: Self.size, dismissal: .explicitOnly, resizable: true,
            minSize: NSSize(width: Self.size.width, height: 420))
        window?.contentView = build()
        refresh(animated: false)
        observers.append(NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        })
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followScroll() }
        })
    }

    // MARK: - popup

    /// Esc cancels a recording before it closes anything.
    override var handlesEscape: Bool { true }

    override func popupDidPresent() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true else { return event }
            if let row = self.recording {
                self.finishRecording(row, with: event)
                return nil
            }
            guard event.keyCode == 53 else { return event }
            self.popupCancelled()
            return nil
        }
    }

    override func closePopup(animated: Bool = true, completion: (() -> Void)? = nil) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording?.setRecording(false)
        recording = nil
        super.closePopup(animated: animated, completion: completion)
    }

    // MARK: - building

    private func build() -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        let header = SectionHeader(text: "SETTINGS")
        let hint = NSTextField(labelWithString: "esc")
        hint.font = Theme.mono(10, weight: .medium)
        hint.textColor = Theme.dimText

        pathLabel.font = Theme.mono(11)
        pathLabel.textColor = Theme.dimText
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reveal = AskButton(label: "reveal in finder", isDefault: false)
        reveal.onClick = { [weak self] in self?.revealFile() }
        let edit = AskButton(label: "open in editor", isDefault: false)
        edit.onClick = { [weak self] in self?.openInEditor() }

        noteLabel.font = Theme.mono(11)
        noteLabel.textColor = Theme.dimText
        noteLabel.preferredMaxLayoutWidth = Self.size.width - 40

        let topRule = NSBox()
        topRule.boxType = .separator
        // A painted view, not a vertical `NSBox` separator. A box decides its
        // orientation from its frame, starts out horizontal at zero size, and
        // hugs a one-point *height* at 750 — which, pinned between the top rule
        // and the bottom edge, pulled the whole popup's content down to the
        // header. The render sheet is what showed it.
        let sideRule = NSView()
        sideRule.wantsLayer = true
        sideRule.layerBackgroundColor = Theme.laneBorder

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 2
        for group in ConfigGroup.allCases {
            let item = NavItem(title: group.rawValue)
            item.onClick = { [weak self] in self?.reveal(group, animated: true) }
            navItems[group] = item
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalToConstant: Self.navWidth - 24).isActive = true
        }

        let sections = NSStackView()
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 0
        sections.edgeInsets = NSEdgeInsets(top: 16, left: 24, bottom: 32, right: 24)
        sections.translatesAutoresizingMaskIntoConstraints = false
        for group in ConfigGroup.allCases {
            let heading = SectionHeader(text: group.header)
            headers.append((group, heading))
            sections.addArrangedSubview(heading)
            sections.setCustomSpacing(10, after: heading)
            if group == .keyboard {
                keyboardNote.font = Theme.mono(11)
                keyboardNote.textColor = Theme.dimText
                keyboardNote.preferredMaxLayoutWidth = Self.textWidth + 260
                sections.addArrangedSubview(keyboardNote)
                sections.setCustomSpacing(10, after: keyboardNote)
                for command in Command.allCases {
                    let row = KeyRow(command: command, store: store)
                    row.onRecord = { [weak self, weak row] in
                        guard let self, let row else { return }
                        self.beginRecording(row)
                    }
                    keyRows.append(row)
                    sections.addArrangedSubview(row)
                }
            } else {
                for field in ConfigField.all where field.group == group {
                    let row = SettingRow(field: field, store: store)
                    rows.append(row)
                    sections.addArrangedSubview(row)
                }
            }
            if let last = sections.arrangedSubviews.last { sections.setCustomSpacing(28, after: last) }
        }

        documentView.addSubview(sections)
        documentView.content = sections
        documentView.autoresizingMask = [.width]
        scroll.documentView = documentView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        for view in [header, hint, pathLabel, reveal, edit, noteLabel, topRule, nav, sideRule, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let edge = Theme.borderWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            pathLabel.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: reveal.leadingAnchor, constant: -12),
            reveal.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            edit.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            reveal.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -8),

            noteLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 10),
            noteLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            noteLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            topRule.topAnchor.constraint(equalTo: noteLabel.bottomAnchor, constant: 12),
            topRule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topRule.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            nav.topAnchor.constraint(equalTo: topRule.bottomAnchor, constant: 16),
            nav.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            sideRule.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            sideRule.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edge),
            sideRule.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.navWidth),
            sideRule.widthAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: sideRule.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edge),

            sections.topAnchor.constraint(equalTo: documentView.topAnchor),
            sections.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
        ])
        return content
    }

    // MARK: - refreshing

    /// Bring every row to what the store now holds. `animated` is false only
    /// for the first paint, which the popup's own entrance already eases.
    private func refresh(animated: Bool) {
        pathLabel.stringValue = (store.path.path as NSString).abbreviatingWithTildeInPath
        noteLabel.attributedStringValue = note()
        for row in rows { row.refresh(animated: animated) }

        let keymap = store.keymap
        var unclaimed = keymap.complaints
        var keyProblems = store.problems.filter { $0.key.hasPrefix(ConfigField.keysTable + ".") }
        for row in keyRows {
            let mine = unclaimed.filter { KeyRow.mentions($0, row.command) }
            let tomlProblems = keyProblems.filter { $0.key == "\(ConfigField.keysTable).\(row.command.rawValue)" }
            unclaimed.removeAll { mine.contains($0) }
            keyProblems.removeAll { tomlProblems.contains($0) }
            row.refresh(keymap: keymap, complaints: mine + tomlProblems.map(\.reason), animated: animated)
        }
        let general = [
            "Every command, the keys that run it, and the key it ships with. rec takes the next chord you press; "
                + "none unbinds; default gives the shipped key back. Keys apply on relaunch.",
        ] + (unclaimed + keyProblems.map(\.text)).map { "$ " + $0 }
        setText(keyboardNote, general.joined(separator: "\n"), animated: animated)
        followScroll()
    }

    /// The line under the path: a write that failed, lines in the file that
    /// were not used, where the settings came from, or that there is no file.
    private func note() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let dim: [NSAttributedString.Key: Any] = [.font: Theme.mono(11), .foregroundColor: Theme.dimText]
        let loud: [NSAttributedString.Key: Any] = [.font: Theme.mono(11), .foregroundColor: Theme.accent]
        func line(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: dim)) }
            out.append(NSAttributedString(string: text, attributes: attributes))
        }
        if let error = store.writeError { line("$ could not write the file: \(error)", loud) }
        let fieldKeys = Set(ConfigField.all.map(\.key))
        for problem in store.problems
        where !fieldKeys.contains(problem.key) && !problem.key.hasPrefix(ConfigField.keysTable + ".") {
            line("$ " + problem.text, loud)
        }
        if !store.fileExists {
            line("No file yet: every value below is its default. The first change creates it.", dim)
        } else if let legacy = store.legacyPath, FileManager.default.fileExists(atPath: legacy.path) {
            line("Copied from \((legacy.path as NSString).abbreviatingWithTildeInPath), "
                + "which is left in place and no longer read.", dim)
        } else {
            line("Written the moment you change something. Edits made in a text editor show up here.", dim)
        }
        line("theme applies at once; everything else on the next launch.", dim)
        return out
    }

    // MARK: - sections

    /// Scroll so `group`'s header is at the top.
    func reveal(_ group: ConfigGroup, animated: Bool) {
        guard let header = headers.first(where: { $0.group == group })?.view else { return }
        documentView.layoutSubtreeIfNeeded()
        let clip = scroll.contentView
        let top = header.convert(header.bounds, to: documentView).minY - 16
        let limit = max(0, documentView.bounds.height - clip.bounds.height)
        let origin = NSPoint(x: 0, y: min(max(0, top), limit))
        if !animated || Motion.isReduced {
            clip.scroll(to: origin)
            scroll.reflectScrolledClipView(clip)
            select(group)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.lane
            context.timingFunction = Motion.easeOutTiming
            clip.animator().setBoundsOrigin(origin)
        }
        select(group)
    }

    private func followScroll() {
        let clip = scroll.contentView
        let visibleTop = clip.bounds.minY + 40
        var current = ConfigGroup.lanes
        for (group, view) in headers where view.convert(view.bounds, to: documentView).minY <= visibleTop {
            current = group
        }
        // At the bottom the last short section can never reach the top.
        if clip.bounds.maxY >= documentView.bounds.height - 2, let last = headers.last {
            current = last.group
        }
        select(current)
    }

    private func select(_ group: ConfigGroup) {
        for (each, item) in navItems { item.setSelected(each == group) }
        selected = group
    }

    // MARK: - actions

    private func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([store.ensureFileExists()])
    }

    private func openInEditor() {
        let url = store.ensureFileExists()
        closePopup { [onOpenInEditor] in onOpenInEditor(url) }
    }

    private func beginRecording(_ row: KeyRow) {
        if let current = recording, current !== row { current.setRecording(false) }
        recording = row
        row.setRecording(true)
    }

    private func finishRecording(_ row: KeyRow, with event: NSEvent) {
        recording = nil
        row.setRecording(false)
        // Esc on its own cancels. A chord with Esc in it is still a chord.
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty { return }
        guard let chord = KeyChord(event: event) else { return }
        store.setChords(row.command, to: [chord.configText])
    }
}

// MARK: - the pieces

/// Which keyboard row a `Keymap` complaint belongs on.
enum KeyComplaint {
    /// By whole word, so a complaint about `ungather` is not also one about
    /// `gather`. A collision names two commands and shows on both rows.
    static func mentions(_ complaint: String, _ command: Command) -> Bool {
        complaint.range(of: "\\b\(command.rawValue)\\b", options: .regularExpression) != nil
    }
}

/// Flipped, so section one is at the top and a scroll starts there.
///
/// Frame-based, like the ⌘/ sheet's text view: it sizes itself to its clip
/// view's width and its sections' height, so nothing about the scroll view
/// takes part in the popup's own layout. The sections inside it are still laid
/// out with constraints.
private final class SettingsDocumentView: NSView {
    weak var content: NSView?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        guard let content else { return }
        let width = superview?.bounds.width ?? frame.width
        let size = NSSize(width: width, height: ceil(content.fittingSize.height))
        if frame.size != size { setFrameSize(size) }
    }
}

/// Fade a view's contents from what it showed to what it shows next, on the
/// pane clock. Nothing on this window changes without one.
@MainActor
private func crossfade(_ view: NSView, animated: Bool) {
    guard animated, !Motion.isReduced else { return }
    view.wantsLayer = true
    let fade = CATransition()
    fade.type = .fade
    fade.duration = Motion.pane
    fade.timingFunction = Motion.easeOutTiming
    view.layer?.add(fade, forKey: kCATransition)
}

@MainActor
private func setText(_ label: NSTextField, _ text: String, animated: Bool) {
    guard label.stringValue != text else { return }
    crossfade(label, animated: animated)
    label.stringValue = text
}

/// Show or hide a view inside a stack, easing both its opacity and the room it
/// takes, so a problem line arriving does not shove the rows below it.
@MainActor
private func setShown(_ view: NSView, _ shown: Bool, in container: NSView?, animated: Bool) {
    guard view.isHidden == shown else { return }
    guard animated, !Motion.isReduced, let container else {
        view.isHidden = !shown
        view.alphaValue = 1
        return
    }
    if shown { view.alphaValue = 0 }
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = Motion.pane
        context.timingFunction = Motion.easeOutTiming
        context.allowsImplicitAnimation = true
        view.isHidden = !shown
        view.animator().alphaValue = shown ? 1 : 0
        container.layoutSubtreeIfNeeded()
    }, completionHandler: {
        MainActor.assumeIsolated { view.alphaValue = 1 }
    })
}

/// A group in the left column. The current one wears the orange `$`.
@MainActor
private final class NavItem: NSView {
    var onClick: (() -> Void)?
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private var isSelected: Bool?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setSelected(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        crossfade(self, animated: isSelected != nil)
        isSelected = selected
        let text = NSMutableAttributedString(string: selected ? "$ " : "  ", attributes: [
            .font: Theme.mono(12, weight: .bold), .foregroundColor: Theme.accent,
        ])
        text.append(NSAttributedString(string: title, attributes: [
            .font: Theme.mono(12, weight: selected ? .medium : .regular),
            .foregroundColor: selected ? NSColor.labelColor : Theme.dimText,
        ]))
        label.attributedStringValue = text
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// A row of square segments, one of them chosen: on/off, or system/light/dark.
@MainActor
final class SquareSegments: NSView {
    var onChoose: ((Int) -> Void)?
    let options: [String]
    private(set) var selected: Int?

    init(options: [String]) {
        self.options = options
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private var font: NSFont { Theme.mono(11, weight: .medium) }

    private var widths: [CGFloat] {
        options.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + 22 }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(0, +) - CGFloat(max(0, options.count - 1)), height: 24)
    }

    func select(_ index: Int?, animated: Bool) {
        guard index != selected else { return }
        crossfade(self, animated: animated)
        selected = index
        needsDisplay = true
    }

    private func rects() -> [NSRect] {
        var x: CGFloat = 0
        return widths.map { width in
            // Neighbours share their one-point edge rather than doubling it.
            defer { x += width - 1 }
            return NSRect(x: x, y: 0, width: width, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = rects()
        for (index, rect) in frames.enumerated() where index != selected {
            draw(options[index], in: rect, chosen: false)
        }
        // The chosen one last, so its orange edge is not overdrawn by a
        // neighbour's grey one.
        if let selected, selected < frames.count { draw(options[selected], in: frames[selected], chosen: true) }
    }

    private func draw(_ title: String, in rect: NSRect, chosen: Bool) {
        (chosen ? Theme.accent : Theme.laneBorder).setStroke()
        let outline = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        let text = NSAttributedString(string: title, attributes: [
            .font: font, .foregroundColor: chosen ? NSColor.labelColor : Theme.dimText,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: rect.minX + (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rects().firstIndex(where: { $0.contains(point) }) else { return }
        onChoose?(index)
    }
}

/// The text column every row shares: a name, a line of explanation, the
/// default and when it applies, and a problem when there is one.
@MainActor
private final class RowText: NSStackView {
    let name = NSTextField(labelWithString: "")
    let summary = NSTextField(wrappingLabelWithString: "")
    /// Wrapping: a default as long as `search_url`'s would otherwise cut off
    /// the "on relaunch" that is the point of the line.
    let meta = NSTextField(wrappingLabelWithString: "")
    let problem = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 3
        name.font = Theme.mono(12, weight: .medium)
        name.textColor = .labelColor
        summary.font = Theme.mono(11)
        summary.textColor = Theme.dimText
        summary.preferredMaxLayoutWidth = SettingsWindow.textWidth
        meta.font = Theme.mono(10)
        meta.textColor = Theme.dimText
        meta.preferredMaxLayoutWidth = SettingsWindow.textWidth
        problem.font = Theme.mono(11)
        problem.textColor = Theme.accent
        problem.preferredMaxLayoutWidth = SettingsWindow.textWidth
        problem.isHidden = true
        for view in [name, summary, meta, problem] { addArrangedSubview(view) }
        widthAnchor.constraint(equalToConstant: SettingsWindow.textWidth).isActive = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not a nib") }

    func setMeta(_ plain: String, pending: Bool, animated: Bool) {
        let text = NSMutableAttributedString(string: plain, attributes: [
            .font: Theme.mono(10), .foregroundColor: Theme.dimText,
        ])
        if pending {
            text.append(NSAttributedString(string: "   $ ", attributes: [
                .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
            ]))
            text.append(NSAttributedString(string: "relaunch to apply", attributes: [
                .font: Theme.mono(10), .foregroundColor: NSColor.labelColor,
            ]))
        }
        guard meta.attributedStringValue != text else { return }
        crossfade(meta, animated: animated)
        meta.attributedStringValue = text
    }

    func setProblem(_ text: String?, container: NSView?, animated: Bool) {
        if let text { setTextNow(text, animated: animated && !problem.isHidden) }
        setShown(problem, text != nil, in: container, animated: animated)
    }

    private func setTextNow(_ text: String, animated: Bool) {
        guard problem.stringValue != text else { return }
        crossfade(problem, animated: animated)
        problem.stringValue = text
    }
}

/// A setting and its control.
@MainActor
private final class SettingRow: NSView, NSTextFieldDelegate {
    let field: ConfigField
    private let store: ConfigStore
    private let text = RowText()
    private let reset = AskButton(label: "default", isDefault: false)
    private var input: NSTextField?
    private var segments: SquareSegments?
    /// A value the row refused before it reached the file.
    private var localProblem: String?
    private var shown: String?

    init(field: ConfigField, store: ConfigStore) {
        self.field = field
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        text.name.stringValue = field.key
        text.summary.stringValue = field.summary

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 6
        switch field.control {
        case .integer, .number:
            let input = makeField(width: 96)
            input.alignment = .right
            let minus = AskButton(label: "−", isDefault: false)
            minus.onClick = { [weak self] in self?.step(-1) }
            let plus = AskButton(label: "+", isDefault: false)
            plus.onClick = { [weak self] in self?.step(1) }
            controls.addArrangedSubview(input)
            controls.addArrangedSubview(minus)
            controls.addArrangedSubview(plus)
        case .text(let placeholder):
            let input = makeField(width: 236)
            input.placeholderString = placeholder
            input.cell?.lineBreakMode = .byTruncatingTail
            controls.addArrangedSubview(input)
        case .toggle:
            let segments = SquareSegments(options: ["on", "off"])
            segments.onChoose = { [weak self] index in self?.commit(.bool(index == 0)) }
            self.segments = segments
            controls.addArrangedSubview(segments)
        case .choice(let options):
            let segments = SquareSegments(options: options)
            segments.onChoose = { [weak self] index in self?.commit(.string(options[index])) }
            self.segments = segments
            controls.addArrangedSubview(segments)
        }
        reset.onClick = { [weak self] in
            guard let self, self.store.isSet(self.field) else { return }
            self.localProblem = nil
            self.store.set(self.field, to: nil)
        }
        reset.toolTip = "Take this key out of the file, so it follows the default"
        controls.addArrangedSubview(reset)

        let row = NSStackView(views: [text, controls])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private func makeField(width: CGFloat) -> NSTextField {
        let input = NSTextField()
        Theme.squareField(input, font: Theme.mono(12), height: 24)
        input.cell?.sendsActionOnEndEditing = true
        input.target = self
        input.action = #selector(committed(_:))
        input.widthAnchor.constraint(equalToConstant: width).isActive = true
        self.input = input
        return input
    }

    func refresh(animated: Bool) {
        let value = field.read(store.config)
        let display = value.map(Self.display) ?? ""
        if let input, input.currentEditor() == nil, input.stringValue != display {
            crossfade(input, animated: animated)
            input.stringValue = display
        }
        shown = display
        if let segments {
            switch (field.control, value) {
            case (.toggle, .bool(let on)?): segments.select(on ? 0 : 1, animated: animated)
            case (.choice(let options), .string(let s)?): segments.select(options.firstIndex(of: s), animated: animated)
            default: segments.select(nil, animated: animated)
            }
        }

        // An optional with no default says what having none means, which is
        // the placeholder its field already shows.
        var unset = "unset"
        if case .text(let placeholder) = field.control { unset = placeholder }
        let defaultText = field.defaultValue.map(Self.display) ?? unset
        let pending = !field.appliesLive && field.read(store.launched) != value
        text.setMeta(
            "default \(defaultText.isEmpty ? "\"\"" : defaultText) · \(field.appliesLive ? "live" : "on relaunch")",
            pending: pending, animated: animated)

        let problem = store.problem(for: field).map { "$ ignored: \($0.reason)" } ?? localProblem.map { "$ \($0)" }
        text.setProblem(problem, container: superview, animated: animated)

        let isSet = store.isSet(field)
        let alpha: CGFloat = isSet ? 1 : 0
        if reset.alphaValue != alpha {
            if animated, !Motion.isReduced {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.pane
                    reset.animator().alphaValue = alpha
                }
            } else {
                reset.alphaValue = alpha
            }
        }
    }

    static func display(_ value: TomlValue) -> String {
        switch value {
        case .string(let s): return s
        case .integer(let n): return String(n)
        case .float(let d): return String(format: "%g", d)
        case .bool(let b): return b ? "on" : "off"
        case .array(let items): return items.map(display).joined(separator: " ")
        }
    }

    @objc private func committed(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard typed != shown else { return }
        if typed.isEmpty {
            localProblem = nil
            store.set(field, to: nil)
            return
        }
        switch parse(typed) {
        case .success(let value): commit(value)
        case .failure(let reason):
            localProblem = "not written: \(reason)"
            sender.stringValue = shown ?? ""
            refresh(animated: true)
        }
    }

    private struct Refusal: Error { let text: String }

    private func parse(_ typed: String) -> Result<TomlValue, Refusal> {
        switch field.control {
        case .integer(let range, _):
            guard let n = Int64(typed) else { return .failure(Refusal(text: "\(typed) is not a whole number")) }
            guard range.contains(n) else {
                return .failure(Refusal(text: "\(n) is outside \(range.lowerBound)–\(range.upperBound)"))
            }
            return .success(.integer(n))
        case .number(let range, _):
            guard let d = Double(typed), d.isFinite else { return .failure(Refusal(text: "\(typed) is not a number")) }
            guard range.contains(d) else {
                return .failure(Refusal(text: "\(typed) is outside \(Self.display(.float(range.lowerBound)))–\(Self.display(.float(range.upperBound)))"))
            }
            return .success(.float(d))
        default:
            return .success(.string(typed))
        }
    }

    private func step(_ direction: Int) {
        let value = field.read(store.config)
        switch (field.control, value) {
        case (.integer(let range, let step), .integer(let n)?):
            commit(.integer(min(max(n + Int64(direction) * step, range.lowerBound), range.upperBound)))
        case (.number(let range, let step), .float(let d)?):
            let next = ((d / step).rounded() + Double(direction)) * step
            let tidy = (next * 1_000_000).rounded() / 1_000_000
            commit(.float(min(max(tidy, range.lowerBound), range.upperBound)))
        default:
            return
        }
    }

    private func commit(_ value: TomlValue) {
        localProblem = nil
        guard value != field.read(store.config) || !store.isSet(field) || store.problem(for: field) != nil else { return }
        store.set(field, to: value)
    }
}

/// A command, the chords that run it, and the ways to change them.
@MainActor
private final class KeyRow: NSView {
    let command: Command
    var onRecord: (() -> Void)?
    private let store: ConfigStore
    private let text = RowText()
    private let chords = NSTextField()
    private let reset = AskButton(label: "default", isDefault: false)
    private var shown = ""

    init(command: Command, store: ConfigStore) {
        self.command = command
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        text.name.stringValue = command.title
        text.summary.stringValue = "keys.\(command.rawValue)"

        Theme.squareField(chords, font: Theme.mono(12), height: 24)
        chords.cell?.sendsActionOnEndEditing = true
        chords.placeholderString = "no key"
        chords.target = self
        chords.action = #selector(committed(_:))
        chords.widthAnchor.constraint(equalToConstant: 132).isActive = true

        let record = AskButton(label: "rec", isDefault: false)
        record.onClick = { [weak self] in self?.onRecord?() }
        record.toolTip = "Press the chord you want next. esc cancels."
        let none = AskButton(label: "none", isDefault: false)
        none.onClick = { [weak self] in
            guard let self else { return }
            self.store.setChords(self.command, to: [])
        }
        reset.onClick = { [weak self] in
            guard let self, self.store.isSet(self.command) else { return }
            self.store.setChords(self.command, to: nil)
        }

        let controls = NSStackView(views: [chords, record, none, reset])
        controls.orientation = .horizontal
        controls.spacing = 6
        let row = NSStackView(views: [text, controls])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 8, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    static func mentions(_ complaint: String, _ command: Command) -> Bool {
        KeyComplaint.mentions(complaint, command)
    }

    func refresh(keymap: Keymap, complaints: [String], animated: Bool) {
        let effective = keymap.chords(for: command).map(\.text).joined(separator: " ")
        if chords.currentEditor() == nil, chords.stringValue != effective {
            crossfade(chords, animated: animated)
            chords.stringValue = effective
        }
        shown = effective
        let shipped = Keymap.defaults.chords(for: command).map(\.text).joined(separator: " ")
        let pending = keymap.chords(for: command) != Keymap.active.chords(for: command)
        text.setMeta("default \(shipped.isEmpty ? "none" : shipped) · on relaunch", pending: pending, animated: animated)
        text.setProblem(
            complaints.isEmpty ? nil : complaints.map { "$ \($0)" }.joined(separator: "\n"),
            container: superview, animated: animated)
        let alpha: CGFloat = store.isSet(command) ? 1 : 0
        if reset.alphaValue != alpha {
            if animated, !Motion.isReduced {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Motion.pane
                    reset.animator().alphaValue = alpha
                }
            } else {
                reset.alphaValue = alpha
            }
        }
    }

    func setRecording(_ on: Bool) {
        crossfade(chords, animated: true)
        chords.layerBorderColor = on ? Theme.accent : Theme.laneBorder
        chords.placeholderString = on ? "press a chord" : "no key"
        chords.stringValue = on ? "" : shown
    }

    /// Typed chords, space-separated, in either spelling. One that does not
    /// parse is written as typed, so the file says exactly what was asked and
    /// the keymap's complaint about it shows up on this row.
    @objc private func committed(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard typed != shown else { return }
        let spellings = typed.split(whereSeparator: \.isWhitespace).map { token in
            KeyChord(String(token))?.configText ?? String(token)
        }
        store.setChords(command, to: spellings)
    }
}
