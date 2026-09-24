import Foundation

/// `config.toml`, held open for the settings window and the running app alike.
///
/// **The UI and the file are equals.** A change in the window is a line edit
/// written straight to the file; a save from a text editor is noticed by the
/// `ConfigWatch` this owns and read back in. Both end in the same place — a new
/// `config`, a new list of `problems`, and `didChange` — so the window cannot
/// show one thing while the file says another, whichever of them moved.
@MainActor
public final class ConfigStore {
    /// Posted, with the store as the object, after every change from either side.
    public static let didChange = Notification.Name("MaxPane.ConfigStore.didChange")

    public let path: URL
    /// The `config.json` this file was copied from, if there is one to mention.
    public let legacyPath: URL?
    /// What was read when the app started, which is what every key that is not
    /// live is still running on.
    public let launched: Config

    public private(set) var config: Config
    public private(set) var problems: [ConfigProblem]
    /// Why the last write failed, until one succeeds.
    public private(set) var writeError: String?
    private(set) var document: TomlDocument
    /// The bytes last read or written, or nil while there is no file. A save
    /// that changes nothing — our own write coming back through the watch, or
    /// a touch — is recognised by this and ignored.
    private var text: String?
    private var watch: ConfigWatch?

    public init(path: URL, legacyPath: URL? = nil, watches: Bool = true) {
        self.path = path
        self.legacyPath = legacyPath
        let (config, problems, text) = ConfigFile.load(from: path)
        self.config = config
        self.problems = problems
        self.text = text
        self.launched = config
        self.document = TomlDocument(text ?? "")
        for problem in problems { Log.warn("config: \(problem.text)") }
        if watches {
            watch = ConfigWatch(path: path) { [weak self] in self?.reloadFromDisk() }
        }
    }

    public var fileExists: Bool { text != nil }

    /// The keymap the file describes — what the next launch will run. Both
    /// sources of chords: `[keys]` and `[[apps]]`.
    public var keymap: Keymap { Keymap(overrides: config.keys, apps: config.apps) }

    /// Whether the file sets this key, as opposed to it being a default.
    public func isSet(_ field: ConfigField) -> Bool { document.entry(field.key) != nil }

    /// Whether the file's `[keys]` table names this command.
    public func isSet(_ command: Command) -> Bool {
        document.entry(command.rawValue, in: ConfigField.keysTable) != nil
    }

    /// A problem with this key, if the file has one.
    public func problem(for field: ConfigField) -> ConfigProblem? {
        problems.first { $0.key == field.key }
    }

    // MARK: - from the file

    /// Read the file again. A no-op when its bytes are the ones already held.
    public func reloadFromDisk() {
        let next = (try? Data(contentsOf: path)).map { String(decoding: $0, as: UTF8.self) }
        guard next != text else { return }
        adopt(next ?? "", exists: next != nil)
        for problem in problems { Log.warn("config: \(problem.text)") }
    }

    // MARK: - from the window

    /// Write `value` for `field`, in place. `nil` takes the key out of the
    /// file, which is what "default" means: it follows the app's default from
    /// then on, rather than pinning today's.
    public func set(_ field: ConfigField, to value: TomlValue?) {
        var next = document
        if let value { next.set(field.key, to: value) } else { next.remove(field.key) }
        write(next)
    }

    /// Bind `command` to these spellings — `[]` unbinds it — or, with nil,
    /// give it back its default key.
    public func setChords(_ command: Command, to spellings: [String]?) {
        var next = document
        if let spellings {
            next.set(command.rawValue, in: ConfigField.keysTable, to: .array(spellings.map(TomlValue.string)))
        } else {
            next.remove(command.rawValue, in: ConfigField.keysTable)
        }
        write(next)
    }

    /// Add a `[[servers]]` table, or point an existing one of that name at a
    /// new URL in place. The token is not the file's business.
    public func addServer(_ entry: RelayServerEntry) {
        var next = document
        if let table = next.arrayTables(ConfigField.serversTable).first(where: {
            if case .success(.string(let name)) = next.entry("name", in: $0)?.value { return name == entry.name }
            return false
        }) {
            next.set("url", in: table, to: .string(entry.url))
            next.set("enabled", in: table, to: .bool(entry.enabled))
            if let color = entry.color { next.set("color", in: table, to: .string(color.rawValue)) }
        } else {
            next.appendArrayTable(ConfigField.serversTable, [
                (key: "name", value: .string(entry.name)),
                (key: "url", value: .string(entry.url)),
                (key: "enabled", value: .bool(entry.enabled)),
            ] + (entry.color.map { [(key: "color", value: TomlValue.string($0.rawValue))] } ?? []))
        }
        write(next)
    }

    /// The `[[servers]]` table whose `name` is `name`, as the document names
    /// it (`servers[2]`), or nil.
    private func serverTable(named name: String, in document: TomlDocument) -> String? {
        document.arrayTables(ConfigField.serversTable).first {
            if case .success(.string(let n)) = document.entry("name", in: $0)?.value { return n == name }
            return false
        }
    }

    /// Take a server's table out of the file. The token is the Keychain's
    /// business, and its removal is the caller's (`RelayServerBook`).
    public func removeServer(named name: String) {
        var next = document
        guard let table = serverTable(named: name, in: next) else { return }
        next.removeArrayTable(table)
        write(next)
    }

    /// `enabled = …` on one server, in place; a table with no `enabled` line
    /// gains one, since the default is true and "off" has to be written.
    public func setServerEnabled(named name: String, _ enabled: Bool) {
        var next = document
        guard let table = serverTable(named: name, in: next) else { return }
        next.set("enabled", in: table, to: .bool(enabled))
        write(next)
    }

    /// `color = "violet"` on one server, in place; a table with no `color`
    /// line gains one. American in the file, like every other key.
    public func setServerColor(named name: String, _ colour: ServerColour) {
        var next = document
        guard let table = serverTable(named: name, in: next) else { return }
        next.set("color", in: table, to: .string(colour.rawValue))
        write(next)
    }

    /// `name = "new"` on one server, in place; refused when the new name is
    /// already a server's. The ledger's panes follow separately.
    @discardableResult
    public func renameServer(from old: String, to new: String) -> Bool {
        var next = document
        guard old != new, let table = serverTable(named: old, in: next),
              serverTable(named: new, in: next) == nil
        else { return false }
        next.set("name", in: table, to: .string(new))
        write(next)
        return true
    }

    // MARK: - the apps with a chord

    /// The `[[apps]]` table whose `name` is `name`, as the document names it
    /// (`apps[1]`), or nil. Case-insensitive, like every other place a name
    /// answers to `maxpane app`.
    private func appTable(named name: String, in document: TomlDocument) -> String? {
        document.arrayTables(ConfigField.appsTable).first {
            if case .success(.string(let n)) = document.entry("name", in: $0)?.value {
                return n.lowercased() == name.lowercased()
            }
            return false
        }
    }

    /// Add an `[[apps]]` table, or point an existing one of that name at a new
    /// url, key and edge in place.
    public func addApp(_ entry: WebAppEntry) {
        var next = document
        if let table = appTable(named: entry.name, in: next) {
            next.set("url", in: table, to: .string(entry.url))
            setKey(entry.key, in: table, of: &next)
            setDocked(entry.docked, in: table, of: &next)
        } else {
            next.appendArrayTable(ConfigField.appsTable, [
                (key: "name", value: .string(entry.name)),
                (key: "url", value: .string(entry.url)),
            ]
                + (entry.key.isEmpty ? [] : [(key: "key", value: TomlValue.string(entry.key))])
                + (entry.docked.map { [(key: "docked", value: TomlValue.string($0.rawValue))] } ?? []))
        }
        write(next)
    }

    public func removeApp(named name: String) {
        var next = document
        guard let table = appTable(named: name, in: next) else { return }
        next.removeArrayTable(table)
        write(next)
    }

    /// `key = "⌃⌥⌘G"` on one app, in place. An empty spelling takes the line
    /// out rather than writing `key = ""`, because "this app has no key" is a
    /// table with no `key` line.
    public func setAppChord(named name: String, to spelling: String) {
        var next = document
        guard let table = appTable(named: name, in: next) else { return }
        setKey(spelling, in: table, of: &next)
        write(next)
    }

    public func setAppURL(named name: String, to url: String) {
        var next = document
        guard let table = appTable(named: name, in: next) else { return }
        next.set("url", in: table, to: .string(url))
        write(next)
    }

    /// `docked = "left"`, or the line taken out for an app that opens in the
    /// strip.
    public func setAppDocked(named name: String, to edge: AppDock?) {
        var next = document
        guard let table = appTable(named: name, in: next) else { return }
        setDocked(edge, in: table, of: &next)
        write(next)
    }

    /// `name = "new"` on one app, in place; refused when the new name is
    /// already an app's, since the name is the identity.
    @discardableResult
    public func renameApp(from old: String, to new: String) -> Bool {
        var next = document
        let trimmed = new.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, old != trimmed, let table = appTable(named: old, in: next),
              appTable(named: trimmed, in: next) == nil
        else { return false }
        next.set("name", in: table, to: .string(trimmed))
        write(next)
        return true
    }

    private func setKey(_ spelling: String, in table: String, of document: inout TomlDocument) {
        let trimmed = spelling.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            document.remove("key", in: table)
        } else {
            document.set("key", in: table, to: .string(trimmed))
        }
    }

    private func setDocked(_ edge: AppDock?, in table: String, of document: inout TomlDocument) {
        if let edge {
            document.set("docked", in: table, to: .string(edge.rawValue))
        } else {
            document.remove("docked", in: table)
        }
    }

    /// The file, created with a header comment if there is none yet — so that
    /// "Reveal" and "Open in editor" always have something to show.
    @discardableResult
    public func ensureFileExists() -> URL {
        if !fileExists { write(TomlDocument(ConfigFile.header + "\n")) }
        return path
    }

    private func write(_ next: TomlDocument) {
        var out = next.text
        if text == nil, !out.hasPrefix("#") { out = ConfigFile.header + "\n\n" + out }
        do {
            // Through a symlink to the file it names, so a config kept in a
            // dotfiles repo stays a link rather than being replaced by a copy.
            let target = path.resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(out.utf8).write(to: target, options: .atomic)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
            Log.warn("config: could not write \(path.path): \(error.localizedDescription)")
            NotificationCenter.default.post(name: Self.didChange, object: self)
            return
        }
        adopt(out, exists: true)
    }

    private func adopt(_ newText: String, exists: Bool) {
        text = exists ? newText : nil
        document = TomlDocument(newText)
        (config, problems) = ConfigFile.decode(document)
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
