import Foundation
import LanedCore
@testable import MaxPaneKit

/// The sidebar model keyed the way it was before sessions had servers: by a
/// bare id, which is a local session's key (ADR-0020). The tests written
/// against that shape read better keeping it — every one of them is about
/// this Mac's sessions — so this is the one adapter between the two.
extension SidebarModel {
    static func rows(
        lanes: [Lane],
        telemetry: [String: SessionTelemetry],
        created: [String: Double] = [:],
        bookmarks: [Bookmark] = [],
        controls: Controls = Controls(),
        now: Date = Date()
    ) -> [Row] {
        rows(
            lanes: lanes,
            telemetry: Dictionary(uniqueKeysWithValues: telemetry.map { (SessionKey(id: $0.key), $0.value) }),
            created: Dictionary(uniqueKeysWithValues: created.map { (SessionKey(id: $0.key), $0.value) }),
            bookmarks: bookmarks,
            controls: controls,
            now: now)
    }
}

extension SidebarModel {
    static func footerCount(telemetry: [String: SessionTelemetry], lanes: [Lane]) -> String {
        footerCount(
            telemetry: Dictionary(uniqueKeysWithValues: telemetry.map { (SessionKey(id: $0.key), $0.value) }),
            lanes: lanes)
    }

    static func blockedCount(_ telemetry: [String: SessionTelemetry]) -> Int {
        blockedCount(Dictionary(uniqueKeysWithValues: telemetry.map { (SessionKey(id: $0.key), $0.value) }))
    }
}
