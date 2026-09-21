import AppKit

/// What the person said to a paste that asked first.
enum PasteAnswer: Equatable {
    /// Esc, ↩, CANCEL, and the pane going away. Nothing is sent.
    case cancelled
    /// Send it. `oneLine` joins the lines first; `tabsToSpaces` is the toggle.
    case paste(oneLine: Bool, tabsToSpaces: Bool)
}

/// A paste that would do something the person may not have meant, held in
/// front of them before a byte of it goes: over the pane it is about to land
/// in, modal to nothing (ADR-0026).
///
/// The shape is `WebAskSheet`'s, for its reasons: a scrim over the pane, a
/// square panel at the top of it outlined on all four sides, the `//` header,
/// the accent on the default button and nowhere else.
///
/// **The default is the safe one.** ↩ and Esc both cancel. Return is the key
/// the whole sheet exists to keep from being pressed by accident, so it cannot
/// be the key that sends five lines to a shell. Sending takes a letter: `P`
/// pastes, `O` pastes as one line, `T` turns tabs to spaces and back. The
/// letters are on the buttons.
///
/// It shows what will be sent, not what was copied: the counts and the preview
/// follow the Tabs to Spaces toggle, and are measured on the bytes
/// `TerminalPaste.bytes(for:)` makes.
///
/// It remembers nothing. The next paste asks again, with the toggle off.
@MainActor
final class PasteAskSheet: NSView {
    /// Fired exactly once; the sheet is off screen first.
    private var onAnswer: ((PasteAnswer) -> Void)?
    /// A click on the scrim: the pane wants the keyboard back on this sheet.
    var onClick: (() -> Void)?

    private let text: String
    private let settings: TerminalPaste.ConfirmSettings
    private let previewFont: NSFont
    private let original: TerminalPaste.Shape

    private let panel = PastePanelView()
    private let summary = NSTextField(labelWithString: "")
    private let reasons = NSTextField(wrappingLabelWithString: "")
    /// What tidying did to the clipboard before the sheet was asked about it,
    /// or nil. The preview is of the tidied text, so the sheet has to say so.
    let tidied: String?
    private let tidiedLine = NSTextField(wrappingLabelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private var tabsButton: AskButton?
    private(set) var tabsToSpaces = false

    /// `terminalFont` is the font the terminals are set in, so the preview
    /// reads as the thing it is a preview of.
    init(
        text: String, settings: TerminalPaste.ConfirmSettings, terminalFont: NSFont?,
        tidied: String? = nil,
        onAnswer: @escaping (PasteAnswer) -> Void
    ) {
        self.text = text
        self.settings = settings
        self.previewFont = terminalFont ?? Theme.mono(11)
        self.original = TerminalPaste.shape(of: text)
        self.tidied = tidied
        self.onAnswer = onAnswer
        super.init(frame: .zero)
        wantsLayer = true
        layerBackgroundColor = NSColor.black.withAlphaComponent(0.55)
        build()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// The text as it stands now, with the toggle applied.
    private var current: String {
        tabsToSpaces ? TerminalPaste.tabsToSpaces(text, width: settings.tabWidth) : text
    }

    // MARK: - building

    private func build() {
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            panel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -12),
        ])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            column.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            column.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])

        let header = NSTextField(labelWithString: "")
        let title = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
        ])
        title.append(NSAttributedString(string: "PASTE_ASKS_FIRST", attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.dimText,
        ]))
        header.attributedStringValue = title
        column.addArrangedSubview(header)

        summary.font = Theme.mono(12, weight: .medium)
        summary.textColor = .labelColor
        column.addArrangedSubview(summary)

        reasons.font = Theme.mono(11)
        reasons.textColor = Theme.dimText
        column.addArrangedSubview(reasons)
        reasons.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        if let tidied {
            tidiedLine.stringValue = "tidied: \(tidied). ⌥⌘V pastes it as copied"
            tidiedLine.font = Theme.mono(11)
            tidiedLine.textColor = Theme.dimText
            column.addArrangedSubview(tidiedLine)
            tidiedLine.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        // The preview in a box of its own, so it reads as quoted rather than
        // as more of the sheet's own words.
        let box = PastePanelView(fill: Theme.laneBackground)
        box.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isSelectable = false
        preview.drawsBackground = false
        preview.lineBreakMode = .byClipping
        preview.cell?.wraps = true
        preview.cell?.truncatesLastVisibleLine = true
        box.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            preview.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            preview.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            preview.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        column.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        if original.tabs > 0 {
            let toggle = AskButton(label: "", isDefault: false)
            toggle.onClick = { [weak self] in self?.toggleTabs() }
            tabsButton = toggle
            row.addArrangedSubview(toggle)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        // Cancel carries the accent: it is where ↩ lands.
        let cancel = AskButton(label: "CANCEL  ↩", isDefault: true)
        cancel.onClick = { [weak self] in self?.answer(.cancelled) }
        row.addArrangedSubview(cancel)
        if original.isMultiline {
            let oneLine = AskButton(label: "ONE LINE  O", isDefault: false)
            oneLine.onClick = { [weak self] in self?.send(oneLine: true) }
            row.addArrangedSubview(oneLine)
        }
        let paste = AskButton(label: "PASTE  P", isDefault: false)
        paste.onClick = { [weak self] in self?.send(oneLine: false) }
        row.addArrangedSubview(paste)
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    /// Counts, reasons and preview, for the text as it stands.
    private func refresh() {
        let text = current
        let shape = TerminalPaste.shape(of: text)
        summary.stringValue = "\(shape.lines) line\(shape.lines == 1 ? "" : "s") · \(TerminalPaste.size(shape.bytes))"
        let why = shape.reasons(settings)
        reasons.stringValue = why.joined(separator: "\n")
        reasons.isHidden = why.isEmpty

        let (lines, more) = TerminalPaste.preview(text)
        let shown = NSMutableAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: previewFont, .foregroundColor: NSColor.labelColor,
        ])
        if more > 0 {
            shown.append(NSAttributedString(
                string: "\n… and \(more) more line\(more == 1 ? "" : "s")",
                attributes: [.font: previewFont, .foregroundColor: Theme.dimText]))
        }
        // One row per line of the paste: a long line is clipped, not wrapped,
        // so eight lines are eight rows and the buttons stay on screen.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
        preview.attributedStringValue = shown
        preview.maximumNumberOfLines = lines.count + (more > 0 ? 1 : 0)

        tabsButton?.label = "TABS TO \(settings.tabWidth) SPACES: \(tabsToSpaces ? "ON" : "OFF")  T"
    }

    // MARK: - answering

    func toggleTabs() {
        guard tabsButton != nil else { return }
        tabsToSpaces.toggle()
        Motion.fade(panel.layer)
        refresh()
    }

    func send(oneLine: Bool) {
        // One Line is only offered for several lines; the key follows the button.
        if oneLine, !original.isMultiline { return }
        answer(.paste(oneLine: oneLine, tabsToSpaces: tabsToSpaces))
    }

    func answer(_ answer: PasteAnswer) {
        guard let handler = onAnswer else { return }
        onAnswer = nil
        Motion.fade(superview?.layer)
        removeFromSuperview()
        handler(answer)
    }

    /// For the pane going away under an unanswered sheet. Nothing is sent.
    func dismissWithoutAnswering() {
        onAnswer = nil
        removeFromSuperview()
    }

    // MARK: - keyboard

    override var acceptsFirstResponder: Bool { true }

    func takeFocus() { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch event.keyCode {
        case 53, 36, 76: answer(.cancelled)               // esc, return, enter
        default:
            guard plain, let key = event.charactersIgnoringModifiers?.lowercased() else { return }
            switch key {
            case "p": send(oneLine: false)
            case "o": send(oneLine: true)
            case "t": toggleTabs()
            default: break                                // swallowed: nothing types through a question
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { answer(.cancelled) }

    /// The scrim swallows clicks: a click beside a question does not answer
    /// it, and the terminal underneath must not get it either.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}

/// Square, filled, outlined on all four sides. `WebAskSheet` keeps its own
/// private; the two are the same four rectangles. `ClipboardAskSheet` shares
/// this one.
@MainActor
final class PastePanelView: NSView {
    private let fill: NSColor

    init(fill: NSColor = Theme.stripBackground) {
        self.fill = fill
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        bounds.fill()
        Theme.laneBorder.setFill()
        for rect in [
            NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth),
            NSRect(x: 0, y: bounds.height - Theme.borderWidth, width: bounds.width, height: Theme.borderWidth),
            NSRect(x: 0, y: 0, width: Theme.borderWidth, height: bounds.height),
            NSRect(x: bounds.width - Theme.borderWidth, y: 0, width: Theme.borderWidth, height: bounds.height),
        ] { rect.fill() }
    }
}
