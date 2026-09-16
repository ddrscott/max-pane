import Foundation

/// What a web pane tells sites it is.
///
/// A `WKWebView` with no `applicationNameForUserAgent` sends exactly this, and
/// nothing after it:
///
/// ```
/// Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)
/// ```
///
/// Measured, not assumed: a pane was pointed at a local server that echoed the
/// `User-Agent` header back, and `navigator.userAgent` agreed with it. There is
/// no `Version/` and no `Safari/` token, which is the exact shape every "is
/// this an embedded webview rather than a browser" check looks for. Google
/// answers it with `disallowed_useragent` at sign-in and with "This browser
/// version is no longer supported" inside its apps — the owner hit both, and
/// they are one string, not two bugs.
///
/// The fix finishes the sentence WebKit started rather than telling a different
/// story. A pane renders in the system WebKit — the same framework, at the
/// version Safari ships in lockstep with — so the `Version/` token is a true
/// statement about the engine. Claiming to be Chrome would not be.
///
/// **It is not a true statement about the feature set**, and nothing here
/// should be read as one. Measured inside a real pane: `PublicKeyCredential`
/// exists but `isUserVerifyingPlatformAuthenticatorAvailable()` returns false,
/// and `window.PaymentRequest` and `window.PushManager` are undefined. Safari 26
/// on this machine has all three. Passkeys are the one worth naming, because
/// Google pushes them hard at sign-in: a site that routes on the Safari claim
/// can offer a passkey path that dead-ends. That is a cost of this string, not
/// an argument against it — a truthful "I am a WKWebView" is exactly what got
/// the owner blocked, and Vivaldi appends its own `Vivaldi/8.1.4087.75` tail
/// for the same reason.
///
/// The version is read out of `Safari.app` at launch rather than hard-coded,
/// because a pinned number is precisely the thing that goes stale and re-creates
/// this bug a year later. `MaxPane/x.y.z` follows it so a site that cares can
/// tell this is not Safari.app driving; it is placed last, where browsers built
/// on someone else's engine have always put their own token.
enum BrowserUserAgent {
    /// Appended to WebKit's platform prefix via
    /// `WKWebViewConfiguration.applicationNameForUserAgent`.
    ///
    /// `customUserAgent` would work too and is worse: it replaces the platform
    /// prefix as well, so a future OS that changes how it describes itself would
    /// be describing itself through a string frozen here.
    /// Computed, not a `static let`. A `let` is read once per process and this
    /// app is left open for days — a Safari update mid-session would leave every
    /// pane built afterwards claiming the old version, which is the same class
    /// of staleness the plist read exists to avoid. It costs one plist read per
    /// web view built, which is a handful over a session.
    static var applicationName: String {
        token(safariVersion: installedSafariVersion() ?? fallbackSafariVersion,
              appVersion: appVersion)
    }

    /// `Version/26.6.2 Safari/605.1.15 MaxPane/0.1.0`, given those two inputs.
    ///
    /// `AppleWebKit/605.1.15` in the platform prefix and `Safari/605.1.15` here
    /// are both frozen constants that every WebKit browser sends; the moving
    /// part has been the `Version/` token since Safari 3.
    static func token(safariVersion: String, appVersion: String) -> String {
        "Version/\(safariVersion) Safari/605.1.15 MaxPane/\(appVersion)"
    }

    /// What a web pane on its Mobile Layout tells sites it is: an iPhone.
    ///
    /// Set through `customUserAgent`, which is the one case where replacing
    /// the platform prefix is the point — `applicationNameForUserAgent` can
    /// only finish WebKit's Macintosh sentence, and a site decides desktop or
    /// phone on the prefix. Computed per read for the same reason as
    /// `applicationName`.
    static var mobile: String {
        mobileToken(safariVersion: installedSafariVersion() ?? fallbackSafariVersion,
                    appVersion: appVersion)
    }

    /// `Mozilla/5.0 (iPhone; CPU iPhone OS 26_6 like Mac OS X) AppleWebKit/605.1.15
    /// (KHTML, like Gecko) Version/26.6.2 Mobile/15E148 Safari/604.1 MaxPane/0.1.0`,
    /// given those two inputs.
    ///
    /// The shape is iPhone Safari's own, token for token, with `MaxPane/` last
    /// as in `token`. The `Version/` is the installed Safari's, because it is
    /// still this machine's WebKit rendering the page. The `iPhone OS` number
    /// is derived from it — Safari and iOS have shared a major.minor since
    /// Safari 15 — so nothing here is a pinned number that goes stale.
    /// `Mobile/15E148` and `Safari/604.1` are the two constants every iPhone
    /// Safari has sent since iOS 11, the way `Safari/605.1.15` is the Mac's.
    static func mobileToken(safariVersion: String, appVersion: String) -> String {
        let parts = safariVersion.split(separator: ".").map(String.init)
        let os = parts.prefix(2).joined(separator: "_") + (parts.count < 2 ? "_0" : "")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
            + "Version/\(safariVersion) Mobile/15E148 Safari/604.1 MaxPane/\(appVersion)"
    }

    /// The installed Safari's marketing version — the number it puts in its own
    /// `Version/` token.
    ///
    /// Safari ships in lockstep with the system WebKit a pane renders in, so
    /// this describes the engine in the pane and not just a neighbouring app.
    static func installedSafariVersion(
        at path: String = "/Applications/Safari.app/Contents/Info.plist"
    ) -> String? {
        guard let plist = NSDictionary(contentsOfFile: path),
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty,
              // A plist that has been replaced by something else entirely should
              // not end up in a header verbatim.
              version.allSatisfy({ $0.isNumber || $0 == "." })
        else { return nil }
        return version
    }

    /// Only reachable on a Mac with no Safari, which is not a configuration
    /// Apple ships. Deliberately the oldest version this app's minimum macOS
    /// could have carried: understating is a worse page, overstating is a lie.
    static let fallbackSafariVersion = "17.0"

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
}
