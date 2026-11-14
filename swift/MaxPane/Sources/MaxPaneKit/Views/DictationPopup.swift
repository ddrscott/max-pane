import AppKit
import LanedCore

/// What the Dictate popup decides, with no view in it (ADR-0049).
enum Dictation {
    /// What a send types. **Send** is the text as it stands; the pane's paste
    /// turns each line ending into Return and drops a trailing one, so nothing
    /// is pressed after the last word. **Send One Line** is Paste as One
    /// Line's join, so nothing in it presses Return at all. Nil when there is
    /// nothing but whitespace to send.
    static func outgoing(_ text: String, oneLine: Bool) -> String? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let out = oneLine ? TerminalPaste.oneLine(text) : text
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
    }

    /// Whether the box holds something history does not have yet: not blank,
    /// and not exactly the entry it was loaded from. An entry recalled and
    /// left alone is not kept again on close; one recalled and changed is a
    /// new entry, and the one it came from stays.
    static func isNew(_ text: String, loadedFrom: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text != loadedFrom
    }

    /// An entry as one line, the way paste history shows one: its first line
    /// with anything on it, control characters made visible.
    static func headline(_ entry: DictationEntry) -> String {
        let line = entry.content.split(whereSeparator: \.isNewline)
            .map { $0.drop(while: \.isWhitespace) }
            .first { !$0.isEmpty } ?? ""
        return TerminalPaste.preview(String(line), limit: 1, width: 200).lines.first ?? ""
    }

    /// `3 lines · 5m ago`.
    static func detail(_ entry: DictationEntry, now: Date = Date()) -> String {
        let lines = entry.content.split(whereSeparator: \.isNewline).filter {
            !$0.allSatisfy(\.isWhitespace)
        }.count
        let age = SessionTelemetry.age(since: Date(timeIntervalSince1970: Double(entry.at) / 1000), now: now)
        return "\(max(lines, 1)) line\(lines > 1 ? "s" : "") · \(age)"
    }
}

/// How the popup turns Apple's dictation on and off. The system's, by
/// default: `NSApplication` answers `startDictation:` and `stopDictation:`,
/// which is what Edit › Start Dictation sends. A test hands in a recorder,
/// because the real one opens the microphone.
@MainActor
struct DictationSwitch {
    var start: () -> Void
    var stop: () -> Void

    static let system = DictationSwitch(
        start: { NSApp.sendAction(Selector(("startDictation:")), to: NSApp, from: nil) },
        stop: { NSApp.sendAction(Selector(("stopDictation:")), to: NSApp, from: nil) })
}

/// Edit › Dictate… (F5): a box to speak into, edit, and type into the
/// terminal that had the keyboard (ADR-0049).
///
/// It opens listening. **Esc stops listening**, and a second Esc closes;
/// F5 (or the microphone key, when macOS lets it through) listens again.
/// **⌘↩ sends** the text as it stands and **⇧⌘↩ sends it as one line**,
/// joined the way Paste as One Line joins it. Either way no Return is pressed
/// after the last word, as with any paste.
///
/// **History is beside the box.** ⇥ moves between the two; ↑ ↓ in the list
/// put that entry in the box to edit or send, ↩ goes back to the box, ⌘⌫
/// deletes the entry after asking. Whatever the box held is kept before
/// anything replaces it, so nothing you said is lost to a stray ↓ or an Esc:
/// a send keeps what was sent (before the one-line join), and a close keeps
/// a box that history does not have yet. An entry recalled and changed is a
/// new entry; the one it came from stays.
///
/// `.explicitOnly`: a click on the strip does not close it. It is reading
/// your voice, and the click may be to look at what the agent just printed.
@MainActor
final class DictationPopup: Popup, NSTableViewDataSource, NSTableViewDelegate {
    static let size = NSSize(width: 820, height: 460)

    private let store: StripStore
    private let config: () -> Config
    private let paneId: String
    private let dictation: DictationSwitch
    private let completion: (String?) -> Void
    private var keyMonitor: Any?
    private var answered = false

    private(set) var entries: [DictationEntry] = []
    /// What the box was last filled from: "" for a fresh box, or an entry's
    /// text. A close keeps the box only when it differs.
    private(set) var loadedFrom = ""
    private(set) var isListening = false
    /// Set while the popup moves the selection itself, so that is not taken
    /// for a ↑ or ↓ asking for an entry.
    private var selectingQuietly = false

    let editor = PlainTextView()
    let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let historyNote = NSTextField(labelWithString: "")

    /// - Parameters:
    ///   - paneId: the terminal that had the keyboard, which a send types
    ///     into and history is kept for (a private lane keeps nothing).
    ///   - target: that lane's name, so the popup says where it will type.
    ///   - completion: the text to type, or nil when nothing is to be sent.
    init(
        store: StripStore, config: @escaping () -> Config, paneId: String, target: String,
        dictation: DictationSwitch = .system, completion: @escaping (String?) -> Void
    ) {
        self.store = store
        self.config = config
        self.paneId = paneId
        self.dictation = dictation
        self.completion = completion
        super.init(size: Self.size, dismissal: .explicitOnly, resizable: true,
                   minSize: NSSize(width: 520, height: 300))
        entries = store.dictationHistory(config())
        window?.contentView = build(target: target)
        refreshStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override var handlesEscape: Bool { true }

    var text: String { editor.string }

    // MARK: - presenting

    override func popupDidPresent() {
        window?.makeFirstResponder(editor)
        installKeys()
        // After the entrance, so the box is key and first responder when the
        // system asks who is listening.
        DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.isReduced ? 0 : Motion.pane)) { [weak self] in
            guard let self, self.isOpen else { return }
            self.startListening()
        }
    }

    override func popupCancelled() { finish(sending: nil) }

    // MARK: - listening

    func startListening() {
        guard !isListening else { return }
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        isListening = true
        dictation.start()
        refreshStatus()
    }

    func stopListening() {
        guard isListening else { return }
        isListening = false
        dictation.stop()
        refreshStatus()
    }

    func toggleListening() { isListening ? stopListening() : startListening() }

    /// Esc: the first stops listening, the next closes.
    func escape() {
        if isListening { stopListening() } else { popupCancelled() }
    }

    // MARK: - sending

    func send(oneLine: Bool) {
        guard let out = Dictation.outgoing(text, oneLine: oneLine) else {
            say("nothing to send yet")
            return
        }
        finish(sending: out)
    }

    /// Answer once. Keep what history does not have, stop listening, go.
    private func finish(sending out: String?) {
        guard !answered else { return }
        answered = true
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        stopListening()
        // A send keeps what was sent even when it is a recalled entry as it
        // was: using it again moves it to the top.
        if out != nil ? !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      : Dictation.isNew(text, loadedFrom: loadedFrom) {
            store.recordDictation(paneId: paneId, text: text, config: config())
        }
        closePopup()
        completion(out)
    }

    // MARK: - history

    /// Put entry `row` in the box, keeping what the box held first if
    /// history does not have it. Keeping it moves rows, so the entry asked
    /// for is found again by its id.
    func load(row: Int) {
        guard row >= 0, row < entries.count else { return }
        let wanted = entries[row]
        guard text != wanted.content else { return }
        stopListening()
        if Dictation.isNew(text, loadedFrom: loadedFrom) {
            let kept = store.recordDictation(paneId: paneId, text: text, config: config())
            loadedFrom = text
            if kept { reloadEntries(selecting: wanted.id) }
        }
        loadedFrom = wanted.content
        editor.string = wanted.content
        editor.undoManager?.removeAllActions()
        Motion.fade(editor.enclosingScrollView?.layer)
        refreshStatus()
    }

    private func reloadEntries(selecting id: Int64?) {
        entries = store.dictationHistory(config())
        table.reloadData()
        if let id, let row = entries.firstIndex(where: { $0.id == id }) {
            selectingQuietly = true
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            selectingQuietly = false
            table.scrollRowToVisible(row)
        }
        refreshHistoryNote()
    }

    private func askToDelete(row: Int) {
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        let preview = TerminalPaste.preview(entry.content, limit: 4, width: 120)
        let more = preview.more > 0 ? "\n… \(preview.more) more line\(preview.more == 1 ? "" : "s")" : ""
        ConfirmPopup.confirm(
            over: window, title: "Delete this from dictation history?",
            detail: preview.lines.joined(separator: "\n") + more,
            action: "Delete", returnConfirms: false
        ) { [weak self] yes in
            guard let self, yes else { return }
            self.store.deleteDictation(entry.id)
            self.reloadEntries(selecting: nil)
            if !self.entries.isEmpty {
                let next = min(row, self.entries.count - 1)
                self.table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            }
        }
    }

    // MARK: - keys

    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// True when the key was the popup's.
    func handle(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let inList = window?.firstResponder === table
        if Command.dictate.chords.contains(KeyChord.typed(event)) {
            toggleListening()
            return true
        }
        switch event.keyCode {
        case 53 where mods.isEmpty:
            escape()
            return true
        case 36, 76:
            if mods == [.command] { send(oneLine: false); return true }
            if mods == [.command, .shift] { send(oneLine: true); return true }
            if inList, mods.isEmpty { focusEditor(); return true }
            return false
        case 48 where mods.isEmpty || mods == [.shift]:
            inList ? focusEditor() : focusList()
            return true
        case 51 where inList && (mods.isEmpty || mods == [.command]):
            askToDelete(row: table.selectedRow)
            return true
        default:
            return false
        }
    }

    func focusEditor() {
        window?.makeFirstResponder(editor)
        refreshStatus()
    }

    func focusList() {
        guard !entries.isEmpty else {
            say("nothing in history yet")
            return
        }
        stopListening()
        window?.makeFirstResponder(table)
        // Selecting is loading (`tableViewSelectionDidChange`).
        if table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            load(row: table.selectedRow)
        }
        refreshStatus()
    }

    // MARK: - table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 40 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < entries.count else { return nil }
        return DictationRow(entry: entries[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selectingQuietly else { return }
        load(row: table.selectedRow)
    }

    // MARK: - what it says

    private func refreshStatus() {
        let line = NSMutableAttributedString()
        if isListening {
            line.append(NSAttributedString(string: "$ ", attributes: [
                .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
            ]))
            line.append(NSAttributedString(string: "LISTENING · ESC STOPS", attributes: [
                .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
            ]))
        } else {
            line.append(PaletteStyle.caps("not listening · \(Self.dictateKey) listens"))
        }
        if status.attributedStringValue != line {
            Motion.fade(status.layer)
            status.attributedStringValue = line
        }
        note.stringValue = "\(Self.dictateKey) listen    ⇥ history    ⌘↩ send    ⇧⌘↩ one line    esc "
            + (isListening ? "stops" : "closes")
        refreshHistoryNote()
    }

    private func refreshHistoryNote() {
        historyNote.attributedStringValue = PaletteStyle.caps(
            entries.isEmpty ? "nothing yet"
                : config().dictationHistoryKeep == 0 ? "history is off · dictation_history_keep"
                : "\(entries.count) kept · newest first")
    }

    private func say(_ text: String) {
        Motion.fade(historyNote.layer)
        historyNote.attributedStringValue = PaletteStyle.caps(text)
    }

    private static var dictateKey: String { Command.dictate.chords.first?.text ?? "F5" }

    // MARK: - building

    private func build(target: String) -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        let header = NSTextField(labelWithString: "")
        let title = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: Theme.accent,
        ])
        title.append(NSAttributedString(string: "DICTATE", attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: Theme.dimText,
        ]))
        header.attributedStringValue = title
        let into = PaletteStyle.label("into \(target)", Theme.mono(11), Theme.dimText)
        into.lineBreakMode = .byTruncatingTail
        into.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.wantsLayer = true
        status.alignment = .right
        let headSpacer = NSView()
        headSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [header, into, headSpacer, status])
        head.spacing = 12

        // The box: the terminals' font, plain text, nothing substituted.
        editor.font = NSFont(name: config().fontName, size: 13) ?? Theme.mono(13)
        editor.textColor = .labelColor
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: 6, height: 8)
        editor.onLeave = { [weak self] in self?.escape() }
        let editorScroll = NSScrollView()
        editorScroll.wantsLayer = true
        editorScroll.documentView = editor
        editorScroll.hasVerticalScroller = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = Theme.stripBackground
        editorScroll.borderType = .noBorder
        editorScroll.wantsLayer = true
        editorScroll.layerBorderColor = Theme.laneBorder
        editorScroll.layer?.borderWidth = Theme.borderWidth

        // History.
        let column = NSTableColumn(identifier: .init("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false
        tableScroll.borderType = .noBorder
        historyNote.wantsLayer = true
        let historyHead = NSTextField(labelWithString: "")
        historyHead.attributedStringValue = {
            let t = NSMutableAttributedString(string: "// ", attributes: [
                .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
            ])
            t.append(NSAttributedString(string: "HISTORY", attributes: [
                .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.dimText,
            ]))
            return t
        }()
        let history = NSStackView(views: [historyHead, tableScroll, historyNote])
        history.orientation = .vertical
        history.alignment = .leading
        history.spacing = 6

        let body = NSStackView(views: [editorScroll, history])
        body.orientation = .horizontal
        body.alignment = .top
        body.distribution = .fill
        body.spacing = 14

        // Footer: the keys, then the three ways out.
        note.font = Theme.mono(10)
        note.textColor = Theme.dimText
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cancel = AskButton(label: "CANCEL", isDefault: false)
        cancel.onClick = { [weak self] in self?.popupCancelled() }
        let oneLine = AskButton(label: "SEND ONE LINE", isDefault: false)
        oneLine.onClick = { [weak self] in self?.send(oneLine: true) }
        let send = AskButton(label: "SEND", isDefault: true)
        send.onClick = { [weak self] in self?.send(oneLine: false) }
        let footSpacer = NSView()
        footSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let foot = NSStackView(views: [note, footSpacer, cancel, oneLine, send])
        foot.spacing = 8

        let stack = NSStackView(views: [head, body, foot])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            head.widthAnchor.constraint(equalTo: stack.widthAnchor),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor),
            foot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            history.widthAnchor.constraint(equalToConstant: 270),
            history.heightAnchor.constraint(equalTo: body.heightAnchor),
            editorScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            tableScroll.widthAnchor.constraint(equalTo: history.widthAnchor),
        ])
        body.setContentHuggingPriority(.init(1), for: .vertical)
        refreshHistoryNote()
        return content
    }
}

/// One history entry: its first line, and its size and age under it.
final class DictationRow: NSTableCellView {
    init(entry: DictationEntry, now: Date = Date()) {
        super.init(frame: .zero)
        let line = PaletteStyle.label(Dictation.headline(entry), Theme.mono(12), .labelColor)
        line.lineBreakMode = .byTruncatingTail
        let detail = PaletteStyle.label(Dictation.detail(entry, now: now), Theme.mono(10), Theme.dimText)
        detail.lineBreakMode = .byTruncatingTail
        for v in [line, detail] { addSubview(v) }
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            line.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 2),
            detail.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
