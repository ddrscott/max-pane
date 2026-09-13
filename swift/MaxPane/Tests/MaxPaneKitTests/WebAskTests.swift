import Testing
import WebKit
@testable import MaxPaneKit

/// That the delegate methods are actually wired to WebKit.
///
/// **This suite exists because of a bug that cost an hour.** `WKUIDelegate`'s
/// completion handlers are declared `@escaping @MainActor @Sendable`, and a
/// method written with a plain `@escaping () -> Void` does not *witness* the
/// requirement — so Swift never infers `@objc` for it, WebKit never finds the
/// selector, and the whole feature silently does nothing. It compiles with one
/// easily-missed warning ("nearly matches optional requirement"), the app runs,
/// and `confirm()` keeps returning false exactly as it did before the code was
/// written. Measured: a page reported `confirm branch: cancel` with no dialog and
/// no log line.
///
/// `instancesRespond(to:)` is the only check that can tell the difference,
/// because it asks the Objective-C runtime the same question WebKit asks.
@Suite("the delegate methods WebKit actually calls")
struct WebDelegateSelectorTests {
    @Test("every dialog, upload, capture and auth selector is exposed to WebKit",
          arguments: [
            "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
            "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
            "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:navigationAction:didBecomeDownload:",
            "webView:navigationResponse:didBecomeDownload:",
          ])
    func paneRespondsToSelector(_ name: String) {
        #expect(WebPaneController.instancesRespond(to: NSSelectorFromString(name)))
    }

    /// The same trap, one class along: `WKDownloadDelegate`'s destination
    /// callback has the same `@MainActor @Sendable` shape, and a download whose
    /// destination is never decided fails with no file and no error.
    @Test("the download delegate's selectors are exposed too",
          arguments: [
            "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:",
            "downloadDidFinish:",
            "download:didFailWithError:resumeData:",
            "download:didReceiveAuthenticationChallenge:completionHandler:",
          ])
    func downloadJobRespondsToSelector(_ name: String) {
        #expect(DownloadJob.instancesRespond(to: NSSelectorFromString(name)))
    }
}

/// The completion-handler contract, in isolation from WebKit.
///
/// Every `WKUIDelegate` callback in the dialogs piece hands over a handler with
/// two rules and no enforcement: call it twice and WebKit crashes, never call it
/// and that web view hangs forever with no error. Neither failure can be
/// reproduced in a test that involves a real `WKWebView` — the first takes the
/// process down and the second looks like nothing happening — so the rule is
/// held by one small type and tested here.
@MainActor
@Suite("one-shot replies")
struct OneShotReplyTests {
    @Test("the second answer does nothing")
    func fireIsIdempotent() {
        var answers: [Bool] = []
        let reply = OneShotReply<Bool>(fallback: false) { answers.append($0) }
        #expect(reply.fire(true))
        #expect(reply.fire(false) == false)
        #expect(reply.fire(true) == false)
        #expect(answers == [true])
    }

    /// The pane-closed case. `abandon` is what `tearDown` calls, and if it did
    /// nothing the web view would never run JavaScript again.
    @Test("an abandoned ask answers with the fallback")
    func abandonAnswers() {
        var answers: [String?] = []
        let reply = OneShotReply<String?>(fallback: nil) { answers.append($0) }
        #expect(reply.isPending)
        reply.abandon()
        #expect(!reply.isPending)
        #expect(answers.count == 1)
        #expect(answers[0] == nil)
    }

    /// The race this exists for: the user clicks OK at the same moment the pane
    /// is torn down. Whichever lands first wins and the other is a no-op.
    @Test("abandoning after an answer does not answer twice")
    func abandonAfterAnswerIsSilent() {
        var count = 0
        let reply = OneShotReply<Int>(fallback: -1) { _ in count += 1 }
        reply.fire(7)
        reply.abandon()
        #expect(count == 1)
    }
}

/// Two questions in one pane, and what happens to them.
@Suite("the ask queue")
struct AskQueueTests {
    /// Every mutating call here goes through a local first. `#expect` takes its
    /// operands as immutable captures, so `#expect(queue.enqueue("a"))` does not
    /// compile at all — the same class of trap as the literal arithmetic note in
    /// `SnapAndConfigTests`.
    @Test("the first ask is the one on screen; the second waits")
    func firstOneShows() {
        var queue = AskQueue<String>()
        let first = queue.enqueue("a")
        // False means "do not present this one" — an iframe calling confirm()
        // while its parent's dialog is up must not repaint the sheet under the
        // pointer between the press and the release.
        let second = queue.enqueue("b")
        #expect(first)
        #expect(second == false)
        #expect(queue.current == "a")
        #expect(queue.count == 2)
    }

    @Test("answering one hands over to the next, in order")
    func finishAdvances() {
        var queue = AskQueue<String>()
        _ = queue.enqueue("a")
        _ = queue.enqueue("b")
        _ = queue.enqueue("c")
        let after = [queue.finish(), queue.finish(), queue.finish()]
        #expect(after == ["b", "c", nil])
        #expect(queue.isEmpty)
    }

    /// A pane going away owes an answer to every one of these, not just the one
    /// that was drawn.
    @Test("draining hands back everything outstanding, oldest first")
    func drainReturnsAll() {
        var queue = AskQueue<String>()
        _ = queue.enqueue("a")
        _ = queue.enqueue("b")
        let drained = queue.drain()
        #expect(drained == ["a", "b"])
        #expect(queue.isEmpty)
        #expect(queue.current == nil)
    }

    @Test("finishing an empty queue is not a crash")
    func finishOnEmpty() {
        var queue = AskQueue<String>()
        let next = queue.finish()
        #expect(next == nil)
    }
}

/// Who the sheet says is asking. A dialog that does not name its origin is a
/// phishing surface, and the conventions have to match the address bar 26 pt
/// below it or the two contradict each other.
@Suite("dialog origins")
struct AskOriginTests {
    @Test("https is dropped and http is kept")
    func schemeConvention() {
        #expect(AskOrigin.label(scheme: "https", host: "example.com", port: 443) == "example.com")
        #expect(AskOrigin.label(scheme: "http", host: "example.com", port: 80) == "http://example.com")
    }

    @Test("a non-default port is part of who is asking")
    func portShows() {
        #expect(AskOrigin.label(scheme: "http", host: "localhost", port: 8071)
            == "http://localhost:8071")
        #expect(AskOrigin.label(scheme: "https", host: "example.com", port: 8443)
            == "example.com:8443")
    }

    @Test("an origin with no host says so rather than inventing one")
    func noHost() {
        #expect(AskOrigin.label(scheme: "file", host: nil, port: nil) == "a local file")
        #expect(AskOrigin.label(scheme: "about", host: "", port: nil) == "this page")
    }

    /// The permission key keeps the scheme where the *label* drops it: http and
    /// https are two origins to the web platform, and a plain http page must
    /// not inherit a camera grant made to the secure one.
    @Test("the permission key keeps both schemes apart")
    func keyKeepsScheme() {
        #expect(AskOrigin.key(scheme: "https", host: "meet.example", port: 443)
            == "https://meet.example")
        #expect(AskOrigin.key(scheme: "http", host: "meet.example", port: 80)
            == "http://meet.example")
    }

    @Test("an origin with nothing to key on gets no key")
    func keyNeedsAHost() {
        #expect(AskOrigin.key(scheme: "file", host: nil, port: nil) == nil)
        #expect(AskOrigin.key(scheme: nil, host: "example.com", port: nil) == nil)
    }
}

/// Where a download lands and what it is called. Every bug this can have is a
/// string bug, and one of them writes outside `~/Downloads`.
@Suite("download naming")
struct DownloadNamingTests {
    @Test("a server-suggested name cannot escape the directory")
    func sanitizeStripsSeparators() {
        #expect(DownloadNaming.sanitize("../../.ssh/authorized_keys") == "authorized_keys")
        #expect(DownloadNaming.sanitize("report.pdf") == "report.pdf")
        #expect(DownloadNaming.sanitize("") == "download")
        #expect(DownloadNaming.sanitize("   ") == "download")
        #expect(DownloadNaming.sanitize(".bashrc") == "bashrc")
        // A name that is nothing but path separators leaves nothing behind, and
        // an empty destination is a write to the directory itself.
        #expect(DownloadNaming.sanitize("///") == "download")
    }

    @Test("a name already taken gets a suffix, before the extension")
    func uniqueNameWalks() {
        let taken: Set<String> = ["report.pdf", "report 1.pdf"]
        #expect(DownloadNaming.uniqueName("report.pdf") { taken.contains($0) } == "report 2.pdf")
        // Before the extension, so the file still opens in the right app.
        #expect(DownloadNaming.uniqueName("report.pdf") { $0 == "report.pdf" } == "report 1.pdf")
    }

    @Test("a free name is left alone")
    func uniqueNameLeavesFreeNames() {
        #expect(DownloadNaming.uniqueName("report.pdf") { _ in false } == "report.pdf")
    }

    @Test("a name with no extension still gets a suffix")
    func uniqueNameWithoutExtension() {
        #expect(DownloadNaming.uniqueName("Makefile") { $0 == "Makefile" } == "Makefile 1")
    }

    /// The guard against an infinite walk. Everything is taken, so the fallback
    /// has to be a name and not a hang.
    @Test("a thousand collisions terminate")
    func uniqueNameTerminates() {
        let name = DownloadNaming.uniqueName("x.zip") { _ in true }
        #expect(name.hasSuffix(".zip"))
        #expect(name != "x.zip")
    }
}

@Suite("byte sizes")
struct ByteSizeTests {
    @Test("the unit changes at each power of 1024")
    func units() {
        #expect(ByteSize.short(512) == "512 B")
        #expect(ByteSize.short(2048) == "2 KB")
        #expect(ByteSize.short(1024 * 1024 * 3) == "3.0 MB")
        #expect(ByteSize.short(-1) == "0 B")
    }
}

/// Which lane the status bar's orange count sends you to next.
@MainActor
@Suite("the asking registry")
struct WebAskCenterTests {
    /// The registry is a singleton because there is one status bar. A test that
    /// left rows in it would change what the next test sees.
    private func fresh() -> WebAskCenter {
        let center = WebAskCenter.shared
        for paneId in center.waiting { center.ended(paneId: paneId) }
        return center
    }

    @Test("a pane that asks twice is listed once")
    func idempotentBegin() {
        let center = fresh()
        center.began(paneId: "p1")
        center.began(paneId: "p1")
        #expect(center.count == 1)
    }

    @Test("clicking walks every waiting lane and comes back round")
    func nextCycles() {
        let center = fresh()
        center.began(paneId: "p1")
        center.began(paneId: "p2")
        #expect(center.next() == "p1")
        #expect(center.next() == "p2")
        #expect(center.next() == "p1")
    }

    /// A pane torn down with a dialog up must leave the list, or the status bar
    /// carries a count nothing can ever clear.
    @Test("a pane that stops asking leaves the list")
    func endedRemoves() {
        let center = fresh()
        center.began(paneId: "p1")
        center.began(paneId: "p2")
        center.ended(paneId: "p1")
        #expect(center.count == 1)
        #expect(center.next() == "p2")
        center.ended(paneId: "p2")
        #expect(center.count == 0)
        #expect(center.next() == nil)
    }

    /// The cursor is an index into a list that shrinks underneath it. Without
    /// the adjustment in `ended`, answering the lane you were sent to skips the
    /// next one.
    @Test("removing a lane you have already visited does not skip the next")
    func cursorSurvivesRemoval() {
        let center = fresh()
        center.began(paneId: "p1")
        center.began(paneId: "p2")
        center.began(paneId: "p3")
        #expect(center.next() == "p1")
        center.ended(paneId: "p1")
        #expect(center.next() == "p2")
    }
}
