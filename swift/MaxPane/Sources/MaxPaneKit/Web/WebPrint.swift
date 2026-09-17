import AppKit
import UniformTypeIdentifiers
import WebKit

/// Print, and Save as PDF, for a web pane.
///
/// Boarding passes, receipts and invoices were a weekly reason to open another
/// browser: ⌘P did nothing in a pane. Now ⌃⌘P runs the system print panel over
/// the pane as a sheet — the panel is the feature, and its PDF menu already has
/// Save as PDF, so the print key is also the everyday PDF key. *Save as PDF…*
/// is the other route, for the whole page in one file: a save panel, WebKit's
/// own `createPDF` of every fold, and the result lands in the pane's download
/// bar so it appears where a download would.
///
/// Two WebKit facts shape the print half. `WKWebView.printOperation(with:)`
/// hands back a view with an empty frame, and an operation run on it prints
/// blank pages until the view is given the paper's size. And the operation
/// must be *retained* until the panel is done — `runModal(for:…)` returns at
/// once, and an operation that is released mid-panel takes the web content
/// process with it (Apple's notes on the method say so). `PrintRun` is that
/// retention, and nothing else.
enum WebPrinting {
    /// The shared print info, copied: the user's paper, orientation and margins
    /// as macOS has them, paginated to fit the page's width so a wide layout
    /// shrinks to the paper rather than spilling onto a second column of pages.
    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    /// The system print panel over `window`, for the page in `webView`. With no
    /// window — a pane whose view is not on screen — the panel is app-modal
    /// instead, which is worse than a sheet and better than nothing.
    @MainActor
    static func print(_ webView: WKWebView, over window: NSWindow?) {
        let info = printInfo()
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // The empty-frame fact above. The paper's size is what the operation
        // paginates against, so it is the only size that makes sense here.
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        PrintRun(operation).run(over: window)
    }
}

/// Holds an `NSPrintOperation` from `runModal` to `didRun`, and itself with it.
@MainActor
final class PrintRun: NSObject {
    /// Every panel still up. A run is its own retention: it puts itself here
    /// and takes itself out when the panel closes.
    private static var live: Set<PrintRun> = []
    private let operation: NSPrintOperation

    init(_ operation: NSPrintOperation) {
        self.operation = operation
    }

    /// How many print panels are open right now; the tests read it.
    static var liveCount: Int { live.count }

    func run(over window: NSWindow?) {
        Self.live.insert(self)
        guard let window else {
            let ok = operation.run()
            return finish(ok)
        }
        operation.runModal(
            for: window, delegate: self,
            didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        finish(success)
    }

    private func finish(_ success: Bool) {
        Log.debug("print \(success ? "done" : "cancelled")")
        Self.live.remove(self)
    }
}

/// What a saved PDF is called. Pure, like `DownloadNaming`, because the bugs
/// it can have are string bugs: a title with a `/` in it, no title at all, a
/// title that already ends in `.pdf`.
enum PDFNaming {
    /// The page's title, then its host, then `page`, always ending in `.pdf`.
    /// `/` becomes `-` before `DownloadNaming.sanitize` sees it, because that
    /// keeps a path's last component and "Invoice / March" is not a path.
    static func filename(title: String?, url: String?) -> String {
        var stem = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if stem.isEmpty, let url, let host = URL(string: url)?.host { stem = host }
        if stem.isEmpty { stem = "page" }
        var name = DownloadNaming.sanitize(stem.replacingOccurrences(of: "/", with: "-"))
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        return name
    }
}

enum PDFExportError: LocalizedError {
    case noPage
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .noPage: return "this pane has no page to save"
        case .timedOut(let seconds): return "the page did not render as PDF within \(Int(seconds)) s"
        }
    }
}

/// An async operation, or `PDFExportError.timedOut` after `seconds` —
/// whichever comes first.
///
/// Neither `evaluateJavaScript` nor `createPDF` is guaranteed to call back:
/// asked of a page that is mid-navigation, or whose web content process goes
/// away, WebKit drops the completion and a continuation waiting on it is
/// suspended for good — the measurement was the one caught doing it, under
/// the test suite's load. That was a Save as PDF
/// that never became a row — nothing failed, nothing finished, the user just
/// waited. So the render runs under a deadline, and a miss is the failed row
/// with the reason.
///
/// Not a task group. A group waits for every child before it returns, and a
/// child stuck on a continuation that will never be resumed is the exact hang
/// this exists to end; cancelling it changes nothing, since there is nothing
/// listening for cancellation inside WebKit's callback. Instead both sides
/// race to resume one continuation, and the loser's result is dropped: an
/// orphaned render that does come back late is discarded, and its task ends.
@MainActor
enum PDFDeadline {
    static let seconds: TimeInterval = 30

    static func run<T: Sendable>(
        within seconds: TimeInterval = Self.seconds,
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.continuation = continuation
            Task { @MainActor in
                let result: Result<T, Error>
                do { result = .success(try await operation()) } catch { result = .failure(error) }
                once.resume(result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                once.resume(.failure(PDFExportError.timedOut(seconds)))
            }
        }
    }

    /// A continuation that resumes once. Main-actor state, no lock: both racers
    /// hop to the main actor before they touch it.
    private final class Once<T: Sendable> {
        var continuation: CheckedContinuation<T, Error>?

        func resume(_ result: Result<T, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

extension WebPaneController {
    /// ⌃⌘P. The sheet hangs on the pane's window; full screen in the pane is
    /// left first, because a sheet over a fullscreen video is a sheet over
    /// nothing you can see.
    func printPage() {
        guard let webView else { return }
        leavePaneFullscreen()
        WebPrinting.print(webView, over: view.window)
    }

    /// Save as PDF…: a save panel named after the page, in `~/Downloads` where
    /// every other file from a pane goes, then `writePDF(to:)`. One at a time;
    /// a second ask while the panel is up does nothing.
    func savePDF() {
        guard let webView, savePanel == nil else { return }
        leavePaneFullscreen()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.directoryURL = DownloadNaming.directory
        panel.nameFieldStringValue = PDFNaming.filename(title: webView.title, url: webView.url?.absoluteString)
        savePanel = panel
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.savePanel = nil
                guard response == .OK, let url = panel?.url else { return }
                Task { @MainActor in await self.writePDF(to: url) }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Close a save panel this pane has up. From `tearDown`: a panel with
    /// nothing behind it would otherwise write to a pane that is gone.
    func cancelSavePanel() {
        savePanel?.cancel(nil)
        savePanel = nil
    }

    /// The whole page as PDF, written to `url`, and a row in the download bar
    /// saying so — finished with the file's size, or failed with the reason.
    /// The row is the same one a download gets, so "where did it go" has the
    /// same answer: click it, and the Finder shows the file.
    func writePDF(to url: URL) async {
        do {
            let data = try await renderPDF()
            try data.write(to: url, options: .atomic)
            downloads.append(DownloadJob(saved: url))
            Log.warn("saved \(url.lastPathComponent) (\(ByteSize.short(Int64(data.count)))) to \(url.path)")
        } catch {
            downloads.append(DownloadJob(saved: url, failed: error.localizedDescription))
            Log.warn("save as PDF failed: \(error.localizedDescription)")
        }
        refreshDownloadBar()
    }

    /// Every fold of the page, not the one on screen. `WKPDFConfiguration.rect`
    /// left nil is the view's bounds — one screen of a receipt — so the
    /// document's own height is asked for and the rect is sized to it, with a
    /// ceiling so a page that scrolls forever does not ask for a PDF that does.
    ///
    /// Under `PDFDeadline`, because neither of the two WebKit calls here is
    /// promised to call back: see the note on that type.
    func renderPDF(within seconds: TimeInterval = PDFDeadline.seconds) async throws -> Data {
        guard let webView else { throw PDFExportError.noPage }
        return try await PDFDeadline.run(within: seconds) { try await Self.render(webView) }
    }

    private static func render(_ webView: WKWebView) async throws -> Data {
        let measured = try? await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        let height = (measured as? NSNumber)?.doubleValue ?? 0
        let bounds = webView.bounds
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0, y: 0, width: bounds.width,
            height: min(max(height, bounds.height), 200_000))
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                continuation.resume(with: result)
            }
        }
    }
}
