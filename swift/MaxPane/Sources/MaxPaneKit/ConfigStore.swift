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

    /// The keymap the file describes — what the next launch will run.
    public var keymap: Keymap { Keymap(overrides: config.keys) }

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
        } else {
            next.appendArrayTable(ConfigField.serversTable, [
                (key: "name", value: .string(entry.name)),
                (key: "url", value: .string(entry.url)),
                (key: "enabled", value: .bool(entry.enabled)),
            ])
        }
        write(next)
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
