import AppKit
import WebKit

/// Where a download lands and what it is called.
///
/// Pure, because every bug this can have is a string bug: a server that
/// suggests `../../.ssh/authorized_keys`, a name with a `/` in it, a second
/// copy of a file you already have. The pixels are worth a screenshot; these
/// are worth tests.
enum DownloadNaming {
    /// The directory downloads go to. `~/Downloads`, because that is where the
    /// user already looks, and because a browser that invents its own folder is
    /// a browser whose files you find six months later.
    static var directory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    }

    /// A basename that cannot escape the directory it is written into.
    ///
    /// `suggestedFilename` comes from `Content-Disposition`, which is a header
    /// the *server* writes. WebKit does some sanitising of its own and it would
    /// be reasonable to trust it; it is not reasonable to depend on it, because
    /// the cost of being wrong is a write outside `~/Downloads` and the cost of
    /// checking is two lines. Path separators and leading dots go; an empty
    /// result becomes `download`, never an empty path.
    static func sanitize(_ suggested: String) -> String {
        // The last path component, which is what every browser keeps: a
        // `Content-Disposition` of `../../.ssh/authorized_keys` names the file
        // `authorized_keys`, and the rest was never a name. Replacing the
        // separators with underscores instead would be safe and would produce
        // `_.._.ssh_authorized_keys`, which is a filename nobody wants to see.
        var name = suggested
            .split(separator: "/").last.map(String.init) ?? ""
        name = name
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A leading dot would make the file invisible in the Finder, which for
        // something the user just asked to download is the same as losing it.
        while name.hasPrefix(".") { name.removeFirst() }
        // 200 bytes leaves room for the ` 1` suffix under HFS+/APFS's 255.
        if name.utf8.count > 200 { name = String(name.prefix(200)) }
        return name.isEmpty ? "download" : name
    }

    /// A name nothing is using yet: `report.pdf`, then `report 1.pdf`, then
    /// `report 2.pdf`.
    ///
    /// **Never overwriting is the requirement**, and the reason it cannot be
    /// left to the filesystem is that `WKDownload` refuses a destination that
    /// already exists — a second download of the same file would simply fail,
    /// which is the silent nothing this whole piece is about. The suffix goes
    /// before the extension so the file still opens in the right app.
    ///
    /// `exists` is injected so the walk is testable without touching a disk.
    static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        // 1…999, then give up and take a timestamp. A thousand copies of one
        // file is not a case worth a nicer answer, but an infinite loop is a
        // case worth not having.
        for n in 1...999 {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            if !exists(candidate) { return candidate }
        }
        let stamp = Int(Date().timeIntervalSince1970)
        return ext.isEmpty ? "\(stem) \(stamp)" : "\(stem) \(stamp).\(ext)"
    }

    static func destination(for suggested: String) -> URL {
        let directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = uniqueName(sanitize(suggested)) {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        return directory.appendingPathComponent(name)
    }
}

/// One download, from the click to the file on disk.
///
/// It is owned by the pane that started it and it outlives the page: navigating
/// away mid-download does not cancel it, because `WKDownload` is not attached to
/// the document. What it must not outlive is the *pane* — `cancel()` is called
/// from `tearDown`, or the progress observation would keep firing into a row
/// that is no longer in any window.
@MainActor
final class DownloadJob: NSObject, WKDownloadDelegate {
    enum State: Equatable {
        case running
        case finished
        case failed(String)
    }

    let id = UUID()
    private(set) var name: String = "download"
    private(set) var destination: URL?
    private(set) var state: State = .running
    private(set) var received: Int64 = 0
    private(set) var expected: Int64 = -1

    /// Called on every progress tick and on every state change; the pane
    /// redraws its bar from it.
    var onChange: (() -> Void)?

    private let download: WKDownload
    private var observations: [NSKeyValueObservation] = []

    init(_ download: WKDownload) {
        self.download = download
        super.init()
        download.delegate = self
        // `WKDownload.progress` is a plain `Progress`, and its
        // `completedUnitCount` is the only byte counter the API offers — the
        // delegate has no "did receive data". Observing the two counts rather
        // than `fractionCompleted` because a response with no `Content-Length`
        // has a fraction of 0 forever, and "4.2 MB so far" is still a true
        // thing to show when a percentage is not.
        observations = [
            download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
                Task { @MainActor in self?.note(progress) }
            },
            download.progress.observe(\.totalUnitCount, options: [.new]) { [weak self] progress, _ in
                Task { @MainActor in self?.note(progress) }
            },
        ]
    }

    private func note(_ progress: Progress) {
        received = progress.completedUnitCount
        expected = progress.totalUnitCount
        onChange?()
    }

    /// `45%`, or the bytes so far when the server did not say how many there
    /// are. Never a fabricated percentage.
    var statusText: String {
        switch state {
        case .running:
            guard expected > 0 else { return ByteSize.short(received) }
            return "\(Int(Double(received) / Double(expected) * 100))%"
        case .finished:
            return ByteSize.short(received)
        case .failed(let why):
            return why
        }
    }

    var fraction: Double {
        guard expected > 0 else { return 0 }
        return min(1, Double(received) / Double(expected))
    }

    func cancel() {
        observations = []
        guard state == .running else { return }
        download.cancel { _ in }
        state = .failed("cancelled")
        onChange?()
    }

    /// Show the finished file in the Finder. The whole answer to "where did it
    /// go" is one click from the row that says it arrived.
    func reveal() {
        guard let destination, state == .finished else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        let url = DownloadNaming.destination(for: suggestedFilename)
        name = url.lastPathComponent
        destination = url
        expected = response.expectedContentLength
        Log.debug("download → \(url.path) (\(expected) bytes expected)")
        onChange?()
        completionHandler(url)
    }

    func downloadDidFinish(_ download: WKDownload) {
        observations = []
        state = .finished
        // The byte count is the file's own size rather than the last progress
        // tick: a download that finished between two observations would
        // otherwise report a number short of the truth, in the one readout the
        // user has for "did I get all of it".
        if let destination,
           let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64 {
            received = size
        }
        Log.warn("downloaded \(name) (\(ByteSize.short(received))) to \(destination?.path ?? "?")")
        onChange?()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        observations = []
        state = .failed(error.localizedDescription)
        Log.warn("download \(name) failed: \(error.localizedDescription)")
        onChange?()
    }

    /// A download behind basic auth or a client certificate. The same handler
    /// the page's own challenges go through, so a protected file downloads
    /// exactly as far as the page it came from does.
    var onChallenge: ((URLAuthenticationChallenge, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void)?

    func download(_ download: WKDownload,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let onChallenge else { return completionHandler(.performDefaultHandling, nil) }
        onChallenge(challenge, completionHandler)
    }
}
