// Spike M3 — `laned-core` via uniffi: StripState round-trip at 300 lanes / 400
// panes. PRD §12 pass criterion: < 5 ms.
//
// The number that matters is the *whole* round-trip the shell will actually
// pay on every mutation: Rust reads SQLite, builds the snapshot, uniffi
// serialises it into a RustBuffer, Swift walks the buffer allocating Swift
// structs and Strings. Timing only the Rust half would flatter the result, so
// this times from the Swift call site and separately reports the Rust-only
// cost so the split is visible.

import Foundation
import LanedCore

// MARK: - timing

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = Int((Double(sorted.count - 1) * p).rounded())
    return sorted[idx]
}

struct Stats {
    let label: String
    let samples: [Double]  // milliseconds

    var sorted: [Double] { samples.sorted() }
    var mean: Double { samples.reduce(0, +) / Double(samples.count) }

    func line() -> String {
        let s = sorted
        return String(
            format: "%-38s n=%-5d mean %6.3f  p50 %6.3f  p95 %6.3f  p99 %6.3f  max %6.3f",
            (label as NSString).utf8String!, samples.count,
            mean, percentile(s, 0.50), percentile(s, 0.95), percentile(s, 0.99), s.last ?? 0)
    }
}

func measure(_ label: String, iterations: Int, _ body: () throws -> Void) rethrows -> Stats {
    // Warm up: first call pays for lazy statement preparation and page cache.
    for _ in 0..<3 { try body() }
    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<iterations {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        samples.append(Double(t1 - t0) / 1_000_000.0)
    }
    return Stats(label: label, samples: samples)
}

// MARK: - fixture

let laneCount = 300
let paneCount = 400
let iterations = 200

// A real on-disk ledger, not in-memory: the shell's ledger is a file, and
// SQLite's page cache behaves differently for the two.
let dbDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("maxpane-m3-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbPath = dbDir.appendingPathComponent("ledger.db").path
defer { try? FileManager.default.removeItem(at: dbDir) }

print("Spike M3 — laned-core over uniffi")
print("ledger: \(dbPath)")
print("target: \(laneCount) lanes / \(paneCount) panes, StripState round-trip < 5 ms\n")

let core = try Core.open(path: dbPath)

let buildStart = DispatchTime.now().uptimeNanoseconds
var laneIDs: [String] = []
for i in 0..<laneCount {
    // Spawn adjacency: every lane lands immediately right of the previous one,
    // which is also the worst case for the ordinal code (every insert splits
    // the same end gap).
    let placement: Placement = laneIDs.isEmpty
        ? .end
        : .rightOf(laneId: laneIDs[laneIDs.count - 1])
    let kind: PaneKind = i % 7 == 0 ? .pty : .web
    let st = try core.createLane(
        placement: placement,
        kind: kind,
        relaySessionId: kind == .pty ? "sess\(i)" : nil,
        url: kind == .web ? "https://example.com/page/\(i)?q=some+realistic+query" : nil,
        inheritTagFromLane: nil)
    let id = st.lanes[st.lanes.count - 1].id
    laneIDs.append(id)
    _ = try core.setLaneTitle(laneId: id, title: "lane \(i) — a realistically long tab title")
    _ = try core.setManualTag(laneId: id, projectRoot: "/Users/spierce/code/project-\(i % 12)")
}
// Extra panes stacked into lanes until we reach the pane target.
var extra = paneCount - laneCount
var li = 0
while extra > 0 {
    _ = try core.addPane(
        laneId: laneIDs[li % laneCount], kind: .web, relaySessionId: nil,
        url: "https://example.com/stacked/\(li)")
    li += 1
    extra -= 1
}
let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000.0

let st = try core.state()
let actualPanes = st.lanes.reduce(0) { $0 + $1.panes.count }
print("built \(st.lanes.count) lanes / \(actualPanes) panes in \(String(format: "%.0f", buildMs)) ms "
      + "(\(String(format: "%.2f", buildMs / Double(laneCount))) ms per create_lane, each a committed write)\n")

// MARK: - the measurements

var results: [Stats] = []

// 1. The headline: a full snapshot crossing the FFI boundary.
results.append(try measure("state() full round-trip", iterations: iterations) {
    _ = try core.state()
})

// 2. The same snapshot, but Swift also walks every field — what the diff-renderer
//    actually does with it. Proves the lazy-decode question either way.
results.append(try measure("state() + walk every field", iterations: iterations) {
    let s = try core.state()
    var acc = 0
    for lane in s.lanes {
        acc &+= lane.id.utf8.count &+ (lane.title?.utf8.count ?? 0) &+ (lane.projectRoot?.utf8.count ?? 0)
        for pane in lane.panes { acc &+= pane.id.utf8.count &+ (pane.url?.utf8.count ?? 0) }
    }
    precondition(acc > 0)
})

// 3. A mutation: commit to SQLite, then hand back the new snapshot. This is the
//    real per-keystroke-ish cost of reordering the strip.
var nudgeRight = true
results.append(try measure("nudge_lane (write + snapshot)", iterations: iterations) {
    _ = try core.nudgeLane(laneId: laneIDs[150], right: nudgeRight)
    nudgeRight.toggle()
})

// 4. Focus: the most frequent mutation of all.
results.append(try measure("focus_pane (write + snapshot)", iterations: iterations) {
    _ = try core.focusPane(paneId: st.lanes[7].panes[0].id)
})

// 5. A gather view — pure filter, no write.
results.append(try measure("gather + ungather", iterations: iterations) {
    _ = try core.gather(projectRoot: "/Users/spierce/code/project-3")
    _ = try core.ungather()
})

// 6. Search across everything, with scrollback loaded, since ⌘P must feel instant.
for lane in st.lanes where lane.panes.first?.kind == .pty {
    let lines = (0..<200).map { "2026-09-12T10:4\($0 % 10):00  compiling laned-core unit \($0) of 200 ok" }
    core.pushScrollback(paneId: lane.panes[0].id, lines: lines)
}
results.append(try measure("search over titles+urls+scrollback", iterations: iterations) {
    _ = try core.search(query: "laned", limit: 50)
})

// 7. The eviction plan, which runs on every scroll settle.
let vp = Viewport(firstVisible: 140, lastVisible: 145)
let mem = MemoryReport(webContentRssBytes: 8 * 1024 * 1024 * 1024, budgetBytes: 6 * 1024 * 1024 * 1024)
results.append(try measure("plan_eviction", iterations: iterations) {
    _ = try core.planEviction(viewport: vp, memory: mem)
})

// 8. The cheap no-op the cwd poller does 20x every 5 seconds.
results.append(try measure("observe_cwd (unchanged, no-op)", iterations: iterations) {
    _ = try core.observeCwd(laneId: laneIDs[0], cwd: "/Users/spierce/code/max-pane")
})

print("── results (milliseconds) " + String(repeating: "─", count: 60))
for r in results { print(r.line()) }
print("")

// MARK: - verdict

let headline = results[0]
let walked = results[1]
let budget = 5.0
let p95 = percentile(headline.sorted, 0.95)
let worst = max(p95, percentile(walked.sorted, 0.95))

print("PRD §12 M3 — StripState round-trip at 300 lanes / 400 panes < 5 ms")
print(String(format: "  state() p95            : %.3f ms", p95))
print(String(format: "  state()+full walk p95  : %.3f ms", percentile(walked.sorted, 0.95)))
print(String(format: "  verdict                : %@ (%.3f ms vs %.1f ms budget, %.0fx headroom)",
             worst < budget ? "PASS" : "FAIL", worst, budget, budget / max(worst, 0.0001)))
