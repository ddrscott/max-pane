import AppKit
import LanedCore

/// The sidebar's ink beyond `Theme`'s greens.
///
/// Status is not decoration, so it gets colour — but only the green family and
/// grey: the brightest, filled and pulsing for "blocked on you", muted green for
/// "working right now", a quieter green for "alive", grey for "gone". Anything
/// else would make the greens stop meaning anything.
enum SidebarInk {
    /// Alive and quiet. Quieter than `Theme.working`, so a session that is
    /// actually producing output still reads louder.
    static let live = Theme.alive
    /// The throughput readout. Green only while bytes are moving.
    static let flow = Theme.working
    static let gone = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 1)
            : NSColor(white: 0.60, alpha: 1)
    }
    static let hover = NSColor(white: 0.5, alpha: 0.10)
    static let selection = Theme.accent.withAlphaComponent(0.16)
}

/// Square selection, square hover, and a hard accent edge on the selected row.
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
    private let chip = PulseLabel(labelWithString: "")
    /// Which server, on a remote session's row: the square in that server's
    /// colour, and no name — the row is already under `// WSL` (ADR-0025).
    /// Nil on a local row, which is then laid out exactly as it was before
    /// servers existed.
    private var serverMark: ServerMark?
    /// The speaker, in the status square's slot while the row's lane is
    /// audible or muted: the owner's design (ADR-0035). Click mutes without
    /// selecting the row; right-click is the volume slider, not the row's menu.
    let speaker = SpeakerMark(points: 12)
    /// Set by the sidebar, which knows the lane.
    var onToggleMute: (() -> Void)? {
        get { speaker.onToggle }
        set { speaker.onToggle = newValue }
    }
    var onVolume: ((SpeakerMark) -> Void)? {
        get { speaker.onVolume }
        set { speaker.onVolume = newValue }
    }
    /// Whether the leading square is drawn, for tests: it is, exactly while
    /// the speaker is not.
    var showsStatusSquare: Bool { !status.isHidden }

    /// The row never names its server; the section above it does. For tests.
    var serverChipText: String? { nil }
    /// The server whose square the row carries, its colour, and whether it
    /// is hollow; nil when the row has none. For tests.
    var serverMarkServer: String? { serverMark?.server }
    var serverMarkColour: ServerColour? { serverMark?.colour }
    var serverMarkIsHollow: Bool? { serverMark?.isHollow }
    /// The badge as drawn, for tests.
    var badgeText: String { badge.stringValue }

    /// Whether this row's BLOCKED chip is breathing right now, for tests.
    var isBlockedMarkPulsing: Bool { chip.isAnimatingPulse }

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
        // An offline session is not known to be running, so its square is
        // hollow with the dead ones: the shape must not claim what the
        // server cannot confirm.
        if entry.isRunning && !isWeb && !entry.offline {
            status.layerBackgroundColor = tint
        } else {
            status.layer?.borderWidth = 1
            status.layerBorderColor = tint
        }

        // Sound takes the square's place, in the square's slot, so the row's
        // grid does not move; silent, the square is back.
        speaker.mark = entry.audio
        status.isHidden = entry.audio != .silent

        // Kind first, then state: a terminal, a page, or a session that is not
        // on the strip yet. The icon takes the state's colour along with the
        // square, so a row's left edge is one mark in one colour: grey at
        // rest, green working, orange done. A lane whose session has died, or
        // a session not on the strip yet, is grey with the rest of the row.
        let markerInk = (attached && entry.isRunning && !isWeb) ? tint : SidebarInk.gone
        let markerIsFor: LucideIcon = isWeb ? .globe : (attached ? .squareTerminal : .plus)
        markerIcon.image = IconImage.make(markerIsFor, points: 12, colour: markerInk)
        markerIcon.imageScaling = .scaleProportionallyDown

        glyph.stringValue = isWeb ? "" : entry.glyph
        glyph.font = Theme.mono(11, weight: entry.needsAttention ? .bold : .regular)
        glyph.textColor = Self.ink(entry.state)
        glyph.alignment = .center

        // The chip only exists for the states worth interrupting someone for —
        // blocked, done. A busy agent shows nothing here, which is
        // exactly what makes the chips that do appear worth looking at.
        let chipInk = Theme.agentStateColor(entry.state)
        chip.stringValue = entry.chip.isEmpty ? "" : " \(entry.chip) "
        chip.font = Theme.mono(8, weight: entry.needsAttention ? .bold : .medium)
        chip.textColor = entry.needsAttention ? Theme.onBlocked : chipInk
        chip.wantsLayer = true
        // Square, like RelayTTY's own chip and like everything else here.
        chip.layer?.cornerRadius = 0
        chip.layer?.borderWidth = entry.chip.isEmpty ? 0 : 1
        chip.layerBorderColor = chipInk
        // BLOCKED is the only chip that gets filled — solid, in the brightest
        // green, and breathing. It is the one signal the eye has to find across
        // ten rows without reading any of them, and in a family of greens the
        // fill and the movement are what keep it from being one more green word.
        chip.layerBackgroundColor = entry.needsAttention ? chipInk : NSColor.clear
        chip.isPulsing = entry.needsAttention

        title.attributedStringValue = Self.titleText(entry)

        badge.stringValue = entry.badge.uppercased()
        badge.font = Theme.mono(10, weight: entry.badgeIsThroughput ? .medium : .regular)
        badge.textColor = Self.badgeInk(entry)
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
        for v: NSView in [status, markerIcon, glyph, title, badge, age, chip, speaker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        // The server's square leads the second line, under the start of the
        // title, where the grey name chip was: the row keeps its grid, the
        // title keeps every character and the state text on the right is not
        // pushed. It sits apart from the status square on purpose — that one
        // is state and stays green or grey. Hollow while the server is not
        // answering. The state chip follows it.
        if let server = entry.server {
            let made = ServerMark(server: server, side: 8, offline: entry.offline)
            addSubview(made)
            serverMark = made
        }

        NSLayoutConstraint.activate([
            status.widthAnchor.constraint(equalToConstant: 7),
            status.heightAnchor.constraint(equalToConstant: 7),
            status.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            status.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            // Centred on the square it replaces, and padded to a target a
            // pointer can find: the glyph is 12 pt, the box 18.
            speaker.centerXAnchor.constraint(equalTo: status.centerXAnchor),
            speaker.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            speaker.widthAnchor.constraint(equalToConstant: SpeakerMark.minimumHit),
            speaker.heightAnchor.constraint(equalToConstant: SpeakerMark.minimumHit),

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

            chip.leadingAnchor.constraint(
                equalTo: serverMark?.trailingAnchor ?? title.leadingAnchor, constant: serverMark == nil ? 0 : 5),
            chip.centerYAnchor.constraint(equalTo: age.centerYAnchor),
            chip.trailingAnchor.constraint(lessThanOrEqualTo: age.leadingAnchor, constant: -6),
        ])
        if let serverMark {
            NSLayoutConstraint.activate([
                serverMark.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                serverMark.centerYAnchor.constraint(equalTo: age.centerYAnchor),
                serverMark.widthAnchor.constraint(equalToConstant: serverMark.side),
                serverMark.heightAnchor.constraint(equalToConstant: serverMark.side),
            ])
        }
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
        // Offline drops with the dead ones to the at-rest grey: the row is
        // still there to be found, and visibly not live.
        let colour: NSColor = (entry.isRunning && !entry.offline) ? .labelColor : SidebarInk.gone
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
    ///
    /// Colour is for a change of state and nothing else. A column of sessions
    /// that are merely alive used to be a column of green squares, which is
    /// the same as no green at all; at rest a row is grey, and the eye goes to
    /// the few that are not.
    private static func statusColor(_ entry: SidebarModel.Entry) -> NSColor {
        guard entry.isRunning, !entry.offline else { return SidebarInk.gone }
        switch entry.kind {
        case .web, .placeholder: return SidebarInk.gone
        case .session:
            switch entry.state {
            case .blocked: return Theme.blocked
            case .working: return Theme.working
            case .done: return Theme.done
            case .idle, .unknown, .exited: return SidebarInk.gone
            }
        }
    }

    /// Green only while the session is working and bytes are moving; dim
    /// otherwise. `badgeIsThroughput` already requires both.
    static func badgeInk(_ entry: SidebarModel.Entry) -> NSColor {
        entry.badgeIsThroughput ? SidebarInk.flow : Theme.dimText
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
///
/// Folded, the header carries what its rows would have said (ADR-0024,
/// amended): `1 BLOCKED · 2 DONE · 3 LANES HIDDEN`, loudest first, each in the
/// row's own colour, and the triangle takes the brightest of them. A fold
/// changes how much room a project takes, not what you can see.
final class SidebarGroupView: NSTableCellView {
    private let triangle = PulseImageView()
    private let label = NSTextField(labelWithString: "")
    /// The right-hand slot: BLOCKED, DONE, WORKING, then the grey count, as
    /// one label each so BLOCKED can breathe on its own. `count` is the
    /// tail, and on an open header the whole of it.
    private let blockedCount = PulseLabel(labelWithString: "")
    private let doneCount = NSTextField(labelWithString: "")
    private let workingCount = NSTextField(labelWithString: "")
    private let count = PulseLabel(labelWithString: "")
    private let slot = NSStackView()
    private let rule = NSView()
    /// A server's state when it is anything but connected, as a chip.
    private let stateChip = NSTextField(labelWithString: "")
    /// Whether the grey tail has anything in front of it, so `layout` knows
    /// there is something to keep when the width runs out.
    private let hasStates: Bool

    /// The header as drawn, for tests.
    var labelText: String { label.stringValue }
    /// The colour of a server section's `//`; nil for `// LOCAL` (the accent
    /// green) and for a path group (no slashes).
    private(set) var slashColour: ServerColour?
    var stateChipText: String { stateChip.isHidden ? "" : stateChip.stringValue.trimmingCharacters(in: .whitespaces) }

    static let height: CGFloat = 26
    /// How far in from the left a click still counts as on the triangle: the
    /// triangle, its inset, and the gap after it. Only a server's header asks,
    /// because only there does the rest of the row do something else.
    static let triangleReach: CGFloat = 24
    /// The least of the path the roll-up may leave on screen before its grey
    /// tail is dropped: `…/PANE` and a little.
    static let leastLabel: CGFloat = 44
    /// A folded header's speaker: something it is hiding is making sound.
    /// Click mutes all of it. No slider: that is one pane's business.
    let speaker = SpeakerMark(points: 11)
    var blockedText: String { blockedCount.isHidden ? "" : blockedCount.stringValue }
    var doneText: String { doneCount.isHidden ? "" : Self.plain(doneCount) }
    var workingText: String { workingCount.isHidden ? "" : Self.plain(workingCount) }
    var countText: String { Self.plain(count) }
    /// The segments on screen after layout, in order, for tests: the tail
    /// is the first to go when the header is short of room.
    var shownRollUp: [String] {
        [blockedCount, doneCount, workingCount, count].filter { !$0.isHidden }.map(Self.plain)
    }
    var isBlockedPulsing: Bool { blockedCount.isPulsing || count.isPulsing }
    /// The triangle's colour and breath, for tests.
    var isMarkPulsing: Bool { triangle.isPulsing }
    private(set) var markColour: NSColor = Theme.dimText
    var hasTriangle: Bool { !triangle.isHidden }

    /// What a click on the state text goes to.
    enum StateHit: Equatable { case blocked, done }

    /// Which state text, if any, a point in this view's coordinates is on.
    /// The controller asks on a click, so a press on `1 BLOCKED` goes to
    /// that session and a press anywhere else folds or opens the header.
    func stateHit(at point: NSPoint) -> StateHit? {
        if !blockedCount.isHidden, blockedCount.frame.insetBy(dx: -3, dy: -6).contains(convert(point, to: slot)) {
            return .blocked
        }
        if !doneCount.isHidden, doneCount.frame.insetBy(dx: -3, dy: -6).contains(convert(point, to: slot)) {
            return .done
        }
        return nil
    }

    private static func plain(_ field: NSTextField) -> String {
        field.stringValue.replacingOccurrences(of: " · ", with: "")
    }

    init(group: SidebarModel.Group) {
        hasStates = group.rollUp.count > 1
        super.init(frame: .zero)

        // The leading mark, in the brightest state's colour under a folded
        // header — blocked breathing, done orange, working green — and grey
        // otherwise: one mark, one colour, the row's own rule.
        let markState = group.markState
        markColour = markState.map(Theme.agentStateColor) ?? Theme.dimText
        triangle.image = IconImage.make(
            group.collapsed ? .chevronRight : .chevronDown, points: 11, colour: markColour)
        triangle.imageScaling = .scaleProportionallyDown
        triangle.isPulsing = markState == .blocked

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

        // The right-hand slot. An open header is one grey word — or, with an
        // agent in it waiting on you, `N BLOCKED` in the blocked green,
        // breathing. A folded header rolls its rows' states up in front of
        // the grey count, each in the row's own colour, ` · ` between.
        let alarmInCount = group.blocked > 0 && group.blockedText == nil && !group.collapsed
        Self.style(count, text: group.countText, dot: hasStates,
                   colour: alarmInCount ? Theme.blocked : Theme.dimText, weight: alarmInCount ? .bold : .regular)
        count.isPulsing = alarmInCount
        count.toolTip = nil

        blockedCount.isHidden = group.blockedText == nil
        Self.style(blockedCount, text: group.blockedText ?? "", dot: false, colour: Theme.blocked, weight: .bold)
        blockedCount.isPulsing = group.blockedText != nil
        blockedCount.toolTip = group.blocked == 1 ? "Go to the blocked session" : "Go to the first blocked session"

        doneCount.isHidden = group.doneText == nil
        Self.style(doneCount, text: group.doneText ?? "", dot: group.blockedText != nil, colour: Theme.done, weight: .bold)
        doneCount.toolTip = group.done == 1 ? "Go to the finished session" : "Go to the first finished session"

        workingCount.isHidden = group.workingText == nil
        Self.style(workingCount, text: group.workingText ?? "", dot: group.blockedText != nil || group.doneText != nil,
                   colour: Theme.working, weight: .medium)

        // A hairline above the header instead of padding: the strip is made of
        // hard edges, and so is its index.
        rule.wantsLayer = true
        rule.layerBackgroundColor = Theme.laneBorder

        for v in [label, count, blockedCount, doneCount, workingCount] {
            v.isBezeled = false
            v.drawsBackground = false
            v.usesSingleLineMode = true
            v.maximumNumberOfLines = 1
        }
        // Set after `usesSingleLineMode`, which would otherwise reset it.
        label.lineBreakMode = .byTruncatingHead
        slot.orientation = .horizontal
        slot.alignment = .centerY
        slot.spacing = 0
        slot.detachesHiddenViews = true
        for v in [blockedCount, doneCount, workingCount, count] { slot.addArrangedSubview(v) }
        for v: NSView in [triangle, label, slot, rule, speaker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        speaker.mark = group.audibleLanes.isEmpty ? .silent : .audible
        speaker.toolTip = group.audibleLanes.isEmpty ? nil
            : "Mute the \(group.audibleLanes.count == 1 ? "lane" : "\(group.audibleLanes.count) lanes") making sound under this header"

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

            // Left of the state text, as the owner asked (ADR-0035).
            speaker.trailingAnchor.constraint(equalTo: slot.leadingAnchor, constant: -4),
            speaker.centerYAnchor.constraint(equalTo: triangle.centerYAnchor),
            speaker.widthAnchor.constraint(equalToConstant: SpeakerMark.minimumHit),
            speaker.heightAnchor.constraint(equalToConstant: SpeakerMark.minimumHit),

            slot.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            slot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            slot.centerYAnchor.constraint(equalTo: triangle.centerYAnchor),
        ])
        // Only while it is there: a silent header's path keeps every point.
        if !group.audibleLanes.isEmpty {
            label.trailingAnchor.constraint(lessThanOrEqualTo: speaker.leadingAnchor, constant: -2).isActive = true
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [count, blockedCount, doneCount, workingCount] {
            v.setContentCompressionResistancePriority(.required, for: .horizontal)
            v.setContentHuggingPriority(.required, for: .horizontal)
        }
        slot.setContentCompressionResistancePriority(.required, for: .horizontal)

        toolTip = group.path == SidebarModel.looseWebGroup ? "Web lanes" : group.path

        // A section header — a server's, or `// LOCAL` beside one — heads a
        // block of project groups, so this Mac and each server read as
        // separate, parallel blocks. It gets the house `// CAPS` mark the
        // path groups deliberately do not: it is a name, not a path, so the
        // slashes cannot be misread as one. It folds every project under
        // it, so it has the triangle the projects have (ADR-0024).
        //
        // A server's state, when it is anything but connected, is a chip in
        // the accent green beside the count — a state, in the family every
        // state uses, outlined and still because filled and moving are
        // BLOCKED's alone — with the last error as the tooltip. A click
        // opens Settings › Servers.
        stateChip.isHidden = true
        if group.isSection {
            // A server's slashes are in that server's colour (ADR-0025): the
            // header is where the colour is introduced, beside the name it
            // stands for on every row below. `// LOCAL` has no colour and
            // keeps the accent green. The name and the state chip are as
            // they were: the chip is state, and state is green.
            let slashes = group.server.map { Theme.server(ServerColours.colour(of: $0)) } ?? Theme.accent
            slashColour = group.server.map(ServerColours.colour(of:))
            let mark = NSMutableAttributedString(
                string: "// ",
                attributes: [.foregroundColor: slashes, .font: Theme.mono(10, weight: .bold)])
            mark.append(NSAttributedString(
                string: group.header,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Theme.mono(10, weight: .bold)]))
            label.attributedStringValue = mark
            label.lineBreakMode = .byTruncatingTail
            let fold = group.collapsed ? "the triangle opens it" : "the triangle folds it"
            toolTip = group.isLocalSection
                ? "This Mac — \(group.rollUpText.lowercased()); click to \(group.collapsed ? "open" : "fold") it"
                : "\(group.server ?? group.header) — \(group.rollUpText.lowercased()); click for Settings › Servers, \(fold)"
        }
        if group.hiddenLanes > 0 {
            toolTip = (toolTip ?? "") + " — \(group.hiddenLanes) lane\(group.hiddenLanes == 1 ? "" : "s") off the strip, still running; open this to bring \(group.hiddenLanes == 1 ? "it" : "them") back"
        }
        if let state = group.stateChip {
            stateChip.isHidden = false
            stateChip.stringValue = " \(state) "
            stateChip.font = Theme.mono(8, weight: .bold)
            stateChip.textColor = Theme.accent
            stateChip.isBezeled = false
            stateChip.drawsBackground = false
            stateChip.wantsLayer = true
            stateChip.layer?.cornerRadius = 0
            stateChip.layer?.borderWidth = 1
            stateChip.layerBorderColor = Theme.accent.withAlphaComponent(0.6)
            stateChip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stateChip)
            NSLayoutConstraint.activate([
                stateChip.trailingAnchor.constraint(equalTo: slot.leadingAnchor, constant: -6),
                stateChip.centerYAnchor.constraint(equalTo: count.centerYAnchor),
                stateChip.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
            ])
            stateChip.setContentCompressionResistancePriority(.required, for: .horizontal)
            let why = group.serverError ?? state.lowercased()
            toolTip = "\(group.server ?? group.header) — \(why); click for Settings › Servers"
        }
    }

    /// One segment of the slot: the text, a dim ` · ` in front of it when
    /// something precedes it, in one colour and weight.
    private static func style(_ field: NSTextField, text: String, dot: Bool, colour: NSColor, weight: NSFont.Weight) {
        let out = NSMutableAttributedString()
        // An absent segment is empty, dot and all: `layout` reads emptiness
        // as absence.
        if dot, !text.isEmpty {
            out.append(NSAttributedString(
                string: " · ", attributes: [.foregroundColor: Theme.dimText, .font: Theme.mono(9)]))
        }
        out.append(NSAttributedString(
            string: text, attributes: [.foregroundColor: colour, .font: Theme.mono(9, weight: weight)]))
        field.attributedStringValue = out
        field.alignment = .right
    }

    /// The grey tail goes first when the width runs out, then the quietest
    /// state, so what is left is always the loudest thing under the fold. A
    /// truncated path is still a path; a truncated `3 LANES H` is nothing.
    /// Decided from what the pieces want, not from where they landed, so
    /// the answer is the same on the pass the hide triggers.
    override func layout() {
        if hasStates {
            let fixed: CGFloat = 7 + 11 + 6 + 6 + 9 + Self.leastLabel
                + (speaker.mark == .silent ? 0 : SpeakerMark.minimumHit + 4)
                + (stateChip.isHidden ? 0 : stateChip.intrinsicContentSize.width + 6)
            // Quietest first; BLOCKED is never dropped.
            let droppable = [count, workingCount, doneCount].filter { $0.attributedStringValue.length > 0 }
            var kept = Set(droppable.map(ObjectIdentifier.init))
            func wanted() -> CGFloat {
                ([blockedCount] + droppable)
                    .filter { $0.attributedStringValue.length > 0 && ($0 === blockedCount || kept.contains(ObjectIdentifier($0))) }
                    .reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            }
            for field in droppable where wanted() + fixed > bounds.width {
                kept.remove(ObjectIdentifier(field))
            }
            for field in droppable {
                let hide = !kept.contains(ObjectIdentifier(field))
                if field.isHidden != hide { field.isHidden = hide }
            }
        }
        super.layout()
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
    /// every `restyle`, because the icon has to go green with the label when
    /// the control turns on — a template image cannot be tinted after the fact.
    private(set) var icon: LucideIcon?
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
