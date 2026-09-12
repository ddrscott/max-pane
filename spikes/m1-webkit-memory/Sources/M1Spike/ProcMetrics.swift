import Foundation
import CProcInfo

/// One process's memory / CPU snapshot.
struct ProcSample {
    var pid: Int32
    var path: String
    var kind: String          // "app", "WebContent", "Networking", "GPU", "other-webkit"
    var physFootprint: UInt64 // bytes; == Activity Monitor "Memory"
    var resident: UInt64      // bytes; classic RSS
    var cpuNs: UInt64         // cumulative user+system ns since process start
}

enum ProcMetrics {

    static func classify(_ path: String) -> String? {
        if path.contains("com.apple.WebKit.WebContent") { return "WebContent" }
        if path.contains("com.apple.WebKit.Networking") { return "Networking" }
        if path.contains("com.apple.WebKit.GPU") { return "GPU" }
        if path.contains("/WebKit.framework/") { return "other-webkit" }
        return nil
    }

    static func allPids() -> [Int32] {
        var cap: Int32 = 8192
        while true {
            var buf = [Int32](repeating: 0, count: Int(cap))
            let n = buf.withUnsafeMutableBufferPointer { mp_list_pids($0.baseAddress, cap) }
            if n < 0 { return [] }
            if n < Int(cap) { return Array(buf[0..<Int(n)]).filter { $0 > 0 } }
            cap *= 2
        }
    }

    static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { mp_pid_path(pid, $0.baseAddress, 4096) }
        if n <= 0 { return nil }
        return String(cString: buf)
    }

    static func sample(pid: Int32, path: String, kind: String) -> ProcSample? {
        var foot: UInt64 = 0, res: UInt64 = 0, u: UInt64 = 0, s: UInt64 = 0
        guard mp_mem(pid, &foot, &res) == 0 else { return nil }
        guard mp_cpu_ns(pid, &u, &s) == 0 else { return nil }
        return ProcSample(pid: pid, path: path, kind: kind,
                          physFootprint: foot, resident: res, cpuNs: u &+ s)
    }

    /// Every WebKit helper alive right now, excluding a baseline pid set that
    /// was already running before we started (other apps' WebViews).
    static func webkitHelpers(excluding baseline: Set<Int32>) -> [ProcSample] {
        var out: [ProcSample] = []
        for pid in allPids() where !baseline.contains(pid) {
            guard let p = path(of: pid), let kind = classify(p) else { continue }
            if let s = sample(pid: pid, path: p, kind: kind) { out.append(s) }
        }
        return out
    }

    static func baselineWebKitPids() -> Set<Int32> {
        var out = Set<Int32>()
        for pid in allPids() {
            if let p = path(of: pid), classify(p) != nil { out.insert(pid) }
        }
        return out
    }

    static func selfSample() -> ProcSample? {
        let pid = getpid()
        return sample(pid: pid, path: path(of: pid) ?? "self", kind: "app")
    }
}

/// A whole-app snapshot: our process plus every WebKit helper it caused.
struct MemSnapshot {
    var label: String
    var wallTime: Double
    var app: ProcSample?
    var helpers: [ProcSample]

    var all: [ProcSample] { (app.map { [$0] } ?? []) + helpers }
    var totalFootprint: UInt64 { all.reduce(0) { $0 &+ $1.physFootprint } }
    var totalResident: UInt64 { all.reduce(0) { $0 &+ $1.resident } }
    var totalCpuNs: UInt64 { all.reduce(0) { $0 &+ $1.cpuNs } }
    func count(_ kind: String) -> Int { helpers.filter { $0.kind == kind }.count }

    static func take(_ label: String, baseline: Set<Int32>) -> MemSnapshot {
        MemSnapshot(label: label,
                    wallTime: Date().timeIntervalSince1970,
                    app: ProcMetrics.selfSample(),
                    helpers: ProcMetrics.webkitHelpers(excluding: baseline))
    }

    var json: [String: Any] {
        var byKind: [String: [String: Any]] = [:]
        for k in ["app", "WebContent", "Networking", "GPU", "other-webkit"] {
            let group = all.filter { $0.kind == k }
            if group.isEmpty { continue }
            byKind[k] = [
                "count": group.count,
                "footprint_mb": group.reduce(0.0) { $0 + Double($1.physFootprint) / 1048576.0 },
                "rss_mb": group.reduce(0.0) { $0 + Double($1.resident) / 1048576.0 },
                "pids": group.map { Int($0.pid) },
            ]
        }
        return [
            "label": label,
            "wall": wallTime,
            "total_footprint_mb": Double(totalFootprint) / 1048576.0,
            "total_rss_mb": Double(totalResident) / 1048576.0,
            "webcontent_count": count("WebContent"),
            "helper_count": helpers.count,
            "by_kind": byKind,
        ]
    }
}
