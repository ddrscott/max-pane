import Foundation

/// A remote relay-tty server's token, in the Keychain and nowhere else.
///
/// The token is the `session` JWT the server prints at startup, inside its
/// auth URL: `https://<slug>.relaytty.com/api/auth/callback?token=…`. The
/// owner pastes that whole line (`maxpane server add`), the URL is split into
/// the base and the token here, and the token goes into the Keychain as a
/// `kSecClassInternetPassword` item against the server's host — the same
/// space and the same store the passwords feature uses (`KeychainPasswords`),
/// so System Settings → Passwords lists it next to everything else and is
/// where it is deleted. `config.toml` carries the name and the URL only.
///
/// Nothing here logs a token, and `parseStartupURL` is the one function that
/// holds one as a `String` outside the Keychain call that stores it.
enum RelayServerTokens {
    /// The account the item is filed under. One token per server, so the
    /// account is a constant and the host is the key.
    static let account = "relay-tty"
    /// `kSecAttrSecurityDomain`, so the item is ours to find and never
    /// mistaken for a site login on the same host.
    static let realm = "relay-tty session"

    /// `{base}/api/auth/callback?token=…` → the base URL and the token. The
    /// callback path is not required: a bare base with `?token=` is taken
    /// too, since that is what a person who trimmed the line will paste.
    static func parseStartupURL(_ raw: String) -> (base: URL, token: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty
        else { return nil }
        guard let token = c.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty,
              token.allSatisfy({ $0.isLetter || $0.isNumber || "._-".contains($0) })
        else { return nil }
        c.scheme = scheme
        c.path = ""
        c.query = nil
        c.fragment = nil
        guard let base = c.url else { return nil }
        return (base, token)
    }

    private static func origin(for base: URL) -> PasswordOrigin? { PasswordOrigin(url: base) }

    /// Keep the token for the server at `base`, replacing one already there.
    @discardableResult
    static func save(_ token: String, for base: URL) -> Bool {
        guard let origin = origin(for: base) else { return false }
        return KeychainPasswords.save(
            origin: origin, account: account, password: token, kind: .htmlForm,
            realm: realm, label: "relay-tty \(origin.host)")
    }

    /// The token for the server at `base`, or nil when none was saved. This
    /// is a Keychain read, so macOS may ask the first time after a rebuild
    /// changes the app's signature.
    static func token(for base: URL) -> String? {
        guard let origin = origin(for: base) else { return nil }
        let login = KeychainPasswords.SavedLogin(
            origin: origin, account: account, realm: realm, isHTTPAuth: false, modified: nil)
        return KeychainPasswords.password(for: login)
    }

    @discardableResult
    static func remove(for base: URL) -> Bool {
        guard let origin = origin(for: base) else { return false }
        return KeychainPasswords.remove(origin: origin, account: account, realm: realm)
    }
}
