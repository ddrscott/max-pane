import Foundation

/// The config file. PRD §3 makes theming beyond a config file a non-goal, so
/// this is deliberately a flat list of the numbers the PRD leaves configurable
/// and nothing else — no theme engine, no plugins.
///
/// Lives at `$XDG_CONFIG_HOME/maxpane/config.toml` — see `Profile.configPath` —
/// and is read by `ConfigFile`, keyed by `ConfigField`'s snake_case names.
/// Missing file, missing key and unparseable value all fall back to the
/// default, because a typo in a config file should not stop the app from
/// opening.
///
/// Still `Codable`: `config.json` is what `ConfigFile.migrate` reads from, and
/// this decoder is the definition of what that file meant.
public struct Config: Codable, Equatable {
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
    /// Collapsing a group or a section in the session sidebar takes its lanes
    /// off the strip and out of the gallery, and expanding it brings them
    /// back where they were (ADR-0024). Nothing is closed: the sessions run
    /// on and the header says how many lanes it is holding. Off, a collapse
    /// folds the sidebar's rows and nothing else. Read every time the hidden
    /// lanes are counted, so a change applies as the file is saved.
    public var sidebarCollapseHidesLanes: Bool = true

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

    /// How long a session's DONE chip is held before it lapses to idle on its
    /// own, in seconds. Focusing the pane clears it sooner; zero holds it
    /// until then.
    public var doneHoldSeconds: Double = 1800

    /// Where `relay-pty-host` lives. `nil` means "find it next to `relay` on
    /// PATH", which is right on this machine and wrong on someone else's.
    public var relayPtyHostPath: String?

    public var fontName: String = "JetBrains Mono"
    public var fontSize: Double = 13

    /// Selecting text in a terminal puts it on the clipboard.
    ///
    /// Off by default, which is Ghostty's default too. A selection made by
    /// accident — and most are — replaced whatever had been copied on purpose
    /// a moment before, silently. ⌘C, Edit › Copy and the right-click Copy
    /// item copy the selection either way. Read when the terminals' shared
    /// configuration is built, so a change takes the next launch, as the font
    /// does.
    public var copyOnSelect: Bool = false

    /// A paste with a line ending inside it asks before it goes.
    ///
    /// With no bracketed paste (`TerminalPaste` says why there never will be)
    /// every interior newline is the Return key: four of five pasted lines have
    /// run before the first can be read. The pane asks first, in a sheet over
    /// itself (ADR-0026). Read at each paste, so a change applies at once.
    public var pasteConfirmMultiline: Bool = true
    /// A paste with a tab in it asks too: at a shell prompt a tab is a request
    /// for completion, not whitespace.
    public var pasteConfirmTabs: Bool = true
    /// A paste of more bytes than this asks, whatever is in it. 0 never asks
    /// about size.
    public var pasteConfirmBytes: UInt32 = 16_384
    /// How many spaces the sheet's Tabs to Spaces makes of one tab.
    public var pasteTabWidth: UInt32 = 4
    /// ⌘V with a picture on the clipboard and nothing else (a screenshot)
    /// writes it to a PNG and pastes that file's path; in a remote lane it is
    /// uploaded to the server and the path there is pasted. Off, such a
    /// clipboard pastes nothing. Read at each paste.
    public var pasteImagesAsFiles: Bool = true
    /// Pasted images older than this many days are removed at launch. 0 keeps
    /// them. Only this Mac's: what was uploaded to a server is the server's.
    public var pasteImageKeepDays: UInt32 = 7
    /// A pasted image bigger than this, as PNG, is refused in one line. 0
    /// refuses nothing (a relay server stops at 100 MB itself).
    public var pasteImageMaxMb: UInt32 = 25

    /// Which terminal cursors blink.
    ///
    /// `focused`, the default: the one terminal that holds the keyboard, and
    /// none when no terminal does. A blinking cursor says "typing goes here",
    /// and only one pane can mean that at a time; a gallery of a dozen blinking
    /// out of phase says nothing. `never` holds every cursor still, the focused
    /// one included. `always` blinks them all, by telling every surface it is
    /// focused, so a program that asked for focus reports (mode 1004) is told
    /// the same thing. A program's own DECSCUSR steady cursor stays steady
    /// under all three. Read when the terminals' shared configuration is
    /// built, so a change takes the next launch, as the font does.
    public var cursorBlink: CursorBlink = .focused

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
    /// ```toml
    /// editor = "code --goto %f:%l:%c"
    /// editor = "hx %f:%l:%c"
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
    /// default; `snap_to_lanes = false` in the config file leaves the scroll
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

    /// Block ads and trackers in web panes, with WebKit's own content blocker
    /// running the list `blockingListUrl` names. On by default: YouTube and
    /// most of the news is unreadable for long without it, and that was the
    /// single biggest reason a web pane sent its owner back to another
    /// browser. Off for one site from the lane's ⋯ menu; off everywhere here.
    /// See `ContentBlocker`.
    public var blocking: Bool = true

    /// Where the rule list comes from: WebKit content-blocker JSON, the format
    /// a Safari content blocker ships, fetched and compiled once a day. More
    /// than one URL, separated by spaces, is joined into one list.
    ///
    /// The default is Adblock Plus's published conversion of EasyList. It is
    /// the one maintained conversion of a list people actually use that is
    /// served in this format; EasyPrivacy has no such conversion, and a
    /// converter from the ABP filter syntax is a project of its own. Anyone
    /// who has one puts its URL here.
    public var blockingListUrl: String = "https://easylist-downloads.adblockplus.org/easylist_content_blocker.json"

    /// Remote relay-tty servers, one `[[servers]]` table each:
    ///
    /// ```toml
    /// [[servers]]
    /// name = "yorkshire"
    /// url = "https://yourslug.relaytty.com"
    /// enabled = true
    /// color = "violet"
    /// ```
    ///
    /// The local server is never listed — it is implicit, and an empty list
    /// is the app exactly as it was before servers existed (ADR-0020). The
    /// token is not here: it lives in the Keychain against the server's host,
    /// put there by `maxpane server add`. The second nesting the file earns,
    /// after `[keys]`: a server is three facts that belong together, and
    /// `server_1_url` keys would be worse to read and worse to write.
    /// Hand-edited in this phase; Settings gets a Servers section in the
    /// next. Read at launch.
    public var servers: [RelayServerEntry] = []

    /// `$XDG_CONFIG_HOME/maxpane/config.toml` for the default profile,
    /// `…/maxpane/profiles/<profile>/config.toml` for any other.
    ///
    /// Per profile, so a preference can be exercised at runtime without editing
    /// the config of whoever is using the app — which is why the lane-rail and
    /// default-width settings once shipped covered by unit tests and never
    /// tried in a running instance.
    public static var path: URL { Profile.current.configPath }

    /// The TOML file at `path`, each bad value skipped with a line on stderr.
    public static func load(from path: URL = Config.path) -> Config {
        let (config, problems, _) = ConfigFile.load(from: path)
        for problem in problems { Log.warn("config: \(problem.text)") }
        return config
    }

    /// `config.json`, decoded key by key, each one falling back to its default.
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
        sidebarCollapseHidesLanes = read(.sidebarCollapseHidesLanes, d.sidebarCollapseHidesLanes)
        releaseDistance = read(.releaseDistance, d.releaseDistance)
        rehydrateDistance = read(.rehydrateDistance, d.rehydrateDistance)
        dataStoreCount = read(.dataStoreCount, d.dataStoreCount)
        webMemorySoftFraction = read(.webMemorySoftFraction, d.webMemorySoftFraction)
        webMemoryHardFraction = read(.webMemoryHardFraction, d.webMemoryHardFraction)
        webMemoryTargetFraction = read(.webMemoryTargetFraction, d.webMemoryTargetFraction)
        memorySampleSeconds = read(.memorySampleSeconds, d.memorySampleSeconds)
        sessionPollSeconds = read(.sessionPollSeconds, d.sessionPollSeconds)
        doneHoldSeconds = read(.doneHoldSeconds, d.doneHoldSeconds)
        relayPtyHostPath = read(.relayPtyHostPath, d.relayPtyHostPath)
        fontName = read(.fontName, d.fontName)
        fontSize = read(.fontSize, d.fontSize)
        copyOnSelect = read(.copyOnSelect, d.copyOnSelect)
        pasteConfirmMultiline = read(.pasteConfirmMultiline, d.pasteConfirmMultiline)
        pasteConfirmTabs = read(.pasteConfirmTabs, d.pasteConfirmTabs)
        pasteConfirmBytes = read(.pasteConfirmBytes, d.pasteConfirmBytes)
        pasteTabWidth = read(.pasteTabWidth, d.pasteTabWidth)
        pasteImagesAsFiles = read(.pasteImagesAsFiles, d.pasteImagesAsFiles)
        pasteImageKeepDays = read(.pasteImageKeepDays, d.pasteImageKeepDays)
        pasteImageMaxMb = read(.pasteImageMaxMb, d.pasteImageMaxMb)
        cursorBlink = read(.cursorBlink, d.cursorBlink)
        editor = read(.editor, d.editor)
        searchUrl = read(.searchUrl, d.searchUrl)
        snapToLanes = read(.snapToLanes, d.snapToLanes)
        snapSeconds = read(.snapSeconds, d.snapSeconds)
        keys = read(.keys, d.keys)
        theme = read(.theme, d.theme)
        blocking = read(.blocking, d.blocking)
        blockingListUrl = read(.blockingListUrl, d.blockingListUrl)
        servers = read(.servers, d.servers)
    }

    /// The servers that are switched on, by name, with the names that appear
    /// twice reported so nothing is silently keyed on the wrong one.
    public var enabledServers: [RelayServerEntry] {
        var seen = Set<String>()
        return servers.filter { $0.enabled && seen.insert($0.name).inserted }
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

/// One `[[servers]]` table. See `Config.servers`.
public struct RelayServerEntry: Codable, Equatable, Sendable {
    /// What the lane header and the sidebar group print. Short, because it
    /// sits where a directory tag sits.
    public var name: String
    /// `https://<slug>.relaytty.com` or `http://host:port`. Scheme and host;
    /// a path is ignored.
    public var url: String
    public var enabled: Bool
    /// `color = "violet"`: the colour this server is known by (ADR-0025).
    /// Nil is a table with no `color` line, which reads as `slate` until the
    /// server book gives it the first colour nobody else has and writes it.
    public var color: ServerColour?

    /// What every surface draws: the file's colour, or `slate`.
    public var colour: ServerColour { color ?? .fallback }

    public init(name: String, url: String, enabled: Bool = true, color: ServerColour? = nil) {
        self.name = name
        self.url = url
        self.enabled = enabled
        self.color = color
    }

    /// The base URL, or nil when `url` is not one a server could be at.
    public var baseURL: URL? {
        guard var c = URLComponents(string: url), let scheme = c.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = c.host, !host.isEmpty
        else { return nil }
        c.scheme = scheme
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// Why this entry cannot be used, or nil when it can.
    public var complaint: String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "name is empty" }
        if trimmed.contains(":") || trimmed.contains("/") { return "name may not contain ':' or '/'" }
        if baseURL == nil { return "url must be http:// or https:// with a host" }
        return nil
    }
}

/// `cursor_blink` in the config file. See `Config.cursorBlink`.
public enum CursorBlink: String, Codable, CaseIterable, Sendable {
    case focused, always, never
}

/// `theme` in the config file. See `Appearance`.
public enum ThemeChoice: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}
