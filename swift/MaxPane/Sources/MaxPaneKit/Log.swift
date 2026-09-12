import Foundation

/// Diagnostics to stderr.
///
/// The app is normally launched from a bundle with nowhere to look, so anything
/// that fails quietly is invisible — a pane that never attaches looks exactly
/// like a session with no output. Run the binary directly to see these:
///
/// ```sh
/// MAXPANE_WINDOWED=1 ./build/MaxPane.app/Contents/MacOS/MaxPane
/// ```
///
/// Set `MAXPANE_DEBUG=1` for the chatty ones.
public enum Log {
    private static let debugEnabled = ProcessInfo.processInfo.environment["MAXPANE_DEBUG"] != nil

    /// Something went wrong that the user may notice. Always printed.
    public static func warn(_ message: @autoclosure () -> String) {
        emit("warn", message())
    }

    /// Routine detail. Printed only with MAXPANE_DEBUG=1.
    public static func debug(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        emit("debug", message())
    }

    private static func emit(_ level: String, _ message: String) {
        FileHandle.standardError.write(Data("maxpane \(level): \(message)\n".utf8))
    }
}
