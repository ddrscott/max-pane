import AppKit

/// The server's name where nothing else names it: a small square outlined
/// chip — `WSL` — tinted in that server's colour (ADR-0025, amending
/// ADR-0023).
///
/// ADR-0023 put this chip, in grey, on every surface. A day of use said that
/// was too much where the context already names the server and too little as
/// a glance-mark, so the mark is now a colour (`ServerMark`, the small solid
/// square) and the *name* stays only where there is no section above the row
/// to say it: the lane header beside the path — and so the gallery tile's
/// header —, ⌘O's session and launch rows, and ⌘P's session and search-hit
/// rows, all of which mix servers. A sidebar row sits under `// WSL` and
/// carries the square alone.
///
/// **Outlined, square, in the server's colour.** Outline and text, never a
/// fill: a filled block in a header is BLOCKED's (ADR-0015), and this is
/// identity, not state. The colours are chosen to be unmistakable for a
/// green or for DONE's orange (`Theme.server`). `slate`, the colour of a
/// server nobody coloured, is exactly the grey chip this was before.
///
/// **No room for a name, the square alone** (`compact`): a gallery tile
/// shrunk past reading, or a header too narrow to keep its title. **Offline**
/// it keeps its colour at reduced alpha, and the square goes hollow.
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
    private let mark = ServerMark()
    private let font: NSFont
    private let padding: CGFloat = 4

    /// The server to name, or nil for a local session: no chip, no width.
    var server: String? {
        didSet { if server != oldValue { apply(animated: false) } }
    }

    /// The server is not answering: the same colour at reduced alpha, and
    /// the square, when that is all there is, hollow.
    var offline = false {
        didSet { if offline != oldValue { apply(animated: true) } }
    }

    /// No room for the name: the square alone.
    var compact = false {
        didSet { if compact != oldValue { apply(animated: true) } }
    }

    /// The square's side when compact. A gallery tile grows it against its
    /// own scale, as the focus outline is drawn thicker there.
    var compactSide: CGFloat = ServerMark.side {
        didSet {
            guard compactSide != oldValue else { return }
            mark.side = compactSide
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    /// What is drawn, for tests.
    private(set) var colour: ServerColour = .fallback
    var showsName: Bool { server != nil && !compact }
    var showsSquareAlone: Bool { server != nil && compact }
    var squareIsHollow: Bool { mark.isHollow }

    private func apply(animated: Bool) {
        label.stringValue = server.map(Self.text(for:)) ?? ""
        isHidden = server == nil
        toolTip = server.map { name in Self.hosts[name].map { "\(name) — \($0)" } ?? name }
        colour = server.map(ServerColours.colour(of:)) ?? .fallback
        if animated, window != nil { Motion.fade(layer) }
        let ink = Theme.server(colour)
        layer?.borderWidth = compact ? 0 : 1
        layerBorderColor = ink.withAlphaComponent(0.6)
        label.textColor = ink
        label.isHidden = compact
        label.alphaValue = offline ? ServerMark.offlineAlpha : 1
        mark.server = compact ? server : nil
        mark.offline = offline
        mark.toolTip = nil
        if offline { layerBorderColor = ink.withAlphaComponent(0.6 * ServerMark.offlineAlpha) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func coloursChanged() {
        guard let server, ServerColours.colour(of: server) != colour else { return }
        apply(animated: true)
    }

    init(server: String? = nil, size: CGFloat = 9, offline: Bool = false) {
        font = Theme.mono(size, weight: .bold)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        label.font = font
        label.alignment = .center
        label.lineBreakMode = .byClipping
        addSubview(label)
        mark.translatesAutoresizingMaskIntoConstraints = true
        addSubview(mark)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        self.server = server     // no observer inside `init`
        self.offline = offline
        apply(animated: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(coloursChanged), name: ServerColours.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// The text as drawn, for tests.
    var text: String { label.stringValue }

    /// Measured, not intrinsic: `NSTextField` comes back a point short of
    /// what it then draws (see `SidebarBookmarkView`). Zero for no server.
    var fittingWidth: CGFloat {
        guard server != nil else { return 0 }
        return compact ? compactSide : namedWidth
    }

    /// The width with the name in it, whether or not it is showing: what a
    /// header weighs against its title before deciding there is no room.
    var namedWidth: CGFloat {
        guard server != nil else { return 0 }
        return ceil((label.stringValue as NSString).size(withAttributes: [.font: font]).width) + padding * 2 + 2
    }

    var fittingHeight: CGFloat { compact ? compactSide : ceil(font.ascender - font.descender) + 3 }

    override var intrinsicContentSize: NSSize {
        NSSize(width: fittingWidth, height: fittingHeight)
    }

    override func layout() {
        super.layout()
        let height = ceil(font.ascender - font.descender) + 1
        label.frame = NSRect(x: 0, y: ((bounds.height - height) / 2).rounded(), width: bounds.width, height: height)
        mark.frame = NSRect(
            x: ((bounds.width - compactSide) / 2).rounded(), y: ((bounds.height - compactSide) / 2).rounded(),
            width: compactSide, height: compactSide)
    }
}
