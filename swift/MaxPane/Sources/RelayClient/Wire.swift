import Foundation

/// RelayTTY wire constants. Source: docs/reference/relay-integration.md §2
/// (shared/types.ts:41-86, crates/pty-host/src/main.rs:34-53).
public enum WSMsg {
    public static let data: UInt8            = 0x00
    public static let resize: UInt8          = 0x01
    public static let exit: UInt8            = 0x02
    public static let bufferReplay: UInt8    = 0x03
    public static let title: UInt8           = 0x04
    public static let notification: UInt8    = 0x05
    public static let resume: UInt8          = 0x10
    public static let sync: UInt8            = 0x11
    public static let sessionState: UInt8    = 0x12
    public static let bufferReplayGz: UInt8  = 0x13
    public static let sessionMetrics: UInt8  = 0x14
    /// Synthesized by the Node WS server only (§2): the full `Session` JSON,
    /// broadcast to every WS client of every session. Never on a Unix socket.
    public static let sessionUpdate: UInt8   = 0x15
    public static let clipboard: UInt8       = 0x16
    public static let image: UInt8           = 0x17
    public static let sparklineReq: UInt8    = 0x18
    public static let sparklineHist: UInt8   = 0x19
    public static let ping: UInt8            = 0x20
    /// The WS bridge's answer to `ping`; pty-host knows neither (§5).
    public static let pong: UInt8            = 0x21
    public static let detach: UInt8          = 0x22
    public static let clearScrollback: UInt8 = 0x23
    public static let setTitle: UInt8        = 0x24
    public static let signal: UInt8          = 0x25
    public static let observe: UInt8         = 0x26
}

@inline(__always)
func beU32(_ b: UnsafePointer<UInt8>) -> UInt32 {
    (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

@inline(__always)
public func beF64(_ bytes: ArraySlice<UInt8>) -> Double? {
    guard bytes.count >= 8 else { return nil }
    var raw: UInt64 = 0
    var i = bytes.startIndex
    for _ in 0..<8 { raw = (raw << 8) | UInt64(bytes[i]); i += 1 }
    return Double(bitPattern: raw)
}

@inline(__always)
public func beU16(_ bytes: ArraySlice<UInt8>, _ o: Int) -> Int {
    let i = bytes.startIndex + o
    return (Int(bytes[i]) << 8) | Int(bytes[i + 1])
}

/// A payload: `[type][data]`, no length. This is exactly one WebSocket
/// binary message (§1, "WebSocket framing"); the Unix socket wraps it.
public func encodePayload(_ type: UInt8, _ data: [UInt8] = []) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(1 + data.count)
    out.append(type)
    out.append(contentsOf: data)
    return out
}

/// Length-prefixed frame: [u32 BE payload_len][type][data], payload_len INCLUDES the type byte.
public func encodeFrame(_ type: UInt8, _ payload: [UInt8] = []) -> [UInt8] {
    lengthPrefixed(encodePayload(type, payload))
}

/// The Unix-socket wrapper around a payload (§1): 4-byte big-endian length
/// that counts the type byte.
public func lengthPrefixed(_ payload: [UInt8]) -> [UInt8] {
    let n = UInt32(payload.count)
    var out = [UInt8]()
    out.reserveCapacity(4 + payload.count)
    out.append(UInt8((n >> 24) & 0xff)); out.append(UInt8((n >> 16) & 0xff))
    out.append(UInt8((n >> 8) & 0xff));  out.append(UInt8(n & 0xff))
    out.append(contentsOf: payload)
    return out
}

/// `RESUME` as a payload (no length prefix); the transport wraps it if it must.
public func encodeResume(offset: Double, maxReplayBytes: Double? = nil) -> [UInt8] {
    var p = [UInt8]()
    func put(_ d: Double) {
        let r = d.bitPattern
        for s in stride(from: 56, through: 0, by: -8) { p.append(UInt8((r >> UInt64(s)) & 0xff)) }
    }
    put(offset)
    if let m = maxReplayBytes { put(m) }
    return encodePayload(WSMsg.resume, p)
}

/// `RESIZE` as a payload (no length prefix).
public func encodeResize(cols: Int, rows: Int) -> [UInt8] {
    let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
    return encodePayload(WSMsg.resize, [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)])
}

/// `SET_TITLE` as a payload (no length prefix): `[0x24] + UTF-8`, what
/// relay-tty's `encodeSetTitle` builds (`messages.ts:53`). pty-host trims
/// it, pins it over the program's own OSC titles and broadcasts `TITLE` to
/// every client; empty unpins and broadcasts nothing (§11).
public func encodeSetTitle(_ title: String) -> [UInt8] {
    encodePayload(WSMsg.setTitle, Array(title.utf8))
}
