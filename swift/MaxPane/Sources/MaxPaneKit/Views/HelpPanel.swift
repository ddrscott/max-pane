import AppKit

/// Every shortcut, in one panel. ⌘/.
///
/// It is generated from `Command`, not written by hand, so a new action shows up
/// here the moment it declares a key — the same reason the menus are generated
/// from it. A keyboard-first app whose keys are undiscoverable is just an app
/// you cannot use.
@MainActor
public final class HelpPanel: NSPanel {
    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        title = "Keyboard Shortcuts"
        isFloatingPanel = true

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 18)
        text.textStorage?.setAttributedString(Self.body())

        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.laneBackground.cgColor
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        contentView = content
    }

    /// A `Command`'s shortcut as a human reads it: ⇧⌘T, not `("t", [.command, .shift])`.
    ///
    /// A command with a second key shows both — `⌘T ⌘D` — because a shortcut
    /// nobody can see is a shortcut nobody uses.
    ///
    /// It reads the **effective** keys, not the shipped ones. A sheet that
    /// printed the defaults would become a lie the moment anyone edited the
    /// config file, and the sheet is the only place most of these keys are
    /// written down. The rendering itself lives in `KeyChord.text`, which is
    /// also what the chord parser reads back — so a key copied off this sheet
    /// goes straight into the config file.
    public static func describe(_ command: Command) -> String {
        let chords = command.chords
        // An em dash, not an empty column: "this command has no key" is an
        // answer, and a blank looks like the sheet failed to render.
        guard !chords.isEmpty else { return "—" }
        return chords.map(\.text).joined(separator: " ")
    }

    private static func body() -> NSAttributedString {
        let out = NSMutableAttributedString()

        func heading(_ s: String) {
            out.append(NSAttributedString(
                string: "// ",
                attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(11, weight: .bold)]))
            out.append(NSAttributedString(
                string: "\(s.uppercased())\n",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: Theme.mono(11, weight: .bold)]))
        }

        func row(_ keys: String, _ title: String) {
            let padded = keys.padding(toLength: max(10, keys.count + 2), withPad: " ", startingAt: 0)
            out.append(NSAttributedString(
                string: padded,
                attributes: [.foregroundColor: Theme.accent, .font: Theme.mono(12, weight: .medium)]))
            out.append(NSAttributedString(
                string: "\(title)\n",
                attributes: [.foregroundColor: NSColor.labelColor, .font: Theme.mono(12)]))
        }

        func blank() { out.append(NSAttributedString(string: "\n")) }

        out.append(NSAttributedString(
            string: "Terminals and web views as peer panes, in portrait columns.\n",
            attributes: [.foregroundColor: NSColor.labelColor, .font: Theme.mono(12)]))
        // Interpolated, not written out. This line said "press ⌘R", which was
        // the key before ⌘O became the only door — a hardcoded chord in the
        // sheet whose job is to be the truth about the keyboard, and the exact
        // way that goes stale.
        out.append(NSAttributedString(
            string: "Nothing on the strip? Press \(describe(.openAnything)) and run something.\n\n",
            attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: Theme.mono(12)]))

        for section in MenuSection.allCases {
            heading(section.rawValue)
            for command in Command.allCases where command.menu == section {
                row(describe(command), command.title)
            }
            blank()
        }

        heading("From a terminal")
        out.append(NSAttributedString(
            string: """
                maxpane run htop      a terminal lane running htop
                maxpane open google.com   a web lane
                maxpane ls            what is on the strip

                Terminals Max Pane starts have BROWSER set, so anything that opens
                a URL politely gets a web lane beside the terminal that asked.

                """,
            attributes: [.foregroundColor: NSColor.labelColor, .font: Theme.mono(12)]))

        return out
    }
}
