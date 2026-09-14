import AppKit

/// The lane header's `s | m | xl` switch.
///
/// The toolbar's lanes | gallery switch, smaller: square segments sharing one
/// border, the lit one in the accent green with a faint green ground, the rest
/// dim. Words rather than icons, because `s`, `m` and `xl` *are* the names —
/// wiz-term's, and the owner's — and a picture of three sizes of rectangle is
/// a worse way to say them.
///
/// None is lit when the lane has been dragged or zoomed off every preset. A
/// segment that changes cross-fades (`Motion.fade`), like the toolbar's.
@MainActor
final class LaneSizeSwitch: NSView {
    /// Fits the 28 pt header with six points either side.
    static let height: CGFloat = 16

    private static func segmentWidth(_ preset: LaneSizePreset) -> CGFloat {
        preset == .xl ? 22 : 18
    }

    var onPick: ((LaneSizePreset) -> Void)?

    private(set) var buttons: [LaneSizePreset: SidebarButton] = [:]

    var selected: LaneSizePreset? {
        didSet {
            guard selected != oldValue else { return }
            for preset in LaneSizePreset.allCases {
                guard let button = buttons[preset] else { continue }
                let on = preset == selected
                guard button.isOn != on else { continue }
                if window != nil { Motion.fade(button.layer) }
                button.isOn = on
                // On top of its neighbours, so the shared border is the lit green
                // all the way round rather than grey on the side it overlaps.
                if on { addSubview(button, positioned: .above, relativeTo: nil) }
            }
        }
    }

    /// The whole switch, segments overlapping by a border.
    var fittingWidth: CGFloat {
        LaneSizePreset.allCases.map(Self.segmentWidth).reduce(0, +)
            - CGFloat(LaneSizePreset.allCases.count - 1) * Theme.borderWidth
    }

    init() {
        super.init(frame: .zero)
        for (index, preset) in LaneSizePreset.allCases.enumerated() {
            let button = SidebarButton(
                text: preset.rawValue, look: .quiet, size: 9, action: #selector(pick(_:)), target: self)
            button.translatesAutoresizingMaskIntoConstraints = true
            button.tag = index
            button.toolTip = Self.tooltip(preset)
            button.setAccessibilityLabel("\(preset.title) lane")
            buttons[preset] = button
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    static func tooltip(_ preset: LaneSizePreset) -> String {
        switch preset {
        case .s: return "Small — the same columns at 60% text"
        case .m: return "Medium — the default width"
        case .xl: return "Extra large — double wide"
        }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for preset in LaneSizePreset.allCases {
            let width = Self.segmentWidth(preset)
            buttons[preset]?.frame = NSRect(x: x, y: 0, width: width, height: bounds.height)
            x += width - Theme.borderWidth
        }
    }

    @objc private func pick(_ sender: SidebarButton) {
        let presets = LaneSizePreset.allCases
        guard presets.indices.contains(sender.tag) else { return }
        onPick?(presets[sender.tag])
    }
}
