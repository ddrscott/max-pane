import AppKit

/// A web pane's browser chrome: one row, at the foot of the pane.
///
/// ## Why one row, and why at the bottom
///
/// Vivaldi spends four horizontal bands on this — tab bar, address bar,
/// bookmarks bar, status line — across 1900 pt. A lane is 656 pt and can be
/// dragged to 420, and it already gives 28 pt to the lane header at the top. A
/// second bar up there would push the page down by 56 pt before it has drawn a
/// pixel, in a column whose whole point is that the page is readable.
///
/// So: one band, and the owner said "at the bottom or top", which settles it.
/// The bottom is where this app's remaining chrome already is (`StatusBar`), it
/// is where Vivaldi's own link-target line is, and it keeps the *page* the first
/// thing under the lane's title.
///
/// ## The decision that makes one row enough
///
/// **The address and the hovered link share the field.** They answer the same
/// question a second apart — "where am I" and "where would this take me" — and
/// you are never asking both at once, because the second only has an answer
/// while the pointer is on a link. Vivaldi can afford a row for each; a lane
/// cannot, and two half-width fields would truncate both. So the field shows
/// the page's address, and swaps to the link target for as long as the pointer
/// rests on one, with a 120 ms crossfade so the substitution is legible as a
/// substitution rather than as the URL changing under you.
///
/// ## What is always here, and what is not
///
/// Always: back, forward, reload/stop, the address (editable, domain
/// emphasised), find, and a load progress hairline. Those are the five things
/// the round's kill criterion names plus the two that cost a glyph each.
///
/// Only when it has something to say: the security warning (an `http://` page
/// only — a padlock on every https page is a padlock nobody reads, so the
/// legible state is its absence) and the zoom readout (only off 100%, where it
/// is both the readout and the Reset button).
///
/// The star is here now, and it used to say here that it never would be: *the
/// strip is the bookmarks bar and a pinned lane is the star*. That was a real
/// argument and it holds for one page at a time — a docked lane is a page you
/// have decided to keep in front of you. What it cannot do is keep a page you
/// are *not* looking at, and the owner keeps eight folders of those and opens
/// them daily. So one glyph, in the row that already has five, lit when this
/// page is kept; the folders live in the sidebar, which is the surface that
/// already groups things, and not in a sixth band across the top.
///
/// Never: a separate search box — the address field takes a question as readily
/// as an address, because a portrait column has room for one field and
/// `OmniText.looksLikeURL` already knows the difference.
@MainActor
final class WebChromeBar: NSView {
    static let height: CGFloat = 26

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReloadOrStop: (() -> Void)?
    var onFind: (() -> Void)?
    /// The star. Keep this page if it is not kept, and open the editor either
    /// way — the same thing ⌘D does, because they are one action with two
    /// doors.
    var onStar: (() -> Void)?
    /// The key. Opens the password menu for this page — fill, or save.
    ///
    /// It is a menu and not a one-click fill on purpose: a site can have more
    /// than one saved account, and a button that filled "the" password would be
    /// a button that picks one of someone's two logins for them.
    var onKeyMenu: (() -> NSMenu?)?
    var onZoomReset: (() -> Void)?
    /// A line typed into the address field. Already trimmed; not yet resolved —
    /// the pane decides whether it is an address or a search.
    var onNavigate: ((String) -> Void)?
    /// Click-and-hold or right-click on back/forward: the pane's own history,
    /// which is the only place `backForwardList` is reachable by mouse.
    var onBackMenu: (() -> NSMenu?)?
    var onForwardMenu: (() -> NSMenu?)?

    private let back = ChromeButton(icon: .arrowLeft)
    private let forward = ChromeButton(icon: .arrowRight)
    private let reload = ChromeButton(icon: .rotateCw)
    private let find = ChromeButton(icon: .search)
    private let star = ChromeButton(icon: .star)
    /// `•••` and not a key glyph. U+26BF ⚿ is the obvious choice and is in
    /// neither JetBrains Mono nor Menlo, so AppKit would substitute a face for
    /// that one character in a 26 pt mono row — the one place a font fallback
    /// is impossible not to notice. Three bullets are a password field drawn at
    /// glyph size, they exist in every font, and they need no legend.
    private let key = ChromeButton(icon: .keyRound)
    private let zoom = ChromeButton(glyph: "100%")
    private let security = NSTextField(labelWithString: "")
    private let address = AddressField()

    private var currentURL: String = ""
    private var hovered: String?
    private var progress: Double = 0
    private var isLoading = false
    /// What the last navigation failed with, while it is still on screen.
    private var failure: String?
    private var failureTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        security.font = Theme.mono(11, weight: .bold)
        security.textColor = Self.warning
        security.isHidden = true
        security.setContentHuggingPriority(.required, for: .horizontal)

        address.font = Theme.mono(11)
        address.onCommit = { [weak self] text in self?.onNavigate?(text) }
        // The address is the only thing on the row that gives, in both
        // directions: it shrinks when the lane is dragged to 420 pt, and it
        // takes all the slack when the lane is wide so that find and zoom sit
        // against the right edge rather than trailing the URL like a suffix.
        // A hugging priority of 1, the same trick `StatusBar` uses for its
        // spacer — `.defaultLow` is 250 and ties with every other view here.
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        address.setContentHuggingPriority(.init(1), for: .horizontal)

        back.onClick = { [weak self] in self?.onBack?() }
        forward.onClick = { [weak self] in self?.onForward?() }
        reload.onClick = { [weak self] in self?.onReloadOrStop?() }
        find.onClick = { [weak self] in self?.onFind?() }
        star.onClick = { [weak self] in self?.onStar?() }
        // A left click opens the same menu a right click would. There is no
        // primary action to put on the click: every one of them puts a password
        // somewhere, and each wants naming before it happens.
        key.onClick = { [weak self] in
            guard let self, let menu = self.onKeyMenu?() else { return }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: self.key.bounds.height + 2),
                       in: self.key)
        }
        zoom.onClick = { [weak self] in self?.onZoomReset?() }
        back.onMenu = { [weak self] in self?.onBackMenu?() }
        forward.onMenu = { [weak self] in self?.onForwardMenu?() }

        back.toolTip = "Back — click and hold for this pane's history"
        forward.toolTip = "Forward"
        reload.toolTip = "Reload (⌘R)"
        find.toolTip = "Find in page (⌘F)"
        star.toolTip = "Keep this page (⌘D)"
        key.toolTip = "Passwords for this site (⌥⌘L fills)"
        key.isHidden = true
        zoom.toolTip = "Zoom — click for actual size (⌘0)"
        zoom.isHidden = true

        // The star sits between the address and find: it is about *this page*,
        // which is what the field to its left says, where find and zoom are
        // about reading whatever is on screen.
        let row = NSStackView(views: [back, forward, reload, security, address, star, key, find, zoom])
        row.orientation = .horizontal
        row.spacing = 2
        row.alignment = .centerY
        // `.fill`, not the default `.gravityAreas`: the address has to take all
        // the slack so find and zoom sit against the lane's right edge. Left as
        // gravity areas, every control huddles at the left and the row reads as
        // one run-on string.
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.setCustomSpacing(6, after: reload)
        row.setCustomSpacing(4, after: security)
        row.setCustomSpacing(6, after: address)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: Self.height),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    // MARK: - what it says

    func setURL(_ url: String?) {
        currentURL = url ?? ""
        // The field keeps the unabbreviated address separately from the three
        // runs it draws, because clicking it has to open *that* for editing —
        // see `AddressField.fullURL`.
        address.fullURL = currentURL
        renderAddress()
    }

    /// The link under the pointer, or nil when there is none.
    func setHoveredLink(_ url: String?) {
        let next = (url?.isEmpty == false) ? url : nil
        guard next != hovered else { return }
        hovered = next
        renderAddress()
    }

    func setNavigation(canGoBack: Bool, canGoForward: Bool, loading: Bool) {
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        if loading != isLoading {
            isLoading = loading
            // A load starting is the answer to "did anything happen", so the
            // previous failure has stopped being the most recent news.
            if loading { clearFailure() }
            // The same button, because stop and reload are the same intention
            // at two moments and a portrait column has no room for the second
            // one to be a separate target.
            reload.icon = loading ? .x : .rotateCw
            reload.toolTip = loading ? "Stop" : "Reload (⌘R)"
        }
    }

    func setProgress(_ value: Double) {
        progress = value
        needsDisplay = true
    }

    /// A navigation failed. Say so in the slot the hover target already
    /// borrows, and take the hairline down.
    ///
    /// The hairline is not cosmetic. A failed load parks `estimatedProgress`
    /// around 0.15 and never moves it again, so the bar drew a green third of a
    /// line forever — watched for 25 seconds — while `isLoading` had already
    /// gone false and the ✕ had reverted to ↻. A progress bar for a load that
    /// is not running, and no way to cancel it.
    ///
    /// It outranks the hovered link for the few seconds it shows. The hover
    /// answer is re-askable by moving the pointer; this one answers a question
    /// asked a moment ago — "did my keystroke reach anything" — and a failed
    /// load leaves the *previous* page under the pointer, full of links to
    /// hover it away with.
    func showFailure(_ text: String) {
        setProgress(0)
        failure = text
        renderAddress()
        failureTimer?.invalidate()
        // Long enough to read a six-word line and glance away; short enough
        // that the lane goes back to being addressed by its address. The slot's
        // permanent job is to say where you are.
        failureTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.clearFailure() }
        }
    }

    func clearFailure() {
        failureTimer?.invalidate()
        failureTimer = nil
        guard failure != nil else { return }
        failure = nil
        renderAddress()
    }

    /// What the bookmark editor hangs off. The star is the row's own view, so
    /// the popover follows it when the lane is dragged narrower.
    var starAnchor: NSView { star }

    /// What the fill menu hangs off, and where a fill's answer is anchored.
    var keyAnchor: NSView { key }

    /// Whether this site has a password saved for it.
    ///
    /// Hidden entirely when it has none, rather than shown greyed. A key that
    /// is always there is a key people stop seeing, and the one fact it carries
    /// — *there is a sign-in saved for this site* — is only worth a glyph when
    /// it is true. It goes green when there is one, which is this app's one
    /// meaning for the accent: the thing here is live.
    func setHasSavedPassword(_ saved: Bool) {
        key.isHidden = !saved
        key.tint = saved ? Theme.accent : nil
    }

    /// Whether this page is one of the ones kept.
    ///
    /// A filled green star, not a hollow one gone bright: the difference
    /// between the two states has to survive being glanced at in a 420 pt
    /// column, and `☆`/`★` differ in their middle rather than only in weight.
    func setKept(_ kept: Bool) {
        star.icon = kept ? .starFilled : .star
        star.tint = kept ? Theme.accent : nil
        star.toolTip = kept ? "Kept — click to edit or remove (⌘D)" : "Keep this page (⌘D)"
    }

    func setZoom(_ level: Double) {
        let atRest = abs(level - 1) < 0.001
        zoom.glyph = "\(Int((level * 100).rounded()))%"
        guard zoom.isHidden != atRest else { return }
        // Fade rather than cut: the row's contents shift when it appears, and a
        // 120 ms fade is the difference between "something arrived" and "the
        // address bar just got shorter for no reason".
        if atRest {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.12
                zoom.animator().alphaValue = 0
            }, completionHandler: { [weak zoom] in zoom?.isHidden = true })
        } else {
            zoom.alphaValue = 0
            zoom.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                zoom.animator().alphaValue = 1
            }
        }
    }

    /// An unfocused pane keeps its chrome — the address *is* the pane's identity
    /// on a strip of ten lanes, and hiding it would make the strip unreadable —
    /// but it does not keep its contrast. The buttons of nine panes you are not
    /// using are nine rows of noise.
    var isPaneFocused: Bool = false {
        didSet {
            guard isPaneFocused != oldValue else { return }
            for button in [back, forward, reload, star, key, find, zoom] { button.isDimmed = !isPaneFocused }
            renderAddress()
            needsDisplay = true
        }
    }

    var isEditingAddress: Bool { address.isEditingAddress }

    /// Editing stopped. Forwarded rather than exposed, so nothing outside this
    /// file has to know the field exists.
    var onAddressEditingEnded: (() -> Void)? {
        get { address.onEndEditing }
        set { address.onEndEditing = newValue }
    }

    /// The typing changed. `(text, deleting)` — see `AddressField.onQueryChanged`.
    var onAddressQueryChanged: ((String, Bool) -> Void)? {
        get { address.onQueryChanged }
        set { address.onQueryChanged = newValue }
    }

    /// ↑, ↓ and Escape, offered to the completion list first.
    var onAddressCompletionKey: ((AddressField.CompletionKey) -> Bool)? {
        get { address.onCompletionKey }
        set { address.onCompletionKey = newValue }
    }

    /// Finish the typing with a suggestion, tail selected.
    func completeAddressInline(to text: String) { address.completeInline(to: text) }

    /// Put the highlighted row in the field, or nil to restore the typing.
    func showHighlightedAddress(_ text: String?) { address.showHighlighted(text) }

    /// `currentURL`, not what the row is drawing. The drawn form has `https://`
    /// and `www.` taken off it for reading, and an address you copied without
    /// its scheme is an address that does not paste back.
    func beginEditingAddress() { address.beginEditing(with: currentURL) }

    /// What the field is holding right now. Nothing in the chrome needs to read
    /// this back — a test does, because "⌘L opened the *drawn* address instead
    /// of the real one" is a bug that looks right on screen and only shows up
    /// on the clipboard, hours later, in a URL with no scheme on it.
    var editedText: String { address.stringValue }

    func endEditingAddress() { address.cancelEditing() }

    // MARK: - drawing

    private func renderAddress() {
        guard !address.isEditingAddress else { return }

        if let failure {
            // The amber ⚠ already means "this needs your eye" on this row, and
            // an error borrowing it is cheaper than a second glyph that appears
            // twice a week.
            security.stringValue = "⚠"
            security.textColor = Self.warning
            security.isHidden = false
            address.show(NSAttributedString(string: failure, attributes: [
                .font: Theme.mono(11, weight: .medium), .foregroundColor: Self.warning,
            ]), fade: true)
            address.toolTip = failure
            return
        }

        if let hovered {
            security.isHidden = true
            address.show(Self.hoverText(hovered), fade: true)
            address.toolTip = hovered
            return
        }

        switch BrowserAddress.security(of: currentURL) {
        case .insecure:
            security.stringValue = "⚠"
            security.textColor = Self.warning
            security.isHidden = false
        case .local:
            security.stringValue = "⌂"
            security.textColor = Theme.dimText
            security.isHidden = false
        case .secure, .none:
            security.isHidden = true
        }

        let display = BrowserAddress.display(currentURL)
        let attributed = NSMutableAttributedString()
        let dim: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(11), .foregroundColor: Theme.dimText,
        ]
        let strong: [NSAttributedString.Key: Any] = [
            .font: Theme.mono(11, weight: .medium),
            .foregroundColor: isPaneFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ]
        attributed.append(NSAttributedString(string: display.dimLead, attributes: dim))
        attributed.append(NSAttributedString(string: display.strong, attributes: strong))
        attributed.append(NSAttributedString(string: display.dimTail, attributes: dim))
        address.show(attributed, fade: hovered == nil && !currentURL.isEmpty)
        address.toolTip = currentURL.isEmpty ? nil : currentURL
    }

    /// `→ example.com/page`. The arrow is what makes it a destination rather
    /// than a claim about where you already are.
    private static func hoverText(_ url: String) -> NSAttributedString {
        let display = BrowserAddress.display(url)
        let out = NSMutableAttributedString(string: "→ ", attributes: [
            .font: Theme.mono(11, weight: .medium), .foregroundColor: Theme.dimText,
        ])
        out.append(NSAttributedString(string: display.strong, attributes: [
            .font: Theme.mono(11, weight: .medium), .foregroundColor: NSColor.labelColor,
        ]))
        out.append(NSAttributedString(string: display.dimTail, attributes: [
            .font: Theme.mono(11), .foregroundColor: Theme.dimText,
        ]))
        return out
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.laneBackground.setFill()
        bounds.fill()

        // A hairline above, so the row reads as chrome and not as the last line
        // of the page.
        Theme.laneBorder.setFill()
        NSRect(x: 0, y: bounds.height - Theme.borderWidth,
               width: bounds.width, height: Theme.borderWidth).fill()

        // Load progress, on the same hairline. Not the accent: the accent is
        // spent on focus, and ten lanes each drawing a bright
        // line every time a page loads is how BLOCKED stops meaning anything.
        // `Theme.working` is already this app's "bytes are moving".
        guard progress > 0.001, progress < 0.999 else { return }
        Theme.working.setFill()
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width * CGFloat(progress), height: 2).fill()
    }

    /// The one colour on this row that is neither the accent nor grey.
    ///
    /// Deliberately not `Theme.accent`: an `http://` page is a caution, and
    /// borrowing the colour that means *this pane needs you* to say it would
    /// make both weaker. Amber, and it appears on maybe one page a month.
    static let warning = NSColor(srgbRed: 0xE0 / 255, green: 0xA0 / 255, blue: 0x10 / 255, alpha: 1)
}

// MARK: - the address field

/// The address, and the only editable thing in a web pane's chrome.
///
/// One field in two states rather than a label that swaps for a text field.
/// Swapping views moves the text by a pixel or two and flickers the run
/// colouring — in a bar whose whole job is to be read at a glance, the click
/// that starts editing must not look like the page navigated.
@MainActor
final class AddressField: NSTextField, NSTextFieldDelegate {
    /// A committed line. Raw, exactly as typed.
    var onCommit: ((String) -> Void)?

    /// Editing stopped, however it stopped — Return, Escape, or the pointer
    /// landing somewhere else. The pane uses it to take the keyboard back, so
    /// Escape returns you to the page you were reading rather than to a window
    /// with the keyboard nowhere: `makeFirstResponder(nil)` below gives the
    /// field editor up and hands first responder to the window itself, and
    /// typing there reaches nothing at all.
    var onEndEditing: (() -> Void)?

    /// The line changed. `deleting` is true when this edit made it shorter,
    /// which is the one fact inline completion cannot work without — see
    /// `AddressCompletion.inlineCompletion`.
    var onQueryChanged: ((String, Bool) -> Void)?

    /// A key the completion list may want. Returning true means it took it, and
    /// the field does nothing further with it.
    var onCompletionKey: ((CompletionKey) -> Bool)?

    enum CompletionKey { case up, down, dismiss }

    private(set) var isEditingAddress = false
    private var display = NSAttributedString()

    /// What the *user* has typed, with no completion written into it.
    ///
    /// Held apart from `stringValue` because `stringValue` is routinely not it:
    /// an inline completion appends to it, and arrowing through the list
    /// replaces it wholesale. Escape has to give this back, and the next query
    /// has to be made of this rather than of whatever was suggested last — a
    /// field that searched its own suggestions would walk further from the
    /// typing on every keystroke.
    private(set) var typedText = ""

    /// True while this file is the one writing to the field, so the write does
    /// not come back through `controlTextDidChange` as though the user had
    /// typed it. Without it, a completion is a query is a completion.
    private var isWritingCompletion = false

    /// The address in full, scheme and all.
    ///
    /// Held apart from what is drawn, and that is the whole point. The drawn
    /// form has `https://` taken off it and is coloured in three runs; editing
    /// a string that is not the string is a trap — you would delete a character
    /// from the end of a URL that does not have the beginning you can see.
    var fullURL: String = ""

    init() {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        isEditable = false
        // False until editing starts, so the click that starts editing reaches
        // `mouseDown` instead of being eaten by text selection.
        isSelectable = false
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.truncatesLastVisibleLine = true
        wantsLayer = true
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func show(_ text: NSAttributedString, fade: Bool) {
        guard !isEditingAddress else { return }
        display = Self.clipped(text)
        if fade, let layer {
            // A crossfade on the layer, not a property animation: the two
            // strings have different colouring in different places and
            // animating that is not a thing AppKit can interpolate.
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.12
            layer.add(transition, forKey: "addressSwap")
        }
        attributedStringValue = display
    }

    /// The same string with tail truncation written into it.
    ///
    /// Not the same as the cell's `lineBreakMode`, which is already
    /// `.byTruncatingTail` and which an `NSTextField` ignores the moment you
    /// hand it an `attributedStringValue`: line breaking then comes from the
    /// string's own paragraph style, and a string with none is laid out as
    /// clipping. The symptom is a long URL that stops mid-character with no
    /// ellipsis, so `…/pull/135000/files` and `…/pull/135000/commits` are the
    /// same address to look at.
    /// Built per call rather than held in a `static let`: `NSParagraphStyle` is
    /// a mutable class and not `Sendable`, so a shared one is a Swift 6 error
    /// for a saving of nothing — this runs a handful of times per navigation.
    nonisolated static func clipped(_ text: NSAttributedString) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let out = NSMutableAttributedString(attributedString: text)
        out.addAttribute(.paragraphStyle, value: style,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    override func mouseDown(with event: NSEvent) {
        guard !isEditingAddress else { return super.mouseDown(with: event) }
        beginEditing(with: fullURL)
    }

    /// Editing shows the whole URL and selects it, which is what every browser
    /// does and what makes "click, type, Return" one gesture rather than three.
    func beginEditing(with url: String?) {
        // ⌘L pressed twice by reflex re-selects; it does not toggle back out to
        // the page. Every browser does this, and the reflex is real — the
        // second press is how you undo a stray keystroke in the field without
        // reaching for the mouse. What is *not* re-read is the URL: half an
        // address you typed is yours until you cancel it.
        guard !isEditingAddress else {
            if window?.firstResponder !== currentEditor() { window?.makeFirstResponder(self) }
            currentEditor()?.selectAll(nil)
            return
        }
        isEditingAddress = true
        typedText = url ?? stringValue
        isEditable = true
        isSelectable = true
        drawsBackground = true
        backgroundColor = Theme.stripBackground
        textColor = .labelColor
        font = Theme.mono(11)
        if let url { stringValue = url }
        // A square 1 pt accent outline. This is the one place the accent is
        // right: it means "the keyboard is here", which is what focus means
        // everywhere else in the app.
        layerBorderColor = Theme.accent
        layer?.borderWidth = 1
        layer?.cornerRadius = 0
        window?.makeFirstResponder(self)
        currentEditor()?.selectAll(nil)
    }

    func cancelEditing() {
        guard isEditingAddress else { return }
        finishEditing()
    }

    /// Finish the typing with the top row's address, leaving everything past
    /// what was typed **selected**.
    ///
    /// The selection is the whole safety of inline completion: the suggested
    /// tail is already gone the moment the next character arrives, so the field
    /// never contains a character the user did not either type or accept by
    /// pressing Return on it.
    func completeInline(to text: String) {
        guard isEditingAddress, text.hasPrefix(typedText), text != stringValue else { return }
        write(text)
        // In UTF-16, because that is what a field editor's ranges are counted
        // in. A URL with an emoji in its path — they exist — would otherwise
        // select from the wrong place and the completion would read as corrupt.
        let typedLength = (typedText as NSString).length
        let fullLength = (text as NSString).length
        currentEditor()?.selectedRange =
            NSRange(location: typedLength, length: fullLength - typedLength)
    }

    /// Put a highlighted row's address in the field, or `nil` to give back what
    /// was typed.
    ///
    /// Return needs no knowledge of the list because of this: whatever is
    /// highlighted is *in the field*, so committing the field and committing the
    /// selection are the same act.
    func showHighlighted(_ text: String?) {
        guard isEditingAddress else { return }
        write(text ?? typedText)
        // The caret at the end, nothing selected. A selection here would be a
        // lie about editability — this text was chosen, not suggested.
        let length = ((text ?? typedText) as NSString).length
        currentEditor()?.selectedRange = NSRange(location: length, length: 0)
    }

    private func write(_ text: String) {
        isWritingCompletion = true
        stringValue = text
        isWritingCompletion = false
    }

    private func finishEditing() {
        // Re-entrant, and measured: giving the field editor up posts
        // `textDidEndEditing`, which lands back here, so one Escape ran this
        // three times. It was invisible while the body only reset properties
        // that were already reset — it stopped being invisible the moment
        // there was a callback in it, and a pane told three times to take the
        // keyboard back is three `makeFirstResponder` calls racing a teardown.
        guard isEditingAddress else { return }
        isEditingAddress = false
        typedText = ""
        isEditable = false
        isSelectable = false
        drawsBackground = false
        layer?.borderWidth = 0
        attributedStringValue = display
        if window?.firstResponder === currentEditor() { window?.makeFirstResponder(nil) }
        // Last, and after `isEditingAddress` is already false: the pane's
        // focus guard reads that flag, so calling out any earlier would be
        // asking it to take a keyboard it believes is still in this field.
        onEndEditing?()
    }

    /// Every edit, and the one thing about it that matters downstream: whether
    /// it was a deletion.
    ///
    /// Length, not the selector, decides. A deletion arrives as ⌫, as ⌦, as a
    /// Cut, as typing over a selection with nothing, and as the field editor
    /// replacing a range — five paths into one notification, and the only thing
    /// they have in common is the direction the string moved.
    func controlTextDidChange(_ notification: Notification) {
        guard !isWritingCompletion else { return }
        let deleting = stringValue.count < typedText.count
        typedText = stringValue
        onQueryChanged?(stringValue, deleting)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            return onCompletionKey?(.up) ?? false
        case #selector(NSResponder.moveDown(_:)):
            return onCompletionKey?(.down) ?? false
        case #selector(NSResponder.insertNewline(_:)):
            let typed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            finishEditing()
            guard !typed.isEmpty else { return true }
            // One turn later, and it is not a nicety. This runs inside the field
            // editor's own key handling, with AppKit part-way through tearing
            // the editor down; starting a navigation and moving first responder
            // from in there left the page loaded, titled, addressed — and never
            // painted, until something else forced a repaint. (The same hazard
            // `webViewDidClose` already documents: do not do work on WebKit's
            // stack.)
            Task { @MainActor [onCommit] in onCommit?(typed) }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Escape peels one layer at a time, which is what Escape means
            // everywhere on this system. The list first — and with it, the
            // typing comes back, because dismissing a suggestion you did not
            // want must not leave the suggestion in the field. Only a second
            // Escape gives the keyboard back to the page.
            if onCompletionKey?(.dismiss) == true {
                showHighlighted(nil)
                return true
            }
            finishEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        // Clicking away is a cancel, not a commit. A half-typed address that
        // navigated because the pointer moved would be the worst bug on this row.
        finishEditing()
    }
}

// MARK: - buttons

/// A square, borderless glyph button.
///
/// Not `NSButton`: a bordered button is a rounded capsule and a borderless one
/// has no hover state at all, and the hit target here has to stay 22 pt wide in
/// a bar that is 26 pt tall. Square, 1 pt of nothing, and a fill on hover.
@MainActor
final class ChromeButton: NSView {
    var onClick: (() -> Void)?
    /// Built lazily on press-and-hold or right-click. Returning nil means the
    /// button has no menu right now, and the press stays a plain click.
    var onMenu: (() -> NSMenu?)?

    var glyph: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Set instead of `glyph` for every control that is an affordance rather
    /// than a readout. The zoom percentage is the one that stays text.
    var icon: LucideIcon? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    /// Overrides the ink when the button is enabled. One caller: the star,
    /// which is the only control on the row whose colour is a *state* rather
    /// than an affordance.
    var tint: NSColor? { didSet { needsDisplay = true } }
    var isDimmed = true { didSet { needsDisplay = true } }

    private var isHovered = false { didSet { needsDisplay = true } }
    private var holdTimer: Timer?
    private var menuShown = false

    convenience init(icon: LucideIcon) {
        self.init(glyph: "")
        self.icon = icon
    }

    init(glyph: String) {
        self.glyph = glyph
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        // A button is exactly its glyph wide. Without this it competes with the
        // address field for the row's slack and the whole row spreads out.
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// A zoom readout is data and gets the house mono at reading size. A glyph
    /// is not: `⟳` and `⌕` are outside JetBrains Mono, so they come back from
    /// the system fallback at a face that draws visibly smaller than the arrows
    /// beside them — measured at 13 pt they read as half the size. Two points
    /// larger puts the row back in balance.
    private var font: NSFont {
        glyph.count > 2 ? Theme.mono(10, weight: .medium) : Theme.mono(15, weight: .medium)
    }

    override var intrinsicContentSize: NSSize {
        // An icon is drawn at a fixed size, so the button is simply square.
        if icon != nil { return NSSize(width: 22, height: 22) }
        let width = (glyph as NSString).size(withAttributes: [.font: font]).width
        return NSSize(width: max(22, width + 10), height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = isEnabled }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        menuShown = false
        // Press-and-hold for the menu, the way a browser's back button has
        // worked for twenty years. A timer rather than a tracking loop: a
        // tracking loop blocks the run loop, and this view lives inside a
        // WKWebView's pane where that would stall the page's rendering too.
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.showMenu() }
        }
    }

    override func mouseUp(with event: NSEvent) {
        holdTimer?.invalidate()
        holdTimer = nil
        guard isEnabled, !menuShown else { return }
        onClick?()
    }

    override func rightMouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    private func showMenu() {
        holdTimer?.invalidate()
        holdTimer = nil
        guard let menu = onMenu?(), menu.numberOfItems > 0 else { return }
        menuShown = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 2), in: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Theme.laneBorder.withAlphaComponent(0.6).setFill()
            bounds.fill()
        }
        // Three levels, and they are a map of what is possible: bright for a
        // thing this pane can do now, dim for a pane you are not in, dimmer
        // still for an action with nothing behind it (no back history, no
        // forward). Hiding the last would make the row's width jump around as
        // you browse, which is worse than a grey arrow.
        let colour: NSColor = !isEnabled
            ? Theme.dimText.withAlphaComponent(0.3)
            : (tint ?? (isDimmed ? Theme.dimText : .labelColor))
        if let icon {
            let points: CGFloat = 15
            if let image = IconImage.make(icon, points: points, colour: colour) {
                image.draw(in: NSRect(
                    x: (bounds.width - points) / 2, y: (bounds.height - points) / 2,
                    width: points, height: points))
            }
            return
        }
        let text = NSAttributedString(string: glyph, attributes: [
            .font: font, .foregroundColor: colour,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }
}
