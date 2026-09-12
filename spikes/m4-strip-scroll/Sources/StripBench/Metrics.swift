import Foundation
import Darwin

// MARK: - Global instrumentation counters (single-threaded, main thread only)

enum Counters {
    static var laneLayoutCalls = 0
    static var laneUpdateConstraints = 0
    static var laneInstantiations = 0
    static var laneConfigures = 0
    static var itemInstantiations = 0
}

// MARK: - Process metrics

func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), raw, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

func physFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
        }
    }
    return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
}

/// Total CPU seconds consumed by this process (user + system, all threads).
func cpuSeconds() -> Double {
    var ru = rusage()
    guard getrusage(RUSAGE_SELF, &ru) == 0 else { return 0 }
    let u = Double(ru.ru_utime.tv_sec) + Double(ru.ru_utime.tv_usec) / 1_000_000.0
    let s = Double(ru.ru_stime.tv_sec) + Double(ru.ru_stime.tv_usec) / 1_000_000.0
    return u + s
}

/// Unix-epoch seconds at which this process was exec'd, from the kernel proc table.
func processStartEpoch() -> Double? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    let rc = sysctl(&mib, u_int(mib.count), &kp, &size, nil, 0)
    guard rc == 0 else { return nil }
    let tv = kp.kp_proc.p_un.__p_starttime
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
}

// MARK: - Stats

struct Stats: Encodable {
    var count: Int
    var mean: Double
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
    var min: Double

    init(_ xs: [Double]) {
        guard !xs.isEmpty else {
            count = 0; mean = 0; p50 = 0; p95 = 0; p99 = 0; max = 0; min = 0; return
        }
        let s = xs.sorted()
        count = s.count
        mean = s.reduce(0, +) / Double(s.count)
        func pct(_ p: Double) -> Double {
            let idx = Int((p * Double(s.count - 1)).rounded())
            return s[Swift.max(0, Swift.min(s.count - 1, idx))]
        }
        p50 = pct(0.50); p95 = pct(0.95); p99 = pct(0.99)
        max = s[s.count - 1]; min = s[0]
    }
}

// MARK: - Deterministic width generation

struct LCG {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state >> 16
    }
    mutating func double() -> Double { Double(next() % 1_000_000) / 1_000_000.0 }
}

/// Varied lane widths in [LANE_MIN, LANE_MAX], deterministic for a given seed.
func laneWidths(count: Int, seed: UInt64 = 0x4D34, min lo: Double = 420, max hi: Double = 900) -> [CGFloat] {
    var rng = LCG(seed: seed)
    return (0..<count).map { _ in
        // Round to 0.5pt the way a drag-resize would land.
        let raw = lo + rng.double() * (hi - lo)
        return CGFloat((raw * 2).rounded() / 2)
    }
}
