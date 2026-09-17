import AppKit
import LanedCore
import WebKit

/// The pane's half of the Notification API: the per-origin ask, the post, and
/// the way back from a click. `WebNotifications` has the argument.
extension WebPaneController {

    /// Every remembered answer in this pane's cookie jar, in the shape the
    /// script embeds. A pane's jar is the identity the site sees (ADR-0003), so
    /// a grant made in another project's jar is not in this map.
    func notificationGrants() -> [String: String] {
        var rows: [String: Bool] = [:]
        for grant in store.sitePermissions(dataStoreId: dataStoreId, feature: .notifications) {
            rows[grant.origin] = grant.allowed
        }
        return WebNotifications.grants(rows)
    }

    /// A message from the script, in this pane's page or in a popup over it —
    /// a popup shares its opener's content controller, so its messages arrive
    /// here and are told apart by `message.webView`.
    func notificationMessage(_ message: WKScriptMessage) {
        guard let kind = WebNotifications.message(message.body) else { return }
        switch kind {
        case .request(let id):
            requestNotificationPermission(id: id, from: message)
        case .show(let id, let title, let body, let icon, let tag):
            showNotification(id: id, title: title, body: body, icon: icon, tag: tag, from: message)
        case .close(let id):
            notifications.close(paneId: paneId, pageId: id)
        }
    }

    // MARK: - requestPermission

    /// The question, once per origin per jar, through the sheet the camera
    /// uses. A remembered answer never reaches the sheet; the script has it
    /// already and only asks when its own state is `default`, but a document
    /// older than the answer can still ask, and gets it without a question.
    private func requestNotificationPermission(id: Int, from message: WKScriptMessage) {
        let frame = message.frameInfo
        let security = frame.securityOrigin
        guard let key = AskOrigin.key(scheme: security.protocol, host: security.host, port: Int(security.port)) else {
            // A `file://` page or an opaque origin: nothing to remember an
            // answer about, and a permission that cannot be scoped is one
            // that should not be granted.
            Log.debug("pane \(paneId) refused notifications to an origin with no host")
            return reply(WebNotifications.answerScript(id: id, result: "denied"), to: message)
        }
        if let remembered = store.sitePermission(dataStoreId: dataStoreId, origin: key, feature: .notifications) {
            Log.debug("pane \(paneId) notifications \(remembered ? "allowed" : "denied") for \(key) (remembered)")
            return reply(WebNotifications.answerScript(id: id, result: remembered ? "granted" : "denied"), to: message)
        }

        let prompt = AskPrompt.capture(what: "TO SEND NOTIFICATIONS")
        let answer: (AskOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            guard case .capture(let allowed, let remember) = outcome else {
                // Esc, ✕, the pane closing: "not now". The promise settles
                // `default` and the page may ask again on a later click.
                return self.reply(WebNotifications.answerScript(id: id, result: "default"), to: message)
            }
            if remember {
                self.store.setSitePermission(
                    dataStoreId: self.dataStoreId, origin: key, feature: .notifications, allowed: allowed)
                self.notifications.grantsChanged(dataStoreId: self.dataStoreId, origin: key, allowed: allowed)
            }
            if allowed { self.notifications.siteGranted() }
            Log.debug("pane \(self.paneId) notifications \(allowed ? "allowed" : "denied") for \(key)\(remember ? " (remembered)" : "")")
            self.reply(WebNotifications.answerScript(id: id, result: allowed ? "granted" : "denied"), to: message)
        }

        if let dialog = popup(showing: message.webView) {
            // A popup's page asks in its dialog, over the page that asked —
            // the rule `WebPopupDelegate` sets for every other question.
            dialog.ask(prompt, origin: AskOrigin.label(
                scheme: security.protocol, host: security.host, port: Int(security.port)), answer: answer)
        } else {
            ask(prompt, from: frame, answer: answer)
        }
    }

    /// The dialog whose page `webView` is, if it is a popup's and not this pane's.
    /// Shared with `WebPaneGeolocation.swift`, whose messages arrive the same way.
    func popup(showing webView: WKWebView?) -> WebPopupDialog? {
        guard let webView, webView !== self.webView else { return nil }
        var dialog = popupDialog
        while let open = dialog {
            if open.webView === webView { return open }
            dialog = open.child
        }
        return nil
    }

    // MARK: - new Notification()

    private func showNotification(id: Int, title: String, body: String, icon: URL?, tag: String?,
                                  from message: WKScriptMessage) {
        let frame = message.frameInfo
        let security = frame.securityOrigin
        // The script only posts while its own state is `granted`, but that
        // state can be a document's own answer from before a remembered
        // *no*; the ledger wins.
        if let key = AskOrigin.key(scheme: security.protocol, host: security.host, port: Int(security.port)),
           store.sitePermission(dataStoreId: dataStoreId, origin: key, feature: .notifications) == false {
            return reply(WebNotifications.eventScript(id: id, type: "error"), to: message)
        }
        if isInFront(message.webView) {
            // The page under the pointer. Safari posts nothing for it either;
            // the page hears its notification shown and closed, and nothing
            // appears over the thing it is about.
            Log.debug("pane \(paneId) notification not posted: the pane is in front")
            reply(WebNotifications.eventScript(id: id, type: "show"), to: message)
            reply(WebNotifications.eventScript(id: id, type: "close"), to: message)
            return
        }
        Log.debug("pane \(paneId) posts a notification from \(AskOrigin.label(scheme: security.protocol, host: security.host, port: Int(security.port)))")
        notifications.post(
            from: self, pageId: id, frame: frame, webView: message.webView,
            title: title, body: body, icon: icon, tag: tag
        ) { [weak self] error in
            guard let self else { return }
            if let error {
                Log.warn("pane \(self.paneId) could not post a notification: \(error.localizedDescription)")
                return self.reply(WebNotifications.eventScript(id: id, type: "error"), to: message)
            }
            self.reply(WebNotifications.eventScript(id: id, type: "show"), to: message)
        }
    }

    /// Whether the page that is notifying is the one the person is looking at:
    /// this pane focused, in the key window of the active app, on screen — or,
    /// for a popup's page, its dialog key.
    func isInFront(_ webView: WKWebView?) -> Bool {
        guard NSApp.isActive else { return false }
        if let webView, webView !== self.webView {
            return webView.window?.isKeyWindow == true
        }
        return store.state.focusedPaneId == paneId
            && view.window?.isKeyWindow == true
            && !view.visibleRect.isEmpty
    }

    // MARK: - the way back

    /// A click on this pane's banner: focused in the ledger, the lane brought
    /// on screen if it was not, the page first responder. The same steps a
    /// closing popup takes to hand the keyboard home (`popupDidClose`).
    func bringForward() {
        try? store.focusPane(paneId)
        if view.window == nil || view.visibleRect.isEmpty {
            revealLane(holding: paneId)
        }
        (view.window ?? popupParent?())?.makeKey()
        takeFocus()
    }

    /// An answer remembered elsewhere in this jar, for the document this pane
    /// has open if it is on that origin. The next document reads it from the
    /// script; this one would otherwise keep asking until reloaded.
    func tellOpenDocument(origin: String, permission: String) {
        guard let webView else { return }
        webView.evaluateJavaScript(
            WebNotifications.permissionScript(origin: origin, result: permission), in: nil, in: .page
        ) { _ in }
    }

    private func reply(_ script: String, to message: WKScriptMessage) {
        guard let webView = message.webView else { return }
        webView.evaluateJavaScript(script, in: message.frameInfo, in: .page) { [paneId] result in
            if case .failure(let error) = result {
                Log.debug("pane \(paneId) notification reply did not land: \(error.localizedDescription)")
            }
        }
    }
}
