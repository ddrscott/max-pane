import AppKit

/// What an empty strip says.
///
/// The app is keyboard-first and fullscreen, which means a fresh launch is a
/// blank rectangle with no menu bar and no affordances — indistinguishable from
/// a broken app. This is the fix, and it names the two keys that actually get
/// you somewhere plus the one that lists the rest.
@MainActor
final class EmptyStripView: NSView {
    init() {
        super.init(frame: .zero)

        let text = NSTextField(labelWithAttributedString: Self.body())
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

    private static func body() -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "// MAX PANE\n\n",
            attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(13, weight: .bold)]))

        for (key, what) in [
            (HelpPanel.describe(.runCommand), "run a command in a new terminal lane"),
            (HelpPanel.describe(.newTerminalLane), "a terminal lane running your shell"),
            (HelpPanel.describe(.newWebLane), "a web lane"),
            (HelpPanel.describe(.attachSession), "attach an existing Relay session"),
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
