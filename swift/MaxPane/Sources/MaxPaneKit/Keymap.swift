import AppKit

/// One chord: a key and the modifiers held with it.
///
/// The modifier mask is stored as its raw `UInt` rather than as
/// `NSEvent.ModifierFlags` so the whole type is trivially `Hashable` and
/// `Sendable` — this is the key of the set `Command.claims` asks on every
/// keystroke that reaches a web pane, and that set is built once and read from
/// wherever the keyboard is handled.
///
/// `key` is stored the way AppKit wants a menu item's key equivalent: the
/// **unshifted, lowercase** character, with `.shift` carried in the mask. ⇧⌘D
/// is `("d", [.command, .shift])`, never `("D", [.command])`.
public struct KeyChord: Hashable, Sendable {
    public let key: String
    public let mask: UInt

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mask) }

    public init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.mask = modifiers.intersection(.deviceIndependentFlagsMask).rawValue
    }

    public init(_ pair: (String, NSEvent.ModifierFlags)) {
        self.init(key: pair.0, modifiers: pair.1)
    }

    public var pair: (String, NSEvent.ModifierFlags) { (key, modifiers) }

    // MARK: - named keys

    /// Keys with no printable character of their own, in both directions.
    ///
    /// The glyphs are what `text` prints and what the ⌘/ sheet has always
    /// shown; the words are what someone types into a config file, because
    /// `"cmd+left"` is reachable from a keyboard and `"⌘←"` is not. Both parse,
    /// so a chord copied off the help sheet goes straight back in the file.
    private static let named: [(word: String, glyph: String, key: String)] = [
        ("esc", "esc", "\u{1b}"),
        ("escape", "esc", "\u{1b}"),
        ("left", "←", "\u{2190}"),
        ("right", "→", "\u{2192}"),
        ("up", "↑", "\u{2191}"),
        ("down", "↓", "\u{2193}"),
        ("tab", "tab", "\u{21e5}"),
        ("space", "space", " "),
        ("return", "↩", "\r"),
        ("enter", "↩", "\r"),
        ("delete", "⌫", "\u{8}"),
        ("backspace", "⌫", "\u{8}"),
    ]

    /// The chord as a human reads it: `⇧⌘D`, `⌃⌘[`, `esc`.
    ///
    /// This is the only renderer. The ⌘/ sheet, the lane menu and the parser
    /// all go through it, so what the sheet prints is by construction something
    /// `KeyChord(_:)` reads back — the two cannot drift into disagreeing about
    /// what a key is called.
    public var text: String {
        var out = ""
        let mods = modifiers
        if mods.contains(.control) { out += "⌃" }
        if mods.contains(.option) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.command) { out += "⌘" }
        if let named = Self.named.first(where: { $0.key == key }) {
            out += named.glyph
        } else {
            out += key.uppercased()
        }
        return out
    }

    // MARK: - parsing

    private static let modifierWords: [(String, NSEvent.ModifierFlags)] = [
        ("cmd", .command), ("command", .command),
        ("ctrl", .control), ("control", .control),
        ("opt", .option), ("option", .option), ("alt", .option),
        ("shift", .shift),
    ]

    private static let modifierGlyphs: [(Character, NSEvent.ModifierFlags)] = [
        ("⌘", .command), ("⌃", .control), ("⌥", .option), ("⇧", .shift),
    ]

    /// `"cmd+shift+d"`, `"⇧⌘D"`, `"esc"`, `"cmd+-"` — or nil if it is none of
    /// those.
    ///
    /// Modifiers are stripped off the front one at a time rather than the whole
    /// string being split on `+`: splitting turns `"cmd+-"` into a component
    /// that is empty and a component that is a modifier's separator, and the
    /// two keys most likely to be rebound after the letters are `-` and `=`.
    public init?(_ text: String) {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers: NSEvent.ModifierFlags = []
        guard !rest.isEmpty else { return nil }

        stripping: while rest.count > 1 {
            if let glyph = Self.modifierGlyphs.first(where: { $0.0 == rest.first }) {
                modifiers.insert(glyph.1)
                rest = rest.dropFirst()
                continue
            }
            for (word, flag) in Self.modifierWords
            where rest.count > word.count + 1
                && rest.prefix(word.count + 1).lowercased() == word + "+" {
                modifiers.insert(flag)
                rest = rest.dropFirst(word.count + 1)
                continue stripping
            }
            break
        }

        let remainder = String(rest)
        if let named = Self.named.first(where: { $0.word == remainder.lowercased() }) {
            self.init(key: named.key, modifiers: modifiers)
            return
        }
        if let named = Self.named.first(where: { $0.glyph == remainder || $0.key == remainder }) {
            self.init(key: named.key, modifiers: modifiers)
            return
        }
        // A lone modifier glyph is not a key. Without this, `"⌘"` parses as
        // "the key ⌘ with no modifiers" and silently binds something to a chord
        // no keyboard can produce.
        guard remainder.count == 1,
              !Self.modifierGlyphs.contains(where: { String($0.0) == remainder })
        else { return nil }
        self.init(key: remainder, modifiers: modifiers)
    }
}

/// The `keys` object in the config file, decoded key by key.
///
/// A value is a chord (`"cmd+shift+d"`), a list of chords (the first is the one
/// the menu shows, the rest are alternates), or `null` — which unbinds the
/// command, because "⌘W should not be a thing" is a real preference and the
/// only other way to express it is a chord nobody presses.
///
/// Decoded by hand for the same reason `Config` is: one bad entry should cost
/// that entry and nothing else. A synthesised decoder throws on the first
/// wrong-typed value and takes the whole keymap with it.
public struct KeyBindings: Codable, Equatable, Sendable {
    /// Command raw value → chords. An empty array is an explicit unbind.
    public var entries: [String: [String]]

    public init(_ entries: [String: [String]] = [:]) { self.entries = entries }

    private struct Key: CodingKey {
        let stringValue: String
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    /// The spellings of "no key at all". `null` is the honest JSON one; the
    /// other two exist because a hand-edited file is where people write what
    /// they mean rather than what a schema wants.
    private static let unboundWords = ["", "none", "off"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var entries: [String: [String]] = [:]
        for key in container.allKeys {
            let name = key.stringValue
            if (try? container.decodeNil(forKey: key)) == true {
                entries[name] = []
            } else if let one = try? container.decode(String.self, forKey: key) {
                entries[name] = Self.unboundWords.contains(one.lowercased()) ? [] : [one]
            } else if let many = try? container.decode([String].self, forKey: key) {
                entries[name] = many
            } else {
                Log.warn("config: ignoring keys.\(name) — expected a chord, a list of chords, or null")
            }
        }
        self.entries = entries
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (name, chords) in entries.sorted(by: { $0.key < $1.key }) {
            guard let key = Key(stringValue: name) else { continue }
            try container.encode(chords, forKey: key)
        }
    }
}

/// Which keys run which commands, right now.
///
/// `Command` still declares the defaults — that is what keeps a new action
/// impossible without a key — and this resolves them against the config file
/// once, at launch. Everything that touches the keyboard reads the resolved
/// map: the menu, the ⌘/ sheet, the lane menu, the window's key monitor and
/// `Command.claims`. One edit in the file therefore moves all five, and the
/// help sheet cannot print a key that no longer fires.
public struct Keymap: Sendable {
    /// Command → its chords, in order. The first is the one a menu item can
    /// carry; the rest are matched in the window's key monitor. Empty means
    /// deliberately unbound.
    public let bindings: [Command: [KeyChord]]

    /// What was wrong with the config file, in the order it was found. Held
    /// rather than printed so resolution is a pure function a test can call —
    /// `install` is what puts these on stderr.
    public let complaints: [String]

    /// Chords with `.command` in them, including the shifted spelling of the
    /// punctuation ones. Built once here because `Command.claims` is asked on
    /// every keystroke that reaches a web pane.
    let claimed: Set<KeyChord>

    // MARK: - the defaults

    /// Exactly what ships: `Command`'s own declarations, unresolved.
    public static let defaults = Keymap(bindings: Dictionary(
        uniqueKeysWithValues: Command.allCases.map { command in
            (command, ((command.defaultShortcut.map { [$0] } ?? []) + command.defaultAlternateShortcuts).map(KeyChord.init))
        }), complaints: [])

    private init(bindings: [Command: [KeyChord]], complaints: [String]) {
        self.bindings = bindings
        self.complaints = complaints
        self.claimed = Self.claimedChords(in: bindings)
    }

    public func chords(for command: Command) -> [KeyChord] { bindings[command] ?? [] }

    // MARK: - the active one

    /// Installed once, at launch, before the window exists; read on the main
    /// thread for the rest of the process. There is no reload-on-change — the
    /// menu's key equivalents are baked in at `buildMenu`, so a second install
    /// would leave the menu saying one thing and the monitor doing another.
    nonisolated(unsafe) public private(set) static var active = Keymap.defaults

    public static func install(_ keymap: Keymap) {
        for complaint in keymap.complaints { Log.warn("keymap: \(complaint)") }
        active = keymap
    }

    // MARK: - resolution

    /// Chords macOS or this app's own fixed menus answer first, with the reason.
    ///
    /// Refused rather than allowed-with-a-warning: a command bound to ⌘Q is a
    /// command that can never run, because the App menu's item is matched
    /// before anything built from `Command`. Shipping a key that silently does
    /// something else is worse than saying no in one line on stderr.
    private static let reserved: [(KeyChord, String)] = [
        (KeyChord(key: "q", modifiers: [.command]), "macOS quits the app"),
        (KeyChord(key: "h", modifiers: [.command]), "macOS hides the app"),
        (KeyChord(key: "h", modifiers: [.command, .option]), "macOS hides the other apps"),
        (KeyChord(key: "m", modifiers: [.command]), "macOS minimises the window"),
        (KeyChord(key: "\u{21e5}", modifiers: [.command]), "macOS switches apps"),
        (KeyChord(key: " ", modifiers: [.command]), "macOS opens Spotlight"),
        (KeyChord(key: "`", modifiers: [.command]), "macOS switches windows"),
        (KeyChord(key: "x", modifiers: [.command]), "the Edit menu cuts"),
        (KeyChord(key: "c", modifiers: [.command]), "the Edit menu copies"),
        (KeyChord(key: "v", modifiers: [.command]), "the Edit menu pastes"),
        (KeyChord(key: "a", modifiers: [.command]), "the Edit menu selects all"),
    ]

    /// Resolve the config file's `keys` against the defaults.
    ///
    /// Configured bindings are laid down before default ones, so rebinding a
    /// key that something else already has is **one** edit rather than two: set
    /// `newTerminalLane` to ⌘R and `reload` yields its default, with a line
    /// saying so. Two configured commands on one chord is a genuine mistake, and
    /// there the earlier one in `Command.allCases` keeps it.
    public init(overrides: KeyBindings) {
        var complaints: [String] = []
        var configured: [Command: [KeyChord]] = [:]

        for (name, spellings) in overrides.entries.sorted(by: { $0.key < $1.key }) {
            guard let command = Command(rawValue: name) else {
                complaints.append("no command is called \"\(name)\"")
                continue
            }
            var chords: [KeyChord] = []
            var rejected = false
            for spelling in spellings {
                guard let chord = KeyChord(spelling) else {
                    complaints.append("\(name): \"\(spelling)\" is not a chord")
                    rejected = true
                    continue
                }
                if let reason = Self.reserved.first(where: { $0.0 == chord })?.1 {
                    complaints.append("\(name): \(chord.text) is not available — \(reason)")
                    rejected = true
                    continue
                }
                if !chords.contains(chord) { chords.append(chord) }
            }
            // Every spelling was bad: keep the default rather than silently
            // unbinding a command over a typo. An *empty* list is different —
            // that is someone asking for no key, and it is honoured.
            if chords.isEmpty && rejected { continue }
            configured[command] = chords
        }

        var bindings: [Command: [KeyChord]] = [:]
        var owner: [KeyChord: Command] = [:]

        func lay(_ command: Command, _ chords: [KeyChord], configuredHere: Bool) {
            var kept: [KeyChord] = []
            for chord in chords {
                // A declared pair is not a collision: the two can never be
                // enabled at the same time, so the chord means one thing
                // wherever you press it. The first to claim it stays the owner.
                if let held = owner[chord], held == command.sharesChordWith {
                    kept.append(chord)
                    continue
                }
                if let held = owner[chord] {
                    let why = configuredHere
                        ? "\(held.rawValue) is also set to it, and comes first"
                        : "\(held.rawValue) is set to it in the config file"
                    complaints.append("\(chord.text): \(command.rawValue) does not get it — \(why)")
                    continue
                }
                owner[chord] = command
                kept.append(chord)
            }
            bindings[command] = kept
        }

        for command in Command.allCases {
            guard let chords = configured[command] else { continue }
            lay(command, chords, configuredHere: true)
        }
        for command in Command.allCases where configured[command] == nil {
            lay(command, Keymap.defaults.chords(for: command), configuredHere: false)
        }

        self.init(bindings: bindings, complaints: complaints)
    }

    // MARK: - what a web pane may not swallow

    /// `charactersIgnoringModifiers` ignores every modifier *except* shift, so
    /// ⇧⌘[ arrives spelling itself `{`. The map declares the unshifted key the
    /// way a menu item wants it, so both spellings go in the set — otherwise
    /// ⇧⌘[ and ⇧⌘] are the two bindings this silently fails to protect, and a
    /// silent gap in a keyboard map is the thing this file exists to prevent.
    /// Letters need no entry: `W` lowercases back to `w`.
    private static let shifted: [String: String] = [
        "[": "{", "]": "}", "=": "+", "-": "_", "\\": "|", "/": "?",
        ",": "<", ".": ">", ";": ":", "'": "\"", "`": "~",
    ]

    private static func claimedChords(in bindings: [Command: [KeyChord]]) -> Set<KeyChord> {
        var out: Set<KeyChord> = []
        for chord in bindings.values.flatMap({ $0 })
        where chord.modifiers.contains(.command) {
            out.insert(chord)
            if chord.modifiers.contains(.shift), let alt = shifted[chord.key] {
                out.insert(KeyChord(key: alt, modifiers: chord.modifiers))
            }
        }
        return out
    }
}
