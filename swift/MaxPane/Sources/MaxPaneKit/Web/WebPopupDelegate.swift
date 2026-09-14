import AppKit
import LanedCore
import WebKit

/// Everything a popup's page can ask for, answered inside its dialog.
///
/// A sign-in page is a web page like any other and asks for the same things:
/// `alert`/`confirm`/`prompt`, HTTP authentication, a client certificate, the
/// camera, a file, a download, a second popup. The rule is the one `WebAsk`
/// sets for panes — a question is drawn over the page that asked it, modal to
/// nothing else — and for a popup that page is in the dialog, so the sheet is
/// too. A question drawn in the opener's lane would sit behind the dialog
/// waiting for an answer nobody can see, and a page waiting on a completion
/// handler runs no more JavaScript.
///
/// Where the opener's own handling is already exactly right, this forwards to
/// it: a file panel is its own window whichever page asked, a download belongs
/// in the opener's download bar because it outlives the sign-in, and a
/// response's "is this a file" decision is the same function of the response.
///
/// Nothing here writes a visit, a title or an address to the ledger. The
/// popup is not on the strip and a relaunch should not know it existed.
extension WebPopupDialog: WKUIDelegate, WKNavigationDelegate {

    // MARK: - a popup from the popup

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, !isDismissed, let pane else { return nil }
        let intent = PopupIntent(navigationAction, windowFeatures)
        let url = navigationAction.request.url?.absoluteString
        switch PopupPolicy.disposition(for: intent) {
        case .lane:
            // A page to read — "Terms of Service" in a sign-in footer. It gets a
            // lane like any `target=_blank`, next to the pane this all started
            // from, and the sign-in stays where it is.
            if let url { pane.openLane(url) }
            return nil
        case .popup:
            let dialog = WebPopupDialog.show(
                replacing: child, configuration: configuration, features: windowFeatures,
                pane: pane, parent: self, openerURL: webView.url?.absoluteString, over: window)
            child = dialog
            return dialog.webView
        }
    }

    /// `window.close()`: the sign-in is done, or given up on.
    func webViewDidClose(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        Log.debug("popup of pane \(pane?.paneId ?? "?") closed itself")
        // WebKit is still on the stack, and this tears its view down.
        Task { @MainActor [weak self] in self?.dismiss() }
    }

    // MARK: - alert / confirm / prompt

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable () -> Void) {
        ask(.alert(message: message), origin: Self.origin(of: frame, or: webView)) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        ask(.confirm(message: message), origin: Self.origin(of: frame, or: webView)) { outcome in
            completionHandler(outcome == .confirmed)
        }
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        ask(.prompt(message: prompt, defaultText: defaultText ?? ""),
            origin: Self.origin(of: frame, or: webView)) { outcome in
            guard case .text(let typed) = outcome else { return completionHandler(nil) }
            completionHandler(typed)
        }
    }

    // MARK: - files, the camera

    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        guard let pane else { return completionHandler(nil) }
        // The pane's panel names the origin from the web view it is handed,
        // which is this one.
        pane.webView(webView, runOpenPanelWith: parameters, initiatedByFrame: frame,
                     completionHandler: completionHandler)
    }

    /// Remembered in the opener's cookie jar, because that is the jar this page
    /// is in and the identity the site sees (ADR-0003); asked in the dialog.
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        guard let pane,
              let key = AskOrigin.key(scheme: origin.protocol, host: origin.host, port: Int(origin.port))
        else { return decisionHandler(.deny) }
        let features: [SiteFeature]
        let what: String
        switch type {
        case .camera: (features, what) = ([.camera], "THE CAMERA")
        case .microphone: (features, what) = ([.microphone], "THE MICROPHONE")
        default: (features, what) = ([.camera, .microphone], "THE CAMERA AND MICROPHONE")
        }
        let decided = features.map {
            pane.store.sitePermission(dataStoreId: pane.dataStoreId, origin: key, feature: $0)
        }
        if decided.allSatisfy({ $0 == true }) { return decisionHandler(.grant) }
        if decided.contains(false) { return decisionHandler(.deny) }
        ask(.capture(what: what), origin: Self.origin(of: frame, or: webView)) { [weak pane] outcome in
            guard case .capture(let allowed, let remember) = outcome else { return decisionHandler(.deny) }
            if remember, let pane {
                for feature in features {
                    pane.store.setSitePermission(
                        dataStoreId: pane.dataStoreId, origin: key, feature: feature, allowed: allowed)
                }
            }
            decisionHandler(allowed ? .grant : .deny)
        }
    }

    // MARK: - navigation

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // ⌘-click keeps its meaning inside a sign-in page: a sibling lane of the
        // pane this came from, and the dialog does not move.
        if !navigationAction.shouldPerformDownload,
           LinkClick.outcome(
               navigationType: navigationAction.navigationType,
               modifiers: navigationAction.modifierFlags,
               buttonNumber: navigationAction.buttonNumber) == .siblingLane,
           let url = navigationAction.request.url?.absoluteString {
            pane?.openLane(url)
            return decisionHandler(.cancel)
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        guard let pane else { return decisionHandler(.allow) }
        pane.webView(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let pane else { return download.cancel { _ in } }
        pane.webView(webView, navigationAction: navigationAction, didBecome: download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let pane else { return download.cancel { _ in } }
        pane.webView(webView, navigationResponse: navigationResponse, didBecome: download)
    }

    /// A new document in the dialog has nothing full screen, so the next Esc
    /// closes the dialog again rather than asking an empty page to leave.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        pageIsFullscreen = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    /// A load that failed says so on the bar, as it does in a pane's chrome.
    private func report(_ error: Error) {
        let error = error as NSError
        let failing = error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
        bar.setProgress(0)
        guard let text = BrowserAddress.failure(domain: error.domain, code: error.code, failingURL: failing)
        else { return }
        bar.say(text, warning: true)
    }

    // MARK: - HTTP authentication

    /// The pane's order, for the pane's reasons (`WebPaneController.handle`):
    /// this session's answer, then a credential saved on purpose, then the
    /// sheet. Server trust is WebKit's.
    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let origin = AskOrigin.label(scheme: space.protocol, host: space.host, port: space.port)
        switch WebAuth.kind(of: space) {
        case .serverTrust, .unsupported:
            completionHandler(.performDefaultHandling, nil)

        case .password(let realm, let isProxy):
            if let known = WebAuth.cached(for: challenge) ?? KeychainPasswords.credential(for: space) {
                WebAuth.remember(known, for: challenge)
                return completionHandler(.useCredential, known)
            }
            ask(.httpAuth(realm: realm, isProxy: isProxy), origin: origin) { outcome in
                guard case .credential(let user, let password, let save) = outcome else {
                    return completionHandler(.cancelAuthenticationChallenge, nil)
                }
                let credential = URLCredential(user: user, password: password, persistence: .forSession)
                WebAuth.remember(credential, for: challenge)
                if save { KeychainPasswords.save(credential: user, password: password, for: space) }
                completionHandler(.useCredential, credential)
            }

        case .clientCertificate:
            let choices = ClientIdentities.available()
            guard !choices.isEmpty else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            ask(.clientCertificate(names: choices.map(\.label)), origin: origin) { outcome in
                guard case .certificate(let index) = outcome, choices.indices.contains(index) else {
                    return completionHandler(.cancelAuthenticationChallenge, nil)
                }
                completionHandler(.useCredential, URLCredential(
                    identity: choices[index].identity, certificates: nil, persistence: .none))
            }
        }
    }

    // MARK: - the queue

    /// Raise a question over the popup's page, or put it behind the one already
    /// up. `answer` runs exactly once: a button, Esc, or the dialog closing.
    func ask(_ prompt: AskPrompt, origin: String, answer: @escaping (AskOutcome) -> Void) {
        guard !isDismissed else { return answer(.cancelled) }
        let pending = PendingAsk(
            prompt: prompt, origin: origin, reply: OneShotReply(fallback: .cancelled, reply: answer))
        if askQueue.enqueue(pending) { presentCurrentAsk() }
    }

    private func presentCurrentAsk() {
        guard askSheet == nil, let pending = askQueue.current else { return }
        let sheet = WebAskSheet(prompt: pending.prompt, origin: pending.origin) { [weak self] outcome in
            self?.finishAsk(with: outcome)
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: pageHost.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        askSheet = sheet
        sheet.takeFocus()
    }

    private func finishAsk(with outcome: AskOutcome) {
        askSheet = nil
        guard let pending = askQueue.current else { return }
        pending.reply.fire(outcome)
        _ = askQueue.finish()
        if askQueue.isEmpty {
            window?.makeFirstResponder(webView)
        } else {
            presentCurrentAsk()
        }
    }

    /// Answer everything outstanding with the safe answer and take the sheet
    /// down — for a dialog closing, or a page being replaced, under a question.
    func drainAsks() {
        askSheet?.dismissWithoutAnswering()
        askSheet = nil
        for pending in askQueue.drain() { pending.reply.abandon() }
    }

    private static func origin(of frame: WKFrameInfo, or webView: WKWebView) -> String {
        let security = frame.securityOrigin
        guard !security.host.isEmpty else { return AskOrigin.label(for: webView.url) }
        return AskOrigin.label(scheme: security.protocol, host: security.host, port: Int(security.port))
    }
}
