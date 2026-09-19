import AppKit

/// What an empty strip says.
///
/// The app is keyboard-first and fullscreen, which means a fresh launch is a
/// blank rectangle with no menu bar and no affordances — indistinguishable from
/// a broken app. This is the fix, and it names the two keys that actually get
/// you somewhere plus the one that lists the rest.
@MainActor
final class EmptyStripView: NSView {
    private let text = NSTextField(labelWithAttributedString: EmptyStripView.body(hidden: 0))

    /// How many lanes a folded sidebar group is keeping off the strip
    /// (ADR-0024). An empty strip that is empty because everything was put
    /// away is not a fresh launch, and saying "start something" over six
    /// running agents would be the wrong sentence.
    var hiddenLanes = 0 {
        didSet {
            guard hiddenLanes != oldValue else { return }
            Motion.fade(text.layer)
            text.attributedStringValue = Self.body(hidden: hiddenLanes)
        }
    }

    /// The text as drawn, for tests.
    var bodyText: String { text.attributedStringValue.string }

    init() {
        super.init(frame: .zero)

        text.wantsLayer = true
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: topAnchor),
            text.bottomAnchor.constraint(equalTo: bottomAnchor),
            text.leadingAnchor.constraint(equalTo: leadingAnchor),
            text.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    private static func body(hidden: Int) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "// MAX PANE\n\n",
            attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(13, weight: .bold)]))
        if hidden > 0 {
            out.append(NSAttributedString(
                string: "\(hidden) lane\(hidden == 1 ? " is" : "s are") in collapsed sidebar groups, still running.\n"
                    + "Open a group in the sidebar to bring \(hidden == 1 ? "it" : "them") back.\n\n",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Theme.mono(13)]))
        }

        for (key, what) in [
            (HelpPanel.describe(.openAnything), "a command, a page, or a running session"),
            (HelpPanel.describe(.newTerminalLane), "a terminal lane running your shell"),
            (HelpPanel.describe(.openPages), "the same picker, pages only"),
            (HelpPanel.describe(.showHelp), "every other shortcut"),
        ] {
            out.append(NSAttributedString(
                string: key.padding(toLength: 8, withPad: " ", startingAt: 0),
                attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(13, weight: .medium)]))
            out.append(NSAttributedString(
                string: "\(what)\n",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Theme.mono(13)]))
        }

        out.append(NSAttributedString(
            string: "\nor, from any terminal:  maxpane run htop\n",
            attributes: [.foregroundColor: NSColor.tertiaryLabelColor, .font: Theme.mono(12)]))
        return out
    }
}
