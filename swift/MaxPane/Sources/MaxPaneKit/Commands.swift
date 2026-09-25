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
    case runCommand
    case reload
    case hardReload
    case editAddress
    case zoomIn
    case zoomOut
    case zoomReset
    case newTerminalLane
    case newPrivateWebLane
    case splitRight
    case splitDown
    case closePane
    case closeLane
    case endSession
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case moveLaneLeft
    case moveLaneRight
    case toggleSidebar
    case search
    case nextAttention
    case previousAttention
    case showAttention
    case gather
    case ungather
    case toggleGallery
    case toggleExpandTile
    case toggleKeepLive
    case renameLane
    case dockLaneLeft
    case dockLaneRight
    case toggleDockMode
    case focusDockLeft
    case focusDockRight
    case peekDesktop
    case widenLane
    case narrowLane
    case claimSession
    case copyWithStyles
    case copyMode
    case pasteWithoutAsking
    case pasteEscaped
    case pasteAsBase64
    case pasteBase64Decoded
    case pasteFileAsBase64
    case pasteSlowly
    case advancedPaste
    case pasteHistory
    case clearPasteHistory
    case clearScrollback
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
    case laneSizeSmall
    case laneSizeMedium
    case laneSizeLarge
    case laneSizeCycle
    case toggleMaximizePane
    case toggleMobileLayout
    case toggleBlocking
    case toggleMute
    case muteOthers
    case muteAll
    case printPage
    case savePDF
    case capturePane
    case captureFullPage
    case showHelp
    case showChangelog
    case checkForUpdates
    case updateApp
    case showSettings

    public var title: String {
        switch self {
        case .openAnything: return "Open…"
        case .openPages: return "Open a Page…"
        case .openSessions: return "Attach a Session…"
        case .runCommand: return "Run Command…"
        case .reload: return "Reload"
        case .hardReload: return "Reload Ignoring Cache"
        case .editAddress: return "Edit Address"
        case .zoomIn: return "Bigger Text"
        case .zoomOut: return "Smaller Text"
        case .zoomReset: return "Actual Size"
        case .newTerminalLane: return "New Terminal Lane"
        case .newPrivateWebLane: return "New Private Web Lane"
        case .splitRight: return "Split Right"
        case .splitDown: return "Split Down"
        case .closePane: return "Close Pane"
        case .closeLane: return "Close Lane"
        case .endSession: return "End Session…"
        case .focusLeft: return "Focus Lane Left"
        case .focusRight: return "Focus Lane Right"
        case .focusUp: return "Focus Pane Above"
        case .focusDown: return "Focus Pane Below"
        case .moveLaneLeft: return "Move Lane Left"
        case .moveLaneRight: return "Move Lane Right"
        case .toggleSidebar: return "Toggle Sidebar"
        case .search: return "Search…"
        case .nextAttention: return "Next Attention"
        case .previousAttention: return "Previous Attention"
        case .showAttention: return "Attention…"
        case .gather: return "Gather Project"
        case .ungather: return "Leave Gather View"
        case .toggleGallery: return "Toggle Gallery"
        case .toggleExpandTile: return "Expand Tile"
        case .toggleKeepLive: return "Keep Lane Loaded"
        case .renameLane: return "Rename Lane…"
        case .dockLaneLeft: return "Dock Lane Left"
        case .dockLaneRight: return "Dock Lane Right"
        case .toggleDockMode: return "Dock Floats Over Strip"
        case .focusDockLeft: return "Focus Left Dock"
        case .focusDockRight: return "Focus Right Dock"
        case .peekDesktop: return "Peek Desktop"
        case .widenLane: return "Widen Lane"
        case .narrowLane: return "Narrow Lane"
        case .claimSession: return "Resize Session to This Lane…"
        case .copyWithStyles: return "Copy with Styles"
        case .copyMode: return "Copy Mode"
        case .pasteWithoutAsking: return "Paste Without Asking"
        case .pasteEscaped: return "Paste Escaped"
        case .pasteAsBase64: return "Paste as Base64"
        case .pasteBase64Decoded: return "Paste Base64-Decoded"
        case .pasteFileAsBase64: return "Paste File as Base64…"
        case .pasteSlowly: return "Paste Slowly"
        case .advancedPaste: return "Advanced Paste…"
        case .pasteHistory: return "Paste History…"
        case .clearPasteHistory: return "Clear Paste History…"
        case .clearScrollback: return "Clear Scrollback"
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
        case .laneSizeSmall: return "Lane Size: Small"
        case .laneSizeMedium: return "Lane Size: Medium"
        case .laneSizeLarge: return "Lane Size: Extra Large"
        case .laneSizeCycle: return "Cycle Lane Size"
        case .toggleMaximizePane: return "Maximize Pane"
        case .toggleMobileLayout: return "Mobile Layout"
        case .toggleBlocking: return "Block Ads on This Site"
        case .toggleMute: return "Mute Pane"
        case .muteOthers: return "Mute Other Panes"
        case .muteAll: return "Mute All"
        case .printPage: return "Print…"
        case .savePDF: return "Save as PDF…"
        case .capturePane: return "Capture Pane"
        case .captureFullPage: return "Capture Full Page"
        case .showHelp: return "Keyboard Shortcuts"
        case .showChangelog: return "What's New…"
        case .checkForUpdates: return "Check for Updates…"
        case .updateApp: return "Update…"
        case .showSettings: return "Settings…"
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
    public var defaultShortcut: (String, NSEvent.ModifierFlags)? {
        switch self {
        // ⌘O is the only door. "Something new goes on the strip" was three keys
        // — ⌘T for a command or a URL, ⌘Y for a page you have been to, ⌘O for a
        // session that is already running — and each of them could see a third
        // of the answer. ⌘T stays as an alternate below, because it is a key
        // the README taught and it now opens the same thing. ⌘D was the other
        // such alternate until Split Right took the key outright.
        //
        // ⌘Y and ⌥⌘O open that same picker with its scope already narrowed, so
        // "pages only" costs one key instead of ⌘O and two presses of ⇥. They
        // are not other pickers; the window, the rows and the keys are the same.
        case .openAnything:    return ("o", [.command])
        case .openPages:       return ("y", [.command])
        case .openSessions:    return ("o", [.command, .option])
        // ⌘E: the same picker with its APP scope chosen — every command by
        // name with its key beside it, the live settings, the servers. Not
        // ⇧⌘P, the key every editor gives this: that is Keep Lane Loaded
        // here, and a chord people have in their fingers stays where it is
        // (see `toggleKeepLive`); ⌥⌘P pairs lanes and ⌃⌘P prints. ⌘E is
        // nobody's: macOS reserves nothing on it, this file had nothing on
        // it, and a browser's ⌘E (Use Selection for Find) is chrome, not a
        // page's. `>` typed into ⌘O reaches the same scope.
        case .runCommand:      return ("e", [.command])
        // The pane under the keyboard, terminal or page alike — one pair of
        // keys, because "this column is too small to read" is one thought.
        // ⌃⌘= and ⌃⌘- resize the *lane*; these resize what is inside it.
        case .zoomIn:          return ("=", [.command])
        case .zoomOut:         return ("-", [.command])
        case .zoomReset:       return ("0", [.command])
        case .newTerminalLane: return ("t", [.command, .shift])
        // ⇧⌘N, the private window's key in every browser. The lane opens on a
        // blank page with the cursor in the address, the way that window does,
        // because what a private lane is for — the other account, once — has
        // no page to start from that history would know.
        case .newPrivateWebLane: return ("n", [.command, .shift])
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
        // ⌘D splits, in every pane. For a while it was two conventions on one
        // key — a browser keeps the page, a terminal splits — with `canPerform`
        // picking whichever fit the focused pane. That meant a web pane could
        // not be split from the keyboard, and the owner never once used ⌘D to
        // keep a page: history search is how a page comes back. So the split
        // owns the key and the ★ in the chrome bar is how a page is kept.
        case .splitRight:      return ("d", [.command])
        case .splitDown:       return ("d", [.command, .shift])
        case .closePane:       return ("w", [.command])
        case .closeLane:       return ("w", [.command, .shift])
        // ⌘W closes the pane and ⇧⌘W the lane; both leave the session
        // running for the sidebar to offer again. ⌃⌘W is the one that ends
        // it — one modifier further on the same key, the way ⌃⌘[ is to ⌘[,
        // and behind a sheet because it kills a program. macOS has no ⌃⌘W
        // (its ⌃⌘ chords are Space, F, Q and D) and nothing here had it.
        case .endSession:      return ("w", [.command, .control])
        case .focusLeft:       return ("[", [.command])
        case .focusRight:      return ("]", [.command])
        case .focusUp:         return ("[", [.command, .shift])
        case .focusDown:       return ("]", [.command, .shift])
        // PRD §7.2 names these explicitly.
        case .moveLaneLeft:    return ("\u{2190}", [.command, .shift])
        case .moveLaneRight:   return ("\u{2192}", [.command, .shift])
        case .toggleSidebar:   return ("b", [.command])
        case .search:          return ("p", [.command])
        // ⌘J: the next agent that needs you — BLOCKED first, then DONE, in
        // strip order from the lane you are in, wrapping (ADR-0037). Nobody
        // had the letter: macOS leaves ⌘J to apps (a text editor's Jump to
        // Selection, which no pane here is), no browser chrome binds it, and
        // nothing in this file did. ⇧⌘J walks the same ring backwards, and
        // ⌥⌘J is the list itself, the way ⌥⌘O is ⌘O's picker with a scope.
        case .nextAttention:     return ("j", [.command])
        case .previousAttention: return ("j", [.command, .shift])
        case .showAttention:     return ("j", [.command, .option])
        // Gather and Leave Gather ship with no key. The owner found gather too
        // surprising to be one keystroke away — *"Users can add a shortcut for
        // them if they know what they're doing"* — and a gather view is what let
        // the sidebar attach one session six times. The View menu keeps them;
        // `keys` binds them.
        case .gather, .ungather: return nil
        // Lanes ⇄ Gallery, both ways on ⌘G. The view he uses every day gets the
        // key, and ⌥⌘G is Google Drive's. **Not Esc** to leave: in the gallery Esc
        // belongs to the focused tile, because answering an agent's prompt from
        // its thumbnail is what the gallery is for.
        case .toggleGallery:   return ("g", [.command])
        // ⌘↩, beside ⇧⌘↩'s Maximize Pane: "open this" and "open this all the
        // way" on one key and its shift. Nothing here binds plain ⌘↩ — Return
        // appears once in this file, on Maximize Pane — `Keymap.reserved` has
        // no Return at all, and macOS keeps no system chord on it (an app's
        // Return keys are its own: Mail sends, Finder renames, and neither is
        // a service or a system binding that would reach over this window).
        // A terminal sees Ghostty's bindings cleared (ADR-0009) and a page
        // gives it up through `claims(_:)`, so it arrives from inside a tile.
        //
        // **Not Esc**, which the 2026-09-13 gallery rule already spent: in the
        // gallery Esc belongs to the focused tile, and the expanded tile is
        // exactly the tile whose agent is being answered. See `toggleGallery`
        // above and ADR-0011, amended 2026-09-24.
        case .toggleExpandTile: return ("\r", [.command])
        // ⇧⌘P kept its key and lost its word. It used to be "Pin Lane", which
        // meant "never evict this lane" — and the owner has since said plainly
        // that pinning is what he calls docking. The key is not the word, and
        // moving a binding people have in their fingers to rename a concept
        // costs more than it buys.
        case .toggleKeepLive:  return ("p", [.command, .shift])
        // ⌃⌘R. ⌘R reloads and ⇧⌘R reloads harder; ⌃⇧⌘R is the deliberately
        // awkward resize. The letter stays with the lane's name and the
        // header's double-click and ⋯ menu reach the same prompt; macOS has
        // nothing on ⌃⌘R and no browser's chrome does.
        case .renameLane:      return ("r", [.command, .control])
        // ⌘[ / ⌘] move focus between lanes; ⌃⌘[ / ⌃⌘] push a lane out to that
        // edge entirely. Same axis, one modifier further. Both toggle, so the
        // key that docked a lane is the key that gives the edge back.
        case .dockLaneLeft:    return ("[", [.command, .control])
        case .dockLaneRight:   return ("]", [.command, .control])
        // ⌘\ cycles a lane's size; ⌃⌘\ is the other question about how much
        // room something takes — whether the dock floats over the strip or takes
        // its width out of it.
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
        // ⌥⌘C, beside ⌘C, and iTerm's key for it: the same copy with its
        // colours. ⌥ is "the other one of these" throughout this file. Safari
        // has it for Show Page Source and a page may bind it, so in a web
        // pane it is the page's (`yieldsToPage`).
        case .copyWithStyles: return ("c", [.command, .option])
        // ⇧⌘C, iTerm's key for copy mode. It is Inspect Element in every
        // browser, so a web pane keeps it too.
        case .copyMode: return ("c", [.command, .shift])
        // ⌥⌘V, beside ⌘V: the same paste with the question skipped, for the
        // five lines you did mean to run. ⌥ is "the other one of these"
        // throughout this file, and no browser or page has a claim on it
        // (Paste and Match Style is ⌥⇧⌘V).
        case .pasteWithoutAsking: return ("v", [.command, .option])
        // ⌃⌘V, the third V: the clipboard as one quoted word that runs
        // nothing. Checked against this file (no other ⌃⌘ chord is on V),
        // against macOS (its ⌃⌘ chords are Space, F, Q and D) and against
        // browsers, which leave it alone.
        case .pasteEscaped: return ("v", [.command, .control])
        // No keys. Each is reached for a few times a month, from the menu,
        // by name; `keys` binds any of them.
        case .pasteAsBase64, .pasteBase64Decoded, .pasteFileAsBase64, .pasteSlowly: return nil
        // ⌥⇧⌘V, iTerm's key for the same sheet. macOS does nothing with it.
        // Apps do: it is Paste and Match Style by convention, and a page in a
        // web pane may bind it. So this is the one chord the app does not
        // take from a page (`yieldsToPage`): in a web pane the page gets the
        // key, and the command, which has nothing to do there, is grey.
        case .advancedPaste: return ("v", [.command, .option, .shift])
        // ⇧⌘H, iTerm's key for the same list. macOS has ⌘H (Hide) and ⌥⌘H
        // (Hide Others) and leaves this one alone; ⇧⌘Y is the other history,
        // the one of pages.
        case .pasteHistory: return ("h", [.command, .shift])
        // No key: it destroys something, once in a while, from a menu.
        case .clearPasteHistory: return nil
        // ⌘K, the key every Mac terminal clears on (Terminal, iTerm, Ghostty)
        // and nobody else's here. Slack, Linear and Notion bind it in the
        // page, so in a web pane it is the page's (`yieldsToPage`), the way
        // ⌥⇧⌘V is: a terminal-only command on a chord pages use.
        case .clearScrollback: return ("k", [.command])
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
        // No key. It had ⌘D, the way every browser does, and shared the chord
        // with Split Right on the grounds that a page and a terminal never
        // offer both. But the split is the thing reached for in every pane,
        // and the owner keeps pages by clicking the ★ — if at all — and finds
        // them again by history search. The menu item and the star remain; a
        // `keys` entry binds this for anyone who wants it on a key.
        case .bookmarkPage:    return nil
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
        // The lane header's `s | m | xl` switch, as commands. No key each: one
        // key that walks them is cheaper to learn than three, and `keys` binds
        // any of them for anyone who wants one.
        case .laneSizeSmall, .laneSizeMedium, .laneSizeLarge: return nil
        // s → m → xl → s, and a lane off every preset goes to m. ⌘\ was Span
        // Lane (2× Width), which xl replaced: two ways to make a lane wide, at
        // two different widths. The key stayed where the wide-lane habit is.
        // A command of its own rather than the chord on the three: a chord runs
        // one command, and which preset comes next depends on the lane.
        case .laneSizeCycle:   return ("\\", [.command])
        // ⇧⌘↩, iTerm's Maximize Active Pane, and a toggle like it: the key that
        // put the pane over the strip is the key that puts it back. Not Esc —
        // a terminal always has a use for Esc. Nothing else here binds Return,
        // and Ghostty's own bindings are cleared (ADR-0009), so the chord
        // reaches the menu from a terminal; a web pane gives it up through
        // `claims(_:)` like every other ⌘-chord in this file.
        case .toggleMaximizePane: return ("\r", [.command, .shift])
        // No key. It is a per-lane setting you flip once for Discord and leave,
        // not a thing you do all day, and every unclaimed ⌘ chord left is one
        // a page might want. `keys` binds it for anyone who disagrees.
        case .toggleMobileLayout: return nil
        // No key either, for the same reason: it is flipped once for the one
        // site whose page a rule breaks, and then left. `keys` binds it.
        case .toggleBlocking: return nil
        // ⌃⌘M. ⌘M is Minimize and ⌥⌘M is Minimize All, which are the
        // system's; ⌃⌘M is nobody's, here or there, and keeps the letter.
        // Claimed from a page like every ⌘ chord: the one key that silences
        // a page has to work while the page has the keyboard.
        case .toggleMute:      return ("m", [.command, .control])
        // No keys. Both are for the moment a sound starts somewhere you are
        // not looking, which is the status bar's speaker, one click; `keys`
        // binds them for anyone who wants that on a chord.
        case .muteOthers, .muteAll: return nil
        // ⌃⌘P, not ⌘P: ⌘P is the palette here, the key the owner presses
        // more than any other, and the keymap refuses two commands on one
        // chord. ⇧⌘P and ⌥⌘P were taken long before printing was. The
        // system print panel this opens already has Save as PDF in its PDF
        // menu, so the print key is also the PDF key.
        case .printPage:       return ("p", [.command, .control])
        // No key. The print panel's PDF menu is the everyday route; this is
        // the one for a whole page in one file, chosen through a save panel,
        // and `keys` binds it for anyone who wants that on a key.
        case .savePDF:         return nil
        // ⌃⌘S. ⇧⌘S is Export Strip and ⌘S is nothing here, but neither is
        // the reason: a capture is the sibling of ⌃⌘P — the other command
        // that turns a pane into a file — and it reads as one on the same
        // modifier. macOS has no ⌃⌘S (its ⌃⌘ chords are Space, F, Q and D),
        // no browser has one, and nothing here had it. ⇧⌘4 is still the
        // system's; this is the one that does not leave the app.
        case .capturePane:     return ("s", [.command, .control])
        // ⇧ on the same key, the way ⇧⌘R is to ⌘R and ⇧⌘W to ⌘W: the same
        // action, asking for more of it. A page only; a terminal has no
        // fold to reach past.
        case .captureFullPage: return ("s", [.command, .control, .shift])
        // The one everybody reaches for when they do not know the others.
        case .showHelp:        return ("/", [.command])
        // No key. The version in the sidebar's corner opens it with a click,
        // and the ⌘/ sheet lists it; `keys` binds it for anyone who wants it
        // on one.
        case .showChangelog:   return nil
        // No keys, like What's New: a release is a few-times-a-month event,
        // reached from the Help menu, the `↻` in the status bar, the
        // popover's line, or ⌘E by name; `keys` binds either (ADR-0038).
        case .checkForUpdates, .updateApp: return nil
        // ⌘, is Settings in every Mac app, which is the whole argument.
        case .showSettings:    return (",", [.command])
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
        // ⌘D was the other such alternate, until Split Right took the key for
        // itself — see `splitRight` above.
        case .openAnything: return [("t", [.command])]
        default: return []
        }
    }

    /// What the menu calls this when it is already on. Only a toggle whose two
    /// directions have different names needs one; the ⌘/ sheet and Settings
    /// list the command by `title`, which is the direction you start from.
    public var activeTitle: String? {
        switch self {
        case .toggleMaximizePane: return "Restore Pane"
        case .toggleExpandTile: return "Collapse Tile"
        case .copyMode: return "Leave Copy Mode"
        case .toggleMute: return "Unmute Pane"
        default: return nil
        }
    }

    /// The one command this is allowed to hold a chord alongside.
    ///
    /// Two commands may share a key only when they can never both be offered,
    /// because then there is no ambiguity to resolve: `canPerform` enables
    /// exactly one of the two, and the menu routes the chord to whichever item
    /// is live. Every *other* collision stays an error the keymap reports.
    ///
    /// Nothing declares a pair today. ⌘D once did — Keep This Page in a web
    /// pane, Split Right in a terminal — until the split took the key for
    /// every pane. The mechanism stays, because the next such pair will want
    /// it and the keymap and its tests already understand it.
    public var sharesChordWith: Command? {
        return nil
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

    /// A command only a terminal pane can answer, on a chord pages have a use
    /// of their own for. Its chords are left out of what `claims(_:)` takes
    /// from a page, unless another command is on the same chord: in a web pane
    /// the command could do nothing, so taking the key would only break the
    /// page's. Few, deliberately. The other terminal pastes sit on chords no
    /// page binds, and stay claimed so that they never reach one. ⌥⌘C and
    /// ⇧⌘C are a browser's own (page source, the inspector) and a page's to
    /// bind.
    public var yieldsToPage: Bool {
        self == .advancedPaste || self == .copyWithStyles || self == .copyMode || self == .clearScrollback
    }

    /// Commands only a page can answer: an address, a form, a document to
    /// print. `canPerform` greys these out on a terminal pane rather than
    /// beeping, because the menu can say which panes an item is for and a
    /// beep cannot; a key that could put a password somewhere unexpected is
    /// dead everywhere it does not mean anything.
    public var needsWebPane: Bool {
        switch self {
        case .editAddress, .bookmarkPage, .fillPassword, .savePassword, .printPage, .savePDF,
             .captureFullPage:
            return true
        default:
            return false
        }
    }

    /// An Edit-menu command that belongs under Copy rather than under Paste,
    /// where the rest of that menu's commands go.
    public var followsCopy: Bool { self == .copyWithStyles || self == .copyMode }

    /// The submenu of its menu this sits in, or nil for the menu itself.
    ///
    /// Edit › Paste Special ▸ holds every paste that is not ⌘V, the way
    /// iTerm's does, so the Edit menu stays four items and a door.
    public var submenu: String? {
        switch self {
        case .pasteWithoutAsking, .pasteEscaped, .pasteAsBase64, .pasteBase64Decoded,
             .pasteFileAsBase64, .pasteSlowly, .advancedPaste:
            return "Paste Special"
        default:
            return nil
        }
    }

    /// Which menu this belongs under.
    public var menu: MenuSection {
        switch self {
        case .openAnything, .openPages, .openSessions, .runCommand, .newTerminalLane, .newPrivateWebLane,
             .splitRight, .splitDown: return .file
        case .closePane, .closeLane: return .file
        // With Close Lane, which it is the stronger form of.
        case .endSession: return .file
        case .focusLeft, .focusRight, .focusUp, .focusDown, .search, .gather, .ungather: return .navigate
        // With ⌘P and ⌘[ ⌘]: they move focus, to the agent that needs it.
        case .nextAttention, .previousAttention, .showAttention: return .navigate
        case .toggleGallery: return .view
        // Directly under Toggle Gallery: it is the other half of getting into
        // the gallery and reading something there.
        case .toggleExpandTile: return .view
        case .moveLaneLeft, .moveLaneRight, .toggleSidebar, .toggleKeepLive,
             .widenLane, .narrowLane, .peekDesktop: return .view
        // With Keep Lane Loaded and the sizes: a fact about the lane.
        case .renameLane: return .view
        case .dockLaneLeft, .dockLaneRight, .toggleDockMode: return .view
        // Under Navigate, not View: these move focus, which is the same thing
        // ⌘[ / ⌘] do and the reason they exist at all.
        case .focusDockLeft, .focusDockRight: return .navigate
        case .claimSession: return .file
        // Under Edit, below Copy, which they are the other two of.
        case .copyWithStyles, .copyMode: return .edit
        // Under Edit, below Paste, which it is the other one of.
        case .pasteWithoutAsking: return .edit
        case .pasteEscaped, .pasteAsBase64, .pasteBase64Decoded, .pasteFileAsBase64, .pasteSlowly,
             .advancedPaste: return .edit
        // Below Paste Special: the pastes, then what was pasted.
        case .pasteHistory, .clearPasteHistory: return .edit
        // Under Edit with the other Clear, and where iTerm keeps its ⌘K.
        case .clearScrollback: return .edit
        case .showMemory: return .view
        // The Help menu, where a Mac user reaches for a keyboard sheet and a
        // what's-new: the ⌘/ sheet was under View while there was no Help
        // menu to put it in.
        case .showHelp, .showChangelog: return .help
        // Help, under What's New: the release you do not have yet is the
        // next thing after the changes you do.
        case .checkForUpdates, .updateApp: return .help
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
        // Fill and save sit under Navigate with ⌘L and Keep This Page: they are things you
        // do to the page in front of you. The import is a File-menu act, with
        // the other import.
        case .fillPassword, .savePassword: return .navigate
        case .importBrowserPasswords: return .file
        // Under File, where every Mac app keeps Print: the two produce a
        // document out of the pane rather than acting on the site.
        case .printPage, .savePDF: return .file
        // With them, and for their reason: a capture is the third way a pane
        // becomes a file.
        case .capturePane, .captureFullPage: return .file
        case .laneSizeSmall, .laneSizeMedium, .laneSizeLarge, .laneSizeCycle: return .view
        // Beside the sizes and not one of them: it changes how much of the
        // window a pane is shown in, and nothing about the lane (ADR-0019).
        case .toggleMaximizePane: return .view
        // With the size presets, which it is the fourth of: a lane's shape.
        case .toggleMobileLayout: return .view
        // Under Navigate with Keep This Page and Fill Password: a thing you do
        // to the site in front of you, not to the lane's shape.
        case .toggleBlocking: return .navigate
        // View, with Mobile Layout and the zooms: how a pane is presented to
        // you, and nothing about where it is or what it has loaded.
        case .toggleMute, .muteOthers, .muteAll: return .view
        // In the app menu, under About, where a Mac user reaches for it.
        case .showSettings: return .app
        }
    }
}

extension Command {
    /// A command about the app rather than the strip: the app menu and Help.
    /// These run from whatever window has the keyboard. Every other command
    /// acts on the strip and, from the menu, runs only while the strip's own
    /// window has the keyboard (`StripWindowController.canPerformFromMenu`).
    public var isAppLevel: Bool { menu == .app || menu == .help }
}

public enum MenuSection: String, CaseIterable {
    /// The menu named for the app. Built by hand around About, Hide and Quit;
    /// only its `Command`s come from here.
    case app = "Max Pane"
    /// Cut, Copy, Paste and Select All are built by hand, as responder-chain
    /// items; the `Command`s that belong beside them follow those.
    case edit = "Edit"
    case file = "File"
    case navigate = "Navigate"
    case view = "View"
    /// Last, as macOS puts it: the ⌘/ sheet and What's New. `AppDelegate`
    /// hands it to `NSApp.helpMenu`, which is what puts the search field in.
    case help = "Help"
}

/// What handles a `Command`. One method, so adding a command is one `case` in
/// the switch and one entry above — never a new delegate protocol.
@MainActor
public protocol CommandHandling: AnyObject {
    func perform(_ command: Command)
    /// Grey out what cannot be done right now (e.g. Leave Gather View when not
    /// gathered).
    func canPerform(_ command: Command) -> Bool
    /// What the menu item says right now. A toggle with two names — Maximize
    /// Pane, Restore Pane — answers with the one that pressing it would do.
    func title(for command: Command) -> String
}

public extension CommandHandling {
    func title(for command: Command) -> String { command.title }
}
