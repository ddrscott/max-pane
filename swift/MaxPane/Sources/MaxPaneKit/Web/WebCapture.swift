import AppKit
import WebKit

/// ⌃⌘S and ⇧⌃⌘S over a web pane: the page as a PNG (`PaneCapture`, ADR-0040).
///
/// **Visible (⌃⌘S)** is `takeSnapshot` with a default configuration: exactly
/// what the lane is showing, at the lane's width, scrolled where you left it.
///
/// **Full page (⇧⌃⌘S)** is the same call around a temporary resize. WebKit
/// will not snapshot what it has not laid out: `WKSnapshotConfiguration.rect`
/// taller than the view gives back the viewport and blank below it, because
/// the rect is read in *view* coordinates and clipped to the view. So the web
/// view is grown to the document's own height for the length of one snapshot
/// and put back. The height is the number `WebPrint` already measures for a
/// PDF — `scrollHeight` — so "the whole page" means the same thing in both
/// places; `PaneCapture.fullPageHeight` puts the ceiling on it.
///
/// **Growing it means the constraint, not the frame.** The web view is pinned
/// to `contentHost` on all four edges, so setting `frame` is undone by the
/// next layout pass — which `takeSnapshot` itself triggers, so the first
/// version of this captured the fold and claimed it was the page (measured:
/// 1 148 px either way for a 4 000 pt document). The bottom pin is
/// deactivated for the length of the snapshot and a height constraint put in
/// its place.
///
/// The resize is visible for a frame or two if the pane is on screen, which is
/// why it happens inside one turn with no animation and everything is restored
/// in a `defer`: a capture that failed must not leave a lane holding a web
/// view ten screens tall.
///
/// Under the same deadline as the PDF, for the same reason (`PDFDeadline`):
/// neither `evaluateJavaScript` nor `takeSnapshot` is promised to call back,
/// and a capture that never returns would be a key that did nothing.
extension WebPaneController {
    func capture(fullPage: Bool, completion: @escaping @MainActor (Result<Data, Error>) -> Void) {
        // `self` strongly: a capture in flight is the only thing holding this
        // turn, and a pane torn down mid-capture should still answer its
        // caller rather than drop the CLI's socket on the floor.
        Task { @MainActor in
            do {
                let image = try await PDFDeadline.run {
                    // A pane the memory policy reclaimed has no web view, and
                    // what is on screen is last eviction's snapshot. Capturing
                    // that would hand back a picture of an older page than the
                    // one the lane claims to be showing, so the page is asked
                    // for again first — which is what scrolling back to the
                    // lane would have done anyway.
                    guard let webView = try await self.pageForCapture() else {
                        throw PaneCapture.Failure.noPane
                    }
                    return try await self.snapshot(webView, fullPage: fullPage)
                }
                completion(PaneCapture.encode(image).mapError { $0 as Error })
            } catch {
                completion(.failure(error))
            }
        }
    }

    /// This pane's live web view, rehydrating an evicted one and waiting for
    /// it to finish loading. Bounded: the whole capture is already under
    /// `PDFDeadline`, and this must not be the thing that eats all of it.
    private func pageForCapture() async throws -> WKWebView? {
        if webView == nil {
            reparentIfNeeded()
            rehydrate()
        }
        guard let webView else { return nil }
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return webView
    }

    /// A capture that failed, as a row in the download bar — where Save as
    /// PDF puts its failures, and where "where did that file go" already has
    /// an answer. Named after what was attempted, since no file was written.
    func reportFailedCapture(_ why: String) {
        downloads.append(DownloadJob(
            saved: URL(fileURLWithPath: PaneCapture.stemPrefix + ".png"), failed: why))
        refreshDownloadBar()
    }

    /// True when the last full-page capture actually reached past the fold.
    /// The pane's notice reads this so it never claims "full page" for a page
    /// that fits on one screen.
    private static func measure(_ webView: WKWebView) async -> Double {
        let measured = try? await webView.evaluateJavaScript(
            "Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0)")
        return (measured as? NSNumber)?.doubleValue ?? 0
    }

    private func snapshot(_ webView: WKWebView, fullPage: Bool) async throws -> CGImage? {
        var grown: NSLayoutConstraint?
        defer {
            if let grown {
                NSLayoutConstraint.deactivate([grown])
                contentBottomPin.map { NSLayoutConstraint.activate([$0]) }
                contentHost.layoutSubtreeIfNeeded()
            }
        }

        if fullPage, let pin = contentBottomPin {
            let viewport = webView.bounds.height
            let document = await Self.measure(webView)
            let height = PaneCapture.fullPageHeight(document: document, viewport: viewport)
            if height > viewport {
                let taller = webView.heightAnchor.constraint(equalToConstant: height)
                NSLayoutConstraint.deactivate([pin])
                NSLayoutConstraint.activate([taller])
                grown = taller
                // Now, not at the next display pass: the snapshot below is
                // about to read what this laid out.
                contentHost.layoutSubtreeIfNeeded()
                // WebKit lays the page out against the new viewport on its own
                // turn, so give it one before asking for pixels.
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        let configuration = WKSnapshotConfiguration()
        // The whole view, however tall it currently is. `afterScreenUpdates`
        // defaults to true, which is what makes the growth above take effect
        // before the pixels are read.
        configuration.rect = CGRect(origin: .zero, size: webView.bounds.size)
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))

        let image: NSImage? = try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: image) }
            }
        }
        return image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
