import AppKit

/// Settings › Servers: the `[[servers]]` tables as rows you can act on.
///
/// Every row is one remote relay-tty server — its name (a field: type and
/// leave it to rename), its URL, a dot and a word for how it is doing, the
/// session count, and the last error in one line when there is one. The
/// controls are the window's own: square segments for on/off, `AskButton`s
/// for paste and remove, `ConfirmPopup` for the remove. Under the rows, one
/// line to paste the Auth URL the server printed at startup, and a name
/// that defaults to the host.
///
/// Nothing here talks to a server. Add writes the file and the Keychain
/// through `RelayServerBook`; the source the registry then starts does the
/// asking on its own queue, and the row reads the answer off the registry
/// when it arrives, through `refresh`. The token is never on screen: the
/// paste field is cleared the moment it is read, and no label ever holds
/// one.
@MainActor
final class ServersSection: NSStackView {
    let book: RelayServerBook
    /// The ledger's half of a rename, owned by the window controller.
    var onRename: ((String, String) -> Void)?

    private let note = NSTextField(wrappingLabelWithString: "")
    private let rowsStack = NSStackView()
    private var rows: [String: ServerRow] = [:]
    private let addName = NSTextField()
    private let addURL = NSTextField()
    private let addButton = AskButton(label: "add", isDefault: true)
    private let addProblem = NSTextField(wrappingLabelWithString: "")
    private var registryObserver: UUID?
    private var lastNames: [String] = []

    /// The width the rows lay out to: the window's content column.
    static let width: CGFloat = SettingsWindow.size.width - SettingsWindow.navWidth - 48

    init(book: RelayServerBook) {
        self.book = book
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false

        note.font = Theme.mono(11)
        note.textColor = Theme.dimText
        note.preferredMaxLayoutWidth = Self.width
        note.stringValue = "A relay-tty server on another machine, whose sessions appear in the sidebar and ⌘O beside "
            + "the local ones. Paste the Auth URL it printed at startup: the token goes to the macOS Keychain, "
            + "the name and URL to [[servers]] in the file. Everything here applies at once."
        addArrangedSubview(note)
        setCustomSpacing(12, after: note)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(rowsStack)
        rowsStack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        setCustomSpacing(14, after: rowsStack)

        // The add line.
        Theme.squareField(addName, font: Theme.mono(12), height: 24)
        addName.placeholderString = "name"
        addName.toolTip = "What the lane header shows. Defaults to the host's first label."
        addName.widthAnchor.constraint(equalToConstant: 132).isActive = true
        Theme.squareField(addURL, font: Theme.mono(12), height: 24)
        addURL.placeholderString = "paste the Auth URL the server printed, or a bare https://host"
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

        book.onChange = { [weak self] in self?.refresh(animated: true) }
        registryObserver = book.registry.observe { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(animated: true) }
        }
        refresh(animated: false)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - rows

    /// Bring the rows to what the file and the registry say now. Rows are
    /// kept by name so a state change fades in place; a server added or
    /// removed rebuilds the list, eased.
    func refresh(animated: Bool) {
        // Nothing eases before the window is up: an animation started off
        // screen leaves a view at alpha 0 until a run loop it may not get.
        let animated = animated && window != nil
        let entries = book.entries
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
        for entry in entries {
            rows[entry.name]?.update(entry: entry, status: book.status(of: entry), animated: animated)
        }
    }

    private func makeRow(_ entry: RelayServerEntry) -> ServerRow {
        let row = ServerRow(name: entry.name)
        row.onToggle = { [weak self] on in
            guard let self, let name = row.currentName else { return }
            self.book.setEnabled(name, on)
        }
        row.onRename = { [weak self] old, new in
            guard let self else { return nil }
            return self.book.rename(old, to: new, ledger: self.onRename)
        }
        row.onColour = { [weak self] colour in
            guard let self, let name = row.currentName else { return }
            if let why = self.book.setColour(name, colour) { row.showProblem(why) }
        }
        row.onPaste = { [weak self] in self?.askForToken(row) }
        row.onRemove = { [weak self] in self?.confirmRemove(row) }
        return row
    }

    /// Scroll-independent: the row is outlined in the accent for a beat so
    /// the eye lands on it after a click in the sidebar.
    func mark(server name: String) {
        rows[name]?.flash()
    }

    // MARK: - actions

    @objc private func addPressed() {
        let pasted = addURL.stringValue
        // The line may carry the token: out of the field before anything
        // else happens, so a failure leaves no credential on screen.
        addURL.stringValue = ""
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAddProblem(nil)
            return
        }
        switch book.add(pasted: pasted, name: addName.stringValue) {
        case .success:
            addName.stringValue = ""
            showAddProblem(nil)
        case .failure(let why):
            showAddProblem(why.text)
        }
    }

    private func showAddProblem(_ text: String?) {
        if let text {
            if addProblem.stringValue != "$ \(text)" {
                if !addProblem.isHidden { crossfade(addProblem) }
                addProblem.stringValue = "$ \(text)"
            }
        }
        setShown(addProblem, text != nil, in: self)
    }

    private func askForToken(_ row: ServerRow) {
        guard let name = row.currentName else { return }
        ConfirmPopup.ask(
            over: window, title: "Paste the Auth URL for \(name)",
            detail: "The line the server printed at startup: https://…/api/auth/callback?token=… "
                + "The token goes to the Keychain and the server is asked again.",
            text: "", action: "Save"
        ) { [weak self] pasted in
            guard let self, let pasted else { return }
            if let why = self.book.pasteToken(name, pasted: pasted) {
                row.showProblem(why)
            }
        }
    }

    private func confirmRemove(_ row: ServerRow) {
        guard let name = row.currentName else { return }
        ConfirmPopup.confirm(
            over: window, title: "Remove \(name)?",
            detail: "Its table leaves config.toml and its token leaves the Keychain. Lanes attached to its "
                + "sessions stay on the strip and say the server is not configured.",
            action: "Remove", returnConfirms: false
        ) { [weak self] yes in
            guard yes else { return }
            self?.book.remove(name)
        }
    }
}

/// One server: name field, URL, state, count, error, and its buttons.
@MainActor
final class ServerRow: NSView, NSTextFieldDelegate {
    var onToggle: ((Bool) -> Void)?
    /// Returns why the rename was refused, or nil when it went through.
    var onRename: ((String, String) -> String?)?
    var onPaste: (() -> Void)?
    var onRemove: (() -> Void)?
    /// A swatch was pressed. The same door as the sidebar header's menu.
    var onColour: ((ServerColour) -> Void)?
    /// The eight, for the tests to read and press.
    let swatches = ServerSwatches()

    private(set) var currentName: String?
    private let dot = NSTextField(labelWithString: "●")
    private let nameField = NSTextField()
    private let url = NSTextField(labelWithString: "")
    private let state = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let segments = SquareSegments(options: ["on", "off"])
    private let paste = AskButton(label: "paste token", isDefault: false)
    private let remove = AskButton(label: "remove", isDefault: false)
    private let rule = NSView()
    private var detailLine: NSStackView?
    private var noticeLine: NSStackView?
    private var shownState: String?
    private var problem: String?

    init(name: String) {
        currentName = name
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        dot.font = Theme.mono(11)
        Theme.squareField(nameField, font: Theme.mono(12, weight: .medium), height: 24)
        nameField.stringValue = name
        nameField.cell?.sendsActionOnEndEditing = true
        nameField.target = self
        nameField.action = #selector(nameCommitted(_:))
        nameField.toolTip = "The server's name, where the directory sits on its lanes. Type and leave to rename."
        nameField.widthAnchor.constraint(equalToConstant: 132).isActive = true
        url.font = Theme.mono(11)
        url.textColor = Theme.dimText
        url.lineBreakMode = .byTruncatingMiddle
        url.widthAnchor.constraint(equalToConstant: 184).isActive = true
        state.font = Theme.mono(11, weight: .medium)
        state.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.font = Theme.mono(11)
        detail.textColor = Theme.accent
        detail.preferredMaxLayoutWidth = ServersSection.width - 20
        notice.font = Theme.mono(10)
        notice.textColor = Theme.dimText
        notice.preferredMaxLayoutWidth = ServersSection.width - 20

        segments.onChoose = { [weak self] index in self?.onToggle?(index == 0) }
        segments.toolTip = "off keeps the entry and ignores it"
        paste.onClick = { [weak self] in self?.onPaste?() }
        paste.toolTip = "Paste the server's Auth URL again: a new token replaces the one in the Keychain"
        remove.onClick = { [weak self] in self?.onRemove?() }
        swatches.onChoose = { [weak self] colour in self?.onColour?(colour) }

        // A spacer between the words and the buttons, so the buttons keep
        // to the right edge whatever the state says.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [dot, nameField, url, state, spacer, segments, paste, remove])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 8
        top.setCustomSpacing(4, after: dot)
        top.translatesAutoresizingMaskIntoConstraints = false

        // The lines under the row sit in from the dot by the name's offset,
        // each behind a fixed spacer rather than a leading constraint the
        // column's own alignment would fight.
        func indented(_ label: NSTextField) -> NSStackView {
            let gap = NSView()
            gap.widthAnchor.constraint(equalToConstant: 12).isActive = true
            let line = NSStackView(views: [gap, label])
            line.orientation = .horizontal
            line.spacing = 0
            line.translatesAutoresizingMaskIntoConstraints = false
            return line
        }
        let detailLine = indented(detail)
        detailLine.isHidden = true
        let noticeLine = indented(notice)
        noticeLine.isHidden = true
        // The colour this server is known by, under its name: the same eight
        // the sidebar header's menu offers, as squares (ADR-0025).
        let colourGap = NSView()
        colourGap.widthAnchor.constraint(equalToConstant: 12).isActive = true
        let colourWord = NSTextField(labelWithString: "color")
        colourWord.font = Theme.mono(10)
        colourWord.textColor = Theme.dimText
        let colourLine = NSStackView(views: [colourGap, colourWord, swatches])
        colourLine.orientation = .horizontal
        colourLine.alignment = .centerY
        colourLine.spacing = 0
        colourLine.setCustomSpacing(8, after: colourWord)
        colourLine.translatesAutoresizingMaskIntoConstraints = false
        let column = NSStackView(views: [top, colourLine, detailLine, noticeLine])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 4
        column.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 10, right: 0)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        self.detailLine = detailLine
        self.noticeLine = noticeLine

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
            widthAnchor.constraint(equalToConstant: ServersSection.width),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // What the row shows, for the tests.
    var stateWord: String { state.stringValue }
    var detailText: String? { detailLine?.isHidden == false ? detail.stringValue : nil }
    var showsTunnelNotice: Bool { noticeLine?.isHidden == false }
    var offersPaste: Bool { !paste.isHidden }

    /// The relay-tty side of the tunnel's WebSocket bypass (plan §1.4), said
    /// once on the row so the owner is never surprised. 1.23.0 accepts
    /// `?token=` on `/ws/share` only; `/ws/sessions/:id` and `/ws/events`
    /// read the cookie, which relaytty.com does not forward.
    static let tunnelNotice = "through relaytty.com, sessions on this server are attachable without the token "
        + "until relay-tty accepts ?token= on /ws/sessions and /ws/events (1.23.0 does not); "
        + "the token is sent regardless, so nothing here changes when it does"

    func update(entry: RelayServerEntry, status: RelayServerBook.Status, animated: Bool) {
        currentName = entry.name
        if nameField.currentEditor() == nil, nameField.stringValue != entry.name {
            crossfade(nameField, animated: animated)
            nameField.stringValue = entry.name
        }
        if url.stringValue != entry.url {
            crossfade(url, animated: animated)
            url.stringValue = entry.url
        }
        var word = status.word
        if status.kind == .connected { word += " · \(status.sessions) session\(status.sessions == 1 ? "" : "s")" }
        let colour: NSColor
        switch status.kind {
        case .connected: colour = Theme.alive
        case .reconnecting, .refused, .noToken: colour = Theme.accent
        case .disabled, .skipped: colour = Theme.dimText
        }
        if shownState != word {
            crossfade(state, animated: animated)
            crossfade(dot, animated: animated)
            state.stringValue = word
            shownState = word
        }
        state.textColor = colour
        dot.textColor = colour
        segments.select(entry.enabled ? 0 : 1, animated: animated)
        swatches.select(entry.colour, animated: animated)
        // Paste is offered where a token would change something: no token,
        // refused, or reconnecting (a token typed wrong reads as unreachable
        // through some proxies). Never on a disabled or skipped row.
        let offersPaste = [.noToken, .refused, .reconnecting].contains(status.kind)
        setShown(paste, offersPaste, in: superview, animated: animated)
        let line = problem ?? status.detail
        setDetail(line.map { "$ " + $0 }, animated: animated)
        let showNotice = status.isTunnelled && entry.enabled && status.kind != .skipped
        if showNotice, notice.stringValue.isEmpty { notice.stringValue = "$ " + Self.tunnelNotice }
        if let noticeLine { setShown(noticeLine, showNotice, in: superview, animated: animated) }
    }

    /// A refusal from the row's own action, shown until the next update
    /// that has something else to say.
    func showProblem(_ text: String) {
        problem = text
        setDetail("$ " + text, animated: true)
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.problem = nil }
        }
    }

    private func setDetail(_ text: String?, animated: Bool) {
        if let text, detail.stringValue != text {
            if detailLine?.isHidden == false { crossfade(detail, animated: animated) }
            detail.stringValue = text
        }
        if let detailLine { setShown(detailLine, text != nil, in: superview, animated: animated) }
    }


    /// The accent outline, in and out on the pane clock — the sidebar's
    /// click landed here.
    func flash() {
        wantsLayer = true
        // The colour stays dynamic (`layerBorderColor` re-resolves it on an
        // appearance change); what eases is the width, one point to none.
        layerBorderColor = Theme.accent
        guard !Motion.isReduced else {
            layer?.borderWidth = 0
            return
        }
        let fade = CABasicAnimation(keyPath: "borderWidth")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = Motion.lane * 4
        fade.timingFunction = Motion.easeOutTiming
        layer?.borderWidth = 0
        layer?.add(fade, forKey: "flash")
    }

    @objc private func nameCommitted(_ sender: NSTextField) {
        let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
        guard let old = currentName, typed != old else { return }
        if let why = onRename?(old, typed) {
            sender.stringValue = old
            showProblem(why)
        }
    }
}

/// The eight server colours as a row of squares, the chosen one framed.
///
/// Squares because the mark is a square. The chosen one wears a
/// full-perimeter outline a point off its edge — never a bar on one side —
/// and a change of choice eases. Each square's tooltip is its name, which is
/// also what `color = "…"` takes in the file.
@MainActor
final class ServerSwatches: NSView {
    var onChoose: ((ServerColour) -> Void)?
    private(set) var selected: ServerColour = .fallback
    private var cells: [ServerColour: SwatchCell] = [:]

    static let cell: CGFloat = 18

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.translatesAutoresizingMaskIntoConstraints = false
        for colour in ServerColour.allCases {
            let cell = SwatchCell(colour: colour)
            cell.onClick = { [weak self] in self?.onChoose?(colour) }
            cells[colour] = cell
            row.addArrangedSubview(cell)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        select(.fallback, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func select(_ colour: ServerColour, animated: Bool) {
        guard colour != selected || cells[colour]?.isChosen != true else { return }
        selected = colour
        if animated, window != nil { Motion.fade(layer) }
        for (each, cell) in cells { cell.isChosen = each == colour }
    }

    /// Press one, as a click would. For tests.
    func press(_ colour: ServerColour) { cells[colour]?.onClick?() }
}

/// One square of `ServerSwatches`: the colour, inset in a frame that shows
/// only when it is the chosen one.
@MainActor
final class SwatchCell: NSView {
    let colour: ServerColour
    var onClick: (() -> Void)?
    private let square = NSView()

    var isChosen = false {
        didSet {
            layer?.borderWidth = isChosen ? 1 : 0
            setAccessibilityValue(isChosen ? "selected" : nil)
        }
    }

    init(colour: ServerColour) {
        self.colour = colour
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layerBorderColor = NSColor.labelColor
        translatesAutoresizingMaskIntoConstraints = false
        ServerMark.paint(square, colour: colour, hollow: false)
        square.translatesAutoresizingMaskIntoConstraints = false
        addSubview(square)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: ServerSwatches.cell),
            heightAnchor.constraint(equalToConstant: ServerSwatches.cell),
            square.centerXAnchor.constraint(equalTo: centerXAnchor),
            square.centerYAnchor.constraint(equalTo: centerYAnchor),
            square.widthAnchor.constraint(equalToConstant: ServerSwatches.cell - 8),
            square.heightAnchor.constraint(equalToConstant: ServerSwatches.cell - 8),
        ])
        toolTip = colour.rawValue
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("\(colour.title) server colour")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
