import Foundation

/// The config file. PRD §3 makes theming beyond a config file a non-goal, so
/// this is deliberately a flat list of the numbers the PRD leaves configurable
/// and nothing else — no theme engine, no plugins.
///
/// Lives at `~/.config/maxpane/config.json`. Missing file, missing key and
/// unparseable value all fall back to the default, because a typo in a config
/// file should not stop the app from opening.
struct Config: Codable {
    /// PRD §8.
    var laneMinPt: UInt32 = 420
    var laneMaxPt: UInt32 = 900
    var laneDefaultPt: UInt32 = 560

    /// PRD §10.2 — lanes off-screen before a web pane is unparented.
    var releaseDistance: UInt32 = 6
    /// PRD §10.3 — lanes away before an evicted pane is rehydrated.
    var rehydrateDistance: UInt32 = 2

    /// PRD §9 — how many `WKWebsiteDataStore` shards to spread projects across.
    var dataStoreCount: Int = 3

    /// Fraction of physical RAM WebKit content processes may hold before
    /// eviction engages.
    var webMemoryBudgetFraction: Double = 0.35

    /// How often to re-read RelayTTY's session files (seconds). pty-host flushes
    /// on a 5 s cadence, so polling faster buys nothing.
    var sessionPollSeconds: Double = 5

    /// Where `relay-pty-host` lives. `nil` means "find it next to `relay` on
    /// PATH", which is right on this machine and wrong on someone else's.
    var relayPtyHostPath: String?

    var fontName: String = "JetBrains Mono"
    var fontSize: Double = 13

    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/maxpane/config.json")
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("maxpane: ignoring \(path.path): \(error)\n".utf8))
            return Config()
        }
    }

    /// The lane width bounds, already ordered, so a config with min > max does
    /// something sane instead of trapping in `clamped(to:)`.
    var widthRange: ClosedRange<UInt32> {
        let lo = min(laneMinPt, laneMaxPt)
        let hi = max(laneMinPt, laneMaxPt)
        return lo...hi
    }

    func clampWidth(_ pt: UInt32) -> UInt32 {
        Swift.min(Swift.max(pt, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Bytes of WebKit content-process residency to stay under.
    var webMemoryBudgetBytes: UInt64 {
        UInt64(Double(ProcessInfo.processInfo.physicalMemory) * webMemoryBudgetFraction)
    }
}
