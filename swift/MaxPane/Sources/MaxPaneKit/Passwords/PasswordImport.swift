import Foundation
import LanedCore

/// Moving another browser's saved passwords into the macOS Keychain.
///
/// ## Where each half runs, and why the line is there
///
/// `laned-core` copies `Login Data` — the copy, its journal and its WAL, opened
/// read-write so a hot journal rolls back, exactly as the history import does —
/// reads the rows, deletes the copy, and hands back **ciphertext**. It cannot
/// do anything else: the key is a macOS Keychain item and that crate has no
/// Keychain. This file is the other half. It asks macOS for the key, which is
/// the moment the user consents, opens each blob in this process, and puts the
/// result straight into the Keychain.
///
/// The consequence worth stating: **a plaintext password from another browser
/// exists for the length of one loop iteration and is never written anywhere
/// but the Keychain.** Not to a variable that outlives the loop, not to an
/// array, not to the report — the report is counters — and not to a log line.
enum PasswordImport {
    /// What an import did, entirely in numbers.
    ///
    /// Counters and not a list, deliberately. A list of what was imported is a
    /// list of the sites someone has accounts on, and the only screen it would
    /// appear on is one the user is already looking at System Settings →
    /// Passwords for.
    struct Report: Equatable {
        /// Rows the browser had, after `laned-core` dropped the ones that are
        /// refusals and federated sign-ins rather than passwords.
        var found = 0
        /// Written to the Keychain: added, or updated in place where an item
        /// for that site and account already existed.
        var saved = 0
        /// The blob was not a `v10` AES blob, or did not decrypt to text. A
        /// row from a Chromium old enough to have used the Keychain directly
        /// lands here, and so would a wrong key.
        var unreadable = 0
        /// Not a web origin we can key a Keychain item by — an extension URL,
        /// an `android://` entry synced from a phone, a malformed row.
        var notAWebsite = 0
        /// The Keychain refused the write.
        var refused = 0

        var isEmpty: Bool { found == 0 }
    }

    /// Where one source login belongs in the Keychain.
    ///
    /// Pure, and the part worth testing: `signon_realm` is Chromium's identity
    /// for a site and it is spelled two ways. `https://example.com/` for a form
    /// login, and `https://example.com:8443/Private Files` for an HTTP-auth
    /// one, where the path is the realm. Getting that wrong would file a 401
    /// credential as a form password, and it would then be offered to any form
    /// on the site.
    ///
    /// `nil` for a row with no web origin. Chromium's table holds
    /// `android://...` rows synced from a phone and `chrome-extension://` rows;
    /// neither is a site this browser can ever fill, and inventing a Keychain
    /// item for one would put a row in the user's password list that nothing
    /// can ever use or explain.
    static func placement(
        for login: SourceLogin
    ) -> (origin: PasswordOrigin, kind: KeychainPasswords.Kind, realm: String?)? {
        let realmURL = URL(string: login.signonRealm)
        guard let origin = PasswordOrigin(url: realmURL) ?? PasswordOrigin(url: URL(string: login.origin))
        else { return nil }

        if login.isHtmlForm {
            return (origin, .htmlForm, nil)
        }
        // The realm is the path of the signon realm, which Chromium writes as
        // `<origin>/<realm>`. An empty one is legal — a server may protect a
        // space with no name — and becomes nil rather than "".
        let path = (realmURL?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return (origin, .httpAuth(method: NSURLAuthenticationMethodHTTPBasic),
                path.isEmpty ? nil : path)
    }

    /// Decrypt and save every login. One pass, no list kept.
    ///
    /// Not `async`: every call in it is a synchronous `SecItem` call, and the
    /// caller runs the whole thing off the main actor. Doing the Keychain work
    /// on a background queue matters — `SecItemAdd` against an item another
    /// application owns can put a panel on screen, and a main-thread loop of
    /// four hundred of those would be a beachball with a dialog behind it.
    static func run(logins: [SourceLogin], key: Data) -> Report {
        var report = Report()
        report.found = logins.count
        for login in logins {
            guard let place = placement(for: login) else {
                report.notAWebsite += 1
                continue
            }
            guard let password = ChromiumSafeStorage.decrypt(login.secret, key: key),
                  !password.isEmpty
            else {
                report.unreadable += 1
                continue
            }
            let ok = KeychainPasswords.save(
                origin: place.origin,
                account: login.username,
                password: password,
                kind: place.kind,
                realm: place.realm)
            // `password` goes out of scope here, and it is the only place in
            // Max Pane that has ever held another browser's password.
            if ok { report.saved += 1 } else { report.refused += 1 }
        }
        return report
    }
}
