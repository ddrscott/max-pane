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

    private var config = Config.load()
    private var store: StripStore!
    private var windowController: StripWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try StripStore()
        } catch {
            presentFatal("Could not open the ledger", error)
            return
        }

        windowController = StripWindowController(store: store, config: config)
        buildMenu()
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - menu

    /// Built from `Command`, so the menu and the key map cannot drift apart.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Max Pane", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a"),
        ] as [(String, Selector, String)] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = nil
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        for section in MenuSection.allCases {
            let item = NSMenuItem()
            let menu = NSMenu(title: section.rawValue)
            menu.autoenablesItems = false
            for command in Command.allCases where command.menu == section {
                let (key, mods) = command.shortcut
                // Esc has no menu representation; it lives in the responder chain.
                guard command != .ungather else { continue }
                let mi = NSMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: key)
                mi.keyEquivalentModifierMask = mods
                mi.target = self
                mi.representedObject = command.rawValue
                menu.addItem(mi)
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

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            guard let raw = item.representedObject as? String, let command = Command(rawValue: raw) else { continue }
            item.isEnabled = windowController.canPerform(command)
        }
    }
}
