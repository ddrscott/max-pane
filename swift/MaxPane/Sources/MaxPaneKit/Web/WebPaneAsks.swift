import AppKit
import LanedCore
import UniformTypeIdentifiers
import WebKit

/// One question this pane has not answered yet.
///
/// The reply is a `OneShotReply` rather than a bare closure because *every*
/// path out of here — a button, Esc, the pane closing, the page being evicted —
/// has to be able to answer, and exactly one of them may.
struct PendingAsk {
    let prompt: AskPrompt
    let origin: String
    let reply: OneShotReply<AskOutcome>
}

// MARK: - the five things real sites need

/// The `WKUIDelegate` and `WKNavigationDelegate` callbacks that decide whether a
/// real website works at all: `alert`/`confirm`/`prompt`, `<input type=file>`,
/// downloads, camera and microphone, and HTTP authentication.
///
/// Before this, each of them failed differently and none of them failed loudly.
/// `confirm()` returned **false** — so a page took its "user clicked Cancel"
/// branch and looked like it was working; a file input did nothing at all, ever;
/// a download link did nothing; `getUserMedia` was denied, which kills a video
/// call; and a basic-auth challenge could not be answered, which puts every
/// internal service out of reach.
///
/// They are together in one file because they share the thing that is actually
/// hard about them — see `WebAsk` for the argument. Each hands over a completion
/// handler that must be called **exactly once**, and each of them belongs in a
/// lane rather than on the window, because the window is the whole strip.
extension WebPaneController {

    // MARK: - alert / confirm / prompt

    func webView(_ webView: WKWebView,
                       runJavaScriptAlertPanelWithMessage message: String,
                       initiatedByFrame frame: WKFrameInfo,
                       completionHandler: @escaping @MainActor @Sendable () -> Void) {
        ask(.alert(message: message), from: frame) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView,
                       runJavaScriptConfirmPanelWithMessage message: String,
                       initiatedByFrame frame: WKFrameInfo,
                       completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        ask(.confirm(message: message), from: frame) { outcome in
            // The one line this whole piece is named for. It used to be a
            // hard-coded `false` by omission, which is indistinguishable from
            // the user having pressed Cancel — so a page that asks "save your
            // changes?" quietly threw them away and reported success.
            completionHandler(outcome == .confirmed)
        }
    }

    func webView(_ webView: WKWebView,
                       runJavaScriptTextInputPanelWithPrompt prompt: String,
                       defaultText: String?,
                       initiatedByFrame frame: WKFrameInfo,
                       completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        ask(.prompt(message: prompt, defaultText: defaultText ?? ""), from: frame) { outcome in
            // nil, not "". They are different answers: `prompt()` returning an
            // empty string means the user pressed OK on an empty box, and a
            // page that branches on `=== null` would take the wrong one.
            guard case .text(let typed) = outcome else { return completionHandler(nil) }
            completionHandler(typed)
        }
    }

    // MARK: - <input type="file">

    /// The file picker, and the one ask here that is **not** drawn in the lane.
    ///
    /// `NSOpenPanel` is what a file input should raise: it is the picker the
    /// user's muscle memory, sidebar, recents and tags live in, and a
    /// hand-drawn file list in a 656 pt column would be worse at the job in
    /// every way. What matters is *how* it is presented — `begin` rather than
    /// `beginSheetModal(for: window)`. A sheet on this window is modal to every
    /// lane, so picking a file for one page would stop ten terminals; `begin`
    /// puts it up as its own window and the strip keeps running underneath.
    func webView(_ webView: WKWebView,
                       runOpenPanelWith parameters: WKOpenPanelParameters,
                       initiatedByFrame frame: WKFrameInfo,
                       completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        let reply = OneShotReply<[URL]?>(fallback: nil, reply: completionHandler)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        // Which page is asking, in the panel's own subtitle. A file picker that
        // appears over a strip of ten lanes with no attribution is a picker you
        // have to guess the owner of — and the guess is a file you did not mean
        // to upload.
        panel.message = "\(AskOrigin.label(for: webView.url)) is asking for a file"
        panel.prompt = "Upload"
        if let types = Self.allowedContentTypes(parameters), !types.isEmpty {
            panel.allowedContentTypes = types
            // The page said what it accepts, not what it forbids. Leaving this
            // true would let the panel grey out a file the page would have
            // taken, and every `accept` list in the wild is a hint rather than
            // a contract.
            panel.allowsOtherFileTypes = true
        }

        openPanels.append(panel)
        panel.begin { [weak self, weak panel] response in
            MainActor.assumeIsolated {
                if let panel, let index = self?.openPanels.firstIndex(of: panel) {
                    self?.openPanels.remove(at: index)
                }
                guard response == .OK, let urls = panel?.urls, !urls.isEmpty else {
                    reply.fire(nil)
                    return
                }
                Log.debug("upload: \(urls.count) file(s) → \(urls.map(\.lastPathComponent))")
                reply.fire(urls)
            }
        }
    }

    /// The `accept` attribute, if WebKit will say what it was.
    ///
    /// **There is no public API for this.** `WKOpenPanelParameters` exposes
    /// `allowsMultipleSelection` and `allowsDirectories` and nothing about
    /// types; the accept list lives on `_allowedFileExtensions` and
    /// `_allowedMIMETypes`, which are WebKit SPI. So this asks politely —
    /// `responds(to:)`, then a cast that can fail — and an unrecognised build
    /// of WebKit gets an unfiltered panel rather than a crash. An unfiltered
    /// panel is a small loss; `accept` is advisory in every browser and the
    /// page still validates what it receives.
    ///
    /// Rejected: parsing `accept` out of the DOM with `evaluateJavaScript`.
    /// The delegate does not say which element was clicked, so it would mean
    /// guessing at `document.activeElement` from a callback that fires after
    /// the click — a guess that is wrong exactly when a page has two file
    /// inputs, which is when getting it right would have mattered.
    static func allowedContentTypes(_ parameters: WKOpenPanelParameters) -> [UTType]? {
        var types: [UTType] = []
        for (selector, make) in [
            ("_allowedFileExtensions", { UTType(filenameExtension: $0) }),
            ("_allowedMIMETypes", { UTType(mimeType: $0) }),
        ] as [(String, (String) -> UTType?)] {
            let sel = NSSelectorFromString(selector)
            guard parameters.responds(to: sel),
                  let raw = parameters.perform(sel)?.takeUnretainedValue() as? [String]
            else { continue }
            for entry in raw {
                // `accept="image/*"` is a wildcard, not a type. Mapping it to
                // `public.image` would be right; mapping `video/*` to nothing
                // and silently dropping the rest of the list would not, so a
                // wildcard abandons filtering entirely rather than filtering
                // wrongly.
                if entry.hasSuffix("/*") { return nil }
                if let type = make(entry.hasPrefix(".") ? String(entry.dropFirst()) : entry) {
                    types.append(type)
                }
            }
        }
        return types.isEmpty ? nil : types
    }

    // MARK: - camera and microphone

    /// A decision per origin, per cookie jar, remembered in the ledger when the
    /// user ticks the box.
    ///
    /// **Why the jar is part of the key.** PRD §5.2 says the app owns no
    /// durable state, so this lives in `laned-core` — but a permission is
    /// arguably per-cookie-jar rather than per-strip, and that argument wins:
    /// the jar is the identity the site sees (ADR-0003), so a grant made from
    /// one project's shard was never a claim about another's. The row is in the
    /// ledger, keyed by `(data_store_id, origin, feature)`; migration 0008 has
    /// the long version.
    ///
    /// Camera and microphone are two rows even when WebKit asks about both at
    /// once, because "the microphone but not the camera" is a real answer and a
    /// combined row could not hold it — nor answer a later audio-only call
    /// without asking again.
    func webView(_ webView: WKWebView,
                       requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                       initiatedByFrame frame: WKFrameInfo,
                       type: WKMediaCaptureType,
                       decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        let reply = OneShotReply<WKPermissionDecision>(fallback: .deny, reply: decisionHandler)
        let features = Self.features(of: type)
        guard let key = AskOrigin.key(
            scheme: origin.protocol, host: origin.host, port: Int(origin.port))
        else {
            // A `file://` page or an opaque origin. There is nothing to
            // remember a decision *about*, and a permission that cannot be
            // scoped is one that should not be granted.
            Log.warn("pane \(paneId) denied capture to an origin with no host")
            reply.fire(.deny)
            return
        }

        let decided = features.map { store.sitePermission(dataStoreId: dataStoreId, origin: key, feature: $0) }
        if decided.allSatisfy({ $0 == true }) {
            Log.debug("pane \(paneId) capture allowed for \(key) (remembered)")
            reply.fire(.grant)
            return
        }
        if decided.contains(false) {
            // Any remembered *no* is a no for the whole call. Granting the half
            // that was allowed would open the camera on a
            // `getUserMedia({audio, video})` the user said no to.
            Log.debug("pane \(paneId) capture denied for \(key) (remembered)")
            reply.fire(.deny)
            return
        }

        ask(.capture(what: Self.phrase(for: type)), from: frame, reply: reply) { [weak self] outcome in
            guard case .capture(let allowed, let remember) = outcome else { return .deny }
            if remember, let self {
                for feature in features {
                    self.store.setSitePermission(
                        dataStoreId: self.dataStoreId, origin: key, feature: feature, allowed: allowed)
                }
            }
            return allowed ? .grant : .deny
        }
    }

    private static func features(of type: WKMediaCaptureType) -> [SiteFeature] {
        switch type {
        case .camera: return [.camera]
        case .microphone: return [.microphone]
        case .cameraAndMicrophone: return [.camera, .microphone]
        @unknown default: return [.camera, .microphone]
        }
    }

    private static func phrase(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "THE CAMERA"
        case .microphone: return "THE MICROPHONE"
        case .cameraAndMicrophone: return "THE CAMERA AND MICROPHONE"
        @unknown default: return "THE CAMERA AND MICROPHONE"
        }
    }

    // MARK: - HTTP authentication

    /// Basic, digest, NTLM, client certificates and server trust, all through
    /// the one callback WebKit gives for them.
    ///
    /// Nothing typed here is written anywhere — see `WebAuth` for what that
    /// costs and why it is the right v1. The log line names the protection
    /// space and never the credential.
    func webView(_ webView: WKWebView,
                       didReceive challenge: URLAuthenticationChallenge,
                       completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func handle(_ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        typealias Answer = (disposition: URLSession.AuthChallengeDisposition, credential: URLCredential?)
        let reply = OneShotReply<Answer>(
            // `cancelAuthenticationChallenge`, not `performDefaultHandling`: the
            // default for a password challenge is to try again with nothing,
            // which loops. Cancelling gives the page the server's own 401, which
            // is a thing the user can read.
            fallback: (.cancelAuthenticationChallenge, nil),
            reply: { completionHandler($0.disposition, $0.credential) })

        switch WebAuth.kind(of: challenge.protectionSpace) {
        case .serverTrust, .unsupported:
            reply.fire((.performDefaultHandling, nil))

        case .password(let realm, let isProxy):
            Log.debug("pane \(paneId) auth challenge \(WebAuth.describe(challenge))")
            // One protected page issues a challenge for the document and for
            // every subresource under it. Without this cache that is twenty
            // identical sheets for one page.
            if let cached = WebAuth.cached(for: challenge) {
                reply.fire((.useCredential, cached))
                return
            }
            ask(.httpAuth(realm: realm, isProxy: isProxy), from: nil,
                originOverride: AskOrigin.label(
                    scheme: challenge.protectionSpace.protocol,
                    host: challenge.protectionSpace.host,
                    port: challenge.protectionSpace.port),
                reply: reply) { outcome in
                guard case .credential(let user, let password) = outcome else {
                    return (.cancelAuthenticationChallenge, nil)
                }
                // `.forSession` and not `.permanent`. `.permanent` hands the
                // password to CFNetwork to write into the login keychain, which
                // is a disk write this piece has said it will not do — and one
                // the user never asked for, from a sheet with no checkbox
                // offering it.
                let credential = URLCredential(user: user, password: password, persistence: .forSession)
                WebAuth.remember(credential, for: challenge)
                return (.useCredential, credential)
            }

        case .clientCertificate:
            Log.debug("pane \(paneId) client certificate requested by \(WebAuth.describe(challenge))")
            let choices = ClientIdentities.available()
            guard !choices.isEmpty else {
                // Nothing to offer. Cancelling lets the server say so in its
                // own words; hanging here would be a blank pane.
                Log.warn("pane \(paneId): no client identity in the keychain to offer \(challenge.protectionSpace.host)")
                reply.fire((.cancelAuthenticationChallenge, nil))
                return
            }
            ask(.clientCertificate(names: choices.map(\.label)), from: nil,
                originOverride: AskOrigin.label(
                    scheme: challenge.protectionSpace.protocol,
                    host: challenge.protectionSpace.host,
                    port: challenge.protectionSpace.port),
                reply: reply) { outcome in
                guard case .certificate(let index) = outcome, choices.indices.contains(index) else {
                    return (.cancelAuthenticationChallenge, nil)
                }
                // The private key never leaves the Keychain: `SecIdentity` is a
                // handle and the TLS signature is made inside the Security
                // framework. That is what makes this safe to implement with no
                // credential store of our own.
                return (.useCredential, URLCredential(
                    identity: choices[index].identity, certificates: nil, persistence: .none))
            }
        }
    }

    // MARK: - downloads

    /// `<a download>` and anything else WebKit has already decided is a file —
    /// and the one gesture that has to be intercepted before the lane moves.
    ///
    /// The two live in one method because `WKNavigationDelegate` only has one.
    /// A second `decidePolicyFor navigationAction` in another extension of this
    /// class compiles and then silently wins or loses at runtime depending on
    /// nothing you can see, taking downloads or ⌘-click with it.
    func webView(_ webView: WKWebView,
                       decidePolicyFor navigationAction: WKNavigationAction,
                       decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        // Main frame only: a navigation inside an iframe is not the pane going
        // anywhere, and counting one would make every ad frame a redirect hop.
        if navigationAction.targetFrame?.isMainFrame == true {
            trail.willNavigate(
                to: navigationAction.request.url?.absoluteString,
                type: navigationAction.navigationType,
                now: CFAbsoluteTimeGetCurrent())
        }
        // Before the download check. A ⌘-click on `<a download>` is still a
        // download — the modifier says *where the page goes*, and that link
        // does not go to a page.
        if !navigationAction.shouldPerformDownload,
           LinkClick.outcome(
               navigationType: navigationAction.navigationType,
               modifiers: navigationAction.modifierFlags,
               buttonNumber: navigationAction.buttonNumber) == .siblingLane,
           let url = navigationAction.request.url?.absoluteString {
            openSiblingLane(url)
            // Cancelled, not allowed: allowing it is what made ⌘-click navigate
            // in place — the lane opened *and* the page you were reading was
            // replaced, which is both halves of the bug at once.
            return decisionHandler(.cancel)
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    /// A new web lane right of this one, by the same path `target=_blank`
    /// already takes — `newWebLane(near:)` then reveal, so the lane inherits
    /// this one's tag and ordinal placement and the strip materialises it.
    private func openSiblingLane(_ url: String) {
        guard let laneId = store.lane(containing: paneId)?.id else { return }
        do {
            try store.newWebLane(url: url, near: laneId)
        } catch {
            Log.warn("pane \(paneId) could not open a sibling lane for \(url): \(error)")
            return
        }
        Log.debug("pane \(paneId) ⌘-click → sibling lane at \(url)")
        revealNewestLane(rightOf: laneId)
    }

    /// The lane the write just created. `newWebLane` places it immediately
    /// right of this one, so it is found by position rather than by diffing the
    /// pane ids — the reconcile has already run by the time the call returns.
    private func revealNewestLane(rightOf laneId: String) {
        let lanes = store.state.lanes
        guard let index = lanes.firstIndex(where: { $0.id == laneId }),
              lanes.indices.contains(index + 1)
        else { return }
        onRevealLane?(lanes[index + 1].id)
    }

    /// A response the pane cannot display, or one the server marked as an
    /// attachment.
    ///
    /// `canShowMIMEType` alone is not enough: a PDF and a `.txt` are both
    /// displayable, and a server that sends `Content-Disposition: attachment`
    /// for them has said it wants them saved. Without the header check, "Export
    /// CSV" on half the dashboards in the world renders the CSV in the lane.
    func webView(_ webView: WKWebView,
                       decidePolicyFor navigationResponse: WKNavigationResponse,
                       decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            return decisionHandler(.download)
        }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                       navigationAction: WKNavigationAction,
                       didBecome download: WKDownload) {
        adopt(download)
    }

    func webView(_ webView: WKWebView,
                       navigationResponse: WKNavigationResponse,
                       didBecome download: WKDownload) {
        adopt(download)
    }

    private func adopt(_ download: WKDownload) {
        let job = DownloadJob(download)
        job.onChange = { [weak self] in self?.refreshDownloadBar() }
        job.onChallenge = { [weak self] challenge, completion in
            guard let self else { return completion(.performDefaultHandling, nil) }
            self.handle(challenge, completionHandler: completion)
        }
        downloads.append(job)
        refreshDownloadBar()
    }

    func installDownloadBar() {
        downloadBar.onDismiss = { [weak self] id in
            guard let self, let index = self.downloads.firstIndex(where: { $0.id == id }) else { return }
            self.downloads[index].cancel()
            self.downloads.remove(at: index)
            self.refreshDownloadBar()
        }
        downloadBar.onReveal = { [weak self] id in
            self?.downloads.first { $0.id == id }?.reveal()
        }
    }

    func refreshDownloadBar() {
        // `WKDownload.progress` ticks once per chunk, which on a fast local
        // connection is hundreds of times a second, and each tick rebuilds the
        // rows. 10 Hz is faster than a number can be read and slow enough that
        // a big download does not spend the main thread on its own progress
        // bar. A state change — finished, failed, a new file — always redraws,
        // because that is the frame the user is actually waiting for.
        let states = downloads.map(\.state)
        let now = CFAbsoluteTimeGetCurrent()
        if states == lastDownloadStates, now - lastDownloadDraw < 0.1 { return }
        lastDownloadStates = states
        lastDownloadDraw = now

        downloadBar.show(downloads)
        let wanted = WebDownloadBar.height(rows: downloads.count)
        guard downloadBarHeight.constant != wanted else { return }
        // 140 ms, the find bar's number, because the page above moves by the
        // same amount for the same reason and two different durations for one
        // gesture reads as the lane stuttering.
        guard !Motion.isReduced else { return downloadBarHeight.constant = wanted }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            downloadBarHeight.animator().constant = wanted
        }
    }

    /// Stop every download this pane started. Called from `tearDown`: a
    /// `WKDownload` is not attached to the document and would otherwise keep
    /// running, reporting progress into a bar that is no longer in any window.
    func cancelDownloads() {
        for job in downloads where job.state == .running { job.cancel() }
        downloads = []
    }

    // MARK: - the queue

    /// Raise a question, or put it behind the one already up.
    ///
    /// `frame` is what names the origin, and it is the frame that *made the
    /// call* rather than the pane's own URL. An ad iframe calling `alert()`
    /// must say it is the ad iframe asking; attributing it to the page around
    /// it is how a dialog becomes a phishing surface.
    private func ask(_ prompt: AskPrompt,
                     from frame: WKFrameInfo?,
                     answer: @escaping (AskOutcome) -> Void) {
        let reply = OneShotReply<AskOutcome>(fallback: .cancelled, reply: answer)
        ask(prompt, from: frame, reply: reply) { $0 }
    }

    /// The general form: an ask whose reply is some other type, mapped from the
    /// outcome. `transform` runs exactly once, on the one outcome that happens.
    private func ask<Value>(_ prompt: AskPrompt,
                            from frame: WKFrameInfo?,
                            originOverride: String? = nil,
                            reply: OneShotReply<Value>,
                            transform: @escaping (AskOutcome) -> Value) {
        let origin = originOverride ?? Self.origin(of: frame) ?? AskOrigin.label(for: webView?.url)
        let pending = PendingAsk(
            prompt: prompt, origin: origin,
            reply: OneShotReply<AskOutcome>(fallback: .cancelled) { outcome in
                reply.fire(transform(outcome))
            })
        let isFirst = askQueue.enqueue(pending)
        WebAskCenter.shared.began(paneId: paneId)
        // The *kind* and the origin, never the text. `MAXPANE_DEBUG` is on for
        // whole sessions, and a page chooses every character of `alert()` and
        // of a `prompt()`'s default — which is where a password manager puts a
        // prefilled value. What is worth logging is that something asked and
        // who; the words are on screen.
        Log.debug("pane \(paneId) asks: \(Self.kindName(prompt)) from \(origin) (queued \(askQueue.count))")
        if isFirst { presentCurrentAsk() }
    }

    private static func kindName(_ prompt: AskPrompt) -> String {
        switch prompt {
        case .alert: return "alert"
        case .confirm: return "confirm"
        case .prompt: return "prompt"
        case .capture(let what): return "capture(\(what))"
        case .httpAuth(_, let isProxy): return isProxy ? "proxy-auth" : "http-auth"
        case .clientCertificate(let names): return "client-cert(\(names.count) available)"
        }
    }

    private static func origin(of frame: WKFrameInfo?) -> String? {
        guard let frame else { return nil }
        let security = frame.securityOrigin
        guard !security.host.isEmpty else { return nil }
        return AskOrigin.label(
            scheme: security.protocol, host: security.host, port: Int(security.port))
    }

    private func presentCurrentAsk() {
        guard askSheet == nil, let pending = askQueue.current else { return }
        let sheet = WebAskSheet(prompt: pending.prompt, origin: pending.origin) { [weak self] outcome in
            self?.finishAsk(with: outcome)
        }
        sheet.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(sheet)
        NSLayoutConstraint.activate([
            sheet.topAnchor.constraint(equalTo: contentHost.topAnchor),
            sheet.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            sheet.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            sheet.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),
        ])
        askSheet = sheet
        sheet.takeFocus()
    }

    private func finishAsk(with outcome: AskOutcome) {
        askSheet = nil
        guard let pending = askQueue.current else { return }
        // The page first, the bookkeeping after. If anything below were to
        // throw or early-return, the completion handler has already run and the
        // web view is not hung.
        pending.reply.fire(outcome)
        _ = askQueue.finish()
        if askQueue.isEmpty {
            WebAskCenter.shared.ended(paneId: paneId)
            // The page gets the keyboard back. Without this the pane is focused
            // according to the ledger and deaf in fact, which is the same bug
            // `applyPendingFocus` documents for lane recycling.
            takeFocus()
        } else {
            presentCurrentAsk()
        }
    }

    /// Answer everything outstanding with the safe answer and take the sheet
    /// down. The one path for a pane that is closing, and for a page that is
    /// being destroyed under an unanswered question.
    func drainAsks() {
        askSheet?.dismissWithoutAnswering()
        askSheet = nil
        let abandoned = askQueue.drain()
        for pending in abandoned { pending.reply.abandon() }
        if !abandoned.isEmpty {
            Log.debug("pane \(paneId) abandoned \(abandoned.count) unanswered ask(s)")
        }
        WebAskCenter.shared.ended(paneId: paneId)
        // A file picker belongs to the pane too, and `NSOpenPanel.begin` keeps
        // its own window alive until something closes it. Cancelling runs the
        // completion handler with `.cancel`, which fires the `OneShotReply` and
        // unblocks the page — so this is the answer, not just the tidy-up.
        for panel in openPanels { panel.cancel(nil) }
        openPanels = []
    }

    /// True while a page in this pane is waiting on a person.
    var isAsking: Bool { !askQueue.isEmpty }
}
