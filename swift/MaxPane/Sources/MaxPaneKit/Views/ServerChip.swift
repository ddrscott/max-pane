import AppKit

/// The one mark of a remote session: a small square outlined chip with the
/// server's name — `WSL` — wherever a remote session is shown.
///
/// The plan's first rule was "the server's name where the directory sits"
/// (`WSL:/home/spierce`). In use that was not enough: a remote row was
/// pixel-identical to a local one and the name was one more run of grey text
/// in a path. The mark is now this chip, the same everywhere — the sidebar's
/// session rows, the lane header beside the path, ⌘O's session and launch
/// rows, ⌘P's session hits, and so the gallery tile's header — and the path
/// beside it stops repeating the name (ADR-0023, superseding that sentence of
/// ADR-0020 and plan §0).
///
/// **Grey, outlined, square.** It is identity, not state: the greens are spent
/// on focus and on what a session is doing, and a permanent green mark on a
/// lane that is remote all day would spend the colour on something that is
/// true all the time. The state of the *server* is a different chip, in the
/// accent green, where a state chip goes. No colour per server, by the
/// owner's leave: if the chip is not enough, that is the next round.
///
/// This is the only place the chip is defined. A local session has none, and
/// with no server configured nothing anywhere builds one.
@MainActor
final class ServerChip: NSView {
    /// Past this many characters a name is cut with an ellipsis: the chip is
    /// a mark, and a mark that pushes the title out of its row is not one.
    static let maxCharacters = 10

    /// Each server's URL host, by name, for the tooltip. Written by
    /// `RelayServers.reload`, the one place a name and a URL are put
    /// together; read here and nowhere else.
    static var hosts: [String: String] = [:]

    /// `yorkshire-miniforum` → `yorkshire…`; ten characters or fewer pass.
    static func text(for server: String) -> String {
        guard server.count > maxCharacters else { return server }
        return String(server.prefix(maxCharacters - 1)) + "…"
    }

    private let label = NSTextField(labelWithString: "")
    private let font: NSFont
    private let padding: CGFloat = 4

    /// The server to name, or nil for a local session: no chip, no width.
    var server: String? {
        didSet { if server != oldValue { apply() } }
    }

    private func apply() {
        label.stringValue = server.map(Self.text(for:)) ?? ""
        isHidden = server == nil
        toolTip = server.map { name in Self.hosts[name].map { "\(name) — \($0)" } ?? name }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    init(server: String? = nil, size: CGFloat = 9) {
        font = Theme.mono(size, weight: .bold)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1
        layerBorderColor = Theme.dimText.withAlphaComponent(0.6)
        label.font = font
        label.textColor = Theme.dimText
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        self.server = server     // no observer inside `init`
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// The text as drawn, for tests.
    var text: String { label.stringValue }

    /// Measured, not intrinsic: `NSTextField` comes back a point short of
    /// what it then draws (see `SidebarBookmarkView`). Zero for no server.
    var fittingWidth: CGFloat {
        guard server != nil else { return 0 }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + padding * 2 + 2
    }

    var fittingHeight: CGFloat { ceil(font.ascender - font.descender) + 3 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fittingWidth, height: fittingHeight)
    }

    override func layout() {
        super.layout()
        let height = ceil(font.ascender - font.descender) + 1
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
    }
}
