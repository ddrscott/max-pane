import Foundation

/// Where a setting is listed in the settings window.
public enum ConfigGroup: String, CaseIterable, Sendable {
    case lanes = "Lanes"
    case galleryMotion = "Gallery & motion"
    case web = "Web & memory"
    case terminals = "Terminals & sessions"
    /// `[[servers]]`: not keys but tables, drawn by `ServersSection` rather
    /// than by `ConfigField` rows.
    case servers = "Servers"
    /// `[[apps]]`: tables too, drawn by `AppsSection`, and last before the
    /// keyboard because an app's row is half a keyboard row.
    case apps = "Apps"
    case editorSearch = "Editor & search"
    case appearance = "Appearance"
    case keyboard = "Keyboard"

    /// `// GALLERY_AND_MOTION`.
    var header: String {
        rawValue.uppercased()
            .replacingOccurrences(of: " & ", with: "_AND_")
            .replacingOccurrences(of: " ", with: "_")
    }
}

/// What kind of control a setting gets.
public enum ConfigControl: Sendable {
    /// A whole number. The range bounds what the settings window will write;
    /// the file itself is held only to the type, so a number a hand edit put
    /// there before this window existed still means what it meant.
    case integer(ClosedRange<Int64>, step: Int64)
    case number(ClosedRange<Double>, step: Double)
    case toggle
    /// `placeholder` says what an empty field means.
    case text(placeholder: String)
    case choice([String])
}

/// One key of `config.toml`: its name, where it is listed, what it does, and
/// how to read it into a `Config`.
///
/// **The one place a TOML name meets a Swift property.** `key` is derived from
/// `name` by `ConfigField.snake`, so `laneDefaultPt` is `lane_default_pt` and
/// there is no second table of spellings to drift; a test holds `all` to
/// `Config`'s stored properties, so a new setting cannot ship without a row.
public struct ConfigField {
    /// The Swift property, and the key the old `config.json` used.
    public let name: String
    public let group: ConfigGroup
    public let control: ConfigControl
    /// One line, from the property's documentation.
    public let summary: String
    /// True only where the running app re-reads the value when the file
    /// changes. Everything else is read at launch, and the window says so.
    public let appliesLive: Bool
    /// The value in `config`, or nil for an optional that is unset.
    public let read: (Config) -> TomlValue?
    /// Put `value` into `config`, or say why it cannot go there.
    let apply: (inout Config, TomlValue) -> String?

    public var key: String { Self.snake(name) }

    /// The shipped value, as the file would spell it.
    public var defaultValue: TomlValue? { read(Config()) }

    /// `laneDefaultPt` → `lane_default_pt`.
    static func snake(_ name: String) -> String {
        var out = ""
        for c in name {
            if c.isUppercase {
                out += "_" + c.lowercased()
            } else {
                out.append(c)
            }
        }
        return out
    }

    // MARK: - builders

    private static func unsigned(
        _ name: String, _ path: WritableKeyPath<Config, UInt32>, _ group: ConfigGroup,
        _ range: ClosedRange<Int64>, step: Int64 = 1, appliesLive: Bool = false, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .integer(range, step: step), summary: summary, appliesLive: appliesLive,
            read: { .integer(Int64($0[keyPath: path])) },
            apply: { config, value in
                guard case .integer(let n) = value else { return "expected a whole number, got \(value.kind)" }
                guard let v = UInt32(exactly: n) else { return "expected a whole number from 0 to \(UInt32.max)" }
                config[keyPath: path] = v
                return nil
            })
    }

    private static func signed(
        _ name: String, _ path: WritableKeyPath<Config, Int>, _ group: ConfigGroup,
        _ range: ClosedRange<Int64>, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .integer(range, step: 1), summary: summary, appliesLive: false,
            read: { .integer(Int64($0[keyPath: path])) },
            apply: { config, value in
                guard case .integer(let n) = value else { return "expected a whole number, got \(value.kind)" }
                guard let v = Int(exactly: n) else { return "\(n) is too large" }
                config[keyPath: path] = v
                return nil
            })
    }

    private static func double(
        _ name: String, _ path: WritableKeyPath<Config, Double>, _ group: ConfigGroup,
        _ range: ClosedRange<Double>, step: Double, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .number(range, step: step), summary: summary, appliesLive: false,
            read: { .float($0[keyPath: path]) },
            apply: { config, value in
                // A whole number is a number: `font_size = 13` is what anyone
                // would write, and `config.json` took it too.
                switch value {
                case .float(let d): config[keyPath: path] = d
                case .integer(let n): config[keyPath: path] = Double(n)
                default: return "expected a number, got \(value.kind)"
                }
                return nil
            })
    }

    private static func bool(
        _ name: String, _ path: WritableKeyPath<Config, Bool>, _ group: ConfigGroup,
        appliesLive: Bool = false, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .toggle, summary: summary, appliesLive: appliesLive,
            read: { .bool($0[keyPath: path]) },
            apply: { config, value in
                guard case .bool(let b) = value else { return "expected true or false, got \(value.kind)" }
                config[keyPath: path] = b
                return nil
            })
    }

    /// One of an enum's raw values. Anything else is refused with the list,
    /// so the key keeps its default rather than meaning nothing.
    private static func choice<E: RawRepresentable & CaseIterable>(
        _ name: String, _ path: WritableKeyPath<Config, E>, _ group: ConfigGroup, appliesLive: Bool,
        _ summary: String
    ) -> ConfigField where E.RawValue == String {
        let options = E.allCases.map(\.rawValue)
        return ConfigField(
            name: name, group: group, control: .choice(options), summary: summary, appliesLive: appliesLive,
            read: { .string($0[keyPath: path].rawValue) },
            apply: { config, value in
                guard case .string(let s) = value, let choice = E(rawValue: s) else {
                    return "expected one of " + options.map { "\"\($0)\"" }.joined(separator: ", ")
                }
                config[keyPath: path] = choice
                return nil
            })
    }

    private static func string(
        _ name: String, _ path: WritableKeyPath<Config, String>, _ group: ConfigGroup, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .text(placeholder: Config()[keyPath: path]), summary: summary,
            appliesLive: false,
            read: { .string($0[keyPath: path]) },
            apply: { config, value in
                guard case .string(let s) = value else { return "expected a string, got \(value.kind)" }
                config[keyPath: path] = s
                return nil
            })
    }

    private static func optionalString(
        _ name: String, _ path: WritableKeyPath<Config, String?>, _ group: ConfigGroup,
        unset: String, _ summary: String
    ) -> ConfigField {
        ConfigField(
            name: name, group: group, control: .text(placeholder: unset), summary: summary, appliesLive: false,
            read: { $0[keyPath: path].map(TomlValue.string) },
            apply: { config, value in
                guard case .string(let s) = value else { return "expected a string, got \(value.kind)" }
                config[keyPath: path] = s
                return nil
            })
    }

    // MARK: - every key

    /// Every setting except `keys`, which is a table of its own and is listed
    /// from `Command`. In the order the window lists them.
    public static var all: [ConfigField] {
        [
            unsigned("laneDefaultPt", \.laneDefaultPt, .lanes, 200...4000, step: 8,
                     "The width every new lane is born at. 656 fits 80 columns of 13 pt text."),
            unsigned("laneMinPt", \.laneMinPt, .lanes, 100...4000, step: 10,
                     "The narrowest a lane can be dragged or narrowed to."),
            unsigned("laneMaxPt", \.laneMaxPt, .lanes, 100...4000, step: 10,
                     "The widest a lane can be dragged or widened to. An xl lane gets twice this."),
            unsigned("lanePeekPt", \.lanePeekPt, .lanes, 0...200, step: 2,
                     "The sliver of the next lane a settled strip always shows. 0 centres exactly."),
            bool("stripEdgeRails", \.stripEdgeRails, .lanes,
                 "The rails at either edge that count the lanes off screen."),
            bool("sidebarCollapseHidesLanes", \.sidebarCollapseHidesLanes, .lanes, appliesLive: true,
                 "Collapsing a group in the session sidebar takes its lanes off the strip; expanding brings them back. Off, it only folds the rows."),
            bool("snapToLanes", \.snapToLanes, .galleryMotion,
                 "Settle a sideways scroll with the nearest lane centred."),
            double("snapSeconds", \.snapSeconds, .galleryMotion, 0...2, step: 0.02,
                   "How long that settle takes."),
            unsigned("releaseDistance", \.releaseDistance, .web, 0...100,
                     "Lanes off screen before a web page is taken out of the window."),
            unsigned("rehydrateDistance", \.rehydrateDistance, .web, 0...100,
                     "Lanes away before an evicted page is loaded again."),
            signed("dataStoreCount", \.dataStoreCount, .web, 1...32,
                   "How many separate cookie jars projects are spread across."),
            double("webMemorySoftFraction", \.webMemorySoftFraction, .web, 0.01...1, step: 0.01,
                   "Share of RAM web pages may hold for long before eviction starts."),
            double("webMemoryHardFraction", \.webMemoryHardFraction, .web, 0.01...1, step: 0.01,
                   "Share of RAM above which pages are evicted at once."),
            double("webMemoryTargetFraction", \.webMemoryTargetFraction, .web, 0.01...1, step: 0.01,
                   "Share of RAM eviction brings web pages back down to."),
            double("memorySampleSeconds", \.memorySampleSeconds, .web, 1...600, step: 1,
                   "How often web memory is measured. Three samples over budget start eviction."),
            bool("blocking", \.blocking, .web,
                 "Block ads and trackers in web pages with the list below. Off for one site from its lane's ⋯ menu."),
            string("blockingListUrl", \.blockingListUrl, .web,
                   "Where the blocking rules come from: WebKit content-blocker JSON, fetched daily. Several URLs, separated by spaces, are joined."),
            choice("webAutoplay", \.webAutoplay, .web, appliesLive: false,
                   "What a page may play unasked. gesture: sound needs a click, muted video may start. allow: anything plays, with sound."),
            string("fontName", \.fontName, .terminals, "The terminal font."),
            double("fontSize", \.fontSize, .terminals, 6...72, step: 1,
                   "The terminal font size, in points. ⌘= and ⌘- zoom a pane from here."),
            bool("copyOnSelect", \.copyOnSelect, .terminals,
                 "Selecting text in a terminal copies it. Off, ⌘C copies."),
            bool("copyTrimTrailing", \.copyTrimTrailing, .terminals, appliesLive: true,
                 "Copying from a terminal drops the spaces at the end of each line."),
            bool("pasteConfirmMultiline", \.pasteConfirmMultiline, .terminals, appliesLive: true,
                 "Ask before a paste of several lines: with no bracketed paste, every line but the last runs as it lands."),
            bool("pasteConfirmTabs", \.pasteConfirmTabs, .terminals, appliesLive: true,
                 "Ask before a paste with a tab in it: at a shell prompt a tab asks for completion."),
            unsigned("pasteConfirmBytes", \.pasteConfirmBytes, .terminals, 0...16_777_216, step: 1024, appliesLive: true,
                     "Ask before a paste of more bytes than this. 0 never asks about size."),
            unsigned("pasteTabWidth", \.pasteTabWidth, .terminals, 1...16, appliesLive: true,
                     "How many spaces the paste sheet's Tabs to Spaces makes of a tab."),
            bool("pasteTidy", \.pasteTidy, .terminals, appliesLive: true,
                 "Tidy pasted text: straighten smart quotes and long dashes, remove a copied \"$ \" prompt, trim stray whitespace. The pane says what it did; ⌥⌘V pastes as copied."),
            unsigned("pasteSlowChunk", \.pasteSlowChunk, .terminals, 1...1000, appliesLive: true,
                     "Paste Slowly sends this many bytes at a time."),
            unsigned("pasteSlowDelayMs", \.pasteSlowDelayMs, .terminals, 1...1000, appliesLive: true,
                     "Paste Slowly waits this many milliseconds between pieces."),
            bool("middleClickPaste", \.middleClickPaste, .terminals, appliesLive: true,
                 "A middle click pastes: the pane's selection if it has one, else the clipboard. A program with mouse reporting on keeps the click; ⌥ or ⇧ with the click pastes anyway. Off, a middle click does nothing."),
            bool("pasteImagesAsFiles", \.pasteImagesAsFiles, .terminals, appliesLive: true,
                 "⌘V of a screenshot saves it as a PNG and pastes the path; in a remote lane it is uploaded and the server's path is pasted."),
            unsigned("pasteImageKeepDays", \.pasteImageKeepDays, .terminals, 0...3650,
                     "Pasted images older than this many days are removed at launch. 0 keeps them."),
            unsigned("pasteImageMaxMb", \.pasteImageMaxMb, .terminals, 0...100, appliesLive: true,
                     "A pasted image bigger than this many MB is refused. 0 refuses nothing."),
            bool("pasteHistory", \.pasteHistory, .terminals, appliesLive: true,
                 "Keep what this app's panes pasted and copied — a terminal's, and a ⌘C in a web pane — for ⇧⌘H. Never the system clipboard at large, what a page copies for you, a password manager's copy, or a private lane. Off, nothing is kept and what was kept is deleted."),
            unsigned("pasteHistoryKeep", \.pasteHistoryKeep, .terminals, 0...10_000, appliesLive: true,
                     "How many paste history entries are kept. 0 keeps none."),
            unsigned("pasteHistoryDays", \.pasteHistoryDays, .terminals, 0...3650, appliesLive: true,
                     "Paste history entries older than this many days are removed. 0 keeps any age."),
            choice("osc52Write", \.osc52Write, .terminals, appliesLive: true,
                   "A program setting the clipboard (OSC 52: tmux, vim, a remote yank). Allowed ones show COPIED in the lane header."),
            choice("osc52Read", \.osc52Read, .terminals, appliesLive: true,
                   "A program asking to read the clipboard (OSC 52). Ask shows what would be handed over, every time."),
            choice("cursorBlink", \.cursorBlink, .terminals, appliesLive: false,
                   "Which terminal cursors blink: the one with the keyboard, all of them, or none."),
            double("sessionPollSeconds", \.sessionPollSeconds, .terminals, 1...120, step: 1,
                   "How often RelayTTY's session files are read. pty-host writes every 5 s."),
            double("doneHoldSeconds", \.doneHoldSeconds, .terminals, 0...86_400, step: 60,
                   "How long DONE stays on a finished session before it lapses to idle. Focusing the pane clears it; 0 holds it until then."),
            choice("agentNotify", \.agentNotify, .terminals, appliesLive: true,
                   "A macOS notification when an agent goes BLOCKED or DONE: away — only while Max Pane is not in front; always — in front too, except the pane with the keyboard; never."),
            optionalString("relayPtyHostPath", \.relayPtyHostPath, .terminals,
                           unset: "found next to relay on PATH",
                           "Where relay-pty-host lives, when it is not next to relay."),
            optionalString("updateCommand", \.updateCommand, .terminals,
                           unset: UpdatePlan.brewLine + ", or the release page without brew",
                           "What Help › Update… runs in a terminal lane. Relaunch is offered when it exits 0."),
            optionalString("editor", \.editor, .editorSearch, unset: FileOpen.defaultEditorTemplate,
                           "What a ⌘-clicked file opens in. %f is the path, %l the line, %c the column."),
            string("searchUrl", \.searchUrl, .editorSearch,
                   "Where the address bar sends what is not an address. %s is the query."),
            choice("theme", \.theme, .appearance, appliesLive: true,
                   "Follow the Mac's light or dark mode, or pin one."),
            bool("statusClock", \.statusClock, .appearance, appliesLive: true,
                 "The clock, battery and network at the right of the status bar while the window is fullscreen and the menu bar is away. Windowed, the menu bar has them."),
        ]
    }

    /// The table the keymap lives in.
    public static let keysTable = "keys"
    /// The array of tables the remote servers live in.
    public static let serversTable = "servers"
    /// The keys one `[[servers]]` element may carry.
    public static let serverKeys: Set<String> = ["name", "url", "enabled", "color"]
    /// The array of tables the web apps with a chord live in.
    public static let appsTable = "apps"
    /// The keys one `[[apps]]` element may carry.
    public static let appKeys: Set<String> = ["name", "url", "key", "docked"]
}

/// Something in the file that was not used, and why.
public struct ConfigProblem: Equatable, Sendable {
    /// `lane_min_pt`, `keys.closePane`, or empty for a line with no key.
    public let key: String
    public let line: Int?
    public let reason: String

    public var text: String {
        let at = line.map { "line \($0): " } ?? ""
        return key.isEmpty ? "\(at)\(reason)" : "\(at)\(key) — \(reason)"
    }
}

/// Reading `config.toml` into a `Config`, and moving an old `config.json` into
/// one.
public enum ConfigFile {
    /// The first lines of a file this app creates.
    static let header = """
        # Max Pane settings. Edit here or in Settings (⌘,); each sees the other's changes.
        # Set only what you want to change: a key that is not here keeps its default.
        """

    /// Every key read key by key, each one falling back to its default.
    ///
    /// The same rule `Config.init(from:)` has always applied to the JSON: one
    /// bad value costs that value, never the file. What changed is that the
    /// reason is kept rather than only printed, so the settings window can show
    /// which key was ignored and why.
    public static func decode(_ document: TomlDocument) -> (config: Config, problems: [ConfigProblem]) {
        var config = Config()
        var problems = document.unreadable.map { ConfigProblem(key: "", line: $0.line, reason: $0.reason + "; left as it is") }
        let fields = ConfigField.all
        var seen = Set<String>()

        var bindings: [String: [String]] = [:]
        // `[[servers]]` elements, by index, each a partial entry until every
        // key has been seen.
        var servers: [Int: (name: String?, url: String?, enabled: Bool, color: ServerColour?, line: Int)] = [:]
        // `[[apps]]` elements, the same way.
        var apps: [Int: (name: String?, url: String?, key: String, docked: AppDock?, line: Int)] = [:]
        for entry in document.entries {
            let table = entry.table
            let identity = "\(table ?? "").\(entry.key)"
            let shown = table.map { "\($0).\(entry.key)" } ?? entry.key
            if seen.contains(identity) {
                problems.append(.init(key: shown, line: entry.line, reason: "set twice; the first one is used"))
                continue
            }
            seen.insert(identity)

            if let table, let element = TomlDocument.arrayElement(table), element.name == ConfigField.serversTable {
                var server = servers[element.index] ?? (nil, nil, true, nil, entry.line)
                switch (entry.key, entry.value) {
                case (_, .failure(let error)):
                    problems.append(.init(key: shown, line: entry.line, reason: error.reason))
                case ("name", .success(.string(let s))): server.name = s
                case ("url", .success(.string(let s))): server.url = s
                case ("enabled", .success(.bool(let b))): server.enabled = b
                case ("color", .success(.string(let s))):
                    // A colour nobody defined costs that colour, never the
                    // server: it is drawn in slate and the row says why.
                    if let colour = ServerColour(rawValue: s.lowercased()) {
                        server.color = colour
                    } else {
                        server.color = .fallback
                        problems.append(.init(
                            key: shown, line: entry.line,
                            reason: "\"\(s)\" is not a server colour (\(ServerColour.names)) — using slate"))
                    }
                case ("color", .success(let v)):
                    server.color = .fallback
                    problems.append(.init(
                        key: shown, line: entry.line,
                        reason: "expected a colour name, got \(v.kind) — using slate"))
                case ("name", .success(let v)), ("url", .success(let v)):
                    problems.append(.init(key: shown, line: entry.line, reason: "expected a string, got \(v.kind)"))
                case ("enabled", .success(let v)):
                    problems.append(.init(key: shown, line: entry.line, reason: "expected true or false, got \(v.kind)"))
                default:
                    problems.append(.init(key: shown, line: entry.line, reason: "not a server setting; left as it is"))
                }
                servers[element.index] = server
                continue
            }

            if let table, let element = TomlDocument.arrayElement(table), element.name == ConfigField.appsTable {
                var app = apps[element.index] ?? (nil, nil, "", nil, entry.line)
                switch (entry.key, entry.value) {
                case (_, .failure(let error)):
                    problems.append(.init(key: shown, line: entry.line, reason: error.reason))
                case ("name", .success(.string(let s))): app.name = s
                case ("url", .success(.string(let s))): app.url = s
                // A chord that does not parse is reported by `Keymap`, on the
                // app's own row, the way `[keys]` reports one: the app keeps
                // its place in every other surface and loses only the key.
                case ("key", .success(.string(let s))): app.key = s
                case ("docked", .success(.string(let s))):
                    // An edge nobody has costs the edge, never the app.
                    if let edge = AppDock(rawValue: s.lowercased()) {
                        app.docked = edge
                    } else {
                        problems.append(.init(
                            key: shown, line: entry.line,
                            reason: "\"\(s)\" is not an edge (\(AppDock.names)) — opening in the strip"))
                    }
                case ("name", .success(let v)), ("url", .success(let v)), ("key", .success(let v)),
                     ("docked", .success(let v)):
                    problems.append(.init(key: shown, line: entry.line, reason: "expected a string, got \(v.kind)"))
                default:
                    problems.append(.init(key: shown, line: entry.line, reason: "not an app setting; left as it is"))
                }
                apps[element.index] = app
                continue
            }

            if table == ConfigField.keysTable {
                switch entry.value {
                case .failure(let error):
                    problems.append(.init(key: shown, line: entry.line, reason: error.reason))
                case .success(.string(let one)):
                    bindings[entry.key] = ["", "none", "off"].contains(one.lowercased()) ? [] : [one]
                case .success(.array(let items)):
                    let strings = items.compactMap { item -> String? in
                        if case .string(let s) = item { return s } else { return nil }
                    }
                    if strings.count == items.count {
                        bindings[entry.key] = strings
                    } else {
                        problems.append(.init(key: shown, line: entry.line, reason: "expected a chord, a list of chords, or []"))
                    }
                case .success:
                    problems.append(.init(key: shown, line: entry.line, reason: "expected a chord, a list of chords, or []"))
                }
                continue
            }
            guard table == nil else {
                let name = table!.hasPrefix("[") ? table! : "[\(table!)]"
                problems.append(.init(key: shown, line: entry.line, reason: "\(name) is not a table this file uses; left as it is"))
                continue
            }
            guard let field = fields.first(where: { $0.key == entry.key }) else {
                // The likeliest typo is the old JSON spelling.
                let hint = fields.first(where: { $0.name == entry.key }).map { " (the name here is \($0.key))" } ?? ""
                problems.append(.init(key: shown, line: entry.line, reason: "not a setting\(hint); left as it is"))
                continue
            }
            let fallback = field.defaultValue.map { " — using the default, \($0.toml)" } ?? " — using the default"
            switch entry.value {
            case .failure(let error):
                problems.append(.init(key: shown, line: entry.line, reason: error.reason + fallback))
            case .success(let value):
                if let reason = field.apply(&config, value) {
                    problems.append(.init(key: shown, line: entry.line, reason: reason + fallback))
                }
            }
        }
        config.keys = KeyBindings(bindings)
        // A server with no name or no usable URL is skipped, and says so on
        // the line its table starts at, the way a bad value is skipped and
        // its default used — except that a server has no default to use.
        for index in servers.keys.sorted() {
            let partial = servers[index]!
            let shown = "\(ConfigField.serversTable)[\(index)]"
            let entry = RelayServerEntry(
                name: partial.name ?? "", url: partial.url ?? "", enabled: partial.enabled, color: partial.color)
            if partial.name == nil {
                problems.append(.init(key: shown, line: partial.line, reason: "a server needs a name; skipped"))
            } else if partial.url == nil {
                problems.append(.init(key: shown, line: partial.line, reason: "a server needs a url; skipped"))
            } else if let why = entry.complaint {
                problems.append(.init(key: shown, line: partial.line, reason: "\(why); skipped"))
            } else if config.servers.contains(where: { $0.name == entry.name }) {
                problems.append(.init(key: shown, line: partial.line, reason: "another server is already named \"\(entry.name)\"; skipped"))
            } else {
                config.servers.append(entry)
            }
        }
        // An app with no name or no usable url is skipped the same way. A
        // name that is already taken is skipped rather than merged: the name
        // is what `maxpane app` is given and what a chord's refusal prints,
        // and two rows answering to one word is the ambiguity that makes both
        // of them useless.
        for index in apps.keys.sorted() {
            let partial = apps[index]!
            let shown = "\(ConfigField.appsTable)[\(index)]"
            let entry = WebAppEntry(
                name: partial.name ?? "", url: partial.url ?? "", key: partial.key, docked: partial.docked)
            if partial.name == nil {
                problems.append(.init(key: shown, line: partial.line, reason: "an app needs a name; skipped"))
            } else if partial.url == nil {
                problems.append(.init(key: shown, line: partial.line, reason: "an app needs a url; skipped"))
            } else if let why = entry.complaint {
                problems.append(.init(key: shown, line: partial.line, reason: "\(why); skipped"))
            } else if let held = config.apps.first(where: { $0.name.lowercased() == entry.name.lowercased() }) {
                // The name that answers is the one already in the file, so a
                // table spelled `mail` under a `Mail` says which it collided
                // with rather than quoting itself back.
                problems.append(.init(key: shown, line: partial.line, reason: "another app is already named \"\(held.name)\"; skipped"))
            } else {
                config.apps.append(entry)
            }
        }
        return (config, problems)
    }

    /// The file at `path`, read. A missing file is every default and no
    /// problems — most people never write one.
    public static func load(from path: URL) -> (config: Config, problems: [ConfigProblem], text: String?) {
        guard let data = try? Data(contentsOf: path) else { return (Config(), [], nil) }
        let text = String(decoding: data, as: UTF8.self)
        let (config, problems) = decode(TomlDocument(text))
        return (config, problems, text)
    }

    // MARK: - from config.json

    /// Copy the settings in `json` into a new `toml`, once.
    ///
    /// A no-op when `toml` already exists — including a `toml` written by an
    /// earlier migration and since edited — or when there is no `json`. The
    /// JSON is never touched: it is the record of what the settings were, and
    /// an older build still reads it. Returns true when it wrote the file.
    @discardableResult
    public static func migrate(json: URL, to toml: URL) throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: toml.path), let data = fm.contents(atPath: json.path) else { return false }
        let text = try tomlText(fromJSON: data, source: json)
        try fm.createDirectory(at: toml.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: toml, options: .atomic)
        return true
    }

    /// `config.json`'s settings as `config.toml`.
    ///
    /// Only the keys the JSON set are written, so a default the JSON left alone
    /// stays a default that follows the app. A value the JSON decoder would
    /// have skipped is skipped here too, and left behind as a comment saying
    /// so, rather than being silently lost or silently made to work.
    static func tomlText(fromJSON data: Data, source: URL) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(source.path) is not a JSON object"])
        }
        var lines = [header, "# Copied from \(source.path), which is left where it was and is no longer read.", ""]
        var scratch = Config()
        let fields = ConfigField.all
        for field in fields {
            guard let raw = dict[field.name], !(raw is NSNull) else { continue }
            guard let value = tomlValue(raw, for: field.control) else {
                lines.append("# \(field.key): \(jsonText(raw)) was skipped — config.json could not use it either")
                continue
            }
            if let reason = field.apply(&scratch, value) {
                lines.append("# \(field.key) = \(value.toml) was skipped — \(reason), in config.json too")
                continue
            }
            lines.append("\(field.key) = \(value.toml)")
        }
        let known = Set(fields.map(\.name) + ["keys"])
        for name in dict.keys.sorted() where !known.contains(name) {
            lines.append("# config.json also had \"\(name)\", which is not a setting")
        }
        if let keys = dict["keys"] as? [String: Any], !keys.isEmpty {
            lines += ["", "[\(ConfigField.keysTable)]"]
            for (command, raw) in keys.sorted(by: { $0.key < $1.key }) {
                let key = TomlDocument.bareOrQuoted(command)
                switch raw {
                case is NSNull: lines.append("\(key) = []")
                case let one as String: lines.append("\(key) = \(TomlValue.string(one).toml)")
                case let many as [String]: lines.append("\(key) = \(TomlValue.array(many.map(TomlValue.string)).toml)")
                default: lines.append("# \(key): \(jsonText(raw)) was skipped — expected a chord, a list of chords, or null")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A JSON scalar as the TOML type its field wants, or nil when it is the
    /// wrong kind entirely. `NSNumber` carries booleans too, so they are told
    /// apart by type identity rather than by value.
    private static func tomlValue(_ raw: Any, for control: ConfigControl) -> TomlValue? {
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            let isFloat = CFNumberIsFloatType(number)
            switch control {
            case .integer:
                if !isFloat { return .integer(number.int64Value) }
                let d = number.doubleValue
                return d == d.rounded() && abs(d) < 9e18 ? .integer(Int64(d)) : .float(d)
            case .number:
                // `14`, written for a number key, comes across as `14.0`, so
                // the file shows the type the key has.
                return .float(number.doubleValue)
            default:
                return isFloat ? .float(number.doubleValue) : .integer(number.int64Value)
            }
        }
        if let string = raw as? String { return .string(string) }
        return nil
    }

    private static func jsonText(_ raw: Any) -> String {
        guard JSONSerialization.isValidJSONObject([raw]),
              let data = try? JSONSerialization.data(withJSONObject: [raw]),
              let text = String(data: data, encoding: .utf8)
        else { return "\(raw)" }
        return String(text.dropFirst().dropLast())
    }
}
