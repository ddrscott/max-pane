import AppKit

/// A program reaching for the clipboard, held in front of the person first:
/// an OSC 52 read under `osc52_read = "ask"`, or a write under
/// `osc52_write = "ask"` (ADR-0028).
///
/// `PasteAskSheet`'s shape, and one deliberate difference. That sheet answers
/// something the person just did, so its keys are bare letters. This one goes
/// up because a *program* asked, quite possibly while the person is typing
/// into the very pane it covers, and the next letter they type must not be
/// the one that hands their clipboard to another machine. So **no bare key
/// allows**: ↩ and Esc deny, every letter is swallowed, and allowing takes
/// ⌥A or a click.
///
/// It shows what would be handed over, truncated, with control characters
/// made visible. It remembers nothing: the next request asks again.
@MainActor
final class ClipboardAskSheet: NSView {
    /// Fired exactly once; the sheet is off screen first.
    private var onAnswer: ((Bool) -> Void)?
    /// A click on the scrim: the pane wants the keyboard on this sheet.
    var onClick: (() -> Void)?

    let question: ProgramClipboard.Question
    let summaryText: String
    let detailText: String
    let previewText: String

    private let panel = PastePanelView()

    init(
        question: ProgramClipboard.Question, asker: ProgramClipboard.Asker, text: String,
        terminalFont: NSFont?, onAnswer: @escaping (Bool) -> Void
    ) {
        self.question = question
        self.onAnswer = onAnswer
        let wording = ProgramClipboard.wording(question, asker, text: text)
        summaryText = wording.summary
        detailText = wording.detail
        let (lines, more) = TerminalPaste.preview(text)
        previewText = lines.joined(separator: "\n")
        super.init(frame: .zero)
        wantsLayer = true
        layerBackgroundColor = NSColor.black.withAlphaComponent(0.55)
        build(lines: lines, more: more, font: terminalFont ?? Theme.mono(11))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private func build(lines: [String], more: Int, font: NSFont) {
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
        title.append(NSAttributedString(
            string: question == .read ? "CLIPBOARD_READ_ASKED" : "CLIPBOARD_WRITE_ASKED",
            attributes: [.font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.dimText]))
        header.attributedStringValue = title
        column.addArrangedSubview(header)

        let summary = NSTextField(wrappingLabelWithString: summaryText)
        summary.font = Theme.mono(12, weight: .medium)
        summary.textColor = .labelColor
        column.addArrangedSubview(summary)
        summary.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let detail = NSTextField(wrappingLabelWithString: detailText)
        detail.font = Theme.mono(11)
        detail.textColor = Theme.dimText
        column.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        let box = PastePanelView(fill: Theme.laneBackground)
        box.translatesAutoresizingMaskIntoConstraints = false
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isSelectable = false
        preview.drawsBackground = false
        preview.lineBreakMode = .byClipping
        preview.cell?.wraps = true
        preview.cell?.truncatesLastVisibleLine = true
        let shown = NSMutableAttributedString(string: previewText, attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        if more > 0 {
            shown.append(NSAttributedString(
                string: "\n… and \(more) more line\(more == 1 ? "" : "s")",
                attributes: [.font: font, .foregroundColor: Theme.dimText]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
        preview.attributedStringValue = shown
        preview.maximumNumberOfLines = lines.count + (more > 0 ? 1 : 0)
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
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)
        // Deny carries the accent: it is where ↩ lands.
        let deny = AskButton(label: "DENY  ↩", isDefault: true)
        deny.onClick = { [weak self] in self?.answer(false) }
        row.addArrangedSubview(deny)
        let allow = AskButton(label: "ALLOW  ⌥A", isDefault: false)
        allow.onClick = { [weak self] in self?.answer(true) }
        row.addArrangedSubview(allow)
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    // MARK: - answering

    func answer(_ allowed: Bool) {
        guard let handler = onAnswer else { return }
        onAnswer = nil
        Motion.fade(superview?.layer)
        removeFromSuperview()
        handler(allowed)
    }

    /// For the pane going away under an unanswered sheet: the pane denies.
    func dismissWithoutAnswering() {
        onAnswer = nil
        removeFromSuperview()
    }

    // MARK: - keyboard

    override var acceptsFirstResponder: Bool { true }

    func takeFocus() { window?.makeFirstResponder(self) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: answer(false)                    // esc, return, enter
        default:
            // ⌥A and nothing else. A bare `a` is somebody still typing.
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags == .option, event.charactersIgnoringModifiers?.lowercased() == "a" { answer(true) }
        }
    }

    override func cancelOperation(_ sender: Any?) { answer(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
}
