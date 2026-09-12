import Foundation

/// Per-pane zoom, remembered across a restart.
///
/// **This is in the wrong place and it is deliberate.** The README's rule is
/// that everything durable lives in `laned-core` — a zoom level is durable, so
/// it wants a `zoom_pct` column on `pane` and a line in `StripStore`, the way
/// `scroll_y` has one. `crates/` belonged to another builder for this round, so
/// it lives beside the ledger instead. When the column exists: read it in
/// `WebPaneController.init`, write it in `setZoom`, and delete this file along
/// with the `.zoom.json` it leaves behind.
///
/// What it does get right, and what a plain `UserDefaults` would not: the file
/// sits next to whichever ledger the launch is using, so `MAXPANE_LEDGER`
/// isolation still holds and a throwaway instance cannot rewrite the zoom
/// levels in the strip someone is working in.
@MainActor
final class PaneZoomStore {
    static let shared = PaneZoomStore()

    private var levels: [String: Double]
    private let url: URL

    init(ledgerPath: String = StripStore.defaultLedgerPath) {
        url = URL(fileURLWithPath: ledgerPath).deletingPathExtension()
            .appendingPathExtension("zoom.json")
        levels = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
    }

    func zoom(for paneId: String) -> Double { levels[paneId] ?? 1 }

    func setZoom(_ zoom: Double, for paneId: String) {
        // Actual size is the default, so it is stored as absence. A strip where
        // every pane is at 100% leaves no file at all, and forgetting a pane is
        // then the same operation as resetting it.
        if abs(zoom - 1) < 0.001 { levels[paneId] = nil } else { levels[paneId] = zoom }
        flush()
    }

    func forget(_ paneId: String) {
        guard levels[paneId] != nil else { return }
        levels[paneId] = nil
        flush()
    }

    /// Drop levels for panes that no longer exist, so a long-lived strip does
    /// not accumulate a row per pane ever opened.
    func sweep(keeping live: Set<String>) {
        let before = levels.count
        levels = levels.filter { live.contains($0.key) }
        if levels.count != before { flush() }
    }

    private func flush() {
        // Written whole and synchronously. It is a few hundred bytes and zoom
        // changes at the speed of a keypress; the alternative — a debounce — is
        // a timer that can be outlived by the process it is protecting.
        if levels.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(levels) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
