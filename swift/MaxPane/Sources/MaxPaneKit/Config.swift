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
    /// 656, not 560. Spike M2 measured cell widths: a 13 pt monospace cell is
    /// 8 pt wide, so 80 columns — what almost every agent TUI assumes — needs
    /// 640 pt of grid, plus 16 pt of lane chrome. At 560 the common case opens
    /// already clipped, and per ADR-0007 the lane may not fix that by resizing
    /// the PTY.
    ///
    /// This is the number every new lane is born at, and it is uniform on
    /// purpose: *"pages on a desk are usually uniform."* It reaches the ledger
    /// through `Core.setDefaultLaneWidth` at launch — until that existed the
    /// setting was decorative, because `create_lane` read a Rust constant that
    /// happened to hold the same 656.
    public var laneDefaultPt: UInt32 = 656

    /// The smallest sliver of the next lane the strip will come to rest with,
    /// in points.
    ///
    /// Uniform lane widths have one failure: when a whole number of them
    /// happens to fill the window, the strip stops flush with a lane boundary
    /// and there is *nothing* at either edge — no evidence that anything exists
    /// beyond the screen. Settling a hair off that alignment costs at most this
    /// many points of the centred lane and buys back the one thing a strip has
    /// to say: there is more, this way.
    ///
    /// 28 because a sliver has to be legible as a *lane*: 1 pt of border plus
    /// ~3 monospace cells of whatever is inside it. Below about 10 it reads as a
    /// thick border and proves nothing. `0` turns it off and gives you exactly
    /// centred snapping again.
    public var lanePeekPt: UInt32 = 28

    /// The two edge rails, which count the lanes off either end of the screen.
    ///
    /// A sliver says *there is more that way*; it cannot say **how much**, and
    /// at the ends of the strip it cannot appear at all. The rails answer both —
    /// a number when lanes are hidden, a solid wall when you have reached the
    /// end. `false` gives the strip the full width and no counters.
    public var stripEdgeRails: Bool = true

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

    /// The command line a ⌘-clicked file opens in, when it is not something a
    /// web pane can render.
    ///
    /// `%f` is the path, already shell-quoted; `%l` is the line and `%c` the
    /// column, each **1** when the text carried none — so the template is
    /// unconditional and never has to grow a "drop the `+` if there is no line"
    /// branch. Nothing else is substituted, which is what leaves `$VAR`, `${}`
    /// and every other bit of shell syntax for the login shell to read.
    ///
    /// `nil` means `${VISUAL:-${EDITOR:-vi}} +%l -- %f`, which is right for vi,
    /// vim, neovim, emacs, nano and micro — as long as the variable names the
    /// program itself, since an alias does not survive the expansion. Editors
    /// that do not take `+N` are why this key exists:
    ///
    /// ```json
    /// { "editor": "code --goto %f:%l:%c" }
    /// { "editor": "hx %f:%l:%c" }
    /// ```
    public var editor: String?

    /// Where a web pane's address bar sends something that is not an address.
    ///
    /// A portrait lane has room for one text field, so the address bar is also
    /// the search box — `%s` is where the query goes, the same placeholder every
    /// browser's custom-engine field uses. Google by default because that is
    /// what the Vivaldi this was measured against is set to; a search box that
    /// answers differently from the one it replaces is a downgrade dressed up
    /// as a principle.
    public var searchUrl: String = "https://www.google.com/search?q=%s"

    /// Settle a horizontal scroll with the nearest lane centred.
    ///
    /// A strip is a row of columns, and a scroll that stops between two of them
    /// leaves both half-readable — you then nudge it by hand, every time. On by
    /// default; `"snapToLanes": false` in the config file leaves the scroll
    /// exactly where the gesture put it.
    public var snapToLanes: Bool = true
    /// How long that settle takes. Short enough not to feel like a delay, long
    /// enough to read as the strip moving rather than jumping.
    public var snapSeconds: Double = 0.18

    /// Which keys run which commands. Command name → a chord, a list of chords,
    /// or `null` to unbind it.
    ///
    /// Set only what you want to move; everything unmentioned keeps the key it
    /// ships with. `Keymap` resolves this against `Command`'s defaults, and the
    /// menu, the ⌘/ sheet and the key monitor all read the result — so one edit
    /// here moves all three, and the help sheet cannot go on advertising a key
    /// that no longer fires.
    ///
    /// The one nesting the file earns. The keymap is the only setting that is a
    /// map rather than a number, and flattening it into `keyNewTerminalLane`
    /// keys would be worse to read and worse to write.
    public var keys: KeyBindings = KeyBindings()

    /// Light or dark: `"system"` follows the Mac, live; `"light"` and `"dark"`
    /// pin it, for the chrome, the terminals and what web pages see as
    /// `prefers-color-scheme` alike.
    ///
    /// The one key that applies the moment the file is saved — `ConfigWatch`
    /// says why it is only this one, for now.
    public var theme: ThemeChoice = .system

    /// `~/.config/maxpane/profiles/<profile>/config.json`.
    ///
    /// Per profile, so a preference can be exercised at runtime without editing
    /// the config of whoever is using the app — which is why the lane-rail and
    /// default-width settings once shipped covered by unit tests and never
    /// tried in a running instance.
    public static var path: URL { Profile.current.configPath }

    public static func load(from path: URL = Config.path) -> Config {
        guard let data = try? Data(contentsOf: path) else { return Config() }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("maxpane: ignoring \(path.path): \(error)\n".utf8))
            return Config()
        }
    }

    /// Decoded key by key, each one falling back to its default.
    ///
    /// Swift's synthesised decoder does not do this: a default value on a
    /// property is used when you construct one in code and ignored when
    /// decoding, so a missing key throws and the *whole file* is discarded.
    /// That made this file all-or-nothing — writing `{"snapToLanes": false}`
    /// silently reverted every other setting to its default — which is not a
    /// config file anyone can use. A bad value is skipped the same way, and
    /// says so on stderr rather than taking the app's settings down with it.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            do {
                return try c.decodeIfPresent(T.self, forKey: key) ?? fallback
            } catch {
                Log.warn("config: ignoring \(key.stringValue) — \(error.localizedDescription)")
                return fallback
            }
        }
        let d = Config()
        laneMinPt = read(.laneMinPt, d.laneMinPt)
        laneMaxPt = read(.laneMaxPt, d.laneMaxPt)
        laneDefaultPt = read(.laneDefaultPt, d.laneDefaultPt)
        lanePeekPt = read(.lanePeekPt, d.lanePeekPt)
        stripEdgeRails = read(.stripEdgeRails, d.stripEdgeRails)
        releaseDistance = read(.releaseDistance, d.releaseDistance)
        rehydrateDistance = read(.rehydrateDistance, d.rehydrateDistance)
        dataStoreCount = read(.dataStoreCount, d.dataStoreCount)
        webMemorySoftFraction = read(.webMemorySoftFraction, d.webMemorySoftFraction)
        webMemoryHardFraction = read(.webMemoryHardFraction, d.webMemoryHardFraction)
        webMemoryTargetFraction = read(.webMemoryTargetFraction, d.webMemoryTargetFraction)
        memorySampleSeconds = read(.memorySampleSeconds, d.memorySampleSeconds)
        sessionPollSeconds = read(.sessionPollSeconds, d.sessionPollSeconds)
        relayPtyHostPath = read(.relayPtyHostPath, d.relayPtyHostPath)
        fontName = read(.fontName, d.fontName)
        fontSize = read(.fontSize, d.fontSize)
        editor = read(.editor, d.editor)
        searchUrl = read(.searchUrl, d.searchUrl)
        snapToLanes = read(.snapToLanes, d.snapToLanes)
        snapSeconds = read(.snapSeconds, d.snapSeconds)
        keys = read(.keys, d.keys)
        theme = read(.theme, d.theme)
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

/// `theme` in the config file. See `Appearance`.
public enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}
