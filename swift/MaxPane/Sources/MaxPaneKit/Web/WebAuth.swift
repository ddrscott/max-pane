import Foundation
import Security

/// Answering an HTTP authentication challenge, without ever writing a password
/// down.
///
/// ## What is stored, and where
///
/// **Nothing, anywhere, ever.** Not the ledger, not a plist, not the Keychain,
/// not a log line. A credential typed into the sheet is held in memory for the
/// life of the process, keyed by protection space, and goes when the app quits.
///
/// That is a deliberate v1 and not an oversight. The Keychain is the only
/// acceptable place for a password on disk, and using it properly means an
/// access-control decision per item, a prompt the user has to understand, and a
/// story for "forget this password" — three things that each want their own
/// round. "Ask every time you launch" is a small cost paid once a day; a
/// password written somewhere it should not be is a cost paid forever, and
/// silently.
///
/// The in-memory cache is not a compromise on that, it is what makes the
/// feature usable at all: one page behind basic auth issues a challenge for the
/// document *and* for every stylesheet, script and image it references. Without
/// the cache, opening one protected page is twenty identical sheets. The cache
/// is keyed by the protection space WebKit hands over — host, port, protocol,
/// realm and authentication method — so a credential typed for one realm is
/// never offered to another.
///
/// ## What gets printed
///
/// `MAXPANE_DEBUG` is chatty by design and this file is the one place that
/// would be a leak. Every log line here names the protection space and nothing
/// else: host, port, realm, method. Never the user, never the password, never
/// the `URLCredential`, whose `description` includes the user name. A `Log.debug`
/// of a challenge object would have been the natural thing to write and is the
/// exact bug this comment exists to prevent.
@MainActor
enum WebAuth {
    /// What kind of challenge this is, which decides who answers it.
    enum Kind: Equatable {
        /// A username and password: basic, digest, NTLM, or a proxy's version
        /// of any of them.
        case password(realm: String, isProxy: Bool)
        /// The server asked the browser to identify itself with a certificate.
        case clientCertificate
        /// A TLS certificate WebKit wants adjudicated. Deliberately handed
        /// straight back to the system: a browser that offers its user a
        /// "continue anyway" button on a bad certificate has spent the whole
        /// value of certificates, and the system's own evaluation already knows
        /// about the user's trust settings, pinning and revocation.
        case serverTrust
        /// Anything a future macOS adds. Default handling, so a challenge this
        /// build does not understand fails the way it would in Safari rather
        /// than hanging the load.
        case unsupported
    }

    static func kind(of space: URLProtectionSpace) -> Kind {
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            return .password(realm: space.realm ?? "", isProxy: space.isProxy())
        case NSURLAuthenticationMethodClientCertificate:
            return .clientCertificate
        case NSURLAuthenticationMethodServerTrust:
            return .serverTrust
        default:
            return .unsupported
        }
    }

    /// A key that separates two challenges that must not share an answer.
    ///
    /// `URLProtectionSpace` is a class with value semantics for `isEqual` but
    /// no `Hashable` conformance worth relying on across OS versions, so the
    /// key is built by hand from the five fields that define the space. The
    /// realm is in it because one host routinely protects two things with two
    /// passwords, and the method is in it because a digest credential is not a
    /// basic one.
    static func cacheKey(for space: URLProtectionSpace) -> String {
        [
            space.protocol ?? "",
            space.host,
            String(space.port),
            space.authenticationMethod,
            space.realm ?? "",
            space.isProxy() ? "proxy" : "origin",
        ].joined(separator: "|")
    }

    /// Credentials typed this session. Process lifetime, nothing on disk.
    ///
    /// Cleared on a failed attempt — `previousFailureCount > 0` means the
    /// cached answer is wrong, and re-offering it would put the pane in a loop
    /// that never shows the user a sheet and never loads the page.
    private static var remembered: [String: URLCredential] = [:]

    static func cached(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        let key = cacheKey(for: challenge.protectionSpace)
        guard challenge.previousFailureCount == 0 else {
            remembered[key] = nil
            return nil
        }
        return remembered[key]
    }

    static func remember(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        remembered[cacheKey(for: challenge.protectionSpace)] = credential
    }

    /// What `MAXPANE_DEBUG` is allowed to see.
    static func describe(_ challenge: URLAuthenticationChallenge) -> String {
        let space = challenge.protectionSpace
        return "\(space.protocol ?? "?")://\(space.host):\(space.port) "
            + "realm=\(space.realm ?? "-") method=\(space.authenticationMethod) "
            + "attempt=\(challenge.previousFailureCount + 1)"
    }
}

/// The identities the Keychain can offer a server that asks for a client
/// certificate.
///
/// Read-only: this never adds, changes or exports anything, and the private key
/// never leaves the Keychain — `SecIdentity` is a handle, and TLS signing
/// happens inside the Security framework. That is what makes "client certs" a
/// safe thing to implement without a credential store of our own.
///
/// **The known gap.** A real browser filters this list by the
/// `distinguishedNames` the server sent in its `CertificateRequest`, so an
/// internal CA's server offers only the certificates it issued. This offers
/// every identity the Keychain will hand over and lets the user pick, which is
/// correct but noisier on a machine with several. Filtering needs the issuer
/// DER of each candidate compared against the server's list; it is the obvious
/// next round and is called out here rather than left to be discovered.
enum ClientIdentities {
    struct Choice {
        let identity: SecIdentity
        let label: String
    }

    static func available() -> [Choice] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // `errSecItemNotFound` is the ordinary answer on a machine with no
        // client certificates, and is not worth a warning.
        guard status == errSecSuccess, let items = result as? [SecIdentity] else { return [] }
        return items.map { Choice(identity: $0, label: label(for: $0)) }
    }

    private static func label(for identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let summary = SecCertificateCopySubjectSummary(certificate) as String?
        else { return "certificate" }
        return summary
    }
}
