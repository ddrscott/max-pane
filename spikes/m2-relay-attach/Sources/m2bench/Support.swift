import Foundation
import SwiftTerm
import RelayClient

final class NullTermDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

struct Stats {
    let name: String, unit: String
    let min: Double, p50: Double, p95: Double, p99: Double, max: Double, mean: Double, n: Int
    init(_ name: String, _ xs: [Double], unit: String = "ms") {
        self.name = name; self.unit = unit
        let s = xs.sorted(); n = s.count
        func pc(_ q: Double) -> Double { s.isEmpty ? 0 : s[Swift.min(s.count - 1, Swift.max(0, Int((q * Double(s.count - 1)).rounded()))) ] }
        min = s.first ?? 0; max = s.last ?? 0
        p50 = pc(0.50); p95 = pc(0.95); p99 = pc(0.99)
        mean = s.isEmpty ? 0 : s.reduce(0, +) / Double(s.count)
    }
    var row: String {
        String(format: "| %@ | %d | %.3f | %.3f | %.3f | %.3f | %.3f | %.3f |",
               name, n, min, mean, p50, p95, p99, max)
    }
    static let header = """
    | metric | n | min | mean | p50 | p95 | p99 | max |
    |---|---|---|---|---|---|---|---|
    """
}

func waitUntil(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let end = now() + timeout
    while now() < end { if cond() { return true }; usleep(2000) }
    return cond()
}

/// Self RSS in bytes via mach task_info(MACH_TASK_BASIC_INFO) — resident_size.
func selfRSS() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func selfFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Total CPU time consumed by this process (user+system), seconds.
func selfCPUSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let u = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let s = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return u + s
}

func mb(_ b: UInt64) -> String { String(format: "%.1f MB", Double(b) / 1_048_576.0) }

/// CPU time of an arbitrary pid (seconds), via proc_pid_rusage.
func pidCPUSeconds(_ pid: Int32) -> Double {
    var info = rusage_info_v4()
    var ptr = withUnsafeMutablePointer(to: &info) { UnsafeMutableRawPointer($0) as rusage_info_t? }
    if proc_pid_rusage(pid, RUSAGE_INFO_V4, &ptr) == 0 {
        return Double(info.ri_user_time + info.ri_system_time) / 1e9
    }
    return 0
}

func pidFootprint(_ pid: Int32) -> UInt64 {
    var info = rusage_info_v4()
    var ptr = withUnsafeMutablePointer(to: &info) { UnsafeMutableRawPointer($0) as rusage_info_t? }
    if proc_pid_rusage(pid, RUSAGE_INFO_V4, &ptr) == 0 { return info.ri_phys_footprint }
    return 0
}
