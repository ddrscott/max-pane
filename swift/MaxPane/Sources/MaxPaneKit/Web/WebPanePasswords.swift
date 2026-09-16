import AppKit
import WebKit

/// The pane's half of passwords: the key in the chrome bar, ⌥⌘L, and the one
/// call that puts a credential into a page.
///
/// `PasswordFill` holds the rules and the script and says why each rule is
/// there. This file is where they are enforced against a live `WKWebView`, and
/// it adds the two that only exist once there is a real page and a real clock:
///
/// - **The origin is read twice.** Once to decide which saved logins to offer,
///   and once *after* the Keychain has answered — because the Keychain can put
///   a macOS panel on screen, the user can take as long as they like over it,
///   and a page is free to navigate while they do. Filling the password for the
///   site that *was* here into the site that is here now is the one way this
///   feature could hand a credential to the wrong origin, and re-reading
///   `webView.url` on the way back is what closes it.
/// - **The read is off the main thread.** A Keychain prompt blocks the thread
///   that asked, and blocking this one freezes every lane in the strip —
///   including the terminals — for a dialog about one page. `WebAsk`'s module
///   doc makes that argument at length for sheets; it is the same argument.
extension WebPaneController {
    /// The origin the fill will be matched against: **WebKit's**, not the
    /// page's.
    ///
    /// `webView.url` is the URL of the load WebKit committed. It is nil for a
    /// pane that has not been built yet, and a pane with no live web view has
    /// nothing to fill — which is why this deliberately does not fall back to
    /// `pane.url`, the way the star does. A star drawn from the ledger is a
    /// cosmetic guess; a password filled from one would be a credential sent
    /// somewhere on the strength of a row in a database.
    var liveOrigin: PasswordOrigin? { PasswordOrigin(url: webView?.url) }

    /// Show the key when this site has a sign-in saved, hide it when it does
    /// not. Called wherever the address changes.
    func refreshSavedPassword() {
        guard let origin = liveOrigin else { return chrome.setHasSavedPassword(false) }
        // A listing, not a read: this asks the Keychain for account names and
        // never for a secret, so it cannot raise a panel and is cheap enough to
        // run on every address change.
        let saved = KeychainPasswords.accounts(for: origin).contains { !$0.isHTTPAuth }
        chrome.setHasSavedPassword(saved)
    }

    /// ⌥⌘L, and the menu's Fill item.
    ///
    /// One saved account fills straight away; several open the menu, because a
    /// key that picked one of someone's two logins for them would be wrong half
    /// the time and silent about it.
    func fillPassword() {
        guard let origin = liveOrigin else {
            return chrome.showFailure("This page has no address to match a password against")
        }
        let saved = KeychainPasswords.accounts(for: origin).filter { !$0.isHTTPAuth }
        switch saved.count {
        case 0:
            chrome.showFailure("No password saved for \(origin.label)")
        case 1:
            fill(saved[0])
        default:
            let menu = NSMenu()
            menu.addItem(accountsHeader(count: saved.count))
            for login in saved { menu.addItem(fillItem(for: login)) }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: chrome.keyAnchor.bounds.height + 2),
                       in: chrome.keyAnchor)
        }
    }

    /// The chrome bar's key menu: every saved account, then the way to add one.
    func passwordMenu() -> NSMenu? {
        guard let origin = liveOrigin else { return nil }
        let menu = NSMenu()
        let saved = KeychainPasswords.accounts(for: origin).filter { !$0.isHTTPAuth }
        if saved.isEmpty {
            let none = NSMenuItem(title: "No password saved for \(origin.label)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(accountsHeader(count: saved.count))
            for login in saved { menu.addItem(fillItem(for: login)) }
        }
        menu.addItem(.separator())
        // A private pane fills and never keeps: the item is not offered, so
        // the menu does not promise what `savePassword` would refuse.
        if !isPrivate {
            let save = NSMenuItem(
                title: "Save a Password for This Site…",
                action: #selector(WebPaneController.savePasswordFromMenu(_:)), keyEquivalent: "")
            save.target = self
            menu.addItem(save)
        }
        let settings = NSMenuItem(
            title: "Open System Settings → Passwords",
            action: #selector(WebPaneController.openPasswordSettings(_:)), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    private func accountsHeader(count: Int) -> NSMenuItem {
        let item = NSMenuItem(
            title: count == 1 ? "Fill this sign-in" : "Fill which sign-in?",
            action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func fillItem(for login: KeychainPasswords.SavedLogin) -> NSMenuItem {
        let item = NSMenuItem(
            title: login.menuTitle,
            action: #selector(WebPaneController.fillFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = login.account
        return item
    }

    @objc func fillFromMenu(_ sender: NSMenuItem) {
        guard let origin = liveOrigin, let account = sender.representedObject as? String,
              let login = KeychainPasswords.accounts(for: origin)
                  .first(where: { $0.account == account && !$0.isHTTPAuth })
        else { return }
        fill(login)
    }

    @objc func savePasswordFromMenu(_ sender: NSMenuItem) { savePassword() }

    @objc func openPasswordSettings(_ sender: NSMenuItem) {
        // The list Max Pane writes into is a system list, so the place to read,
        // change and delete what is in it is the system's own screen. Half the
        // reason for sharing Safari's keychain space is that this URL is a
        // complete answer to "how do I forget this password".
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Passwords-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// Read one password and put it in the form. See `PasswordFill.fill`.
    private func fill(_ login: KeychainPasswords.SavedLogin) {
        guard let webView, liveOrigin == login.origin else { return }
        PasswordFill.fill(login, into: webView, logName: "pane \(paneId)") { [weak self] message in
            self?.chrome.showFailure(message)
        }
    }

    /// ⇧⌘L — put a password for this site in the Keychain.
    ///
    /// Typed into a sheet of ours rather than lifted out of the page. Max Pane
    /// does not watch password fields: a script that could read what you type
    /// into one is a script that reads what you type into one, and the saving
    /// it would buy is worth less than never having written it. The cost is
    /// that saving is a deliberate act, which the README says out loud.
    func savePassword() {
        // The Keychain is the one store a private lane would otherwise reach.
        // The menu item is greyed out and left out of the key's menu; this is
        // for the `keys` binding that reaches here anyway.
        if isPrivate { return chrome.showFailure("A private lane never saves a password") }
        guard let origin = liveOrigin else {
            return chrome.showFailure("This page has no address to save a password for")
        }
        askToSavePassword(origin: origin) { [weak self] user, password in
            guard let self else { return }
            let ok = KeychainPasswords.save(origin: origin, account: user, password: password)
            self.chrome.showFailure(
                ok ? "Saved for \(origin.label)" : "The Keychain would not save it")
            self.refreshSavedPassword()
        }
    }
}

extension PasswordFill {
    /// Read one password and put it in `webView`'s form. The only injection in
    /// the app — for a pane's page and a popup's alike, so the rules below have
    /// one copy.
    ///
    /// `report` gets the one line worth showing. `logName` says whose page it
    /// was in the log, which never carries the account or the secret.
    @MainActor
    static func fill(_ login: KeychainPasswords.SavedLogin, into webView: WKWebView, logName: String,
                     report: @escaping @MainActor (String) -> Void) {
        guard let before = PasswordOrigin(url: webView.url), before == login.origin else { return }
        let account = login.account
        Task { @MainActor [weak webView] in
            // Off the main actor: this can raise the macOS "may Max Pane use
            // this password" panel and blocks until it is answered.
            let secret = await Task.detached(priority: .userInitiated) {
                KeychainPasswords.password(for: login)
            }.value
            guard let webView else { return }
            guard let secret else { return report("macOS did not hand over the password") }
            // The second origin read, from the same web view the password is
            // about to go into. The page is free to have navigated while the
            // panel was up, and the password below belongs to `before`.
            guard let now = PasswordOrigin(url: webView.url), now == before else {
                return report("The page changed — nothing was filled")
            }
            webView.callAsyncJavaScript(
                PasswordFill.javaScript,
                // Bound as values. The secret is never part of a program, so
                // there is no escaping to get wrong and no script string that
                // could carry it into a log.
                arguments: ["user": account, "secret": secret, "expect": before.key],
                in: nil,
                in: .defaultClient
            ) { result in
                Task { @MainActor in
                    switch result {
                    case .success(let value):
                        let outcome = PasswordFill.outcome(from: value)
                        // The origin and the outcome's *case*. Never the
                        // account, never the length of anything, never which
                        // field was found — `WebAuth`'s line, held.
                        Log.debug("\(logName) fill on \(before.label): \(outcome.tag)")
                        report(outcome.message)
                    case .failure(let error):
                        // The domain and the code, not the message: a
                        // JavaScript exception's text is assembled by the page's
                        // engine and is not a thing to copy into a log that is
                        // on for whole sessions.
                        let ns = error as NSError
                        Log.debug("\(logName) fill on \(before.label) threw \(ns.domain) \(ns.code)")
                        report("The page would not accept a fill")
                    }
                }
            }
        }
    }
}
