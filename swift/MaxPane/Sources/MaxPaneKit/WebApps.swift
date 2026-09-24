import Foundation
import LanedCore

/// A chord per web app: what `[[apps]]` means once it meets the strip.
///
/// Omarchy gives an installed web app a `Super+Shift+E` of its own, and the
/// thing that makes the key worth learning is that it means one thing forever.
/// A bookmark on ⌘4 does not: ⌘4 is the fourth row of *this* ranking, and the
/// ranking moves every hour. So the chord here is not "open a page" either —
/// it is **go to the app**: focus the lane already showing it, and open one
/// only when there is none. Pressing it twice is pressing it once.
///
/// Pure, over a `[Lane]` snapshot, so the two decisions worth being sure of —
/// which lane counts as "already open" and which one wins when several do —
/// are answerable in a test with no window and no WebKit.
public enum WebApps {
    /// The lane this app is already on, or nil.
    ///
    /// **Matching is by registrable domain**, the same notion the per-site ad
    /// blocking exemption switches on (`ContentBlocker.domain(of:)`), for the
    /// same reason: `mail.google.com`, `www.google.com/mail` and a page three
    /// redirects deep into the same site are one site to the person who has
    /// one key for it, and an exact-URL match would open a second Gmail lane
    /// the moment you read a message. The cost is the other direction —
    /// `docs.google.com` and `mail.google.com` are one domain, so two apps on
    /// `google.com` find each other's lanes. Two apps on one registrable
    /// domain are one app to this matcher, which is the honest reading of a
    /// rule stated in domains.
    ///
    /// **Several matching lanes: the most recently focused.** Not the
    /// leftmost, which would make the chord depend on where the lane happens
    /// to sit, and not the newest, which sends you to the copy you have never
    /// looked at. `lastFocusAt` is the one ordering that answers "the Gmail I
    /// was using", and it is what eviction and ⌘P already rank by.
    public static func lane(for app: WebAppEntry, in lanes: [Lane]) -> Lane? {
        guard let domain = app.domain else { return nil }
        return lanes
            .filter { lane in
                lane.panes.contains { pane in
                    pane.kind == .web && ContentBlocker.domain(of: paneHost(pane)) == domain
                }
            }
            .max { $0.lastFocusAt < $1.lastFocusAt }
    }

    /// The web pane in that lane to put the keyboard in: the first one on the
    /// app's site, so a split lane with a terminal under the page focuses the
    /// page.
    public static func pane(for app: WebAppEntry, in lane: Lane) -> Pane? {
        guard let domain = app.domain else { return nil }
        return lane.panes.first {
            $0.kind == .web && ContentBlocker.domain(of: paneHost($0)) == domain
        }
    }

    /// The app that answers to this name, case-insensitively — what
    /// `maxpane app NAME` and a picker row are given. Exact first, so an app
    /// called `mail` is never shadowed by one called `mailchimp`; then a
    /// unique prefix, because typing the whole name into a shell is the part
    /// people stop doing.
    public static func named(_ name: String, in apps: [WebAppEntry]) -> WebAppEntry? {
        let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        if let exact = apps.first(where: { $0.name.lowercased() == wanted }) { return exact }
        let prefixed = apps.filter { $0.name.lowercased().hasPrefix(wanted) }
        return prefixed.count == 1 ? prefixed[0] : nil
    }

    /// The host of the page a pane is on, from the ledger's `url`.
    private static func paneHost(_ pane: Pane) -> String? {
        guard let url = pane.url, let parsed = URL(string: url) else { return nil }
        return parsed.host
    }
}
