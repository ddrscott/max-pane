import AppKit
import LanedCore

/// The passwords import's state and every string it prints, with no AppKit in
/// it — the same split `ImportWizardModel` is, for the same reason: what this
/// has to get right is the wording, and the wording is assertable.
struct ImportPasswordsModel {
    /// Three screens, not four.
    ///
    /// There is no merge-or-replace question here, and that is the whole reason
    /// this is its own window rather than a fifth screen in `⌥⌘Y`. "Replace"
    /// would mean deleting the passwords already in this Mac's Keychain —
    /// Safari's, other apps', the user's own — which is not a thing a browser
    /// import may offer, so the question has exactly one legal answer and
    /// asking it would be theatre. An import adds what the browser has and
    /// updates an item that is already there for the same site and account.
    enum Step: Equatable {
        case source
        case working
        case done(PasswordImport.Report)
        case failed(String)
    }

    var step: Step = .source
    var sources: [LoginSource]
    var selected: Int = 0

    init(sources: [LoginSource]) {
        self.sources = sources
        self.selected = sources.firstIndex(where: { $0.blocked == nil }) ?? 0
    }

    var selectedSource: LoginSource? {
        sources.indices.contains(selected) ? sources[selected] : nil
    }

    var blockedReason: String? { selectedSource?.blocked }
    var isEmpty: Bool { sources.isEmpty }

    func title(of source: LoginSource) -> String {
        guard let profile = source.profile else { return source.name }
        return "\(source.name) — \(profile)"
    }

    func detail(of source: LoginSource) -> String {
        "\(ImportWizardModel.bytes(source.sizeBytes))  \(ImportWizardModel.abbreviate(source.path))"
    }

    /// What the first screen says before anything happens.
    ///
    /// It names the macOS panel *before* it appears. An unexplained "Max Pane
    /// wants to use your confidential information stored in Vivaldi Safe
    /// Storage" is a dialog people either deny out of suspicion or accept out
    /// of habit, and both of those are worse than knowing which button was
    /// coming and why.
    static func consent(for source: LoginSource?) -> String {
        let name = source?.name ?? "the browser"
        let item = source?.safeStorageService ?? "<Browser> Safe Storage"
        return """
        Max Pane will copy \(name)'s password file, read it, and delete the copy. \
        macOS will then ask whether Max Pane may use the key called "\(item)" — \
        that panel is what unlocks the passwords, and Deny stops the import with \
        nothing written.

        Each password is written to the macOS Keychain as an ordinary internet \
        password, the same kind Safari saves, so they appear in System Settings → \
        Passwords where they can be read, changed and deleted. Max Pane keeps no \
        password file of its own.
        """
    }

    /// The report, as label-and-value rows. Counters only: a list of what was
    /// imported is a list of the sites someone has accounts on.
    static func doneLines(_ report: PasswordImport.Report) -> [(String, String)] {
        var lines: [(String, String)] = [
            ("Passwords the browser had", ImportWizardModel.thousands(UInt32(report.found))),
            ("Saved to the Keychain", ImportWizardModel.thousands(UInt32(report.saved))),
        ]
        if report.unreadable > 0 {
            lines.append(("Could not be decrypted", ImportWizardModel.thousands(UInt32(report.unreadable))))
        }
        if report.notAWebsite > 0 {
            lines.append(("Not a website (phone or extension)",
                          ImportWizardModel.thousands(UInt32(report.notAWebsite))))
        }
        if report.refused > 0 {
            lines.append(("The Keychain refused", ImportWizardModel.thousands(UInt32(report.refused))))
        }
        return lines
    }

    static func doneHeadline(_ report: PasswordImport.Report) -> String {
        if report.saved == 0 {
            return "Nothing was imported."
        }
        return "\(ImportWizardModel.thousands(UInt32(report.saved))) "
            + "password\(report.saved == 1 ? "" : "s") are now in the Keychain."
    }
}

// MARK: - the panel

/// Import another browser's saved passwords: pick a browser, read what will
/// happen, let macOS ask its question, done.
///
/// Its own window rather than a fifth screen in the history wizard. Two reasons
/// and both are about the user rather than the code: the merge-or-replace
/// question that wizard is built around has no legal answer here (see
/// `ImportPasswordsModel.Step`), and the consent that matters is a macOS panel
/// this app does not draw and cannot style — so the screen before it exists to
/// say what is about to be asked, which is not a job any of the history
/// wizard's screens do.
@MainActor
final class ImportPasswordsWizard: NSWindowController, NSWindowDelegate {
    /// Internal for the render-sheet test, like its sibling's.
    var model: ImportPasswordsModel
    private let store: StripStore
    private var whileOpen: ImportPasswordsWizard?
    private var monitor: Any?

    private let body = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let buttons = NSStackView()

    init(store: StripStore, sources: [LoginSource]? = nil) {
        self.store = store
        self.model = ImportPasswordsModel(sources: sources ?? store.loginSources())
        let panel = SquarePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        super.init(window: panel)
        panel.delegate = self

        let frame = ImportWizardPanelView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = frame

        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 12
        body.translatesAutoresizingMaskIntoConstraints = false

        heading.font = Theme.mono(11, weight: .medium)
        heading.textColor = Theme.dimText

        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let header = SectionHeader(text: "IMPORT_PASSWORDS")
        header.translatesAutoresizingMaskIntoConstraints = false
        for v in [header, heading, body, buttons] { frame.addSubview(v) }
        heading.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: frame.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 20),
            heading.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            heading.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -20),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14),
            body.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(lessThanOrEqualTo: buttons.topAnchor, constant: -14),
            buttons.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -18),
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func present(over parent: NSWindow?) {
        guard let panel = window else { return }
        whileOpen = self
        if let parent {
            let f = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: f.midX - panel.frame.width / 2,
                y: f.midY - panel.frame.height / 2 + f.height * 0.1))
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func dismiss() {
        guard whileOpen != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel = window {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        whileOpen = nil
    }

    func windowDidResignKey(_ notification: Notification) {}

    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53: self.escape(); return nil
            case 36, 76: self.advance(); return nil
            case 125: self.move(by: 1); return nil
            case 126: self.move(by: -1); return nil
            default: return event
            }
        }
    }

    private func escape() {
        if case .working = model.step { return }
        dismiss()
    }

    private func move(by delta: Int) {
        guard case .source = model.step, !model.sources.isEmpty else { return }
        model.selected = min(max(0, model.selected + delta), model.sources.count - 1)
        render()
    }

    private func advance() {
        switch model.step {
        case .source:
            guard model.selectedSource != nil, model.blockedReason == nil else { return }
            run()
        case .working:
            return
        case .done, .failed:
            dismiss()
        }
    }

    /// Read, unlock, write. All three off the main actor.
    ///
    /// The Keychain calls are the reason. `SecItemAdd` against an item another
    /// application owns can put a macOS panel on screen, and four hundred of
    /// those on the main thread would be a beachball with a dialog trapped
    /// behind it.
    private func run() {
        guard let source = model.selectedSource else { return }
        model.step = .working
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                let logins = try await self.store.browserLogins(source)
                let service = source.safeStorageService
                let report = try await Task.detached(priority: .userInitiated) {
                    // The consent panel happens inside this call, and nothing
                    // has been decrypted before it returns.
                    let key = try ChromiumSafeStorage.key(service: service)
                    return PasswordImport.run(logins: logins, key: key)
                }.value
                self.model.step = .done(report)
            } catch let error as ChromiumSafeStorage.KeyError {
                self.model.step = .failed(error.message)
            } catch {
                self.model.step = .failed(ImportHistoryWizard.sentence(error))
            }
            self.render()
        }
    }

    // MARK: - drawing

    func render() {
        for v in body.views { v.removeFromSuperview() }
        for v in buttons.views { v.removeFromSuperview() }
        switch model.step {
        case .source: renderSource()
        case .working: renderWorking()
        case .done(let report): renderDone(report)
        case .failed(let why): renderFailed(why)
        }
        window?.contentView?.needsDisplay = true
    }

    private func renderSource() {
        if model.isEmpty {
            heading.stringValue = "No browser with saved passwords found on this Mac."
            addRow(paragraph(
                "Max Pane can import from the Chromium family — Vivaldi, Chrome, Brave, Edge. "
                + "Safari needs no import: its passwords are already Keychain items, so Max Pane "
                + "can already fill them. Firefox keeps its own encrypted store and is not read "
                + "in this version."))
            buttons.addView(button("Close", isDefault: true) { [weak self] in self?.dismiss() },
                            in: .trailing)
            return
        }
        heading.stringValue = "Which browser? ↑ ↓ to choose, ↩ to import."
        for (i, source) in model.sources.enumerated() {
            let row = WizardRow(
                title: model.title(of: source),
                detail: model.detail(of: source),
                isSelected: i == model.selected,
                isBlocked: source.blocked != nil)
            row.onClick = { [weak self] in
                self?.model.selected = i
                self?.render()
            }
            addRow(row)
        }
        if let why = model.blockedReason {
            addRow(paragraph("⚠ " + why))
        } else {
            addRow(paragraph(ImportPasswordsModel.consent(for: model.selectedSource)))
        }
        buttons.addView(button("Cancel", isDefault: false) { [weak self] in self?.dismiss() },
                        in: .trailing)
        buttons.addView(
            button("Import", isDefault: model.blockedReason == nil) { [weak self] in self?.advance() },
            in: .trailing)
    }

    private func renderWorking() {
        heading.stringValue = "Reading the browser's copy, then asking macOS for the key…"
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addRow(spinner)
        addRow(paragraph(
            "The browser's own file is never written to — Max Pane reads a copy and deletes "
            + "it. If macOS asks whether Max Pane may use the browser's key, that is this "
            + "import; Deny stops it and writes nothing."))
    }

    private func renderDone(_ report: PasswordImport.Report) {
        heading.stringValue = ImportPasswordsModel.doneHeadline(report)
        for (label, value) in ImportPasswordsModel.doneLines(report) {
            addRow(statLine(label, value))
        }
        addRow(paragraph(
            "They live in System Settings → Passwords now, alongside Safari's. ⌥⌘L fills "
            + "one into the form you are looking at."))
        buttons.addView(button("Done", isDefault: true) { [weak self] in self?.dismiss() },
                        in: .trailing)
    }

    private func renderFailed(_ why: String) {
        heading.stringValue = "The import did not happen."
        addRow(paragraph(why))
        buttons.addView(button("Close", isDefault: true) { [weak self] in self?.dismiss() },
                        in: .trailing)
    }

    // MARK: - small views

    private func addRow(_ view: NSView) {
        body.addView(view, in: .top)
        view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
    }

    private func button(_ label: String, isDefault: Bool, action: @escaping () -> Void) -> AskButton {
        let b = AskButton(label: label, isDefault: isDefault)
        b.onClick = action
        return b
    }

    private func paragraph(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = Theme.mono(11)
        f.textColor = Theme.dimText
        f.isSelectable = true
        f.drawsBackground = false
        f.isBezeled = false
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    private func statLine(_ label: String, _ value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        let l = NSTextField(labelWithString: label)
        l.font = Theme.mono(11)
        l.textColor = Theme.dimText
        let v = NSTextField(labelWithString: value)
        v.font = Theme.mono(11, weight: .medium)
        v.textColor = .labelColor
        v.isSelectable = true
        row.addView(l, in: .leading)
        row.addView(v, in: .trailing)
        return row
    }
}
