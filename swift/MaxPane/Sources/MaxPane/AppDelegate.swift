import AppKit
import LanedCore
import MaxPaneKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }

    /// Not `Config.load()` at initialisation: the config file's path depends on
    /// the profile, and the profile's directories may not exist until the
    /// migration below has run. An initialiser would read the wrong file, once,
    /// on the one launch where it matters.
    private var config = Config()
    private var store: StripStore!
    private var windowController: StripWindowController!
    private var configStore: ConfigStore?
    private var configObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything derives a path. A refused `--profile` stops the
        // launch rather than falling back to the default, because falling back
        // means writing into the strip the person was trying to stay out of.
        if let complaint = Profile.currentComplaint {
            presentFatal("Could not start", ProfileArgumentError(complaint))
            return
        }
        Profile.current.prepareDirectories()
        do {
            // Only the default profile's own launch moves the default profile's
            // ledger. A throwaway `--profile probe` instance touching the live
            // strip — even to reorganise it — is the exact thing `--profile`
            // exists to make impossible, and it would do it on first launch,
            // before anyone had a reason to be watching.
            if Profile.current.isDefault { try Profile.migrateLegacyLayout() }
        } catch {
            presentFatal("Could not move the ledger into the default profile", error)
            return
        }
        // `config.json` becomes `config.toml` once, for whichever profile this
        // is, and the JSON stays where it was. Not when `MAXPANE_CONFIG` names
        // the file: a path someone pointed somewhere is theirs to fill.
        if !Profile.configIsOverridden {
            let json = Profile.current.legacyConfigPath
            do {
                if try ConfigFile.migrate(json: json, to: Config.path) {
                    Log.warn("config: copied \(json.path) to \(Config.path.path); the JSON is left in place and no longer read")
                }
            } catch {
                Log.warn("config: could not copy \(json.path) to \(Config.path.path): \(error.localizedDescription)")
            }
        }
        let configStore = ConfigStore(
            path: Config.path, legacyPath: Profile.configIsOverridden ? nil : Profile.current.legacyConfigPath)
        self.configStore = configStore
        config = configStore.config
        // Before any window exists, so nothing is built in one appearance and
        // then faded into the other on launch.
        Appearance.apply(config.theme)
        // `theme` is the one key that applies the moment the file is saved,
        // from a text editor or from the settings window alike.
        configObserver = NotificationCenter.default.addObserver(
            forName: ConfigStore.didChange, object: configStore, queue: .main
        ) { [weak configStore] _ in
            MainActor.assumeIsolated {
                if let configStore { Appearance.apply(configStore.config.theme) }
            }
        }
        // Before the window and before the menu: both bake in key equivalents
        // when they are built, so a keymap installed after either of them would
        // leave the menu advertising one key and the monitor answering another.
        Keymap.install(Keymap(overrides: config.keys))

        do {
            // Clamped here rather than trusted: `laneDefaultPt` is a number in a
            // file a person edits, and the core would clamp it anyway — doing it
            // on this side keeps the app's own `widthRange` the one that decides
            // what a lane may be.
            store = try StripStore(laneDefaultPt: config.clampWidth(config.laneDefaultPt))
        } catch {
            presentFatal("Could not open the ledger", error)
            return
        }

        // The ad and tracker blocker: the ledger's exemptions in, the compiled
        // list looked up (or fetched and compiled, off the main thread) and
        // added to every web view as it lands. Before the window, so the first
        // pane built attaches to a blocker that already knows the exemptions.
        let blocker = ContentBlocker.shared
        blocker.isEnabled = config.blocking
        blocker.loadExemptions(store.blockingExemptDomains())
        blocker.persistExemption = { [weak store] domain, exempt in store?.setBlockingExempt(domain, exempt) }
        blocker.start(source: config.blockingListUrl)

        windowController = StripWindowController(store: store, config: config)
        windowController.configStore = configStore
        buildMenu()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// A link handed over by another app — Mail, Slack, `open`, anything — when
    /// Max Pane is the default browser.
    ///
    /// It lands where every other URL in this app lands: a lane, revealed. The
    /// alternative would be a browser that opens links somewhere you have to go
    /// and find, which is the thing a strip exists not to do.
    ///
    /// Declaring the schemes in Info.plist is what makes the app *eligible* to
    /// be chosen; this is what makes choosing it work. Ship one without the
    /// other and the app appears in the list and then swallows every link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "http" || url.scheme == "https" {
            windowController?.openFromOutside(url.absoluteString)
        }
    }

    /// Layout is already durable — every mutation commits before it animates —
    /// but a web pane's session is only in WebKit's head until it is asked for.
    func applicationWillTerminate(_ notification: Notification) {
        windowController?.flushPaneState()
    }

    // MARK: - menu

    /// Built from `Command`, so the menu and the key map cannot drift apart.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Max Pane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        for command in Command.allCases where command.menu == .app {
            appMenu.addItem(menuItem(for: command))
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Max Pane", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Max Pane", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // The Edit menu, which macOS does not supply and which nothing else
        // here would have created.
        //
        // Its absence is invisible in code review and fatal in use: SwiftTerm
        // implements `copy(_:)`, `paste(_:)` and `selectAll(_:)` as responder
        // methods, but with no menu item carrying those selectors, ⌘V reaches
        // nothing and silently does nothing. A critic driving the app found it
        // in five minutes; pasting a path or a stack trace into an agent prompt
        // is the most frequent input action there is.
        //
        // `target = nil` is the point — each item walks the responder chain to
        // whatever is focused, so the same ⌘C works in a terminal lane, a web
        // pane and the search field without any of them knowing about this menu.
        //
        // Paste is the exception, and is targeted here: a terminal pane needs
        // its own paste rather than the emulator's. `pasteFromEditMenu(_:)`
        // says why, and still ends at `paste:` for every other kind of pane.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(AppDelegate.pasteFromEditMenu(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] as [(String, Selector, String)] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = selector == #selector(AppDelegate.pasteFromEditMenu(_:)) ? self : nil
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        for section in MenuSection.allCases where section != .app {
            let item = NSMenuItem()
            let menu = NSMenu(title: section.rawValue)
            menu.autoenablesItems = false
            for command in Command.allCases where command.menu == section {
                menu.addItem(menuItem(for: command))
            }
            item.submenu = menu
            main.addItem(item)
        }

        NSApp.mainMenu = main
        // Validate lazily: what is possible depends on what is focused.
        for section in main.items.dropFirst() {
            section.submenu?.delegate = self
        }
    }

    /// A command as a menu item, carrying its ⌘-chord if it has one.
    ///
    /// A command with no ⌘-chord — unbound, or bound to something like Esc that
    /// the window's key monitor handles — is still an item. It was previously
    /// skipped outright, which is how "Leave Gather View" came to be an action
    /// with no key that listened and no menu entry to click either.
    private func menuItem(for command: Command) -> NSMenuItem {
        let chord = command.menuChord
        let item = NSMenuItem(
            title: command.title, action: #selector(runCommand(_:)),
            keyEquivalent: chord?.key ?? "")
        item.keyEquivalentModifierMask = chord?.modifiers ?? []
        item.target = self
        item.representedObject = command.rawValue
        return item
    }

    /// ⌘V, offered to a terminal pane first and to everything else after.
    ///
    /// The two sends are the whole of it. `pasteIntoTerminalPane:` is answered
    /// only by a terminal pane's container, so it finds one when a terminal has
    /// the keyboard and nothing at all otherwise — at which point `paste:`
    /// takes over and reaches WKWebView, a search field, or whatever else is
    /// focused, exactly as it did before this existed.
    ///
    /// The terminal has to be asked separately because its own `paste:` frames
    /// the clipboard from the local emulator's belief about a program at the
    /// far end of a socket. See `TerminalPaste`.
    @objc private func pasteFromEditMenu(_ sender: Any?) {
        let toTerminal = #selector(TerminalPasteTarget.pasteIntoTerminalPane(_:))
        if NSApp.sendAction(toTerminal, to: nil, from: sender) { return }
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = Command(rawValue: raw) else { return }
        windowController.perform(command)
    }

    private func presentFatal(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

/// So a refused `--profile` reaches the same alert as a failure to open the
/// ledger, and says the same kind of thing.
private struct ProfileArgumentError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let raw = item.representedObject as? String, let command = Command(rawValue: raw) else { continue }
            item.isEnabled = windowController.canPerform(command)
        }
    }
}
