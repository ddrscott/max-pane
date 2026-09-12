import Foundation
import CRelayGzip

public enum GzipError: Error { case inflateFailed(Int32) }

/// BUFFER_REPLAY_GZ (0x13) is a complete RFC1952 gzip member, NOT raw deflate and NOT zlib.
/// Apple's Compression COMPRESSION_ZLIB is raw DEFLATE and fails on this input; we use
/// zlib's inflateInit2(&s, 16 + MAX_WBITS).  (reference §4)
public func gunzip(_ input: ArraySlice<UInt8>) throws -> [UInt8] {
    let bytes = Array(input)
    var outPtr: UnsafeMutablePointer<UInt8>? = nil
    var outLen: Int = 0
    let rc = bytes.withUnsafeBufferPointer { bp in
        crelay_gunzip(bp.baseAddress, bp.count, &outPtr, &outLen)
    }
    guard rc == 0, let p = outPtr else { throw GzipError.inflateFailed(rc) }
    defer { crelay_free(p) }
    return Array(UnsafeBufferPointer(start: p, count: outLen))
}
