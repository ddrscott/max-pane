import Foundation

/// Input on its way to a session, cut into pieces a pty-host will take whole.
///
/// pty-hosts older than relay-tty 1.23 dropped everything past about 1 KB of a
/// single `DATA` message, and a session keeps the pty-host it was started with
/// for as long as it lives, so "the server was upgraded" says nothing about
/// the session in front of you. Nothing on the wire tells a client which kind
/// it is talking to. So no `DATA` message this client sends carries more than
/// `limit` bytes, whatever it is: a paste, a held buffer flushed on reconnect,
/// a burst of mouse reports.
///
/// Here, in the client, rather than in the app: the spike bench under
/// `spikes/m7-remote-relay` links this module, so the cut it measures is the
/// cut the app makes.
public enum InputChunks {
    /// Under the ~1 022 bytes the old pty-host kept, with room to spare.
    public static let limit = 1000

    /// `bytes` in order, in pieces of at most `limit`, none of which ends in
    /// the middle of a UTF-8 sequence.
    ///
    /// A piece is a message, and a message is handed to the PTY in one write.
    /// Half a character at the end of a write is harmless to a byte stream and
    /// not to everything that reads one: a line editor that redraws between
    /// two reads shows the first half as garbage. A cut backs up to the start
    /// of the character it would have split, which costs at most three bytes.
    /// Bytes that are not UTF-8 at all — a run of continuation bytes longer
    /// than a piece — are cut at `limit` rather than looped over for ever.
    public static func split(_ bytes: [UInt8], limit: Int = InputChunks.limit) -> [ArraySlice<UInt8>] {
        var pieces: [ArraySlice<UInt8>] = []
        pieces.reserveCapacity(bytes.count / max(limit, 1) + 1)
        var start = 0
        while start < bytes.count {
            let end = self.end(ofPieceAt: start, in: bytes, limit: limit)
            pieces.append(bytes[start..<end])
            start = end
        }
        return pieces
    }

    /// Where the piece that starts at `start` ends. For a sender that takes
    /// one piece at a time off the front of a buffer that is still growing.
    public static func end(ofPieceAt start: Int, in bytes: [UInt8], limit: Int = InputChunks.limit) -> Int {
        let end = min(start + max(limit, 1), bytes.count)
        guard end < bytes.count else { return end }
        var cut = end
        while cut > start, bytes[cut] & 0b1100_0000 == 0b1000_0000 { cut -= 1 }
        return cut > start ? cut : end
    }
}
