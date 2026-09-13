import AppKit

/// Find in page, on demand.
///
/// The one piece of chrome that is *not* always present. Find is a thing you
/// start, finish and dismiss — unlike the address, which is the pane's identity
/// and has to be readable without asking. A permanent search field would cost a
/// second band in a column that could not spare the first one.
///
/// It arrives by sliding its own height out from under the chrome bar rather
/// than appearing, because the page above it has to move up by 26 pt either way
/// and a cut makes that read as the page jumping. 140 ms, which is long enough
/// to follow and short enough that ⌘F still feels instant.
@MainActor
final class WebFindBar: NSView {
    static let height: CGFloat = 26

    /// `(query, forward)`. Fired on every keystroke and on each ↩/⇧↩.
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    private let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    private let previous = ChromeButton(icon: .chevronUp)
    private let next = ChromeButton(icon: .chevronDown)
    private let close = ChromeButton(icon: .x)

    var query: String { field.stringValue }

    /// True while the keyboard belongs to the find field, so the pane knows not
    /// to take it back on the click that put it there.
    var isEditing: Bool { window?.firstResponder === field.currentEditor() && field.currentEditor() != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        let glyph = NSTextField(labelWithString: "⌕")
        glyph.font = Theme.mono(12, weight: .medium)
        glyph.textColor = Theme.dimText

        field.font = Theme.mono(11)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.placeholderString = "find in page"
        field.delegate = self
        field.cell?.usesSingleLineMode = true

        status.font = Theme.mono(10)
        status.textColor = Theme.dimText
        status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)

        for button in [previous, next, close] { button.isDimmed = false }
        previous.onClick = { [weak self] in self?.search(forward: false) }
        next.onClick = { [weak self] in self?.search(forward: true) }
        close.onClick = { [weak self] in self?.onClose?() }
        previous.toolTip = "Previous match (⇧↩)"
        next.toolTip = "Next match (↩)"
        close.toolTip = "Close (esc)"

        let row = NSStackView(views: [glyph, field, status, previous, next, close])
        row.orientation = .horizontal
        row.spacing = 2
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(6, after: glyph)
        row.setCustomSpacing(8, after: field)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func takeFocus() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    /// What WebKit found, and — once the page has been counted — how many.
    ///
    /// `WKWebView.find` reports a boolean and nothing more, so the count arrives
    /// separately and later: this is called twice per search, first with
    /// `.none` the moment WebKit answers, then again when the page has been
    /// walked. The first call is what keeps `no match` instant, and the second
    /// is why `3/17` appears a beat after the highlight rather than holding it
    /// up. See `FindCount` for what makes the number honest.
    ///
    /// An empty field says nothing at all, because "no match" for a query
    /// nobody has typed is noise.
    func report(found: Bool, tally: FindCount.Tally = .none) {
        guard !field.stringValue.isEmpty else {
            status.stringValue = ""
            return
        }
        status.stringValue = found ? FindCount.label(matchFound: true, tally: tally) : "no match"
        status.textColor = found ? Theme.dimText : WebChromeBar.warning
    }

    private func search(forward: Bool) {
        guard !field.stringValue.isEmpty else { return }
        onSearch?(field.stringValue, forward)
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.laneBackground.setFill()
        bounds.fill()
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: bounds.height - Theme.borderWidth,
               width: bounds.width, height: Theme.borderWidth).fill()
    }
}

extension WebFindBar: NSTextFieldDelegate {
    /// Search as you type. WebKit's `find` is incremental and cheap, and a find
    /// bar that waits for ↩ is a find bar you use twice as many keystrokes on.
    func controlTextDidChange(_ notification: Notification) {
        guard !field.stringValue.isEmpty else { return status.stringValue = "" }
        onSearch?(field.stringValue, true)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            // ⇧↩ walks backwards. The field editor reports both chords through
            // this one selector on some layouts and splits them on others, so
            // the modifier on the event decides rather than the selector.
            search(forward: !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }
}
