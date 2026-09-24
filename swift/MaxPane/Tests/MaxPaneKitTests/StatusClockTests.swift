import AppKit
import Foundation
import IOKit.ps
import LanedCore
import Testing
@testable import MaxPaneKit

/// `14:32 · 78% ⚡ · wifi` at the right of the status bar while fullscreen
/// (Omarchy F2): the line, the red under 15 %, the missing segment on a
/// desktop, the minute boundary, IOKit's dictionaries, and the bar showing
/// and hiding it. Nothing here reads the test runner's own battery.
@Suite("status clock")
@MainActor
struct StatusClockTests {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-09-23 14:32:17 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_260_337)

    @Test("the line is time · battery · network, with ⚡ on power and no battery segment on a desktop")
    func line() {
        #expect(StatusClock.Reading(time: "14:32", battery: .init(percent: 78, charging: true), network: .wifi).text == "14:32 · 78% \(StatusClock.bolt) · wifi")
        #expect(StatusClock.Reading(time: "14:32", battery: .init(percent: 78, charging: false), network: .wired).text == "14:32 · 78% · wired")
        #expect(StatusClock.Reading(time: "09:05", battery: nil, network: .none).text == "09:05 · offline")
        #expect(StatusClock.Reading(time: "09:05", battery: nil, network: .other).text == "09:05 · net")
    }

    @Test("under 15 % is low; 15 is not; charging does not change it")
    func low() {
        #expect(StatusClock.Battery(percent: 14, charging: false).isLow)
        #expect(StatusClock.Battery(percent: 14, charging: true).isLow)
        #expect(!StatusClock.Battery(percent: 15, charging: false).isLow)
        #expect(!StatusClock.Battery(percent: 100, charging: true).isLow)
        let reading = StatusClock.Reading(time: "14:32", battery: .init(percent: 9, charging: false), network: .wifi)
        #expect(reading.segments.map(\.low) == [false, true, false])
    }

    @Test("the time is HH:mm, 24-hour, in the zone given")
    func time() {
        #expect(StatusClock.time(Self.now, timeZone: Self.utc) == "14:32")
        #expect(StatusClock.time(Self.now, timeZone: TimeZone(identifier: "America/Chicago")!) == "09:32")
        #expect(StatusClock.time(Date(timeIntervalSince1970: 1_790_205_000), timeZone: Self.utc) == "23:10")
    }

    @Test("the next tick is the next :00, never now and never a minute past now")
    func nextMinute() {
        let next = StatusClock.nextMinute(after: Self.now)
        #expect(next.timeIntervalSince1970 == 1_790_260_380)
        #expect(StatusClock.time(next, timeZone: Self.utc) == "14:33")
        // Exactly on the boundary, the next boundary is a whole minute on.
        #expect(StatusClock.nextMinute(after: next).timeIntervalSince1970 == 1_790_260_440)
    }

    @Test("IOKit's internal battery: percent from current over max, ⚡ on AC or while charging; a UPS or nothing is no battery")
    func battery() {
        func source(_ current: Int, _ max: Int, state: String, charging: Bool, type: String = kIOPSInternalBatteryType as String) -> [String: Any] {
            [kIOPSTypeKey as String: type,
             kIOPSCurrentCapacityKey as String: current,
             kIOPSMaxCapacityKey as String: max,
             kIOPSPowerSourceStateKey as String: state,
             kIOPSIsChargingKey as String: charging]
        }
        let ac = kIOPSACPowerValue as String, battery = kIOPSBatteryPowerValue as String
        #expect(StatusClock.battery(from: [source(78, 100, state: ac, charging: true)]) == .init(percent: 78, charging: true))
        #expect(StatusClock.battery(from: [source(100, 100, state: ac, charging: false)]) == .init(percent: 100, charging: true))
        #expect(StatusClock.battery(from: [source(12, 100, state: battery, charging: false)]) == .init(percent: 12, charging: false))
        // Max Capacity is the scale, whatever it is.
        #expect(StatusClock.battery(from: [source(4500, 6000, state: battery, charging: false)]) == .init(percent: 75, charging: false))
        #expect(StatusClock.battery(from: []) == nil)
        #expect(StatusClock.battery(from: [source(50, 100, state: ac, charging: false, type: kIOPSUPSType as String)]) == nil)
        #expect(StatusClock.battery(from: [[kIOPSTypeKey as String: kIOPSInternalBatteryType as String]]) == nil)
    }

    @Test("the network is the interface kind and nothing more")
    func network() {
        #expect(StatusClock.network(satisfied: true, wifi: true, wired: false) == .wifi)
        #expect(StatusClock.network(satisfied: true, wifi: false, wired: true) == .wired)
        #expect(StatusClock.network(satisfied: true, wifi: true, wired: true) == .wifi)
        #expect(StatusClock.network(satisfied: true, wifi: false, wired: false) == .other)
        #expect(StatusClock.network(satisfied: false, wifi: true, wired: false) == .none)
    }

    @Test("the bar shows the line at the right, paints a low battery red, and takes it away")
    func bar() {
        let bar = StatusBar(frame: NSRect(x: 0, y: 0, width: 900, height: StatusBar.height))
        #expect(bar.clockText == "")
        #expect(!bar.clockLowBattery)
        bar.setClock(.init(time: "14:32", battery: .init(percent: 78, charging: true), network: .wifi))
        #expect(bar.clockText == "14:32 · 78% \(StatusClock.bolt) · wifi")
        #expect(!bar.clockLowBattery)
        bar.setClock(.init(time: "14:33", battery: .init(percent: 9, charging: false), network: .wifi))
        #expect(bar.clockText == "14:33 · 9% · wifi")
        #expect(bar.clockLowBattery)
        bar.setClock(.init(time: "14:34", battery: nil, network: .wired))
        #expect(bar.clockText == "14:34 · wired")
        #expect(!bar.clockLowBattery)
        bar.setClock(nil)
        #expect(bar.clockText == "")
    }

    @Test("the tooltip says what each segment is, and how to turn the line off")
    func tooltip() {
        let text = StatusBar.clockTooltip(.init(time: "14:32", battery: .init(percent: 9, charging: true), network: .wifi))
        #expect(text.hasPrefix("The Mac's clock · battery low, 9%, on power · Wi-Fi"))
        #expect(text.contains("status_clock = false"))
        #expect(StatusBar.clockTooltip(.init(time: "14:32", battery: nil, network: .none)).hasPrefix("The Mac's clock · no network"))
    }

    @Test("status_clock is a config key, on by default, under Appearance, live")
    func setting() throws {
        #expect(Config().statusClock)
        let field = try #require(ConfigField.all.first { $0.name == "statusClock" })
        #expect(field.key == "status_clock")
        #expect(field.group == .appearance)
        #expect(field.appliesLive)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maxpane-status-clock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.toml")
        try "status_clock = false\n".write(to: file, atomically: true, encoding: .utf8)
        let (config, problems, _) = ConfigFile.load(from: file)
        #expect(problems.isEmpty)
        #expect(!config.statusClock)
    }

    @Test("a source starts with a reading of now and delivers it; stopped, it is quiet")
    func source() {
        let source = StatusClockSource()
        var seen: [StatusClock.Reading] = []
        source.onChange = { seen.append($0) }
        source.start()
        #expect(seen.count == 1)
        #expect(seen.first?.time == StatusClock.time(Date()))
        source.stop()
    }

    // MARK: the sheet

    /// The bar with the clock at the right, a low battery in the red, in
    /// both appearances. Gated on `MAXPANE_SHOTS`.
    ///
    ///     ./scripts/test.sh shots /tmp/shots
    @Test("renders the clock, a low battery and the network at the right of the bar")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else {
            print("SKIPPED renders the status clock sheet — set MAXPANE_SHOTS=DIR")
            return
        }
        for (name, reading) in [
            ("status-bar-clock", StatusClock.Reading(time: "14:32", battery: .init(percent: 78, charging: true), network: .wifi)),
            ("status-bar-clock-low", StatusClock.Reading(time: "23:58", battery: .init(percent: 9, charging: false), network: .none)),
        ] {
            try AppearanceSheet.render(to: dir, named: name) {
                let sheet = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: StatusBar.height))
                let bar = StatusBar(frame: sheet.bounds)
                bar.update(
                    state: StripState(lanes: [], scrollX: 0, focusedPaneId: nil, gatherFilter: nil, hiddenLaneIds: [], revision: 1),
                    telemetry: [:], webBytes: 0)
                bar.setUpdate("↻ v0.8.0", tooltip: nil)
                bar.setClock(reading)
                sheet.addSubview(bar)
                bar.layoutSubtreeIfNeeded()
                return sheet
            }
        }
    }
}
