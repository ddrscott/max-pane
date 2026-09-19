import AppKit

/// The mark of a server: a small solid square in that server's colour
/// (ADR-0025).
///
/// One component, defined once, the same 9 pt square wherever the server is
/// already named nearby — a sidebar row under `// WSL`, a swatch in the menu
/// and in Settings — and, inside `ServerChip`, what is left of the chip when
/// there is no room for a name. Its tooltip is the server's name, so the
/// square alone is never a riddle.
///
/// **Solid is live, hollow is offline.** A server that is not answering keeps
/// its colour — it is still *that* server — and loses its fill: an outline in
/// the same colour at reduced alpha, the way a status square goes hollow when
/// nothing vouches for a process (ADR-0023).
///
/// The colour is identity and nothing else. State stays green and DONE stays
/// orange; this square is never a status square and sits apart from one.
///
/// It re-reads its colour when `ServerColours` changes and cross-fades, so a
/// colour picked from the menu is on every mark in the same turn, eased.
@MainActor
final class ServerMark: NSView {
    /// The side everywhere but the sidebar row, which is a point smaller to
    /// sit on its 9 pt second line.
    static let side: CGFloat = 9
    /// An offline mark's outline, against a live one's fill.
    static let offlineAlpha: CGFloat = 0.55

    var server: String? {
        didSet { if server != oldValue { apply(animated: false) } }
    }

    var offline: Bool {
        didSet { if offline != oldValue { apply(animated: true) } }
    }

    /// The side, in points. A gallery tile's chip grows it so the square
    /// lands on screen at about the size it has on the strip.
    var side: CGFloat {
        didSet {
            guard side != oldValue else { return }
            invalidateIntrinsicContentSize()
        }
    }

    /// What is drawn, for tests.
    private(set) var colour: ServerColour = .fallback
    var isHollow: Bool { offline }

    init(server: String? = nil, side: CGFloat = ServerMark.side, offline: Bool = false) {
        self.side = side
        self.offline = offline
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = 0
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        self.server = server     // no observer inside `init`
        apply(animated: false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(coloursChanged), name: ServerColours.didChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    @objc private func coloursChanged() {
        guard let server, ServerColours.colour(of: server) != colour else { return }
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        isHidden = server == nil
        guard let server else { return }
        colour = ServerColours.colour(of: server)
        // A change of colour or of liveness is a cross-fade, never a cut.
        if animated, window != nil { Motion.fade(layer) }
        Self.paint(self, colour: colour, hollow: offline)
        toolTip = ServerChip.hosts[server].map { "\(server) — \($0)" } ?? server
    }

    /// The square's two looks, on any layer-backed view: the menu's and
    /// Settings' swatches are painted by the same lines as the mark itself.
    static func paint(_ view: NSView, colour: ServerColour, hollow: Bool) {
        let ink = Theme.server(colour)
        view.wantsLayer = true
        view.layer?.cornerRadius = 0
        if hollow {
            view.layerBackgroundColor = NSColor.clear
            view.layer?.borderWidth = 1
            view.layerBorderColor = ink.withAlphaComponent(offlineAlpha)
        } else {
            view.layerBackgroundColor = ink
            view.layer?.borderWidth = 0
        }
    }

    /// The square as an image, for a menu item: `NSMenu` draws images, not
    /// views. Drawn through a handler, so it re-resolves with the appearance
    /// the menu opens in.
    static func swatch(_ colour: ServerColour, side: CGFloat = ServerMark.side) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            Theme.server(colour).setFill()
            rect.fill()
            return true
        }
    }
}
