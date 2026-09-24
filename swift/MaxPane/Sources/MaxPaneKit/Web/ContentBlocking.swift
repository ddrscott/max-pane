import Foundation
import WebKit

/// Ad and tracker blocking for every web pane, and the popups over them.
///
/// A `WKContentRuleList` is WebKit's own blocker: a list compiled once into a
/// bytecode the network process runs on every request, with no script in the
/// page and no work of ours per load. The list comes from a URL in the config
/// file — WebKit's content-blocker JSON, which is what Safari extensions ship —
/// and is compiled into a `WKContentRuleListStore` under the profile's
/// Application Support. That store **is the cache**: a launch looks the compiled
/// list up by identifier and adds it, and only fetches when the cache is
/// missing, was built from a different source, or is older than a day. Nothing
/// here touches the network on the main thread, and a first launch with no
/// cache opens its window at once; the list is added to every live view when
/// the compile lands.
///
/// **150 000 rules is WebKit's ceiling per list**, and a list past it fails to
/// compile with an error that does not say so. `RuleListSplit` cuts a bigger
/// source into several lists rather than one, keeping the exception rules
/// (`ignore-previous-rules`) with every part, because an exception only reaches
/// the rules *before it in the same list*.
///
/// **Per site, off.** The switch is by registrable domain — `youtube.com`, not
/// `www.youtube.com` — kept in the ledger by `StripStore`, and applied here on
/// every main-frame navigation: the pane's `decidePolicyFor` tells the blocker
/// where the page is going, and the lists come off its
/// `WKUserContentController` or go back on before the request. A popup shares
/// its opener's controller (WebKit copies the configuration and keeps the same
/// controller object), so it follows the opener's site, which is the site that
/// opened it.
@MainActor
public final class ContentBlocker {
    /// The one the app uses. Tests build their own over a temporary directory.
    public static let shared = ContentBlocker(
        directory: Profile.current.supportDirectory.appendingPathComponent("content-rules", isDirectory: true))

    /// WebKit's limit. Not configurable: it is a fact about WebKit.
    static let rulesPerList = 150_000
    /// How old a compiled list may be before a launch fetches the source again.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private var ruleStore: WKContentRuleListStore?
    /// The compiled lists, once they exist. Several when the source was split.
    public private(set) var lists: [WKContentRuleList] = []
    public private(set) var ruleCount = 0
    /// `blocking = false` in the config file. Off, nothing is attached and every
    /// site reads as unblocked; the lists stay compiled for the next launch.
    public var isEnabled = true
    /// The sites the blocker is off for, as registrable domains.
    public private(set) var exemptDomains: Set<String> = []
    /// Where a flipped exemption is written. The app points this at the ledger;
    /// a test leaves it nil.
    public var persistExemption: ((String, Bool) -> Void)?

    private struct Attachment {
        weak var controller: WKUserContentController?
        var host: String?
        var applied = false
    }
    private var attachments: [ObjectIdentifier: Attachment] = [:]
    private var refreshTimer: Timer?
    private var loading = false

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - who is blocked

    /// `www.youtube.com` → `youtube.com`; an IP literal or a single label is
    /// itself. Lowercased, so the ledger's rows compare as plain strings.
    /// `nonisolated`: a pure string function, and the one registrable-domain
    /// rule in the app. `[[apps]]` matches a lane by it off the main actor
    /// (`WebApps`), and a second copy of the rule that could disagree with
    /// this one about what `bbc.co.uk` is would be worse than either.
    public nonisolated static func domain(of host: String?) -> String? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return BrowserAddress.splitHost(host).registrable
    }

    public func isExempt(host: String?) -> Bool {
        guard let domain = Self.domain(of: host) else { return false }
        return exemptDomains.contains(domain)
    }

    /// Whether requests from a page on `host` are filtered right now.
    public func isBlocking(host: String?) -> Bool {
        isEnabled && !lists.isEmpty && !isExempt(host: host)
    }

    /// The ledger's rows, read once at launch.
    public func loadExemptions(_ domains: [String]) {
        exemptDomains = Set(domains.map { $0.lowercased() })
        reapplyAll()
    }

    /// Switch the blocker off for a site, or back on. Every attached view on
    /// that site changes at once; the caller reloads the page it was asked from.
    public func setExempt(_ domain: String, _ exempt: Bool) {
        let domain = domain.lowercased()
        if exempt { exemptDomains.insert(domain) } else { exemptDomains.remove(domain) }
        persistExemption?(domain, exempt)
        reapplyAll()
    }

    // MARK: - views

    /// A web view's controller, from `buildWebView`. `host` is where the pane
    /// is when it is built; `willNavigate` keeps it current.
    public func attach(_ controller: WKUserContentController, host: String?) {
        var attachment = Attachment(controller: controller, host: host)
        attachment.applied = apply(to: controller, host: host, applied: false)
        attachments[ObjectIdentifier(controller)] = attachment
    }

    public func detach(_ controller: WKUserContentController) {
        attachments.removeValue(forKey: ObjectIdentifier(controller))
    }

    /// The pane's main frame is about to go to `host`. Called before the
    /// navigation is allowed, so the lists are right for the document that
    /// loads and for every request it makes.
    public func willNavigate(_ controller: WKUserContentController, toHost host: String?) {
        let id = ObjectIdentifier(controller)
        guard var attachment = attachments[id] else { return }
        attachment.host = host
        attachment.applied = apply(to: controller, host: host, applied: attachment.applied)
        attachments[id] = attachment
    }

    /// Put the lists on the controller or take them off, as the site and the
    /// switch say. Returns whether they are on.
    private func apply(to controller: WKUserContentController, host: String?, applied: Bool) -> Bool {
        let wanted = isBlocking(host: host)
        guard wanted != applied else { return wanted }
        if wanted {
            for list in lists { controller.add(list) }
        } else {
            controller.removeAllContentRuleLists()
        }
        return wanted
    }

    private func reapplyAll() {
        for (id, attachment) in attachments {
            guard let controller = attachment.controller else {
                attachments.removeValue(forKey: id)
                continue
            }
            var next = attachment
            next.applied = apply(to: controller, host: attachment.host, applied: attachment.applied)
            attachments[id] = next
        }
    }

    /// New lists in, old ones out, on every view that should have them.
    private func swap(in lists: [WKContentRuleList], ruleCount: Int) {
        for (id, attachment) in attachments where attachment.applied {
            guard let controller = attachment.controller else { continue }
            controller.removeAllContentRuleLists()
            var next = attachment
            next.applied = false
            attachments[id] = next
        }
        self.lists = lists
        self.ruleCount = ruleCount
        reapplyAll()
    }

    // MARK: - the source

    /// What the store holds, beside it: which source it was built from and
    /// when, so a launch knows whether to trust it.
    struct Meta: Codable, Equatable {
        var source: String
        var fetchedAt: Date
        var identifiers: [String]
        var ruleCount: Int
    }

    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    var meta: Meta? {
        get { (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(Meta.self, from: $0) } }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            try? data.write(to: metaURL, options: .atomic)
        }
    }

    private func store() throws -> WKContentRuleListStore {
        if let ruleStore { return ruleStore }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let made = WKContentRuleListStore(url: directory) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "no rule list store at \(directory.path)"])
        }
        ruleStore = made
        return made
    }

    /// The launch path: the cache first, the network only when the cache will
    /// not do, and a daily refresh after that. Returns at once.
    public func start(source: String) {
        guard isEnabled, !loading else { return }
        loading = true
        Task { [weak self] in
            await self?.load(source: source)
            self?.loading = false
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.loading else { return }
                self.loading = true
                Task { await self.refresh(source: source); self.loading = false }
            }
        }
    }

    private func load(source: String) async {
        let cached = meta
        if let cached, cached.source == source, !cached.identifiers.isEmpty, await lookUp(cached) {
            if Date().timeIntervalSince(cached.fetchedAt) < Self.refreshInterval { return }
            Log.debug("blocking: cached list is \(Int(Date().timeIntervalSince(cached.fetchedAt) / 3600)) h old, refreshing")
        }
        await refresh(source: source)
    }

    /// The compiled lists named in `meta`, from the store. False when any is
    /// missing — a cleared store, a WebKit that no longer reads the bytecode.
    private func lookUp(_ cached: Meta) async -> Bool {
        guard let store = try? store() else { return false }
        var found: [WKContentRuleList] = []
        for identifier in cached.identifiers {
            guard let list = await store.list(identifier) else { return false }
            found.append(list)
        }
        swap(in: found, ruleCount: cached.ruleCount)
        Log.debug("blocking: \(cached.ruleCount) rules in \(found.count) list(s) from the cache")
        return true
    }

    /// Fetch every URL in `source`, join them, compile, and swap the result in.
    /// A failure keeps whatever is already on the views — the last compiled
    /// list is the offline fallback — and says why on the log.
    private func refresh(source: String) async {
        let urls = Self.sources(source)
        guard !urls.isEmpty else {
            Log.warn("blocking: blocking_list_url names no URL; nothing is blocked")
            return
        }
        var joined: [Any] = []
        for url in urls {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    Log.warn("blocking: \(url) answered \(http.statusCode); keeping the last compiled list")
                    return
                }
                guard let rules = try JSONSerialization.jsonObject(with: data) as? [Any] else {
                    Log.warn("blocking: \(url) is not a JSON array of rules; keeping the last compiled list")
                    return
                }
                joined += rules
            } catch {
                Log.warn("blocking: could not fetch \(url): \(error.localizedDescription); keeping the last compiled list")
                return
            }
        }
        do {
            try await install(rules: joined, source: source)
        } catch {
            Log.warn("blocking: could not compile the list from \(source): \(error.localizedDescription)")
        }
    }

    /// Whitespace- or comma-separated URLs.
    static func sources(_ text: String) -> [URL] {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { URL(string: String($0)) }
            .filter { $0.scheme == "https" || $0.scheme == "http" || $0.scheme == "file" }
    }

    /// Compile WebKit content-blocker JSON, split as WebKit needs, and put it on
    /// every attached view. What `refresh` does with what it fetched; what a
    /// test does with a list of its own.
    public func install(json: Data, source: String) async throws {
        guard let rules = try JSONSerialization.jsonObject(with: json) as? [Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "not a JSON array of rules"])
        }
        try await install(rules: rules, source: source)
    }

    private func install(rules: [Any], source: String) async throws {
        let started = CFAbsoluteTimeGetCurrent()
        let store = try store()
        let parts = RuleListSplit.split(rules, limit: Self.rulesPerList)
        // A new identifier per build, so the old lists are not overwritten
        // under views still holding them; the stale ones are removed after.
        let stamp = String(Int(Date().timeIntervalSince1970))
        var compiled: [WKContentRuleList] = []
        for (index, part) in parts.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: part)
            let text = String(decoding: data, as: UTF8.self)
            let identifier = "maxpane-\(stamp)-\(index)"
            guard let list = try await store.compile(identifier, text) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "WebKit returned no list for part \(index)"])
            }
            compiled.append(list)
        }
        let previous = meta?.identifiers ?? []
        swap(in: compiled, ruleCount: rules.count)
        meta = Meta(source: source, fetchedAt: Date(), identifiers: compiled.map(\.identifier), ruleCount: rules.count)
        for stale in previous where !compiled.map(\.identifier).contains(stale) {
            store.removeContentRuleList(forIdentifier: stale) { _ in }
        }
        let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        Log.debug("blocking: compiled \(rules.count) rules into \(compiled.count) list(s) in \(ms) ms")
    }
}

extension WKContentRuleListStore {
    /// `lookUpContentRuleList`, awaited. WebKit calls back on the main queue.
    @MainActor
    func list(_ identifier: String) async -> WKContentRuleList? {
        await withCheckedContinuation { continuation in
            lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                continuation.resume(returning: list)
            }
        }
    }

    /// `compileContentRuleList`, awaited.
    @MainActor
    func compile(_ identifier: String, _ json: String) async throws -> WKContentRuleList? {
        try await withCheckedThrowingContinuation { continuation in
            compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: list) }
            }
        }
    }
}

/// Cutting a rule list to WebKit's size.
///
/// A rule is a JSON object with a `trigger` and an `action`; an action of type
/// `ignore-previous-rules` is an exception, and it only reaches the rules
/// before it *in its own list*. So a list cut into two cannot simply be cut:
/// every exception must ride with every part, or the second part's rules
/// block what the first part's exceptions were written to allow. Each part is
/// therefore `limit − exceptions` ordinary rules followed by all the
/// exceptions. When the exceptions alone leave no room, the list is cut
/// plainly and the caller's log says so.
enum RuleListSplit {
    static func isException(_ rule: Any) -> Bool {
        guard let rule = rule as? [String: Any], let action = rule["action"] as? [String: Any] else { return false }
        return action["type"] as? String == "ignore-previous-rules"
    }

    static func split(_ rules: [Any], limit: Int) -> [[Any]] {
        guard rules.count > limit else { return rules.isEmpty ? [] : [rules] }
        let exceptions = rules.filter(isException)
        let ordinary = rules.filter { !isException($0) }
        let room = limit - exceptions.count
        guard room > 0 else {
            Log.warn("blocking: \(exceptions.count) exception rules leave no room under \(limit); cutting plainly, and exceptions will not reach every part")
            return stride(from: 0, to: rules.count, by: limit).map { Array(rules[$0..<min($0 + limit, rules.count)]) }
        }
        return stride(from: 0, to: ordinary.count, by: room).map {
            Array(ordinary[$0..<min($0 + room, ordinary.count)]) + exceptions
        }
    }
}
