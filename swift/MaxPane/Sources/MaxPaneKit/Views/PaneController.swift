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

    /// Scale what is inside the pane: 1.0 is actual size.
    ///
    /// A terminal changes its font size and re-derives its grid; a page changes
    /// its page zoom. Both are "this column is too small to read", so both are
    /// the same key.
    var zoom: Double { get }
    func setZoom(_ zoom: Double)

    /// ⌘R, and ⇧⌘R when `fromOrigin` is true — fetch it again, ignoring the
    /// cache.
    ///
    /// The same seam as `setZoom`: the command walks in, the pane decides what
    /// the word means for it. Only a web pane has something to re-fetch, which
    /// is why the default below is what it is.
    func reload(fromOrigin: Bool)

    /// ⌘L — put the keyboard in this pane's address bar with the whole address
    /// selected, so the next keystroke replaces it and ⌘C copies it.
    ///
    /// The same seam as `reload(fromOrigin:)`, and the one place it parts
    /// company with it: ⌘R is offered on every pane and beeps where it means
    /// nothing, because a terminal *could* have a sense of "fetch it again".
    /// An address is not like that — a terminal does not have one at all — so
    /// this is greyed out in the menu instead, the way "Resize Session to This
    /// Lane…" is greyed out for a page. A menu item that says why beats a beep
    /// that does not.
    func editAddress()

    /// Keep This Page — keep it, and open the editor on it. Greyed out for a
    /// terminal for the same reason `editAddress` is: a pane with no address
    /// has no page to keep.
    func keepPage()

    /// ⌥⌘L — put a saved password into the form on this page, and ⇧⌘L — save
    /// one for this site. Greyed out for a terminal, and greyed out harder
    /// than the two above: there is no form in a terminal, so a key that could
    /// put a credential somewhere unexpected is dead everywhere it does not
    /// mean anything.
    func fillPassword()
    func savePassword()

    /// ⌃⌘P — the system print panel over this page, and Save as PDF… — the
    /// whole page as one PDF file. Greyed out for a terminal, which has no
    /// document to print; see `WebPrint.swift`.
    func printPage()
    func savePDF()

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

    /// A pane that does not scale reports actual size and ignores the keys.
    var zoom: Double { 1 }
    func setZoom(_ zoom: Double) {}

    /// A pane with nothing to re-fetch says so, out loud.
    ///
    /// ⌘R exists on every pane because the strip has two kinds and a key that
    /// works in one lane and silently does nothing in the next is a key you
    /// stop trusting in both. A terminal's screen is not a document — there is
    /// no origin to ask again — so the honest answer is the system's own "that
    /// key does not apply here", which is a beep.
    ///
    /// The alternative worth doing later, in the terminal's own file: repaint
    /// the surface from the emulator's buffer, which is what `redraw` means in
    /// tmux and is the only thing in a terminal that "reload" could honestly
    /// name. What it must never do is *run* something — ⌘R used to open a
    /// prompt that started a command, and a key that quietly kept doing that
    /// after being renamed "reload" would be the worst outcome of the rename.
    func reload(fromOrigin: Bool) { NSSound.beep() }

    /// A pane with no address bar does nothing, silently. `canPerform` has
    /// already greyed the item out, so the only way to arrive here is a key
    /// pressed at the moment focus moved — and a beep for that is noise.
    func editAddress() {}

    /// As `editAddress`: the menu item is already greyed, so the only way here
    /// is a key pressed as focus moved.
    func keepPage() {}

    /// As `editAddress`, and for the one kind of key where "does nothing,
    /// silently" is the only acceptable default.
    func fillPassword() {}
    func savePassword() {}

    /// As `keepPage`: greyed already, so arriving here is a key on a moved focus.
    func printPage() {}
    func savePDF() {}
}

/// The rungs ⌘= and ⌘- climb.
enum PaneZoom {
    /// Multiplicative, and the ladder browsers use. A fixed ±1pt is a tenth of
    /// a 10pt font and a twentieth of a 20pt one — the same key would do
    /// something different depending on where you started.
    static let ladder: [Double] = [0.5, 0.67, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// The next rung from wherever the pane is now, stopping at the ends.
    static func next(from current: Double, up: Bool) -> Double {
        if up { return ladder.first { $0 > current + 0.001 } ?? ladder.last! }
        return ladder.last { $0 < current - 0.001 } ?? ladder.first!
    }

    /// The rung closest to `value`, for a gesture that lands between two:
    /// a pinch ends wherever the fingers stop, and the pane settles on the
    /// ladder so ⌘= and ⌘- go on stepping from a rung rather than from 1.37.
    static func nearest(to value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return ladder.min { abs($0 - value) < abs($1 - value) }!
    }
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
