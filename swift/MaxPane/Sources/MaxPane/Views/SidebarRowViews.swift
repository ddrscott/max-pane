import AppKit
import LanedCore

/// One lane in the sidebar: kind glyph, title, project tag, live/evicted state,
/// pinned marker (PRD §7.6).
///
/// Laid out by hand rather than with a stack view — this is redrawn for every
/// visible row on every snapshot, and at 150 lanes the constraint solver is not
/// worth inviting.
final class SidebarLaneView: NSTableCellView {
    private let glyph = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let tag = NSTextField(labelWithString: "")
    private let marker = NSTextField(labelWithString: "")

    init(lane: Lane, isLive: Bool) {
        super.init(frame: .zero)

        let kind: PaneGlyph = lane.panes.first.map {
            switch $0.kind {
            case .pty: return .pty
            case .web: return .web
            case .placeholder: return .placeholder
            }
        } ?? .web

        glyph.stringValue = Theme.glyph(for: kind)
        glyph.font = Theme.mono(12, weight: .medium)
        // The orange $ is the live-terminal marker; everything else stays quiet.
        glyph.textColor = (kind == .pty && isLive) ? Theme.accent : Theme.dimText
        glyph.alignment = .center

        title.stringValue = lane.title ?? lane.panes.first?.url.map(Self.hostOf) ?? "untitled"
        title.font = Theme.mono(12)
        title.lineBreakMode = .byTruncatingTail
        title.textColor = isLive ? .labelColor : Theme.dimText

        tag.stringValue = lane.projectRoot.map { ($0 as NSString).lastPathComponent } ?? ""
        tag.font = Theme.mono(10)
        tag.textColor = Theme.dimText
        tag.alignment = .right
        tag.lineBreakMode = .byTruncatingHead

        marker.stringValue = lane.pinned ? "▪" : ""
        marker.font = Theme.mono(10)
        marker.textColor = Theme.accent

        for v in [glyph, title, tag, marker] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.isBezeled = false
            v.drawsBackground = false
            addSubview(v)
        }

        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 14),

            marker.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 2),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 8),

            title.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 4),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),

            tag.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 8),
            tag.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tag.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // The tag yields before the title does when the sidebar is narrow.
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tag.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// A web lane with no title is best identified by its host, not its full URL.
    static func hostOf(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }
}

/// A `// PROJECT` header, shown only past 50 lanes.
final class SidebarGroupView: NSTableCellView {
    init(label: String, count: Int) {
        super.init(frame: .zero)
        let text = NSTextField(labelWithString: "")
        let attributed = NSMutableAttributedString(
            string: "// ",
            attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(10, weight: .bold)])
        attributed.append(NSAttributedString(
            string: "\(label.uppercased())  \(count)",
            attributes: [.foregroundColor: Theme.dimText, .font: Theme.mono(10, weight: .bold)]))
        text.attributedStringValue = attributed
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}
