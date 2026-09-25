import AppKit

/// What a ⌘C in a web pane leaves in paste history (ADR-0041).
///
/// ADR-0031's line is the reason this is safe and is not moved here: **the
/// pane writes, the app never polls.** Nothing in this file runs while the app
/// is idle. It runs when the app itself has just performed WebKit's own copy
/// for a page that has the keyboard, it looks at the pasteboard for as long as
/// that copy takes to land and not a moment longer, and it stops at the first
/// change. A copy made in Safari, in Mail, or by a page's own script is never
/// seen, because nothing here ever runs for one.
///
/// Reading the pasteboard rather than asking the page is what makes a copied
/// *picture* recordable at all, and it keeps one decision instead of two: the
/// pane keeps what ⌘V would have taken (`TerminalPaste.clipboard`), so a row
/// replayed into a prompt with ⇧⌘H ↩ is the text a paste would have sent.
enum WebClipboard {
    /// What the copy put on the pasteboard, as paste history keeps it.
    enum Copied: Equatable {
        /// The text that was copied.
        case text(String)
        /// A picture and nothing else — a Copy Image with no address beside
        /// it. It becomes a file and the row is that file's path
        /// (`PastedImages`, ADR-0027).
        case picture(Data)
    }

    /// What is on `pasteboard` now that the pane's own copy has landed, or nil
    /// when there is nothing to keep.
    ///
    /// The same reading a paste makes, so the same rules: a password
    /// manager's mark is honoured (`doNotRecord`), text wins over a picture,
    /// and a picture is only a picture when `paste_images_as_files` is on —
    /// off, a copied picture would become no file and so has no path to keep.
    static func copied(on pasteboard: NSPasteboard, imagesAsFiles: Bool) -> Copied? {
        let read = TerminalPaste.clipboard(pasteboard, images: imagesAsFiles)
        if read.doNotRecord { return nil }
        if let text = read.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        if let png = read.image { return .picture(png) }
        return nil
    }

    /// How long a copy is given to reach the pasteboard. WebKit's copy crosses
    /// to the web process and back, so it is not on the pasteboard when
    /// `copy:` returns; a fifth of a second is far more than the round trip
    /// costs and short enough that nothing is looking at the pasteboard by the
    /// time a person could copy something else.
    static let settle: TimeInterval = 0.2
    /// How often it is looked at inside that window.
    static let step: TimeInterval = 0.02

    /// Call `landed` once `pasteboard`'s contents change, or never.
    ///
    /// `after` is the `changeCount` read *before* the copy was performed.
    /// Nothing changing means the copy copied nothing — an empty selection —
    /// and then nothing is recorded, which is the right answer and the common
    /// one. This is the only place in the app that looks at a pasteboard it
    /// did not just write, and it exists for a fraction of a second.
    ///
    /// The deadline is **wall clock, checked before the pasteboard is read**,
    /// and not a count of turns: a main thread that stalls for a second is a
    /// main thread that must come back to find this over, rather than one that
    /// reads a pasteboard somebody else has written since. So the promise is
    /// exact — nothing is kept from a pasteboard read more than `within` after
    /// this pane performed its copy.
    @MainActor
    static func whenCopyLands(
        on pasteboard: NSPasteboard, after count: Int,
        within: TimeInterval = settle, step: TimeInterval = step,
        landed: @escaping (NSPasteboard) -> Void
    ) {
        let deadline = CFAbsoluteTimeGetCurrent() + within
        func look() {
            guard CFAbsoluteTimeGetCurrent() <= deadline else { return }
            guard pasteboard.changeCount == count else {
                landed(pasteboard)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + step) { look() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + step) { look() }
    }
}

extension WebPaneController {
    /// ⌘C, or Edit › Copy, with this pane's page holding the keyboard: the
    /// copy WebKit would have made, and what it copied kept in paste history
    /// under `web` (ADR-0041).
    ///
    /// False means *not this pane's copy*: the keyboard is in the address
    /// field, the find field or another pane, and the key goes on to whatever
    /// does have it, unrecorded. So a lane's own chrome keeps its ⌘C, and a
    /// web view that this app did not build — an OAuth popup's — is never
    /// recorded at all: a sign-in window is the one page whose contents this
    /// app has the least business keeping.
    @discardableResult
    func copyFromPage() -> Bool {
        // The page has the keyboard — the web view itself or something inside
        // it, *in the key window*. The window clause is what keeps a ⌘C typed
        // into a picker over the strip from being taken as the page's: the
        // strip window's first responder is still the web view then, it is
        // only no longer key (`keyboardIsIn`, ADR-0045).
        guard keyboardIsIn(webView) else { return false }
        let pasteboard = clipPasteboard
        let before = pasteboard.changeCount
        // WebKit's own `copy:`, down the responder chain to the page, exactly
        // as the Edit menu would have sent it. False when WebKit answers no
        // such action, which is a WebKit that has stopped implementing the
        // editing commands: the key then goes on to the web view and copies
        // as it always did, unrecorded.
        guard NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) else { return false }
        let settings = self.settings
        guard settings.pasteHistory, settings.pasteHistoryKeep > 0 else { return true }
        WebClipboard.whenCopyLands(on: pasteboard, after: before) { [weak self] board in
            self?.remember(copiedOn: board)
        }
        return true
    }

    /// Keep what the pane's copy put on `pasteboard`. Which pane it was is all
    /// that is said: the ledger looks the lane up and refuses a private one,
    /// and redacts what is shaped like a secret, exactly as it does for a
    /// terminal (ADR-0031).
    func remember(copiedOn pasteboard: NSPasteboard) {
        let settings = self.settings
        switch WebClipboard.copied(on: pasteboard, imagesAsFiles: settings.pasteImagesAsFiles) {
        case .text(let text):
            store.recordClip(paneId: paneId, kind: .copy, source: .web, text: text, config: settings)
        case .picture(let png):
            remember(copiedPicture: png, settings)
        case nil:
            break
        }
    }

    /// A copied picture becomes a file and the row is its path, quoted as a
    /// prompt takes it — the same store and the same sweep as a pasted one
    /// (ADR-0027), under `copy-…`. The file is on this Mac: a web pane has no
    /// session and so no server to upload it to, and the path reaches a
    /// remote prompt as text like any other row.
    private func remember(copiedPicture png: Data, _ settings: Config) {
        let limits = TerminalPaste.ImageSettings(settings)
        if let refusal = TerminalPaste.imageRefusal(bytes: png.count, limits) {
            Log.debug("pane \(paneId): copied picture not kept — \(refusal)")
            return
        }
        do {
            let url = try pastedImages.save(png, prefix: PastedImages.copiedPrefix)
            guard let word = TerminalPaste.shellWord(for: url.path) else {
                Log.warn("pane \(paneId): copied picture saved at a path no prompt can take: \(url.path)")
                return
            }
            store.recordClip(paneId: paneId, kind: .copy, source: .web, text: word, config: settings)
            Log.debug("pane \(paneId): copied picture kept as \(url.lastPathComponent)")
        } catch {
            Log.warn("pane \(paneId): copied picture not saved: \(error.localizedDescription)")
        }
    }
}
