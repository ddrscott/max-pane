import Foundation

/// Notices whenever the config file is saved.
///
/// `ConfigStore` is what listens: it reads `config.toml` again, applies `theme`
/// — the one key the running app re-reads — and refreshes an open settings
/// window. The watch exists because a setting that says it applies live has to
/// apply when the file is edited, and the file is most often edited in a
/// terminal lane *inside* this app, so "re-read when the app comes back to the
/// front" would never fire.
///
/// Two sources, because editors save two ways. An in-place write changes the
/// file; an atomic save renames a new file over it, which the old file's watch
/// sees as a delete and the directory sees as a write. The directory's watch is
/// also what notices a config file created where there was none, which is the
/// common case: most people never write one.
@MainActor
public final class ConfigWatch {
    private let path: URL
    private let onSave: @MainActor () -> Void
    nonisolated(unsafe) private var directorySource: DispatchSourceFileSystemObject?
    nonisolated(unsafe) private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// A burst of events — a rename, then attributes, then a write — is one save.
    static let settle: TimeInterval = 0.1

    /// Called after each save, settled. The caller reads the file.
    public init(path: URL, onSave: @escaping @MainActor () -> Void) {
        self.path = path
        self.onSave = onSave
        directorySource = Self.source(
            for: path.deletingLastPathComponent().path, events: [.write, .rename, .delete]
        ) { [weak self] in self?.changed() }
        watchFile()
    }

    /// Called with the file read into a `Config`.
    public convenience init(path: URL = Config.path, onChange: @escaping @MainActor (Config) -> Void) {
        self.init(path: path, onSave: { onChange(Config.load(from: path)) })
    }

    deinit {
        directorySource?.cancel()
        fileSource?.cancel()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = Self.source(for: path.path, events: [.write, .extend, .delete, .rename, .attrib]) {
            [weak self] in self?.changed()
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The file may be a different file now; watch whichever one is
                // there, or nothing until the directory says one arrived.
                self.watchFile()
                self.onSave()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    private static func source(
        for path: String, events: DispatchSource.FileSystemEvent, handler: @escaping @MainActor () -> Void
    ) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
