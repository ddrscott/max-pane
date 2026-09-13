import AppKit
import LanedCore

/// What an evicted web pane looks like (PRD §10.3): the snapshot, dimmed, with a
/// kind glyph.
///
/// Two failure modes are ordinary rather than exceptional, and both must look
/// deliberate. The snapshot file can be missing — a cleared cache, a restored
/// backup, a crash between the write and the commit ([ADR-0006](../../../docs/decisions/0006-placeholder-snapshots.md)).
/// And a lane can be evicted before it ever painted, so there was never a
/// snapshot to take. In both cases this draws a plain dimmed panel with the URL,
/// never an error and never a blank rectangle.
@MainActor
final class PlaceholderView: NSView {
    private let imageView = NSImageView()
    private let dim = NSView()
    private let glyph = NSTextField(labelWithString: Theme.glyph(for: .placeholder))
    private let caption = NSTextField(labelWithString: "")

    init(pane: Pane) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.laneBackground.cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        // The snapshot was taken at the lane's width; pin it to the top so the
        // fold lines up with where the page actually was.
        imageView.imageAlignment = .alignTop
        imageView.translatesAutoresizingMaskIntoConstraints = false

        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        dim.translatesAutoresizingMaskIntoConstraints = false

        glyph.font = Theme.mono(22)
        glyph.textColor = Theme.dimText
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        caption.font = Theme.mono(10)
        caption.textColor = Theme.dimText
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingMiddle
        caption.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(dim)
        addSubview(glyph)
        addSubview(caption)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            dim.topAnchor.constraint(equalTo: topAnchor),
            dim.leadingAnchor.constraint(equalTo: leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: trailingAnchor),
            dim.bottomAnchor.constraint(equalTo: bottomAnchor),

            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),

            caption.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])

        apply(pane)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    func apply(_ pane: Pane) {
        caption.stringValue = pane.url.flatMap { URL(string: $0)?.host } ?? pane.url ?? ""

        guard let path = pane.snapshotPath,
              FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path)
        else {
            // No snapshot, by accident or because there never was one. A dimmed
            // panel with the host is still a recognisable lane.
            imageView.image = nil
            dim.layer?.backgroundColor = Theme.stripBackground.cgColor
            return
        }
        imageView.image = image
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
    }
}

/// Where a pane's snapshot lives, and the housekeeping that keeps the directory
/// from growing without bound.
enum SnapshotStore {
    static var directory: URL { Profile.current.snapshotsDirectory }

    static func path(for paneId: String) -> String {
        directory.appendingPathComponent("\(paneId).jpg").path
    }

    /// Encode and write a snapshot. JPEG at quality 0.6, per ADR-0006 — 1.19 ms
    /// against HEIC's 25.9 ms, which matters because eviction runs exactly when
    /// the machine is already short of memory.
    ///
    /// Call this off the main thread: `takeSnapshot` hands back its image on the
    /// main queue, and encoding a batch of evictions there would be felt.
    static func write(_ image: NSImage, for paneId: String) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return nil }
        let path = path(for: paneId)
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            // A failed snapshot is not a failed eviction. The pane still goes;
            // it just comes back as a dimmed panel instead of a picture.
            return nil
        }
    }

    static func remove(for paneId: String) {
        try? FileManager.default.removeItem(atPath: path(for: paneId))
    }

    /// Delete snapshots with no matching pane. Run at launch: panes disappear in
    /// ways that do not always get to run cleanup, `kill -9` being the obvious one.
    static func sweep(keeping liveePaneIds: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") {
            let id = String(name.dropLast(4))
            guard !liveePaneIds.contains(id) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
