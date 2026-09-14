import AppKit

/// A question, a notice, or a one-field prompt, in the same frame as every other
/// dialog.
///
/// These were `NSAlert`s: macOS's rounded card, run modally, centred on the
/// screen rather than on the window they were about, and the one kind of dialog
/// here that neither animated nor looked like the app. The owner asked for every
/// dialog to be the same centred, auto-dismissing popup, so a confirmation is
/// now a `Popup`: Esc or a click away is Cancel, and ↩ presses whichever choice
/// is marked default — which, for anything destructive, is still Cancel. That
/// rule predates this and every caller keeps it.
///
/// Asynchronous, where an alert was synchronous. A caller that used to read
/// `runModal()`'s answer on the next line now continues in the closure.
@MainActor
final class ConfirmPopup: Popup {
    struct Choice {
        let title: String
        /// What ↩ presses. One per popup.
        let isDefault: Bool
    }

    static let width: CGFloat = 460

    private let choices: [Choice]
    let field: NSTextField?
    private let completion: (_ choice: Int?, _ text: String) -> Void
    private var returnMonitor: Any?
    private var answered = false

    init(
        title: String, detail: String?, choices: [Choice], fieldText: String? = nil,
        completion: @escaping (_ choice: Int?, _ text: String) -> Void
    ) {
        self.choices = choices
        self.completion = completion
        if let fieldText {
            let input = NSTextField()
            // Styled first: the style swaps in its own cell, which would drop a
            // value set before it.
            Theme.squareField(input, font: Theme.mono(12), height: 26)
            input.stringValue = fieldText
            self.field = input
        } else {
            self.field = nil
        }
        super.init(size: NSSize(width: Self.width, height: 160), dismissal: .clickAway)
        let content = build(title: title, detail: detail)
        window?.contentView = content
        content.layoutSubtreeIfNeeded()
        window?.setContentSize(NSSize(width: Self.width, height: ceil(content.fittingSize.height)))
    }

    /// Yes or no. `returnConfirms: false` puts ↩ on Cancel, which is what every
    /// destructive confirmation in the app does.
    static func confirm(
        over parent: NSWindow?, title: String, detail: String?, action: String,
        cancel: String = "Cancel", returnConfirms: Bool, then: @escaping (Bool) -> Void
    ) {
        ConfirmPopup(
            title: title, detail: detail,
            choices: [Choice(title: cancel, isDefault: !returnConfirms), Choice(title: action, isDefault: returnConfirms)]
        ) { choice, _ in then(choice == 1) }
            .present(over: parent)
    }

    /// Something to read and dismiss.
    static func inform(over parent: NSWindow?, title: String, detail: String?, ok: String = "OK") {
        ConfirmPopup(title: title, detail: detail, choices: [Choice(title: ok, isDefault: true)]) { _, _ in }
            .present(over: parent)
    }

    /// One line of text. `then` gets the text, or nil if the prompt was cancelled.
    static func ask(
        over parent: NSWindow?, title: String, detail: String?, text: String, action: String,
        then: @escaping (String?) -> Void
    ) {
        ConfirmPopup(
            title: title, detail: detail,
            choices: [Choice(title: "Cancel", isDefault: false), Choice(title: action, isDefault: true)],
            fieldText: text
        ) { choice, value in then(choice == 1 ? value : nil) }
            .present(over: parent)
    }

    /// Answer once: a button, ↩, Esc or a click away, whichever comes first.
    func choose(_ index: Int?) {
        guard !answered else { return }
        answered = true
        if let returnMonitor { NSEvent.removeMonitor(returnMonitor) }
        returnMonitor = nil
        let text = field?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        closePopup()
        completion(index, text)
    }

    override func popupCancelled() { choose(nil) }

    override func popupDidPresent() {
        if let field { window?.makeFirstResponder(field) }
        returnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isOpen, self.window?.isKeyWindow == true,
                  event.keyCode == 36 || event.keyCode == 76 else { return event }
            self.choose(self.choices.firstIndex(where: \.isDefault))
            return nil
        }
    }

    private func build(title: String, detail: String?) -> NSView {
        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0

        let inner = Self.width - 40
        let heading = NSTextField(wrappingLabelWithString: title)
        heading.font = Theme.mono(13, weight: .bold)
        heading.textColor = .labelColor
        heading.preferredMaxLayoutWidth = inner
        var rows: [NSView] = [heading]
        if let detail, !detail.isEmpty {
            let body = NSTextField(wrappingLabelWithString: detail)
            body.font = Theme.mono(12)
            body.textColor = Theme.dimText
            body.preferredMaxLayoutWidth = inner
            rows.append(body)
        }
        if let field { rows.append(field) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = choices.enumerated().map { index, choice -> AskButton in
            let button = AskButton(label: choice.title, isDefault: choice.isDefault)
            button.onClick = { [weak self] in self?.choose(index) }
            return button
        }
        let buttonRow = NSStackView(views: [spacer] + buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        rows.append(buttonRow)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(18, after: rows[rows.count - 2])
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        var constraints = [
            content.widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttonRow.widthAnchor.constraint(equalToConstant: inner),
        ]
        if let field { constraints.append(field.widthAnchor.constraint(equalToConstant: inner)) }
        NSLayoutConstraint.activate(constraints)
        return content
    }
}
