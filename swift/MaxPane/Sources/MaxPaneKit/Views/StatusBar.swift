import AppKit
import LanedCore

/// The strip's footer: what exists, what it is doing, and how to get help.
///
/// The RelayTTY web app puts `10 sessions` in its toolbar and `v1.21.0` at the
/// foot of its sidebar, and both earn their space — with ten agents running, the
/// first question is always "how many, and are any of them waiting for me?"
/// Max Pane had no answer to either.
///
/// Deliberately a footer rather than a toolbar: the strip is the interface and a
/// chrome bar across the top would eat the lane headers' room.
@MainActor
public final class StatusBar: NSView {
    private let profile = NSTextField(labelWithString: "")
    private let lanes = NSTextField(labelWithString: "")
    private let sessions = NSTextField(labelWithString: "")
    private let attention = PulseLabel(labelWithString: "")

    /// The sessions readout as drawn, for tests.
    var sessionsText: String { sessions.stringValue }
    var attentionText: String { attention.stringValue }

    /// Whether the attention count is breathing right now, for tests.
    var isAttentionPulsing: Bool { attention.isAnimatingPulse }
    /// The attention count, for ⌥⌘J's list to hang from — while it is
    /// showing anything, since a popup hung from an empty label hangs from
    /// nothing anyone can see.
    var attentionAnchor: NSView? { attention.stringValue.isEmpty ? nil : attention }
    /// How many panes are making sound: the speaker and a count, and nothing
    /// at all while it is none. A click mutes every one of them.
    private let soundIcon = NSImageView()
    private let sound = NSTextField(labelWithString: "")
    private let soundGroup = NSStackView()
    /// The count as drawn, for tests; empty while nothing is audible.
    var soundText: String { soundShown ? sound.stringValue : "" }
    private var soundShown = false
    public var onClickSound: (() -> Void)?
    /// `↻ v0.8.0` while a newer release is out (ADR-0038): at the right,
    /// where Omarchy's bar puts its circle arrow, and nothing at all
    /// otherwise. A click runs Help › Update…. In the accent, like the
    /// corner's `+N`: news about the build, not a state of anything.
    private let updateLabel = NSTextField(labelWithString: "")
    private var updateShown = false
    /// The `↻` as drawn, for tests; empty while there is no release to name.
    var updateText: String { updateShown ? updateLabel.stringValue : "" }
    var updateTooltip: String? { updateLabel.toolTip }
    public var onClickUpdate: (() -> Void)?
    private let memory = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    public var onClickSessions: (() -> Void)?
    public var onClickMemory: (() -> Void)?
    public var onToggleSidebar: (() -> Void)?

    /// Scroll to the next lane whose page has stopped to ask something. The one
    /// way to reach a dialog in a lane that is off screen — see `WebAskCenter`
    /// for why nothing scrolls there on its own.
    ///
    /// Also what a click on `N BLOCKED` runs, when no page is asking: the
    /// receiver tries the asking pages first and the blocked agents second.
    public var onClickAsking: (() -> Void)?

    /// The one control that has to be reachable while the thing it controls is
    /// hidden, which is why it lives in the footer and not in the sidebar.
    private let sidebarToggle = NSButton()

    public static let height: CGFloat = 24

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerBackgroundColor = Theme.laneBackground

        sidebarToggle.isBordered = false
        sidebarToggle.bezelStyle = .inline
        sidebarToggle.target = self
        sidebarToggle.action = #selector(toggleSidebar)
        sidebarToggle.setButtonType(.momentaryChange)
        sidebarToggle.translatesAutoresizingMaskIntoConstraints = false
        // A glyph this size is an 11×14pt target, which is smaller than the
        // pointer that has to find it. Widened deliberately rather than by
        // padding the hit test, so what is clickable is what is drawn.
        NSLayoutConstraint.activate([
            sidebarToggle.widthAnchor.constraint(equalToConstant: 26),
            sidebarToggle.heightAnchor.constraint(equalToConstant: 20),
        ])
        setSidebarOpen(true)

        // Held rather than looked up by index: the hugging priority below is
        // what pushes the right-hand group to the edge, and an index into
        // `row.views` silently starts pointing at a readout the moment anything
        // is inserted before it.
        let spacer = NSView()
        soundIcon.image = IconImage.make(.volume2, points: 12, colour: Theme.dimText)
        soundIcon.imageScaling = .scaleNone
        soundGroup.setViews([soundIcon, sound], in: .leading)
        soundGroup.orientation = .horizontal
        soundGroup.spacing = 3
        soundGroup.alignment = .centerY
        soundGroup.isHidden = true
        soundGroup.alphaValue = 0
        updateLabel.isHidden = true
        updateLabel.alphaValue = 0
        let row = NSStackView(views: [sidebarToggle, profile, lanes, sessions, attention, soundGroup, spacer, updateLabel, memory, hint])
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The spacer view is what pushes the right-hand group to the edge.
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        for field in [profile, lanes, sessions, attention, sound, updateLabel, memory, hint] {
            field.font = Theme.mono(10)
            field.textColor = Theme.dimText
        }
        updateLabel.font = Theme.mono(10, weight: .bold)
        updateLabel.textColor = Theme.accent
        hint.stringValue = "⌘/ shortcuts"
        setProfile(Profile.current)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A hairline above, so the footer reads as chrome rather than as content.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: bounds.height - Theme.borderWidth, width: bounds.width, height: Theme.borderWidth).fill()
    }

    /// Name the profile, unless it is the default one.
    ///
    /// Silent for the default because that is where the work happens and a
    /// permanent `default` chip would be read once and then never again. Loud
    /// for anything else, because two identical windows is how agents drove the
    /// wrong instance three times in one afternoon — and the one being driven
    /// is exactly the one that is not the default.
    public func setProfile(_ profile: Profile) {
        self.profile.stringValue = profile.isDefault ? "" : "$ \(profile.name)"
        self.profile.textColor = Theme.accent
        self.profile.toolTip = profile.isDefault
            ? nil
            : "This window is the \"\(profile.name)\" profile — its own strip, config and logins"
    }

    /// Filled when the sidebar is showing, hollow when it is not — the glyph
    /// says what is there rather than what pressing it will do, because a
    /// button labelled with its own action reads backwards once it is toggled.
    public func setSidebarOpen(_ open: Bool) {
        sidebarToggle.image = IconImage.make(
            open ? .panelLeftClose : .panelLeft, points: 13, colour: Theme.dimText)
        sidebarToggle.imagePosition = .imageOnly
        sidebarToggle.attributedTitle = NSAttributedString(string: "")
        sidebarToggle.toolTip = (open ? "Hide" : "Show") + " the session sidebar (⌘B)"
    }

    @objc private func toggleSidebar() { onToggleSidebar?() }

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        // This gesture is on the whole footer, so it sees the press before the
        // button does and the button's own action never runs. Rather than fight
        // that, the footer dispatches it — the button is then there for its
        // look, its tooltip and its accessibility, not for its target.
        //
        // The rect has to be converted, not read: `frame` is in the stack
        // view's coordinates and `point` is in the footer's, and comparing them
        // directly silently opens the session picker instead, which is exactly
        // what it did.
        let button = sidebarToggle.convert(sidebarToggle.bounds, to: self)
        if button.insetBy(dx: -6, dy: -6).contains(point) {
            onToggleSidebar?()
            return
        }
        // The asking count is a target before it is a readout, so it is hit
        // tested against its own frame rather than against a fraction of the
        // bar: it is the only way to reach a dialog in a lane you cannot see,
        // and "roughly the left third" is not good enough for that.
        if isAlarmed, attention.convert(attention.bounds, to: self).insetBy(dx: -6, dy: -4).contains(point) {
            onClickAsking?()
            return
        }
        if soundShown, soundGroup.convert(soundGroup.bounds, to: self).insetBy(dx: -6, dy: -4).contains(point) {
            onClickSound?()
            return
        }
        if updateShown, updateLabel.convert(updateLabel.bounds, to: self).insetBy(dx: -6, dy: -4).contains(point) {
            onClickUpdate?()
            return
        }
        // The right-hand third is the memory readout; the rest is sessions.
        if point.x > bounds.width * 0.7 { onClickMemory?() } else { onClickSessions?() }
    }

    /// True while the attention field is showing pages waiting on a person, as
    /// opposed to blocked agents or nothing at all.
    private var isAsking = false
    /// True while it is showing either alarm. Both are a place to go: a
    /// BLOCKED agent may be in a lane a folded sidebar group is hiding, and
    /// the count is then the one thing on screen that leads to it.
    private var isAlarmed = false
    /// The lanes readout as drawn, for tests.
    var lanesText: String { lanes.stringValue }

    public func update(state: StripState, telemetry: [SessionKey: SessionTelemetry], webBytes: UInt64) {
        update(state: state, telemetry: telemetry, webBytes: webBytes, asking: 0)
    }

    /// `asking` is how many web panes have a dialog on screen waiting for an
    /// answer. It shares the attention column with BLOCKED because they are the
    /// same sentence — *something has stopped and is waiting on you* — and two
    /// separate bright counts would each be half as loud. So they share one ink,
    /// the blocked green, and one breath.
    public func update(
        state: StripState, telemetry: [SessionKey: SessionTelemetry], webBytes: UInt64, asking: Int
    ) {
        let laneCount = state.lanes.count
        let paneCount = state.lanes.reduce(0) { $0 + $1.panes.count }
        // Lanes a folded sidebar group is keeping off the strip (ADR-0024).
        // Said here because this line is on screen whatever the sidebar is
        // doing, including shut: a strip that is short of lanes always says
        // so, and how many.
        let hidden = state.hiddenLaneIds.count
        let shown = (laneCount == paneCount
            ? "\(laneCount) lane\(laneCount == 1 ? "" : "s")"
            : "\(laneCount) lanes · \(paneCount) panes")
            + (hidden > 0 ? " · \(hidden) hidden" : "")
        // Into or out of "hidden" is a change of meaning in place; ease it.
        if (hidden > 0) != lanes.stringValue.contains("hidden"), !lanes.stringValue.isEmpty {
            Motion.fade(lanes.layer)
        }
        lanes.stringValue = shown
        lanes.toolTip = hidden > 0
            ? "\(hidden) lane\(hidden == 1 ? " is" : "s are") in a collapsed sidebar group, still running. Expand the group to bring \(hidden == 1 ? "it" : "them") back."
            : nil

        let running = telemetry.values.filter(\.isRunning)
        // Sessions on a server that is not answering are still sessions, and
        // are said to be what they are: nobody can vouch for them. Their
        // BLOCKED and WORKING are not counted below — `state` is `.unknown`
        // while offline — so the alarm never points at a prompt that cannot
        // be answered (ADR-0023).
        let offline = running.filter(\.isOffline).count
        sessions.stringValue = "\(running.count) session\(running.count == 1 ? "" : "s")"
            + (offline > 0 ? " · \(offline) offline" : "")

        // The number that actually changes behaviour. Not "idle" — idle is the
        // resting state of every session and counting it would light this up
        // permanently. `blocked` means pty-host found a prompt in the terminal's
        // tail: the agent has stopped and is waiting on a person.
        let blocked = running.filter(\.needsAttention).count
        isAsking = asking > 0
        // ASKING leads when both are true. A blocked agent is waiting on a
        // decision you can take your time over; a page waiting on `confirm()`
        // has stopped its own JavaScript, and every second it waits is a second
        // the site looks broken.
        var parts: [String] = []
        if asking > 0 { parts.append("\(asking) ASKING") }
        if blocked > 0 { parts.append("\(blocked) BLOCKED") }
        let alarmed = !parts.isEmpty
        isAlarmed = alarmed
        // Into or out of the alarm is a change of meaning in place; ease it.
        if alarmed != (attention.isPulsing) { Motion.fade(attention.layer) }
        if alarmed {
            attention.stringValue = parts.joined(separator: " · ")
            attention.textColor = Theme.blocked
            attention.toolTip = asking > 0
                ? "Click to go to the page that is asking"
                : "Click to go to the agent that is waiting"
        } else {
            let working = running.filter { $0.state == .working }.count
            attention.stringValue = working > 0 ? "\(working) working" : ""
            attention.textColor = Theme.dimText
            attention.toolTip = nil
        }
        attention.isPulsing = alarmed

        memory.stringValue = webBytes > 0 ? "web \(Self.mb(webBytes))" : ""

        if let filter = state.gatherFilter {
            hint.stringValue = "gathered: \((filter as NSString).lastPathComponent) — esc to leave"
            hint.textColor = Theme.accent
        } else {
            hint.stringValue = "⌘/ shortcuts"
            hint.textColor = Theme.dimText
        }
    }

    /// How many panes are audible. The glyph is the app's speaker, grey like
    /// the readouts beside it: sound is not state, and gets no state colour.
    /// Arrives and leaves with a fade; the count changing is just a number.
    public func setAudible(_ count: Int) {
        if count > 0 { sound.stringValue = "\(count)" }
        soundGroup.toolTip = count > 0
            ? "\(count) pane\(count == 1 ? " is" : "s are") making sound. Click to mute \(count == 1 ? "it" : "them all")."
            : nil
        guard (count > 0) != soundShown else { return }
        soundShown = count > 0
        let shown = soundShown
        if shown { soundGroup.isHidden = false }
        // Nothing to ease in a bar nobody can see yet.
        guard window != nil else {
            soundGroup.alphaValue = shown ? 1 : 0
            soundGroup.isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.isReduced ? 0 : Motion.pane
            context.timingFunction = Motion.easeOutTiming
            soundGroup.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.soundShown else { return }
                self.soundGroup.isHidden = true
            }
        })
    }

    /// A newer release, or nil when there is none to name. Arrives and
    /// leaves with a fade, like the speaker; the text changing (a second
    /// release before the first was taken) is just text.
    public func setUpdate(_ text: String?, tooltip: String?) {
        if let text { updateLabel.stringValue = text }
        updateLabel.toolTip = tooltip
        guard (text != nil) != updateShown else { return }
        updateShown = text != nil
        let shown = updateShown
        if shown { updateLabel.isHidden = false }
        guard window != nil else {
            updateLabel.alphaValue = shown ? 1 : 0
            updateLabel.isHidden = !shown
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.isReduced ? 0 : Motion.pane
            context.timingFunction = Motion.easeOutTiming
            updateLabel.animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.updateShown else { return }
                self.updateLabel.isHidden = true
            }
        })
    }

    static func mb(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
    }
}
