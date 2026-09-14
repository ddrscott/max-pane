import AppKit

/// The row above the strip: a LANES | GALLERY switch, a way into ⌘P, and how
/// many sessions are running — level with the sidebar's header, so the two read
/// as one band across the window.
///
/// The owner, twice. First: *"we should add something to fill in that top gap"*,
/// which became controls in the full-screen title bar. Then, with a screenshot of
/// those controls drawn over an expanded tile's header: *"can we move [lanes |
/// gallery] [Find] [sessions] down a level so it's at the same level and to the
/// right of the session sidebar? And that bar shouldn't be invisible when we're
/// full screen."* A title bar accessory is drawn over content and only exists
/// where a title bar does; a row in the layout is neither.
///
/// `StatusBar` exists because chrome across the top eats the lane headers' room,
/// and this does cost the strip 34 pt. It is the sidebar header's 34, though: the
/// sidebar already spends that height at the top, and the strip beside it now
/// lines up with it rather than starting higher. `+ NEW` is not repeated here —
/// the sidebar's half of the same row already has one.
@MainActor
final class StripToolbar: NSView {
    /// The sidebar header's height (`SidebarViewController.buildHeader`). The two
    /// halves of the row have to agree, or the rule under them steps.
    static let height: CGFloat = 34

    var onLayout: ((_ gallery: Bool) -> Void)?
    var onFind: (() -> Void)?

    private(set) var lanesButton: SidebarButton!
    private(set) var galleryButton: SidebarButton!
    private(set) var findButton: SidebarButton!
    let sessions = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The sidebar's own ground: its header has none of its own, and the two
        // halves of the row are meant to be one band.
        layerBackgroundColor = Theme.stripBackground

        lanesButton = SidebarButton(text: "LANES", look: .quiet, action: #selector(pickLanes), target: self)
        galleryButton = SidebarButton(text: "GALLERY", look: .quiet, action: #selector(pickGallery), target: self)
        findButton = SidebarButton(
            text: "find a lane…  ⌘P", icon: .search, look: .quiet, action: #selector(findLane), target: self)
        lanesButton.toolTip = "The strip (⌘G)"
        galleryButton.toolTip = "Every lane on one screen (⌘G)"
        findButton.toolTip = "Find a lane by title, URL or something it printed (⌘P)"
        for button in [lanesButton, galleryButton, findButton] as [SidebarButton] {
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        }

        // The two halves of one switch share a border: overlapped by a point, so
        // the seam between them is one line and not two.
        let segment = NSStackView(views: [lanesButton, galleryButton])
        segment.orientation = .horizontal
        segment.spacing = -Theme.borderWidth

        let row = NSStackView(views: [segment, findButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        sessions.font = Theme.mono(10)
        sessions.textColor = Theme.dimText
        // Hugging its text, so the gap between the controls and the count is
        // empty row rather than label. Without it the label was laid out 944 pt
        // wide from the find button to the edge — and an attributed string drops
        // a text field's alignment, so the count was drawn at the wrong end of it.
        sessions.usesSingleLineMode = true
        sessions.maximumNumberOfLines = 1
        sessions.cell?.wraps = false
        sessions.lineBreakMode = .byClipping
        sessions.setContentHuggingPriority(.required, for: .horizontal)
        sessions.setContentCompressionResistancePriority(.required, for: .horizontal)

        for view in [row, sessions] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            sessions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            sessions.centerYAnchor.constraint(equalTo: centerYAnchor),
            sessions.leadingAnchor.constraint(greaterThanOrEqualTo: row.trailingAnchor, constant: 12),
        ])

        setLayout(isGallery: false)
        setSessions(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // The sidebar header's rule, carried on across the strip.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth).fill()
    }

    /// Light the half of the switch the strip is showing.
    func setLayout(isGallery: Bool) {
        lanesButton.isOn = !isGallery
        galleryButton.isOn = isGallery
    }

    /// The footer's count, with the live marker when anything is running.
    func setSessions(_ running: Int) {
        // One line, clipped, in the string itself: setting an attributed string
        // replaces the field's own line settings, and a field that thinks it may
        // wrap has no single-line width to hug.
        let line = NSMutableParagraphStyle()
        line.lineBreakMode = .byClipping
        let text = NSMutableAttributedString()
        if running > 0 {
            text.append(NSAttributedString(
                string: "$ ", attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(10, weight: .bold)]))
        }
        text.append(NSAttributedString(
            string: "\(running) session\(running == 1 ? "" : "s")",
            attributes: [.foregroundColor: Theme.dimText, .font: Theme.mono(10)]))
        text.addAttribute(.paragraphStyle, value: line, range: NSRange(location: 0, length: text.length))
        sessions.attributedStringValue = text
        sessions.invalidateIntrinsicContentSize()
    }

    @objc func pickLanes() { onLayout?(false) }
    @objc func pickGallery() { onLayout?(true) }
    @objc func findLane() { onFind?() }
}
