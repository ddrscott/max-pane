import Foundation
import Security

/// The only place Max Pane keeps a password: the macOS Keychain.
///
/// ## The decision this file is
///
/// > "i don't mind integrating into Mac keychain. let's just not invent a new
/// > way to store passwords."
///
/// So there is no store. Not in the ledger, not in a plist, not in
/// `UserDefaults`, not in a file beside the profile, not in a temporary file,
/// not in a log line. A credential exists in this process in exactly two
/// shapes: a `String` held for the length of one function that is about to put
/// it in the Keychain or about to hand it to one form field, and the
/// process-lifetime in-memory cache `WebAuth` already keeps for HTTP
/// challenges. Everything else goes through `SecItem*`.
///
/// ## Shared with Safari, deliberately
///
/// These are `kSecClassInternetPassword` items keyed by server, protocol, port
/// and account — **the same space Safari uses**, with no service attribute of
/// our own to fence them off. That was a decision with a real alternative, so
/// here is why this side won:
///
/// - The owner is making this his full-time browser. A password saved in
///   Safari is a password he expects to be able to use here, and sharing the
///   space means Safari's logins need no import at all — reading the Keychain
///   *is* the import.
/// - It gives "forget this password" away for free, and gives it away in the
///   right place. System Settings → Passwords lists what Max Pane saved,
///   alongside everything else, with the same delete button. A private service
///   attribute would have meant a credential store only this app can see or
///   audit, which is the thing the owner said not to build wearing a different
///   hat.
/// - macOS keeps the access control. An item Safari wrote is ACL'd to Safari,
///   so the first time Max Pane reads one the system asks the user to allow
///   it. That prompt is the feature: the decision to let this app read a
///   password stays with macOS and the person, not with code in this file.
///
/// The cost is real and is stated in the README: the Keychain identifies an
/// application by its code signature, so the panel returns whenever that
/// changes. `build-app.sh` signs with a Developer ID when it finds one, which
/// is stable — but a build with no signing identity is ad-hoc, and an ad-hoc
/// signature is a different application every time it is made.
///
/// ## What is never logged
///
/// Nothing in this file passes a password, an account name, or a `SecItem`
/// attribute dictionary to `Log`. The most it will ever say is an origin and
/// an `OSStatus`. `WebAuth` holds the same line for HTTP challenges and the
/// reasoning there applies here without change.
enum KeychainPasswords {
    // MARK: - what a saved login is

    /// What kind of sign-in a saved item is for.
    ///
    /// It matters because one host routinely has both: a `<form>` login for
    /// the site and an HTTP-auth credential for a directory under it, with
    /// different user names. `kSecAttrAuthenticationType` is the Keychain's own
    /// field for exactly this, so it is used for exactly this.
    enum Kind: Equatable {
        /// A password typed into a page's form.
        case htmlForm
        /// A 401. The realm is the server's own label and is stored in
        /// `kSecAttrSecurityDomain`, which is what that attribute is for.
        case httpAuth(method: String)

        /// `kSecAttrAuthenticationType`, or nil to leave it unset.
        var authenticationType: CFString? {
            switch self {
            case .htmlForm:
                return kSecAttrAuthenticationTypeHTMLForm
            case .httpAuth(let method):
                switch method {
                case NSURLAuthenticationMethodHTTPDigest: return kSecAttrAuthenticationTypeHTTPDigest
                case NSURLAuthenticationMethodNTLM: return kSecAttrAuthenticationTypeNTLM
                default: return kSecAttrAuthenticationTypeHTTPBasic
                }
            }
        }
    }

    /// One saved login, **without its password**.
    ///
    /// The separation is the design and not a convenience. Drawing the menu of
    /// accounts for a site is a listing; filling one is a read of a secret.
    /// Keeping them as two calls means the picker on screen — which the user
    /// may never choose from, and which exists while a page is running — never
    /// holds a password at all, and the read that does happens after the click,
    /// for one account, once.
    struct SavedLogin: Equatable {
        let origin: PasswordOrigin
        let account: String
        /// `kSecAttrSecurityDomain` — the HTTP-auth realm, absent for a form.
        let realm: String?
        let isHTTPAuth: Bool
        let modified: Date?

        /// What the menu shows. An account is allowed to be empty: Chromium
        /// and Safari both store password-only logins, and a blank menu item
        /// would be unclickable in a way the user could not explain.
        var menuTitle: String { account.isEmpty ? "(no user name)" : account }
    }

    // MARK: - reading

    /// Every account saved for `origin`, newest first. No passwords.
    ///
    /// One query for both kinds, filtered afterwards in `classify`, rather than
    /// a query per `kSecAttrAuthenticationType`. The reason is interoperation:
    /// items written by other apps routinely leave that attribute unset — every
    /// `inet` item on this machine does — and a query that demanded
    /// `kSecAttrAuthenticationTypeHTMLForm` would silently see none of them.
    /// A shared keychain space that only finds its own writes is a private
    /// store with extra steps.
    static func accounts(for origin: PasswordOrigin) -> [SavedLogin] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin.host,
            kSecAttrProtocol as String: origin.keychainProtocol,
            kSecAttrPort as String: origin.keychainPort,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        // Safari's passwords are synchronizable items when iCloud Keychain is
        // on, and a query that does not say so does not see them. `Any` is the
        // only value that returns both kinds in one pass.
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            // `errSecItemNotFound` is the ordinary answer for a site with no
            // saved password and is not worth a line. Anything else is, and the
            // line names the origin and the status — never an attribute.
            if status != errSecItemNotFound {
                Log.warn("keychain lookup for \(origin.label) failed: \(status)")
            }
            return []
        }
        return classify(items, origin: origin)
    }

    /// Turn raw `SecItem` attribute dictionaries into logins.
    ///
    /// Pure, and separate from the query, because this is the half with rules
    /// in it and the half a test can reach. The Keychain cannot be exercised
    /// from a test suite without writing into the owner's real login keychain,
    /// which is not a thing a test may do.
    static func classify(_ items: [[String: Any]], origin: PasswordOrigin) -> [SavedLogin] {
        items.map { item in
            let type = item[kSecAttrAuthenticationType as String]
            return SavedLogin(
                origin: origin,
                account: item[kSecAttrAccount as String] as? String ?? "",
                realm: item[kSecAttrSecurityDomain as String] as? String,
                // Unset counts as a form login. That is the generous half of
                // the interoperation rule above: an item some other app wrote
                // without an authentication type is far more likely to be a
                // site password than a 401, and the origin has already been
                // matched exactly either way.
                isHTTPAuth: isHTTPAuthType(type),
                modified: item[kSecAttrModificationDate as String] as? Date)
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// `kSecAttrAuthenticationType` is a four-character code, and comes back
    /// from `SecItemCopyMatching` as an `NSNumber` rather than as the `CFString`
    /// constant that was passed in — which is why this compares numbers.
    static func isHTTPAuthType(_ value: Any?) -> Bool {
        guard let code = fourCharCode(value) else { return false }
        return [
            kSecAttrAuthenticationTypeHTTPBasic,
            kSecAttrAuthenticationTypeHTTPDigest,
            kSecAttrAuthenticationTypeNTLM,
        ].contains { fourCharCode($0) == code }
    }

    /// `'form'` as a `UInt32`, whichever of the three shapes the Keychain hands
    /// it back in: an `NSNumber`, a `CFString` constant, or a plain string.
    static func fourCharCode(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber { return number.uint32Value }
        guard let text = value as? String, text.utf8.count == 4 else { return nil }
        return text.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    /// The password for one saved login. **The only call in the app that
    /// returns one out of the Keychain.**
    ///
    /// This is where macOS may show its own "Max Pane wants to use a password
    /// from your keychain" panel, for an item another app wrote. That panel is
    /// not in the way of the feature, it *is* the feature's access control, so
    /// nothing here tries to suppress it or to pre-authorise anything.
    static func password(for login: SavedLogin) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: login.origin.host,
            kSecAttrProtocol as String: login.origin.keychainProtocol,
            kSecAttrPort as String: login.origin.keychainPort,
            kSecAttrAccount as String: login.account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        if let realm = login.realm { query[kSecAttrSecurityDomain as String] = realm }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecItemNotFound && status != errSecUserCanceled {
                Log.warn("keychain read for \(login.origin.label) failed: \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - writing

    /// Save, or update what is already there for this account.
    ///
    /// `SecItemAdd` then `SecItemUpdate` on `errSecDuplicateItem`, rather than
    /// delete-then-add: an item the user has granted other applications access
    /// to keeps that grant through an update and loses it through a delete, and
    /// silently narrowing someone's Keychain ACL is not a thing a browser
    /// should do while saving a password.
    @discardableResult
    static func save(origin: PasswordOrigin,
                     account: String,
                     password: String,
                     kind: Kind = .htmlForm,
                     realm: String? = nil,
                     label: String? = nil) -> Bool {
        guard let secret = password.data(using: .utf8) else { return false }

        var attributes: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin.host,
            kSecAttrProtocol as String: origin.keychainProtocol,
            kSecAttrPort as String: origin.keychainPort,
            kSecAttrAccount as String: account,
        ]
        if let type = kind.authenticationType {
            attributes[kSecAttrAuthenticationType as String] = type
        }
        if let realm, !realm.isEmpty {
            attributes[kSecAttrSecurityDomain as String] = realm
        }
        // What Passwords.app and Keychain Access show in their first column.
        // The origin, because "what site is this for" is the only question
        // anyone asks of that list.
        attributes[kSecAttrLabel as String] = label ?? origin.host

        var add = attributes
        add[kSecValueData as String] = secret
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecSuccess { return true }
        guard status == errSecDuplicateItem else {
            Log.warn("keychain save for \(origin.label) failed: \(status)")
            return false
        }

        // The query half must not carry the label: it is the one attribute the
        // user is free to rename in Keychain Access, and a query that insisted
        // on ours would fail to find the item it just collided with and then
        // fail to add it either — a save that reports success twice and writes
        // nothing.
        var query = attributes
        query.removeValue(forKey: kSecAttrLabel as String)
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        let updated = SecItemUpdate(
            query as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if updated != errSecSuccess {
            Log.warn("keychain update for \(origin.label) failed: \(updated)")
        }
        return updated == errSecSuccess
    }

    /// Forget one. Used by nothing today except the tests' own cleanup — the
    /// place to delete a saved password is System Settings → Passwords, which
    /// is half the reason the items live in the shared space.
    @discardableResult
    static func remove(origin: PasswordOrigin, account: String, realm: String? = nil) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: origin.host,
            kSecAttrProtocol as String: origin.keychainProtocol,
            kSecAttrPort as String: origin.keychainPort,
            kSecAttrAccount as String: account,
        ]
        query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        if let realm, !realm.isEmpty { query[kSecAttrSecurityDomain as String] = realm }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - the HTTP-auth seam

    /// The saved credential for an HTTP challenge, if there is one.
    ///
    /// The protection space is WebKit's, so the host, port and scheme are the
    /// ones it actually connected to. The realm is matched too: one host
    /// protecting two directories with two passwords is ordinary, and the
    /// realm is the only thing that tells them apart.
    static func credential(for space: URLProtectionSpace) -> URLCredential? {
        guard let origin = PasswordOrigin(
            url: URL(string: "\(space.protocol ?? "https")://\(space.host):\(space.port)"))
        else { return nil }
        let realm = space.realm ?? ""
        let candidates = accounts(for: origin).filter { login in
            guard login.isHTTPAuth else { return false }
            guard !realm.isEmpty else { return true }
            return login.realm == nil || login.realm == realm
        }
        guard let best = candidates.first, let password = password(for: best) else { return nil }
        // `.forSession`, always. The credential is already in the Keychain
        // because someone put it there on purpose; handing CFNetwork
        // `.permanent` would ask it to write a *second* copy under attributes
        // we do not control, which is the invisible disk write `WebAuth` was
        // built to avoid.
        return URLCredential(user: best.account, password: password, persistence: .forSession)
    }

    /// Save what was typed into the sign-in sheet, because the checkbox was
    /// ticked. Never called without it.
    @discardableResult
    static func save(credential user: String,
                     password: String,
                     for space: URLProtectionSpace) -> Bool {
        guard let origin = PasswordOrigin(
            url: URL(string: "\(space.protocol ?? "https")://\(space.host):\(space.port)"))
        else { return false }
        return save(origin: origin,
                    account: user,
                    password: password,
                    kind: .httpAuth(method: space.authenticationMethod),
                    realm: space.realm)
    }
}
