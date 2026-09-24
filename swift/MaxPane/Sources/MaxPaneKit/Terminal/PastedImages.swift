import Foundation
import RelayClient

/// Where a picture pasted into a terminal goes to become a path.
///
/// A screenshot on the clipboard has no text, and a program at a prompt takes
/// a *path* (Claude Code reads the image a path names). So ⌘V writes the
/// picture to a file and pastes the file's quoted path. For a local session
/// the file is here, in this directory; for a session on a relay server it is
/// uploaded there instead (`RelayUpload`) and nothing is written on this Mac.
///
/// `~/Library/Caches/app.ljs.maxpane/paste/` for the default profile and
/// `…/app.ljs.maxpane/profiles/<name>/paste/` for any other. Caches, because
/// these are copies of something that was on a clipboard: the system may
/// clear them, and this app clears them itself after `paste_image_keep_days`.
/// The directory is a parameter everywhere, so a test never touches the real
/// one.
public struct PastedImages {
    let directory: URL

    init(directory: URL) { self.directory = directory }

    init(profile: Profile = .current) {
        self.init(directory: Self.directory(for: profile, caches:
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]))
    }

    static func directory(for profile: Profile, caches: URL) -> URL {
        var base = caches.appendingPathComponent("app.ljs.maxpane", isDirectory: true)
        if !profile.isDefault {
            base = base.appendingPathComponent("profiles", isDirectory: true)
                .appendingPathComponent(profile.name, isDirectory: true)
        }
        return base.appendingPathComponent("paste", isDirectory: true)
    }

    /// The picture a ⌘C in a web pane copied (ADR-0041), which is written
    /// here so paste history has a path to keep. It says `copy` because that
    /// is what it was: nothing has been pasted yet, and a row in ⇧⌘H is how
    /// it gets to a prompt.
    static let copiedPrefix = "copy"

    /// The three things that land in this directory. A captured pane
    /// (`PaneCapture`, ⌃⌘S) is a picture the app made of itself rather than
    /// one off a clipboard, and a copied one is on its way to a clipboard
    /// rather than off it, so each says so in its name — and both are
    /// otherwise the same kind of file, kept on the same clock and swept by
    /// the same prune.
    static let prefixes = ["paste", PaneCapture.stemPrefix, copiedPrefix]

    /// `paste-YYYYMMDD-HHMMSS`, in this Mac's time zone: the name is for the
    /// person looking in the directory, and the file's own date is the record.
    /// `prefix` is `capture` for a captured pane and `copy` for a picture
    /// copied in a web pane.
    static func stem(at date: Date, prefix: String = "paste", timeZone: TimeZone = .current) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = timeZone
        format.dateFormat = "yyyyMMdd-HHmmss"
        return prefix + "-" + format.string(from: date)
    }

    /// The `n`th name for a stem: `paste-….png`, then `paste-…-2.png`, `-3`.
    static func name(stem: String, attempt n: Int) -> String {
        n <= 1 ? "\(stem).png" : "\(stem)-\(n).png"
    }

    /// Write `png` under a name nothing has. Two screenshots pasted in one
    /// second get `…-2`; the write itself refuses to replace a file
    /// (`O_EXCL`), so a name taken between the look and the write is the
    /// next name rather than somebody's lost picture.
    func save(_ png: Data, at date: Date = Date(), prefix: String = "paste") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = Self.stem(at: date, prefix: prefix)
        var lastError: Error = CocoaError(.fileWriteFileExists)
        for attempt in 1...1000 {
            let url = directory.appendingPathComponent(Self.name(stem: stem, attempt: attempt))
            do {
                try png.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                lastError = error
            }
        }
        throw lastError
    }

    /// Remove this directory's `paste-*.png` and `capture-*.png` files last modified more than
    /// `days` ago; 0 keeps everything. Only files of that name, and never a
    /// subdirectory: another profile's pictures live under this one's parent
    /// and a person may have put something of their own beside them.
    /// Returns what went, for the log and the test.
    @discardableResult
    func prune(olderThanDays days: Int, now: Date = Date()) -> [URL] {
        guard days > 0 else { return [] }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])) ?? []
        var removed: [URL] = []
        for url in files {
            let name = url.lastPathComponent
            guard Self.prefixes.contains(where: { name.hasPrefix($0 + "-") }), name.hasSuffix(".png"),
                  let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true, let modified = values.contentModificationDate, modified < cutoff
            else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed.append(url) }
        }
        return removed
    }

    /// The launch-time prune, off the main thread: a directory listing is not
    /// worth a frame of startup.
    public static func pruneAtLaunch(days: Int) {
        guard days > 0 else { return }
        let images = PastedImages()
        DispatchQueue.global(qos: .utility).async {
            let removed = images.prune(olderThanDays: days)
            if !removed.isEmpty {
                Log.debug("paste: removed \(removed.count) saved image\(removed.count == 1 ? "" : "s") older than \(days) days")
            }
        }
    }
}

/// `POST /api/upload` on a relay-tty server: how a file gets *to* the host.
///
/// The first piece of the plan's Phase 4 (`docs/plans/remote-relay-servers.md`
/// §4.5: remote files go through the server's API, the way the relay-tty web
/// app does it). What the web app does, and so what this does:
///
/// - `relay-tty/server/api.ts:713` — `router.post("/upload")`: the raw bytes
///   as the body, the name in an `X-Filename` header (the server keeps only
///   its basename, `:721`), written into the server's configured upload
///   directory (`readUploadDir`, `:35`, `~/.relay-tty/uploads` unless
///   `PUT /api/upload-dir` changed it). A name already there gets a random
///   suffix (`:752`), so nothing over there is overwritten either. 100 MB at
///   most (`:762`). The answer is `{"ok", "path", "name", "size"}` (`:779`),
///   `path` being the absolute path on that machine, which is what is pasted.
/// - `relay-tty/app/routes/sessions.$id.tsx:735` — the web client's
///   `uploadOne`: `fetch("/api/upload", {method: "POST", headers:
///   {"X-Filename": file.name}, body: file})`, then `path` out of the JSON.
///
/// `X-Upload-Dir` (the web app's file browser uses it, `file-browser.tsx:368`)
/// is deliberately not sent: where uploads land is the server owner's setting,
/// and the session's cwd is not this app's to fill with screenshots.
///
/// Authenticated as every other call is: the server's Keychain token as the
/// `session` cookie (`RemoteSpawner`).
final class RelayUpload: @unchecked Sendable {
    enum UploadError: LocalizedError, Equatable {
        case refused(server: String, status: Int, body: String)
        case unreachable(server: String, why: String)
        case badReply(server: String)

        var errorDescription: String? {
            switch self {
            case .refused(let server, let status, let body):
                return "\(server): could not upload the image — HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
            case .unreachable(let server, let why):
                return "\(server): could not upload the image — \(why)"
            case .badReply(let server):
                return "\(server): could not upload the image — the server's answer had no path in it"
            }
        }
    }

    let name: String
    private let endpoint: RelayServer
    private let urlSession: URLSession

    init(name: String, endpoint: RelayServer) {
        self.name = name
        self.endpoint = endpoint
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.waitsForConnectivity = false
        // Between packets, not for the whole upload: 25 MB through a hotel's
        // uplink takes as long as it takes, and a minute of silence is dead.
        config.timeoutIntervalForRequest = 60
        urlSession = URLSession(configuration: config)
    }

    /// Send `data` as `filename`; the completion gets the path on the server,
    /// on the main thread, exactly once. The request runs on URLSession's own
    /// queue, so nothing here blocks the pane.
    func upload(_ data: Data, filename: String,
                completion: @escaping @MainActor (Result<String, UploadError>) -> Void)
    {
        var c = URLComponents(url: endpoint.baseURL, resolvingAgainstBaseURL: false)!
        c.path = "/api/upload"
        var request = URLRequest(url: c.url!)
        request.httpMethod = "POST"
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token = endpoint.token {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        let name = name
        // `self` strongly, as `RemoteSpawner.post` does and for its reason:
        // the caller makes an uploader for one upload and holds nothing, and
        // an uploader that is gone takes its URLSession's answer with it.
        urlSession.uploadTask(with: request, from: data) { [self] body, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let result: Result<String, UploadError>
            if let error {
                result = .failure(.unreachable(server: name, why: (error as NSError).localizedDescription))
            } else if status != 200 {
                result = .failure(.refused(server: name, status: status, body: RemoteSpawner.errorLine(body)))
            } else if let path = Self.path(in: body) {
                result = .success(path)
            } else {
                result = .failure(.badReply(server: name))
            }
            urlSession.finishTasksAndInvalidate()
            Task { @MainActor in completion(result) }
        }.resume()
    }

    /// `{"ok": true, "path": "/home/…/paste-….png", …}`. Only an absolute
    /// path is one: anything else is not somewhere a prompt over there can
    /// reach, whatever the server meant by it.
    static func path(in data: Data?) -> String? {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String, path.hasPrefix("/")
        else { return nil }
        return path
    }
}
