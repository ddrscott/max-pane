import Foundation

/// A remote relay-tty server's token, in the Keychain and nowhere else.
///
/// The token is the `session` JWT the server prints at startup, inside its
/// auth URL: `https://<slug>.relaytty.com/api/auth/callback?token=…`. The
/// owner pastes that whole line (Settings › Servers, or `maxpane server
/// add`), the URL is split into the base and the token here, and the token
/// goes into the Keychain as a `kSecClassInternetPassword` item against the
/// server's host — the same space and the same store the passwords feature
/// uses (`KeychainPasswords`), so System Settings → Passwords lists it next
/// to everything else and is where it is deleted. `config.toml` carries the
/// name and the URL only (ADR-0021).
///
/// Nothing here logs a token, and `parseStartupURL` is the one function that
/// holds one as a `String` outside the store call that keeps it.
enum RelayServerTokens {
    /// The account the item is filed under. One token per server, so the
    /// account is a constant and the host is the key.
    static let account = "relay-tty"
    /// `kSecAttrSecurityDomain`, so the item is ours to find and never
    /// mistaken for a site login on the same host.
    static let realm = "relay-tty session"

    /// What a pasted line came to: the server's base URL and, when the line
    /// carried one, its token.
    struct Parsed: Equatable {
        let base: URL
        let token: String?
        /// The path the line had, if it was not the callback's — kept so a
        /// caller can say "that is not the auth URL" without refusing a
        /// server that is nevertheless there.
        let path: String
        var isCallback: Bool { path.isEmpty || path == "/" || path == "/api/auth/callback" }
        var host: String { base.host ?? "" }
    }

    /// The startup line the server prints, or a bare URL, however it
    /// arrived: `Auth URL (1y): https://…/api/auth/callback?token=…`, with
    /// the terminal's colour codes, a prompt's `$ ` or a trailing `)` from
    /// a sentence, trimmed down to the one URL inside it. Nil when there is
    /// no `http(s)://host` in the text, or the token it carries is not one
    /// (a JWT is letters, digits, `.`, `_` and `-` and nothing else).
    static func parse(_ raw: String) -> Parsed? {
        var text = raw.replacingOccurrences(
            of: "\u{1b}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        // The URL is what starts at the scheme and ends at the next space.
        guard let start = text.range(of: "https?://", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        text = String(text[start.lowerBound...])
        if let end = text.firstIndex(where: { $0.isWhitespace || $0.isNewline }) { text = String(text[..<end]) }
        // Trailing punctuation from the sentence the line was pasted out of.
        while let last = text.last, ")]}>.,;'\"`".contains(last) { text.removeLast() }
        guard var c = URLComponents(string: text), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty
        else { return nil }
        let path = c.path
        var token: String?
        if let value = c.queryItems?.first(where: { $0.name == "token" })?.value {
            guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
            else { return nil }
            token = value
        }
        c.scheme = scheme
        c.host = host.lowercased()
        c.path = ""
        c.query = nil
        c.fragment = nil
        c.user = nil
        c.password = nil
        guard let base = c.url else { return nil }
        return Parsed(base: base, token: token, path: path)
    }

    /// `{base}/api/auth/callback?token=…` → the base URL and the token, for
    /// the callers that need both; a line with no token is nil here.
    static func parseStartupURL(_ raw: String) -> (base: URL, token: String)? {
        guard let parsed = parse(raw), let token = parsed.token else { return nil }
        return (parsed.base, token)
    }

    /// The name a server gets when the user gives none: the first label of
    /// its host (`yourslug.relaytty.com` → `yourslug`), the whole host when
    /// it is an address or has one label (`localhost`, `192.168.68.10`).
    static func defaultName(for base: URL) -> String {
        guard let host = base.host?.lowercased(), !host.isEmpty else { return "server" }
        let labels = host.split(separator: ".")
        if labels.count > 1, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return host }
        return String(labels.first ?? Substring(host))
    }

    /// Whether this server is reached through relaytty.com's tunnel, where
    /// the WebSocket upgrade arrives without its cookie (spike M7 §4).
    static func isTunnelled(_ base: URL) -> Bool {
        guard let host = base.host?.lowercased() else { return false }
        return host == "relaytty.com" || host.hasSuffix(".relaytty.com")
    }

    // MARK: - the store

    /// Where the tokens are kept. The Keychain in the app; a dictionary in
    /// tests, because the owner's login keychain is not a fixture and a test
    /// that wrote into it could leave a credential behind when it failed.
    struct Store: Sendable {
        var save: @Sendable (_ token: String, _ origin: PasswordOrigin) -> Bool
        var token: @Sendable (_ origin: PasswordOrigin) -> String?
        var remove: @Sendable (_ origin: PasswordOrigin) -> Bool

        static let keychain = Store(
            save: { token, origin in
                KeychainPasswords.save(
                    origin: origin, account: account, password: token, kind: .htmlForm,
                    realm: realm, label: "relay-tty \(origin.host)")
            },
            token: { origin in
                KeychainPasswords.password(for: KeychainPasswords.SavedLogin(
                    origin: origin, account: account, realm: realm, isHTTPAuth: false, modified: nil))
            },
            remove: { origin in KeychainPasswords.remove(origin: origin, account: account, realm: realm) })

        /// A store over a dictionary keyed on the origin, for tests.
        static func memory(_ box: TokenBox) -> Store {
            Store(
                save: { token, origin in box.values[origin] = token; return true },
                token: { origin in box.values[origin] },
                remove: { origin in box.values.removeValue(forKey: origin) != nil })
        }
    }

    final class TokenBox: @unchecked Sendable {
        var values: [PasswordOrigin: String] = [:]
        init() {}
    }

    nonisolated(unsafe) static var store = Store.keychain

    private static func origin(for base: URL) -> PasswordOrigin? { PasswordOrigin(url: base) }

    /// Keep the token for the server at `base`, replacing one already there.
    @discardableResult
    static func save(_ token: String, for base: URL) -> Bool {
        guard let origin = origin(for: base) else { return false }
        return store.save(token, origin)
    }

    /// The token for the server at `base`, or nil when none was saved. This
    /// is a Keychain read, so macOS may ask the first time after a rebuild
    /// changes the app's signature.
    static func token(for base: URL) -> String? {
        guard let origin = origin(for: base) else { return nil }
        return store.token(origin)
    }

    @discardableResult
    static func remove(for base: URL) -> Bool {
        guard let origin = origin(for: base) else { return false }
        return store.remove(origin)
    }
}
