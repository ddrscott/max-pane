import Foundation
import Security

/// Which site a saved password belongs to — scheme, host and port, and nothing
/// else.
///
/// ## Why this is a type and not three strings
///
/// Every mistake a password manager can make that actually hurts someone is a
/// mistake about identity. Offering `https://example.com`'s password to
/// `http://example.com` hands it to anyone on the wire; offering it to
/// `login.example.com` hands it to whoever runs that subdomain; offering it to
/// `exampłe.com` hands it to a phisher. So the comparison happens in exactly
/// one place, it is total equality of all three fields, and there is no
/// "close enough" anywhere in this file:
///
/// - **The scheme is part of the identity.** `http` and `https` are two
///   origins to the web platform and they are two origins here. A saved
///   `https` credential is never filled into an `http` page, which is the case
///   that matters: a downgrade is exactly what an attacker on the network can
///   arrange.
/// - **The host is compared whole.** No registrable-domain match, no suffix
///   match, no subdomain match. `accounts.example.com` and `example.com` are
///   different sites and a browser that treats them as one is a browser that
///   will eventually hand a password to a user-content subdomain.
/// - **The host is IDNA-normalised by `URL` before it reaches here** and then
///   lowercased, so the comparison is between two Punycode strings and a
///   homograph cannot equal its lookalike.
///
/// ## Where the origin comes from
///
/// Only ever from `WKWebView.url` or `WKFrameInfo.securityOrigin` — values
/// WebKit computed from the load it actually committed. **Never** from
/// `document.location`, `document.domain`, a page's own report of itself, or
/// anything else the page can choose. That distinction is the whole of the
/// origin check: a page asked "who are you" will happily answer "your bank".
struct PasswordOrigin: Equatable, Hashable {
    /// Lowercase, and only ever `http` or `https`.
    let scheme: String
    /// Lowercase; Punycode for an internationalised name.
    let host: String
    /// The real port, defaults resolved — 443 for https, 80 for http. See
    /// `keychainPort` for the different number the Keychain wants.
    let port: Int

    /// `nil` for anything that is not a fillable web origin: `file:`,
    /// `about:blank`, a data URL, an FTP URL, a URL with no host.
    ///
    /// A `nil` here is what stops the whole feature on a page that has no
    /// identity to match against, which is the correct answer — there is no
    /// site to have saved a password for.
    init?(url: URL?) {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    init(scheme: String, host: String, port: Int) {
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    /// `https://example.com`, `http://localhost:8071`. The key form, with the
    /// scheme always present — `AskOrigin.key`'s conventions, because a
    /// password sheet and a permission sheet naming the same site differently
    /// would be worse than either being wrong alone.
    var key: String {
        isDefaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }

    /// What the chrome bar and the menus show: the address bar's conventions,
    /// where `https://` is the state of every page and therefore not worth
    /// saying, and `http://` is the one scheme worth noticing.
    var label: String { AskOrigin.label(scheme: scheme, host: host, port: port) }

    var isDefaultPort: Bool {
        (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
    }

    /// `kSecAttrProtocol`.
    var keychainProtocol: CFString {
        scheme == "https" ? kSecAttrProtocolHTTPS : kSecAttrProtocolHTTP
    }

    /// `kSecAttrPort`, which is **0 for a default port** and not 443.
    ///
    /// That is not our convention, it is the login keychain's: every
    /// `kSecClassInternetPassword` item on this machine written by Safari, by
    /// the system, or by `security(1)` carries `"port"<uint32>=0x00000000` for
    /// an ordinary https site — checked against the real keychain before this
    /// was written. Storing 443 instead would produce items that work
    /// perfectly for us and are invisible to everything else, which is the
    /// precise failure a shared keychain space exists to avoid.
    var keychainPort: Int { isDefaultPort ? 0 : port }

    /// The same origin as WebKit's `WKSecurityOrigin` reports it.
    ///
    /// `WKSecurityOrigin.port` is 0 for a default port, the same convention the
    /// Keychain uses and the opposite of `URL.port`, which is nil. Two zeroes
    /// meaning two different things one line apart is the kind of detail that
    /// produces a fill on the wrong port, so the conversion is here and is
    /// named.
    init?(securityOrigin: WKSecurityOriginLike) {
        let scheme = securityOrigin.originProtocol.lowercased()
        guard scheme == "http" || scheme == "https", !securityOrigin.originHost.isEmpty
        else { return nil }
        self.scheme = scheme
        self.host = securityOrigin.originHost.lowercased()
        self.port = securityOrigin.originPort == 0
            ? (scheme == "https" ? 443 : 80)
            : securityOrigin.originPort
    }
}

/// The three fields of a `WKSecurityOrigin`, as a protocol so the conversion
/// above is testable without a live web view.
///
/// `WKSecurityOrigin` cannot be constructed — WebKit hands them out and there
/// is no initialiser — so a test that wanted to assert the default-port rule
/// would otherwise have to run a page load.
protocol WKSecurityOriginLike {
    var originProtocol: String { get }
    var originHost: String { get }
    var originPort: Int { get }
}
