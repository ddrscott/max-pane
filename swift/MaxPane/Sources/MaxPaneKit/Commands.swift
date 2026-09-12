import AppKit

/// Every action the app can take, and the key that runs it.
///
/// PRD §8: "Keyboard-first: every action has a shortcut; the mouse is optional."
/// Keeping the whole map in one enum is how that stays true — a new action has
/// to declare its key here or it does not exist.
public enum Command: String, CaseIterable {
    case openAnything
    case openPages
    case openSessions
    case reload
    case hardReload
    case zoomIn
    case zoomOut
    case zoomReset
    case newTerminalLane
    case splitDown
    case closePane
    case closeLane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case moveLaneLeft
    case moveLaneRight
    case toggleSidebar
    case search
    case gather
    case ungather
    case togglePinned
    case peekDesktop
    case widenLane
    case narrowLane
    case claimSession
    case showMemory
    case pairWithNext
    case exportStrip
    case importStrip
    case toggleSpan
    case showHelp

    public var title: String {
        switch self {
        case .openAnything: return "Open…"
        case .openPages: return "Open a Page…"
        case .openSessions: return "Attach a Session…"
        case .reload: return "Reload"
        case .hardReload: return "Reload Ignoring Cache"
        case .zoomIn: return "Bigger Text"
        case .zoomOut: return "Smaller Text"
        case .zoomReset: return "Actual Size"
        case .newTerminalLane: return "New Terminal Lane"
        case .splitDown: return "Split Down"
        case .closePane: return "Close Pane"
        case .closeLane: return "Close Lane"
        case .focusLeft: return "Focus Lane Left"
        case .focusRight: return "Focus Lane Right"
        case .focusUp: return "Focus Pane Above"
        case .focusDown: return "Focus Pane Below"
        case .moveLaneLeft: return "Move Lane Left"
        case .moveLaneRight: return "Move Lane Right"
        case .toggleSidebar: return "Toggle Sidebar"
        case .search: return "Search…"
        case .gather: return "Gather Project"
        case .ungather: return "Leave Gather View"
        case .togglePinned: return "Pin Lane"
        case .peekDesktop: return "Peek Desktop"
        case .widenLane: return "Widen Lane"
        case .narrowLane: return "Narrow Lane"
        case .claimSession: return "Resize Session to This Lane…"
        case .showMemory: return "Memory"
        case .pairWithNext: return "Pair With Lane to the Right"
        case .exportStrip: return "Export Strip…"
        case .importStrip: return "Import Strip…"
        case .toggleSpan: return "Span Lane (2× Width)"
        case .showHelp: return "Keyboard Shortcuts"
        }
    }

    /// (key equivalent, modifier mask). AppKit wants the lowercase character and
    /// an explicit `.shift` when the binding is shifted.
    public var shortcut: (String, NSEvent.ModifierFlags) {
        switch self {
        // ⌘O is the only door. "Something new goes on the strip" was three keys
        // — ⌘T for a command or a URL, ⌘Y for a page you have been to, ⌘O for a
        // session that is already running — and each of them could see a third
        // of the answer. ⌘T and ⌘D stay as alternates below, because they are
        // the keys the README taught and they now open the same thing.
        //
        // ⌘Y and ⌥⌘O open that same picker with its scope already narrowed, so
        // "pages only" costs one key instead of ⌘O and two presses of ⇥. They
        // are not other pickers; the window, the rows and the keys are the same.
        case .openAnything:    return ("o", [.command])
        case .openPages:       return ("y", [.command])
        case .openSessions:    return ("o", [.command, .option])
        // The pane under the keyboard, terminal or page alike — one pair of
        // keys, because "this column is too small to read" is one thought.
        // ⌃⌘= and ⌃⌘- resize the *lane*; these resize what is inside it.
        case .zoomIn:          return ("=", [.command])
        case .zoomOut:         return ("-", [.command])
        case .zoomReset:       return ("0", [.command])
        case .newTerminalLane: return ("t", [.command, .shift])
        // ⌘R is reload, the way it is in every browser. Running a command is
        // ⌘O's job now, which is a better door for it than a prompt was.
        case .reload:          return ("r", [.command])
        case .hardReload:      return ("r", [.command, .shift])
        case .splitDown:       return ("d", [.command, .shift])
        case .closePane:       return ("w", [.command])
        case .closeLane:       return ("w", [.command, .shift])
        case .focusLeft:       return ("[", [.command])
        case .focusRight:      return ("]", [.command])
        case .focusUp:         return ("[", [.command, .shift])
        case .focusDown:       return ("]", [.command, .shift])
        // PRD §7.2 names these explicitly.
        case .moveLaneLeft:    return ("\u{2190}", [.command, .shift])
        case .moveLaneRight:   return ("\u{2192}", [.command, .shift])
        case .toggleSidebar:   return ("b", [.command])
        case .search:          return ("p", [.command])
        case .gather:          return ("g", [.command])
        // Esc, which is not a menu key equivalent — handled in the responder chain.
        case .ungather:        return ("\u{1b}", [])
        case .togglePinned:    return ("p", [.command, .shift])
        // PRD §16: the escape hatch to the rest of macOS.
        case .peekDesktop:     return ("\u{21e5}", [.command, .option])
        case .widenLane:       return ("=", [.command, .control])
        case .narrowLane:      return ("-", [.command, .control])
        // Deliberately awkward. It reshapes the PTY for every other client,
        // including a phone, so it should not sit next to anything routine.
        case .claimSession:    return ("r", [.command, .control, .shift])
        case .showMemory:      return ("i", [.command, .option])
        case .pairWithNext:    return ("p", [.command, .option])
        case .exportStrip:     return ("s", [.command, .shift])
        case .importStrip:     return ("o", [.command, .shift])
        case .toggleSpan:      return ("\\", [.command])
        // The one everybody reaches for when they do not know the others.
        case .showHelp:        return ("/", [.command])
        }
    }

    /// Other keys for the same action, for the ones muscle memory has more than
    /// one name for. AppKit gives a menu item exactly one key equivalent, so
    /// these are matched in the window's key monitor — but they are declared
    /// here, because a shortcut that is not in this file is a shortcut nobody
    /// can find.
    public var alternateShortcuts: [(String, NSEvent.ModifierFlags)] {
        switch self {
        // ⌘T and ⌘D used to open a picker of their own. They now open ⌘O, and
        // they open it identically — same window, same rows, same placement.
        // Keeping them as near-variants was the tempting move and the wrong
        // one: a second picker that looks like the first and behaves slightly
        // differently is worse than the three honest ones this replaced.
        case .openAnything: return [("t", [.command]), ("d", [.command])]
        default: return []
        }
    }

    /// Which menu this belongs under.
    public var menu: MenuSection {
        switch self {
        case .openAnything, .openPages, .openSessions, .newTerminalLane, .splitDown: return .file
        case .closePane, .closeLane: return .file
        case .focusLeft, .focusRight, .focusUp, .focusDown, .search, .gather, .ungather: return .navigate
        case .moveLaneLeft, .moveLaneRight, .toggleSidebar, .togglePinned,
             .widenLane, .narrowLane, .peekDesktop: return .view
        case .claimSession: return .file
        case .showMemory, .showHelp: return .view
        case .reload, .hardReload: return .navigate
        case .zoomIn, .zoomOut, .zoomReset: return .view
        case .pairWithNext: return .navigate
        case .exportStrip, .importStrip: return .file
        case .toggleSpan: return .view
        }
    }
}

public enum MenuSection: String, CaseIterable {
    case file = "File"
    case navigate = "Navigate"
    case view = "View"
}

/// What handles a `Command`. One method, so adding a command is one `case` in
/// the switch and one entry above — never a new delegate protocol.
@MainActor
public protocol CommandHandling: AnyObject {
    func perform(_ command: Command)
    /// Grey out what cannot be done right now (e.g. Leave Gather View when not
    /// gathered).
    func canPerform(_ command: Command) -> Bool
}
