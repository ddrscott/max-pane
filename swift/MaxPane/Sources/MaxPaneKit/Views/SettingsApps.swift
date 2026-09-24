import AppKit

/// Settings › Apps: the `[[apps]]` tables as rows you can act on.
///
/// One row per web app — its name (a field: type and leave it to rename),
/// where it lives, the chord, and which edge it opens at. `rec` takes the next
/// chord you press and `none` unbinds, exactly as the Keyboard section's rows
/// do and through the same `ChordRecorder`, because an app's key is a key and
/// learning a second way to set one would be learning it twice.
///
/// Nothing here talks to the strip. Every control writes `config.toml` through
/// `ConfigStore`, comments kept, and the rows come back from the file — so an
/// app added by hand in an editor and one added here are the same app by the
/// time anything reads them. The chord itself applies at the next launch, like
/// `[keys]`, and the row says so.
@MainActor
final class AppsSection: NSStackView {
    let store: ConfigStore
    /// Set by the window: the next key press is this row's chord.
    var onRecord: ((AppRow) -> Void)?

    private let note = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private var rows: [String: AppRow] = [:]
    private let addName = NSTextField()
    private let addURL = NSTextField()
    private let addButton = AskButton(label: "add", isDefault: true)
    private let addProblem = NSTextField(wrappingLabelWithString: "")
    private var lastNames: [String] = []

    static let width: CGFloat = ServersSection.width

    init(store: ConfigStore) {
        self.store = store
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        note.font = Theme.mono(11)
        note.textColor = Theme.dimText
        note.preferredMaxLayoutWidth = Self.width
        note.stringValue = "A page with a key of its own. The chord focuses the lane already on that site — matched "
            + "by domain, so anywhere inside it counts — and opens one only when there is none. dock holds that "
            + "new lane at an edge. Names and addresses apply at once; a chord applies on relaunch."
        addArrangedSubview(note)
        setCustomSpacing(12, after: note)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        setCustomSpacing(14, after: rowsStack)

        Theme.squareField(addName, font: Theme.mono(12), height: 24)
        addName.placeholderString = "name"
        addName.toolTip = "What ⌘/, ⌘E and `maxpane app` call it."
        addName.widthAnchor.constraint(equalToConstant: 132).isActive = true
        Theme.squareField(addURL, font: Theme.mono(12), height: 24)
        addURL.placeholderString = "mail.google.com"
        addURL.cell?.lineBreakMode = .byTruncatingTail
        addURL.widthAnchor.constraint(equalToConstant: Self.width - 132 - 6 - 6 - 50).isActive = true
        addURL.target = self
        addURL.action = #selector(addPressed)
        addButton.onClick = { [weak self] in self?.addPressed() }
        let addLine = NSStackView(views: [addName, addURL, addButton])
        addLine.orientation = .horizontal
        addLine.spacing = 6
        addLine.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(addLine)
        setCustomSpacing(4, after: addLine)

        addProblem.font = Theme.mono(11)
        addProblem.textColor = Theme.accent
        addProblem.preferredMaxLayoutWidth = Self.width
        addProblem.isHidden = true
        addArrangedSubview(addProblem)

        refresh(animated: false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not a nib") }

    /// The rows, in file order, for the window and the tests.
    var appRows: [AppRow] { rowsStack.arrangedSubviews.compactMap { $0 as? AppRow } }

    // MARK: - rows

    func refresh(animated: Bool) {
        let animated = animated && window != nil
        let entries = store.config.apps
        let names = entries.map(\.name)
        if names != lastNames {
            let old = rows
            rows = [:]
            for view in rowsStack.arrangedSubviews { view.removeFromSuperview() }
            for entry in entries {
                let row = old[entry.name] ?? makeRow(entry)
                rows[entry.name] = row
                rowsStack.addArrangedSubview(row)
            }
            if animated { crossfade(rowsStack) }
            lastNames = names
        }
        let keymap = store.keymap
        // A complaint that names this app belongs on its row. The keymap
        // spells one `apps.<name>:` or `<chord>: the app <name> …`, so the
        // name is what the row looks for — and a collision that names two
        // apps shows on both, the way a command collision does.
        for entry in entries {
            let mine = keymap.complaints.filter { AppRow.mentions($0, entry.name) }
            rows[entry.name]?.update(entry: entry, keymap: keymap, complaints: mine, animated: animated)
        }
    }

    private func makeRow(_ entry: WebAppEntry) -> AppRow {
        let row = AppRow(name: entry.name)
        row.onRename = { [weak self] old, new in
            guard let self else { return nil }
            if new.isEmpty { return "an app needs a name" }
            return self.store.renameApp(from: old, to: new) ? nil : "\"\(new)\" is already an app's name"
        }
        row.onURL = { [weak self] url in
            guard let self, let name = row.currentName else { return }
            self.store.setAppURL(named: name, to: url)
        }
        row.onChord = { [weak self] spelling in
            guard let self, let name = row.currentName else { return }
            self.store.setAppChord(named: name, to: spelling)
        }
        row.onDock = { [weak self] edge in
            guard let self, let name = row.currentName else { return }
            self.store.setAppDocked(named: name, to: edge)
        }
        row.onRecord = { [weak self, weak row] in
            guard let self, let row else { return }
            self.onRecord?(row)
        }
        row.onRemove = { [weak self] in self?.confirmRemove(row) }
        return row
    }

    // MARK: - actions

    @objc private func addPressed() {
        let name = addName.stringValue.trimmingCharacters(in: .whitespaces)
        let url = addURL.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty || !url.isEmpty else {
            showAddProblem(nil)
            return
        }
        // The name defaults to the site, the way a server's defaults to its
        // host: "Gmail" is not information the address lacks.
        let entry = WebAppEntry(name: name.isEmpty ? (WebAppEntry(name: "x", url: url).domain ?? "") : name, url: url)
        if let why = entry.complaint {
            showAddProblem(why)
            return
        }
        guard !store.config.apps.contains(where: { $0.name.lowercased() == entry.name.lowercased() }) else {
            showAddProblem("\"\(entry.name)\" is already an app's name")
            return
        }
        store.addApp(entry)
        addName.stringValue = ""
        addURL.stringValue = ""
        showAddProblem(nil)
    }

    private func showAddProblem(_ text: String?) {
        if let text, addProblem.stringValue != "$ \(text)" {
            if !addProblem.isHidden { crossfade(addProblem) }
            addProblem.stringValue = "$ \(text)"
        }
        setShown(addProblem, text != nil, in: self)
    }

    private func confirmRemove(_ row: AppRow) {
        guard let name = row.currentName else { return }
        ConfirmPopup.confirm(
            over: window, title: "Remove \(name)?",
            detail: "Its table leaves config.toml and its chord stops working at the next launch. "
                + "A lane already on the site stays exactly where it is.",
            action: "Remove", returnConfirms: false
        ) { [weak self] yes in
            guard yes else { return }
            self?.store.removeApp(named: name)
        }
    }
}

/// One app: name field, address, chord field with `rec` and `none`, the dock
/// segments, and remove.
@MainActor
final class AppRow: NSView, ChordRecording {
    /// Returns why the rename was refused, or nil when it went through.
    var onRename: ((String, String) -> String?)?
    var onURL: ((String) -> Void)?
    /// A chord spelling, or "" to unbind.
    var onChord: ((String) -> Void)?
    var onDock: ((AppDock?) -> Void)?
    var onRecord: (() -> Void)?
    var onRemove: (() -> Void)?

    private(set) var currentName: String?
    private let nameField = NSTextField()
    private let urlField = NSTextField()
    private let chordField = NSTextField()
    private let dock = SquareSegments(options: ["strip", "left", "right"])
    private let remove = AskButton(label: "remove", isDefault: false)
    private let meta = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let rule = NSView()
    private var detailLine: NSStackView?
    private var shownChord = ""

    init(name: String) {
        currentName = name
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        Theme.squareField(nameField, font: Theme.mono(12, weight: .medium), height: 24)
        nameField.stringValue = name
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.toolTip = "What ⌘/, ⌘E and `maxpane app` call it. Type and leave to rename."
        nameField.widthAnchor.constraint(equalToConstant: 132).isActive = true

        Theme.squareField(urlField, font: Theme.mono(11), height: 24)
        urlField.cell?.sendsActionOnEndEditing = true
        urlField.cell?.lineBreakMode = .byTruncatingTail
        urlField.target = self
        urlField.action = #selector(urlCommitted(_:))
        urlField.toolTip = "Where the app lives. A bare host is read as https://."
        urlField.widthAnchor.constraint(equalToConstant: 216).isActive = true

        Theme.squareField(chordField, font: Theme.mono(12), height: 24)
        chordField.cell?.sendsActionOnEndEditing = true
        chordField.placeholderString = "no key"
        chordField.target = self
        chordField.action = #selector(chordCommitted(_:))
        chordField.widthAnchor.constraint(equalToConstant: 96).isActive = true

        let record = AskButton(label: "rec", isDefault: false)
        record.onClick = { [weak self] in self?.onRecord?() }
        record.toolTip = "Press the chord you want next. esc cancels."
        let none = AskButton(label: "none", isDefault: false)
        none.onClick = { [weak self] in self?.onChord?("") }
        remove.onClick = { [weak self] in self?.onRemove?() }
        dock.toolTip = "Which edge the chord opens the lane at. strip is an ordinary lane."
        dock.onChoose = { [weak self] index in
            self?.onDock?(index == 1 ? .left : index == 2 ? .right : nil)
        }

        meta.font = Theme.mono(10)
        meta.textColor = Theme.dimText
        detail.font = Theme.mono(11)
        detail.textColor = Theme.accent
        detail.preferredMaxLayoutWidth = AppsSection.width - 20

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [nameField, urlField, chordField, record, none, spacer, remove])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6
        top.translatesAutoresizingMaskIntoConstraints = false

        func indented(_ label: NSTextField) -> NSStackView {
            let gap = NSView()
            gap.widthAnchor.constraint(equalToConstant: 2).isActive = true
            let line = NSStackView(views: [gap, label])
            line.orientation = .horizontal
            line.spacing = 0
            line.translatesAutoresizingMaskIntoConstraints = false
            return line
        }
        // The edge goes under the row rather than beside it, the way a
        // server's colour does: the top line is already four controls wide,
        // and three segments on the end of it ran off the column.
        let dockGap = NSView()
        dockGap.widthAnchor.constraint(equalToConstant: 2).isActive = true
        let dockWord = NSTextField(labelWithString: "dock")
        dockWord.font = Theme.mono(10)
        dockWord.textColor = Theme.dimText
        let dockLine = NSStackView(views: [dockGap, dockWord, dock])
        dockLine.orientation = .horizontal
        dockLine.alignment = .centerY
        dockLine.spacing = 0
        dockLine.setCustomSpacing(8, after: dockWord)
        dockLine.translatesAutoresizingMaskIntoConstraints = false
        let metaLine = indented(meta)
        let detailLine = indented(detail)
        detailLine.isHidden = true
        let column = NSStackView(views: [top, dockLine, metaLine, detailLine])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        self.detailLine = detailLine

        rule.wantsLayer = true
        rule.layerBackgroundColor = Theme.laneBorder
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            widthAnchor.constraint(equalToConstant: AppsSection.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // What the row shows, for the tests.
    var chordText: String { chordField.stringValue }
    var metaText: String { meta.stringValue }
    var detailText: String? { detailLine?.isHidden == false ? detail.stringValue : nil }

    /// Whether a keymap complaint is about this app. By name, and only where
    /// the keymap actually names one — `apps.<name>:` or `the app <name>` —
    /// so a command's complaint that merely contains the word never lands
    /// here.
    static func mentions(_ complaint: String, _ name: String) -> Bool {
        complaint.lowercased().contains("apps.\(name.lowercased()):")
            || complaint.lowercased().contains("the app \(name.lowercased()) ")
            || complaint.lowercased().hasSuffix("the app \(name.lowercased())")
    }

    func update(entry: WebAppEntry, keymap: Keymap, complaints: [String], animated: Bool) {
        currentName = entry.name
        if nameField.currentEditor() == nil, nameField.stringValue != entry.name {
            crossfade(nameField, animated: animated)
            nameField.stringValue = entry.name
        }
        if urlField.currentEditor() == nil, urlField.stringValue != entry.url {
            crossfade(urlField, animated: animated)
            urlField.stringValue = entry.url
        }
        // The chord the *file* asks for, not the one the keymap granted: the
        // field is what you typed, and the refusal is the line under it.
        let asked = entry.chord?.text ?? entry.key
        if chordField.currentEditor() == nil, chordField.stringValue != asked {
            crossfade(chordField, animated: animated)
            chordField.stringValue = asked
        }
        shownChord = asked
        dock.select(entry.docked == .left ? 1 : entry.docked == .right ? 2 : 0, animated: animated)
        let running = Keymap.active.chord(forApp: entry.name)
        let pending = keymap.chord(forApp: entry.name) != running
        var line = entry.domain.map { "goes to \($0)" } ?? "no site"
        if pending { line += " · relaunch to apply" }
        if meta.stringValue != line {
            crossfade(meta, animated: animated)
            meta.stringValue = line
        }
        meta.textColor = pending ? Theme.accent : Theme.dimText
        setDetail(complaints.isEmpty ? nil : complaints.map { "$ \($0)" }.joined(separator: "\n"), animated: animated)
    }

    // MARK: - ChordRecording

    func setRecording(_ on: Bool) {
        crossfade(chordField, animated: true)
        chordField.layerBorderColor = on ? Theme.accent : Theme.laneBorder
        chordField.placeholderString = on ? "press a chord" : "no key"
        chordField.stringValue = on ? "" : shownChord
    }

    func commit(_ chord: KeyChord) { onChord?(chord.configText) }

    // MARK: - fields

    @objc private func nameCommitted(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let old = currentName, typed != old else { return }
        if let why = onRename?(old, typed) {
            sender.stringValue = old
            setDetail("$ " + why, animated: true)
        }
    }

    @objc private func urlCommitted(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        onURL?(typed)
    }

    /// A typed chord, in either spelling. One that does not parse is written
    /// as typed, so the file says what was asked and the keymap's complaint
    /// about it shows on this row.
    @objc private func chordCommitted(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard typed != shownChord else { return }
        onChord?(KeyChord(typed)?.configText ?? typed)
    }

    private func setDetail(_ text: String?, animated: Bool) {
        if let text, detail.stringValue != text {
            if detailLine?.isHidden == false { crossfade(detail, animated: animated) }
            detail.stringValue = text
        }
        if let detailLine { setShown(detailLine, text != nil, in: superview, animated: animated) }
    }
}
