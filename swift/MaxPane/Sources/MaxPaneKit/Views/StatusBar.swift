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
    private let lanes = NSTextField(labelWithString: "")
    private let sessions = NSTextField(labelWithString: "")
    private let attention = NSTextField(labelWithString: "")
    private let memory = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "")

    public var onClickSessions: (() -> Void)?
    public var onClickMemory: (() -> Void)?
    /// Scroll to the next lane whose page has stopped to ask something. The one
    /// way to reach a dialog in a lane that is off screen — see `WebAskCenter`
    /// for why nothing scrolls there on its own.
    public var onClickAsking: (() -> Void)?

    public static let height: CGFloat = 24

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.laneBackground.cgColor

        let row = NSStackView(views: [lanes, sessions, attention, NSView(), memory, hint])
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
        row.views[3].setContentHuggingPriority(.init(1), for: .horizontal)

        for field in [lanes, sessions, attention, memory, hint] {
            field.font = Theme.mono(10)
            field.textColor = Theme.dimText
        }
        hint.stringValue = "⌘/ shortcuts"

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

    @objc private func clicked(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: self)
        // The asking count is a target before it is a readout, so it is hit
        // tested against its own frame rather than against a fraction of the
        // bar: it is the only way to reach a dialog in a lane you cannot see,
        // and "roughly the left third" is not good enough for that.
        if isAsking, attention.frame.insetBy(dx: -6, dy: -4).contains(point) {
            onClickAsking?()
            return
        }
        // The right-hand third is the memory readout; the rest is sessions.
        if point.x > bounds.width * 0.7 { onClickMemory?() } else { onClickSessions?() }
    }

    /// True while the attention field is showing pages waiting on a person, as
    /// opposed to blocked agents or nothing at all.
    private var isAsking = false

    public func update(state: StripState, telemetry: [String: SessionTelemetry], webBytes: UInt64) {
        update(state: state, telemetry: telemetry, webBytes: webBytes, asking: 0)
    }

    /// `asking` is how many web panes have a dialog on screen waiting for an
    /// answer. It shares the attention column with BLOCKED because they are the
    /// same sentence — *something has stopped and is waiting on you* — and two
    /// separate orange counts would each be half as loud.
    public func update(
        state: StripState, telemetry: [String: SessionTelemetry], webBytes: UInt64, asking: Int
    ) {
        let laneCount = state.lanes.count
        let paneCount = state.lanes.reduce(0) { $0 + $1.panes.count }
        lanes.stringValue = laneCount == paneCount
            ? "\(laneCount) lane\(laneCount == 1 ? "" : "s")"
            : "\(laneCount) lanes · \(paneCount) panes"

        let running = telemetry.values.filter(\.isRunning)
        sessions.stringValue = "\(running.count) session\(running.count == 1 ? "" : "s")"

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
        if !parts.isEmpty {
            attention.stringValue = parts.joined(separator: " · ")
            attention.textColor = Theme.accent
            attention.toolTip = asking > 0 ? "Click to go to the page that is asking" : nil
        } else {
            let working = running.filter { $0.state == .working }.count
            attention.stringValue = working > 0 ? "\(working) working" : ""
            attention.textColor = Theme.dimText
            attention.toolTip = nil
        }

        memory.stringValue = webBytes > 0 ? "web \(Self.mb(webBytes))" : ""

        if let filter = state.gatherFilter {
            hint.stringValue = "gathered: \((filter as NSString).lastPathComponent) — esc to leave"
            hint.textColor = Theme.accent
        } else {
            hint.stringValue = "⌘/ shortcuts"
            hint.textColor = Theme.dimText
        }
    }

    static func mb(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
    }
}
