import AppKit
import Darwin
import LanedCore

/// What the strip needs from a pane, whatever is inside it.
///
/// A terminal and a web view have almost nothing in common, so this is
/// deliberately small: a view, a way to adopt a new snapshot, and the four
/// things the eviction policy can ask for.
@MainActor
protocol PaneController: AnyObject {
    var paneId: String { get }
    var view: NSView { get }

    /// Adopt a new snapshot of this pane.
    func apply(_ pane: Pane)

    /// Put the keyboard here.
    func takeFocus()

    /// Release everything; the pane is gone for good.
    func tearDown()

    /// Write anything the pane would otherwise lose, without tearing it down.
    ///
    /// Called on quit. A terminal has nothing to save — the session lives in
    /// Relay and the ledger already has the layout — but a web pane's history
    /// and scroll are only in WebKit's head until someone asks for them.
    func flushState()

    // Eviction actions (PRD §10.2, §10.3). Each must be idempotent: the plan is
    // recomputed on every scroll settle and will re-issue whatever is still true.

    /// Take the view out of the hierarchy but keep the object alive.
    func unparent()
    /// Put it back.
    func reparentIfNeeded()
    /// Snapshot, record scroll, destroy.
    func evict()
    /// Rebuild and restore URL and scroll.
    func rehydrate()
}

extension PaneController {
    func flushState() {}
}

/// What WebKit's content processes actually weigh, right now.
///
/// PRD §10.3 names `task_info`/`proc_pid_rusage` as the input to the eviction
/// policy. The app cannot ask WebKit directly, so it walks the process table for
/// the helper processes and sums their physical footprint.
///
/// Sampled on scroll settle rather than continuously — walking every pid is not
/// free, and the answer does not change fast enough to be worth a tighter loop.
enum WebProcessMemory {
    /// The helper processes WebKit spawns under an app's process pool.
    private static let helperNames = [
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking",
        "com.apple.WebKit.GPU",
    ]

    // Sampled from whichever thread asks; the worst a race can do is recompute.
    nonisolated(unsafe) private static var cached: (bytes: UInt64, at: CFAbsoluteTime) = (0, 0)
    /// Re-measuring more often than this buys nothing.
    private static let maxAge: CFAbsoluteTime = 1.0

    /// Resident footprint across every WebKit helper belonging to this app,
    /// in bytes.
    static func currentBytes() -> UInt64 {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cached.at < maxAge { return cached.bytes }

        var total: UInt64 = 0
        for pid in childPids() where isWebKitHelper(pid) {
            total += footprint(of: pid)
        }
        cached = (total, now)
        return total
    }

    /// WebKit helpers are spawned by launchd rather than parented to us, so
    /// "children" is not enough — this walks every process and keeps the ones
    /// whose responsible pid is this app.
    private static func childPids() -> [pid_t] {
        var size = proc_listallpids(nil, 0)
        guard size > 0 else { return [] }
        // Room for processes that start between the sizing call and the read.
        size += 64
        var pids = [pid_t](repeating: 0, count: Int(size))
        let bytes = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.size * pids.count))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        let me = ProcessInfo.processInfo.processIdentifier
        return pids[0..<count].filter { $0 != 0 && $0 != me }
    }

    private static func isWebKitHelper(_ pid: pid_t) -> Bool {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN and does not surface in
        // Swift's Darwin overlay.
        var buf = [CChar](repeating: 0, count: 4 * 1024)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        guard helperNames.contains(where: { path.contains($0) }) else { return false }
        // Only our own helpers: another app's Safari tabs are not our budget.
        return responsiblePid(pid) == ProcessInfo.processInfo.processIdentifier
    }

    /// The pid a helper is doing work on behalf of. Private API in spirit but
    /// public in `libproc`; if it is ever unavailable the fallback counts every
    /// WebKit helper, which over-estimates rather than under-estimates — the
    /// safe direction for a memory budget.
    private static func responsiblePid(_ pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == Int32(size) else {
            return ProcessInfo.processInfo.processIdentifier
        }
        // A WebKit helper's parent is launchd; the app that asked for it is the
        // responsible process, which for our purposes is close enough to the
        // parent chain we can see without private API.
        return pid_t(info.pbi_ppid) == 1
            ? ProcessInfo.processInfo.processIdentifier
            : pid_t(info.pbi_ppid)
    }

    private static func footprint(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return 0 }
        // Phys_footprint is what Activity Monitor calls Memory, and what the
        // system actually counts against a process under pressure.
        return usage.ri_phys_footprint
    }
}
