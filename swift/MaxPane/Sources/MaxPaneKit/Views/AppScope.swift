import AppKit

/// What a row of the APP scope does: run Max Pane itself rather than a program
/// or a page.
///
/// Three kinds, and no fourth: every `Command` (what the menu bar can do), the
/// settings that apply live (what Settings can flip without a relaunch), and a
/// server's switches (what Settings › Servers can do to one). A row that would
/// run a shell line is refused here on purpose — that is ⌘O's job, and one
/// list where ↩ sometimes starts a process is the confusion this scope exists
/// to keep out of.
enum AppAction: Equatable {
    case command(Command)
    /// Write this value for this key, through `ConfigStore`, comments kept.
    case setting(key: String, to: TomlValue)
    case server(name: String, ServerAction)
}

/// What can be done to one configured server from a row.
enum ServerAction: Equatable {
    case enable
    case disable
    /// Rebuild the endpoint and connect again, for a server that stopped
    /// answering or whose token was just pasted.
    case reconnect
    case colour(ServerColour)

    var title: String {
        switch self {
        case .enable: return "Enable"
        case .disable: return "Disable"
        case .reconnect: return "Reconnect"
        case .colour(let c): return "Colour: \(c.title)"
        }
    }

    var word: String {
        switch self {
        case .enable: return "enable"
        case .disable: return "disable"
        case .reconnect: return "reconnect"
        case .colour: return "colour"
        }
    }
}

/// The APP scope's corpus, read once when the picker opens and again after a
/// row changes something.
///
/// A snapshot rather than a set of closures, so `rows(for:)` is a pure
/// function a test can call with a handful of items and no window: which row
/// is greyed and why, what a setting row says its value is, and whether a
/// command matches on its title come out of here, not out of AppKit.
struct AppScope: Equatable {
    struct CommandItem: Equatable {
        var command: Command
        /// What the menu calls it right now (`CommandHandling.title(for:)`).
        var title: String
        /// The keys the file gives it — `Keymap.active` until a binding is
        /// changed, then the file's, marked `pending`.
        var chords: [KeyChord]
        /// The file's chord differs from the running one: relaunch to apply.
        var pending: Bool
        /// Why it cannot run right now, from the same rule the menu greys
        /// with (`canPerform`); nil when it can.
        var unavailable: String?
    }

    struct SettingItem: Equatable {
        /// `paste_tidy`, as the file spells it.
        var key: String
        var value: TomlValue
        /// What ↩ writes: the other boolean, or the next choice.
        var next: TomlValue
        var summary: String
    }

    struct ServerItem: Equatable {
        var name: String
        var action: ServerAction
        /// The status word and session count, as Settings › Servers prints it.
        var detail: String
    }

    var commands: [CommandItem]
    var settings: [SettingItem]
    var servers: [ServerItem]

    static let empty = AppScope(commands: [], settings: [], servers: [])

    // MARK: - building the corpus

    /// Every command, in `Command.allCases` order, with the chord the file
    /// gives it and whether it can run.
    static func commandItems(
        file keymap: Keymap, active: Keymap = .active,
        title: (Command) -> String = { $0.title },
        unavailable: (Command) -> String?
    ) -> [CommandItem] {
        Command.allCases.map { command in
            let chords = keymap.chords(for: command)
            return CommandItem(
                command: command, title: title(command), chords: chords,
                pending: chords != active.chords(for: command), unavailable: unavailable(command))
        }
    }

    /// The boolean and choice settings that apply live, with their value in
    /// `config`. Everything else is read at launch, and a row that flipped a
    /// number the app would not read until tomorrow would be a row that lies.
    static func settingItems(config: Config, fields: [ConfigField] = ConfigField.all) -> [SettingItem] {
        fields.compactMap { field in
            guard field.appliesLive, let value = field.read(config) else { return nil }
            let next: TomlValue
            switch (field.control, value) {
            case (.toggle, .bool(let on)):
                next = .bool(!on)
            case (.choice(let options), .string(let current)):
                guard let index = options.firstIndex(of: current) else { return nil }
                next = .string(options[(index + 1) % options.count])
            default:
                return nil
            }
            return SettingItem(key: field.key, value: value, next: next, summary: field.summary)
        }
    }

    /// Enable or disable, reconnect, and the next colour, per configured
    /// server. Disabled servers get only Enable: nothing else means anything
    /// on a server the app is not talking to.
    static func serverItems(
        entries: [RelayServerEntry], status: (RelayServerEntry) -> String
    ) -> [ServerItem] {
        entries.flatMap { entry -> [ServerItem] in
            let detail = status(entry)
            guard entry.enabled else {
                return [ServerItem(name: entry.name, action: .enable, detail: detail)]
            }
            let colours = ServerColour.allCases
            let next = colours[((colours.firstIndex(of: entry.colour) ?? 0) + 1) % colours.count]
            return [
                ServerItem(name: entry.name, action: .reconnect, detail: detail),
                ServerItem(name: entry.name, action: .disable, detail: detail),
                ServerItem(name: entry.name, action: .colour(next), detail: "\(detail) · now \(entry.colour.rawValue)"),
            ]
        }
    }

    // MARK: - the rows

    /// The list, for what was typed after `>` (or in the scope itself).
    ///
    /// Nothing typed lists everything under three headers, in the order the
    /// menu bar has it, so the scope reads as the menu bar laid flat. Typing
    /// ranks by `MatchQuality` like every other scope and drops guesses when
    /// something matched properly (`OmniRanking` rule 3). Ties keep list
    /// order, which is why every candidate carries its index as a negative
    /// timestamp: the sort's recency tie-break then reads as "earlier in the
    /// menu first", and a non-positive `chosenAt` prints no age.
    func rows(for query: String) -> [OmniRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = candidates()
        guard !trimmed.isEmpty else {
            var rows: [OmniRow] = []
            let commands = all.filter { if case .app(.command) = $0.action { return true } else { return false } }
            let settings = all.filter { if case .app(.setting) = $0.action { return true } else { return false } }
            let servers = all.filter { if case .app(.server) = $0.action { return true } else { return false } }
            if !commands.isEmpty {
                rows.append(.section(title: "COMMANDS", note: "\(commands.count) · ⌘⌫ binds"))
                rows.append(contentsOf: commands.map(OmniRow.item))
            }
            if !settings.isEmpty {
                rows.append(.section(title: "SETTINGS", note: "\(settings.count) live"))
                rows.append(contentsOf: settings.map(OmniRow.item))
            }
            if !servers.isEmpty {
                let named = Set(self.servers.map(\.name)).count
                rows.append(.section(title: "SERVERS", note: "\(named) \(named == 1 ? "server" : "servers")"))
                rows.append(contentsOf: servers.map(OmniRow.item))
            }
            if rows.isEmpty {
                rows.append(.note(title: OmniScope.app.title, detail: "nothing to run"))
            }
            return rows
        }

        var matched = all.compactMap { candidate -> OmniCandidate? in
            guard let quality = MatchQuality.of(trimmed, inAny: candidate.searchable) else { return nil }
            var hit = candidate
            hit.quality = quality
            return hit
        }
        if matched.contains(where: { $0.quality.isLiteral }) {
            matched.removeAll { !$0.quality.isLiteral }
        }
        matched.sort {
            if $0.quality != $1.quality { return $0.quality < $1.quality }
            return $0.chosenAt > $1.chosenAt
        }
        guard !matched.isEmpty else {
            return [.note(title: OmniScope.app.title, detail: "nothing in Max Pane matches “\(trimmed)”")]
        }
        return [.section(title: "MATCHES", note: "\(matched.count)")] + matched.map(OmniRow.item)
    }

    private func candidates() -> [OmniCandidate] {
        var out: [OmniCandidate] = []
        func add(_ candidate: OmniCandidate) {
            var c = candidate
            c.chosenAt = -Int64(out.count)
            out.append(c)
        }
        for item in commands {
            let chord = item.chords.map(\.text).joined(separator: " ")
            var detail = item.command.menu.rawValue
            if item.pending { detail += " · relaunch to apply" }
            if let why = item.unavailable { detail += " · \(why)" }
            add(OmniCandidate(
                action: .app(.command(item.command)), kind: .app,
                headline: item.title, detail: detail, quality: .prefix,
                chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil,
                trailing: chord.isEmpty ? "—" : chord,
                unavailable: item.unavailable,
                searchable: [item.title, item.command.rawValue, item.command.menu.rawValue]))
        }
        for item in settings {
            add(OmniCandidate(
                action: .app(.setting(key: item.key, to: item.next)), kind: .app,
                headline: item.key, detail: item.summary, quality: .prefix,
                chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil,
                trailing: Self.display(item.value),
                unavailable: nil,
                searchable: [item.key, item.key.replacingOccurrences(of: "_", with: " ")]))
        }
        for item in servers {
            add(OmniCandidate(
                action: .app(.server(name: item.name, item.action)), kind: .app,
                headline: "\(item.name): \(item.action.title)", detail: item.detail, quality: .prefix,
                chosenAt: 0, count: 0, telemetry: nil, bookmarkId: nil,
                trailing: nil,
                unavailable: nil,
                searchable: [item.name, item.action.word, "server \(item.name)"]))
        }
        return out
    }

    /// `on`, `off`, or the choice's word: what the row's right edge prints.
    static func display(_ value: TomlValue) -> String {
        switch value {
        case .bool(let b): return b ? "on" : "off"
        case .string(let s): return s
        default: return value.toml
        }
    }
}

/// The recorder Settings › Keyboard and the APP scope share: the next key
/// press, read as a chord, or the two ways it is not one.
enum ChordRecorder {
    enum Outcome: Equatable {
        /// Esc on its own. A chord with Esc in it is still a chord.
        case cancelled
        /// A key nothing can name — a bare modifier, a dead key.
        case ignored
        case chord(KeyChord)
    }

    static func outcome(of event: NSEvent) -> Outcome {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, modifiers.isEmpty { return .cancelled }
        guard let chord = KeyChord(event: event) else { return .ignored }
        return .chord(chord)
    }
}
