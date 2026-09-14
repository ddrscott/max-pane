import AppKit
import LanedCore

/// The sidebar's ink beyond `Theme`'s one accent.
///
/// Status is not decoration, so it gets colour — but only three: orange for
/// "working right now", green for "alive and waiting on you", grey for "gone".
/// Anything else would make the accent stop meaning anything.
enum SidebarInk {
    /// Alive and quiet. Dimmer than `Theme.agentStateColor(.working)`, so a
    /// session that is actually producing output still reads brighter.
    static let live = NSColor(srgbRed: 0.18, green: 0.55, blue: 0.31, alpha: 1)
    /// The throughput readout. Green only while bytes are moving.
    static let flow = Theme.agentStateColor(.working)
    static let gone = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 1)
            : NSColor(white: 0.60, alpha: 1)
    }
    static let hover = NSColor(white: 0.5, alpha: 0.10)
    static let selection = Theme.accent.withAlphaComponent(0.16)
}

/// Square selection, square hover, and a hard orange edge on the selected row.
///
/// `NSTableView`'s source-list style draws a rounded blue capsule; that is the
/// one thing the house style has no version of, so the row draws its own.
final class SidebarRowView: NSTableRowView {
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    /// Group headers are structure, not targets — they take no highlight.
    var isTargetable = true

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, isTargetable, !isSelected else { return }
        SidebarInk.hover.setFill()
        bounds.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isTargetable else { return }
        SidebarInk.selection.setFill()
        bounds.fill()
        Theme.accent.setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// One session (or web lane) in the browser.
///
///     ▪ $ ◑  Pane terminal siz…   1.7KB/s
///       WORKING                     6s ago
///
/// Two lines, because the bar proved the second one is worth its pixels: a
/// throughput reading with no age beside it cannot tell "busy" from "stuck",
/// and the agent-state chip is the thing you actually scan ten rows for.
final class SidebarEntryView: NSTableCellView {
    private let status = NSView()
    /// What kind of pane this row is, and whether it is on the strip.
    private let markerIcon = NSImageView()
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let age = NSTextField(labelWithString: "")
    private let chip = NSTextField(labelWithString: "")

    static let height: CGFloat = 40

    init(entry: SidebarModel.Entry) {
        super.init(frame: .zero)

        let attached = entry.laneId != nil
        let isWeb = entry.kind != .session

        // A filled square is a running process; a hollow one is a lane with no
        // process behind it. Shape carries the fact, so the colour does not have
        // to carry two.
        status.wantsLayer = true
        status.layer?.cornerRadius = 0
        let tint = Self.statusColor(entry)
        if entry.isRunning && !isWeb {
            status.layerBackgroundColor = tint
        } else {
            status.layer?.borderWidth = 1
            status.layerBorderColor = tint
        }

        // Kind first, then state: a terminal, a page, or a session that is not
        // on the strip yet. Orange means "live, and on the strip" — a lane whose
        // session has died is neither, so it goes grey with the rest of the row.
        let markerInk = (attached && entry.isRunning && !isWeb) ? Theme.flowing : SidebarInk.gone
        let markerIsFor: LucideIcon = isWeb ? .globe : (attached ? .squareTerminal : .plus)
        markerIcon.image = IconImage.make(markerIsFor, points: 12, colour: markerInk)
        markerIcon.imageScaling = .scaleProportionallyDown

        glyph.stringValue = isWeb ? "" : entry.glyph
        glyph.font = Theme.mono(11, weight: entry.needsAttention ? .bold : .regular)
        glyph.textColor = Self.ink(entry.state)
        glyph.alignment = .center

        // The chip only exists for the states worth interrupting someone for —
        // blocked, working, done. An ordinary shell shows nothing here, which is
        // exactly what makes the chips that do appear worth looking at.
        let chipInk = Theme.agentStateColor(entry.state)
        chip.stringValue = entry.chip.isEmpty ? "" : " \(entry.chip) "
        chip.font = Theme.mono(8, weight: entry.needsAttention ? .bold : .medium)
        chip.textColor = chipInk
        chip.wantsLayer = true
        // Square, like RelayTTY's own chip and like everything else here.
        chip.layer?.cornerRadius = 0
        chip.layer?.borderWidth = entry.chip.isEmpty ? 0 : 1
        chip.layerBorderColor = chipInk
        // BLOCKED is the only chip that gets filled. It is the one signal the
        // eye has to find across ten rows without reading any of them.
        chip.layerBackgroundColor = entry.needsAttention
            ? Theme.accent.withAlphaComponent(0.18)
            : NSColor.clear

        title.attributedStringValue = Self.titleText(entry)

        badge.stringValue = entry.badge.uppercased()
        badge.font = Theme.mono(10, weight: entry.badgeIsThroughput ? .medium : .regular)
        badge.textColor = entry.badgeIsThroughput ? SidebarInk.flow : Theme.dimText
        badge.alignment = .right

        age.stringValue = entry.age
        age.font = Theme.mono(9)
        age.textColor = NSColor.tertiaryLabelColor
        age.alignment = .right

        toolTip = attached
            ? "\(entry.title)\n\(entry.sessionId ?? "web lane") — click to reveal on the strip"
            : "\(entry.title)\n\(entry.sessionId ?? "") — click to attach"

        for v in [glyph, title, badge, age, chip] {
            v.isBezeled = false
            v.drawsBackground = false
            // A label that wraps eats the row below it. Every column here is one
            // line that truncates, always — and the break mode has to be set
            // *after* `usesSingleLineMode`, which resets it to clipping and
            // would drop the ellipsis that says a title was cut.
            v.usesSingleLineMode = true
            v.maximumNumberOfLines = 1
            v.lineBreakMode = .byTruncatingTail
            v.cell?.truncatesLastVisibleLine = true
        }
        for v: NSView in [status, markerIcon, glyph, title, badge, age, chip] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 7),
            status.heightAnchor.constraint(equalToConstant: 7),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            status.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            markerIcon.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 5),
            markerIcon.widthAnchor.constraint(equalToConstant: 12),
            markerIcon.heightAnchor.constraint(equalToConstant: 12),
            markerIcon.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            glyph.leadingAnchor.constraint(equalTo: markerIcon.trailingAnchor, constant: 3),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),

            badge.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            badge.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor),

            age.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            age.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),

            chip.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            chip.centerYAnchor.constraint(equalTo: age.centerYAnchor),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
        ])
        // The title yields to nothing: a truncated title is still readable, a
        // truncated throughput reading is a wrong number.
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private static func titleText(_ entry: SidebarModel.Entry) -> NSAttributedString {
        // Every live session gets a full-strength title. Dimming the ones that
        // are not on the strip was a mistake the first screenshot made obvious:
        // it greys out most of the browser, and those are the rows you are here
        // to find. The `$`/`+` marker carries "on the strip" instead.
        let colour: NSColor = entry.isRunning ? .labelColor : SidebarInk.gone
        // An attributed string carries its own paragraph style, and the field's
        // `lineBreakMode` does not reach it — without this the title clips flat
        // with no ellipsis to say it was cut.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString()
        if entry.pinned {
            out.append(NSAttributedString(
                string: "▪ ",
                attributes: [
                    .foregroundColor: Theme.accent,
                    .font: Theme.mono(9),
                    .paragraphStyle: paragraph,
                ]))
        }
        out.append(NSAttributedString(
            string: entry.title,
            attributes: [
                .foregroundColor: colour,
                .font: Theme.mono(12),
                .paragraphStyle: paragraph,
            ]))
        return out
    }

    /// The dot answers "is there a process there", the glyph answers "what is it
    /// doing". So a running session with nothing else known is green: alive is
    /// the fact the dot exists to carry, and an ordinary shell is not a problem.
    /// The dot answers "is there a process there", the glyph and chip answer
    /// "what is it doing". So a running session with nothing else known is
    /// green: alive is the fact the dot exists to carry, and an ordinary shell
    /// is not a problem.
    private static func statusColor(_ entry: SidebarModel.Entry) -> NSColor {
        guard entry.isRunning else { return SidebarInk.gone }
        switch entry.kind {
        case .web, .placeholder: return SidebarInk.gone
        case .session:
            switch entry.state {
            case .blocked: return Theme.accent
            case .working: return Theme.agentStateColor(.working)
            case .idle, .done, .unknown: return SidebarInk.live
            case .exited: return SidebarInk.gone
            }
        }
    }

    /// `Theme.agentStateColor` is the authority, and it deliberately returns
    /// clear for the two states that get no chip — so those fall back to a
    /// readable dim here rather than disappearing.
    private static func ink(_ state: AgentState) -> NSColor {
        let colour = Theme.agentStateColor(state)
        return colour == .clear ? Theme.dimText : colour
    }
}

/// `▼ // ~/CODE/MAX-PANE ………… 1 RUNNING`
///
/// The house `// CAPS` header, with the bar's disclosure triangle and running
/// count folded into it. Grouping is unconditional here: ten sessions across six
/// projects is exactly when a flat list stops being a browser.
final class SidebarGroupView: NSTableCellView {
    private let triangle = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let rule = NSView()

    static let height: CGFloat = 26

    init(group: SidebarModel.Group) {
        super.init(frame: .zero)

        triangle.image = IconImage.make(
            group.collapsed ? .chevronRight : .chevronDown, points: 11, colour: Theme.dimText)
        triangle.imageScaling = .scaleProportionallyDown

        // A header separates by being *quieter* than the rows, not louder.
        //
        // Bold and `labelColor` put it on the same axis as the titles — same
        // ink, near-identical weight once 10pt bold meets 12pt regular — so the
        // eye had nothing to sort them by and the path read as another session.
        // Titles are the content and keep full strength; the path is structure,
        // so it recedes and lets the triangle and the hairline do the work.
        //
        // No `//` mark in front of it, house style notwithstanding: these rows
        // are literal filesystem paths, and `//` is path syntax. A header
        // reading `// ~/code/max-pane` invites the question of what the empty
        // segment is.
        label.stringValue = group.header
        label.font = Theme.mono(10)
        label.textColor = Theme.dimText
        // Head, not tail: the end of a path is the part that says which project
        // this is. `…/WORKTREES/AGENT-AD3` beats `~/CODE/MAX-PA…`.
        label.lineBreakMode = .byTruncatingHead

        // A collapsed group hides its rows; the count is then the only thing
        // left to say "there is an agent in here waiting on you", so when there
        // is one it takes the accent and the rest stays quiet.
        count.stringValue = group.countText
        count.font = Theme.mono(9, weight: group.blocked > 0 ? .bold : .regular)
        count.textColor = group.blocked > 0 ? Theme.accent : Theme.dimText
        count.alignment = .right

        // A hairline above the header instead of padding: the strip is made of
        // hard edges, and so is its index.
        rule.wantsLayer = true
        rule.layerBackgroundColor = Theme.laneBorder

        for v in [label, count] {
            v.isBezeled = false
            v.drawsBackground = false
            v.usesSingleLineMode = true
            v.maximumNumberOfLines = 1
        }
        // Set after `usesSingleLineMode`, which would otherwise reset it.
        label.lineBreakMode = .byTruncatingHead
        for v: NSView in [triangle, label, count, rule] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            triangle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            triangle.widthAnchor.constraint(equalToConstant: 11),
            triangle.heightAnchor.constraint(equalToConstant: 11),
            triangle.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 2),


            label.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: triangle.centerYAnchor),

            count.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            count.centerYAnchor.constraint(equalTo: triangle.centerYAnchor),
        ])
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)

        toolTip = group.path == SidebarModel.looseWebGroup ? "Web lanes" : group.path
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// A square, monospaced control. AppKit has no bezel that is not rounded, so the
/// border is a layer and the title is drawn flat.
final class SidebarButton: NSButton {
    enum Look { case accent, quiet, chip }

    private var look: Look = .quiet
    private var text: String = ""
    /// Drawn to the left of the text, or alone when there is none. Retinted on
    /// every `restyle`, because the icon has to go orange with the label when
    /// the control turns on — a template image cannot be tinted after the fact.
    private var icon: LucideIcon?
    var isOn = false { didSet { restyle() } }

    init(
        text: String, icon: LucideIcon? = nil, look: Look, size: CGFloat = 10,
        action: Selector?, target: AnyObject?
    ) {
        super.init(frame: .zero)
        self.look = look
        self.text = text
        self.icon = icon
        self.font = Theme.mono(size, weight: .medium)
        self.isBordered = false
        self.bezelStyle = .shadowlessSquare
        self.wantsLayer = true
        self.layer?.cornerRadius = 0
        self.layer?.borderWidth = 1
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        restyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func setText(_ next: String) {
        text = next
        restyle()
    }

    func setIcon(_ next: LucideIcon?) {
        icon = next
        restyle()
    }

    private func restyle() {
        let ink: NSColor
        let border: NSColor
        switch look {
        case .accent:
            ink = Theme.accent
            border = Theme.accent
        case .quiet:
            ink = isOn ? Theme.accent : Theme.dimText
            border = isOn ? Theme.accent : Theme.laneBorder
        case .chip:
            ink = isOn ? Theme.accent : Theme.dimText
            border = isOn ? Theme.accent : Theme.laneBorder
        }
        layerBorderColor = border
        layerBackgroundColor = isOn ? Theme.accent.withAlphaComponent(0.12) : NSColor.clear
        if let icon {
            image = IconImage.make(icon, points: (font?.pointSize ?? 10) + 2, colour: ink)
            imagePosition = text.isEmpty ? .imageOnly : .imageLeading
            imageHugsTitle = true
        } else {
            image = nil
            imagePosition = .noImage
        }
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .foregroundColor: ink,
                .font: font ?? Theme.mono(10, weight: .medium),
            ])
    }
}

/// One bookmark or folder: `▸ ★ Title …… detail`.
///
/// Two lines would be wrong here in a way they are not for a session. A session
/// row earns its 40 points because it carries a state, a chip, a throughput
/// badge and an age; a bookmark carries a name and an address, and the whole
/// value of a bar is that eight of them fit on screen at once. At 24 points a
/// folder of twenty is one glance.
@MainActor
final class SidebarBookmarkView: NSTableCellView {
    private let triangle = NSImageView()
    private let glyph = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    static let height: CGFloat = 24
    /// How far one level of nesting moves a row. Small on purpose: a sidebar is
    /// 290 pt and the owner's folders hold folders, so a generous indent spends
    /// the width on whitespace and truncates the names it is indenting.
    static let indent: CGFloat = 12

    init(row: SidebarModel.BookmarkRow) {
        super.init(frame: .zero)

        triangle.image = row.isFolder
            ? IconImage.make(row.collapsed ? .chevronRight : .chevronDown,
                             points: 11, colour: Theme.dimText)
            : nil
        triangle.imageScaling = .scaleProportionallyDown

        // A kept page is a star — the same glyph the chrome bar lights and the
        // same one ⌘O prints beside the row. Three surfaces, one mark.
        //
        // A folder gets nothing here, only the triangle. It had a `▸` of its
        // own for one render and the sheet settled it: `▼ ▸ Daily` is two
        // marks for one fact, and the triangle is the one that also says
        // whether the folder is open. The column stays so that a folder's name
        // and a page's name start at the same x.
        glyph.image = row.isFolder
            ? nil
            : IconImage.make(.star, points: 11, colour: Theme.accent)
        glyph.imageScaling = .scaleProportionallyDown

        title.stringValue = row.title
        title.font = Theme.mono(11, weight: row.isFolder ? .bold : .regular)
        title.textColor = .labelColor

        detail.stringValue = row.detail
        detail.font = Theme.mono(9)
        detail.textColor = SidebarInk.gone
        detail.alignment = .right

        for v: NSView in [triangle, glyph] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for label in [title, detail] {
            label.isBezeled = false
            label.drawsBackground = false
            label.usesSingleLineMode = true
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.cell?.truncatesLastVisibleLine = true
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        // Which half gives when the row is too narrow, and it is not the same
        // half for the two kinds of row.
        //
        // A folder's detail is `3 ITEMS` and its title is a name: the count is
        // four characters that must not truncate, and the name is what has room
        // to lose. A page's detail is an address and its title is what the user
        // called it — there, the name is the thing you are reading and the
        // address is the context, so the address gives. Dragged to 260 pt with
        // both set the folder's way, `std` inside `Rust/Standard Library`
        // disappeared entirely under its own URL. The sheet is how that was
        // seen.
        title.setContentCompressionResistancePriority(
            row.isFolder ? .defaultLow : .required, for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        detail.setContentCompressionResistancePriority(
            row.isFolder ? .required : .defaultLow, for: .horizontal)
        detail.setContentHuggingPriority(.required, for: .horizontal)

        let lead = 10 + Self.indent * CGFloat(row.depth)
        NSLayoutConstraint.activate([
            triangle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: lead),
            triangle.widthAnchor.constraint(equalToConstant: 11),
            triangle.heightAnchor.constraint(equalToConstant: 11),
            triangle.centerYAnchor.constraint(equalTo: centerYAnchor),

            glyph.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 2),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 12),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),

            title.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 5),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            detail.leadingAnchor.constraint(
                greaterThanOrEqualTo: title.trailingAnchor, constant: 6),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if row.isFolder {
            // Measured rather than intrinsic. `NSTextField`'s single-line
            // intrinsic width came back a point or two short of what it then
            // drew, so `1 ITEM` rendered as `1 IT…` in a 290 pt sidebar with
            // forty points of empty row beside it — while `3 ITEMS`, longer,
            // fitted. The sheet is how that was seen; `ChromeButton` measures
            // its own glyph for the same reason.
            //
            // Folders only: a page's detail is an address, and pinning that to
            // its full width is what pushed the title out of the row.
            detail.widthAnchor.constraint(
                equalToConstant: ceil(Self.width(of: row.detail)) + 2).isActive = true
        }
        toolTip = row.url ?? row.title
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: Theme.mono(9)]).width
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
