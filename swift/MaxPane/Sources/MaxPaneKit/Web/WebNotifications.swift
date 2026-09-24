import AppKit
import UserNotifications
import WebKit

/// The Notification API, answered by the shell.
///
/// `WKWebView` on macOS does not implement `window.Notification` at all: the
/// constructor is missing, so Slack, Gmail, Linear and every chat app in a
/// pane can neither ask for permission nor notify, and their feature detection
/// (`"Notification" in window`) quietly turns the feature off. After blocking,
/// this is the biggest gap between a lane and a browser, because the sites you
/// keep open all day are the ones that notify.
///
/// So the API is a page-world user script, in every frame, before the page
/// runs — the `PaneFullscreen` pattern — and the pane is the notification
/// centre behind it:
///
/// - **`Notification.permission` is synchronous**, so the answer cannot be
///   fetched. Every remembered answer for this pane's cookie jar is written
///   into the script source as a map from origin to `granted` / `denied`, and
///   the script reads its own `location.origin` out of it. A new remembered
///   answer rewrites the script on every pane in that jar (`refreshUserScripts`)
///   for their next document, and tells the open documents on that origin.
/// - **`requestPermission()`** goes through the pane's ask sheet — the same
///   per-origin, per-jar question the camera asks (`WebPaneAsks`), remembered
///   in the same ledger table under `notifications`. Esc is "not now", and
///   resolves `default`; BLOCK and ALLOW without the box resolve for this
///   document only.
/// - **`new Notification()`** posts through `UNUserNotificationCenter` with the
///   site's title, body and icon; the icon is fetched with a short deadline and
///   dropped if it does not arrive. A click brings the app, the lane and the
///   pane forward and fires the page's `click`; `show`, `close` and `error`
///   arrive as they do in a browser, and `close()` takes it down.
/// - **Nothing for a pane you are looking at.** A notification for the focused
///   pane in the key window of the active app is a banner about the thing
///   under the pointer; Safari does not post one either, and the page still
///   hears `show` and `close`.
///
/// Service workers' `showNotification` is out of scope, and an evicted pane's
/// page is gone with it, so only a page that is alive can notify; the README
/// says both out loud.
enum WebNotifications {
    /// The name both the handler and the script agree on.
    static let channel = "maxpaneNotifications"

    /// The property on `window` the shell speaks to the script through, and
    /// the guard against the script running twice in one document.
    static let marker = "__maxpaneNotifications"

    /// What a page sent.
    enum Message: Equatable {
        /// `Notification.requestPermission()`; `id` is the promise to settle.
        case request(id: Int)
        /// `new Notification(title, options)`; `id` names the object.
        case show(id: Int, title: String, body: String, icon: URL?, tag: String?)
        /// `notification.close()`.
        case close(id: Int)
    }

    static func message(_ body: Any) -> Message? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String,
              let id = (dict["id"] as? NSNumber)?.intValue
        else { return nil }
        switch type {
        case "request":
            return .request(id: id)
        case "show":
            let tag = (dict["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let icon = (dict["icon"] as? String).flatMap(URL.init(string:))
                .flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
            return .show(
                id: id, title: dict["title"] as? String ?? "", body: dict["body"] as? String ?? "",
                icon: icon, tag: tag)
        case "close":
            return .close(id: id)
        default:
            return nil
        }
    }

    // MARK: - what the shell says back

    /// Settle a `requestPermission()` promise: `granted`, `denied`, or
    /// `default` for a question dismissed rather than answered.
    static func answerScript(id: Int, result: String) -> String {
        "window.\(marker) && window.\(marker).answer(\(id), '\(result)'); 0"
    }

    /// Fire one of the four events at a page's notification object.
    static func eventScript(id: Int, type: String) -> String {
        "window.\(marker) && window.\(marker).event(\(id), '\(type)'); 0"
    }

    /// An answer remembered from another pane in the same jar, for a document
    /// that is already open on that origin.
    static func permissionScript(origin: String, result: String) -> String {
        "window.\(marker) && window.\(marker).permission(\(quoted(origin)), '\(result)'); 0"
    }

    /// `[origin: allowed]` as the script's `granted` / `denied` map.
    static func grants(_ rows: [String: Bool]) -> [String: String] {
        rows.mapValues { $0 ? "granted" : "denied" }
    }

    // MARK: - the script

    /// The first line, which is the same whatever the grants are, so an
    /// installed copy can be recognised and replaced.
    static let header = "/* \(marker) */"

    static func source(grants: [String: String]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: grants, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return header + "\n" + body.replacingOccurrences(of: "__GRANTS__", with: json)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static let body = #"""
        (() => {
          if (Object.prototype.hasOwnProperty.call(window, '\#(marker)')) return;
          const CHANNEL = '\#(channel)';
          const GRANTS = __GRANTS__;
          let permission = GRANTS[location.origin] || 'default';
          let nextId = 1;
          const live = new Map();   // id → Notification, until it closes or fails
          const asks = new Map();   // id → resolve, for requestPermission
          const later = (fn) => setTimeout(fn, 0);
          const post = (message) => {
            try { window.webkit.messageHandlers[CHANNEL].postMessage(message); return true; } catch (e) { return false; }
          };
          const fire = (target, type) => {
            const event = new Event(type);
            const handler = target['on' + type];
            if (typeof handler === 'function') {
              try { handler.call(target, event); } catch (e) { later(() => { throw e; }); }
            }
            target.dispatchEvent(event);
          };
          const text = (value) => value === undefined || value === null ? '' : String(value);
          const resolveIcon = (icon) => {
            if (!icon) return '';
            try { return new URL(String(icon), document.baseURI).href; } catch (e) { return ''; }
          };

          class Notification extends EventTarget {
            constructor(title, options) {
              super();
              if (arguments.length === 0) {
                throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
              }
              options = options && typeof options === 'object' ? options : {};
              const id = nextId++;
              const fields = {
                title: text(title), body: text(options.body), icon: resolveIcon(options.icon),
                tag: text(options.tag), lang: text(options.lang), dir: options.dir || 'auto',
                badge: resolveIcon(options.badge), image: resolveIcon(options.image),
                data: options.data === undefined ? null : options.data,
                silent: options.silent === undefined || options.silent === null ? null : !!options.silent,
                requireInteraction: !!options.requireInteraction, renotify: !!options.renotify,
                timestamp: typeof options.timestamp === 'number' ? options.timestamp : Date.now(),
                actions: [], vibrate: [],
              };
              for (const name of Object.keys(fields)) {
                Object.defineProperty(this, name, { value: fields[name], enumerable: true });
              }
              Object.defineProperty(this, '__id', { value: id });
              this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
              live.set(id, this);
              if (permission !== 'granted') {
                later(() => { live.delete(id); fire(this, 'error'); });
                return;
              }
              const sent = post({ type: 'show', id, title: fields.title, body: fields.body, icon: fields.icon, tag: fields.tag });
              if (!sent) later(() => { live.delete(id); fire(this, 'error'); });
            }
            close() {
              if (!live.has(this.__id)) return;
              post({ type: 'close', id: this.__id });
            }
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              const promise = new Promise((resolve) => {
                if (permission !== 'default') return resolve(permission);
                const id = nextId++;
                asks.set(id, resolve);
                if (!post({ type: 'request', id })) { asks.delete(id); resolve('default'); }
              });
              if (typeof callback === 'function') {
                promise.then((result) => { try { callback(result); } catch (e) { later(() => { throw e; }); } });
              }
              return promise;
            }
          }
          Object.defineProperty(Notification.prototype, Symbol.toStringTag, { value: 'Notification' });

          const shell = Object.freeze({
            answer(id, result) {
              const resolve = asks.get(id);
              if (!resolve) return;
              asks.delete(id);
              if (result === 'granted' || result === 'denied') permission = result;
              resolve(result);
            },
            event(id, type) {
              const target = live.get(id);
              if (!target) return;
              if (type === 'close' || type === 'error') live.delete(id);
              fire(target, type);
            },
            permission(origin, result) {
              if (origin === location.origin && (result === 'granted' || result === 'denied')) permission = result;
            },
          });
          Object.defineProperty(window, '\#(marker)', { value: shell });
          Object.defineProperty(window, 'Notification', { value: Notification, writable: true, configurable: true, enumerable: false });
        })();
        """#

    // MARK: - installing

    /// Install the script and the handler on a web view, with these grants.
    ///
    /// Idempotent for the same reason `LinkHoverProbe.install` is: a second
    /// `add` of a handler by the same name is an Objective-C exception. A copy
    /// of the script already there with the same grants is left alone; with
    /// other grants the caller has emptied the controller first
    /// (`WebPaneController.refreshUserScripts`), because a user script cannot
    /// be removed on its own.
    @MainActor
    static func install(on webView: WKWebView, handler: WKScriptMessageHandler, grants: [String: String]) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: channel)
        content.add(handler, name: channel)
        let source = source(grants: grants)
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        // Every frame: an embedded chat widget notifies from its own frame.
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    /// True when the controller holds a copy of this script with other grants
    /// than these — the one case a refresh is worth a `removeAllUserScripts`.
    @MainActor
    static func isStale(on webView: WKWebView, grants: [String: String]) -> Bool {
        let wanted = source(grants: grants)
        let installed = webView.configuration.userContentController.userScripts
            .filter { $0.source.hasPrefix(header) }
        return !installed.isEmpty && !installed.contains { $0.source == wanted }
    }

    @MainActor
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
    }
}

// MARK: - posting

/// The seam between the pane and macOS's notification centre.
///
/// `UNUserNotificationCenter.current()` traps in a process that is not an app
/// bundle — which the test runner is not — so nothing here touches it until
/// the app asks, and a test hands the centre a recorder instead.
protocol NotificationPosting: AnyObject {
    /// Ask macOS whether this app may notify at all. Called once, the first
    /// time a site is granted — not at launch, where the question would be
    /// about nothing the person had asked for.
    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void)
    /// Post one. `icon` is a local file, already fetched, or nil; `subtitle`
    /// is the line under the title, empty for a page's (the Notification
    /// API has none) and the state and directory for an agent's.
    func post(identifier: String, title: String, subtitle: String, body: String, icon: URL?,
              completion: @escaping @Sendable (Error?) -> Void)
    /// Take delivered notifications down: the page's `close()`, or a tag
    /// replacing them.
    func remove(identifiers: [String])
}

/// The real thing.
final class SystemNotificationPoster: NotificationPosting {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    func requestAuthorization(_ completion: @escaping @Sendable (Bool) -> Void) {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { Log.warn("notifications: macOS refused authorization: \(error.localizedDescription)") }
            completion(granted)
        }
    }

    func post(identifier: String, title: String, subtitle: String, body: String, icon: URL?,
              completion: @escaping @Sendable (Error?) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        if let icon, let attachment = try? UNNotificationAttachment(identifier: "icon", url: icon) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil), withCompletionHandler: completion)
    }

    func remove(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// A site's icon as a file `UNNotificationAttachment` can take, or nil.
///
/// Fetched with a deadline rather than awaited: a notification that arrives
/// two seconds late because a CDN was slow is worse than one with no picture,
/// and a page's icon URL is a page's claim about a resource that may not exist.
/// Cached by URL for the life of the process, since a chat app notifies with
/// the same icon a hundred times a day.
@MainActor
final class NotificationIconCache {
    static let deadline: TimeInterval = 1.5
    /// PNG, JPEG and GIF are what `UNNotificationAttachment` accepts of the
    /// formats a site icon comes in; an `.ico` would be refused at post time.
    private static let extensions: [String: String] = ["image/png": "png", "image/jpeg": "jpg", "image/gif": "gif"]

    private var files: [URL: URL] = [:]
    private var failed: Set<URL> = []
    private let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maxpane-notification-icons-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func fetch(_ url: URL?, completion: @escaping @MainActor (URL?) -> Void) {
        guard let url else { return completion(nil) }
        if let file = files[url] { return completion(file) }
        if failed.contains(url) { return completion(nil) }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.deadline
        let directory = self.directory
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            var file: URL?
            if let data, !data.isEmpty,
               let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?
                   .split(separator: ";").first.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }),
               let ext = Self.extensions[type] {
                let target = directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
                if (try? data.write(to: target)) != nil { file = target }
            }
            Task { @MainActor in
                if let file { self.files[url] = file } else { self.failed.insert(url) }
                completion(file)
            }
        }
        task.resume()
    }
}

// MARK: - the centre

/// Which pane each posted notification belongs to, and the way back to it.
///
/// One for the app, because there is one `UNUserNotificationCenter` and a
/// click on a banner arrives with nothing but the identifier this handed out.
/// Panes register while they have a page and leave when it goes; a click for a
/// pane that has since closed is a no-op with a log line, which is what the
/// acceptance asks for and what a banner about a closed page deserves.
@MainActor
public final class WebNotificationCenter {
    public static let shared = WebNotificationCenter(poster: SystemNotificationPoster())

    /// One notification on screen, and the page object it stands for.
    struct Posted {
        let paneId: String
        let pageId: Int
        let frame: WKFrameInfo
        weak var webView: WKWebView?
    }

    let poster: NotificationPosting
    let icons = NotificationIconCache()
    /// How the app comes forward on a click. The real thing activates the app;
    /// a test records the call rather than stealing the desktop's focus.
    var activateApp: () -> Void = { NSApp.activate(ignoringOtherApps: true) }
    /// Whether macOS has been asked yet. Once per process, at the first grant.
    private(set) var authorizationRequested = false

    private struct WeakPane { weak var controller: WebPaneController? }
    private var panes: [String: WeakPane] = [:]
    private(set) var posted: [String: Posted] = [:]
    private var bridge: NotificationDelegateBridge?
    /// Notifications that are not a page's — an agent's (`AgentNotifier`) —
    /// by identifier prefix. There is one `UNUserNotificationCenter` delegate
    /// per process, so every click lands here first and is handed on.
    private var routes: [(prefix: String, activated: (String, Bool) -> Void)] = []

    init(poster: NotificationPosting) {
        self.poster = poster
    }

    /// Become `UNUserNotificationCenter`'s delegate, so a banner shows while the
    /// app is frontmost and a click comes back here. App only: the runner has
    /// no bundle for the centre to speak for.
    public func installSystemDelegate() {
        let bridge = NotificationDelegateBridge(center: self)
        self.bridge = bridge
        UNUserNotificationCenter.current().delegate = bridge
    }

    func register(_ pane: WebPaneController) {
        panes[pane.paneId] = WeakPane(controller: pane)
    }

    func unregister(paneId: String) {
        panes[paneId] = nil
    }

    /// Every registered pane in one cookie jar: the ones whose next document
    /// needs a new grants map.
    func panes(inDataStore dataStoreId: String) -> [WebPaneController] {
        panes.values.compactMap(\.controller).filter { $0.dataStoreId == dataStoreId }
    }

    /// A click on a notification whose identifier starts with `prefix` goes
    /// to `activated` (with whether it was a dismissal) rather than to a pane.
    func addRoute(prefix: String, activated: @escaping (String, Bool) -> Void) {
        routes.removeAll { $0.prefix == prefix }
        routes.append((prefix, activated))
    }

    /// A site was just allowed. The first time, ask macOS.
    func siteGranted() { ensureAuthorized() }

    /// Ask macOS whether this app may notify, once per process, the first
    /// time there is something to say: a site allowed, or an agent stopping
    /// while nobody is looking. Never at launch.
    func ensureAuthorized() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        poster.requestAuthorization { granted in
            Log.debug("notifications: macOS authorization \(granted ? "granted" : "refused")")
        }
    }

    /// A remembered answer changed for `origin` in `dataStoreId`: every pane in
    /// that jar rewrites its script for the next document, and a document
    /// already open on that origin is told directly.
    func grantsChanged(dataStoreId: String, origin: String, allowed: Bool) {
        let result = allowed ? "granted" : "denied"
        for pane in panes(inDataStore: dataStoreId) {
            pane.refreshUserScripts()
            pane.tellOpenDocument(origin: origin, permission: result)
        }
    }

    /// Post one for `pane`. The identifier carries the tag when there is one,
    /// so a chat app's "3 new messages" replaces "2 new messages" rather than
    /// stacking, and the replaced object hears `close` as it would in a browser.
    func post(from pane: WebPaneController, pageId: Int, frame: WKFrameInfo, webView: WKWebView?,
              title: String, body: String, icon: URL?, tag: String?,
              completion: @escaping @MainActor (Error?) -> Void) {
        let identifier = tag.map { "maxpane.\(pane.paneId).tag.\($0)" } ?? "maxpane.\(pane.paneId).\(UUID().uuidString)"
        if let replaced = posted[identifier], replaced.pageId != pageId {
            tell(replaced, "close")
        }
        posted[identifier] = Posted(paneId: pane.paneId, pageId: pageId, frame: frame, webView: webView)
        let poster = self.poster
        icons.fetch(icon) { file in
            poster.post(identifier: identifier, title: title, subtitle: "", body: body, icon: file) { error in
                Task { @MainActor in completion(error) }
            }
        }
    }

    /// The page's `close()`, or the pane going away under one.
    func close(paneId: String, pageId: Int) {
        for (identifier, entry) in posted where entry.paneId == paneId && entry.pageId == pageId {
            posted[identifier] = nil
            poster.remove(identifiers: [identifier])
            tell(entry, "close")
        }
    }

    /// A banner was clicked (or swiped away). The pane it belongs to comes
    /// forward and its page hears `click`; a dismissal is only `close`.
    func activated(identifier: String, dismissed: Bool = false) {
        guard let entry = posted[identifier] else {
            if let route = routes.first(where: { identifier.hasPrefix($0.prefix) }) {
                route.activated(identifier, dismissed)
                return
            }
            Log.debug("notifications: \(identifier) is nobody's now")
            return
        }
        posted[identifier] = nil
        guard let pane = panes[entry.paneId]?.controller else {
            Log.debug("notifications: pane \(entry.paneId) has closed; its notification is a no-op")
            return
        }
        if dismissed {
            tell(entry, "close")
            return
        }
        activateApp()
        pane.bringForward()
        tell(entry, "click")
        tell(entry, "close")
    }

    /// Fire an event at the page object a posted notification stands for. In
    /// the frame that made it, so an embedded widget hears its own click.
    func tell(_ entry: Posted, _ type: String) {
        guard let webView = entry.webView else {
            return Log.debug("notifications: no page left to hear \(type) for pane \(entry.paneId)")
        }
        webView.evaluateJavaScript(
            WebNotifications.eventScript(id: entry.pageId, type: type), in: entry.frame, in: .page
        ) { result in
            if case .failure(let error) = result {
                Log.debug("notifications: \(type) did not reach pane \(entry.paneId): \(error.localizedDescription)")
            }
        }
    }
}

/// `UNUserNotificationCenterDelegate`, hopping to the main actor where the
/// centre lives. Its callbacks are not promised any thread.
final class NotificationDelegateBridge: NSObject, UNUserNotificationCenterDelegate {
    private let center: WebNotificationCenter

    init(center: WebNotificationCenter) {
        self.center = center
    }

    /// A banner even while the app is frontmost: the pane it is about may be
    /// fifteen lanes away, which is the whole reason it was posted.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let identifier = response.notification.request.identifier
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        let target = self.center
        Task { @MainActor in
            target.activated(identifier: identifier, dismissed: dismissed)
            completionHandler()
        }
    }
}
