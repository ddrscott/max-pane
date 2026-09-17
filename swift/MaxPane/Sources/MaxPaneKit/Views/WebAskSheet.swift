import AppKit

/// What a page is asking for, in the shape the sheet has to draw.
enum AskPrompt: Equatable {
    case alert(message: String)
    case confirm(message: String)
    case prompt(message: String, defaultText: String)
    /// `getUserMedia`, `Notification.requestPermission()` and
    /// `navigator.geolocation`. `what` is already phrased — "THE CAMERA", "THE
    /// MICROPHONE", "THE CAMERA AND MICROPHONE", "TO SEND NOTIFICATIONS", "TO
    /// KNOW WHERE YOU ARE" — because the two capture flags
    /// are stored as two rows and the *sentence* is one, and a permission is a
    /// permission: BLOCK, ALLOW, and a box to remember either.
    case capture(what: String)
    /// HTTP basic/digest. `realm` is the server's own label for the thing being
    /// protected, and is shown as the server's words rather than as ours.
    case httpAuth(realm: String, isProxy: Bool)
    /// The server asked for a client certificate; these are the identities the
    /// Keychain can offer.
    case clientCertificate(names: [String])
    /// **Ours, not the page's.** ⇧⌘L: a user name and a password to put in the
    /// Keychain for the site in the address bar.
    ///
    /// It is drawn by this sheet because it belongs in the pane — modal to
    /// nothing, over the page it is about, with the origin line above it — and
    /// those are the same reasons a page's questions are drawn here. The origin
    /// line matters more for this one than for any of the others: it is the
    /// only statement of *which site this password is about to be filed under*,
    /// and it comes from `WKWebView.url` rather than from anything the page
    /// says.
    case savePassword
}

/// What the person said.
enum AskOutcome: Equatable {
    /// Esc, ✕, CANCEL, and every abandonment. The answer that is never a lie:
    /// `confirm()` gets false, `prompt()` gets nil, an auth challenge is
    /// cancelled, capture is denied.
    case cancelled
    /// alert's one button, and confirm's true.
    case confirmed
    case text(String)
    /// A user name and a password, from the sign-in sheet or the save sheet.
    ///
    /// `save` is the checkbox, and it is the whole of the difference the
    /// Keychain decision made to HTTP auth: unticked, the credential answers
    /// this challenge and lives in memory until the app quits, exactly as it
    /// did before there was anywhere to put it. Ticked, it is written to the
    /// Keychain by us — never by handing CFNetwork `.permanent`, which would be
    /// a second copy under attributes we do not control. It is always false for
    /// the save sheet, whose whole purpose is the write.
    case credential(user: String, password: String, save: Bool)
    case certificate(index: Int)
    /// `remember` is the checkbox, and it is honoured for **both** answers — a
    /// remembered *no* is the more valuable half, because a site that asks on
    /// every load is the reason people click Allow to make it stop.
    case capture(allowed: Bool, remember: Bool)
}

/// One question, drawn inside the pane that is asking it.
///
/// ## The shape, and why it is this one
///
/// A scrim over the page and a square panel at the top of it. Not a card: the
/// house rule is square corners and a full-perimeter outline, and a dialog is
/// exactly the place a rounded bubble with a coloured left rail would look most
/// like something a template generated (`Theme`).
///
/// It covers the page and stops at the chrome bar, so **the address stays
/// readable underneath the question**. That is not a layout convenience — the
/// sheet's own origin line and the address bar 26 pt below it are two
/// independent statements of who is asking, and a page that could cover the
/// second one could make the first one mean nothing.
///
/// The origin leads, in chrome type, outside the message and above it. A page
/// chooses every character of `alert()` and none of the origin; putting them in
/// the same run, or putting the origin after the message, is how a dialog
/// becomes a place to type a password into.
///
/// The accent appears exactly twice: the `//` of the section header, and the
/// outline on the default button — which is the accent's existing meaning
/// everywhere else in the app, *the keyboard is here*.
@MainActor
final class WebAskSheet: NSView {
    /// Fired exactly once. The sheet removes itself first, so a double-click on
    /// a button cannot produce two outcomes.
    private var onAnswer: ((AskOutcome) -> Void)?

    private let prompt: AskPrompt
    private let panel = AskPanelView()
    private let textField = NSTextField()
    private let userField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let remember = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let certificates = NSPopUpButton()
    private var defaultButton: AskButton?

    init(prompt: AskPrompt, origin: String, onAnswer: @escaping (AskOutcome) -> Void) {
        self.prompt = prompt
        self.onAnswer = onAnswer
        super.init(frame: .zero)
        wantsLayer = true
        // Dark enough that the page is visibly not the thing to interact with,
        // light enough that you can still see *which* page is asking — a solid
        // cover would make one asking lane look like any other.
        layerBackgroundColor = NSColor.black.withAlphaComponent(0.55)
        build(origin: origin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - building

    private func build(origin: String) {
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // Pinned to the top rather than centred: a lane is 656 pt of
            // portrait and a centred panel in a stack of two panes lands on the
            // seam. The top is where a sheet comes from in every other Mac app.
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

        column.addArrangedSubview(headerLabel())
        column.addArrangedSubview(originLabel(origin))

        let message = wrappingLabel(messageText)
        column.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        for field in fields() {
            column.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        if let label = rememberLabel {
            remember.title = " \(label)"
            remember.font = Theme.mono(10)
            remember.contentTintColor = Theme.dimText
            column.addArrangedSubview(remember)
        }

        let row = buttonRow()
        column.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    /// `// ASKS` — the house section header, with the slashes in the accent.
    private func headerLabel() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        let text = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.accent,
        ])
        text.append(NSAttributedString(string: headerText, attributes: [
            .font: Theme.mono(10, weight: .bold), .foregroundColor: Theme.dimText,
        ]))
        field.attributedStringValue = text
        return field
    }

    private var headerText: String {
        switch prompt {
        case .alert: return "SAYS"
        case .confirm, .prompt: return "ASKS"
        case .capture(let what): return "WANTS \(what)"
        case .httpAuth(_, let isProxy): return isProxy ? "PROXY WANTS A SIGN-IN" : "WANTS A SIGN-IN"
        case .clientCertificate: return "WANTS A CERTIFICATE"
        // No "wants": nothing is asking. This one is the user's own act, and
        // the header says so rather than borrowing the page's voice.
        case .savePassword: return "SAVE_PASSWORD"
        }
    }

    /// Who is asking, in the address bar's own conventions so the two cannot
    /// contradict each other. Truncated in the middle, never at the end: the
    /// registrable domain is the part an attacker cannot choose and the part a
    /// tail truncation would eat first.
    private func originLabel(_ origin: String) -> NSTextField {
        let field = NSTextField(labelWithString: origin)
        field.font = Theme.mono(12, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = origin
        return field
    }

    private var messageText: String {
        switch prompt {
        case .alert(let message), .confirm(let message):
            return message
        case .prompt(let message, _):
            return message
        case .capture(let what):
            // "THE CAMERA" is a thing to use; "TO SEND NOTIFICATIONS" and "TO
            // KNOW WHERE YOU ARE" are already the rest of the sentence.
            return what.hasPrefix("TO ")
                ? "This page is asking \(what.lowercased())."
                : "This page is asking to use \(what.lowercased())."
        case .httpAuth(let realm, _):
            return realm.isEmpty ? "A username and password are required." : realm
        case .clientCertificate:
            return "This server asks the browser to identify itself with a certificate."
        case .savePassword:
            return "Saved in the macOS Keychain, for this site only. ⌥⌘L fills it. "
                + "Max Pane never watches what you type into a page, so a password gets "
                + "here only this way or by importing one."
        }
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = Theme.mono(11)
        field.textColor = .labelColor
        field.isSelectable = true
        field.isEditable = false
        field.drawsBackground = false
        // A page can put a thousand lines in `alert()`. Eight is as much as a
        // portrait lane can show without the buttons leaving the screen, and a
        // sheet whose buttons you cannot reach is a hung pane.
        field.maximumNumberOfLines = 8
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func fields() -> [NSView] {
        switch prompt {
        case .prompt(_, let initial):
            style(textField)
            textField.stringValue = initial
            return [textField]
        case .httpAuth, .savePassword:
            style(userField)
            userField.placeholderString = "user"
            style(passwordField)
            passwordField.placeholderString = "password"
            return [userField, passwordField]
        case .clientCertificate(let names):
            certificates.removeAllItems()
            certificates.addItems(withTitles: names)
            certificates.font = Theme.mono(11)
            return names.isEmpty ? [] : [certificates]
        case .alert, .confirm, .capture:
            return []
        }
    }

    /// Square, hairlined, mono. `NSTextField`'s bezel is a rounded rectangle,
    /// which is the one shape this app does not draw.
    private func style(_ field: NSTextField) {
        field.font = Theme.mono(11)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = Theme.laneBackground
        field.focusRingType = .none
        field.wantsLayer = true
        field.layerBorderColor = Theme.laneBorder
        field.layer?.borderWidth = 1
        field.layer?.cornerRadius = 0
        field.delegate = self
        field.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private var rememberLabel: String? {
        // Only capture. An auth credential is never remembered here (see
        // `WebAuth`), and "remember this alert" is not a thing that means
        // anything.
        if case .capture = prompt { return "remember this answer for this site" }
        // The checkbox the HTTP-auth work said it did not have. It is
        // unticked by default and stays that way: "ask me every launch" is a
        // small cost paid once a day, and a password written somewhere is a
        // cost paid forever — so the write happens when someone says so.
        if case .httpAuth = prompt { return "save this password in the macOS Keychain" }
        return nil
    }

    private func buttonRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        row.addArrangedSubview(spacer)

        for (label, isDefault, outcome) in buttons {
            let button = AskButton(label: label, isDefault: isDefault)
            button.onClick = { [weak self] in self?.answer(outcome()) }
            if isDefault { defaultButton = button }
            row.addArrangedSubview(button)
        }
        return row
    }

    /// `(label, isDefault, outcome)`, left to right. The destructive or
    /// cancelling answer is on the left and never the default, so ↩ on a sheet
    /// you have not read cannot grant a camera.
    private var buttons: [(String, Bool, () -> AskOutcome)] {
        switch prompt {
        case .alert:
            return [("OK", true, { .confirmed })]
        case .confirm:
            return [("CANCEL", false, { .cancelled }), ("OK", true, { .confirmed })]
        case .prompt:
            return [
                ("CANCEL", false, { .cancelled }),
                ("OK", true, { [weak self] in .text(self?.textField.stringValue ?? "") }),
            ]
        case .capture:
            return [
                ("BLOCK", false, { [weak self] in
                    .capture(allowed: false, remember: self?.remember.state == .on)
                }),
                ("ALLOW", false, { [weak self] in
                    .capture(allowed: true, remember: self?.remember.state == .on)
                }),
            ]
        case .httpAuth:
            return [
                ("CANCEL", false, { .cancelled }),
                ("SIGN IN", true, { [weak self] in
                    guard let self else { return .cancelled }
                    return .credential(
                        user: self.userField.stringValue,
                        password: self.passwordField.stringValue,
                        save: self.remember.state == .on)
                }),
            ]
        case .savePassword:
            return [
                ("CANCEL", false, { .cancelled }),
                ("SAVE", true, { [weak self] in
                    guard let self else { return .cancelled }
                    return .credential(
                        user: self.userField.stringValue,
                        password: self.passwordField.stringValue,
                        save: false)
                }),
            ]
        case .clientCertificate(let names):
            guard !names.isEmpty else { return [("CANCEL", true, { .cancelled })] }
            return [
                ("CANCEL", false, { .cancelled }),
                ("SEND", true, { [weak self] in
                    .certificate(index: self?.certificates.indexOfSelectedItem ?? 0)
                }),
            ]
        }
    }

    // MARK: - answering

    /// Exactly once, and the sheet is off screen before the page hears about
    /// it. Two clicks on OK inside one run loop turn would otherwise call
    /// WebKit's completion handler twice, which is a crash and not an error.
    private func answer(_ outcome: AskOutcome) {
        guard let handler = onAnswer else { return }
        onAnswer = nil
        removeFromSuperview()
        handler(outcome)
    }

    /// For the pane tearing down underneath an unanswered sheet.
    func dismissWithoutAnswering() {
        onAnswer = nil
        removeFromSuperview()
    }

    // MARK: - keyboard

    /// The sheet takes the keyboard, and the pane's `applyPendingFocus` stands
    /// off while it is up — without that the page would take first responder
    /// back on the next reconcile and Esc would go to the document.
    override var acceptsFirstResponder: Bool { true }

    func takeFocus() {
        switch prompt {
        case .prompt: window?.makeFirstResponder(textField)
        case .httpAuth, .savePassword: window?.makeFirstResponder(userField)
        default: window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: answer(.cancelled)                       // esc
        case 36, 76: defaultButton?.onClick?()            // return, enter
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { answer(.cancelled) }

    /// The scrim swallows clicks. Not a dismissal: clicking outside a question
    /// you did not read should not answer it, and the page underneath must not
    /// receive the click either.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? (bounds.contains(convert(point, from: superview)) ? self : nil)
    }

    override func mouseDown(with event: NSEvent) {}
}

extension WebAskSheet: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            defaultButton?.onClick?()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            answer(.cancelled)
            return true
        case #selector(NSResponder.insertTab(_:)):
            // Only the auth sheet has two fields, and tabbing between them is
            // the difference between a sign-in and a sign-in you have to reach
            // for the mouse in the middle of.
            if control === userField { window?.makeFirstResponder(passwordField); return true }
            return false
        default:
            return false
        }
    }
}

// MARK: - the panel

/// The sheet's body: square, filled, outlined on all four sides.
///
/// The full perimeter is the point. A single-edge accent rail is the house's
/// named anti-pattern, and a panel floating on a scrim needs an edge on every
/// side anyway or it reads as a hole in the page rather than a thing on top of
/// it.
@MainActor
private final class AskPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.stripBackground.setFill()
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

/// A square text button. `NSButton`'s every bordered style is a capsule.
@MainActor
final class AskButton: NSView {
    var onClick: (() -> Void)?

    private let label: String
    private let isDefault: Bool
    private var isHovered = false { didSet { needsDisplay = true } }

    init(label: String, isDefault: Bool) {
        self.label = label
        self.isDefault = isDefault
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private var font: NSFont { Theme.mono(11, weight: .medium) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: (label as NSString).size(withAttributes: [.font: font]).width + 22, height: 24)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.laneBorder.withAlphaComponent(0.6).setFill()
            bounds.fill()
        }
        // The default button carries the accent, as a square outline. It is the
        // same statement the address field makes when it is being edited —
        // *↩ lands here* — rather than a new colour with a new meaning.
        (isDefault ? Theme.accent : Theme.laneBorder).setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()

        let text = NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: isDefault ? NSColor.labelColor : Theme.dimText,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
