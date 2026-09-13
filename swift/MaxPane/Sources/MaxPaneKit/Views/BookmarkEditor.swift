import AppKit
import LanedCore

/// The little sheet ⌘D opens: what this page is called, and which folder it is
/// in.
///
/// ## Why keeping is one press and editing is the panel
///
/// ⌘D keeps the page *before* this opens, and this opens on the page that is
/// now kept. That is Chrome's shape and it is right for the same reason: the
/// common case is "keep this", the uncommon one is "keep this, but call it
/// something and put it somewhere", and a dialog that stood between the press
/// and the keeping would tax the common case to serve the rare one. Nothing
/// here is a commit button — every control writes as it is used — so dismissing
/// it with esc or by clicking away leaves the page kept, which is what was
/// asked for. **Remove** is the undo, and it is on the panel because "I meant
/// to press ⌘W" is the other thing that happens a second after ⌘D.
///
/// ## Why a popover and not a fourth palette
///
/// Because it is about one row, and it is anchored to the star that row belongs
/// to. A palette is for choosing among many things; this is for editing one,
/// and the app already has three pickers that a fourth would have to be told
/// apart from.
@MainActor
final class BookmarkEditor: NSViewController {
    private let store: StripStore
    /// The row being edited. Re-read after every write, because the folder
    /// popup can move it and `Bookmark` is a snapshot.
    private var bookmark: Bookmark
    private let onClose: () -> Void

    private let name = NSTextField()
    private let folders = NSPopUpButton()
    private let newFolder = NSTextField()
    private let newFolderRow = NSStackView()
    /// The bar, then every folder in tree order. Index matches the popup's,
    /// after the first item — so a folder whose title is "New Folder…" cannot
    /// be mistaken for the command at the end.
    private var folderIds: [String?] = []

    private weak var popover: NSPopover?

    init(store: StripStore, bookmark: Bookmark, onClose: @escaping () -> Void) {
        self.store = store
        self.bookmark = bookmark
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    /// Open on `anchor`'s trailing edge, with the name field selected so the
    /// second thing anyone does after ⌘D — rename it — costs no click.
    static func show(
        over anchor: NSView, store: StripStore, bookmark: Bookmark, onClose: @escaping () -> Void
    ) {
        let popover = NSPopover()
        let editor = BookmarkEditor(store: store, bookmark: bookmark, onClose: onClose)
        editor.popover = popover
        popover.contentViewController = editor
        popover.behavior = .transient
        // `.applicationDefined` would mean dismissing it by hand from three
        // places; transient closes on the click outside that everyone expects,
        // and nothing here is lost by closing.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        editor.view.window?.makeFirstResponder(editor.name)
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 150))

        let header = SectionHeader(text: "KEPT_PAGE")

        name.font = Theme.mono(12)
        name.stringValue = bookmark.title
        name.focusRingType = .none
        name.bezelStyle = .squareBezel
        name.target = self
        name.action = #selector(commitName)
        // `NSTextField` only sends its action on ↩ or on focus leaving; the
        // second is what makes clicking straight into the folder popup save the
        // rename rather than discard it.
        name.delegate = self

        folders.pullsDown = false
        folders.font = Theme.mono(11)
        folders.target = self
        folders.action = #selector(folderChosen)
        rebuildFolderMenu()

        newFolder.font = Theme.mono(11)
        newFolder.placeholderString = "Folder name, then ↩"
        newFolder.focusRingType = .none
        newFolder.bezelStyle = .squareBezel
        newFolder.target = self
        newFolder.action = #selector(commitNewFolder)
        newFolderRow.orientation = .horizontal
        newFolderRow.addView(newFolder, in: .leading)
        newFolderRow.isHidden = true

        let remove = AskButton(label: "Remove", isDefault: false)
        remove.onClick = { [weak self] in self?.remove() }
        let done = AskButton(label: "Done", isDefault: true)
        done.onClick = { [weak self] in self?.close() }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [remove, spacer, done])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [header, name, folders, newFolderRow, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            name.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            folders.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            newFolder.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        view = root
    }

    /// The bar, every folder indented by its depth, then the one command.
    ///
    /// Indented with spaces rather than with `NSMenuItem.indentationLevel`,
    /// because the popup's *closed* state draws the chosen item's title and
    /// drops the indentation — so `Rust` inside `Work` would read as a folder
    /// on the bar exactly when the reader most needs to know it is not.
    private func rebuildFolderMenu() {
        let menu = NSMenu()
        folderIds = [nil]
        menu.addItem(withTitle: "Bookmarks Bar", action: nil, keyEquivalent: "")
        for folder in store.bookmarkFolders() {
            let pad = String(repeating: "   ", count: Int(folder.depth))
            menu.addItem(withTitle: pad + folder.title, action: nil, keyEquivalent: "")
            folderIds.append(folder.id)
        }
        menu.addItem(.separator())
        folderIds.append(nil)
        menu.addItem(withTitle: "New Folder…", action: nil, keyEquivalent: "")
        folders.menu = menu
        let index = folderIds.firstIndex { $0 != nil && $0 == bookmark.parentId } ?? 0
        folders.selectItem(at: index)
    }

    /// The index of the "New Folder…" command: the last item, past the
    /// separator the popup counts as one of its own.
    private var newFolderIndex: Int { (folders.menu?.numberOfItems ?? 1) - 1 }

    @objc private func folderChosen() {
        let index = folders.indexOfSelectedItem
        if index == newFolderIndex {
            newFolderRow.isHidden = false
            view.window?.makeFirstResponder(newFolder)
            return
        }
        newFolderRow.isHidden = true
        guard index > 0, index < folderIds.count else {
            move(to: nil)
            return
        }
        move(to: folderIds[index])
    }

    @objc private func commitNewFolder() {
        let title = newFolder.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        // On the bar, always. A new folder made from here is a new folder on
        // the bar — that is what a bookmarks bar's folders are, and "inside
        // which existing folder" is a question the popup above can answer
        // afterwards without this having to ask it first.
        guard let folder = try? store.addBookmark(parent: nil, url: nil, title: title) else { return }
        newFolder.stringValue = ""
        newFolderRow.isHidden = true
        move(to: folder.id)
    }

    private func move(to parent: String?) {
        guard parent != bookmark.parentId else { return }
        try? store.moveBookmark(bookmark.id, to: parent)
        reread()
        rebuildFolderMenu()
    }

    @objc private func commitName() {
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, title != bookmark.title else { return }
        try? store.renameBookmark(bookmark.id, title)
        reread()
    }

    /// The row as the ledger now has it. Everything here writes and then
    /// re-reads rather than patching the local copy: the tree is one cheap read
    /// and a hand-patched snapshot is how a panel comes to disagree with the
    /// thing it is editing.
    private func reread() {
        guard let fresh = store.bookmarks().first(where: { $0.id == bookmark.id }) else {
            close()
            return
        }
        bookmark = fresh
    }

    private func remove() {
        try? store.removeBookmark(bookmark.id)
        close()
    }

    private func close() {
        commitName()
        popover?.performClose(nil)
        onClose()
    }
}

extension BookmarkEditor: NSTextFieldDelegate {
    /// Editing ended — by ↩, by ⇥, or by the focus going to the folder popup.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard (obj.object as? NSTextField) === name else { return }
        commitName()
    }
}
