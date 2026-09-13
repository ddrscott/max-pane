import AppKit

/// What the pane shows while a file is arriving, and after it has.
///
/// **A download that completes with no trace is the same bug as a download that
/// never starts**, so this does not auto-hide. A finished row stays until the
/// user dismisses it, says the file's name and final size, and reveals it in the
/// Finder when clicked — which is the whole of "where did it go", one click from
/// the thing that said it arrived.
///
/// It lives in the lane, above the chrome bar and below the find bar, and it
/// belongs to the pane that started the download rather than to the app. A
/// global downloads shelf would be a second place to look in an app whose
/// premise is that everything about a page is in that page's column — and would
/// have to decide what to do when the lane that asked for the file is fifteen
/// lanes away, which is a question the lane answers by not having it.
///
/// Rows are 20 pt and there are at most three; a fourth download collapses the
/// oldest finished row rather than growing the bar into the page. The progress
/// hairline is `Theme.flowing` green — the app's existing "bytes are moving" —
/// and not Signal Orange, which is spent on focus and attention.
@MainActor
final class WebDownloadBar: NSView {
    static let rowHeight: CGFloat = 20
    static let maxRows = 3

    /// Dismiss one row. The job is not cancelled by this if it has finished;
    /// for a running one it is, because the only other reading of ✕ on a
    /// running download is "hide it and let it keep going", and a download you
    /// cannot see is a download you cannot find.
    var onDismiss: ((UUID) -> Void)?
    var onReveal: ((UUID) -> Void)?

    private let stack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.borderWidth),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// How tall the bar wants to be for `count` rows. The pane owns the
    /// constraint so the change can be animated with the same 140 ms the find
    /// bar uses — the page above has to move either way, and a cut reads as the
    /// page jumping.
    static func height(rows: Int) -> CGFloat {
        rows <= 0 ? 0 : CGFloat(min(rows, maxRows)) * rowHeight + Theme.borderWidth
    }

    func show(_ jobs: [DownloadJob]) {
        let shown = Array(jobs.suffix(Self.maxRows))
        // Rebuilt rather than diffed: three rows of two labels, redrawn on a
        // progress tick that arrives a few times a second. Diffing this would
        // be more code than it saves.
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for job in shown {
            let row = DownloadRowView(job: job)
            row.onDismiss = { [weak self] in self?.onDismiss?(job.id) }
            row.onReveal = { [weak self] in self?.onReveal?(job.id) }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.laneBackground.setFill()
        bounds.fill()
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: bounds.height - Theme.borderWidth,
               width: bounds.width, height: Theme.borderWidth).fill()
    }
}

/// One file: a glyph that says what state it is in, the name, and the number.
@MainActor
private final class DownloadRowView: NSView {
    var onDismiss: (() -> Void)?
    var onReveal: (() -> Void)?

    private let glyph = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let close = ChromeButton(glyph: "×")
    private let fraction: Double
    private let isRunning: Bool

    init(job: DownloadJob) {
        fraction = job.fraction
        isRunning = job.state == .running
        super.init(frame: .zero)
        wantsLayer = true

        switch job.state {
        case .running:
            glyph.stringValue = "↓"
            glyph.textColor = Theme.flowing
        case .finished:
            glyph.stringValue = "✓"
            glyph.textColor = Theme.flowing
        case .failed:
            glyph.stringValue = "✕"
            glyph.textColor = WebChromeBar.warning
        }
        glyph.font = Theme.mono(11, weight: .medium)

        name.stringValue = job.name
        name.font = Theme.mono(10)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.setContentHuggingPriority(.init(1), for: .horizontal)

        status.stringValue = job.statusText
        status.font = Theme.mono(10)
        status.textColor = Theme.dimText
        status.alignment = .right
        status.setContentHuggingPriority(.required, for: .horizontal)

        close.isDimmed = false
        close.onClick = { [weak self] in self?.onDismiss?() }
        close.toolTip = job.state == .running ? "Cancel" : "Dismiss"

        toolTip = job.destination?.path
        if job.state == .finished { toolTip = "\(job.destination?.path ?? "") — click to show in Finder" }

        let row = NSStackView(views: [glyph, name, status, close])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: WebDownloadBar.rowHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func mouseUp(with event: NSEvent) { onReveal?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isRunning, fraction > 0 else { return }
        // A 2 pt bar along the bottom of the row rather than a spinner: it is
        // the only readout that answers "will this be a while", and in a mono
        // row it is free — no glyph, no layout, no width that changes.
        Theme.flowing.withAlphaComponent(0.5).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: 2).fill()
    }
}
