import AppKit
import WebKit

/// A page's popup — the OAuth sign-in window — as a dialog over the window.
///
/// The owner, signing in to LinkedIn with Google: *"browser popups should not
/// open new panes … it breaks the lanes flow and causes too many lanes to
/// appear and lose focus. I … didn't see the lane and clicked sign in a bunch
/// more times."* Until this, a `window.open` became a web lane written beside
/// its opener. That lane landed wherever the opener was — scrolled away,
/// docked, under the gallery — took the focus, multiplied with every click on
/// "Sign in", outlived the sign-in as a ledger row restored on the next launch,
/// and when it closed itself nothing gave the keyboard back.
///
/// So a popup is not a place on the strip. It is a conversation with the page
/// that opened it, and it is drawn the way every other conversation in the app
/// is: `Popup`, square, centred over the window whatever the opener's state.
///
/// - **The same web view WebKit asked for.** Built from the configuration
///   `createWebViewWith` handed over, which is where `window.opener`,
///   `postMessage` and the shared cookie jar live. A fresh configuration severs
///   all three.
/// - **Its real origin is always on screen.** `WebPopupBar` — the one thing in
///   the dialog the page cannot draw.
/// - **It closes the way a sign-in window should**: Esc, ✕, the page's own
///   `window.close()`, the opener pane closing or its page being evicted, or
///   the opener leaving for another origin (`PopupOpener`). Never on a click
///   away — clicking back into the page must not throw away a half-typed
///   password.
/// - **One per opener.** Another `window.open` from the same page replaces
///   what is in this one rather than stacking; one from *inside* it — an
///   account chooser — is a child dialog over it.
/// - **The keyboard goes home.** Key while it is open; when it closes, the
///   opener pane has the focus again, revealed if it was off screen.
/// - **Transient.** Nothing about it reaches the ledger, so a relaunch does not
///   bring back a sign-in window whose opener is gone.
@MainActor
final class WebPopupDialog: Popup {
    /// The pane whose page opened this — directly, or through the dialog this
    /// one sits on. It owns the dialog; the dialog only borrows it for what a
    /// popup shares with its opener: the cookie jar, lanes, downloads.
    private(set) weak var pane: WebPaneController?
    /// The dialog this one was opened from, for an account chooser.
    private(set) weak var parentDialog: WebPopupDialog?
    /// The popup this one's page has open, if any.
    var child: WebPopupDialog?
    /// Where the opener was when it asked. See `PopupOpener`.
    let openerURL: String?

    private(set) var webView: ChromeWebView
    let bar = WebPopupBar()
    /// The page, and any question the page asks, laid out below the bar.
    let pageHost = NSView()

    /// Internal rather than private: `WebPopupDelegate.swift` fills them.
    var askQueue = AskQueue<PendingAsk>()
    var askSheet: WebAskSheet?

    private var observations: [NSKeyValueObservation] = []
    /// Set by the first `dismiss`. A popup that is fading out is no longer the
    /// opener's popup: another `window.open` gets a new dialog, and nothing
    /// the fading page asks for is started.
    private(set) var isDismissed = false

    // MARK: - opening

    /// The popup `configuration` is for: in `current` if that is still open,
    /// otherwise in a new dialog centred over `window`.
    ///
    /// Replacing is what makes five clicks on "Sign in" one sign-in. A page that
    /// names its window (`window.open(url, "auth", …)`) never gets here twice —
    /// WebKit navigates the window it already has — so this is the case where
    /// it did not, and the answer is the same.
    static func show(
        replacing current: WebPopupDialog?, configuration: WKWebViewConfiguration,
        features: WKWindowFeatures, pane: WebPaneController, parent: WebPopupDialog?,
        openerURL: String?, over window: NSWindow?
    ) -> WebPopupDialog {
        // The popup must be in the opener's cookie jar or the cookie the
        // sign-in sets lands where the opener cannot read it, and the login
        // evaporates at the redirect. WebKit copies the opener's data store
        // into the configuration it hands over, so this is a check rather than
        // an assignment: assigning would be the thing that broke it.
        if configuration.websiteDataStore !== DataStorePool.shared.store(pane.dataStoreId) {
            Log.warn("pane \(pane.paneId) popup arrived with a different data store; cookies will not be shared")
        }
        if let current, current.isOpen, !current.isDismissed {
            current.replace(configuration: configuration, features: features)
            return current
        }
        let dialog = WebPopupDialog(
            configuration: configuration, features: features, pane: pane, parent: parent,
            openerURL: openerURL)
        dialog.present(over: window)
        return dialog
    }

    private init(
        configuration: WKWebViewConfiguration, features: WKWindowFeatures?,
        pane: WebPaneController, parent: WebPopupDialog?, openerURL: String?
    ) {
        let page = Self.pageSize(features)
        webView = ChromeWebView(frame: NSRect(origin: .zero, size: page), configuration: configuration)
        self.pane = pane
        self.parentDialog = parent
        self.openerURL = openerURL
        super.init(
            size: PopupGeometry.dialogSize(page: page, bar: WebPopupBar.height),
            dismissal: .explicitOnly, resizable: true,
            minSize: PopupGeometry.dialogSize(page: PopupGeometry.minimumPage, bar: WebPopupBar.height))
        // Not `.floating`, unlike every other popup. A sign-in page raises
        // windows of its own — the file panel, the Keychain's "allow" panel —
        // and a floating dialog would sit on top of the one thing it is waiting
        // for. As a child of the strip window it still stays above the strip.
        window?.level = .normal
        window?.contentView = buildContent()
        bar.onClose = { [weak self] in self?.dismiss() }
        wire(webView)
    }

    private static func pageSize(_ features: WKWindowFeatures?) -> NSSize {
        PopupGeometry.pageSize(width: features?.width?.doubleValue, height: features?.height?.doubleValue)
    }

    private func buildContent() -> NSView {
        let content = WebPopupContent()
        content.dialog = self
        content.wantsLayer = true
        content.layerBackgroundColor = Theme.laneBackground
        // On the content's own layer, which Core Animation composites above
        // every sublayer — the web view included — so the page cannot paint
        // over the dialog's edge.
        content.layerBorderColor = Theme.laneBorder
        content.layer?.borderWidth = Theme.borderWidth
        content.layer?.cornerRadius = 0
        pageHost.wantsLayer = true
        for view in [bar, pageHost] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: WebPopupBar.height),
            pageHost.topAnchor.constraint(equalTo: bar.bottomAnchor),
            pageHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pageHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            pageHost.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        return content
    }

    /// Everything a popup's web view needs to be this dialog's.
    private func wire(_ view: ChromeWebView) {
        // The lane's ground rather than WebKit's white, for the same reason a
        // pane does it (`WebPaneController.wire`): a sign-in window arriving as
        // a white flash over a dark strip is the least welcome flash there is.
        view.onAppearanceChange { view in
            (view as? WKWebView)?.underPageBackgroundColor =
                NSColor(cgColor: Theme.laneBackground.cgColor(in: view.effectiveAppearance))
        }
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.translatesAutoresizingMaskIntoConstraints = false
        pageHost.addSubview(view, positioned: .below, relativeTo: askSheet)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        // KVO for the address, not `didCommit`: a sign-in flow is a chain of
        // redirects and `pushState`s, and the bar has to be right at every hop
        // or it is not worth reading.
        observations = [
            view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                Task { @MainActor in self?.addressChanged(view.url?.absoluteString) }
            },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.bar.setProgress(view.isLoading ? view.estimatedProgress : 0) }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in if !view.isLoading { self?.bar.setProgress(0) } }
            },
        ]
    }

    private func addressChanged(_ url: String?) {
        bar.setURL(url)
        // A chooser this page opened is talking to the page that was here.
        if let child, PopupOpener.hasLeft(openedFrom: child.openerURL, now: url) {
            child.dismiss()
        }
    }

    /// Put a new popup where the old one was, with a crossfade.
    private func replace(configuration: WKWebViewConfiguration, features: WKWindowFeatures) {
        child?.dismiss(returningFocus: false)
        drainAsks()
        let old = webView
        let fresh = ChromeWebView(frame: pageHost.bounds, configuration: configuration)
        webView = fresh
        if !Motion.isReduced, let layer = pageHost.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.pane
            fade.timingFunction = Motion.easeOutTiming
            layer.add(fade, forKey: kCATransition)
        }
        retire(old)
        wire(fresh)
        resize(toPage: Self.pageSize(features))
        window?.makeFirstResponder(fresh)
        Log.debug("pane \(pane?.paneId ?? "?") popup replaced the one it had open")
    }

    /// The new page asked for a different size. Eased, from the centre.
    private func resize(toPage page: NSSize) {
        guard let panel = window else { return }
        let area = panel.parent.map { $0.convertToScreen($0.contentLayoutRect) }
            ?? panel.screen?.visibleFrame ?? panel.frame
        let target = Popup.frame(
            size: PopupGeometry.dialogSize(page: page, bar: WebPopupBar.height),
            minSize: panel.minSize, in: area)
        guard target != panel.frame else { return }
        guard !Motion.isReduced else { return panel.setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.pane
            context.timingFunction = Motion.easeOutTiming
            panel.animator().setFrame(target, display: true)
        }
    }

    // MARK: - closing

    override func popupDidPresent() {
        window?.makeFirstResponder(webView)
    }

    /// Esc. A question the page is asking is answered first — Cancel, as it
    /// would be in a pane — and only an Esc with nothing asked closes the
    /// dialog.
    override func popupCancelled() {
        if let askSheet { return askSheet.cancelOperation(nil) }
        // A video filling the dialog's page leaves full screen first. `Popup`'s
        // Esc monitor sees the key before the page does, so the page's own Esc
        // handling never runs here and has to be asked for.
        if pageIsFullscreen {
            pageIsFullscreen = false
            webView.evaluateJavaScript(PaneFullscreen.exitScript)
            return
        }
        dismiss()
    }

    /// True while an element of the popup's page fills the dialog's web area.
    /// The origin bar stays: it is the one row the page cannot draw, and a
    /// page that could hide it on request could be any site it liked.
    /// Set by the opener pane, which is where the popup's script messages
    /// arrive — see `WebPaneController.fullScreenMessage`.
    var pageIsFullscreen = false

    /// Close it, and hand the keyboard back to whatever opened it.
    ///
    /// `returningFocus` is false only when there is nothing to return to: the
    /// opener pane is closing, its page is being evicted, or this is a child
    /// going with its parent.
    func dismiss(returningFocus: Bool = true) {
        guard !isDismissed else { return }
        isDismissed = true
        child?.dismiss(returningFocus: false)
        // Before the fade, not after it: every outstanding question holds a
        // WebKit completion handler, and a page that never hears back never
        // runs another line of JavaScript.
        drainAsks()
        let finish = { [weak self] in
            guard let self else { return }
            self.retire(self.webView)
            if let parent = self.parentDialog {
                parent.childDidClose(self, returningFocus: returningFocus)
            } else {
                self.pane?.popupDidClose(self, returningFocus: returningFocus)
            }
        }
        guard isOpen else { return finish() }
        closePopup(completion: finish)
    }

    /// A web view this dialog no longer shows. Released with the dialog, which
    /// is when WebKit closes the page and the opener's handle reads `closed`.
    private func retire(_ view: WKWebView) {
        view.stopLoading()
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.removeFromSuperview()
    }

    private func childDidClose(_ dialog: WebPopupDialog, returningFocus: Bool) {
        if child === dialog { child = nil }
        // `Popup` already made this panel key again; the page is what types.
        guard returningFocus, isOpen, child == nil else { return }
        window?.makeFirstResponder(askSheet ?? webView)
    }

    // MARK: - keys

    /// What an app shortcut does while a popup has the keyboard.
    enum KeyAction: Equatable {
        /// ⌘W: the dialog is the thing in front, so it is the thing that closes.
        case close
        /// ⌥⌘L: this page's form, not the one behind it.
        case fill
        case reload
        /// ⌃⌘P: the dialog's page is the one in front, so it is the one that
        /// prints — a receipt is as likely to be in a popup as behind it.
        case print
        /// Menu actions aimed at "the focused page", which here would be the
        /// opener behind the dialog — reloading it, zooming it, closing its
        /// lane or saving a password for it, in the middle of its own sign-in.
        case ignore
        /// Everything about the strip rather than a page: the menu has it.
        case app
    }

    static func keyAction(for command: Command) -> KeyAction {
        switch command {
        case .closePane: return .close
        case .fillPassword: return .fill
        case .reload, .hardReload: return .reload
        case .printPage: return .print
        case .editAddress, .zoomIn, .zoomOut, .zoomReset, .bookmarkPage, .savePassword, .closeLane, .savePDF:
            return .ignore
        default: return .app
        }
    }

    /// True when the key was this dialog's to handle.
    fileprivate func handleKey(_ event: NSEvent) -> Bool? {
        guard let typed = event.charactersIgnoringModifiers, event.modifierFlags.contains(.command) else {
            return nil
        }
        let chord = KeyChord(key: typed, modifiers: event.modifierFlags)
        guard let command = Command.allCases.first(where: { Keymap.active.chords(for: $0).contains(chord) })
        else { return nil }
        switch Self.keyAction(for: command) {
        case .close: dismiss()
        case .fill: fillPassword()
        case .reload:
            if command == .hardReload { webView.reloadFromOrigin() } else { webView.reload() }
        case .print: WebPrinting.print(webView, over: window)
        case .ignore: break
        // Back to the menu before the web view can claim it, exactly as
        // `WebPaneContainer` does for a pane.
        case .app: return false
        }
        return true
    }

    // MARK: - passwords

    /// ⌥⌘L inside the dialog, against the popup's own origin.
    func fillPassword() {
        guard let origin = PasswordOrigin(url: webView.url) else {
            return bar.say("This page has no address to match a password against", warning: true)
        }
        let saved = KeychainPasswords.accounts(for: origin).filter { !$0.isHTTPAuth }
        switch saved.count {
        case 0:
            bar.say("No password saved for \(origin.label)", warning: true)
        case 1:
            fill(saved[0])
        default:
            let menu = NSMenu()
            let header = NSMenuItem(title: "Fill which sign-in?", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for login in saved {
                let item = NSMenuItem(title: login.menuTitle, action: #selector(fillFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = login.account
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 8, y: -2), in: bar)
        }
    }

    @objc private func fillFromMenu(_ sender: NSMenuItem) {
        guard let origin = PasswordOrigin(url: webView.url), let account = sender.representedObject as? String,
              let login = KeychainPasswords.accounts(for: origin)
                  .first(where: { $0.account == account && !$0.isHTTPAuth })
        else { return }
        fill(login)
    }

    private func fill(_ login: KeychainPasswords.SavedLogin) {
        PasswordFill.fill(login, into: webView, logName: "popup of pane \(pane?.paneId ?? "?")") {
            [weak self] message in self?.bar.say(message, warning: false)
        }
    }
}

/// The dialog's content view, for the keys it has to see before the page does.
@MainActor
private final class WebPopupContent: NSView {
    weak var dialog: WebPopupDialog?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.isKeyWindow == true, let handled = dialog?.handleKey(event) { return handled }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - the origin bar

/// The one row a popup's page cannot draw: where it really is.
///
/// A sign-in dialog is exactly where a page would like to be mistaken for
/// another — a borderless square with a Google form in it looks like Google
/// whoever served it. So the bar says, from `WKWebView.url` and never from
/// anything the page chooses: a padlock for https, the amber ⚠ the chrome bar
/// uses for plain http, and the host with its registrable name in contrast,
/// the same emphasis `BrowserAddress` gives the address field. Nothing on it
/// can be typed into; the full address is on hover and a click copies it.
///
/// Unlike the chrome bar, https gets its padlock. There the absence of a lock
/// is the legible state because a pane is one of ten; here the origin *is* the
/// content of the row, and the lock is what makes it read as a claim checked
/// rather than a title.
@MainActor
final class WebPopupBar: NSView {
    static let height: CGFloat = 28

    var onClose: (() -> Void)?

    private let origin = OriginLabel(labelWithString: "")
    private let note = NSTextField(labelWithString: "")
    private let close = ChromeButton(icon: .x)
    private(set) var url = ""
    private var progress: Double = 0
    private var noteTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        origin.lineBreakMode = .byTruncatingHead
        origin.wantsLayer = true
        origin.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        origin.onClick = { [weak self] in self?.copyAddress() }

        note.font = Theme.mono(10, weight: .medium)
        note.textColor = Theme.dimText
        note.lineBreakMode = .byTruncatingTail
        note.alphaValue = 0
        note.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        note.setContentHuggingPriority(.required, for: .horizontal)

        close.isDimmed = true
        close.toolTip = "Close (Esc)"
        close.onClick = { [weak self] in self?.onClose?() }

        for view in [origin, note, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            origin.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            origin.centerYAnchor.constraint(equalTo: centerYAnchor),
            note.leadingAnchor.constraint(greaterThanOrEqualTo: origin.trailingAnchor, constant: 10),
            note.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -6),
            note.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setURL(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - what it says

    func setURL(_ raw: String?) {
        let next = raw ?? ""
        let changed = next != url
        url = next
        let text = Self.originText(for: url)
        if changed, !Motion.isReduced, window != nil, let layer = origin.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.12
            layer.add(fade, forKey: kCATransition)
        }
        origin.attributedStringValue = text
        origin.toolTip = url.isEmpty ? nil : "\(url)\nClick to copy"
        needsDisplay = true
    }

    func setProgress(_ value: Double) {
        progress = value
        needsDisplay = true
    }

    /// A line at the right of the bar for a few seconds: a failed load, a
    /// fill's answer, "copied".
    func say(_ text: String, warning: Bool, for seconds: TimeInterval = 5) {
        note.stringValue = text
        note.textColor = warning ? WebChromeBar.warning : Theme.dimText
        note.toolTip = text
        fadeNote(to: 1)
        noteTimer?.invalidate()
        noteTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fadeNote(to: 0) }
        }
    }

    private func fadeNote(to alpha: CGFloat) {
        guard !Motion.isReduced else { return note.alphaValue = alpha }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            note.animator().alphaValue = alpha
        }
    }

    private func copyAddress() {
        guard !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        say("copied", warning: false, for: 1.5)
    }

    /// The origin as three runs: dim subdomain (and `http://`, in amber),
    /// the registrable name in contrast, dim port. Never the path — a path is
    /// the page's to choose, and a long one would push the host out of sight.
    static func originText(for raw: String) -> NSAttributedString {
        let dim: [NSAttributedString.Key: Any] = [.font: Theme.mono(11), .foregroundColor: Theme.dimText]
        let parsed = URL(string: raw)
        guard let parsed, let host = parsed.host, !host.isEmpty else {
            // `about:blank` while the first load is still provisional, or a
            // `data:` page. Say which, and not a data URL's megabytes.
            let label = raw.hasPrefix("about:") ? raw : (parsed?.scheme.map { "\($0):" } ?? raw)
            return NSAttributedString(string: label, attributes: dim)
        }
        let display = BrowserAddress.display(raw)
        let out = NSMutableAttributedString()
        if BrowserAddress.security(of: raw) == .insecure, display.dimLead.hasPrefix("http://") {
            out.append(NSAttributedString(string: "http://", attributes: [
                .font: Theme.mono(11, weight: .medium), .foregroundColor: WebChromeBar.warning,
            ]))
            out.append(NSAttributedString(string: String(display.dimLead.dropFirst("http://".count)), attributes: dim))
        } else {
            out.append(NSAttributedString(string: display.dimLead, attributes: dim))
        }
        out.append(NSAttributedString(string: display.strong, attributes: [
            .font: Theme.mono(11, weight: .semibold), .foregroundColor: NSColor.labelColor,
        ]))
        if let port = parsed.port {
            out.append(NSAttributedString(string: ":\(port)", attributes: dim))
        }
        return out
    }

    // MARK: - drawing

    override func draw(_ dirtyRect: NSRect) {
        Theme.laneBackground.setFill()
        bounds.fill()
        // The hairline between the bar and the page, and the load on it —
        // `Theme.working`, as in the chrome bar, because it is the same news.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth).fill()
        if progress > 0.001, progress < 0.999 {
            Theme.working.setFill()
            NSRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: 2).fill()
        }

        let slot = NSRect(x: 10, y: (bounds.height - 12) / 2, width: 12, height: 12)
        switch BrowserAddress.security(of: url) {
        case .secure:
            IconImage.make(.lock, points: 12, colour: Theme.dimText)?.draw(in: slot)
        case .insecure:
            drawGlyph("⚠", colour: WebChromeBar.warning, in: slot)
        case .local:
            drawGlyph("⌂", colour: Theme.dimText, in: slot)
        case .none:
            break
        }
    }

    private func drawGlyph(_ glyph: String, colour: NSColor, in slot: NSRect) {
        let text = NSAttributedString(string: glyph, attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: colour,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2))
    }
}

/// A label that copies rather than selects, and does not drag the dialog.
@MainActor
private final class OriginLabel: NSTextField {
    var onClick: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
