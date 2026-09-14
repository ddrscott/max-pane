import AppKit

/// Every shortcut, in one panel. ⌘/.
///
/// It is generated from `Command`, not written by hand, so a new action shows up
/// here the moment it declares a key — the same reason the menus are generated
/// from it. A keyboard-first app whose keys are undiscoverable is just an app
/// you cannot use.
@MainActor
///
/// A `Popup` since the owner asked for one frame for every dialog: ⌘/ used to be
/// a titled utility window that stayed up until closed by hand. It now opens
/// centred, closes on Esc, a click away, or ⌘/ again.
final class HelpPanel: Popup {
    init() {
        super.init(size: NSSize(width: 600, height: 560), dismissal: .clickAway)

        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 480))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 14)
        // A text view pads every line by a few points of its own, which put the
        // body a hair right of the `// KEYBOARD_SHORTCUTS` header above it. With
        // it off, the header and every row start on the same 20 pt line.
        text.textContainer?.lineFragmentPadding = 0
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textStorage?.setAttributedString(Self.body())
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let header = SectionHeader(text: "KEYBOARD_SHORTCUTS")
        let hint = NSTextField(labelWithString: "esc")
        hint.font = Theme.mono(10, weight: .medium)
        hint.textColor = Theme.dimText
        let rule = NSBox()
        rule.boxType = .separator

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.laneBackground.cgColor
        content.layer?.borderColor = Theme.laneBorder.cgColor
        content.layer?.borderWidth = Theme.borderWidth
        // Square, like every other popup.
        content.layer?.cornerRadius = 0
        for view in [header, hint, rule, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        let edge = Theme.borderWidth
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            hint.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            rule.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: edge),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -edge),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -edge),
        ])
        window?.contentView = content
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
