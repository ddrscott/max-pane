import AppKit

/// What the person said to an Advanced Paste.
enum AdvancedPasteAnswer: Equatable {
    /// Esc, ↩, CANCEL, and the pane going away. Nothing is sent.
    case cancelled
    /// Send `text`: what the sheet's preview was of, to the byte.
    case paste(text: String, slowly: Bool)
}

/// The toggles and the regular expression of the last Advanced Paste, **for
/// as long as the app runs and no longer**, and never the content. Nothing
/// here is written anywhere. A pane is handed `shared`; a test hands its own.
@MainActor
final class AdvancedPasteMemory {
    static let shared = AdvancedPasteMemory()
    var last = TerminalPaste.Advanced()
}

/// Edit › Paste Special › Advanced Paste… (⌥⇧⌘V): the clipboard, editable,
/// the transforms that exist as a column of toggles, a regular expression,
/// and the exact bytes that would go (ADR-0032).
///
/// `PasteAskSheet`'s shape and its keyboard, for its reasons: a scrim over
/// the pane, a square panel outlined on all four sides, the `//` header, the
/// accent on CANCEL because that is where ↩ lands. **↩ and Esc cancel.**
/// Sending takes a letter: `P` pastes, `S` pastes slowly. `1`–`8` are the
/// toggles, `E` puts the keyboard in the content and `R` in the pattern.
///
/// Two text boxes make one difference: while the keyboard is in one, letters
/// are text. **Esc there comes back to the keys** rather than cancelling (a
/// second Esc cancels), ↩ in the content is a line and in the pattern comes
/// back too, and ⌘↩ pastes from anywhere.
///
/// **The column is the order.** Top to bottom is the order the steps are
/// applied in, whichever was switched on first, and the regular expression
/// sits in its place in it. The sheet computes nothing: what it shows and
/// what it sends are both `TerminalPaste.compose` of the content and the
/// toggles, so the preview cannot disagree with the wire.
@MainActor
final class AdvancedPasteSheet: NSView, NSTextViewDelegate, NSTextFieldDelegate {
    /// Fired exactly once; the sheet is off screen first.
    private var onAnswer: ((AdvancedPasteAnswer) -> Void)?
    /// A click on the scrim: the pane wants the keyboard back on this sheet.
    var onClick: (() -> Void)?

    private let memory: AdvancedPasteMemory
    private let font: NSFont
    private(set) var advanced: TerminalPaste.Advanced

    private let panel = PastePanelView()
    /// The three parts that move between the two arrangements (`arrange`).
    private let body = NSStackView()
    private let right = NSStackView()
    private let editorScroll = NSScrollView()
    private let steps = NSStackView()
    private let output = NSStackView()
    private var arrangement: [NSLayoutConstraint] = []
    private(set) var isWide: Bool?
    private var previewLimit = 8
    let editor = PlainTextView()
    let patternField = PlainTextField()
    let replacementField = PlainTextField()
    private var rows: [TerminalPaste.Advanced.Step: AdvancedToggleRow] = [:]
    private let regexNote = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let preview = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "")
    private var pasteButton: AskButton?
    private var slowButton: AskButton?

    /// What the preview showed last: its lines, as drawn.
    private(set) var previewLines: [String] = []
    private(set) var summaryText = ""

    /// `terminalFont` is the font the terminals are set in: the content and
    /// the preview read as the thing they are.
    init(
        text: String, tabWidth: Int, terminalFont: NSFont?, memory: AdvancedPasteMemory,
        onAnswer: @escaping (AdvancedPasteAnswer) -> Void
    ) {
        self.memory = memory
        self.font = terminalFont ?? Theme.mono(11)
        var advanced = memory.last
        advanced.tabWidth = tabWidth
        self.advanced = advanced
        self.onAnswer = onAnswer
        super.init(frame: .zero)
        wantsLayer = true
        layerBackgroundColor = NSColor.black.withAlphaComponent(0.55)
        build(text: text)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// The content as it stands, edits and all.
    var content: String { editor.string }

    /// What would go out now. The one thing shown and the one thing sent.
    var composed: TerminalPaste.Composed { TerminalPaste.compose(content, advanced) }

    // MARK: - building

    private func build(text: String) {
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
        func add(_ view: NSView) {
            column.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        add(Self.header("ADVANCED_PASTE"))

        // The content: plain text in the terminal's font, and nothing macOS
        // would like to improve about it (`PlainText.harden`).
        editor.string = text
        editor.font = font
        editor.textColor = .labelColor
        editor.delegate = self
        editor.onFocusChange = { [weak self] in self?.refreshHint() }
        editor.onLeave = { [weak self] in self?.takeFocus() }
        let scroll = editorScroll
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.laneBackground
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layerBorderColor = Theme.laneBorder
        scroll.layer?.borderWidth = Theme.borderWidth
        scroll.translatesAutoresizingMaskIntoConstraints = false
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 4, height: 5)
        // The content is what gives when the pane is short: never the steps,
        // and the preview only after it.
        let tall = scroll.heightAnchor.constraint(equalToConstant: 92)
        tall.priority = .defaultLow
        NSLayoutConstraint.activate([tall, scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 36)])

        // The steps, in the order they are applied, the pattern in its place.
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 1
        func addStep(_ view: NSView) {
            steps.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }
        func addToggles(_ some: [TerminalPaste.Advanced.Step]) {
            for step in some {
                let row = AdvancedToggleRow(key: "\(step.rawValue + 1)", label: step.label(tabWidth: advanced.tabWidth))
                row.onClick = { [weak self] in self?.toggle(step) }
                rows[step] = row
                addStep(row)
            }
        }
        addToggles(TerminalPaste.Advanced.Step.beforeRegex)
        addStep(regexRow())
        regexNote.font = Theme.mono(10)
        regexNote.lineBreakMode = .byTruncatingTail
        addStep(regexNote)
        addToggles(TerminalPaste.Advanced.Step.afterRegex)

        summary.font = Theme.mono(12, weight: .medium)
        summary.textColor = .labelColor
        summary.lineBreakMode = .byTruncatingTail
        output.orientation = .vertical
        output.alignment = .leading
        output.spacing = 8
        output.addArrangedSubview(summary)

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
        output.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: output.widthAnchor).isActive = true

        body.spacing = 8
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 8
        add(body)
        arrange(wide: false)

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        hint.font = Theme.mono(10)
        hint.textColor = Theme.dimText
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        hint.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(hint)
        // Cancel carries the accent: it is where ↩ lands.
        let cancel = AskButton(label: "CANCEL  ↩", isDefault: true)
        cancel.onClick = { [weak self] in self?.answer(.cancelled) }
        row.addArrangedSubview(cancel)
        let slow = AskButton(label: "PASTE SLOWLY  S", isDefault: false)
        slow.onClick = { [weak self] in self?.send(slowly: true) }
        row.addArrangedSubview(slow)
        slowButton = slow
        let paste = AskButton(label: "PASTE  P", isDefault: false)
        paste.onClick = { [weak self] in self?.send(slowly: false) }
        row.addArrangedSubview(paste)
        pasteButton = paste
        add(row)
    }

    private static func header(_ name: String) -> NSTextField {
        let header = NSTextField(labelWithString: "")
        let title = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
        ])
        title.append(NSAttributedString(string: name, attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.dimText,
        ]))
        header.attributedStringValue = title
        return header
    }

    /// `R  s/ pattern / replacement /`, as sed would have it said.
    private func regexRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .centerY
        func label(_ text: String, width: CGFloat? = nil) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.font = Theme.mono(11)
            field.textColor = Theme.dimText
            field.setContentHuggingPriority(.required, for: .horizontal)
            if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
            return field
        }
        row.addArrangedSubview(label("R", width: 12))
        row.addArrangedSubview(label("s/"))
        for (field, value, placeholder) in [
            (patternField, advanced.pattern, "pattern"), (replacementField, advanced.replacement, "replacement, $1"),
        ] {
            field.stringValue = value
            field.placeholderString = placeholder
            field.font = font
            field.isBezeled = false
            field.isBordered = false
            field.drawsBackground = true
            field.backgroundColor = Theme.laneBackground
            field.focusRingType = .none
            field.wantsLayer = true
            field.layerBorderColor = Theme.laneBorder
            field.layer?.borderWidth = Theme.borderWidth
            field.layer?.cornerRadius = 0
            field.delegate = self
            field.usesSingleLineMode = true
            field.cell?.isScrollable = true
            field.onFocusChange = { [weak self] in self?.refreshHint() }
            field.heightAnchor.constraint(equalToConstant: 20).isActive = true
            field.setContentHuggingPriority(.init(1), for: .horizontal)
            row.addArrangedSubview(field)
            row.addArrangedSubview(label("/"))
        }
        patternField.widthAnchor.constraint(equalTo: replacementField.widthAnchor).isActive = true
        patternField.nextKeyView = replacementField
        replacementField.nextKeyView = patternField
        return row
    }

    /// Below this the steps go above the preview instead of beside it.
    static let wideFrom: CGFloat = 560

    /// The two arrangements. **Narrow**, a lane at `s`: the content, the
    /// steps, the preview, top to bottom. **Wide**: the steps down the left
    /// and the content over the preview on the right, which is what fits the
    /// half-height pane of a lane split down. The same views either way.
    private func arrange(wide: Bool) {
        guard wide != isWide else { return }
        isWide = wide
        // Taking a view out of the window takes the keyboard out of it. A
        // lane dragged across the threshold mid-edit keeps its caret.
        var typingIn: NSView?
        if isTyping, let responder = window?.firstResponder as? NSTextView {
            typingIn = responder.isFieldEditor ? responder.delegate as? NSView : responder
        }
        defer { if let typingIn { window?.makeFirstResponder(typingIn) } }
        NSLayoutConstraint.deactivate(arrangement)
        for view in [editorScroll, steps, output, right] as [NSView] { view.removeFromSuperview() }
        if wide {
            body.orientation = .horizontal
            body.alignment = .top
            body.spacing = 14
            right.addArrangedSubview(editorScroll)
            right.addArrangedSubview(output)
            body.addArrangedSubview(steps)
            body.addArrangedSubview(right)
            arrangement = [
                steps.widthAnchor.constraint(equalTo: body.widthAnchor, multiplier: 0.45),
                editorScroll.widthAnchor.constraint(equalTo: right.widthAnchor),
                output.widthAnchor.constraint(equalTo: right.widthAnchor),
            ]
        } else {
            body.orientation = .vertical
            body.alignment = .leading
            body.spacing = 8
            arrangement = [editorScroll, steps, output].map {
                body.addArrangedSubview($0)
                return $0.widthAnchor.constraint(equalTo: body.widthAnchor)
            }
        }
        NSLayoutConstraint.activate(arrangement)
    }

    /// How many lines of preview the pane has room for, two to eight: what
    /// is fixed (the header, the steps, the buttons, the least the content
    /// may be) taken from the height, in rows of the preview's font.
    override func layout() {
        let wide = bounds.width >= Self.wideFrom
        arrange(wide: wide)
        let fixed: CGFloat = wide ? 190 : 400
        let row = ceil(font.ascender - font.descender + font.leading) + 1
        let limit = min(max(Int((bounds.height - fixed) / row), 2), 8)
        if limit != previewLimit {
            previewLimit = limit
            refresh()
        }
        super.layout()
    }

    // MARK: - state

    /// Everything that follows from the content and the toggles.
    private func refresh() {
        let composed = composed
        for (step, row) in rows { row.isOn = advanced.steps.contains(step) }

        if let problem = composed.regexProblem {
            regexNote.stringValue = "   \(problem)"
            regexNote.textColor = Theme.blocked
        } else if let count = composed.replacements {
            regexNote.stringValue = "   \(count) replacement\(count == 1 ? "" : "s")" + (count == 0 ? ": no match" : "")
            regexNote.textColor = Theme.dimText
        } else {
            regexNote.stringValue = "   NSRegularExpression · ^ and $ match at each line"
            regexNote.textColor = Theme.dimText
        }

        let (lines, more, size) = TerminalPaste.advancedPreview(composed, limit: previewLimit)
        previewLines = lines
        summaryText = composed.refusal ?? size
        summary.stringValue = summaryText
        summary.textColor = composed.problem == nil ? .labelColor : Theme.blocked

        let shown = NSMutableAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: font, .foregroundColor: NSColor.labelColor,
        ])
        if more > 0 {
            shown.append(NSAttributedString(
                string: "\n… and \(more) more line\(more == 1 ? "" : "s")",
                attributes: [.font: font, .foregroundColor: Theme.dimText]))
        }
        if lines.isEmpty {
            shown.append(NSAttributedString(string: " ", attributes: [.font: font]))
        }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        shown.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: shown.length))
        preview.attributedStringValue = shown
        preview.maximumNumberOfLines = max(lines.count + (more > 0 ? 1 : 0), 1)
        refreshHint()
    }

    private var isTyping: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder !== self && responder.isDescendant(of: self)
    }

    /// Whether the keyboard is on this sheet or in one of its text boxes.
    var holdsKeyboard: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }

    private func refreshHint() {
        hint.stringValue = isTyping ? "Esc: back to the keys · ⌘↩ pastes" : "1–8 toggle · E edit · R regex"
    }

    // MARK: - answering

    func toggle(_ step: TerminalPaste.Advanced.Step) {
        if advanced.steps.contains(step) { advanced.steps.remove(step) } else { advanced.steps.insert(step) }
        Motion.fade(panel.layer)
        refresh()
    }

    /// For a test, and for nothing else: what typing in the row would do.
    func setRegex(pattern: String, replacement: String) {
        patternField.stringValue = pattern
        replacementField.stringValue = replacement
        regexChanged()
    }

    private func regexChanged() {
        advanced.pattern = patternField.stringValue
        advanced.replacement = replacementField.stringValue
        refresh()
    }

    /// Paste what the preview shows. Nothing to send, or a step that could
    /// not be done, sends nothing and leaves the sheet up saying why.
    func send(slowly: Bool) {
        let composed = composed
        guard composed.problem == nil, !TerminalPaste.bytes(for: composed.text).isEmpty else {
            Motion.fade(panel.layer)
            return
        }
        answer(.paste(text: composed.text, slowly: slowly))
    }

    func answer(_ answer: AdvancedPasteAnswer) {
        guard let handler = onAnswer else { return }
        onAnswer = nil
        // The toggles and the pattern, until the app quits. Not the content.
        memory.last = advanced
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

    func takeFocus() {
        window?.makeFirstResponder(self)
        refreshHint()
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
        switch event.keyCode {
        case 53, 36, 76: answer(.cancelled)               // esc, return, enter
        default:
            guard plain, let key = event.charactersIgnoringModifiers?.lowercased() else { return }
            switch key {
            case "p": send(slowly: false)
            case "s": send(slowly: true)
            case "e": window?.makeFirstResponder(editor)
            case "r": window?.makeFirstResponder(patternField)
            default:
                // Swallowed unless it is a toggle's digit: nothing types
                // through a question.
                if let digit = Int(key), let step = TerminalPaste.Advanced.Step(rawValue: digit - 1) { toggle(step) }
            }
        }
    }

    override func cancelOperation(_ sender: Any?) { answer(.cancelled) }

    /// ⌘↩ pastes, from the keys or from a text box. Here and not in
    /// `Commands.swift`: it is this sheet's key while it is up and nobody's
    /// otherwise, and this walk runs before the menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if holdsKeyboard, modifiers == [.command], event.keyCode == 36 || event.keyCode == 76 {
            send(slowly: false)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func textDidChange(_ notification: Notification) { refresh() }

    func controlTextDidChange(_ obj: Notification) { regexChanged() }

    /// In the pattern or the replacement: ↩ and Esc come back to the keys.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:)):
            takeFocus()
            return true
        default:
            return false
        }
    }

    /// The scrim swallows clicks: a click beside a question does not answer
    /// it, and the terminal underneath must not get it either.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
        onClick?()
    }
}

// ⌘V in this sheet's text boxes needs nothing here. It used to: the pane's
// container is up the responder chain from the boxes, and it took the Edit
// menu's routed paste, so this sheet answered first as a one-off. The
// container now answers only while the terminal itself has the keyboard
// (ADR-0045), so the routed paste finds no taker from a box and the menu's
// plain `paste:` reaches it — the rule every sheet and picker gets.

/// One step of an Advanced Paste: its digit, a square that is filled when the
/// step is on, its name. Grey at rest, the accent when on.
@MainActor
final class AdvancedToggleRow: NSView {
    var onClick: (() -> Void)?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }
    private let key: String
    private let label: String
    private var isHovered = false { didSet { needsDisplay = true } }

    init(key: String, label: String) {
        self.key = key
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.laneBorder.withAlphaComponent(0.6).setFill()
            bounds.fill()
        }
        let font = Theme.mono(11, weight: isOn ? .medium : .regular)
        func draw(_ text: String, at x: CGFloat, _ colour: NSColor) {
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: colour])
            let size = string.size()
            string.draw(at: NSPoint(x: x, y: ((bounds.height - size.height) / 2).rounded()))
        }
        draw(key, at: 0, Theme.dimText)
        let box = NSRect(x: 18, y: ((bounds.height - 9) / 2).rounded(), width: 9, height: 9)
        if isOn {
            Theme.accent.setFill()
            box.fill()
        } else {
            Theme.laneBorder.setStroke()
            let outline = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.stroke()
        }
        draw(label, at: 36, isOn ? .labelColor : Theme.dimText)
    }
}

/// Text that stays what was typed. macOS would turn `"` into `“`, `--` into
/// `—` and `...` into `…`, correct the spelling of a command and make a link
/// of a URL: each of them the very thing `TerminalPaste.tidy` exists to undo,
/// so none of them may happen in a box whose text goes to a shell.
@MainActor
enum PlainText {
    static func harden(_ view: NSTextView) {
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.usesFontPanel = false
        view.usesRuler = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.smartInsertDeleteEnabled = false
        view.enabledTextCheckingTypes = 0
    }

    /// Every one of them off. What a test asks.
    static func isHardened(_ view: NSTextView) -> Bool {
        !view.isRichText && !view.isAutomaticQuoteSubstitutionEnabled && !view.isAutomaticDashSubstitutionEnabled
            && !view.isAutomaticTextReplacementEnabled && !view.isAutomaticSpellingCorrectionEnabled
            && !view.isAutomaticTextCompletionEnabled && !view.isAutomaticLinkDetectionEnabled
            && !view.isAutomaticDataDetectionEnabled && !view.isContinuousSpellCheckingEnabled
            && !view.isGrammarCheckingEnabled && !view.smartInsertDeleteEnabled && view.enabledTextCheckingTypes == 0
    }
}

/// The content of an Advanced Paste. Esc leaves it for the sheet's keys.
@MainActor
final class PlainTextView: NSTextView {
    var onFocusChange: (() -> Void)?
    var onLeave: (() -> Void)?

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        PlainText.harden(self)
        drawsBackground = false
        insertionPointColor = Theme.accent
    }

    override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return super.becomeFirstResponder()
    }

    override func cancelOperation(_ sender: Any?) { onLeave?() }

    /// Spelling and substitutions can be switched back on from the context
    /// menu, per view. Whatever was switched, a paste into the box is plain.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// A one-line field whose field editor is its own and is hardened
/// (`PlainText`): the window's shared one is everybody's, and would keep
/// whatever was set on it for the next field that borrowed it.
@MainActor
final class PlainTextField: NSTextField {
    var onFocusChange: (() -> Void)?

    override class var cellClass: AnyClass? {
        get { PlainFieldCell.self }
        set {}
    }

    override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.onFocusChange?() } }
        return super.becomeFirstResponder()
    }
}

final class PlainFieldCell: NSTextFieldCell {
    private var plainEditor: NSTextView?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        MainActor.assumeIsolated {
            if let plainEditor { return plainEditor }
            let editor = NSTextView(frame: .zero)
            editor.isFieldEditor = true
            PlainText.harden(editor)
            plainEditor = editor
            return editor
        }
    }
}
