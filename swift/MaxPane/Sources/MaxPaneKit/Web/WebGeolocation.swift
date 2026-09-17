import CoreLocation
import Foundation
import WebKit

/// `navigator.geolocation`, answered by the shell.
///
/// **Measured, not assumed:** a bare `WKWebView` on macOS 26 never answers a
/// page's `getCurrentPosition` at all. Not `PERMISSION_DENIED`, not
/// `TIMEOUT` — the page's own `timeout` option never fires either, because
/// the spec starts that clock only once permission is granted, and WebKit has
/// no public way for the app to grant it. (`_WKUIDelegate` has a private
/// `requestGeolocationPermissionForOrigin:` that Safari implements; it is not
/// API.) A TCC grant to the app changes nothing about that: WebKit never asks
/// the app, so it never reaches CoreLocation. Maps, weather and store-locator
/// pages therefore sat on a spinner forever, and this file exists because a
/// page-world shim is the only route rather than the convenient one.
///
/// So the API is a user script, in every frame, before the page runs — the
/// `WebNotifications` pattern — and the pane is the location provider behind
/// it:
///
/// - **The shim replaces `navigator.geolocation`** with an object built on
///   WebKit's own `Geolocation.prototype`, and its positions and errors on
///   `GeolocationPosition`, `GeolocationCoordinates` and
///   `GeolocationPositionError`'s, so a page's `instanceof` and
///   `Object.prototype.toString` read as they would in Safari. Every call
///   posts to the shell with an id; `clearWatch` posts the id back.
/// - **Every request asks the person first**, through the pane's sheet — the
///   same per-origin, per-jar question the camera asks, remembered in the
///   same ledger table under `geolocation`. Only after a yes does the centre
///   touch `CLLocationManager`, which is when macOS's own prompt appears, the
///   first time, with `NSLocationUsageDescription`'s words. A no at either
///   level is `PERMISSION_DENIED` (code 1) at once; Esc is "not now", also
///   code 1, and nothing is remembered.
/// - **One `CLLocationManager` for the app**, in `WebGeolocationCenter`. A fix
///   fans out to every waiting request and every live watch, the manager stops
///   when nothing is waiting, and the last fix answers a `maximumAge` without
///   starting it again.
/// - **`timeout` runs in the page**, armed by the shell when the person has
///   said yes (`armed`), which is where the spec starts it; a watch re-arms
///   after every fix.
enum WebGeolocation {
    /// The name both the handler and the script agree on.
    static let channel = "maxpaneGeolocation"

    /// The property on `window` the shell speaks to the script through, and
    /// the guard against the script running twice in one document.
    static let marker = "__maxpaneGeolocation"

    /// `GeolocationPositionError` codes, as the spec numbers them.
    enum Code {
        static let permissionDenied = 1
        static let positionUnavailable = 2
        static let timeout = 3
    }

    /// What a page sent.
    enum Message: Equatable {
        /// `getCurrentPosition` (`watch: false`) or `watchPosition`; `id` is
        /// the callback pair to answer. `maximumAge` is in milliseconds, or
        /// nil for the spec's `Infinity` — any fix will do.
        case request(id: Int, watch: Bool, highAccuracy: Bool, maximumAge: Double?)
        /// `clearWatch(id)`.
        case clear(id: Int)
    }

    static func message(_ body: Any) -> Message? {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String,
              let id = (dict["id"] as? NSNumber)?.intValue
        else { return nil }
        switch type {
        case "get", "watch":
            let age = (dict["maximumAge"] as? NSNumber)?.doubleValue
            return .request(
                id: id, watch: type == "watch",
                highAccuracy: (dict["highAccuracy"] as? NSNumber)?.boolValue ?? false,
                maximumAge: age.flatMap { $0 < 0 || !$0.isFinite ? nil : $0 })
        case "clear":
            return .clear(id: id)
        default:
            return nil
        }
    }

    // MARK: - what the shell says back

    /// A position for request `id`.
    static func positionScript(id: Int, fix: LocationFix) -> String {
        "window.\(marker) && window.\(marker).position(\(id), \(fix.json)); 0"
    }

    /// An error for request `id`: one of `Code`, and the message a page's
    /// error callback reads.
    static func failureScript(id: Int, code: Int, message: String) -> String {
        "window.\(marker) && window.\(marker).failure(\(id), \(code), \(quoted(message))); 0"
    }

    /// The person said yes; the page's `timeout` clock starts now.
    static func armedScript(id: Int) -> String {
        "window.\(marker) && window.\(marker).armed(\(id)); 0"
    }

    static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: - the script

    /// The first line, so an installed copy can be recognised.
    static let header = "/* \(marker) */"

    static var source: String { header + "\n" + body }

    private static let body = #"""
        (() => {
          if (Object.prototype.hasOwnProperty.call(window, '\#(marker)')) return;
          const CHANNEL = '\#(channel)';
          let nextId = 1;
          const live = new Map();   // id → { success, error, watch, timeout, timer }
          const later = (fn) => setTimeout(fn, 0);
          const post = (message) => {
            try { window.webkit.messageHandlers[CHANNEL].postMessage(message); return true; } catch (e) { return false; }
          };
          const own = (values) => {
            const props = {};
            for (const name of Object.keys(values)) props[name] = { value: values[name], enumerable: true };
            return props;
          };
          const proto = (name) => (typeof window[name] === 'function' ? window[name].prototype : Object.prototype);
          const makeError = (code, message) => Object.create(proto('GeolocationPositionError'), Object.assign(
            own({ code, message }),
            { PERMISSION_DENIED: { value: 1 }, POSITION_UNAVAILABLE: { value: 2 }, TIMEOUT: { value: 3 } }));
          const makePosition = (fix) => {
            const values = {
              latitude: fix.latitude, longitude: fix.longitude, accuracy: fix.accuracy,
              altitude: fix.altitude, altitudeAccuracy: fix.altitudeAccuracy, heading: fix.heading, speed: fix.speed,
            };
            const coords = Object.create(proto('GeolocationCoordinates'), own(Object.assign({}, values, {
              toJSON() { return Object.assign({}, values); },
            })));
            return Object.create(proto('GeolocationPosition'), own({
              coords, timestamp: fix.timestamp,
              toJSON() { return { coords: coords.toJSON(), timestamp: fix.timestamp }; },
            }));
          };
          const clamp = (value, fallback) => {
            if (value === undefined || value === null) return fallback;
            const n = Number(value);
            if (Number.isNaN(n)) return fallback;
            return n < 0 ? 0 : n;
          };
          const call = (fn, target, arg) => {
            if (typeof fn !== 'function') return;
            try { fn.call(target, arg); } catch (e) { later(() => { throw e; }); }
          };
          const disarm = (entry) => { if (entry.timer !== null) { clearTimeout(entry.timer); entry.timer = null; } };
          const arm = (id, entry) => {
            disarm(entry);
            if (!Number.isFinite(entry.timeout)) return;
            entry.timer = setTimeout(() => {
              entry.timer = null;
              if (!entry.watch) { live.delete(id); post({ type: 'clear', id }); }
              call(entry.error, null, makeError(3, 'Timeout expired'));
            }, entry.timeout);
          };
          const request = (name, success, error, options, watch) => {
            if (typeof success !== 'function') {
              throw new TypeError("Failed to execute '" + name + "' on 'Geolocation': parameter 1 is not of type 'PositionCallback'.");
            }
            options = options && typeof options === 'object' ? options : {};
            const id = nextId++;
            const entry = {
              success, error: typeof error === 'function' ? error : null, watch,
              timeout: clamp(options.timeout, Infinity), timer: null,
            };
            live.set(id, entry);
            const maximumAge = clamp(options.maximumAge, 0);
            const sent = post({
              type: watch ? 'watch' : 'get', id, highAccuracy: !!options.enableHighAccuracy,
              maximumAge: Number.isFinite(maximumAge) ? maximumAge : -1,
            });
            if (!sent) {
              live.delete(id);
              later(() => call(entry.error, null, makeError(2, 'Position unavailable')));
            }
            return id;
          };

          const geolocation = Object.create(proto('Geolocation'), {
            getCurrentPosition: { value: function getCurrentPosition(success, error, options) {
              request('getCurrentPosition', success, error, options, false);
            }, writable: true, configurable: true },
            watchPosition: { value: function watchPosition(success, error, options) {
              return request('watchPosition', success, error, options, true);
            }, writable: true, configurable: true },
            clearWatch: { value: function clearWatch(id) {
              const entry = live.get(id);
              if (!entry || !entry.watch) return;
              disarm(entry);
              live.delete(id);
              post({ type: 'clear', id });
            }, writable: true, configurable: true },
          });

          const shell = Object.freeze({
            armed(id) {
              const entry = live.get(id);
              if (entry) arm(id, entry);
            },
            position(id, fix) {
              const entry = live.get(id);
              if (!entry) return;
              if (entry.watch) arm(id, entry); else { disarm(entry); live.delete(id); }
              call(entry.success, null, makePosition(fix));
            },
            failure(id, code, message) {
              const entry = live.get(id);
              if (!entry) return;
              // A denial ends a watch; anything else leaves it watching, as a
              // browser does when a fix goes briefly unavailable.
              if (!entry.watch || code === 1) { disarm(entry); live.delete(id); }
              call(entry.error, null, makeError(code, message));
            },
          });
          Object.defineProperty(window, '\#(marker)', { value: shell });
          Object.defineProperty(navigator, 'geolocation', { value: geolocation, writable: false, configurable: true, enumerable: true });
        })();
        """#

    // MARK: - installing

    /// Install the script and the handler on a web view. Idempotent for the
    /// reason `WebNotifications.install` is.
    @MainActor
    static func install(on webView: WKWebView, handler: WKScriptMessageHandler) {
        let content = webView.configuration.userContentController
        content.removeScriptMessageHandler(forName: channel)
        content.add(handler, name: channel)
        guard !content.userScripts.contains(where: { $0.source == source }) else { return }
        // Every frame: an embedded map asks from its own frame.
        content.addUserScript(WKUserScript(
            source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    @MainActor
    static func remove(from webView: WKWebView) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
    }
}

// MARK: - a fix

/// One position, in the shape `GeolocationCoordinates` reads. `timestamp` is
/// milliseconds since the epoch, as `GeolocationPosition.timestamp` is.
struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var altitude: Double?
    var altitudeAccuracy: Double?
    var heading: Double?
    var speed: Double?
    var timestamp: Date

    init(latitude: Double, longitude: Double, accuracy: Double, altitude: Double? = nil,
         altitudeAccuracy: Double? = nil, heading: Double? = nil, speed: Double? = nil,
         timestamp: Date = Date()) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.altitudeAccuracy = altitudeAccuracy
        self.heading = heading
        self.speed = speed
        self.timestamp = timestamp
    }

    /// `CLLocation`'s negative values mean "unknown", which the web API spells
    /// `null`.
    init(_ location: CLLocation) {
        let positive = { (value: Double) -> Double? in value >= 0 ? value : nil }
        self.init(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            accuracy: max(0, location.horizontalAccuracy),
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            altitudeAccuracy: positive(location.verticalAccuracy),
            heading: positive(location.course), speed: positive(location.speed),
            timestamp: location.timestamp)
    }

    var age: TimeInterval { Date().timeIntervalSince(timestamp) }

    /// As the script's `position()` takes it.
    var json: String {
        let number = { (value: Double?) -> Any in value.map { $0 as Any } ?? NSNull() }
        let object: [String: Any] = [
            "latitude": latitude, "longitude": longitude, "accuracy": accuracy,
            "altitude": number(altitude), "altitudeAccuracy": number(altitudeAccuracy),
            "heading": number(heading), "speed": number(speed),
            "timestamp": (timestamp.timeIntervalSince1970 * 1000).rounded(),
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - the source

/// Whether this app may know where the Mac is, as far as macOS is concerned.
enum LocationAuthorization: Equatable, Sendable {
    /// Never asked. Asking puts up macOS's prompt with the usage string.
    case notDetermined
    /// Refused in System Settings, restricted, or Location Services off for
    /// the whole machine. Reported to the page at once as `PERMISSION_DENIED`.
    case denied
    case allowed
}

/// The seam between the centre and CoreLocation.
///
/// A `CLLocationManager` in a process that is not an app bundle has no TCC
/// identity to be granted to, and its prompt cannot be answered from a test,
/// so a test hands the centre a stub that is told what to say.
@MainActor
protocol LocationSource: AnyObject {
    var authorization: LocationAuthorization { get }
    /// Where the source reports: an authorization change, a fix, a failure.
    var onAuthorization: ((LocationAuthorization) -> Void)? { get set }
    var onFix: ((LocationFix) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// Put up macOS's prompt. Answered through `onAuthorization`.
    func requestAuthorization()
    func start(highAccuracy: Bool)
    func stop()
}

/// The real thing: one `CLLocationManager`, made on the main thread so its
/// delegate is called there.
@MainActor
final class CoreLocationSource: NSObject, LocationSource, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var onAuthorization: ((LocationAuthorization) -> Void)?
    var onFix: ((LocationFix) -> Void)?
    var onFailure: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuthorization { Self.map(manager.authorizationStatus) }

    func requestAuthorization() {
        // Without `NSLocationUsageDescription` in Info.plist this is where the
        // process would die, with no prompt and no log line; the key is there.
        manager.requestWhenInUseAuthorization()
    }

    func start(highAccuracy: Bool) {
        manager.desiredAccuracy = highAccuracy ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted, .denied: return .denied
        case .authorizedAlways, .authorized: return .allowed
        @unknown default: return .denied
        }
    }

    // The delegate is called on the thread the manager was made on, which is
    // the main thread; the protocol does not say so in types.
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { onAuthorization?(Self.map(status)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        let fix = LocationFix(last)
        MainActor.assumeIsolated { onFix?(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        let message = error.localizedDescription
        MainActor.assumeIsolated {
            if denied { onAuthorization?(.denied) } else { onFailure?(message) }
        }
    }
}

// MARK: - the centre

/// Every request a page has made that the person has said yes to, and the one
/// location manager that answers them.
///
/// One for the app, because Location Services is one thing and the fix is the
/// same for every lane. A request arrives here only after the pane's ask has
/// been answered yes (`WebPaneGeolocation`); nothing here asks the person.
@MainActor
public final class WebGeolocationCenter {
    public static let shared = WebGeolocationCenter(source: CoreLocationSource())

    /// A `getCurrentPosition` waiting for a fix, or a `watchPosition` that
    /// wants every one.
    struct Request {
        let paneId: String
        let id: Int
        let frame: WKFrameInfo
        weak var webView: WKWebView?
        let watch: Bool
        let highAccuracy: Bool
    }

    private struct Key: Hashable {
        let paneId: String
        let id: Int
    }

    let source: LocationSource
    private var requests: [Key: Request] = [:]
    private var order: [Key] = []
    /// Whether `start` has been called and `stop` has not.
    private(set) var isRunning = false
    /// macOS's prompt is up. One prompt for however many requests arrive
    /// while it is; the answer runs them all.
    private var awaitingAuthorization = false
    /// The newest fix, for a `maximumAge` that it satisfies.
    private(set) var lastFix: LocationFix?

    init(source: LocationSource) {
        self.source = source
        source.onAuthorization = { [weak self] status in self?.authorizationChanged(status) }
        source.onFix = { [weak self] fix in self?.received(fix) }
        source.onFailure = { [weak self] message in self?.failed(message) }
    }

    /// The person said yes to this origin. Answer from the last fix if it is
    /// young enough, refuse at once if macOS has refused the app, otherwise
    /// wait for CoreLocation — asking macOS first if it has never been asked.
    func request(_ request: Request, maximumAge: Double?) {
        switch source.authorization {
        case .denied:
            // Promptly, and with the reason: a page that waits on a timeout
            // for a permission that will never come is the failure this
            // replaces, and the person can only fix this one in System
            // Settings.
            Log.debug("geolocation: refused by macOS for pane \(request.paneId); Location Services or the app's grant is off")
            tell(request, WebGeolocation.failureScript(
                id: request.id, code: WebGeolocation.Code.permissionDenied,
                message: "Location Services is off for Max Pane in System Settings › Privacy & Security."))
            return
        case .notDetermined, .allowed:
            break
        }
        tell(request, WebGeolocation.armedScript(id: request.id))
        // A fix young enough for the page's `maximumAge` (nil: any age) answers
        // a one-shot without waking the manager.
        if !request.watch, let fix = lastFix, maximumAge.map({ fix.age * 1000 <= $0 }) ?? true {
            tell(request, WebGeolocation.positionScript(id: request.id, fix: fix))
            return
        }
        let key = Key(paneId: request.paneId, id: request.id)
        if requests[key] == nil { order.append(key) }
        requests[key] = request
        if source.authorization == .notDetermined {
            guard !awaitingAuthorization else { return }
            awaitingAuthorization = true
            Log.debug("geolocation: asking macOS, for pane \(request.paneId)")
            source.requestAuthorization()
        } else {
            run()
        }
    }

    /// `clearWatch`, or a one-shot the page gave up on.
    func clear(paneId: String, id: Int) {
        drop(Key(paneId: paneId, id: id))
        stopIfIdle()
    }

    /// A pane's page is gone: nothing of its is waiting any more.
    func clear(paneId: String) {
        for key in order where key.paneId == paneId { drop(key) }
        stopIfIdle()
    }

    var waiting: Int { requests.count }

    // MARK: - what CoreLocation says

    private func authorizationChanged(_ status: LocationAuthorization) {
        if status != .notDetermined { awaitingAuthorization = false }
        switch status {
        case .allowed:
            run()
        case .denied:
            Log.debug("geolocation: macOS refused; \(requests.count) request(s) told")
            for key in order {
                guard let request = requests[key] else { continue }
                tell(request, WebGeolocation.failureScript(
                    id: request.id, code: WebGeolocation.Code.permissionDenied,
                    message: "Location Services is off for Max Pane in System Settings › Privacy & Security."))
            }
            requests = [:]
            order = []
            stopIfIdle()
        case .notDetermined:
            break
        }
    }

    private func received(_ fix: LocationFix) {
        lastFix = fix
        for key in order {
            guard let request = requests[key] else { continue }
            tell(request, WebGeolocation.positionScript(id: request.id, fix: fix))
            if !request.watch { requests[key] = nil }
        }
        order = order.filter { requests[$0] != nil }
        stopIfIdle()
    }

    private func failed(_ message: String) {
        Log.debug("geolocation: no fix: \(message)")
        for key in order {
            guard let request = requests[key] else { continue }
            tell(request, WebGeolocation.failureScript(
                id: request.id, code: WebGeolocation.Code.positionUnavailable, message: message))
            // A watch keeps watching; a browser's does too.
            if !request.watch { requests[key] = nil }
        }
        order = order.filter { requests[$0] != nil }
        stopIfIdle()
    }

    // MARK: - the manager

    private func run() {
        guard !requests.isEmpty else { return }
        let highAccuracy = requests.values.contains { $0.highAccuracy }
        isRunning = true
        source.start(highAccuracy: highAccuracy)
    }

    private func stopIfIdle() {
        guard requests.isEmpty, isRunning else { return }
        isRunning = false
        source.stop()
    }

    private func drop(_ key: Key) {
        guard requests.removeValue(forKey: key) != nil else { return }
        order.removeAll { $0 == key }
    }

    private func tell(_ request: Request, _ script: String) {
        guard let webView = request.webView else {
            return Log.debug("geolocation: no page left to answer for pane \(request.paneId)")
        }
        webView.evaluateJavaScript(script, in: request.frame, in: .page) { result in
            if case .failure(let error) = result {
                Log.debug("geolocation: answer did not reach pane \(request.paneId): \(error.localizedDescription)")
            }
        }
    }
}
