import AppKit
import Foundation
import Testing
@testable import MaxPaneKit

/// The parser on the real file and on the edges it does not have yet, the
/// corner text, and the popup's model.
@Suite("changelog")
struct ChangelogTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static var realText: String {
        get throws { try String(contentsOf: repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8) }
    }

    /// An independent count of the file, so the test cannot rot: `- ` lines
    /// between each `## ` heading and the next, keyed by the heading's version.
    static func handCount(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        var current: String?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                current = line.dropFirst(3).components(separatedBy: " ").first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                counts[current!] = 0
            } else if line.hasPrefix("- "), let current {
                counts[current, default: 0] += 1
            }
        }
        return counts
    }

    @Test("the real CHANGELOG.md parses to the sections it has, with every entry counted")
    func realFile() throws {
        let text = try Self.realText
        let log = Changelog.parse(text)
        let counted = Self.handCount(text)

        #expect(log.sections.map(\.version) == Array(counted.keys).sorted { a, b in
            text.range(of: "## [\(a)]")!.lowerBound < text.range(of: "## [\(b)]")!.lowerBound
        })
        for section in log.sections {
            #expect(section.count == counted[section.version], "\(section.version)")
            for group in section.groups {
                #expect(["Added", "Changed", "Fixed", "Removed", "Deprecated", "Security"].contains(group.category), Comment(rawValue: group.category))
                #expect(!group.entries.isEmpty, "\(section.version) › \(group.category) is empty")
                for entry in group.entries {
                    #expect(!entry.hasPrefix("- "))
                    #expect(entry == entry.trimmingCharacters(in: .whitespaces))
                }
            }
        }
        #expect(log.sections.first?.isUnreleased == true)
        // Zero at the moment a release is cut, when everything has just moved
        // under the new version; the corner then reads the bare version.
        #expect(log.unreleasedCount == (counted["Unreleased"] ?? 0))
        // The link block at the foot is not a section and not an entry.
        #expect(!log.sections.contains { $0.version.hasPrefix("http") })
        // Every released section has a date; the link references did not
        // leak into one as an entry.
        for section in log.sections where !section.isUnreleased {
            #expect(section.date?.count == 10, Comment(rawValue: section.version))
            #expect(!section.groups.flatMap(\.entries).contains { $0.hasPrefix("[") && $0.contains("]: http") })
        }
        // The top release is the plist's version — release.sh's contract, and
        // the version the corner shows.
        let plist = try #require(NSDictionary(contentsOf: Self.repoRoot.appendingPathComponent("swift/MaxPane/Resources/Info.plist")) as? [String: Any])
        #expect(log.latestRelease?.version == plist["CFBundleShortVersionString"] as? String)
    }

    @Test("a missing Unreleased section, empty categories, entries under no category, continuation lines, and the link block")
    func edges() {
        let text = """
            # Changelog

            Some preamble with a - dash that is not an entry.
            - nor is this, before any heading

            ## [0.2.0] - 2026-02-02

            ### Added
            - One
            - Two, with `backticks` kept
              and a wrapped second line
            ### Changed

            ### Fixed
            * Three, starred

            ## 0.1.0 - 2026-01-01
            - Loose, under no category

            ## [0.0.1]

            [0.2.0]: https://example.com/compare/v0.1.0...v0.2.0
            [0.1.0]: https://example.com/releases/tag/v0.1.0
            """
        let log = Changelog.parse(text)
        #expect(log.unreleased == nil)
        #expect(log.unreleasedCount == 0)
        #expect(log.sections.map(\.version) == ["0.2.0", "0.1.0", "0.0.1"])
        #expect(log.sections.map(\.date) == ["2026-02-02", "2026-01-01", nil])
        let top = log.sections[0]
        #expect(top.groups.map(\.category) == ["Added", "Changed", "Fixed"])
        #expect(top.groups[0].entries == ["One", "Two, with `backticks` kept and a wrapped second line"])
        #expect(top.groups[1].entries.isEmpty)
        #expect(top.groups[2].entries == ["Three, starred"])
        #expect(top.count == 3)
        #expect(log.sections[1].groups == [.init(category: "", entries: ["Loose, under no category"])])
        #expect(log.sections[2].groups.isEmpty)
        #expect(log.latestRelease?.version == "0.2.0")
        #expect(Changelog.parse("").sections.isEmpty)
        #expect(Changelog.parse("## [Unreleased]\n").unreleasedCount == 0)
        // Windows line endings do not become part of an entry.
        #expect(Changelog.parse("## [Unreleased]\r\n### Added\r\n- One\r\n").unreleased?.groups[0].entries == ["One"])
    }

    @Test("a section's markdown is the section as Keep a Changelog writes it")
    func markdown() {
        let section = Changelog.Section(version: "0.6.1", date: "2026-09-16", groups: [
            .init(category: "Added", entries: ["A `thing`"]),
            .init(category: "Fixed", entries: ["B", "C"]),
        ])
        #expect(section.markdown == """
            ## [0.6.1] - 2026-09-16

            ### Added
            - A `thing`

            ### Fixed
            - B
            - C

            """)
        #expect(Changelog.Section(version: "Unreleased", date: nil, groups: []).markdown == "## [Unreleased]\n")
        // The real file's top section round-trips: parse, print, parse again.
        let text = (try? Self.realText) ?? ""
        let log = Changelog.parse(text)
        for section in log.sections {
            #expect(Changelog.parse(section.markdown).sections == [section], Comment(rawValue: section.version))
        }
    }

    @Test("the corner reads v0.6.1 on a release, v0.6.1+40 on an unreleased build, nothing extra when dirty")
    func corner() {
        let release = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-16", dirty: false)
        #expect(VersionCorner.text(build: release, unreleased: 0) == .init(version: "v0.6.1", suffix: nil))
        #expect(VersionCorner.text(build: release, unreleased: 0).plain == "v0.6.1")

        let ahead = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-22", dirty: false)
        #expect(VersionCorner.text(build: ahead, unreleased: 40) == .init(version: "v0.6.1", suffix: "+40"))
        #expect(VersionCorner.text(build: ahead, unreleased: 40).plain == "v0.6.1+40")

        let dirty = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-22", dirty: true)
        #expect(VersionCorner.text(build: dirty, unreleased: 40) == VersionCorner.text(build: ahead, unreleased: 40))

        // Built exactly at the tag: the release, whatever Unreleased holds.
        let tagged = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-16", dirty: false, tag: "v0.6.1")
        #expect(VersionCorner.text(build: tagged, unreleased: 40).suffix == nil)
        // Some other tag at HEAD is not this release.
        let other = BuildInfo(version: "0.6.1", commit: "a8e73d6", tag: "spike-3")
        #expect(VersionCorner.text(build: other, unreleased: 40).suffix == "+40")
    }

    @Test("the tooltip says the version, the unreleased count, and what it was built from")
    func tooltip() {
        let dirty = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-22", dirty: true)
        #expect(VersionCorner.tooltip(build: dirty, unreleased: 40)
            == "0.6.1 · 40 unreleased changes · built 2026-09-22 from a8e73d6 (dirty)")
        let clean = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-22", dirty: false)
        #expect(VersionCorner.tooltip(build: clean, unreleased: 1)
            == "0.6.1 · 1 unreleased change · built 2026-09-22 from a8e73d6")
        let release = BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-16", dirty: false, tag: "v0.6.1")
        #expect(VersionCorner.tooltip(build: release, unreleased: 40)
            == "0.6.1 · release build · built 2026-09-16 from a8e73d6")
        // `swift run`: no stamp at all.
        #expect(VersionCorner.tooltip(build: BuildInfo(version: "0.6.1"), unreleased: 3)
            == "0.6.1 · 3 unreleased changes · not a bundled build")
    }

    @Test("BuildInfo reads the plist keys build-app.sh writes, and a plist without them")
    func buildInfo() {
        let stamped = BuildInfo(info: [
            "CFBundleShortVersionString": "0.6.1", "MaxPaneBuildCommit": "a8e73d6",
            "MaxPaneBuildDate": "2026-09-22", "MaxPaneBuildDirty": true, "MaxPaneBuildTag": "v0.6.1",
        ])
        #expect(stamped == BuildInfo(version: "0.6.1", commit: "a8e73d6", date: "2026-09-22", dirty: true, tag: "v0.6.1"))
        // A hand edit that wrote the bool as a word.
        #expect(BuildInfo(info: ["CFBundleShortVersionString": "0.6.1", "MaxPaneBuildDirty": "YES"]).dirty)
        // The checked-in plist, as `swift run` would see it: version only.
        let bare = BuildInfo(info: ["CFBundleShortVersionString": "0.6.1"])
        #expect(bare == BuildInfo(version: "0.6.1"))
        #expect(BuildInfo(info: [:]).version == "0.1.0")
    }

    @Test("What's New is a command in the Help menu beside ⌘/, with no key of its own")
    @MainActor
    func command() {
        #expect(Command.showChangelog.title == "What's New…")
        #expect(Command.showChangelog.menu == .help)
        #expect(Command.showHelp.menu == .help)
        #expect(Command.showChangelog.defaultShortcut == nil)
        #expect(HelpPanel.describe(.showChangelog) == "—")
        #expect(MenuSection.allCases.last == .help)
    }

    @Test("the popup's model: newest first, Unreleased open, releases folded with a count, copy as markdown")
    func popupModel() {
        let log = Changelog.parse("""
            ## [Unreleased]
            ### Added
            - A
            - B
            ## [0.6.1] - 2026-09-16
            ### Fixed
            - C
            ## [0.6.0] - 2026-09-16
            ### Added
            - D
            - E
            - F
            """)
        var model = ChangelogPopupModel(changelog: log)
        #expect(!model.isEmpty)
        #expect(model.items.map(\.header) == ["UNRELEASED · 2", "0.6.1 · 2026-09-16", "0.6.0 · 2026-09-16"])
        #expect(model.items.map(\.isFolded) == [false, true, true])
        #expect(model.items.map(\.foldedCount) == ["2 changes", "1 change", "3 changes"])
        #expect(model.items[1].copyText == "## [0.6.1] - 2026-09-16\n\n### Fixed\n- C\n")
        model.toggle(1)
        #expect(model.items.map(\.isFolded) == [false, false, true])
        model.toggle(0)
        #expect(model.items[0].isFolded)
        model.toggle(99)
        #expect(model.items.map(\.isFolded) == [true, false, true])

        // A release without a date, and a changelog with no Unreleased.
        let dated = ChangelogPopupModel(changelog: Changelog.parse("## [0.1.0]\n- X\n"))
        #expect(dated.items.map(\.header) == ["0.1.0"])
        #expect(dated.items.map(\.isFolded) == [true])

        // No changelog in the bundle.
        let none = ChangelogPopupModel(changelog: nil)
        #expect(none.isEmpty)
        #expect(ChangelogPopupModel(changelog: Changelog(sections: [])).isEmpty)
    }
}

/// The popup as built, and the corner label.
@Suite("changelog popup")
@MainActor
struct ChangelogPopupTests {
    static let log = Changelog.parse("""
        ## [Unreleased]
        ### Added
        - A long entry that goes on for long enough to wrap inside the popup's column, twice over, with a `code` span in it
        - B
        ### Fixed
        - C
        ## [0.6.1] - 2026-09-16
        ### Fixed
        - D
        """)

    @Test("draws every section, Unreleased open, and folds and opens on toggle")
    func sections() {
        let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: Self.log))
        #expect(popup.headerTexts == ["// UNRELEASED · 3", "// 0.6.1 · 2026-09-16"])
        #expect(popup.openSections == [0])
        #expect(popup.emptyText == nil)
        popup.toggle(1)
        #expect(popup.openSections == [0, 1])
        popup.toggle(0)
        #expect(popup.openSections == [1])
    }

    @Test("copy puts the section on the clipboard as markdown")
    func copy() {
        let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: Self.log))
        let before = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let before { NSPasteboard.general.setString(before, forType: .string) }
        }
        popup.copy(1)
        #expect(NSPasteboard.general.string(forType: .string) == "## [0.6.1] - 2026-09-16\n\n### Fixed\n- D\n")
    }

    @Test("with no changelog it says so in one line instead of opening empty")
    func empty() {
        let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: nil))
        #expect(popup.headerTexts.isEmpty)
        #expect(popup.emptyText == ChangelogPopupModel.emptyMessage)
    }

    @Test("the corner label is the version in grey and the +N in the accent")
    func cornerLabel() {
        let text = SidebarViewController.cornerText(.init(version: "v0.6.1", suffix: "+40"))
        #expect(text.string == "v0.6.1+40")
        var range = NSRange()
        #expect(text.attribute(.foregroundColor, at: 0, effectiveRange: &range) as? NSColor == Theme.dimText)
        #expect(range == NSRange(location: 0, length: 6))
        #expect(text.attribute(.foregroundColor, at: 6, effectiveRange: &range) as? NSColor == Theme.accent)
        #expect(range == NSRange(location: 6, length: 3))
        #expect(SidebarViewController.cornerText(.init(version: "v0.6.1", suffix: nil)).string == "v0.6.1")
    }

    /// The popup as a picture, in both appearances. Gated on `MAXPANE_SHOTS`.
    ///
    ///     ./scripts/test.sh shots /tmp/shots
    @Test("renders the popup")
    func renderSheet() throws {
        guard let dir = ProcessInfo.processInfo.environment["MAXPANE_SHOTS"] else { return }
        let text = try String(contentsOf: ChangelogTests.repoRoot.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        var open: [Popup] = []
        try AppearanceSheet.render(to: dir, named: "changelog-popup") {
            let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: Changelog.parse(text)))
            open.append(popup)
            let panel = try #require(popup.window)
            panel.setContentSize(ChangelogPopup.size)
            return try #require(panel.contentView)
        }
        try AppearanceSheet.render(to: dir, named: "changelog-popup-folded") {
            let popup = ChangelogPopup(model: ChangelogPopupModel(changelog: Changelog.parse(text)))
            popup.toggle(0)
            popup.toggle(1)
            open.append(popup)
            let panel = try #require(popup.window)
            panel.setContentSize(ChangelogPopup.size)
            return try #require(panel.contentView)
        }
        _ = open
    }
}
