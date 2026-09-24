import AppKit
import Foundation
import IOKit.ps
import Network

/// `14:32 · 78% ⚡ · wifi` at the right of the status bar, while the window
/// is fullscreen and the Mac's own menu bar — which has all three — is away.
///
/// Omarchy's Waybar is always there with a clock and a battery; here the
/// first launch is fullscreen and the window comes back fullscreen if left
/// that way (ADR-0036), so the owner was leaving the app to learn the time
/// or whether the laptop was about to die. Windowed, nothing: the menu bar
/// is showing and a second clock under it would be a second clock.
///
/// The model is pure — a `Reading` in, a string out — so the rule for the
/// red, the `⚡`, the missing battery segment on a desktop and the minute
/// boundary are all tested without a battery in the test runner. The
/// `StatusClockSource` below is what reads the Mac.
public enum StatusClock {
    /// Under this, the battery segment takes the red that already means
    /// "past the hard limit" (README › Colour). Never a green: a battery is
    /// not an agent state, and a green number would read as WORKING.
    public static let lowPercent = 15

    public struct Battery: Equatable, Sendable {
        public var percent: Int
        /// On AC power, whether or not the battery is still taking charge:
        /// `100% ⚡` on a plugged-in Mac says the right thing, and an
        /// unplugged one at 100% has the bolt taken away.
        public var charging: Bool
        public init(percent: Int, charging: Bool) {
            self.percent = percent
            self.charging = charging
        }
        public var isLow: Bool { percent < StatusClock.lowPercent }
        var text: String { "\(percent)%" + (charging ? " " + StatusClock.bolt : "") }
    }

    /// `⚡` with its text presentation selector, so it takes the label's
    /// grey like a glyph rather than arriving as the yellow emoji — the
    /// one colour on the bar would otherwise be the one nobody chose.
    public static let bolt = "\u{26A1}\u{FE0E}"

    /// The kind of the interface the default route is on, and no more: the
    /// SSID would need Location permission, which was refused.
    public enum Network: String, Equatable, Sendable {
        case wifi, wired
        /// Satisfied over something else — cellular, a USB hotspot, a VPN
        /// whose underlying interface is not reported.
        case other = "net"
        case none = "offline"
        var text: String { rawValue }
    }

    public struct Reading: Equatable, Sendable {
        public var time: String
        /// Nil on a Mac with no battery, and then no segment at all.
        public var battery: Battery?
        public var network: Network
        public init(time: String, battery: Battery?, network: Network) {
            self.time = time
            self.battery = battery
            self.network = network
        }

        /// The line as drawn, `·`-separated.
        public var text: String { segments.map(\.text).joined(separator: " · ") }

        /// The segments and whether each takes the red; the bar draws them.
        var segments: [(text: String, low: Bool)] {
            var out: [(String, Bool)] = [(time, false)]
            if let battery { out.append((battery.text, battery.isLow)) }
            out.append((network.text, false))
            return out
        }
    }

    /// `HH:mm`, 24-hour whatever the locale's clock preference says: the
    /// bar is mono and eleven points, and `2:32 PM` is three characters
    /// wider for nothing the owner asked for.
    public static func time(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    /// The next `:00` after `date`: the tick lands on the minute rather than
    /// sixty seconds after launch, so the bar changes when the clock does.
    public static func nextMinute(after date: Date) -> Date {
        let seconds = date.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(seconds / 60) + 1) * 60)
    }

    /// The internal battery from IOKit's power-source descriptions
    /// (`IOPSGetPowerSourceDescription` for each of `IOPSCopyPowerSourcesList`),
    /// or nil when there is none: a desktop, or a UPS alone.
    public static func battery(from sources: [[String: Any]]) -> Battery? {
        for source in sources {
            guard source[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType as String,
                  let current = source[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = source[kIOPSMaxCapacityKey as String] as? Int, max > 0
            else { continue }
            // Current Capacity is already a percentage on every Mac IOKit
            // has shipped on, but Max Capacity is the documented scale.
            let percent = Int((Double(current) / Double(max) * 100).rounded())
            let onAC = source[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue as String
            let charging = source[kIOPSIsChargingKey as String] as? Bool ?? false
            return Battery(percent: min(percent, 100), charging: onAC || charging)
        }
        return nil
    }

    /// `NWPath` to the kind the bar names.
    public static func network(satisfied: Bool, wifi: Bool, wired: Bool) -> Network {
        guard satisfied else { return .none }
        if wifi { return .wifi }
        if wired { return .wired }
        return .other
    }

    /// What the Mac says right now, with no source running: the first frame
    /// after entering fullscreen, before any notification.
    public static func readNow(now: Date = Date()) -> Reading {
        Reading(time: time(now), battery: battery(from: powerSources()), network: .none)
    }

    static func powerSources() -> [[String: Any]] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }
}

/// The three feeds behind a `Reading`, each pushed rather than polled: a
/// timer aligned to the minute, IOKit's power-source notification, and
/// `NWPathMonitor`. Started when the window goes fullscreen and stopped when
/// it leaves, so a windowed app runs none of them.
@MainActor
public final class StatusClockSource {
    public private(set) var reading: StatusClock.Reading
    public var onChange: ((StatusClock.Reading) -> Void)?

    private var tick: Timer?
    private var powerSource: CFRunLoopSource?
    private var monitor: NWPathMonitor?

    public init(now: Date = Date()) {
        reading = StatusClock.readNow(now: now)
    }

    /// Reads once, delivers it, then follows the three feeds.
    public func start() {
        reading.time = StatusClock.time(Date())
        reading.battery = StatusClock.battery(from: StatusClock.powerSources())
        onChange?(reading)
        scheduleTick()

        // The context is this object unretained: `stop` removes the source
        // before `deinit` can run, and the window controller holds the
        // source for exactly as long as it holds the bar it feeds.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<StatusClockSource>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in me.batteryChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let kind = StatusClock.network(
                satisfied: path.status == .satisfied,
                wifi: path.usesInterfaceType(.wifi),
                wired: path.usesInterfaceType(.wiredEthernet))
            Task { @MainActor in self?.networkChanged(kind) }
        }
        monitor.start(queue: .global(qos: .utility))
        self.monitor = monitor
    }

    public func stop() {
        tick?.invalidate()
        tick = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
            self.powerSource = nil
        }
        monitor?.cancel()
        monitor = nil
    }

    /// One shot to the next `:00`, re-armed from each fire rather than
    /// repeating, so a timer that slept through a lid close lands back on
    /// the boundary instead of sixty seconds past wherever it woke.
    private func scheduleTick() {
        tick?.invalidate()
        let timer = Timer(fire: StatusClock.nextMinute(after: Date()), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reading.time = StatusClock.time(Date())
                self.onChange?(self.reading)
                self.scheduleTick()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    private func batteryChanged() {
        let battery = StatusClock.battery(from: StatusClock.powerSources())
        guard battery != reading.battery else { return }
        reading.battery = battery
        onChange?(reading)
    }

    private func networkChanged(_ kind: StatusClock.Network) {
        guard kind != reading.network else { return }
        reading.network = kind
        onChange?(reading)
    }
}
