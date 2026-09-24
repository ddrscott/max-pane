import AppKit
import LanedCore

/// ⌃⌘S: the focused pane as a PNG, and its path where a program can read it
/// (ADR-0040).
///
/// "Look at this rendering bug" used to be: leave the app, ⇧⌘4, drag a
/// rectangle, come back, ⌘V. All of that is one key here, and the picture
/// lands the way a pasted one does — a file under the profile's Caches
/// (`PastedImages`), its quoted path typed at the nearest prompt, uploaded
/// first when that prompt is on a relay server.
///
/// Everything in here is pure. The two captures themselves are AppKit and
/// WebKit calls on the pane controllers; what is decidable without a screen —
/// which prompt gets the path, how tall a full-page snapshot is, and whether
/// what came back is a picture at all — is decided here, where a test can ask.
enum PaneCapture {
    /// What one capture is called, in front of `PastedImages`' timestamp:
    /// `capture-20260923-143205.png`, beside the `paste-…` files and pruned
    /// on the same `paste_image_keep_days` clock.
    static let stemPrefix = "capture"

    // MARK: - which prompt gets the path

    /// The terminal pane a captured path should be typed into: the nearest
    /// `pty` pane in the same lane, measured in stack positions, **below
    /// first** at equal distance.
    ///
    /// Below first because a split's lower pane is where the agent usually
    /// is — ⌘D puts the new terminal under the page you were reading — and
    /// because the alternative, "whichever the ledger lists first", is not a
    /// rule anyone could predict from looking at the screen.
    ///
    /// The captured pane itself counts: capturing a terminal and typing the
    /// path into that same terminal is the ordinary case, not a special one.
    /// Nil when the lane holds no terminal at all, and the caller copies
    /// instead.
    static func nearestTerminal(to paneId: String, among panes: [Pane]) -> Pane? {
        let ordered = panes.sorted { $0.position < $1.position }
        guard let start = ordered.firstIndex(where: { $0.id == paneId }) else {
            return ordered.first { $0.kind == .pty }
        }
        if ordered[start].kind == .pty { return ordered[start] }
        for distance in 1..<max(ordered.count, 2) {
            for index in [start + distance, start - distance] where ordered.indices.contains(index) {
                if ordered[index].kind == .pty { return ordered[index] }
            }
        }
        return nil
    }

    // MARK: - how much page

    /// How tall a full-page (⇧) web snapshot should be.
    ///
    /// `document` is `scrollHeight`, which is what `WebPrint` already measures
    /// for a PDF; the same number, because "the whole page" should mean the
    /// same thing in both. Never shorter than the viewport — a page that fits
    /// has one screen to give — and never taller than `ceiling`, because an
    /// infinite scroll's `scrollHeight` grows for as long as you ask and a
    /// bitmap of it does not fit in memory.
    ///
    /// The ceiling is in points and deliberately far below the PDF's 200 000:
    /// a PDF of 200 000 points is vector text, and a PNG of it at 2× would be
    /// 700 × 400 000 pixels — about a terabyte. 20 000 points is roughly
    /// twenty screens, which is longer than anything worth sending to an
    /// agent as one picture.
    static let fullPageCeiling: Double = 20_000

    static func fullPageHeight(document: Double, viewport: Double,
                               ceiling: Double = fullPageCeiling) -> Double
    {
        guard viewport > 0 else { return 0 }
        return min(max(document, viewport), ceiling)
    }

    /// True when the ⇧ variant got no more than the fold: the page is shorter
    /// than the viewport, or WebKit would not grow. The pane says "full page"
    /// only when it got one, so the notice never claims more than the file has.
    static func isFullPage(captured: Double, viewport: Double) -> Bool {
        captured > viewport + 1
    }

    // MARK: - is this a picture

    /// A capture with nothing in it: every pixel the same colour.
    ///
    /// The guard exists because the terminal capture goes through
    /// `cacheDisplay`, which reads the view's backing layer, and a pane whose
    /// first frame has not been composited yet still has the bare
    /// `CAMetalLayer` the view was built with — a Metal drawable that
    /// `cacheDisplay` cannot see into and returns as flat nothing. A pane that
    /// has drawn once has an `IOSurfaceLayer` instead and comes back complete
    /// (measured; ADR-0040). So the blank case is real but rare, and it is
    /// better to say "the pane has not drawn yet" than to write a file that
    /// looks like a broken screenshot.
    ///
    /// Sampled on a grid rather than read whole: a 3000 × 4000 full-page
    /// capture is 48 MB of pixels and a blank one is blank everywhere, so
    /// 10 000 samples decide it as well as twelve million would.
    static func isBlank(_ image: CGImage, samples: Int = 100) -> Bool {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return true }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var first: UInt32?
        let stepX = max(1, width / samples), stepY = max(1, height / samples)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let i = (y * width + x) * 4
                let pixel = UInt32(pixels[i]) << 24 | UInt32(pixels[i + 1]) << 16
                    | UInt32(pixels[i + 2]) << 8 | UInt32(pixels[i + 3])
                guard let first else { first = pixel; continue }
                if pixel != first { return false }
            }
        }
        return true
    }

    /// The PNG bytes of a captured image, or nil when there is nothing to
    /// write. `NSBitmapImageRep` from the image's own CGImage, so a 2×
    /// capture keeps its pixels rather than being flattened to points.
    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// What went wrong, in the words the pane's notice uses.
    enum Failure: LocalizedError, Equatable {
        case noPane
        case blank
        case notEncodable

        var errorDescription: String? {
            switch self {
            case .noPane: return "nothing to capture"
            case .blank: return "the pane has not drawn anything yet"
            case .notEncodable: return "the capture could not be written as a PNG"
            }
        }
    }

    /// A captured image on its way to a file: checked for blankness, then
    /// encoded. The one door, so the terminal and the web pane cannot
    /// disagree about what counts as a picture.
    static func encode(_ image: CGImage?) -> Result<Data, Failure> {
        guard let image else { return .failure(.noPane) }
        guard !isBlank(image) else { return .failure(.blank) }
        guard let data = png(image) else { return .failure(.notEncodable) }
        return .success(data)
    }
}
