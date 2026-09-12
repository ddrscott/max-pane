import Foundation

/// Accumulates bytes across reads and yields complete frames.
/// Mirrors shared/framing.ts:20-29 — zero-length frames are SKIPPED, not errors.
public struct FrameParser {
    private var pending: [UInt8] = []

    public init() {}

    /// Appends `bytes` and calls `sink(type, payloadSlice)` for each complete frame.
    /// The slice is only valid for the duration of the call.
    public mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>, _ sink: (UInt8, ArraySlice<UInt8>) -> Void) {
        pending.append(contentsOf: bytes)
        var pos = 0
        while pending.count - pos >= 4 {
            let len: Int = pending.withUnsafeBufferPointer { bp in Int(beU32(bp.baseAddress! + pos)) }
            if pending.count - pos - 4 < len { break }
            if len == 0 { pos += 4; continue }                 // framing.ts:26
            let type = pending[pos + 4]
            let body = pending[(pos + 5)..<(pos + 4 + len)]
            sink(type, body)
            pos += 4 + len
        }
        if pos > 0 { pending.removeFirst(pos) }
    }

    public var bufferedBytes: Int { pending.count }
}
