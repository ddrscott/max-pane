import CommonCrypto
import Foundation
import Security

/// Opening a Chromium password, which is the one thing `laned-core` cannot do.
///
/// ## The scheme, measured rather than remembered
///
/// Every Chromium fork on macOS encrypts each saved password with one AES key
/// derived from a single random string it keeps in the login keychain as
/// `<Browser> Safe Storage`. The blob in `logins.password_value` is:
///
/// ```
/// "v10" ‖ AES-128-CBC( PKCS#7(password), key, iv = 16 × 0x20 )
/// ```
///
/// with `key = PBKDF2-HMAC-SHA1(safeStorage, salt: "saltysalt", rounds: 1003,
/// length: 16)`.
///
/// **CBC, not GCM.** The ticket said AES-GCM, which is what Chromium uses on
/// Windows. The owner's real Vivaldi profile says otherwise and says it
/// unambiguously: all 442 encrypted rows begin with the bytes `v10`, and every
/// one of them has a remainder that is an exact multiple of 16. A GCM blob
/// carries a 12-byte nonce and a 16-byte tag and is not block-aligned; a
/// thousand of them being block-aligned by chance is not a thing that happens.
/// The measurement is written down here because the two schemes fail
/// differently — GCM tells you the key was wrong, CBC hands back plausible
/// rubbish — so a wrong guess would have been discovered by a user, in their
/// Keychain, rather than here.
///
/// ## What is not here
///
/// No caching of the derived key beyond the import that asked for it, no
/// writing it anywhere, and no logging of anything derived from it. The only
/// thing this file ever hands out is one `String`, to one caller, which puts it
/// in the Keychain and drops it.
enum ChromiumSafeStorage {
    /// The three constants Chromium fixed in 2011 and has not moved since.
    /// Named rather than inlined because each is a silent-wrong-answer if
    /// mistyped: a wrong round count derives a wrong key, and a wrong key
    /// under CBC decrypts to bytes rather than to an error.
    static let salt = "saltysalt"
    static let rounds: UInt32 = 1003
    static let keyLength = 16
    /// Sixteen spaces. Chromium's own `OSCrypt` calls it `kIVBlockSizeAES128`
    /// and fills it with `' '`.
    static let iv = [UInt8](repeating: 0x20, count: 16)
    /// The three bytes in front of every ciphertext, naming the scheme.
    static let version = Data("v10".utf8)

    /// Why the key could not be had. Each of these is a different sentence to
    /// the user and none of them is "import failed".
    enum KeyError: Error, Equatable {
        /// The browser has never saved a password, so there is no item.
        case noSafeStorageItem(service: String)
        /// The user pressed Deny on the macOS panel, or dismissed it.
        case denied
        case keychain(OSStatus)
        case notDerivable

        var message: String {
            switch self {
            case .noSafeStorageItem(let service):
                return "This browser has no saved passwords — macOS has no \"\(service)\" key for it."
            case .denied:
                return "macOS was not allowed to hand over the browser's password key, so nothing was imported."
            case .keychain(let status):
                return "macOS would not hand over the browser's password key (\(status))."
            case .notDerivable:
                return "The browser's password key is not in a form this version understands."
            }
        }
    }

    /// The AES key for one browser, via the macOS panel the user has to accept.
    ///
    /// **This call is the consent gate for the whole import.** It is macOS that
    /// asks, in macOS's own words, naming Max Pane and naming the item — which
    /// is a better consent dialog than one this app could draw, because it is
    /// the one the user already knows how to disbelieve.
    static func key(service: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: throw KeyError.noSafeStorageItem(service: service)
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw KeyError.denied
        default: throw KeyError.keychain(status)
        }
        guard let data = result as? Data, let passphrase = String(data: data, encoding: .utf8),
              let derived = derive(from: passphrase)
        else { throw KeyError.notDerivable }
        return derived
    }

    /// PBKDF2-HMAC-SHA1 over the safe-storage string.
    ///
    /// Pure, so the whole crypto path can be exercised by a test that makes its
    /// own key — which is the only way to test this at all: the real key is the
    /// thing behind the consent panel, and a test fixture containing a real
    /// Chromium password would be the exact file this feature exists not to
    /// create.
    static func derive(from passphrase: String) -> Data? {
        var key = [UInt8](repeating: 0, count: keyLength)
        let saltBytes = [UInt8](salt.utf8)
        let passBytes = [UInt8](passphrase.utf8)
        let status = passBytes.withUnsafeBufferPointer { pass in
            saltBytes.withUnsafeBufferPointer { salt in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                    pass.count,
                    salt.baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    rounds,
                    &key, key.count)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(key)
    }

    /// One `password_value` blob, opened.
    ///
    /// `nil` for anything that is not a `v10` blob — a row from a Chromium old
    /// enough to have kept the password in the Keychain itself, or a row whose
    /// bytes are not what this understands. A `nil` skips that row and is
    /// counted; it never guesses.
    static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > version.count, blob.prefix(version.count) == version else { return nil }
        let body = blob.dropFirst(version.count)
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }

        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var written = 0
        let status: CCCryptorStatus = [UInt8](body).withUnsafeBufferPointer { input in
            [UInt8](key).withUnsafeBufferPointer { keyBytes in
                iv.withUnsafeBufferPointer { ivBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count,
                        ivBytes.baseAddress,
                        input.baseAddress, input.count,
                        &out, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        // UTF-8 or nothing. A wrong key under CBC produces bytes that decrypt
        // "successfully" and mean nothing, and this is the cheap check that
        // catches it before anything reaches the Keychain: real passwords are
        // text, and random bytes are valid UTF-8 about one time in a hundred
        // for a password-length run.
        return String(data: Data(out.prefix(written)), encoding: .utf8)
    }

    /// The same operation forwards, for the round-trip test. Not used by the
    /// app — there is nothing in Max Pane that writes a Chromium blob — and it
    /// lives here rather than in the test file so the two halves cannot drift
    /// into using different constants and agreeing with each other about it.
    static func encrypt(_ text: String, key: Data) -> Data? {
        let body = [UInt8](text.utf8)
        var out = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128 * 2)
        var written = 0
        let status: CCCryptorStatus = body.withUnsafeBufferPointer { input in
            [UInt8](key).withUnsafeBufferPointer { keyBytes in
                iv.withUnsafeBufferPointer { ivBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, keyBytes.count,
                        ivBytes.baseAddress,
                        input.baseAddress, input.count,
                        &out, out.count, &written)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return version + Data(out.prefix(written))
    }
}
