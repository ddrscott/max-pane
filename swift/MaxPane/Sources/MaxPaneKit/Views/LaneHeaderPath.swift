import Foundation

/// Fitting a working directory into the few characters a lane header has left.
///
/// The path is the second most valuable thing in the header — it is what tells
/// you *which* `claude` this is when six of them are called "Latest commit
/// changes" — but it is also the longest string in the row and it loses the
/// fight for space with the title. So it has to shrink well, and "well" is a
/// decision, not a default.
///
/// The rule here: **abbreviate, then drop leading components, then head-truncate
/// the last one.** `/Users/spierce/code/trifecta-discovery` becomes
/// `~/code/trifecta-discovery`, then `…/code/trifecta-discovery`, then
/// `…/trifecta-discovery`, then `…covery`.
///
/// Why not tail truncation (`/Users/spierce/code/trifecta-…`, which is what the
/// bar does): every session on this machine lives under `/Users/spierce/code`,
/// so a tail-truncated path spends its whole budget printing the prefix that is
/// identical on every lane and then elides the one word that distinguishes them.
/// The bar gets away with it because a wide pane leaves room for a few
/// distinguishing characters; a 420pt lane does not. Middle truncation
/// (`/Users/…/trifecta-discovery`) keeps the root, but the root is `/Users` on
/// every single lane too.
///
/// Dropping whole components rather than characters keeps the result a
/// legitimate-looking suffix of a path instead of a word cut mid-syllable, which
/// matters when you are scanning ten of them at once.
enum LaneHeaderPath {
    static let ellipsis = "…"

    /// The header string for `path` in a field `maxChars` monospace cells wide.
    /// Returns `""` when there is not enough room to say anything true.
    static func fit(_ path: String, maxChars: Int) -> String {
        let abbreviated = abbreviate(path)
        guard maxChars > 0, !abbreviated.isEmpty else { return "" }
        if abbreviated.count <= maxChars { return abbreviated }

        // Drop leading components while keeping the separator, so the result
        // still reads as a path: `…/code/trifecta-discovery`.
        let components = abbreviated.split(separator: "/", omittingEmptySubsequences: true)
        for drop in 1..<max(components.count, 1) {
            let kept = components[drop...].joined(separator: "/")
            let candidate = ellipsis + "/" + kept
            if candidate.count <= maxChars { return candidate }
        }

        // Not even `…/<last component>` fits. Keep the tail of the last
        // component — the end of a directory name is more distinguishing than
        // its beginning (`trifecta-discovery` vs `trifecta-artifacts`).
        let last = components.last.map(String.init) ?? abbreviated
        guard maxChars > 1 else { return ellipsis }
        let keep = maxChars - 1
        return ellipsis + String(last.suffix(keep))
    }

    /// `$HOME` → `~`, the way every shell prompt and the bar itself print it.
    /// Worth 12 characters on this machine, which is most of a directory name.
    ///
    /// The `~` rule itself lives on `SessionTelemetry` because the sidebar groups
    /// by it; if the two ever disagreed, a lane and its sidebar row would claim
    /// to be in different directories.
    static func abbreviate(_ path: String) -> String {
        var path = path
        // A trailing slash is never information; it is just a wasted cell.
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return "" }
        return SessionTelemetry.abbreviate(path)
    }
}
