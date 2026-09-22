import AppKit

/// What's New: the bundled `CHANGELOG.md`, newest first, hung from the version
/// in the sidebar's corner.
///
/// The owner: *"would be nice to click the version number to get a list of
/// changes from the log."* A `Popup` for the square panel, the fade in and out,
/// Esc and click-away; anchored (`anchorRect`) because it is about the label
/// that was clicked, and centred when What's New is chosen from the Help menu
/// with the sidebar away. `// UNRELEASED · 40` is open, since it is the part
/// that is news; every released version is folded behind its date and count
/// and opens on a click. `copy` on a header puts that section on the clipboard
/// as markdown, for a release note.
///
/// `ChangelogPopupModel` decides the order, the fold state and the copy text;
/// this draws it.
@MainActor
final class ChangelogPopup: Popup {
    static let size = NSSize(width: 480, height: 540)
    private static let inset: CGFloat = 20

    private(set) var model: ChangelogPopupModel
    private let stack = NSStackView()
    private var sections: [ChangelogSectionView] = []

    /// The section headers as drawn, for tests.
    var headerTexts: [String] { sections.map(\.headerText) }
    /// Which sections are open, for tests.
    var openSections: [Int] { sections.indices.filter { !model.items[$0].isFolded } }
    /// The one-line notice when there is no changelog, or nil.
    private(set) var emptyText: String?

    /// A window someone reads: ⌘-Tab to check a commit is not a decision to
    /// close it.
    override var closesWhenAppDeactivates: Bool { false }

    init(model: ChangelogPopupModel) {
        self.model = model
        super.init(size: Self.size, dismissal: .clickAway)

        let content = NSView()
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        // Square, like every other popup.
        content.layer?.cornerRadius = 0

        let header = SectionHeader(text: "WHATS_NEW")
        let hint = NSTextField(labelWithString: "esc")
        hint.font = Theme.mono(10, weight: .medium)
        hint.textColor = Theme.dimText
        let rule = NSBox()
        rule.boxType = .separator

        // The sections, top-aligned in a scrolling column. The document view
        // is flipped so the column starts at the top, where reading does.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.wantsLayer = true
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 14, right: 0)
        let document = FlippedView()
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        if model.isEmpty {
            let notice = NSTextField(wrappingLabelWithString: ChangelogPopupModel.emptyMessage)
            notice.font = Theme.mono(11)
            notice.textColor = Theme.dimText
            emptyText = notice.stringValue
            stack.addArrangedSubview(notice)
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        }
        for (index, item) in model.items.enumerated() {
            let section = ChangelogSectionView(item: item, inset: Self.inset)
            section.onToggle = { [weak self] in self?.toggle(index) }
            section.onCopy = { [weak self] in self?.copy(index) }
            sections.append(section)
            stack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        for view in [header, hint, rule, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        let edge = Theme.borderWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.inset),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.inset),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edge),

            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Self.inset),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        window?.contentView = content
    }

    /// Open or fold one version. The column below it moves, so the whole
    /// column fades across the change rather than jumping.
    func toggle(_ index: Int) {
        guard sections.indices.contains(index) else { return }
        model.toggle(index)
        Motion.fade(stack.layer)
        sections[index].setFolded(model.items[index].isFolded)
    }

    /// The section as markdown, on the clipboard.
    func copy(_ index: Int) {
        guard model.items.indices.contains(index) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.items[index].copyText, forType: .string)
        sections[index].showCopied()
    }
}

/// One version: its `// HEADER`, its count while folded, its `copy`, and its
/// categories and entries while open.
@MainActor
final class ChangelogSectionView: NSView {
    var onToggle: (() -> Void)?
    var onCopy: (() -> Void)?

    private let triangle = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let copyButton: SidebarButton
    private let headerRow = NSView()
    private let body = NSTextField(wrappingLabelWithString: "")
    /// The header over the body, as a stack so a hidden body takes no room:
    /// a plain subview keeps its constraints when hidden, and a folded
    /// section was a header over a blank.
    private let column = NSStackView()
    private let isUnreleased: Bool
    private var copiedReset: DispatchWorkItem?

    var headerText: String { title.stringValue }
    var bodyText: String { body.stringValue }
    var isBodyHidden: Bool { body.isHidden }

    init(item: ChangelogPopupModel.Item, inset: CGFloat) {
        copyButton = SidebarButton(text: "copy", look: .quiet, size: 9, action: nil, target: nil)
        isUnreleased = item.section.isUnreleased
        super.init(frame: .zero)

        triangle.imageScaling = .scaleProportionallyDown
        title.attributedStringValue = Self.header(item.header)
        title.lineBreakMode = .byTruncatingTail
        count.stringValue = item.foldedCount
        count.font = Theme.mono(9)
        count.textColor = Theme.dimText
        copyButton.layer?.borderWidth = 0
        copyButton.toolTip = "Copy this section as markdown"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)

        body.attributedStringValue = Self.body(item.section)
        body.preferredMaxLayoutWidth = ChangelogPopup.size.width - 2 * inset - 18

        for view in [triangle, title, count, copyButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            headerRow.addSubview(view)
        }
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        column.addArrangedSubview(headerRow)
        column.addArrangedSubview(body)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        headerRow.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(headerClicked(_:))))

        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            headerRow.widthAnchor.constraint(equalTo: column.widthAnchor),
            headerRow.heightAnchor.constraint(equalToConstant: 30),

            triangle.leadingAnchor.constraint(equalTo: headerRow.leadingAnchor),
            triangle.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            triangle.widthAnchor.constraint(equalToConstant: 12),
            triangle.heightAnchor.constraint(equalToConstant: 12),
            title.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            count.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            copyButton.leadingAnchor.constraint(equalTo: count.trailingAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: headerRow.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: headerRow.centerYAnchor),
            copyButton.heightAnchor.constraint(equalToConstant: 18),

            body.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 18),
            body.trailingAnchor.constraint(equalTo: column.trailingAnchor),
        ])
        setFolded(item.isFolded)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func setFolded(_ folded: Bool) {
        body.isHidden = folded
        // The count, while folded — except on Unreleased, whose header
        // already carries it.
        count.isHidden = !folded || isUnreleased
        triangle.image = IconImage.make(folded ? .chevronRight : .chevronDown, points: 11, colour: Theme.dimText)
    }

    /// `copy` reads `copied` for a moment, and fades back.
    func showCopied() {
        copiedReset?.cancel()
        Motion.fade(copyButton.layer)
        copyButton.setText("copied")
        let reset = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Motion.fade(self.copyButton.layer)
            self.copyButton.setText("copy")
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: reset)
    }

    @objc private func headerClicked(_ recognizer: NSClickGestureRecognizer) {
        // The button has its own click; a press on it is not a fold.
        if copyButton.frame.contains(recognizer.location(in: headerRow)) { return }
        onToggle?()
    }

    @objc private func copyClicked() { onCopy?() }

    /// `// ` in the accent, the rest in the label colour: the house header.
    private static func header(_ text: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: Theme.accent,
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: NSColor.labelColor,
        ]))
        return s
    }

    /// `ADDED`, then its entries as `- ` lines with wrapped lines hanging
    /// under the text, not under the dash. Backticks stay as written: this is
    /// the changelog, not a rendering of it.
    private static func body(_ section: Changelog.Section) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let hanging = NSMutableParagraphStyle()
        hanging.firstLineHeadIndent = 0
        hanging.headIndent = 13
        hanging.paragraphSpacing = 3
        let categoryStyle = NSMutableParagraphStyle()
        categoryStyle.paragraphSpacingBefore = 8
        categoryStyle.paragraphSpacing = 4
        for (i, group) in section.groups.enumerated() {
            if !group.category.isEmpty {
                let style = i == 0 ? { let s = NSMutableParagraphStyle(); s.paragraphSpacing = 4; return s }() : categoryStyle
                out.append(NSAttributedString(string: group.category.uppercased() + "\n", attributes: [
                    .font: Theme.mono(9, weight: .bold), .foregroundColor: Theme.dimText, .paragraphStyle: style,
                ]))
            }
            for entry in group.entries {
                out.append(NSAttributedString(string: "- \(entry)\n", attributes: [
                    .font: Theme.mono(11), .foregroundColor: NSColor.labelColor, .paragraphStyle: hanging,
                ]))
            }
        }
        if out.length > 0 { out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1)) }
        return out
    }
}

/// A document view whose origin is its top-left, so a column of sections
/// starts where reading does and a short list sits at the top, not the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
