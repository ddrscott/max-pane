import AppKit
import LanedCore
import Testing
import WebKit
@testable import MaxPaneKit

/// Round 3: the three things round 2 carried out of its own "Smaller" list.
///
/// None of these could be verified by a live gesture. The owner's own instance
/// held the front for the whole of this work, and four workers before this one
/// correctly aborted synthetic input rather than risk a ⌘-chord landing in his
/// strip — so every assertion below is on the logic that decides, not on a
/// keystroke or a right-click. Where that leaves a gap it is named in the test.

// MARK: - the address bar's autocomplete

@Suite("address-bar autocomplete")
@MainActor
struct AddressCompletionTests {
    private func entry(_ url: String, _ title: String? = nil) -> HistoryEntry {
        HistoryEntry(
            url: url, title: title, firstVisitAt: 0, lastVisitAt: 0, visitCount: 1,
            matchedField: .url, score: 0)
    }

    /// The report this exists for, in one line: *"`en.wik` offers nothing."*
    @Test("what the report asked for: en.wik finds the page")
    func theReportedCase() {
        let rows = AddressCompletion.rows(
            query: "en.wik",
            from: [entry("https://en.wikipedia.org/wiki/Rust", "Rust — Wikipedia")])
        #expect(rows.count == 1)
        #expect(rows.first?.url == "https://en.wikipedia.org/wiki/Rust")
        #expect(AddressCompletion.inlineCompletion(
            for: "en.wik", suggestion: rows.first, deleting: false)
            == "en.wikipedia.org/wiki/Rust")
    }

    /// An empty field offers nothing at all. The alternative — the whole of
    /// recent history dumped over the page the moment ⌘L is pressed — is ⌘O,
    /// which says so in its own header.
    @Test("nothing typed, nothing offered")
    func emptyQuery() {
        #expect(AddressCompletion.rows(query: "", from: [entry("https://a.com/")]).isEmpty)
        #expect(AddressCompletion.rows(query: "   ", from: [entry("https://a.com/")]).isEmpty)
    }

    /// A row that offers exactly what is already in the field has no effect
    /// except to sit between the typing and Return.
    @Test("the address you have finished typing is not a suggestion")
    func dropsTheExactMatch() {
        let rows = AddressCompletion.rows(
            query: "example.com/a",
            from: [entry("https://example.com/a"), entry("https://example.com/ab")])
        #expect(rows.map(\.url) == ["https://example.com/ab"])
    }

    /// `http://x/a` and `https://x/a` are two rows in the ledger — a scheme
    /// change is a real visit — and one place to the person reading the list.
    @Test("two schemes for one page are one row")
    func dedupesOnTheHandle() {
        let rows = AddressCompletion.rows(
            query: "exa",
            from: [entry("https://example.com/a"), entry("http://example.com/a"),
                   entry("https://www.example.com/a")])
        #expect(rows.count == 1)
    }

    /// The core ranks; this does not re-rank. `history.rs` gives the reason —
    /// two matchers disagreeing about the same typing with no way for the user
    /// to know which they are under.
    @Test("the ledger's order survives")
    func keepsTheCoresOrder() {
        let rows = AddressCompletion.rows(
            query: "s",
            from: [entry("https://second.com/"), entry("https://first.com/")])
        #expect(rows.map(\.handle) == ["second.com/", "first.com/"])
    }

    @Test("at most six rows")
    func honoursTheRowLimit() {
        let history = (0..<40).map { entry("https://site\($0).example.com/") }
        #expect(AddressCompletion.rows(query: "site", from: history).count
            == AddressCompletion.maxRows)
    }

    /// **The bug that makes naive inline completion unusable.** Without the
    /// deletion guard, ⌫ removes a character and the field immediately puts it
    /// back, and the only way out of the address is select-all.
    @Test("backspace is possible")
    func neverCompletesWhileDeleting() {
        let suggestion = AddressSuggestion(
            url: "https://example.com/a", handle: "example.com/a", title: nil)
        #expect(AddressCompletion.inlineCompletion(
            for: "exa", suggestion: suggestion, deleting: true) == nil)
        #expect(AddressCompletion.inlineCompletion(
            for: "exa", suggestion: suggestion, deleting: false) == "example.com/a")
    }

    /// A completion that is not a prefix would move characters the user is
    /// looking at. The row is still offered — it is only the *field* that is
    /// left alone.
    @Test("only a prefix is written into the field")
    func onlyPrefixesCompleteInline() {
        let substring = AddressSuggestion(
            url: "https://docs.example.com/", handle: "docs.example.com/", title: nil)
        #expect(AddressCompletion.inlineCompletion(
            for: "example", suggestion: substring, deleting: false) == nil)
    }

    /// A trailing space is someone typing a question, not an address, and the
    /// field takes both — `OmniText.looksLikeURL` decides at Return.
    @Test("a search phrase is not completed to a URL")
    func leavesPhrasesAlone() {
        let suggestion = AddressSuggestion(
            url: "https://rust.example.com/", handle: "rust.example.com/", title: nil)
        #expect(AddressCompletion.inlineCompletion(
            for: "rust ", suggestion: suggestion, deleting: false) == nil)
    }

    /// The typed characters keep the case they were typed in. A field that
    /// rewrote `GitHub` to `github` under the cursor has moved text the user is
    /// still editing.
    @Test("the typing is not re-cased by the completion")
    func preservesTypedCase() {
        let suggestion = AddressSuggestion(
            url: "https://github.com/x", handle: "github.com/x", title: nil)
        #expect(AddressCompletion.inlineCompletion(
            for: "GitHub", suggestion: suggestion, deleting: false) == "GitHub.com/x")
    }

    /// Off either end is "nothing chosen", not a wrap: walking off the top has
    /// to give the typing back, and a wrap would strand it behind six rows.
    @Test("arrowing off the top returns to what was typed")
    func selectionDoesNotWrap() {
        let list = AddressCompletionList()
        var highlighted: [String?] = []
        list.onHighlight = { highlighted.append($0?.handle) }
        list.show([
            AddressSuggestion(url: "https://a.com/", handle: "a.com/", title: nil),
            AddressSuggestion(url: "https://b.com/", handle: "b.com/", title: nil),
        ], query: "a")

        list.move(1)
        #expect(list.highlighted == 0)
        list.move(1)
        #expect(list.highlighted == 1)
        list.move(1)
        #expect(list.highlighted == nil)
        #expect(highlighted == ["a.com/", "b.com/", nil])
    }

    @Test("↑ from nothing chosen lands on the last row")
    func upFromNothing() {
        let list = AddressCompletionList()
        list.show([
            AddressSuggestion(url: "https://a.com/", handle: "a.com/", title: nil),
            AddressSuggestion(url: "https://b.com/", handle: "b.com/", title: nil),
        ], query: "a")
        list.move(-1)
        #expect(list.highlighted == 1)
    }

    /// The list opens *upward* — the chrome is at the foot of the pane — so row
    /// 0 is the one nearest the field, which is the bottom of this view. Getting
    /// this backwards would mean clicking the best match and getting the worst.
    @Test("row 0 is the row nearest the field")
    func rowsAreOrderedFromTheField() {
        let list = AddressCompletionList()
        list.show([
            AddressSuggestion(url: "https://a.com/", handle: "a.com/", title: nil),
            AddressSuggestion(url: "https://b.com/", handle: "b.com/", title: nil),
        ], query: "a")
        list.frame = NSRect(x: 0, y: 0, width: 420, height: list.height)
        #expect(list.rowIndex(at: NSPoint(x: 10, y: 5)) == 0)
        #expect(list.rowIndex(at: NSPoint(x: 10, y: AddressCompletionList.rowHeight + 5)) == 1)
        #expect(list.rowIndex(at: NSPoint(x: 10, y: 500)) == nil)
    }

    @Test("an empty list is not shown, and has no height")
    func emptyListStaysDown() {
        let list = AddressCompletionList()
        list.show([], query: "zzz")
        #expect(!list.isShowing)
        #expect(list.height == 0)
    }

    /// Escape has to hand back what was typed, not what was suggested. The
    /// field holds the typing separately for exactly this.
    @Test("the field remembers the typing behind a completion")
    func typedTextSurvivesACompletion() {
        let field = AddressField()
        let window = NSWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 600, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        field.frame = NSRect(x: 0, y: 0, width: 600, height: 26)
        window.contentView?.addSubview(field)
        field.beginEditing(with: "")

        field.stringValue = "en.wik"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(field.typedText == "en.wik")

        field.completeInline(to: "en.wikipedia.org/wiki/Rust")
        #expect(field.stringValue == "en.wikipedia.org/wiki/Rust")
        // Still `en.wik`: the completion must not become the next query, or the
        // field searches its own suggestions and walks away from the typing.
        #expect(field.typedText == "en.wik")

        field.showHighlighted(nil)
        #expect(field.stringValue == "en.wik")
    }

    /// Only the tail is selected, so the next character typed replaces the
    /// suggestion rather than appending to it.
    @Test("the suggested tail is selected, the typing is not")
    func completionSelectsOnlyTheTail() {
        let field = AddressField()
        let window = NSWindow(
            contentRect: NSRect(x: -9000, y: -9000, width: 600, height: 60),
            styleMask: [.borderless], backing: .buffered, defer: false)
        field.frame = NSRect(x: 0, y: 0, width: 600, height: 26)
        window.contentView?.addSubview(field)
        field.beginEditing(with: "")
        field.stringValue = "en.wik"
        field.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        field.completeInline(to: "en.wikipedia.org")

        #expect(field.currentEditor()?.selectedRange
            == NSRange(location: 6, length: "ipedia.org".utf16.count))
    }
}

// MARK: - the find bar's match count

@Suite("an honest find match count")
struct FindCountTests {
    /// **Rule 1.** WebKit is the authority on whether there is a match. A count
    /// of zero next to a highlight on screen would be the readout contradicting
    /// the page, which is worse than the silence it replaced.
    @Test("a count that disagrees with WebKit says nothing")
    func neverContradictsTheHighlight() {
        #expect(FindCount.label(
            matchFound: true, tally: .init(total: 0, index: 0, partial: false)) == "")
    }

    @Test("no match at all is the find bar's own business")
    func silentWhenNothingFound() {
        #expect(FindCount.label(
            matchFound: false, tally: .init(total: 9, index: 1, partial: false)) == "")
    }

    @Test("the shape every find bar has trained")
    func readsAsNOfM() {
        #expect(FindCount.label(
            matchFound: true, tally: .init(total: 17, index: 3, partial: false)) == "3/17")
    }

    /// **Rule 2.** The index comes from WebKit's own selection. When the
    /// selection cannot be placed — it is in a frame, or the page moved it —
    /// the total is still true and is shown alone, rather than inventing an `n`.
    @Test("an unplaceable selection costs the index, not the total")
    func totalAloneWhenTheSelectionIsLost() {
        #expect(FindCount.label(
            matchFound: true, tally: .init(total: 17, index: 0, partial: false)) == "17")
    }

    /// **Rule 3.** `find` searches subframes and script reaches the main frame
    /// only, with no public way to enumerate the rest. One character admits the
    /// number is a floor.
    @Test("a count that cannot see every frame says so")
    func framesWearAPlus() {
        #expect(FindCount.label(
            matchFound: true, tally: .init(total: 4, index: 2, partial: true)) == "2/4+")
        #expect(FindCount.label(
            matchFound: true, tally: .init(total: 4, index: 0, partial: true)) == "4+")
    }

    @Test("a reply that is not the shape the script produces reads as no count")
    func tolerantOfRubbish() {
        #expect(FindCount.tally(from: nil) == .none)
        #expect(FindCount.tally(from: "17") == .none)
        #expect(FindCount.tally(from: ["index": 2]) == .none)
        #expect(FindCount.tally(from: ["total": 17, "index": 3, "partial": true])
            == .init(total: 17, index: 3, partial: true))
        // A total without an index is the documented degradation, not a fault.
        #expect(FindCount.tally(from: ["total": 17])
            == .init(total: 17, index: 0, partial: false))
    }

    /// A find query is arbitrary user text, and this is the one place in the
    /// find path where it crosses into another language. A quote or a backslash
    /// that escaped unquoted would be a syntax error at best.
    @Test("the query cannot break out of the script")
    func quotesTheQuery() {
        #expect(FindCount.jsString("plain") == "\"plain\"")
        #expect(FindCount.jsString("a\"b") == "\"a\\\"b\"")
        #expect(FindCount.jsString("a\\b") == "\"a\\\\b\"")
        #expect(FindCount.jsString("a\nb").contains("\\n"))
        let injected = FindCount.javaScript(for: "\"); alert(1); (\"")
        #expect(!injected.contains("alert(1);\n"))
        #expect(injected.hasPrefix("(function"))
    }
}

// MARK: - the context menu

@Suite("the right-click menu's nouns")
@MainActor
struct WebContextMenuTests {
    private func item(_ identifier: String?, _ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier) }
        return item
    }

    /// The report: *"'Open Link in New Window' is the wrong noun for what
    /// happens."* This app has no windows to open a link in — the item makes a
    /// lane, to the right, and now says so.
    @Test("window becomes lane")
    func renamesTheLinkItem() {
        let menu = NSMenu()
        menu.addItem(item(WebContextMenu.Identifier.openLinkInNewWindow,
                          "Open Link in New Window"))
        #expect(WebContextMenu.rename(in: menu) == 1)
        #expect(menu.items[0].title == "Open Link in a Lane to the Right")
    }

    /// "to the Right" is the half the reader cannot otherwise find out: on a
    /// fifteen-lane strip, "a new lane" without a direction is a thing you then
    /// go looking for.
    @Test("the direction is in every renamed item")
    func everyRenameSaysWhere() {
        for title in WebContextMenu.titles.values {
            #expect(title.contains("Lane to the Right"))
            #expect(!title.contains("Window"))
        }
    }

    /// Actions, order, separators and the keyboard loop stay WebKit's. Renaming
    /// is the only change here that cannot regress the download path or a menu
    /// item this app has never seen.
    @Test("everything else is left exactly as WebKit built it")
    func leavesTheRestAlone() {
        let menu = NSMenu()
        let download = item("WKMenuItemIdentifierDownloadLinkedFile", "Download Linked File")
        let copy = item("WKMenuItemIdentifierCopyLink", "Copy Link")
        let future = item("WKMenuItemIdentifierSomethingNew", "Something New")
        for entry in [download, copy, future] { menu.addItem(entry) }

        #expect(WebContextMenu.rename(in: menu) == 0)
        #expect(menu.items.map(\.title)
            == ["Download Linked File", "Copy Link", "Something New"])
    }

    /// **The designed failure.** The identifier is not in the macOS SDK —
    /// `WKMenuItemIdentifier` is iOS-only, and these strings were read out of
    /// this machine's WebKit. If a future WebKit stops setting them, the result
    /// is the stock menu, which is what shipped before this change.
    @Test("an item with no identifier is left stock")
    func degradesToTheStockMenu() {
        let menu = NSMenu()
        menu.addItem(item(nil, "Open Link in New Window"))
        #expect(WebContextMenu.rename(in: menu) == 0)
        #expect(menu.items[0].title == "Open Link in New Window")
    }

    @Test("a nested item is reached too")
    func walksSubmenus() {
        let menu = NSMenu()
        let parent = item(nil, "Link")
        let submenu = NSMenu()
        submenu.addItem(item(WebContextMenu.Identifier.openImageInNewWindow,
                             "Open Image in New Window"))
        parent.submenu = submenu
        menu.addItem(parent)
        #expect(WebContextMenu.rename(in: menu) == 1)
        #expect(submenu.items[0].title == "Open Image in a Lane to the Right")
    }

    /// Renaming twice is renaming once. `willOpenMenu` can be called again for
    /// the same menu object, and a second pass must not report work it did not
    /// do.
    @Test("renaming is idempotent")
    func idempotent() {
        let menu = NSMenu()
        menu.addItem(item(WebContextMenu.Identifier.openLinkInNewWindow,
                          "Open Link in New Window"))
        #expect(WebContextMenu.rename(in: menu) == 1)
        #expect(WebContextMenu.rename(in: menu) == 0)
    }

    /// The premise that blocked this in round 2 — *"the one web view this app
    /// does not construct is the adopted popup"* — is false, and this is the
    /// assertion that keeps it false. Every web view in this target is built by
    /// us — the pane's own, and the popup `WebPopupDialog` builds from WebKit's
    /// configuration, first and in place of a replaced one — so the menu is
    /// right on an OAuth popup too.
    @Test("the popup's web view is ours, so the menu is right there too")
    func bothWebViewsAreOurs() {
        func source(_ path: String) -> String {
            try! String(
                contentsOfFile: #filePath.replacingOccurrences(
                    of: "Tests/MaxPaneKitTests/ChromeRound3Tests.swift", with: "Sources/MaxPaneKit/" + path),
                encoding: .utf8)
        }
        let pane = source("Web/WebPaneController.swift")
        let popup = source("Views/WebPopupDialog.swift")
        // A plain `WKWebView(frame:` in either is a view whose context menu
        // would still say "window".
        for text in [pane, popup] { #expect(!text.contains("WKWebView(frame:")) }
        #expect(pane.components(separatedBy: "ChromeWebView(frame:").count - 1 == 1)
        #expect(popup.components(separatedBy: "ChromeWebView(frame:").count - 1 == 2)
    }
}
