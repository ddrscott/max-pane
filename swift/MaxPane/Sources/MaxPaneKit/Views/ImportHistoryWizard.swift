import AppKit
import LanedCore

/// The wizard's state and every string it prints, with no AppKit in it.
///
/// Separated from the panel for the reason `LaneHeaderModel` and `SidebarModel`
/// are: what this thing has to get right is the *wording* — which browsers it
/// offers, what the difference between merge and replace is said to be, and
/// whether the report describes the import that is about to happen. All of that
/// is assertable in a test; none of it is assertable through a window.
struct ImportWizardModel {
    /// Four screens, and the rule for them: nothing is written before `report`
    /// has been read.
    enum Step: Equatable {
        /// Which browser.
        case source
        /// Merge or replace, with the difference spelled out.
        case mode
        /// The dry run's answer. The last screen before anything is written.
        case report
        /// Copying, reading, writing. Seconds, not milliseconds — see
        /// `StripStore.importHistory`. The flag is which of the two long calls
        /// is in flight, because they take very different amounts of time and
        /// only one of them has written anything.
        case working(importing: Bool)
        case done
        case failed(String)
    }

    /// A dry run, and the mode it was run for.
    ///
    /// One value rather than two fields, because the two can disagree: a plan
    /// computed for `Merge` says the ledger ends up with 109 465 pages and the
    /// same source under `Replace` says 109 046, so a report that read the
    /// current mode while showing last mode's numbers would describe a different
    /// import than the button underneath it performs. That is the single failure
    /// this screen exists to prevent, so it is made unrepresentable instead of
    /// merely avoided — changing the mode discards the dry run.
    struct DryRun: Equatable {
        let mode: ImportMode
        let plan: ImportPlan
    }

    var step: Step = .source
    var sources: [HistorySource]
    var selected: Int = 0
    var dry: DryRun?
    var outcome: ImportOutcome?

    /// What the next dry run will be run for. Setting it throws away the last
    /// one; see [`DryRun`].
    var mode: ImportMode = .merge {
        didSet { if mode != oldValue { dry = nil } }
    }

    init(sources: [HistorySource]) {
        self.sources = sources
        // Land on something importable, so the common case is ↩ ↩ ↩ rather than
        // ↩ into a sentence about System Settings.
        self.selected = sources.firstIndex(where: { $0.blocked == nil }) ?? 0
    }

    // MARK: - the source list

    var selectedSource: HistorySource? {
        sources.indices.contains(selected) ? sources[selected] : nil
    }

    /// Why the selected source cannot be used, if it cannot.
    var blockedReason: String? { selectedSource?.blocked }

    var isEmpty: Bool { sources.isEmpty }

    /// "Vivaldi — Default", or just "Safari" for a browser with one profile.
    func title(of source: HistorySource) -> String {
        guard let profile = source.profile else { return source.name }
        return "\(source.name) — \(profile)"
    }

    /// The size and the path, because two rows reading "Vivaldi — Profile 2"
    /// are told apart by nothing else.
    func detail(of source: HistorySource) -> String {
        "\(Self.bytes(source.sizeBytes))  \(Self.abbreviate(source.path))"
    }

    // MARK: - the two modes, in words

    /// The wizard explains the difference rather than assuming it.
    ///
    /// Both options keep every page you have been to in Max Pane *findable* or
    /// not, and that is the whole distinction — so it is stated as what happens
    /// to what is already here, not as "merge" and "replace", which are words
    /// that mean whatever the reader guesses.
    static func explanation(of mode: ImportMode, plan: ImportPlan?) -> String {
        switch mode {
        case .merge:
            return """
            Keeps everything already in Max Pane and folds the browser's history \
            and bookmarks into it. A page both have is one row: the earlier first \
            visit, the later last visit, and the larger visit count. A bookmark \
            already kept at the same address in the same folder is left alone, \
            name and all. Nothing is deleted, and importing the same profile \
            twice changes nothing.
            """
        case .replace:
            // One phrase, not a count and a plural glued together: before the dry
            // run there is no count, and "the every pages" is what assembling it
            // from parts produced. The render sheet is how that was seen.
            let what = plan.map { p in
                "the \(Self.thousands(p.existingPages)) page\(p.existingPages == 1 ? "" : "s")"
            } ?? "every page"
            return """
            Throws away \(what) Max Pane has recorded — and every bookmark it \
            keeps — and takes only the browser's. The whole ledger is copied to a \
            file beside it first, and this screen names that file: it is the only \
            way back.
            """
        }
    }

    // MARK: - the dry run

    /// What the import would do, as label-and-value rows.
    ///
    /// Every number the ticket asked a dry run to report is here, and the two
    /// that decide whether to go ahead — how much is new, and how large the
    /// ledger ends up — are last, where a reader stops.
    var reportLines: [(String, String)] {
        guard let dry else { return [] }
        let plan = dry.plan
        var lines: [(String, String)] = [
            ("pages in source", Self.thousands(plan.sourcePages)),
            ("not importable", Self.thousands(plan.skipped)),
            ("covering", Self.range(plan)),
            ("already in Max Pane", Self.thousands(plan.alreadyKnown)),
            ("new to Max Pane", Self.thousands(plan.newPages)),
        ]
        let arrow = "\(Self.thousands(plan.existingPages)) → \(Self.thousands(plan.resultingPages))"
        switch dry.mode {
        case .merge:
            lines.append(("pages after merge", arrow))
        case .replace:
            lines.append(("pages after replace", arrow))
            lines.append(("discarded", Self.thousands(plan.existingPages)))
        }
        // The second half of the same import, and it is its own block rather
        // than being interleaved with the pages: the two corpora are different
        // sizes by three orders of magnitude, and a reader comparing 108 854
        // with 312 down the same column reads the smaller number as a rounding
        // error rather than as the bar they use every day.
        switch plan.sourceBookmarks {
        case .some(let count):
            lines.append(("bookmarks in source", Self.thousands(count)))
            lines.append(("already kept here", Self.thousands(plan.bookmarksAlreadyKnown)))
            let newKept = count - plan.bookmarksAlreadyKnown
            switch dry.mode {
            case .merge:
                lines.append((
                    "bookmarks after merge",
                    "\(Self.thousands(plan.existingBookmarks)) → at least "
                        + Self.thousands(plan.existingBookmarks + newKept)))
            case .replace:
                lines.append((
                    "bookmarks after replace",
                    "\(Self.thousands(plan.existingBookmarks)) → at least "
                        + Self.thousands(newKept)))
            }
        case .none:
            // Not a zero. Safari keeps its bookmarks in a binary property list
            // this app does not read, and a blank row would say it has none.
            lines.append(("bookmarks", "not readable from this browser"))
        }
        return lines
    }

    /// The button that writes. It says which of the two it is doing and to how
    /// many pages, because it is the last thing read before a `Replace`.
    var confirmTitle: String {
        guard let dry else { return "Import" }
        switch dry.mode {
        case .merge:
            let kept = (dry.plan.sourceBookmarks ?? 0) - dry.plan.bookmarksAlreadyKnown
            guard kept > 0 else { return "Merge \(Self.thousands(dry.plan.newPages)) new pages" }
            return "Merge \(Self.thousands(dry.plan.newPages)) pages and "
                + "\(Self.thousands(kept)) bookmarks"
        case .replace: return "Replace with \(Self.thousands(dry.plan.sourcePages)) pages"
        }
    }

    /// Nothing to write, so nothing to confirm.
    /// What the working screen says, which is the one string here with a duty of
    /// care: fifteen seconds of "a few seconds" is how someone concludes it has
    /// hung and force-quits mid-import.
    ///
    /// The estimate is arithmetic on a measurement, not a guess — the owner's
    /// 613 MB / 108 854-page Vivaldi profile imported in 15.3 s in release, so
    /// [`PAGES_PER_SECOND`] is that, rounded down.
    func workingMessage(importing: Bool) -> String {
        let name = selectedSource.map { title(of: $0) } ?? "the browser"
        guard importing else {
            let size = selectedSource.map { " (\(Self.bytes($0.sizeBytes)))" } ?? ""
            return "Copying \(name)\(size) and reading it. Nothing is written yet."
        }
        guard let dry else { return "Importing \(name)." }
        let seconds = max(1, Int((Double(dry.plan.sourcePages) / Self.PAGES_PER_SECOND).rounded()))
        return "Importing \(Self.thousands(dry.plan.sourcePages)) pages from \(name). "
            + "About \(seconds) second\(seconds == 1 ? "" : "s")."
    }

    /// Measured, release, on an M-series Mac: 108 854 pages in 15.3 s, of which
    /// the bulk upsert, the total re-`seq` and the rebuilt trigram index are
    /// nearly all of it. Rounded down so the estimate errs long.
    static let PAGES_PER_SECOND = 7_000.0

    var hasSomethingToDo: Bool {
        guard let dry else { return false }
        switch dry.mode {
        case .merge: return dry.plan.sourcePages > 0 || (dry.plan.sourceBookmarks ?? 0) > 0
        case .replace:
            return dry.plan.sourcePages > 0 || dry.plan.existingPages > 0
                || (dry.plan.sourceBookmarks ?? 0) > 0 || dry.plan.existingBookmarks > 0
        }
    }

    // MARK: - afterwards

    var doneLines: [(String, String)] {
        guard let outcome else { return [] }
        var lines: [(String, String)] = [
            ("pages added", Self.thousands(outcome.inserted)),
            ("pages folded", Self.thousands(outcome.updated)),
        ]
        if outcome.discarded > 0 {
            lines.append(("pages discarded", Self.thousands(outcome.discarded)))
        }
        lines.append(("history now holds", Self.thousands(outcome.plan.resultingPages)))
        if outcome.bookmarksInserted > 0 {
            // Rows, folders included, because that is what the sidebar is about
            // to draw and the number the report promised was "at least".
            lines.append(("bookmarks added", Self.thousands(outcome.bookmarksInserted)))
        }
        if outcome.bookmarksDiscarded > 0 {
            lines.append(("bookmarks discarded", Self.thousands(outcome.bookmarksDiscarded)))
        }
        lines.append(("took", Self.seconds(outcome.elapsedMs)))
        if let backup = outcome.backupPath {
            lines.append(("old ledger saved to", Self.abbreviate(backup)))
        }
        return lines
    }

    /// The one sentence at the top of the last screen.
    var doneHeadline: String {
        guard let outcome else { return "" }
        if outcome.inserted == 0 && outcome.updated == 0 && outcome.discarded == 0
            && outcome.bookmarksInserted == 0 && outcome.bookmarksDiscarded == 0
        {
            return "Nothing changed — this browser was already here."
        }
        if outcome.bookmarksInserted > 0 {
            return "⌘O and ⌘Y can find these pages; the bookmarks are in the sidebar."
        }
        return "⌘O and ⌘Y can find these pages now."
    }

    // MARK: - formatting

    /// Grouped, because `109046` and `1090460` are the same shape at a glance
    /// and this screen is entirely a comparison of counts.
    static func thousands(_ n: UInt32) -> String {
        var digits = Array(String(n))
        var out: [Character] = []
        while digits.count > 3 {
            out = [","] + digits.suffix(3) + out
            digits.removeLast(3)
        }
        return String(digits + out)
    }

    static func bytes(_ n: UInt64) -> String {
        let mb = Double(n) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(n) / 1024)
    }

    static func seconds(_ ms: Int64) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    static func range(_ plan: ImportPlan, calendar: Calendar = .current) -> String {
        guard let from = plan.earliestVisitAt, let to = plan.latestVisitAt else { return "—" }
        let a = HistoryClock.date(Date(timeIntervalSince1970: Double(from) / 1000), calendar: calendar)
        let b = HistoryClock.date(Date(timeIntervalSince1970: Double(to) / 1000), calendar: calendar)
        return a == b ? a : "\(a) → \(b)"
    }

    /// `~/Library/…/Vivaldi/Default/History`. The full path is 60 characters of
    /// which the middle 30 are the same on every Mac, and the panel is a
    /// portrait-width column.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

// MARK: - the panel

/// Import another browser's history: pick a browser, pick merge or replace, read
/// what it would do, then do it.
///
/// A borderless square panel rather than a sheet, for the reason `SearchPalette`
/// is one: `.titled` gets macOS's rounded chrome whatever the content layer
/// says. It is a child window of the strip so it travels with it, and it holds
/// itself alive while it is on screen — the caller hands over a completion and
/// is under no obligation to keep the controller.
@MainActor
final class ImportHistoryWizard: Popup {
    /// Internal rather than private so the render-sheet test can put the panel
    /// on a step and draw it. Every screen after the first needs a dry run or an
    /// outcome to show, and neither is something a test should have to produce
    /// by running an import.
    var model: ImportWizardModel
    private let store: StripStore
    private var monitor: Any?

    private let body = NSStackView()
    private let heading = NSTextField(labelWithString: "")
    private let buttons = NSStackView()

    /// `sources` is for the render sheet, which needs the same three rows on
    /// every machine rather than whatever browsers the developer has installed.
    init(store: StripStore, sources: [HistorySource]? = nil) {
        self.store = store
        self.model = ImportWizardModel(sources: sources ?? store.historySources())
        // `.explicitOnly`: a stray click on the strip must not throw away an
        // import half chosen, so this closes on Esc or its own buttons. An
        // import runs for seconds and the user is entitled to look at the strip
        // while it does. See `Popup`.
        super.init(size: NSSize(width: 560, height: 440), dismissal: .explicitOnly)
        let panel = window!

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

        // Not IMPORT_HISTORY any more: one pass over a profile brings its
        // history and its bookmarks, because "import from Vivaldi" is one
        // decision and asking it twice would be two wizards over one file.
        let header = SectionHeader(text: "IMPORT_BROWSER")
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

    /// Its own monitor handles Esc — and declines it while an import is writing.
    override var handlesEscape: Bool { true }

    override func popupDidPresent() {
        installKeyMonitor()
    }

    func dismiss() {
        guard isOpen else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        closePopup()
    }


    private func installKeyMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window?.isKeyWindow == true else { return event }
            switch event.keyCode {
            case 53: self.escape(); return nil            // esc
            case 36, 76: self.advance(); return nil       // return, enter
            case 125: self.move(by: 1); return nil        // down
            case 126: self.move(by: -1); return nil       // up
            default: return event
            }
        }
    }

    /// Esc closes, except while a bulk write is in flight — there is nothing to
    /// cancel by then (it is one transaction) and a window that vanishes
    /// mid-import is how someone concludes it failed.
    private func escape() {
        if case .working = model.step { return }
        dismiss()
    }

    private func move(by delta: Int) {
        switch model.step {
        case .source:
            guard !model.sources.isEmpty else { return }
            model.selected = min(max(0, model.selected + delta), model.sources.count - 1)
        case .mode:
            model.mode = model.mode == .merge ? .replace : .merge
        default:
            return
        }
        render()
    }

    private func advance() {
        switch model.step {
        case .source:
            guard model.selectedSource != nil, model.blockedReason == nil else { return }
            model.step = .mode
            render()
        case .mode:
            runDryRun()
        case .report:
            guard model.hasSomethingToDo else { return }
            runImport()
        case .working:
            return
        case .done, .failed:
            dismiss()
        }
    }

    private func back() {
        switch model.step {
        case .mode: model.step = .source
        case .report: model.step = .mode
        default: return
        }
        render()
    }

    private func runDryRun() {
        guard let source = model.selectedSource else { return }
        let mode = model.mode
        model.step = .working(importing: false)
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await self.store.planHistoryImport(source, mode)
                self.model.dry = ImportWizardModel.DryRun(mode: mode, plan: plan)
                self.model.step = .report
            } catch {
                self.model.step = .failed(Self.sentence(error))
            }
            self.render()
        }
    }

    private func runImport() {
        guard let source = model.selectedSource else { return }
        let mode = model.mode
        model.step = .working(importing: true)
        render()
        Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.store.importHistory(source, mode)
                self.model.outcome = outcome
                self.model.step = .done
            } catch {
                self.model.step = .failed(Self.sentence(error))
            }
            self.render()
        }
    }

    /// The sentence, not the enum case. `CoreError` spells out what went wrong
    /// and reflecting the case instead was a bug this repo has already fixed
    /// once, in the CLI.
    static func sentence(_ error: Error) -> String {
        (error as? LanedCore.CoreError).map { "\($0.localizedDescription)" }
            ?? error.localizedDescription
    }

    // MARK: - drawing each step

    func render() {
        for v in body.views { v.removeFromSuperview() }
        for v in buttons.views { v.removeFromSuperview() }

        switch model.step {
        case .source: renderSource()
        case .mode: renderMode()
        case .report: renderReport()
        case .working(let importing): renderWorking(importing: importing)
        case .done: renderDone()
        case .failed(let why): renderFailed(why)
        }
        window?.contentView?.needsDisplay = true
    }

    private func renderSource() {
        if model.isEmpty {
            heading.stringValue = "No browser profile found on this Mac."
            addRow(paragraph(
                "Max Pane looks for Chromium-family profiles, Safari's History.db and "
                + "Firefox's places.sqlite. None of them is where it would be."))
            buttons.addView(button("Close", isDefault: true) { [weak self] in self?.dismiss() }, in: .trailing)
            return
        }
        heading.stringValue = "Which browser? ↑ ↓ to choose, ↩ to continue."
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
        }
        buttons.addView(button("Cancel", isDefault: false) { [weak self] in self?.dismiss() }, in: .trailing)
        buttons.addView(
            button("Continue", isDefault: model.blockedReason == nil) { [weak self] in self?.advance() },
            in: .trailing)
    }

    private func renderMode() {
        heading.stringValue = "↑ ↓ to switch, ↩ to see what it would do."
        for mode in [ImportMode.merge, ImportMode.replace] {
            let row = WizardRow(
                title: mode == .merge ? "Merge" : "Replace",
                detail: ImportWizardModel.explanation(of: mode, plan: model.dry?.plan),
                isSelected: model.mode == mode,
                isBlocked: false,
                wraps: true)
            row.onClick = { [weak self] in
                self?.model.mode = mode
                self?.render()
            }
            addRow(row)
        }
        buttons.addView(button("Back", isDefault: false) { [weak self] in self?.back() }, in: .trailing)
        buttons.addView(button("Check", isDefault: true) { [weak self] in self?.advance() }, in: .trailing)
    }

    private func renderReport() {
        heading.stringValue = "Nothing has been written yet."
        for (label, value) in model.reportLines {
            addRow(statLine(label, value))
        }
        if model.mode == .replace {
            addRow(paragraph(
                "The whole ledger is copied first, and the next screen names the file."))
        }
        buttons.addView(button("Back", isDefault: false) { [weak self] in self?.back() }, in: .trailing)
        buttons.addView(
            button(model.confirmTitle, isDefault: model.hasSomethingToDo) { [weak self] in self?.advance() },
            in: .trailing)
    }

    private func renderWorking(importing: Bool) {
        heading.stringValue = model.workingMessage(importing: importing)
        let spinner = NSProgressIndicator()
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addRow(spinner)
        addRow(paragraph(
            "The browser's own file is never written to — Max Pane reads a copy and "
            + "deletes it afterwards."))
    }

    private func renderDone() {
        heading.stringValue = model.doneHeadline
        for (label, value) in model.doneLines {
            addRow(statLine(label, value))
        }
        buttons.addView(button("Done", isDefault: true) { [weak self] in self?.dismiss() }, in: .trailing)
    }

    private func renderFailed(_ why: String) {
        heading.stringValue = "The import did not happen."
        addRow(paragraph(why))
        addRow(paragraph("Nothing was written: an import is one transaction."))
        buttons.addView(button("Close", isDefault: true) { [weak self] in self?.dismiss() }, in: .trailing)
    }

    // MARK: - small views

    /// Add a row to the body at full panel width.
    ///
    /// The order matters and is the whole reason this exists: a constraint
    /// between two views is only legal once they share an ancestor, so
    /// `widthAnchor` has to be tied to `body` *after* the `addView`. Building the
    /// row with the constraint already on it throws `NSGenericException` — which
    /// is how the render-sheet test found this.
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

    /// `label ……… value`, the shape the status bar already uses for a count.
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

/// The panel body: square, filled, outlined on all four sides — never a single
/// accent edge, which is the house's named anti-pattern.
///
/// Internal rather than private because the passwords import is a second window
/// with the same body, and two copies of a shape whose whole job is to be
/// recognisably the same shape is how two windows drift apart.
@MainActor
final class ImportWizardPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.stripBackground.setFill()
        bounds.fill()
        Theme.laneBorder.setFill()
        for rect in [
            NSRect(x: 0, y: 0, width: bounds.width, height: Theme.borderWidth),
            NSRect(x: 0, y: bounds.height - Theme.borderWidth, width: bounds.width, height: Theme.borderWidth),
            NSRect(x: 0, y: 0, width: Theme.borderWidth, height: bounds.height),
            NSRect(x: bounds.width - Theme.borderWidth, y: 0, width: Theme.borderWidth, height: bounds.height),
        ] { rect.fill() }
    }
}

/// `// SECTION_HEADER`, with the slashes in Signal Orange.
@MainActor
/// `// SECTION_NAME` with the slashes in Signal Orange — the house header, used
/// by every panel that is not a palette.
final class SectionHeader: NSTextField {
    init(text: String) {
        super.init(frame: .zero)
        isEditable = false
        isBordered = false
        drawsBackground = false
        isSelectable = false
        let s = NSMutableAttributedString(string: "// ", attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: Theme.accent,
        ])
        s.append(NSAttributedString(string: text, attributes: [
            .font: Theme.mono(11, weight: .bold), .foregroundColor: NSColor.labelColor,
        ]))
        attributedStringValue = s
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }
}

/// One choosable row: a title, a detail line, and a full-perimeter outline when
/// it is the one selected.
@MainActor
final class WizardRow: NSView {
    var onClick: (() -> Void)?

    private let isSelected: Bool
    private let isBlocked: Bool

    init(title: String, detail: String, isSelected: Bool, isBlocked: Bool, wraps: Bool = false) {
        self.isSelected = isSelected
        self.isBlocked = isBlocked
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The `$` marks the live choice, the way it marks an active state
        // everywhere else in this app. It is not a bullet: an unselected row
        // gets two spaces, so the titles stay in one column.
        let name = NSTextField(labelWithString: (isSelected ? "$ " : "  ") + title)
        name.font = Theme.mono(12, weight: isSelected ? .medium : .regular)
        name.textColor = isBlocked ? Theme.dimText : (isSelected ? Theme.accent : .labelColor)
        let sub = wraps
            ? NSTextField(wrappingLabelWithString: "  " + detail)
            : NSTextField(labelWithString: "  " + detail)
        sub.font = Theme.mono(10)
        sub.textColor = Theme.dimText
        sub.drawsBackground = false
        sub.isBezeled = false

        let stack = NSStackView(views: [name, sub])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func mouseUp(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        Theme.accent.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}
