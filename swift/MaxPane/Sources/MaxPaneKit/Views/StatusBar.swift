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
    public var onToggleSidebar: (() -> Void)?

    /// The one control that has to be reachable while the thing it controls is
    /// hidden, which is why it lives in the footer and not in the sidebar.
    private let sidebarToggle = NSButton()

    public static let height: CGFloat = 24

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.laneBackground.cgColor

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

        let row = NSStackView(views: [sidebarToggle, lanes, sessions, attention, NSView(), memory, hint])
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
        row.views[4].setContentHuggingPriority(.init(1), for: .horizontal)

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

    /// Filled when the sidebar is showing, hollow when it is not — the glyph
    /// says what is there rather than what pressing it will do, because a
    /// button labelled with its own action reads backwards once it is toggled.
    public func setSidebarOpen(_ open: Bool) {
        sidebarToggle.attributedTitle = NSAttributedString(
            string: open ? "◧" : "□",
            attributes: [.font: Theme.mono(11), .foregroundColor: Theme.dimText])
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
        let x = point.x
        // The right-hand third is the memory readout; the rest is sessions.
        if x > bounds.width * 0.7 { onClickMemory?() } else { onClickSessions?() }
    }

    public func update(state: StripState, telemetry: [String: SessionTelemetry], webBytes: UInt64) {
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
        if blocked > 0 {
            attention.stringValue = "\(blocked) BLOCKED"
            attention.textColor = Theme.accent
        } else {
            let working = running.filter { $0.state == .working }.count
            attention.stringValue = working > 0 ? "\(working) working" : ""
            attention.textColor = Theme.dimText
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
