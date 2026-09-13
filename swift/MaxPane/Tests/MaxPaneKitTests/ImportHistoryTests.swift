import Foundation
import LanedCore
import Testing

@testable import MaxPaneKit

/// The history-import wizard.
///
/// What the app half of this feature has to get right is the *wording*, so most
/// of what follows reads the strings. Two of them carry an obligation rather
/// than a description: the Replace explanation has to say that the old ledger is
/// kept, because it is the only undo, and the report screen has to be able to
/// say that nothing has been written yet — which is only true if the dry run
/// really is one, and the last suite here proves that against a real file.
@Suite("the import wizard's wording")
@MainActor
struct ImportWizardWordingTests {
    private func source(
        _ name: String, profile: String? = nil, bytes: UInt64 = 642_875_392,
        blocked: String? = nil
    ) -> HistorySource {
        HistorySource(
            name: name, profile: profile, kind: .chromium,
            path: NSHomeDirectory() + "/Library/Application Support/\(name)/Default/History",
            sizeBytes: bytes, blocked: blocked)
    }

    private func plan(
        source: UInt32 = 109_046, skipped: UInt32 = 3_800, known: UInt32 = 12,
        existing: UInt32 = 431, from: Int64? = 1_708_620_457_202, to: Int64? = 1_757_000_000_000,
        resulting: UInt32? = nil
    ) -> ImportPlan {
        ImportPlan(
            sourcePages: source, skipped: skipped, alreadyKnown: known,
            newPages: source - known, earliestVisitAt: from, latestVisitAt: to,
            existingPages: existing, resultingPages: resulting ?? existing + (source - known))
    }

    @Test("a browser with one profile is not labelled with one")
    func titles() {
        let m = ImportWizardModel(sources: [source("Safari"), source("Vivaldi", profile: "Default")])
        #expect(m.title(of: m.sources[0]) == "Safari")
        #expect(m.title(of: m.sources[1]) == "Vivaldi — Default")
    }

    @Test("the row says how large the file is and where it is, abbreviated")
    func details() {
        let m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        let detail = m.detail(of: m.sources[0])
        #expect(detail.contains("613 MB"))
        #expect(detail.hasSuffix("~/Library/Application Support/Vivaldi/Default/History"))
        #expect(!detail.contains(NSHomeDirectory()), "the home directory is 20 characters of nothing")
    }

    /// Opening on a row that cannot be used makes the common case ↩ into a
    /// sentence about System Settings.
    @Test("the selection starts on something importable")
    func initialSelectionSkipsBlocked() {
        let m = ImportWizardModel(sources: [
            source("Safari", blocked: "macOS is withholding Safari's history. … Full Disk Access …"),
            source("Vivaldi", profile: "Default"),
        ])
        #expect(m.selected == 1)
        #expect(m.blockedReason == nil)
    }

    @Test("a blocked row cannot be advanced past, and says why")
    func blockedRowExplainsItself() {
        var m = ImportWizardModel(sources: [
            source("Safari", blocked: "macOS is withholding Safari's history. Give Max Pane Full Disk Access …")
        ])
        #expect(m.selected == 0)
        #expect(m.blockedReason?.contains("Full Disk Access") == true)
        m.selected = 0
        #expect(m.blockedReason != nil)
    }

    @Test("every browser gone means a sentence, not an empty list")
    func noSources() {
        let m = ImportWizardModel(sources: [])
        #expect(m.isEmpty)
        #expect(m.selectedSource == nil)
    }

    /// The difference is explained rather than assumed — and Replace's
    /// explanation has to mention the backup, because that file is the only way
    /// back from a one-click choice.
    @Test("merge and replace each say what happens to what is already here")
    func modesAreExplained() {
        let merge = ImportWizardModel.explanation(of: .merge, plan: plan())
        #expect(merge.contains("Nothing is deleted"))
        #expect(merge.contains("earlier first visit"))
        #expect(merge.contains("later last visit"))
        #expect(merge.contains("twice changes nothing"))

        let replace = ImportWizardModel.explanation(of: .replace, plan: plan())
        #expect(replace.contains("431"), "replace should say how much it is throwing away")
        #expect(replace.contains("only way back"))
        #expect(replace.contains("copied"))
    }

    /// The mode screen comes *before* the dry run, so this is the sentence the
    /// user actually reads — and assembling it from a count and a plural spelled
    /// it "the every pages" until the render sheet showed it.
    @Test("replace reads as English with a count and without one")
    func replaceCountsAgree() {
        let one = ImportWizardModel.explanation(of: .replace, plan: plan(existing: 1))
        #expect(one.contains("Throws away the 1 page Max Pane"))

        let many = ImportWizardModel.explanation(of: .replace, plan: plan(existing: 431))
        #expect(many.contains("Throws away the 431 pages Max Pane"))

        let unknown = ImportWizardModel.explanation(of: .replace, plan: nil)
        #expect(unknown.contains("Throws away every page Max Pane"))
        #expect(!unknown.contains("every pages"))
    }

    @Test("the report carries every number a dry run promised")
    func reportLines() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.dry = .init(mode: .merge, plan: plan())
        m.step = .report
        let lines = Dictionary(uniqueKeysWithValues: m.reportLines)
        #expect(lines["pages in source"] == "109,046")
        #expect(lines["not importable"] == "3,800")
        #expect(lines["already in Max Pane"] == "12")
        #expect(lines["new to Max Pane"] == "109,034")
        #expect(lines["pages after merge"] == "431 → 109,465")
        #expect(lines["covering"]?.contains("2024") == true)
        #expect(lines["covering"]?.contains("→") == true)
    }

    @Test("replace's report says what it discards")
    func replaceReportSaysDiscarded() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        // A `Replace` plan is the one the core computed for `Replace`: the whole
        // source stands alone, so the ledger ends up at exactly `sourcePages`.
        m.dry = .init(mode: .replace, plan: plan(resulting: 109_046))
        let lines = Dictionary(uniqueKeysWithValues: m.reportLines)
        #expect(lines["discarded"] == "431")
        #expect(lines["pages after replace"] == "431 → 109,046")
    }

    /// The last thing read before a `Replace`, so it may not say "Import".
    @Test("the confirm button names the act and the count")
    func confirmTitle() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.dry = .init(mode: .merge, plan: plan())
        #expect(m.confirmTitle == "Merge 109,034 new pages")
        m.dry = .init(mode: .replace, plan: plan(resulting: 109_046))
        #expect(m.confirmTitle == "Replace with 109,046 pages")
    }

    @Test("an empty source has nothing to confirm")
    func nothingToDo() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.dry = .init(mode: .merge, plan: plan(source: 0, skipped: 0, known: 0, existing: 0, from: nil, to: nil))
        #expect(!m.hasSomethingToDo)
        #expect(ImportWizardModel.range(m.dry!.plan) == "—")
    }

    @Test("the last screen names the backup file")
    func doneNamesTheBackup() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.mode = .replace
        m.outcome = ImportOutcome(
            plan: plan(), inserted: 109_046, updated: 0, discarded: 431,
            backupPath: NSHomeDirectory() + "/Library/Application Support/MaxPane/profiles/default/ledger.db.pre-import-17",
            elapsedMs: 8_412)
        let lines = Dictionary(uniqueKeysWithValues: m.doneLines)
        #expect(lines["pages added"] == "109,046")
        #expect(lines["pages discarded"] == "431")
        #expect(lines["took"] == "8.4 s")
        #expect(lines["old ledger saved to"]?.hasPrefix("~/Library") == true)
        #expect(m.doneHeadline.contains("⌘O"))
    }

    @Test("a merge that changed nothing says so rather than congratulating itself")
    func idempotentImportSaysSo() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.outcome = ImportOutcome(
            plan: plan(), inserted: 0, updated: 0, discarded: 0, backupPath: nil, elapsedMs: 120)
        #expect(m.doneHeadline.contains("already here"))
        let lines = Dictionary(uniqueKeysWithValues: m.doneLines)
        #expect(lines["old ledger saved to"] == nil, "a merge takes no backup and must not claim one")
        #expect(lines["took"] == "120 ms")
    }

    /// Not a hypothetical: without this, going Back from the report, choosing
    /// the other mode and pressing ↩ would show `Merge`'s numbers above a button
    /// that performs a `Replace`.
    @Test("changing the mode throws the dry run away")
    func switchingModeDiscardsTheReport() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])
        m.dry = .init(mode: .merge, plan: plan())
        #expect(!m.reportLines.isEmpty)
        m.mode = .replace
        #expect(m.dry == nil)
        #expect(m.reportLines.isEmpty)
        #expect(!m.hasSomethingToDo, "a mode with no dry run may not be confirmable")
        // Setting it to what it already was is not a change.
        m.dry = .init(mode: .replace, plan: plan(resulting: 109_046))
        m.mode = .replace
        #expect(m.dry != nil)
    }

    /// Fifteen seconds of "a few seconds" is how someone concludes it has hung
    /// and force-quits in the middle of a bulk write.
    @Test("the working screen says which half it is in, and roughly how long")
    func workingMessage() {
        var m = ImportWizardModel(sources: [source("Vivaldi", profile: "Default")])

        let copying = m.workingMessage(importing: false)
        #expect(copying.contains("Copying Vivaldi — Default (613 MB)"))
        #expect(copying.contains("Nothing is written yet"), "the dry run must not imply it wrote")

        m.dry = .init(mode: .merge, plan: plan())
        let importing = m.workingMessage(importing: true)
        #expect(importing.contains("109,046 pages"))
        #expect(importing.contains("Vivaldi — Default"))
        // 109,046 / 7,000 measured pages a second, rounded.
        #expect(importing.contains("About 16 seconds"))
        #expect(!importing.contains("Nothing is written"))
    }

    @Test("a tiny import is one second, not one seconds")
    func workingMessagePlural() {
        var m = ImportWizardModel(sources: [source("Safari")])
        m.dry = .init(mode: .merge, plan: plan(source: 40, skipped: 0, known: 0, existing: 0))
        #expect(m.workingMessage(importing: true).hasSuffix("About 1 second."))
    }

    @Test("counts are grouped, because the screen is a comparison of counts")
    func thousands() {
        #expect(ImportWizardModel.thousands(0) == "0")
        #expect(ImportWizardModel.thousands(7) == "7")
        #expect(ImportWizardModel.thousands(999) == "999")
        #expect(ImportWizardModel.thousands(1_000) == "1,000")
        #expect(ImportWizardModel.thousands(112_846) == "112,846")
        #expect(ImportWizardModel.thousands(1_112_846) == "1,112,846")
    }

    @Test("sizes read the way the Finder says them")
    func bytes() {
        #expect(ImportWizardModel.bytes(642_875_392) == "613 MB")
        #expect(ImportWizardModel.bytes(5_242_880) == "5 MB")
        #expect(ImportWizardModel.bytes(241_664) == "236 KB")
        #expect(ImportWizardModel.bytes(3_221_225_472) == "3.0 GB")
    }

    /// The two ends of a two-year range are dates, not "22d ago".
    @Test("a date range is two full dates")
    func dateRange() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let p = plan(from: 1_708_620_457_202, to: 1_708_620_457_202)
        #expect(ImportWizardModel.range(p, calendar: cal) == "22 Feb 2024")
        let two = plan(from: 1_708_620_457_202, to: 1_757_000_000_000)
        #expect(ImportWizardModel.range(two, calendar: cal) == "22 Feb 2024 → 4 Sep 2025")
    }
}

/// The dry run against a real file: it has to report, and it has to write
/// nothing. Both halves matter — a "dry run" that has already imported is worse
/// than no dry run at all.
@Suite("the dry run over a real profile")
@MainActor
struct ImportDryRunTests {
    private func store() throws -> (StripStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try StripStore(ledgerPath: dir.appendingPathComponent("ledger.db").path), dir)
    }

    /// A Chromium `History` file, built with the `sqlite3` every Mac has, so the
    /// fixture is a real database rather than a mock of one.
    private func chromiumFixture(in dir: URL) throws -> HistorySource {
        let path = dir.appendingPathComponent("History")
        // 13353094057202910 µs since 1601-01-01 is 2024-02-22, and is the first
        // visit in the owner's own Vivaldi profile.
        let sql = """
        CREATE TABLE urls(id INTEGER PRIMARY KEY, url LONGVARCHAR, title LONGVARCHAR,
                          visit_count INTEGER DEFAULT 0 NOT NULL, last_visit_time INTEGER NOT NULL,
                          hidden INTEGER DEFAULT 0 NOT NULL);
        CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER NOT NULL, visit_time INTEGER NOT NULL);
        INSERT INTO urls VALUES (1, 'https://doc.rust-lang.org/std/', 'std - Rust', 9, 13353094057202910, 0);
        INSERT INTO visits VALUES (1, 1, 13353094057202910);
        INSERT INTO urls VALUES (2, 'https://news.example/', 'News', 2, 13353094067202910, 0);
        INSERT INTO visits VALUES (2, 2, 13353094067202910);
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [path.path, sql]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return HistorySource(
            name: "Fixture", profile: nil, kind: .chromium, path: path.path,
            sizeBytes: UInt64((try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0),
            blocked: nil)
    }

    @Test("a dry run reports and writes nothing; the import that follows agrees with it")
    func dryRunThenImport() async throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try chromiumFixture(in: dir)

        let plan = try await store.planHistoryImport(source, .merge)
        #expect(plan.sourcePages == 2)
        #expect(plan.newPages == 2)
        #expect(plan.existingPages == 0)
        #expect(store.historyCount == 0, "the dry run wrote something")

        let outcome = try await store.importHistory(source, .merge)
        #expect(outcome.plan == plan, "the report described a different import")
        #expect(outcome.inserted == 2)
        #expect(outcome.backupPath == nil, "a merge does not need a way back")
        #expect(store.historyCount == 2)

        // And they are findable, which is the only reason any of this happened.
        #expect(store.history("rust-lang").contains { $0.url.contains("doc.rust-lang.org") })
        #expect(store.history("").count == 2)
    }

    @Test("replace names the file it wrote")
    func replaceNamesItsBackup() async throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try chromiumFixture(in: dir)
        try store.newWebLane(url: "https://kept.example/", near: nil)

        let outcome = try await store.importHistory(source, .replace)
        let backup = try #require(outcome.backupPath)
        #expect(FileManager.default.fileExists(atPath: backup))
        // The whole ledger, so the lanes come back with the history.
        let old = try StripStore(ledgerPath: backup)
        #expect(old.state.lanes.count == 1)
    }

    /// The wizard offers what is on the disk. Whatever this machine has, every
    /// row has to be something we could act on — a name, a path, and a size.
    @Test("detection describes each source well enough to choose between them")
    func detectionIsUsable() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = ImportWizardModel(sources: store.historySources())
        for source in model.sources {
            #expect(!source.name.isEmpty)
            #expect(source.path.hasPrefix("/"))
            #expect(!model.title(of: source).isEmpty)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }
}

/// A picture of each screen, for the same reason `OmniPickerRenderTests` takes
/// one: what a row *says* is testable and whether a wizard reads as a sequence
/// of decisions is not. Gated on `MAXPANE_SHOTS`, so it costs nothing normally.
///
///     ./scripts/test.sh shots /tmp/shots
@Suite("import wizard rendering")
@MainActor
struct ImportWizardRenderTests {
    @Test("renders every screen, with the browsers a real Mac has")
    func renderSheets() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxpane-shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try StripStore(ledgerPath: tmp.appendingPathComponent("ledger.db").path)

        // Fixed rows, so the sheet is the same on every machine: two profiles of
        // one browser (the case the detail line exists for) and one behind TCC.
        let sources = [
            HistorySource(
                name: "Vivaldi", profile: "Default", kind: .chromium,
                path: NSHomeDirectory() + "/Library/Application Support/Vivaldi/Default/History",
                sizeBytes: 642_875_392, blocked: nil),
            HistorySource(
                name: "Vivaldi", profile: "Profile 2", kind: .chromium,
                path: NSHomeDirectory() + "/Library/Application Support/Vivaldi/Profile 2/History",
                sizeBytes: 8_437_760, blocked: nil),
            HistorySource(
                name: "Safari", profile: nil, kind: .safari,
                path: NSHomeDirectory() + "/Library/Safari/History.db",
                sizeBytes: 241_664,
                blocked: "macOS is withholding Safari's history. Give Max Pane Full Disk Access "
                    + "in System Settings → Privacy & Security, then reopen this window."),
        ]
        let plan = ImportPlan(
            sourcePages: 109_046, skipped: 3_800, alreadyKnown: 12, newPages: 109_034,
            earliestVisitAt: 1_708_620_457_202, latestVisitAt: 1_757_000_000_000,
            existingPages: 431, resultingPages: 109_465)

        let screens: [(String, (inout ImportWizardModel) -> Void)] = [
            ("1-source", { $0.step = .source }),
            ("2-source-blocked", { $0.step = .source; $0.selected = 2 }),
            ("3-mode", { $0.step = .mode }),
            ("4-report", { $0.dry = .init(mode: .merge, plan: plan); $0.step = .report }),
            ("5-report-replace", {
                $0.mode = .replace
                $0.dry = .init(
                    mode: .replace,
                    plan: ImportPlan(
                        sourcePages: plan.sourcePages, skipped: plan.skipped,
                        alreadyKnown: plan.alreadyKnown, newPages: plan.newPages,
                        earliestVisitAt: plan.earliestVisitAt, latestVisitAt: plan.latestVisitAt,
                        existingPages: plan.existingPages, resultingPages: plan.sourcePages))
                $0.step = .report
            }),
            ("6-working", { $0.dry = .init(mode: .merge, plan: plan); $0.step = .working(importing: true) }),
            ("7-done", {
                $0.outcome = ImportOutcome(
                    plan: plan, inserted: 109_034, updated: 12, discarded: 0,
                    backupPath: nil, elapsedMs: 8_412)
                $0.step = .done
            }),
        ]

        for (name, configure) in screens {
            let wizard = ImportHistoryWizard(store: store, sources: sources)
            configure(&wizard.model)
            wizard.render()
            let view = try #require(wizard.window?.contentView)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("import-\(name).png"))
        }
    }
}
