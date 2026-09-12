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
        let x = gesture.location(in: self).x
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

        // The number that actually changes behaviour: an idle agent is usually
        // an agent blocked on a prompt, and the whole point of the strip is
        // noticing that without reading every column.
        let waiting = running.filter { $0.state == .idle || $0.state == .done }.count
        if waiting > 0 {
            attention.stringValue = "\(waiting) waiting"
            attention.textColor = Theme.accent
        } else {
            attention.stringValue = ""
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
