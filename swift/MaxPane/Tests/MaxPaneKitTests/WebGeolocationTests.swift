import AppKit
import CoreLocation
import Testing
import WebKit
@testable import MaxPaneKit

/// `navigator.geolocation`, proven in real WebKit rather than argued.
///
/// Bare WebKit never answers a page's `getCurrentPosition` on macOS — measured
/// before this shim existed: seven seconds, no callback, the page's own
/// `timeout` never firing — so everything a page sees of it here is the
/// shim's. A loopback site serves the page, as `WebNotificationTests` does;
/// the centre reads a stub in place of `CLLocationManager`, which has no TCC
/// identity in a process that is not an app bundle and whose prompt no test
/// can answer; and the sheet is answered through the method its buttons call.
@Suite("web geolocation, in real WebKit", .serialized)
@MainActor
struct WebGeolocationTests {
    @Test("the shape a page reads; Esc is PERMISSION_DENIED and remembers nothing; a remembered BLOCK survives a reload")
    func deniedIsRemembered() async throws {
        try await GeolocationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            #expect(await f.js(web, "shape()") as? String == "true,function,function,function,[object Geolocation]")

            // Esc: code 1, nothing in the ledger, CoreLocation never touched.
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .cancelled)
            #expect(await f.eventually { await f.events(web).contains("err:1:true:true") })
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .geolocation) == nil)
            #expect(f.stub.authorizationRequests == 0 && f.stub.starts.isEmpty)

            // BLOCK with the box ticked: denied, in the ledger under this jar.
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .capture(allowed: false, remember: true))
            #expect(await f.eventually { await f.events(web).filter { $0.hasPrefix("err:1") }.count == 2 })
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .geolocation) == false)

            // A reload asks again and is refused without a sheet.
            try await f.reload(web)
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("err:1:true:true") })
            #expect(f.controller.askSheet == nil)
            #expect(f.stub.starts.isEmpty)
        }
    }

    @Test("two calls share one sheet; ALLOW asks macOS once, starts the manager, and the stub's coordinates reach both; a watch, a cached fix, a timeout, and a pane closing")
    func grantedRoundTrip() async throws {
        try await GeolocationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)

            // Two questions from the same origin while the sheet is up are one
            // sheet, and one answer settles both.
            #expect(await f.js(web, "get(); get(); 1") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            #expect(await f.eventually { f.controller.geolocationAsks.values.first?.count == 2 })
            f.controller.finishAsk(with: .capture(allowed: true, remember: true))
            #expect(f.store.sitePermission(dataStoreId: f.controller.dataStoreId, origin: f.site.origin, feature: .geolocation) == true)
            // macOS is asked at the first yes, and the manager waits on it.
            #expect(await f.eventually { f.stub.authorizationRequests == 1 })
            #expect(f.stub.starts.isEmpty)
            #expect(f.center.waiting == 2)
            f.stub.grant()
            #expect(f.stub.starts == [false])
            #expect(f.center.isRunning)
            f.stub.deliver(LocationFix(latitude: 51.5, longitude: -0.12, accuracy: 20))
            #expect(await f.eventually { await f.events(web).filter { $0 == "ok:51.5,-0.12" }.count == 2 })
            #expect(await f.events(web).contains("proto:true:true"))
            // Nothing left waiting, so the manager stops.
            #expect(f.center.waiting == 0 && !f.center.isRunning && f.stub.stops == 1)
            #expect(f.controller.askSheet == nil)

            // Remembered: a reload asks without a sheet. A `maximumAge` the
            // last fix satisfies is answered without waking the manager.
            try await f.reload(web)
            #expect(await f.js(web, "get({ maximumAge: 60000 })") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("ok:51.5,-0.12") })
            #expect(f.controller.askSheet == nil)
            #expect(f.stub.starts.count == 1 && f.stub.authorizationRequests == 1)

            // The default `maximumAge` of 0 wants a fresh one, with high accuracy.
            #expect(await f.js(web, "get({ enableHighAccuracy: true })") as? Int == 1)
            #expect(await f.eventually { f.stub.starts.count == 2 })
            #expect(f.stub.starts.last == true)
            f.stub.deliver(LocationFix(latitude: 48.85, longitude: 2.35, accuracy: 5))
            #expect(await f.eventually { await f.events(web).contains("ok:48.85,2.35") })
            #expect(f.stub.stops == 2)

            // A watch hears every fix and stops the manager when it is cleared.
            #expect(await f.js(web, "watch()") as? Int != nil)
            #expect(await f.eventually { f.stub.starts.count == 3 })
            f.stub.deliver(LocationFix(latitude: 1, longitude: 1, accuracy: 1))
            #expect(await f.eventually { await f.events(web).contains("watch:1") })
            f.stub.deliver(LocationFix(latitude: 2, longitude: 2, accuracy: 1))
            #expect(await f.eventually { await f.events(web).contains("watch:2") })
            #expect(f.center.isRunning)
            #expect(await f.js(web, "clear()") as? Int == 1)
            #expect(await f.eventually { !f.center.isRunning })
            #expect(f.center.waiting == 0 && f.stub.stops == 3)

            // The page's own `timeout` runs once the yes is in: code 3, and the
            // centre forgets the request.
            #expect(await f.js(web, "get({ timeout: 100 })") as? Int == 1)
            #expect(await f.eventually { await f.events(web).contains("err:3:true:false") })
            #expect(await f.eventually { f.center.waiting == 0 })

            // No fix: code 2, and the one-shot is done with.
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { f.center.waiting == 1 })
            f.stub.fail("no fix")
            #expect(await f.eventually { await f.events(web).contains("err:2:true:false") })
            #expect(f.center.waiting == 0)

            // A pane that closes with a watch up leaves nothing waiting.
            #expect(await f.js(web, "watch()") as? Int != nil)
            #expect(await f.eventually { f.center.isRunning })
            f.controller.tearDown()
            #expect(f.center.waiting == 0 && !f.center.isRunning)
        }
    }

    @Test("refused in System Settings: PERMISSION_DENIED at once, no prompt, no manager")
    func appLevelDenied() async throws {
        try await GeolocationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            f.stub.authorization = .denied
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .capture(allowed: true, remember: false))
            #expect(await f.eventually { await f.events(web).contains("err:1:true:true") })
            #expect(f.stub.authorizationRequests == 0 && f.stub.starts.isEmpty)
            #expect(f.center.waiting == 0)
        }
    }

    @Test("refused at macOS's own prompt: PERMISSION_DENIED, and the request is dropped")
    func refusedAtThePrompt() async throws {
        try await GeolocationFixture.with { f in
            #expect(await f.ready())
            let web = try #require(f.controller.webView)
            #expect(await f.js(web, "get()") as? Int == 1)
            #expect(await f.eventually { f.controller.askSheet != nil })
            f.controller.finishAsk(with: .capture(allowed: true, remember: false))
            #expect(await f.eventually { f.stub.authorizationRequests == 1 })
            f.stub.deny()
            #expect(await f.eventually { await f.events(web).contains("err:1:true:true") })
            #expect(f.stub.starts.isEmpty && f.center.waiting == 0)
        }
    }
}

/// The parts of the shim that need no WebKit.
@Suite("geolocation messages and scripts")
struct WebGeolocationScriptTests {
    @Test("what a page sends is read back as a message, and junk is not")
    func messages() {
        #expect(WebGeolocation.message(["type": "get", "id": 3, "highAccuracy": true, "maximumAge": 500])
            == .request(id: 3, watch: false, highAccuracy: true, maximumAge: 500))
        // -1 is the script's spelling of Infinity: any fix will do.
        #expect(WebGeolocation.message(["type": "watch", "id": 4, "maximumAge": -1])
            == .request(id: 4, watch: true, highAccuracy: false, maximumAge: nil))
        #expect(WebGeolocation.message(["type": "clear", "id": 6]) == .clear(id: 6))
        #expect(WebGeolocation.message(["type": "dance", "id": 1]) == nil)
        #expect(WebGeolocation.message("get") == nil)
    }

    @Test("a fix is JSON the script's position() takes, with null for what CoreLocation did not know")
    func fixJSON() {
        let fix = LocationFix(latitude: 1.5, longitude: -2, accuracy: 10, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(fix.json == #"{"accuracy":10,"altitude":null,"altitudeAccuracy":null,"heading":null,"latitude":1.5,"longitude":-2,"speed":null,"timestamp":1700000000000}"#)
        // CoreLocation says "unknown" with a negative number.
        let unknown = LocationFix(CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 3, longitude: 4), altitude: 100,
            horizontalAccuracy: 30, verticalAccuracy: -1, course: -1, speed: -1, timestamp: Date()))
        #expect(unknown.altitude == nil && unknown.altitudeAccuracy == nil && unknown.heading == nil && unknown.speed == nil)
        #expect(unknown.latitude == 3 && unknown.accuracy == 30)
        #expect(WebGeolocation.failureScript(id: 2, code: 1, message: "it's \"off\"")
            == #"window.__maxpaneGeolocation && window.__maxpaneGeolocation.failure(2, 1, "it's \"off\""); 0"#)
        #expect(WebGeolocation.source.hasPrefix(WebGeolocation.header))
    }
}

// MARK: - the fixture

@MainActor
final class GeolocationFixture {
    let site: LocalSite
    let dir: URL
    let store: StripStore
    let stub: StubLocationSource
    let center: WebGeolocationCenter
    let controller: WebPaneController
    let window: NSWindow

    /// Run `body` against a fresh fixture and always take it down. Skipped
    /// outside `./scripts/test.sh` for the reason every real-WebKit suite is.
    static func with(_ body: (GeolocationFixture) async throws -> Void) async throws {
        guard !Profile.current.dataSalt.isEmpty else {
            print("SKIPPED web geolocation in real WebKit: run through ./scripts/test.sh, which names a profile")
            return
        }
        let fixture = try await GeolocationFixture()
        do {
            try await body(fixture)
        } catch {
            fixture.tearDown()
            throw error
        }
        fixture.tearDown()
    }

    private init() async throws {
        site = try await LocalSite(pages: ["/page": Self.page])
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-geo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path)
        stub = StubLocationSource()
        center = WebGeolocationCenter(source: stub)
        try store.newWebLane(url: site.origin + "/page", near: nil)
        let lane = try #require(store.state.lanes.first)
        let pane = try #require(lane.panes.first)
        controller = WebPaneController(
            pane: pane, lane: lane, store: store, config: Config(),
            notifications: WebNotificationCenter(poster: RecordedNotificationPoster()), geolocation: center)
        // Off every screen, never key: a test has no business putting windows
        // in front of someone.
        window = NSWindow(
            contentRect: NSRect(x: -8000, y: 200, width: 600, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1000))
        controller.view.frame = NSRect(x: 0, y: 0, width: 600, height: 1000)
        window.contentView?.addSubview(controller.view)
        controller.popupParent = { [weak window] in window }
    }

    func js(_ view: WKWebView?, _ script: String) async -> Any? {
        guard let view else { return nil }
        return try? await view.evaluateJavaScript(script)
    }

    func events(_ view: WKWebView) async -> [String] {
        (await js(view, "events.slice()") as? [String]) ?? []
    }

    func ready() async -> Bool {
        await eventually {
            await js(controller.webView, "document.readyState === 'complete' && typeof get === 'function' ? 1 : 0") as? Int == 1
        }
    }

    /// Reload, and wait for the new document: its `events` starts empty.
    func reload(_ view: WKWebView) async throws {
        _ = await js(view, "events.push('reloading'); location.reload(); 1")
        #expect(await eventually { await js(view, "typeof events !== 'undefined' && events.length === 0 && typeof get === 'function' ? 1 : 0") as? Int == 1 })
    }

    func eventually(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return await condition()
    }

    func tearDown() {
        controller.tearDown()
        window.orderOut(nil)
        site.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every event the page hears, and the calls a site makes: a one-shot with
    /// options, a watch, and clearing it. The error line carries the code, the
    /// `instanceof` a page's `catch` may check, and the constant comparison a
    /// page's `switch` makes.
    static let page = """
        <!doctype html><title>Where</title>
        <script>
          window.events = [];
          function shape() {
            return [navigator.geolocation instanceof Geolocation, typeof navigator.geolocation.getCurrentPosition,
                    typeof navigator.geolocation.watchPosition, typeof navigator.geolocation.clearWatch,
                    Object.prototype.toString.call(navigator.geolocation)].join(',');
          }
          function onError(prefix) {
            return e => events.push(prefix + e.code + ':' + (e instanceof GeolocationPositionError) + ':' + (e.code === e.PERMISSION_DENIED));
          }
          function get(options) {
            navigator.geolocation.getCurrentPosition(p => {
              events.push('ok:' + p.coords.latitude + ',' + p.coords.longitude);
              events.push('proto:' + (p instanceof GeolocationPosition) + ':' + (p.coords instanceof GeolocationCoordinates));
            }, onError('err:'), options || {});
            return 1;
          }
          function watch() {
            window.watchId = navigator.geolocation.watchPosition(p => events.push('watch:' + p.coords.latitude), onError('watcherr:'));
            return watchId;
          }
          function clear() { navigator.geolocation.clearWatch(watchId); return 1; }
        </script>
        <body>where</body>
        """
}

/// Stands in for `CLLocationManager`. Told what macOS would say, and records
/// what was asked of it.
@MainActor
final class StubLocationSource: LocationSource {
    var authorization: LocationAuthorization = .notDetermined
    var onAuthorization: ((LocationAuthorization) -> Void)?
    var onFix: ((LocationFix) -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var authorizationRequests = 0
    /// One entry per `start`, with its `highAccuracy`.
    private(set) var starts: [Bool] = []
    private(set) var stops = 0

    func requestAuthorization() { authorizationRequests += 1 }
    func start(highAccuracy: Bool) { starts.append(highAccuracy) }
    func stop() { stops += 1 }

    /// The person clicked Allow on macOS's prompt.
    func grant() {
        authorization = .allowed
        onAuthorization?(.allowed)
    }

    /// The person clicked Don't Allow.
    func deny() {
        authorization = .denied
        onAuthorization?(.denied)
    }

    func deliver(_ fix: LocationFix) { onFix?(fix) }
    func fail(_ message: String) { onFailure?(message) }
}
