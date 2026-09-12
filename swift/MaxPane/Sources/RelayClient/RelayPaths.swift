import Foundation

/// Where RelayTTY keeps its runtime state.
///
/// One definition, because the app and the protocol client must agree — and
/// because `~/.relay-tty` is pty-host's directory, not ours. MaxPane reads these
/// paths and never writes them.
public enum RelayPaths {
    public static var home: String { NSHomeDirectory() }
    public static var root: String { home + "/.relay-tty" }
    public static var sessionsDir: String { root + "/sessions" }
    public static var socketsDir: String { root + "/sockets" }
    public static func sessionJSON(for id: String) -> String { sessionsDir + "/\(id).json" }
    public static func socket(for id: String) -> String { socketsDir + "/\(id).sock" }
}
