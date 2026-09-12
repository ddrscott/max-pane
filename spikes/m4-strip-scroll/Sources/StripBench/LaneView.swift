import AppKit

/// Cheap stand-in for a real lane: layer-backed column with a header label,
/// a project-tag chip and N text rows. NOT a WebKit view (that is spike M1).
final class LaneView: NSView {

    static let signalOrange = NSColor(srgbRed: 0xE8 / 255.0, green: 0x5D / 255.0, blue: 0x00 / 255.0, alpha: 1)
    static let rowsPerLane = 12

    private let header = NSTextField(labelWithString: "")
    private let chip = NSView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let promptMark = NSTextField(labelWithString: "$")
    private var rows: [NSTextField] = []

    private(set) var laneIndex: Int = -1

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 1000))
        Counters.laneInstantiations += 1

        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.078, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 0.20, alpha: 1).cgColor
        layer?.cornerRadius = 0   // square corners, per house style

        header.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        header.textColor = .white
        header.lineBreakMode = .byTruncatingTail
        addSubview(header)

        promptMark.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        promptMark.textColor = LaneView.signalOrange
        addSubview(promptMark)

        chip.wantsLayer = true
        chip.layer?.backgroundColor = LaneView.signalOrange.cgColor
        chip.layer?.cornerRadius = 0
        addSubview(chip)

        chipLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        chipLabel.textColor = .black
        chip.addSubview(chipLabel)

        for _ in 0..<LaneView.rowsPerLane {
            let t = NSTextField(labelWithString: "")
            t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            t.textColor = NSColor(white: 0.70, alpha: 1)
            t.lineBreakMode = .byTruncatingTail
            rows.append(t)
            addSubview(t)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(index: Int) {
        Counters.laneConfigures += 1
        laneIndex = index
        header.stringValue = String(format: "lane-%03d · agent-run", index)
        chipLabel.stringValue = "PROJ-\(index % 17)"
        for (i, r) in rows.enumerated() {
            r.stringValue = "// ROW_\(i)  \(index * 31 + i * 7)  ok  0x\(String(index &* 2654435761 &+ i, radix: 16))"
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        Counters.laneLayoutCalls += 1
        let w = bounds.width
        let pad: CGFloat = 12
        promptMark.frame = NSRect(x: pad, y: pad, width: 12, height: 18)
        header.frame = NSRect(x: pad + 16, y: pad, width: max(0, w - pad * 2 - 16), height: 18)
        chip.frame = NSRect(x: pad, y: pad + 24, width: 92, height: 16)
        chipLabel.frame = NSRect(x: 6, y: 1, width: 80, height: 14)
        var y: CGFloat = pad + 52
        for r in rows {
            r.frame = NSRect(x: pad, y: y, width: max(0, w - pad * 2), height: 15)
            y += 18
        }
    }

    override func updateConstraints() {
        Counters.laneUpdateConstraints += 1
        super.updateConstraints()
    }
}

/// NSCollectionViewItem wrapper for variant B.
final class LaneItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("LaneItem")
    var lane: LaneView { view as! LaneView }

    override func loadView() {
        Counters.itemInstantiations += 1
        view = LaneView()
    }
}
