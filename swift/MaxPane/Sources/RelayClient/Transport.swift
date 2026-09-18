import Foundation

/// Why a transport stopped delivering.
///
/// `isFinal` is the one bit a reconnect policy needs: the reference client
/// stops retrying on WebSocket close codes 4001 and 1008 (§9, gotcha 30),
/// and an `EXIT` is handled by the session before the transport ever closes.
public struct RelayClose: Sendable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// Orderly EOF, or a WS close with a retryable code.
        case closed
        /// A read or write failed; `errno` or the URL error code.
        case failed(Int)
        /// No inbound frame for `zombieAfter` seconds (§5). WS only.
        case zombie
        /// The server refused the credential: WS close 4001 or 1008.
        case authRefused
    }
    public let kind: Kind
    /// The WebSocket close code when there was one; 0 on a Unix socket.
    public let code: Int
    public let reason: String

    public init(kind: Kind, code: Int = 0, reason: String = "") {
        self.kind = kind; self.code = code; self.reason = reason
    }

    /// `true` when reconnecting would only be refused again.
    public var isFinal: Bool { kind == .authRefused }

    public var description: String {
        switch kind {
        case .closed:        return code == 0 ? "closed" : "closed \(code) \(reason)"
        case .failed(let e): return "failed \(e) \(reason)"
        case .zombie:        return "zombie"
        case .authRefused:   return "auth refused \(code) \(reason)"
        }
    }
}

/// Bytes in and out of one attached session, as payloads.
///
/// A payload is `[type][data]` and nothing else: one WebSocket binary
/// message is one payload, and the Unix socket wraps the same bytes in a
/// 4-byte length (§1). `RelaySession` speaks only payloads, so its handshake,
/// offset arithmetic and gzip are the same over both, which spike M7 proved
/// by attaching the same session both ways.
///
/// `open(firstPayload:)` must put the first payload on the wire before it
/// returns or, for a transport that connects asynchronously, before any other
/// work: pty-host gives a client 100 ms from accept to send `RESUME` (§3.2)
/// and drops a late one.
public protocol RelayTransport: AnyObject {
    /// Every complete inbound payload, on the transport's queue. The slice is
    /// valid only for the duration of the call.
    var onPayload: ((UInt8, ArraySlice<UInt8>) -> Void)? { get set }
    /// Once, after which nothing more arrives.
    var onClosed: ((RelayClose) -> Void)? { get set }

    /// Monotonic seconds (`now()`) when the connection was established, 0 until then.
    var tConnected: Double { get }
    /// Monotonic seconds when the first payload was handed to the wire.
    var tFirstSent: Double { get }

    func open(firstPayload: [UInt8]) throws
    func send(_ payload: [UInt8])
    func close()
}
