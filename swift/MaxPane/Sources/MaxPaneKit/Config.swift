import Foundation

/// The config file. PRD §3 makes theming beyond a config file a non-goal, so
/// this is deliberately a flat list of the numbers the PRD leaves configurable
/// and nothing else — no theme engine, no plugins.
///
/// Lives at `~/.config/maxpane/config.json`. Missing file, missing key and
/// unparseable value all fall back to the default, because a typo in a config
/// file should not stop the app from opening.
public struct Config: Codable {
    public init() {}

    /// PRD §8.
    public var laneMinPt: UInt32 = 420
    public var laneMaxPt: UInt32 = 900
    /// 640, not 560. Spike M2 measured cell widths: a 13 pt monospace cell is
    /// 8 pt wide, so 80 columns — what almost every agent TUI assumes — needs
    /// 640 pt of lane. At 560 the common case starts out horizontally scrolled,
    /// and per ADR-0007 the lane cannot fix that by resizing the PTY.
    public var laneDefaultPt: UInt32 = 640

    /// PRD §10.2 — lanes off-screen before a web pane is unparented.
    public var releaseDistance: UInt32 = 6
    /// PRD §10.3 — lanes away before an evicted pane is rehydrated.
    public var rehydrateDistance: UInt32 = 2

    /// PRD §9 — how many `WKWebsiteDataStore` shards to spread projects across.
    public var dataStoreCount: Int = 3

    /// Fractions of physical RAM that bound WebKit's footprint. Spike M1 §9.4
    /// derived all three from measurement: 100 real sites weighed 9.48 GB and
    /// 130 extrapolates to ~11.96 GB, so the soft mark has to bite around the
    /// former and the hard mark has to sit above the latter or it fires
    /// constantly.
    public var webMemorySoftFraction: Double = 0.25
    public var webMemoryHardFraction: Double = 0.35
    public var webMemoryTargetFraction: Double = 0.20

    /// How often to sample WebKit's footprint. The policy wants three
    /// consecutive over-budget samples before it acts, so this also sets what
    /// "sustained" means: 3 × 10 s.
    public var memorySampleSeconds: Double = 10

    /// How often to re-read RelayTTY's session files (seconds). pty-host flushes
    /// on a 5 s cadence, so polling faster buys nothing.
    public var sessionPollSeconds: Double = 5

    /// Where `relay-pty-host` lives. `nil` means "find it next to `relay` on
    /// PATH", which is right on this machine and wrong on someone else's.
    public var relayPtyHostPath: String?

    public var fontName: String = "JetBrains Mono"
    public var fontSize: Double = 13

    public static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/maxpane/config.json")
    }

    public static func load() -> Config {
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
    public var widthRange: ClosedRange<UInt32> {
        let lo = min(laneMinPt, laneMaxPt)
        let hi = max(laneMinPt, laneMaxPt)
        return lo...hi
    }

    public func clampWidth(_ pt: UInt32) -> UInt32 {
        Swift.min(Swift.max(pt, widthRange.lowerBound), widthRange.upperBound)
    }

    private var physicalMemory: Double { Double(ProcessInfo.processInfo.physicalMemory) }

    /// Sustained residency above this starts eviction.
    public var webMemorySoftBytes: UInt64 { UInt64(physicalMemory * webMemorySoftFraction) }
    /// Residency above this evicts immediately, with no waiting.
    public var webMemoryHardBytes: UInt64 { UInt64(physicalMemory * webMemoryHardFraction) }
    /// Evict down to here once evicting, so the cooldown has something to hold.
    public var webMemoryTargetBytes: UInt64 { UInt64(physicalMemory * webMemoryTargetFraction) }
}
