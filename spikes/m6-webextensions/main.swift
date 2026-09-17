// Spike M6 — WKWebExtension against the macOS 14 floor.
//
// One process, one phase, picked by argv:
//   M6Spike <out-dir> baseline   N panes, no extension controller; footprint
//   M6Spike <out-dir> ext        N panes, Dark Reader loaded and granted; footprint
//   M6Spike <out-dir> probe      1 pane: prompts, injection, popup, commands
//   M6Spike <out-dir> rg         1 pane on github.com with Refined GitHub
//
// Env: EXT_DIR (unpacked Dark Reader), RG_DIR (unpacked Refined GitHub),
// FIXTURE (URL every pane loads), PANES (default 6), SETTLE (seconds, default
// 12), GRANT (1 grants the manifest's host patterns up front; 0 leaves them
// requested, to see what WebKit does on its own).
//
// The windows sit one level below the desktop picture and the app is an
// accessory, so nothing here ever takes focus from whoever is working.

import AppKit
import WebKit

// MARK: - plumbing

setvbuf(stdout, nil, _IONBF, 0)
NSSetUncaughtExceptionHandler { e in
    FileHandle.standardError.write("m6: uncaught \(e.name.rawValue): \(e.reason ?? "")\n\(e.callStackSymbols.prefix(12).joined(separator: "\n"))\n".data(using: .utf8)!)
}
let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: M6Spike <out-dir> baseline|ext|probe|rg\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
let phase = args[2]
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let env = ProcessInfo.processInfo.environment
let paneCount = Int(env["PANES"] ?? "") ?? 6
let settle = Double(env["SETTLE"] ?? "") ?? 12
let grant = (env["GRANT"] ?? "1") == "1"
// The app's panes use persistent identifier stores (ADR-0003); a private lane
// is `.nonPersistent()`. STORE picks which the spike's panes get, PRIVATE_DATA
// lets the extension into ephemeral sessions the way Safari's "Allow in
// Private Browsing" does.
let persistentStore = (env["STORE"] ?? "persistent") == "persistent"
let privateData = (env["PRIVATE_DATA"] ?? "0") == "1"
let spikeStoreID = UUID(uuidString: "6D360000-0000-4000-8000-00000000A6A6")!
func paneStore() -> WKWebsiteDataStore { persistentStore ? WKWebsiteDataStore(forIdentifier: spikeStoreID) : .nonPersistent() }
let fixture = URL(string: env["FIXTURE"] ?? "http://127.0.0.1:18960/page.html")!
let lane = CGSize(width: 656, height: 1000)
let t0 = Date()

var events: [[String: Any]] = []
func log(_ kind: String, _ detail: [String: Any] = [:]) {
    var e = detail
    e["t_ms"] = Int(Date().timeIntervalSince(t0) * 1000)
    e["event"] = kind
    events.append(e)
    let extra = detail.isEmpty ? "" : " " + detail.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
    print("[\(e["t_ms"]!) ms] \(kind)\(extra)")
}
var report: [String: Any] = ["phase": phase, "panes": paneCount, "grant": grant, "fixture": fixture.absoluteString, "persistentStore": persistentStore, "privateData": privateData]
func finish(_ code: Int32) -> Never {
    report["events"] = events
    report["os"] = ProcessInfo.processInfo.operatingSystemVersionString
    let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: outDir.appendingPathComponent("report-\(phase).json"))
    print("wrote \(outDir.path)/report-\(phase).json")
    if persistentStore {
        WKWebsiteDataStore.remove(forIdentifier: spikeStoreID) { _ in exit(code) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(code) }
        while true { RunLoop.main.run(mode: .default, before: .distantFuture) }
    }
    exit(code)
}

// MARK: - processes

struct ProcSample { let pid: Int32; let path: String; let footprintMB: Double; let rssMB: Double }

func footprint(_ pid: Int32) -> (Double, Double)? {
    // `rusage_info_t` is `void *`, and the kernel writes the struct THROUGH the
    // pointer you pass — Apple's callers write `(rusage_info_t *)&info`. Passing
    // `&someVoidPointer` hands it an 8-byte stack slot to fill with a ~300-byte
    // struct, which is a __stack_chk_fail with no message (found the hard way).
    let buf = UnsafeMutableRawPointer.allocate(byteCount: 4096, alignment: 16)
    defer { buf.deallocate() }
    buf.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    guard proc_pid_rusage(pid, RUSAGE_INFO_V4, buf.assumingMemoryBound(to: rusage_info_t?.self)) == 0 else { return nil }
    let info = buf.load(as: rusage_info_v4.self)
    return (Double(info.ri_phys_footprint) / 1_048_576, Double(info.ri_resident_size) / 1_048_576)
}

func webkitPids() -> [Int32: String] {
    let n = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    var pids = [Int32](repeating: 0, count: Int(n) * 2)
    let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
    var out: [Int32: String] = [:]
    var buf = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(Int(got) / MemoryLayout<Int32>.size) where pid > 0 {
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            if path.contains("com.apple.WebKit.") { out[pid] = path }
        }
    }
    return out
}
let baselinePids = Set(webkitPids().keys)

func sampleNewWebKit() -> [ProcSample] {
    webkitPids().compactMap { (pid, path) in
        guard !baselinePids.contains(pid), let (f, r) = footprint(pid) else { return nil }
        let short = path.components(separatedBy: "/").last ?? path
        return ProcSample(pid: pid, path: short, footprintMB: f, rssMB: r)
    }.sorted { $0.pid < $1.pid }
}

func contentPid(of webView: WKWebView) -> Int32? {
    // `-[WKWebView _webProcessIdentifier]` is private; a spike may read it, and
    // calling the IMP directly avoids KVC's exception on a key it will not map.
    let sel = Selector(("_webProcessIdentifier"))
    guard webView.responds(to: sel), let imp = class_getMethodImplementation(type(of: webView), sel) else { return nil }
    typealias Getter = @convention(c) (AnyObject, Selector) -> pid_t
    return unsafeBitCast(imp, to: Getter.self)(webView, sel)
}

// MARK: - panes as tabs

@available(macOS 15.4, *)
final class Tab: NSObject, WKWebExtensionTab {
    let webView: WKWebView
    weak var win: Win?
    let index: Int
    init(webView: WKWebView, index: Int) { self.webView = webView; self.index = index }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { win }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { index }
    func url(for context: WKWebExtensionContext) -> URL? { webView.url }
    func title(for context: WKWebExtensionContext) -> String? { webView.title }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !webView.isLoading }
    func size(for context: WKWebExtensionContext) -> CGSize { webView.bounds.size }
    func isSelected(for context: WKWebExtensionContext) -> Bool { index == 0 }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func isMuted(for context: WKWebExtensionContext) -> Bool { false }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { 1 }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { false }
}

@available(macOS 15.4, *)
final class Win: NSObject, WKWebExtensionWindow {
    var tabs: [Tab] = []
    let frame: CGRect
    init(frame: CGRect) { self.frame = frame }
    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { tabs }
    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { tabs.first }
    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState { .normal }
    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
    func frame(for context: WKWebExtensionContext) -> CGRect { frame }
    func screenFrame(for context: WKWebExtensionContext) -> CGRect { NSScreen.main?.frame ?? frame }
}

@available(macOS 15.4, *)
final class Coordinator: NSObject, WKWebExtensionControllerDelegate {
    let win: Win
    var popupWebView: WKWebView?
    var onPopup: ((WKWebExtension.Action) -> Void)?
    init(win: Win) { self.win = win }

    func webExtensionController(_ c: WKWebExtensionController, openWindowsFor ctx: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [win] }
    func webExtensionController(_ c: WKWebExtensionController, focusedWindowFor ctx: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { win }

    func webExtensionController(_ c: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for ctx: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        log("prompt.permissions", ["permissions": permissions.map(\.rawValue).sorted().joined(separator: ","), "tab": tab != nil])
        completionHandler(permissions, nil)
    }
    func webExtensionController(_ c: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for ctx: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        log("prompt.urls", ["urls": urls.map(\.absoluteString).sorted().joined(separator: ","), "tab": tab != nil])
        completionHandler(urls, nil)
    }
    func webExtensionController(_ c: WKWebExtensionController, promptForPermissionMatchPatterns patterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for ctx: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        log("prompt.matchPatterns", ["patterns": patterns.map(\.string).sorted().joined(separator: ","), "tab": tab != nil])
        completionHandler(patterns, nil)
    }
    func webExtensionController(_ c: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext ctx: WKWebExtensionContext) {
        log("action.updated", ["label": action.label, "badge": action.badgeText, "enabled": action.isEnabled, "presentsPopup": action.presentsPopup])
    }
    func webExtensionController(_ c: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for ctx: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        log("popup.present", ["hasWebView": action.popupWebView != nil, "hasPopover": action.popupPopover != nil,
                              "webViewFrame": action.popupWebView.map { NSStringFromRect($0.frame) } ?? "-",
                              "popoverSize": action.popupPopover.map { NSStringFromSize($0.contentSize) } ?? "-"])
        popupWebView = action.popupWebView
        onPopup?(action)
        completionHandler(nil)
    }
    func webExtensionController(_ c: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for ctx: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void) {
        log("request.newTab", ["url": configuration.url?.absoluteString ?? "-"])
        completionHandler(nil, NSError(domain: "m6", code: 1))
    }
    func webExtensionController(_ c: WKWebExtensionController, openOptionsPageFor ctx: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        log("request.optionsPage", ["url": ctx.optionsPageURL?.absoluteString ?? "-"])
        completionHandler(nil)
    }
}

// MARK: - the app

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
var windows: [NSWindow] = []
var webViews: [WKWebView] = []
var extController: AnyObject?   // WKWebExtensionController, held loosely so this file compiles at 14.0
var coordinator: AnyObject?
var winModel: AnyObject?
var contexts: [String: AnyObject] = [:]

let belowDesktop = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)

func makePane(_ i: Int, configuration: WKWebViewConfiguration) -> WKWebView {
    let frame = NSRect(x: 40 + CGFloat(i % 3) * 60, y: 40 + CGFloat(i / 3) * 60, width: lane.width, height: lane.height)
    let w = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    w.title = "M6 pane \(i)"
    w.level = belowDesktop
    w.isReleasedWhenClosed = false
    let wv = WKWebView(frame: NSRect(origin: .zero, size: lane), configuration: configuration)
    wv.autoresizingMask = [.width, .height]
    w.contentView = wv
    w.orderBack(nil)
    windows.append(w)
    webViews.append(wv)
    return wv
}

func evalJSON(_ wv: WKWebView, _ js: String, _ done: @escaping (Any?) -> Void) {
    wv.evaluateJavaScript("JSON.stringify(\(js))") { r, e in
        if let e = e { done(["error": String(describing: e)]); return }
        guard let s = r as? String, let d = s.data(using: .utf8) else { done(nil); return }
        done(try? JSONSerialization.jsonObject(with: d))
    }
}

let darkReaderProbe = """
({ mode: document.documentElement.getAttribute('data-darkreader-mode'),
   scheme: document.documentElement.getAttribute('data-darkreader-scheme'),
   styles: document.querySelectorAll('style.darkreader').length,
   meta: !!document.querySelector('meta[name=darkreader]'),
   htmlBg: getComputedStyle(document.documentElement).backgroundColor,
   bodyBg: getComputedStyle(document.body).backgroundColor,
   bodyColor: getComputedStyle(document.body).color,
   m6: document.documentElement.dataset.m6 || null, m6bg: document.documentElement.dataset.m6bg || null,
   innerWidth: innerWidth, dpr: devicePixelRatio, title: document.title })
"""
let refinedProbe = """
({ htmlClass: document.documentElement.className,
   rgh: document.querySelectorAll('[class*="rgh-"]').length,
   rghAttrs: Array.from(document.documentElement.attributes).map(a => a.name).filter(n => n.startsWith('rgh')).join(','),
   innerWidth: innerWidth, title: document.title })
"""

func snapshot(_ wv: WKWebView, _ name: String, _ done: @escaping () -> Void) {
    wv.takeSnapshot(with: nil) { img, err in
        if let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent(name))
            log("snapshot", ["file": name, "px": "\(rep.pixelsWide)x\(rep.pixelsHigh)"])
        } else {
            log("snapshot.failed", ["file": name, "error": err.map { String(describing: $0) } ?? "nil"])
        }
        done()
    }
}

func recordMemory(_ label: String) {
    let samples = sampleNewWebKit()
    let panePids = Set(webViews.compactMap(contentPid))
    var rows: [[String: Any]] = []
    var paneTotal = 0.0, otherContent = 0.0, networking = 0.0, gpu = 0.0
    for s in samples {
        let isPane = panePids.contains(s.pid)
        rows.append(["pid": s.pid, "process": s.path, "footprintMB": (s.footprintMB * 10).rounded() / 10, "rssMB": (s.rssMB * 10).rounded() / 10, "pane": isPane])
        if s.path.contains("WebContent") { if isPane { paneTotal += s.footprintMB } else { otherContent += s.footprintMB } }
        else if s.path.contains("Networking") { networking += s.footprintMB }
        else if s.path.contains("GPU") { gpu += s.footprintMB }
    }
    let selfFoot = footprint(getpid())?.0 ?? 0
    let summary: [String: Any] = [
        "label": label, "processes": rows,
        "webContentPanes": panePids.count, "webContentOther": rows.filter { ($0["process"] as! String).contains("WebContent") && !($0["pane"] as! Bool) }.count,
        "paneWebContentMB": (paneTotal * 10).rounded() / 10,
        "perPaneWebContentMB": panePids.isEmpty ? 0 : ((paneTotal / Double(panePids.count)) * 10).rounded() / 10,
        "otherWebContentMB": (otherContent * 10).rounded() / 10,
        "networkingMB": (networking * 10).rounded() / 10, "gpuMB": (gpu * 10).rounded() / 10,
        "appMB": (selfFoot * 10).rounded() / 10,
        "totalMB": ((paneTotal + otherContent + networking + gpu + selfFoot) * 10).rounded() / 10,
    ]
    var mem = report["memory"] as? [[String: Any]] ?? []
    mem.append(summary)
    report["memory"] = mem
    log("memory", ["label": label, "panes": panePids.count, "perPaneMB": summary["perPaneWebContentMB"]!, "otherWebContentMB": summary["otherWebContentMB"]!, "totalMB": summary["totalMB"]!])
}

// Load pages and wait until every pane has finished, with a ceiling.
final class LoadWatcher: NSObject, WKNavigationDelegate {
    var pending = 0
    var done: (() -> Void)?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pending -= 1; log("page.loaded", ["url": webView.url?.absoluteString ?? "-"]); if pending == 0 { done?(); done = nil } }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { pending -= 1; log("page.failed", ["error": error.localizedDescription]); if pending == 0 { done?(); done = nil } }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { pending -= 1; log("page.failed", ["error": error.localizedDescription]); if pending == 0 { done?(); done = nil } }
}
let watcher = LoadWatcher()

func loadAll(_ url: URL, _ then: @escaping () -> Void) {
    watcher.pending = webViews.count
    watcher.done = then
    for wv in webViews { wv.navigationDelegate = watcher; wv.load(URLRequest(url: url)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { if watcher.done != nil { log("page.timeout"); watcher.done?(); watcher.done = nil } }
}

func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

// Poll the first pane until Dark Reader's markers appear (or give up), and log how long it took.
func waitForInjection(_ wv: WKWebView, probe: String, isInjected: @escaping (Any?) -> Bool, deadline: Double, _ done: @escaping (Any?) -> Void) {
    let start = Date()
    func tick() {
        evalJSON(wv, probe) { r in
            if isInjected(r) || Date().timeIntervalSince(start) > deadline { done(r) } else { after(0.1) { tick() } }
        }
    }
    tick()
}

// MARK: - extension loading (all behind #available)

@available(macOS 15.4, *)
func loadExtension(dir: String, name: String, controller: WKWebExtensionController, grantHosts: Bool, _ done: @escaping (WKWebExtensionContext?) -> Void) {
    let start = Date()
    Task { @MainActor in
        let ext: WKWebExtension
        do { ext = try await WKWebExtension(resourceBaseURL: URL(fileURLWithPath: dir, isDirectory: true)) }
        catch { log("ext.loadFailed", ["name": name, "error": String(describing: error)]); done(nil); return }
        log("ext.parsed", ["name": ext.displayName ?? name, "version": ext.version ?? "-", "mv": ext.manifestVersion,
                           "ms": Int(Date().timeIntervalSince(start) * 1000),
                           "errors": ext.errors.map(\.localizedDescription).joined(separator: " | "),
                           "background": ext.hasBackgroundContent, "persistentBackground": ext.hasPersistentBackgroundContent,
                           "injectedContent": ext.hasInjectedContent, "options": ext.hasOptionsPage, "commands": ext.hasCommands,
                           "contentRules": ext.hasContentModificationRules,
                           "requestedPermissions": ext.requestedPermissions.map(\.rawValue).sorted().joined(separator: ","),
                           "optionalPermissions": ext.optionalPermissions.map(\.rawValue).sorted().joined(separator: ","),
                           "requestedPatterns": ext.requestedPermissionMatchPatterns.map(\.string).sorted().joined(separator: ","),
                           "optionalPatterns": ext.optionalPermissionMatchPatterns.map(\.string).sorted().joined(separator: ",")])
        let ctx = WKWebExtensionContext(for: ext)
        ctx.uniqueIdentifier = "m6-\(name)"
        ctx.isInspectable = true
        ctx.hasAccessToPrivateData = privateData
        // Treat the manifest's `permissions` as granted at install, the way every
        // browser does; host access is the thing the spike varies.
        for p in ext.requestedPermissions { ctx.setPermissionStatus(.grantedExplicitly, for: p) }
        if grantHosts {
            for pat in ext.requestedPermissionMatchPatterns { ctx.setPermissionStatus(.grantedExplicitly, for: pat) }
        }
        do {
            let t = Date()
            try controller.load(ctx)
            log("ext.loaded", ["name": name, "ms": Int(Date().timeIntervalSince(t) * 1000), "loaded": ctx.isLoaded,
                               "errors": ctx.errors.map(\.localizedDescription).joined(separator: " | "),
                               "baseURL": ctx.baseURL.absoluteString,
                               "hostAccessToFixture": ctx.hasAccess(to: fixture),
                               "fixtureStatus": ctx.permissionStatus(for: fixture).rawValue,
                               "allURLs": ctx.hasAccessToAllURLs, "allHosts": ctx.hasAccessToAllHosts,
                               "commands": ctx.commands.map { "\($0.id)[\($0.activationKey ?? "-")/\($0.modifierFlags.rawValue)]" }.joined(separator: ","),
                               "optionsPage": ctx.optionsPageURL?.absoluteString ?? "-"])
            contexts[name] = ctx
            // Non-persistent background content (a service worker) is started
            // by WebKit on demand. Whether "on demand" includes a content
            // script's first runtime.sendMessage is the question WAKE_BG=0/1
            // answers: 1 asks for it up front, the way a browser would at launch.
            if (env["WAKE_BG"] ?? "1") == "1" {
                let bg = Date()
                ctx.loadBackgroundContent { error in
                    log("ext.backgroundLoaded", ["name": name, "ms": Int(Date().timeIntervalSince(bg) * 1000), "error": error.map { String(describing: $0) } ?? "-"])
                    done(ctx)
                }
            } else {
                done(ctx)
            }
        } catch {
            log("ext.loadThrew", ["name": name, "error": String(describing: error)])
            done(nil)
        }
    }
}

@available(macOS 15.4, *)
func makeExtensionSetup() -> (WKWebExtensionController, WKWebViewConfiguration, Coordinator, Win) {
    let cfg = WKWebExtensionController.Configuration.nonPersistent()
    let controller = WKWebExtensionController(configuration: cfg)
    let win = Win(frame: NSRect(x: 0, y: 0, width: lane.width, height: lane.height))
    let coord = Coordinator(win: win)
    controller.delegate = coord
    let wc = WKWebViewConfiguration()
    wc.websiteDataStore = paneStore()
    wc.webExtensionController = controller
    extController = controller; coordinator = coord; winModel = win
    return (controller, wc, coord, win)
}

@available(macOS 15.4, *)
func registerPanes(_ controller: WKWebExtensionController, _ win: Win) {
    for (i, wv) in webViews.enumerated() { let t = Tab(webView: wv, index: i); t.win = win; win.tabs.append(t) }
    controller.didOpenWindow(win)
    for t in win.tabs { controller.didOpenTab(t) }
    controller.didFocusWindow(win)
    if let first = win.tabs.first { controller.didActivateTab(first, previousActiveTab: nil) }
}

// MARK: - phases

func runBaseline() {
    let wc = WKWebViewConfiguration()
    wc.websiteDataStore = paneStore()
    for i in 0..<paneCount { _ = makePane(i, configuration: wc) }
    loadAll(fixture) {
        after(settle) {
            recordMemory("baseline: \(paneCount) panes, no extension controller")
            snapshot(webViews[0], "baseline-pane0.png") { finish(0) }
        }
    }
}

func runExt() {
    guard #available(macOS 15.4, *) else { log("unavailable", ["os": ProcessInfo.processInfo.operatingSystemVersionString]); finish(3) }
    let (controller, wc, _, win) = makeExtensionSetup()
    loadExtension(dir: env["EXT_DIR"] ?? "", name: "darkreader", controller: controller, grantHosts: grant) { ctx in
        guard ctx != nil else { finish(4) }
        recordMemory("ext: controller + Dark Reader loaded, 0 panes")
        for i in 0..<paneCount { _ = makePane(i, configuration: wc) }
        registerPanes(controller, win)
        loadAll(fixture) {
            waitForInjection(webViews[0], probe: darkReaderProbe, isInjected: { ($0 as? [String: Any])?["mode"] is String }, deadline: 10) { r in
                log("inject.pane0", ["result": String(describing: r ?? "nil")])
                report["injection"] = r
                after(settle) {
                    recordMemory("ext: \(paneCount) panes, Dark Reader granted=\(grant)")
                    snapshot(webViews[0], "ext-pane0.png") { finish(0) }
                }
            }
        }
    }
}

func runProbe() {
    guard #available(macOS 15.4, *) else { log("unavailable"); finish(3) }
    let (controller, wc, coord, win) = makeExtensionSetup()
    let extDir = env["EXT_DIR"] ?? ""
    loadExtension(dir: extDir, name: URL(fileURLWithPath: extDir).lastPathComponent, controller: controller, grantHosts: grant) { ctx in
        guard let ctx = ctx else { finish(4) }
        let wv = makePane(0, configuration: wc)
        registerPanes(controller, win)
        let tab = win.tabs[0]
        log("ext.beforeLoad", ["hasInjectedContentForFixture": ctx.hasInjectedContent(for: fixture), "hasAccess": ctx.hasAccess(to: fixture, in: tab),
                               "statusInTab": ctx.permissionStatus(for: fixture, in: tab).rawValue])
        let loadStart = Date()
        loadAll(fixture) {
            waitForInjection(wv, probe: darkReaderProbe, isInjected: { d in let d = d as? [String: Any]; return d?["mode"] is String || d?["m6bg"] is String }, deadline: 10) { r in
                log("inject.result", ["msSinceLoadStart": Int(Date().timeIntervalSince(loadStart) * 1000), "result": String(describing: r ?? "nil"),
                                      "contextErrors": ctx.errors.map(\.localizedDescription).joined(separator: " | ")])
                report["injection"] = r
                // The browser action: what is there to draw, and what the popup wants.
                let action = ctx.action(for: tab)
                let icon = action?.icon(for: CGSize(width: 16, height: 16))
                var a: [String: Any] = ["exists": action != nil]
                if let action = action {
                    a["label"] = action.label; a["badge"] = action.badgeText; a["enabled"] = action.isEnabled
                    a["presentsPopup"] = action.presentsPopup; a["icon16"] = icon.map { NSStringFromSize($0.size) } ?? "nil"
                    a["menuItems"] = action.menuItems.map(\.title)
                    if let icon = icon, let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: outDir.appendingPathComponent("action-icon.png"))
                    }
                }
                a["contextMenuItems"] = ctx.menuItems(for: tab).map(\.title)
                report["action"] = a
                log("action", a)
                guard let action = action, action.presentsPopup else { snapshot(wv, "probe-pane0.png") { finish(0) }; return }

                coord.onPopup = { action in
                    guard let popup = action.popupWebView else { finish(0) }
                    // Give WebKit a host for it the way a browser would: the popover, anchored in the pane.
                    if let popover = action.popupPopover {
                        popover.show(relativeTo: NSRect(x: lane.width - 40, y: lane.height - 10, width: 24, height: 24), of: wv, preferredEdge: .minY)
                        log("popup.shownInPopover", ["contentSize": NSStringFromSize(popover.contentSize)])
                    }
                    func measure(_ n: Int) {
                        evalJSON(popup, "({ w: document.documentElement.scrollWidth, h: document.documentElement.scrollHeight, bodyW: getComputedStyle(document.body).width, bodyH: getComputedStyle(document.body).height, minW: getComputedStyle(document.body).minWidth, innerWidth: innerWidth, innerHeight: innerHeight, title: document.title, url: location.href, ready: document.readyState })") { r in
                            let d = r as? [String: Any]
                            let settled = (d?["ready"] as? String) == "complete" && ((d?["h"] as? Int) ?? 0) > 50
                            if settled || n > 40 {
                                var p: [String: Any] = ["dom": r ?? "nil", "webViewFrame": NSStringFromRect(popup.frame), "popoverSize": action.popupPopover.map { NSStringFromSize($0.contentSize) } ?? "-", "fitsLane656": ((d?["w"] as? Int) ?? 9999) <= 656]
                                p["polls"] = n
                                report["popup"] = p
                                log("popup.measured", p)
                                after(1.0) {
                                    snapshot(popup, "popup.png") {
                                        snapshot(wv, "probe-pane0.png") {
                                            action.closePopup()
                                            // Commands: does the extension's keyboard shortcut reach it?
                                            let cmds = ctx.commands.map { ["id": $0.id, "title": $0.title, "key": $0.activationKey ?? "", "mods": $0.modifierFlags.rawValue, "menuItem": $0.menuItem.title] }
                                            report["commands"] = cmds
                                            log("commands", ["count": cmds.count, "list": cmds.map { "\($0["id"]!)=\($0["key"]!)" }.joined(separator: ",")])
                                            if let toggle = ctx.commands.first(where: { $0.id == "toggle" }), let key = toggle.activationKey {
                                                let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: toggle.modifierFlags, timestamp: 0, windowNumber: wv.window?.windowNumber ?? 0, context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
                                                let matched = ctx.command(for: ev)?.id ?? "nil"
                                                let handled = ctx.performCommand(for: ev)
                                                log("command.toggle", ["matched": matched, "handled": handled])
                                                after(1.5) {
                                                    evalJSON(wv, darkReaderProbe) { r2 in
                                                        log("inject.afterToggle", ["result": String(describing: r2 ?? "nil")])
                                                        report["afterToggle"] = r2
                                                        snapshot(wv, "probe-pane0-toggled.png") { recordMemory("probe: 1 pane + popup opened once"); finish(0) }
                                                    }
                                                }
                                            } else { recordMemory("probe: 1 pane + popup opened once"); finish(0) }
                                        }
                                    }
                                }
                            } else { after(0.25) { measure(n + 1) } }
                        }
                    }
                    measure(0)
                }
                log("popup.perform")
                ctx.performAction(for: tab)
                after(15) { if report["popup"] == nil { log("popup.timeout"); finish(5) } }
            }
        }
    }
}

func runRefined() {
    guard #available(macOS 15.4, *) else { log("unavailable"); finish(3) }
    let (controller, wc, _, win) = makeExtensionSetup()
    loadExtension(dir: env["RG_DIR"] ?? "", name: "refined-github", controller: controller, grantHosts: grant) { ctx in
        guard let ctx = ctx else { finish(4) }
        let wv = makePane(0, configuration: wc)
        registerPanes(controller, win)
        let url = URL(string: env["RG_URL"] ?? "https://github.com/ddrscott/max-pane")!
        log("rg.access", ["url": url.absoluteString, "hasAccess": ctx.hasAccess(to: url), "injected": ctx.hasInjectedContent(for: url)])
        loadAll(url) {
            waitForInjection(wv, probe: refinedProbe, isInjected: { (($0 as? [String: Any])?["rgh"] as? Int ?? 0) > 0 }, deadline: 15) { r in
                log("rg.inject", ["result": String(describing: r ?? "nil")])
                report["injection"] = r
                let action = ctx.action(for: win.tabs[0])
                log("rg.action", ["exists": action != nil, "label": action?.label ?? "-", "presentsPopup": action?.presentsPopup ?? false, "menuItems": action?.menuItems.map(\.title).joined(separator: ",") ?? "-"])
                after(settle) {
                    recordMemory("rg: 1 pane on github.com, Refined GitHub")
                    snapshot(wv, "rg-pane0.png") { finish(0) }
                }
            }
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        log("start", ["phase": phase, "panes": paneCount, "grant": grant, "store": persistentStore ? "persistent" : "nonPersistent", "privateData": privateData, "fixture": fixture.absoluteString, "baselineWebKitPids": baselinePids.count])
        switch phase {
        case "baseline": runBaseline()
        case "ext": runExt()
        case "probe": runProbe()
        case "rg": runRefined()
        default: log("badPhase"); finish(2)
        }
        after(180) { log("watchdog"); finish(9) }
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()
