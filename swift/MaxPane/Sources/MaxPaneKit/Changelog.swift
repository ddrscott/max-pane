import Foundation

/// `CHANGELOG.md`, read rather than restructured.
///
/// The version in the sidebar's corner used to be `CFBundleShortVersionString`
/// and nothing else, so a build from main with forty unreleased entries said
/// `v0.6.1`, the same as the release. The owner: *"the app version in the
/// corner never updates … keep that synced with the change log and add
/// `+$number` for number of unreleased features if we're running an unreleased
/// version."* The changelog is already the one curated list of what changed,
/// so it is read instead of duplicated: `build-app.sh` copies it into the
/// bundle, this parses it, and the corner counts it.
///
/// Keep a Changelog, as the file is written: `## [Unreleased]`, then
/// `## [0.6.1] - 2026-09-16` and so on, each with `### Added` / `### Changed` /
/// `### Fixed` groups of one-line `- ` entries, and the compare links at the
/// foot. Tolerant of a missing Unreleased section, of an empty category, of a
/// section with entries under no category, and of a continuation line — none
/// of which the file has today, all of which an edit could produce. Entries are
/// plain text with their backticks left in; nothing here renders markdown.
///
/// Pure: the text comes in, the sections come out, and `Bundle.main` is only
/// consulted by `bundled()`, so the parser is testable from a test runner whose
/// main bundle is not the app.
public struct Changelog: Equatable, Sendable {
    /// One `### Category` under a version, with its entries in file order.
    public struct Group: Equatable, Sendable {
        public let category: String
        public let entries: [String]

        public init(category: String, entries: [String]) {
            self.category = category
            self.entries = entries
        }
    }

    /// One `## [version]` heading and everything under it.
    public struct Section: Equatable, Sendable {
        /// `Unreleased`, or the version as written: `0.6.1`.
        public let version: String
        /// What followed the dash on the heading, if anything: `2026-09-16`.
        public let date: String?
        public let groups: [Group]

        public init(version: String, date: String?, groups: [Group]) {
            self.version = version
            self.date = date
            self.groups = groups
        }

        public var isUnreleased: Bool { version.caseInsensitiveCompare("Unreleased") == .orderedSame }

        /// Every entry under every category. A fix is a change the owner wants
        /// to know about as much as a feature, so nothing is left out.
        public var count: Int { groups.reduce(0) { $0 + $1.entries.count } }

        /// The section as Keep a Changelog markdown, for pasting into a release
        /// note. Its heading, then each category with its entries, one blank
        /// line between.
        public var markdown: String {
            var lines = ["## [\(version)]" + (date.map { " - \($0)" } ?? "")]
            for group in groups {
                lines.append("")
                if !group.category.isEmpty { lines.append("### \(group.category)") }
                lines.append(contentsOf: group.entries.map { "- \($0)" })
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }

    /// Newest first, as the file is written.
    public let sections: [Section]

    public init(sections: [Section]) { self.sections = sections }

    public var unreleased: Section? { sections.first(where: \.isUnreleased) }
    public var unreleasedCount: Int { unreleased?.count ?? 0 }
    /// The top released section: the version the corner shows, and what
    /// `release.sh` requires to match the plist.
    public var latestRelease: Section? { sections.first { !$0.isUnreleased } }

    // MARK: - parsing

    /// `## [Unreleased]`, `## [0.6.1] - 2026-09-16`, or `## 0.6.1 - 2026-09-16`
    /// without brackets: the brackets are the link style, not the meaning.
    private static let heading = try! NSRegularExpression(
        pattern: #"^##\s+\[?([^\]\s]+)\]?\s*(?:[-–—]\s*(\S.*?))?\s*$"#)
    private static let category = try! NSRegularExpression(pattern: #"^###\s+(\S.*?)\s*$"#)
    private static let entry = try! NSRegularExpression(pattern: #"^[-*+]\s+(\S.*?)\s*$"#)

    public static func parse(_ text: String) -> Changelog {
        var sections: [Section] = []
        var version: String?
        var date: String?
        var groups: [Group] = []
        var categoryName = ""
        var entries: [String] = []

        func closeGroup() {
            if !entries.isEmpty || !categoryName.isEmpty { groups.append(Group(category: categoryName, entries: entries)) }
            entries = []
        }
        func closeSection() {
            closeGroup()
            if let version { sections.append(Section(version: version, date: date, groups: groups)) }
            version = nil
            date = nil
            groups = []
            categoryName = ""
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let range = NSRange(line.startIndex..., in: line)
            if let m = heading.firstMatch(in: line, range: range) {
                closeSection()
                version = String(line[Range(m.range(at: 1), in: line)!])
                date = Range(m.range(at: 2), in: line).map { String(line[$0]) }
                continue
            }
            guard version != nil else { continue }
            if let m = category.firstMatch(in: line, range: range) {
                closeGroup()
                categoryName = String(line[Range(m.range(at: 1), in: line)!])
                continue
            }
            if let m = entry.firstMatch(in: line, range: range) {
                entries.append(String(line[Range(m.range(at: 1), in: line)!]))
                continue
            }
            // An indented continuation of the entry above, which a wrapped
            // edit could produce: joined with a space, so it stays one entry.
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !entries.isEmpty, !trimmed.isEmpty, line.first?.isWhitespace == true {
                entries[entries.count - 1] += " " + trimmed
            }
        }
        closeSection()
        return Changelog(sections: sections)
    }

    /// The copy `build-app.sh` put in `Contents/Resources`, or nil for a
    /// `swift run` from the package, which has no bundle to carry one.
    @MainActor
    public static func bundled() -> Changelog? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }
}

/// What the bundle was built from, as `build-app.sh` stamped it into
/// `Info.plist`: the `MaxPaneBuild*` keys beside the hand-set version.
///
/// The version is the release number and stays hand-set (`release.sh` reads it
/// for the tag and the DMG); the rest is written by the build script into the
/// copied plist only, so the checked-in file never changes.
public struct BuildInfo: Equatable, Sendable {
    public static let versionKey = "CFBundleShortVersionString"
    public static let commitKey = "MaxPaneBuildCommit"
    public static let dateKey = "MaxPaneBuildDate"
    public static let dirtyKey = "MaxPaneBuildDirty"
    public static let tagKey = "MaxPaneBuildTag"

    public let version: String
    /// The short commit, or nil for a build with no stamp.
    public let commit: String?
    /// `YYYY-MM-DD`, UTC, or nil for a build with no stamp.
    public let date: String?
    public let dirty: Bool
    /// The tag exactly at the built commit — `v0.6.1` — or nil when there was
    /// none: what makes a build "the release" even before the changelog's
    /// Unreleased section is emptied.
    public let tag: String?

    public init(version: String, commit: String? = nil, date: String? = nil, dirty: Bool = false, tag: String? = nil) {
        self.version = version
        self.commit = commit
        self.date = date
        self.dirty = dirty
        self.tag = tag
    }

    /// From a plist's dictionary. `PlistBuddy` writes a bool as a bool; a
    /// hand edit might write `YES`, so both are read.
    public init(info: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let s = info[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        let dirty: Bool
        if let b = info[Self.dirtyKey] as? Bool { dirty = b }
        else if let s = string(Self.dirtyKey) { dirty = ["yes", "true", "1"].contains(s.lowercased()) }
        else { dirty = false }
        self.init(
            version: string(Self.versionKey) ?? "0.1.0",
            commit: string(Self.commitKey), date: string(Self.dateKey), dirty: dirty, tag: string(Self.tagKey))
    }

    @MainActor
    public static var current: BuildInfo { BuildInfo(info: Bundle.main.infoDictionary ?? [:]) }
}

/// The version in the sidebar's corner: `v0.6.1` on a release, `v0.6.1+40` on
/// a build with forty unreleased entries, and a tooltip that says the rest.
public enum VersionCorner {
    public struct Text: Equatable, Sendable {
        /// `v0.6.1`, in the footer's grey.
        public let version: String
        /// `+40`, in the accent, or nil on a release build.
        public let suffix: String?
        public var plain: String { version + (suffix ?? "") }
    }

    /// A release build is one whose Unreleased section is empty, or one built
    /// exactly at the tag `v<version>` — the tag is the release, whatever the
    /// changelog looked like at that commit. A dirty tree changes nothing
    /// here: it is in the tooltip.
    public static func text(build: BuildInfo, unreleased: Int) -> Text {
        let version = "v" + build.version
        guard unreleased > 0, build.tag != version else { return Text(version: version, suffix: nil) }
        return Text(version: version, suffix: "+\(unreleased)")
    }

    /// `0.6.1 · 40 unreleased changes · built 2026-09-22 from a8e73d6 (dirty)`.
    public static func tooltip(build: BuildInfo, unreleased: Int) -> String {
        var parts = [build.version]
        let text = text(build: build, unreleased: unreleased)
        if text.suffix != nil {
            parts.append(unreleased == 1 ? "1 unreleased change" : "\(unreleased) unreleased changes")
        } else {
            parts.append("release build")
        }
        if let commit = build.commit {
            var built = "built"
            if let date = build.date { built += " \(date)" }
            built += " from \(commit)"
            if build.dirty { built += " (dirty)" }
            parts.append(built)
        } else {
            parts.append("not a bundled build")
        }
        return parts.joined(separator: " · ")
    }
}

/// What the changelog popup shows, and in what state: the changelog newest
/// first, Unreleased open, every released version folded behind its count.
/// The view reads this; the fold and the copy text are decided here so they
/// can be tested without a window.
public struct ChangelogPopupModel: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let section: Changelog.Section
        public var isFolded: Bool

        /// `UNRELEASED · 40` or `0.6.1 · 2026-09-16`: what follows the `// `.
        public var header: String {
            if section.isUnreleased { return "UNRELEASED · \(section.count)" }
            return section.date.map { "\(section.version) · \($0)" } ?? section.version
        }

        /// Shown beside a folded header, so the fold says what it hides.
        public var foldedCount: String {
            section.count == 1 ? "1 change" : "\(section.count) changes"
        }

        /// What `copy` on the header puts on the clipboard: the section as
        /// markdown, for a release note.
        public var copyText: String { section.markdown }
    }

    public private(set) var items: [Item]

    public init(changelog: Changelog?) {
        items = (changelog?.sections ?? []).map { Item(section: $0, isFolded: !$0.isUnreleased) }
    }

    /// No changelog in the bundle, or one with no sections: the popup says so
    /// in a line rather than opening empty.
    public var isEmpty: Bool { items.isEmpty }
    public static let emptyMessage = "No changelog in this build. A built app carries CHANGELOG.md; a `swift run` does not."

    public mutating func toggle(_ index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].isFolded.toggle()
    }
}
