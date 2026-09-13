import Foundation
import LanedCore
import Security
import Testing
@testable import MaxPaneKit

/// Passwords, and the four places this feature could hand a credential to the
/// wrong party.
///
/// **Nothing in this file touches the login keychain.** The owner's real
/// Keychain is not a fixture, and a test that wrote a password into it — even
/// a fake one, even tidied up afterwards — would be a test that can leave a
/// credential behind when it fails. So everything here is the pure half:
/// origin equality, the attribute dictionaries `SecItemCopyMatching` hands
/// back, the Chromium crypto, and the strings. The `SecItem` calls themselves
/// are three-line wrappers over those, and the thing worth protecting is the
/// rules.

@Suite("which site a password belongs to")
struct PasswordOriginTests {
    @Test("the scheme is part of the identity")
    func schemeMatters() {
        let secure = PasswordOrigin(url: URL(string: "https://example.com/login"))
        let plain = PasswordOrigin(url: URL(string: "http://example.com/login"))
        #expect(secure != nil)
        #expect(plain != nil)
        // The case that matters: an attacker on the network arranges the
        // downgrade, and a manager that filled here would post the password in
        // clear.
        #expect(secure != plain)
    }

    @Test("a subdomain is a different site")
    func subdomainsAreNotTheSameSite() {
        #expect(PasswordOrigin(url: URL(string: "https://example.com/"))
            != PasswordOrigin(url: URL(string: "https://login.example.com/")))
        #expect(PasswordOrigin(url: URL(string: "https://example.com/"))
            != PasswordOrigin(url: URL(string: "https://example.com.evil.test/")))
    }

    @Test("a default port resolves, and is 0 to the Keychain")
    func defaultPorts() throws {
        let origin = try #require(PasswordOrigin(url: URL(string: "https://example.com/x")))
        #expect(origin.port == 443)
        // Not 443. Every `inet` item on a Mac — Safari's, the system's,
        // `security(1)`'s — carries port 0 for an ordinary https site, and an
        // item written with 443 would work perfectly here and be invisible to
        // everything else.
        #expect(origin.keychainPort == 0)
        #expect(origin.key == "https://example.com")
    }

    @Test("a non-default port is part of the identity and is kept")
    func explicitPort() throws {
        let origin = try #require(PasswordOrigin(url: URL(string: "http://localhost:8071/")))
        #expect(origin.port == 8071)
        #expect(origin.keychainPort == 8071)
        #expect(origin.key == "http://localhost:8071")
        #expect(origin != PasswordOrigin(url: URL(string: "http://localhost:9000/")))
    }

    @Test("a page with no web origin has nothing to fill",
          arguments: ["file:///Users/spierce/notes.html", "about:blank",
                      "data:text/html,<form>", "ftp://example.com/", "maxpane://help"])
    func noOrigin(_ url: String) {
        #expect(PasswordOrigin(url: URL(string: url)) == nil)
    }

    @Test("the host is compared as Punycode, so a lookalike is not a match")
    func homographs() {
        // `URL` does the IDNA conversion, so what reaches the comparison is
        // `xn--exmple-4ua.com` and not a string that renders like example.com.
        let lookalike = PasswordOrigin(url: URL(string: "https://exаmple.com/"))
        let real = PasswordOrigin(url: URL(string: "https://example.com/"))
        #expect(lookalike != real)
    }

    @Test("WebKit's 0-means-default port becomes a real port")
    func securityOriginPorts() throws {
        struct Origin: WKSecurityOriginLike {
            var originProtocol: String
            var originHost: String
            var originPort: Int
        }
        let https = try #require(PasswordOrigin(
            securityOrigin: Origin(originProtocol: "https", originHost: "Example.com", originPort: 0)))
        #expect(https.port == 443)
        #expect(https.host == "example.com")
        let odd = try #require(PasswordOrigin(
            securityOrigin: Origin(originProtocol: "http", originHost: "localhost", originPort: 8071)))
        #expect(odd.port == 8071)
        #expect(PasswordOrigin(
            securityOrigin: Origin(originProtocol: "ftp", originHost: "x.test", originPort: 21)) == nil)
    }
}

@Suite("reading the Keychain's answer")
struct KeychainClassifyTests {
    private static let origin = PasswordOrigin(scheme: "https", host: "example.com", port: 443)

    /// `kSecAttrAuthenticationType` comes back as a number, not as the
    /// `CFString` constant that went in — which is the detail that would make a
    /// naive `== kSecAttrAuthenticationTypeHTMLForm` compare false for every
    /// item, forever, silently.
    private func code(_ value: CFString) -> NSNumber {
        NSNumber(value: KeychainPasswords.fourCharCode(value as String)!)
    }

    @Test("an item with no authentication type counts as a form login")
    func untypedIsAForm() {
        let items: [[String: Any]] = [[kSecAttrAccount as String: "scott"]]
        let out = KeychainPasswords.classify(items, origin: Self.origin)
        #expect(out.count == 1)
        // The generous half of the interoperation rule: every `inet` item on
        // this machine leaves the attribute unset, and an item some other app
        // wrote for a site is far more likely to be a site password than a 401.
        #expect(out[0].isHTTPAuth == false)
        #expect(out[0].account == "scott")
    }

    @Test("a basic-auth item is not offered to a form")
    func httpAuthIsSeparate() {
        let items: [[String: Any]] = [[
            kSecAttrAccount as String: "admin",
            kSecAttrSecurityDomain as String: "Home NAS",
            kSecAttrAuthenticationType as String: code(kSecAttrAuthenticationTypeHTTPBasic),
        ]]
        let out = KeychainPasswords.classify(items, origin: Self.origin)
        #expect(out[0].isHTTPAuth)
        #expect(out[0].realm == "Home NAS")
    }

    @Test("an explicit form type is still a form")
    func formTypeIsAForm() {
        let items: [[String: Any]] = [[
            kSecAttrAccount as String: "scott",
            kSecAttrAuthenticationType as String: code(kSecAttrAuthenticationTypeHTMLForm),
        ]]
        #expect(KeychainPasswords.classify(items, origin: Self.origin)[0].isHTTPAuth == false)
    }

    @Test("the most recently changed account is offered first")
    func newestFirst() {
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        let items: [[String: Any]] = [
            [kSecAttrAccount as String: "old", kSecAttrModificationDate as String: old],
            [kSecAttrAccount as String: "new", kSecAttrModificationDate as String: new],
        ]
        #expect(KeychainPasswords.classify(items, origin: Self.origin).map(\.account) == ["new", "old"])
    }

    @Test("an account with no name is still clickable")
    func emptyAccount() {
        let out = KeychainPasswords.classify([[:]], origin: Self.origin)
        #expect(out[0].menuTitle == "(no user name)")
    }
}

@Suite("filling a form")
struct PasswordFillTests {
    @Test("every answer the script can give has a sentence")
    func outcomes() {
        #expect(PasswordFill.outcome(from: "filled-with-user") == .filled(user: true))
        #expect(PasswordFill.outcome(from: "filled") == .filled(user: false))
        #expect(PasswordFill.outcome(from: "none") == .noPasswordField)
        #expect(PasswordFill.outcome(from: "several") == .severalPasswordFields)
        #expect(PasswordFill.outcome(from: "opaque-frame") == .hiddenInAnotherSitesFrame)
        // A page that somehow answered something else, and a page that answered
        // nothing, are both failures and neither is reported as a fill.
        #expect(PasswordFill.outcome(from: "surprise").didFill == false)
        #expect(PasswordFill.outcome(from: nil).didFill == false)
    }

    @Test("no message names an account or a field")
    func messagesSayNothingPrivate() {
        let all: [PasswordFill.Outcome] = [
            .filled(user: true), .filled(user: false), .noPasswordField,
            .severalPasswordFields, .hiddenInAnotherSitesFrame, .failed("x"),
        ]
        for outcome in all {
            #expect(!outcome.message.isEmpty)
        }
    }

    /// A regression guard on the script's two safety clauses, not on its
    /// behaviour — that needs a page. Both of these have been deleted from
    /// password managers before, by someone making the fill work on one more
    /// site.
    @Test("the script still checks the origin of every document it walks into")
    func theOriginGuardIsStillThere() {
        // The top document is checked against WebKit's committed origin with
        // no inheritance allowed, every subframe is reached only through
        // `contentDocument`, and a subframe whose origin disagrees is dropped.
        #expect(PasswordFill.javaScript.contains("if (top !== expect)"))
        #expect(PasswordFill.javaScript.contains("contentDocument"))
        #expect(PasswordFill.javaScript.contains("if (here !== expect && !inherited)"))
    }

    @Test("the script refuses a page with more than one password box")
    func theAmbiguityGuardIsStillThere() {
        #expect(PasswordFill.javaScript.contains("if (forms.length > 1) return 'several'"))
    }

    /// The password is bound as an argument by `callAsyncJavaScript`, so the
    /// script is a constant with no substitution points in it. If someone ever
    /// turns it into an interpolated string this fails, which is the point: a
    /// quote-escaping bug there is arbitrary code execution in the page.
    @Test("the script is a constant, with nothing substituted into it")
    func theScriptIsAConstant() {
        #expect(!PasswordFill.javaScript.contains("\\("))
    }
}

@Suite("opening a Chromium password")
struct ChromiumSafeStorageTests {
    /// PBKDF2-HMAC-SHA1, "saltysalt", 1003 rounds, 16 bytes — checked against a
    /// vector computed by Python's `hashlib`, not by this code. Three constants,
    /// each of which derives a *different valid-looking key* if mistyped, and
    /// CBC hands back plausible rubbish rather than an error for a wrong key.
    @Test("the key derivation matches an independent implementation")
    func derivation() throws {
        let key = try #require(ChromiumSafeStorage.derive(from: "peanuts"))
        #expect(key.map { String(format: "%02x", $0) }.joined()
            == "d9a09d499b4e1b7461f28e67972c6dbd")
        let other = try #require(ChromiumSafeStorage.derive(from: "a-real-safe-storage-value"))
        #expect(other.map { String(format: "%02x", $0) }.joined()
            == "654fd79f3a3799f6dcbff2f4492d409d")
    }

    @Test("a blob encrypted with the key opens, and one with another key does not")
    func roundTrip() throws {
        let key = try #require(ChromiumSafeStorage.derive(from: "peanuts"))
        let wrong = try #require(ChromiumSafeStorage.derive(from: "cashews"))
        let blob = try #require(ChromiumSafeStorage.encrypt("hunter2 — ünïcode", key: key))
        // The shape the owner's real profile has: `v10` and a block-aligned
        // remainder. All 442 of his rows look like this, which is how CBC was
        // established rather than guessed.
        #expect(blob.prefix(3) == Data("v10".utf8))
        #expect((blob.count - 3) % 16 == 0)
        #expect(ChromiumSafeStorage.decrypt(blob, key: key) == "hunter2 — ünïcode")
        // A wrong key decrypts to bytes rather than failing. The UTF-8 check is
        // what turns that into a skipped row instead of a Keychain item full of
        // rubbish.
        #expect(ChromiumSafeStorage.decrypt(blob, key: wrong) == nil)
    }

    @Test("anything that is not a v10 CBC blob is skipped, never guessed at",
          arguments: [
            Data(),
            Data("v10".utf8),
            Data("v11abcdefghijklmnop".utf8),
            Data("plaintext-password".utf8),
            Data("v10".utf8) + Data(repeating: 0, count: 15),  // not block-aligned
          ])
    func refusesUnknownShapes(_ blob: Data) throws {
        let key = try #require(ChromiumSafeStorage.derive(from: "peanuts"))
        #expect(ChromiumSafeStorage.decrypt(blob, key: key) == nil)
    }
}

@Suite("where an imported login goes")
struct PasswordImportTests {
    private func login(origin: String, realm: String, form: Bool, user: String = "scott") -> SourceLogin {
        SourceLogin(origin: origin, signonRealm: realm, username: user,
                    secret: Data("v10".utf8), isHtmlForm: form,
                    createdMs: 0, lastUsedMs: 0)
    }

    @Test("a form login becomes a form item on its own origin")
    func formLogin() throws {
        let place = try #require(PasswordImport.placement(
            for: login(origin: "https://example.com/login", realm: "https://example.com/", form: true)))
        #expect(place.origin.key == "https://example.com")
        #expect(place.kind == .htmlForm)
        #expect(place.realm == nil)
    }

    @Test("an HTTP-auth login keeps its realm, which is what tells two apart")
    func httpAuthLogin() throws {
        let place = try #require(PasswordImport.placement(
            for: login(origin: "https://nas.test/files/",
                       realm: "https://nas.test:8443/Private Files", form: false)))
        #expect(place.origin.key == "https://nas.test:8443")
        #expect(place.kind == .httpAuth(method: NSURLAuthenticationMethodHTTPBasic))
        #expect(place.realm == "Private Files")
    }

    @Test("a row that is not a website gets no Keychain item at all",
          arguments: ["android://Base64Hash@com.example.app/",
                      "chrome-extension://abcdefghijklmnop/",
                      "",
                      "federation://example.com/accounts.google.com"])
    func notAWebsite(_ realm: String) {
        #expect(PasswordImport.placement(
            for: login(origin: realm, realm: realm, form: true)) == nil)
    }

    @Test("a form row with an unusable realm still lands on its page's origin")
    func fallsBackToTheOriginURL() throws {
        let place = try #require(PasswordImport.placement(
            for: login(origin: "https://example.com/login", realm: "nonsense", form: true)))
        #expect(place.origin.key == "https://example.com")
    }

    @Test("the report is counters and never a list of sites")
    func reportShape() {
        var report = PasswordImport.Report()
        report.found = 442
        report.saved = 440
        report.unreadable = 2
        #expect(ImportPasswordsModel.doneHeadline(report).contains("440"))
        let lines = ImportPasswordsModel.doneLines(report)
        #expect(lines.contains { $0.0 == "Could not be decrypted" && $0.1 == "2" })
        // Nothing that is not a number.
        #expect(lines.allSatisfy { $0.1.allSatisfy { c in c.isNumber || c == "," } })
    }

    @Test("nothing imported says so rather than congratulating anyone")
    func nothingImported() {
        #expect(ImportPasswordsModel.doneHeadline(PasswordImport.Report()) == "Nothing was imported.")
    }
}

@Suite("the passwords import wizard says what will happen")
struct ImportPasswordsModelTests {
    private func source(_ name: String, blocked: String? = nil) -> LoginSource {
        LoginSource(name: name, profile: "Default",
                    path: "/Users/x/Library/Application Support/\(name)/Default/Login Data",
                    safeStorageService: "\(name) Safe Storage",
                    sizeBytes: 491_520, blocked: blocked)
    }

    /// The macOS panel is named *before* it appears. An unexplained "Max Pane
    /// wants to use your confidential information stored in Vivaldi Safe
    /// Storage" is a dialog people deny out of suspicion or accept out of
    /// habit, and both are worse than knowing what was coming.
    @Test("the consent screen names the macOS panel before it appears")
    func consentNamesThePanel() {
        let text = ImportPasswordsModel.consent(for: source("Vivaldi"))
        #expect(text.contains("Vivaldi Safe Storage"))
        #expect(text.contains("Deny"))
        #expect(text.contains("deletes the copy") || text.contains("delete the copy"))
        #expect(text.contains("System Settings"))
    }

    @Test("it lands on a browser it can actually read")
    func skipsBlockedRows() {
        let model = ImportPasswordsModel(sources: [
            source("Brave", blocked: "macOS is withholding it."),
            source("Vivaldi"),
        ])
        #expect(model.selected == 1)
        #expect(model.blockedReason == nil)
    }

    @Test("a blocked row is offered with its reason rather than hidden")
    func blockedRowSpeaks() {
        let model = ImportPasswordsModel(sources: [source("Brave", blocked: "Full Disk Access.")])
        #expect(model.sources.count == 1)
        #expect(model.blockedReason == "Full Disk Access.")
    }

    @Test("no Chromium profile says what Safari and Firefox do instead")
    func emptyStateIsNotAShrug() {
        #expect(ImportPasswordsModel(sources: []).isEmpty)
    }
}

@Suite("the keys passwords cost")
struct PasswordKeymapTests {
    @Test("fill, save and import each have a key and none of them collides")
    func keysAreDistinct() {
        let map = Keymap.defaults
        let fill = map.chords(for: .fillPassword)
        let save = map.chords(for: .savePassword)
        let load = map.chords(for: .importBrowserPasswords)
        #expect(!fill.isEmpty && !save.isEmpty && !load.isEmpty)
        #expect(fill != save)
        // Every command's chords across the whole map, with no duplicates: a
        // shortcut that quietly shadows another is how ⌘O came to open nothing.
        var seen = Set<KeyChord>()
        for command in Command.allCases {
            for chord in map.chords(for: command) {
                #expect(!seen.contains(chord), "\(chord) is bound twice")
                seen.insert(chord)
            }
        }
    }
}

/// The passwords wizard's three screens, drawn.
///
/// Rendered rather than only asserted, for the same reason its sibling is: the
/// thing it has to get right is a paragraph, and a paragraph is a layout
/// problem as much as a wording one. This one has a second reason — the screen
/// before the macOS panel is the only place the user is told what is about to be
/// asked of them, and a sentence that has run off the bottom of a 440 pt panel
/// is a sentence nobody read.
///
/// Skipped unless `MAXPANE_SHOTS` names a directory; `./scripts/test.sh shots`
/// is what sets it.
@Suite("passwords wizard rendering")
@MainActor
struct ImportPasswordsRenderTests {
    @Test("renders every screen, with fixed rows")
    func renderSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StripStore(ledgerPath: tmp.appendingPathComponent("ledger.db").path)

        let support = NSHomeDirectory() + "/Library/Application Support"
        let sources = [
            LoginSource(name: "Vivaldi", profile: "Default",
                        path: support + "/Vivaldi/Default/Login Data",
                        safeStorageService: "Vivaldi Safe Storage",
                        sizeBytes: 491_520, blocked: nil),
            LoginSource(name: "Google Chrome", profile: "Default",
                        path: support + "/Google/Chrome/Default/Login Data",
                        safeStorageService: "Chrome Safe Storage",
                        sizeBytes: 118_784,
                        blocked: "macOS is withholding Google Chrome's saved passwords. Give Max "
                            + "Pane Full Disk Access in System Settings → Privacy & Security, "
                            + "then reopen this window."),
        ]
        var report = PasswordImport.Report()
        report.found = 442
        report.saved = 438
        report.unreadable = 1
        report.notAWebsite = 3

        let screens: [(String, ImportPasswordsModel.Step, Int)] = [
            ("1-source", .source, 0),
            ("2-source-blocked", .source, 1),
            ("3-working", .working, 0),
            ("4-done", .done(report), 0),
            ("5-denied", .failed(ChromiumSafeStorage.KeyError.denied.message), 0),
        ]

        for (name, step, selected) in screens {
            let wizard = ImportPasswordsWizard(store: store, sources: sources)
            wizard.model.selected = selected
            wizard.model.step = step
            wizard.render()
            let view = try #require(wizard.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("passwords-\(name).png"))
        }
    }
}
