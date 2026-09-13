import AppKit

/// Every action the app can take, and the key that runs it.
///
/// PRD §8: "Keyboard-first: every action has a shortcut; the mouse is optional."
/// Keeping the whole map in one enum is how that stays true — a new action has
/// to declare its key here or it does not exist.
public enum Command: String, CaseIterable, Sendable {
    case openAnything
    case openPages
    case openSessions
    case reload
    case hardReload
    case editAddress
    case zoomIn
    case zoomOut
    case zoomReset
    case newTerminalLane
    case splitRight
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
    case toggleGallery
    case toggleKeepLive
    case dockLaneLeft
    case dockLaneRight
    case toggleDockMode
    case focusDockLeft
    case focusDockRight
    case peekDesktop
    case widenLane
    case narrowLane
    case claimSession
    case showMemory
    case pairWithNext
    case exportStrip
    case importStrip
    case importBrowserHistory
    case showHistory
    case bookmarkPage
    case fillPassword
    case savePassword
    case importBrowserPasswords
    case toggleSpan
    case showHelp

    public var title: String {
        switch self {
        case .openAnything: return "Open…"
        case .openPages: return "Open a Page…"
        case .openSessions: return "Attach a Session…"
        case .reload: return "Reload"
        case .hardReload: return "Reload Ignoring Cache"
        case .editAddress: return "Edit Address"
        case .zoomIn: return "Bigger Text"
        case .zoomOut: return "Smaller Text"
        case .zoomReset: return "Actual Size"
        case .newTerminalLane: return "New Terminal Lane"
        case .splitRight: return "Split Right"
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
        case .toggleGallery: return "Toggle Gallery"
        case .toggleKeepLive: return "Keep Lane Loaded"
        case .dockLaneLeft: return "Dock Lane Left"
        case .dockLaneRight: return "Dock Lane Right"
        case .toggleDockMode: return "Dock Floats Over Strip"
        case .focusDockLeft: return "Focus Left Dock"
        case .focusDockRight: return "Focus Right Dock"
        case .peekDesktop: return "Peek Desktop"
        case .widenLane: return "Widen Lane"
        case .narrowLane: return "Narrow Lane"
        case .claimSession: return "Resize Session to This Lane…"
        case .showMemory: return "Memory"
        case .pairWithNext: return "Pair With Lane to the Right"
        case .exportStrip: return "Export Strip…"
        case .importStrip: return "Import Strip…"
        case .importBrowserHistory: return "Import From Another Browser…"
        case .showHistory: return "History"
        case .bookmarkPage: return "Keep This Page…"
        case .fillPassword: return "Fill Password"
        case .savePassword: return "Save a Password for This Site…"
        case .importBrowserPasswords: return "Import Passwords From Another Browser…"
        case .toggleSpan: return "Span Lane (2× Width)"
        case .showHelp: return "Keyboard Shortcuts"
        }
    }

    /// The key this command ships with. AppKit wants the lowercase character
    /// and an explicit `.shift` when the binding is shifted.
    ///
    /// This is the **default**, not necessarily the key that runs it: the
    /// config file's `keys` object can move any of these, and `Keymap.active`
    /// is what the menu, the ⌘/ sheet and the key monitor read. The switch
    /// stays here because it is the thing that makes an action without a key
    /// impossible to write.
    public var defaultShortcut: (String, NSEvent.ModifierFlags) {
        switch self {
        // ⌘O is the only door. "Something new goes on the strip" was three keys
        // — ⌘T for a command or a URL, ⌘Y for a page you have been to, ⌘O for a
        // session that is already running — and each of them could see a third
        // of the answer. ⌘T stays as an alternate below, because it is a key
        // the README taught and it now opens the same thing. ⌘D was the other
        // such alternate until bookmarks needed it — see `bookmarkPage`.
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
        // ⌘L, the way it is in every browser: the address, whole and selected,
        // so ⌘L ⌘C copies it and ⌘L then typing replaces it. It was passed over
        // once on the grounds that it "already means something else here" —
        // that was ⌘L for a new web lane, which ⌘O took over long ago, so the
        // key has been free and dead ever since. It has to be *here* rather
        // than a pane key: a focused `WKWebView` claims every ⌘-chord in
        // `performKeyEquivalent`, and `claims(_:)` below only rescues the
        // chords this file declares.
        case .editAddress:     return ("l", [.command])
        // ⌘D is two conventions colliding on one key: a browser keeps the
        // page, a terminal splits. Both keep it, and which one runs is which
        // pane you are in — `canPerform` enables exactly one of them, and the
        // menu routes the chord to the enabled item. That is also the bug this
        // fixed: with only `bookmarkPage` on ⌘D, the item was disabled in a
        // terminal, the menu declined the key, and Ghostty typed a `d`.
        case .splitRight:      return ("d", [.command])
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
        // Lanes ⇄ Gallery. Beside ⌘G because both change what the window is
        // showing of the strip without changing the strip. **Not Esc**, which
        // would have been the obvious "leave this view" key: in the gallery Esc
        // belongs to the focused tile, because answering an agent's prompt from
        // its thumbnail is what the gallery is for.
        case .toggleGallery:   return ("g", [.command, .option])
        // ⇧⌘P kept its key and lost its word. It used to be "Pin Lane", which
        // meant "never evict this lane" — and the owner has since said plainly
        // that pinning is what he calls docking. The key is not the word, and
        // moving a binding people have in their fingers to rename a concept
        // costs more than it buys.
        case .toggleKeepLive:  return ("p", [.command, .shift])
        // ⌘[ / ⌘] move focus between lanes; ⌃⌘[ / ⌃⌘] push a lane out to that
        // edge entirely. Same axis, one modifier further. Both toggle, so the
        // key that docked a lane is the key that gives the edge back.
        case .dockLaneLeft:    return ("[", [.command, .control])
        case .dockLaneRight:   return ("]", [.command, .control])
        // ⌘\ spans a lane to 2×; ⌃⌘\ is the other question about how much room
        // something takes — whether the dock floats over the strip or takes its
        // width out of it.
        case .toggleDockMode:  return ("\\", [.command, .control])
        // The way in, and the way out, for the keyboard.
        //
        // ⌘[ / ⌘] skip the docks — the owner asked for that directly, and it is
        // right: those keys scroll the strip, and a docked lane does not
        // scroll, so landing on one would be a keypress with no motion and a
        // focus ring that jumped across the window and back. But PRD §8 says
        // every action has a shortcut and the mouse is optional, and a music
        // page you cannot focus is a music page you cannot pause without
        // reaching for the trackpad.
        //
        // So: one key per edge, and each one is a toggle. Pressing it while
        // focus is already in that dock returns focus to the lane it came from.
        // A single "go to the dock and come back" key was the tempting cheaper
        // option and it is worse with two docks: which of them it means is
        // hidden state the user cannot see. Naming the edge is never ambiguous,
        // and it matches ⌘[ / ⌘] on the same axis.
        case .focusDockLeft:   return ("[", [.command, .option])
        case .focusDockRight:  return ("]", [.command, .option])
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
        // ⌘Y opens history; ⌥⌘Y is where it comes from. The mnemonic is the
        // reason it is not next to Import Strip's ⇧⌘O — importing a strip and
        // importing two years of browsing are unrelated acts that happen to
        // share an English word.
        case .importBrowserHistory: return ("y", [.command, .option])
        // ⌘Y opens the door, ⇧⌘Y opens the record. Same letter, because they
        // are the same corpus asked two different questions — "take me back to
        // that page" and "what was I doing on Tuesday" — and a reader who has
        // one of them in their fingers should find the other by holding one
        // more key rather than by reading the help sheet.
        case .showHistory:     return ("y", [.command, .shift])
        // ⌘D, the way it is in every browser, and it cost something: ⌘D was an
        // alternate for ⌘O. That was defensible while there was nothing else
        // for the key to mean — it is the key a `⌘D` muscle reaches for to
        // *keep a page*, and a door that already answers to ⌘O and ⌘T did not
        // need a third name as much as this needs its first.
        case .bookmarkPage:    return ("d", [.command])
        // ⌘L is the address; ⌥⌘L is the other thing at the top of a page you
        // have to type into. One key, pressed while looking at the form, is
        // the whole of what makes filling safe — see `PasswordFill` — so it is
        // deliberately a key and not a thing that happens on load.
        case .fillPassword:    return ("l", [.command, .option])
        // ⇧⌘L, beside it, for the other direction. Saving is explicit too:
        // Max Pane does not watch what you type into password fields, so
        // nothing offers to save one unless you ask.
        case .savePassword:    return ("l", [.command, .shift])
        // With the other import, not with the other passwords: ⌥⌘Y brings a
        // browser's history and bookmarks, ⌃⌥⌘Y brings its passwords. They are
        // deliberately not one key — one of them ends with the Keychain asking
        // the user a question, and a wizard that walks into that on the way to
        // importing history would be a browser helping itself to passwords.
        case .importBrowserPasswords: return ("y", [.command, .option, .control])
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
    public var defaultAlternateShortcuts: [(String, NSEvent.ModifierFlags)] {
        switch self {
        // ⌘T used to open a picker of its own. It now opens ⌘O, and it opens
        // it identically — same window, same rows, same placement. Keeping it
        // as a near-variant was the tempting move and the wrong one: a second
        // picker that looks like the first and behaves slightly differently is
        // worse than the three honest ones this replaced.
        //
        // ⌘D was the other such alternate until bookmarks needed it, which is
        // the first thing that has ever wanted that key here. See
        // `bookmarkPage` above.
        case .openAnything: return [("t", [.command])]
        default: return []
        }
    }

    /// The one command this is allowed to hold a chord alongside.
    ///
    /// Two commands may share a key only when they can never both be offered,
    /// because then there is no ambiguity to resolve: ⌘D keeps the page in a
    /// web pane and splits to the right in a terminal, `canPerform` enables
    /// exactly one of the two, and the menu routes the chord to whichever item
    /// is live. Every *other* collision stays an error the keymap reports —
    /// this is a declared exception, not a hole.
    public var sharesChordWith: Command? {
        switch self {
        case .bookmarkPage: return .splitRight
        case .splitRight: return .bookmarkPage
        default: return nil
        }
    }

    /// The keys that actually run this command, after the config file has had
    /// its say. The first is the one a menu item can carry; the rest are
    /// matched in the window's key monitor. Empty means deliberately unbound.
    public var chords: [KeyChord] { Keymap.active.chords(for: self) }

    /// The chord a menu item may advertise, or nil when there is nothing for it
    /// to show.
    ///
    /// A menu item's key equivalent is matched by AppKit *before* the responder
    /// chain, which is exactly what is wanted for a ⌘-chord and exactly what is
    /// not wanted for anything without one: Esc as a key equivalent would be
    /// taken from the find field and the address field, which have their own
    /// uses for it. Those chords are handled in the window's key monitor
    /// instead, where the first responder can be consulted first — so the item
    /// is still listed, still clickable, and simply carries no key.
    public var menuChord: KeyChord? {
        guard let first = chords.first, first.modifiers.contains(.command) else { return nil }
        return first
    }

    /// Whether the app has claimed this key for itself.
    ///
    /// Asked by a web pane before it lets the page it is showing see a ⌘-chord.
    /// A focused `WKWebView` answers YES to `performKeyEquivalent` for every
    /// ⌘-chord and hands it to the page — and that walk runs *before* the main
    /// menu, so a page that keeps ⌘O is a page from which ⌘O never opens the
    /// picker. Measured with the web view as first responder: ⌘O, ⌘T and ⌘Y
    /// were all swallowed there. No browser lets a page bind its chrome keys,
    /// and this is where that is decided.
    ///
    /// It reads the *resolved* keymap, so a chord someone chose in the config
    /// file is rescued the same way a default one is — otherwise every
    /// configurable key would die inside a web pane, which is most of them.
    ///
    /// ⌘-chords only. Esc is a key a page has its own uses for — leaving a
    /// video, closing a modal — and which no menu item carries.
    public static func claims(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let typed = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        return Keymap.active.claimed.contains(
            KeyChord(key: typed, modifiers: event.modifierFlags))
    }

    /// Which menu this belongs under.
    public var menu: MenuSection {
        switch self {
        case .openAnything, .openPages, .openSessions, .newTerminalLane,
             .splitRight, .splitDown: return .file
        case .closePane, .closeLane: return .file
        case .focusLeft, .focusRight, .focusUp, .focusDown, .search, .gather, .ungather: return .navigate
        case .toggleGallery: return .view
        case .moveLaneLeft, .moveLaneRight, .toggleSidebar, .toggleKeepLive,
             .widenLane, .narrowLane, .peekDesktop: return .view
        case .dockLaneLeft, .dockLaneRight, .toggleDockMode: return .view
        // Under Navigate, not View: these move focus, which is the same thing
        // ⌘[ / ⌘] do and the reason they exist at all.
        case .focusDockLeft, .focusDockRight: return .navigate
        case .claimSession: return .file
        case .showMemory, .showHelp: return .view
        case .reload, .hardReload, .editAddress: return .navigate
        // Under Navigate with ⌘Y's picker, not under View with the dashboards:
        // what it is for is going back to a page, and the two keys that do that
        // should be found in the same place.
        case .showHistory: return .navigate
        case .zoomIn, .zoomOut, .zoomReset: return .view
        case .pairWithNext: return .navigate
        case .exportStrip, .importStrip, .importBrowserHistory: return .file
        // Under Navigate with ⌘Y and ⇧⌘Y: keeping a page and going back to one
        // are the same thought about the same corpus, and the File menu is
        // where panes are made.
        case .bookmarkPage: return .navigate
        // Fill and save sit under Navigate with ⌘L and ⌘D: they are things you
        // do to the page in front of you. The import is a File-menu act, with
        // the other import.
        case .fillPassword, .savePassword: return .navigate
        case .importBrowserPasswords: return .file
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
