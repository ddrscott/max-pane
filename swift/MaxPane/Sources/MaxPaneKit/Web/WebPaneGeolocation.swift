import AppKit
import LanedCore
import WebKit

/// The pane's half of `navigator.geolocation`: the per-origin ask, and the
/// hand-off to the centre once the person has said yes. `WebGeolocation` has
/// the argument and the measurement.
extension WebPaneController {

    /// A message from the script, in this pane's page or in a popup over it —
    /// a popup shares its opener's content controller, so its messages arrive
    /// here and are told apart by `message.webView`.
    func geolocationMessage(_ message: WKScriptMessage) {
        guard let kind = WebGeolocation.message(message.body) else { return }
        switch kind {
        case .request(let id, let watch, let highAccuracy, let maximumAge):
            requestPosition(id: id, watch: watch, highAccuracy: highAccuracy, maximumAge: maximumAge, from: message)
        case .clear(let id):
            geolocation.clear(paneId: paneId, id: id)
        }
    }

    /// The question, once per origin per jar, through the sheet the camera
    /// uses — before CoreLocation is ever touched, and even when macOS has
    /// already granted the app, because the app is not the thing that wants to
    /// know where you are.
    private func requestPosition(id: Int, watch: Bool, highAccuracy: Bool, maximumAge: Double?,
                                 from message: WKScriptMessage) {
        let frame = message.frameInfo
        let security = frame.securityOrigin
        let request = WebGeolocationCenter.Request(
            paneId: paneId, id: id, frame: frame, webView: message.webView, watch: watch, highAccuracy: highAccuracy)
        guard let key = AskOrigin.key(scheme: security.protocol, host: security.host, port: Int(security.port)) else {
            // A `file://` page or an opaque origin: nothing to remember an
            // answer about, and a permission that cannot be scoped is one
            // that should not be granted.
            Log.debug("pane \(paneId) refused geolocation to an origin with no host")
            return refusePosition(request, "Only a page with an origin can ask where you are.")
        }
        if let remembered = store.sitePermission(dataStoreId: dataStoreId, origin: key, feature: .geolocation) {
            Log.debug("pane \(paneId) geolocation \(remembered ? "allowed" : "denied") for \(key) (remembered)")
            if remembered {
                geolocation.request(request, maximumAge: maximumAge)
            } else {
                refusePosition(request, "You blocked this site from knowing where you are.")
            }
            return
        }

        // One sheet for an origin, however many calls it makes while the
        // sheet is up: Maps asks once and then watches, and two questions
        // saying the same thing would be the page repeating itself.
        let waiting = (request: request, maximumAge: maximumAge)
        if geolocationAsks[key] != nil {
            geolocationAsks[key]?.append(waiting)
            return
        }
        geolocationAsks[key] = [waiting]

        let prompt = AskPrompt.capture(what: "TO KNOW WHERE YOU ARE")
        let answer: (AskOutcome) -> Void = { [weak self] outcome in
            guard let self else { return }
            let requests = self.geolocationAsks.removeValue(forKey: key) ?? []
            guard case .capture(let allowed, let remember) = outcome else {
                // Esc, ✕, the pane closing: "not now". The page hears
                // PERMISSION_DENIED, as it does from a dismissed prompt in
                // Safari, and may ask again on a later click.
                for waiting in requests { self.refusePosition(waiting.request, "You dismissed the request.") }
                return
            }
            if remember {
                self.store.setSitePermission(
                    dataStoreId: self.dataStoreId, origin: key, feature: .geolocation, allowed: allowed)
            }
            Log.debug("pane \(self.paneId) geolocation \(allowed ? "allowed" : "denied") for \(key)\(remember ? " (remembered)" : "")")
            for waiting in requests {
                if allowed {
                    self.geolocation.request(waiting.request, maximumAge: waiting.maximumAge)
                } else {
                    self.refusePosition(waiting.request, "You blocked this site from knowing where you are.")
                }
            }
        }

        if let dialog = popup(showing: message.webView) {
            // A popup's page asks in its dialog, over the page that asked —
            // the rule `WebPopupDelegate` sets for every other question.
            dialog.ask(prompt, origin: AskOrigin.label(
                scheme: security.protocol, host: security.host, port: Int(security.port)), answer: answer)
        } else {
            ask(prompt, from: frame, answer: answer)
        }
    }

    /// `PERMISSION_DENIED`, now, with a sentence the page's error callback can
    /// show.
    private func refusePosition(_ request: WebGeolocationCenter.Request, _ message: String) {
        guard let webView = request.webView else { return }
        webView.evaluateJavaScript(
            WebGeolocation.failureScript(id: request.id, code: WebGeolocation.Code.permissionDenied, message: message),
            in: request.frame, in: .page
        ) { [paneId] result in
            if case .failure(let error) = result {
                Log.debug("pane \(paneId) geolocation refusal did not land: \(error.localizedDescription)")
            }
        }
    }
}
