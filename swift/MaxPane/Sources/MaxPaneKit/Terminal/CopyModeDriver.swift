import AppKit
import GhosttyKit
import GhosttyTerminal

/// Carries a `CopyMode` onto a real surface (ADR-0033).
///
/// libghostty has no call that sets a selection, and none that says where the
/// cursor or a search match is. What it does have, in public, is enough to
/// build one honestly:
///
/// - **The viewport moves by absolute row** (`scroll_to_row:N`), and
///   `TerminalSurfaceScrollbarDelegate` reports the row it landed on. The
///   move is asynchronous (it is a message to the emulator's own thread), so
///   nothing here acts on a scroll until the scrollbar has confirmed it.
/// - **A selection is a drag**, and a drag is three public calls
///   (`sendMousePos`, `sendMouseButton` down and up). The emulator pins the
///   press to the *text*, not the screen, so pressing, scrolling, and then
///   moving selects across more than a screenful. ⇧ is held for all of it,
///   which is the emulator's own "this click is mine, not the program's":
///   nothing is reported to a program that asked for the mouse.
/// - A press that lands where the last one did is a double click, and a
///   double click selects a word. So each drag is preceded by a click far
///   from it, which also clears whatever was selected.
///
/// The cursor is this class's: an outline drawn over the cell.
@MainActor
final class CopyModeDriver {
    private let terminal: ClickableTerminalView
    private let surface: () -> TerminalSurface?
    private let viewportText: () -> String?
    private let padding: CGPoint

    /// The cell size as the emulator measured it, in pixels. Nil until the
    /// library has said; the grid is divided up by hand until then.
    var metrics: TerminalGridMetrics?
    /// The last scrollbar the emulator reported.
    private(set) var scrollbar: TerminalScrollbar?

    private(set) var mode: CopyMode?
    var isOn: Bool { mode != nil }

    /// Copy mode came on, went off, or has something new to say.
    var onChange: (() -> Void)?
    /// `y`: copy what is selected. The pane's, since it owns the pasteboard.
    var onCopy: (() -> Void)?
    var onNotice: ((String) -> Void)?

    private let cursorView = CopyModeCursorView()
    private var queue: [CopyMode.Key] = []
    private var busy = false
    /// The row the viewport is known to be at.
    private var shownOffset = 0
    private var appliedDrag: (from: CopyMode.Cell, to: CopyMode.Cell)?
    private var waiting: (id: Int, offset: Int?, resume: CheckedContinuation<Void, Never>)?
    private var waits = 0
    private var said = false

    private func say(_ text: String) {
        said = true
        onNotice?(text)
    }

    /// How long a scroll is given to be confirmed before it is taken as done.
    static let settleSeconds: TimeInterval = 0.25
    /// How long the emulator's search thread is given to find its matches.
    static let searchSeconds: TimeInterval = 0.2

    init(
        terminal: ClickableTerminalView, surface: @escaping () -> TerminalSurface?,
        viewportText: @escaping () -> String?, padding: CGPoint
    ) {
        self.terminal = terminal
        self.surface = surface
        self.viewportText = viewportText
        self.padding = padding
    }

    // MARK: - on and off

    /// Turn copy mode on. False with no surface or no grid to put a cursor on.
    @discardableResult
    func enter(columns: Int, rows: Int) -> Bool {
        guard mode == nil, surface() != nil, columns > 0, rows > 0 else { return false }
        let total = scrollbar.map { Int($0.total) } ?? rows
        let offset = scrollbar.map { Int($0.offset) } ?? 0
        // The last line with anything on it is where the prompt is, nearly
        // always, and the emulator does not say where its own cursor is.
        let lines = viewportLines()
        let row = lines.lastIndex { !$0.allSatisfy(\.isWhitespace) } ?? 0
        mode = CopyMode(
            columns: columns, rows: rows, total: total, offset: offset,
            cursor: .init(column: 0, row: offset + row))
        shownOffset = mode?.offset ?? 0
        appliedDrag = nil
        queue.removeAll()
        terminal.addSubview(cursorView)
        placeCursor()
        Motion.fade(cursorView.layer)
        onChange?()
        return true
    }

    /// Turn it off: the search and the selection go, and the viewport returns
    /// to the bottom, where output is about to arrive.
    func leave() {
        guard mode != nil else { return }
        queue.removeAll()
        release()
        if let surface = surface() {
            _ = surface.performBindingAction("end_search")
            if appliedDrag != nil { clearSelection(on: surface) }
            _ = surface.performBindingAction("scroll_to_bottom")
        }
        mode = nil
        appliedDrag = nil
        if let waiting {
            self.waiting = nil
            waiting.resume.resume()
        }
        cursorView.removeFromSuperview()
        onChange?()
    }

    // MARK: - keys

    /// A key while copy mode is on. Always swallowed; a ⌘-chord that got this
    /// far was not a command, and is not the program's either.
    func key(_ event: NSEvent) {
        guard mode != nil, let key = CopyMode.key(for: event) else { return }
        queue.append(key)
        drain()
    }

    /// Keys are answered one at a time and in order, each only once the one
    /// before it is on screen: a key is read against the text in view.
    private func drain() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            while mode != nil, !queue.isEmpty {
                let key = queue.removeFirst()
                let lines = viewportLines()
                let base = shownOffset
                let before = mode?.status
                said = false
                let effects = mode?.press(key) { row in
                    lines.indices.contains(row - base) ? lines[row - base] : nil
                } ?? []
                await apply()
                for effect in effects { await perform(effect) }
                // Unless something was just said in that line: "not found"
                // outranks the reminder it would be replaced by.
                if mode != nil, mode?.status != before, !said { onChange?() }
            }
            busy = false
        }
    }

    private func perform(_ effect: CopyMode.Effect) async {
        guard let surface = surface() else { return }
        switch effect {
        case .copy:
            onCopy?()
        case .leave:
            leave()
        case .find(let needle):
            _ = surface.performBindingAction("end_search")
            guard surface.performBindingAction("search:\(needle)") else {
                say("find: the emulator would not search")
                return
            }
            // Its matches are found on a thread of its own, and nothing says
            // when it is done.
            await pause(Self.searchSeconds)
            await landOnMatch(after: "navigate_search:next", needle: needle)
        case .findAgain(let older):
            guard let needle = mode?.found else { return }
            await landOnMatch(after: older ? "navigate_search:next" : "navigate_search:previous", needle: needle)
        }
    }

    /// Step the emulator's search, wait for the viewport it chose, and put
    /// the cursor on the occurrence in view nearest to where it was. Nearest,
    /// because the library does not pass on which match the emulator selected
    /// (`GHOSTTY_ACTION_SEARCH_SELECTED` stops at `TerminalCallbackBridge`).
    private func landOnMatch(after action: String, needle: String) async {
        guard let surface = surface(), var mode else { return }
        _ = surface.performBindingAction(action)
        await settle(on: nil)
        let offset = scrollbar.map { Int($0.offset) } ?? shownOffset
        let from = (column: mode.cursor.column, row: mode.cursor.row - offset)
        guard let hit = CopyMode.nearest(needle, in: viewportLines(), to: from) else {
            say("not found: \(needle)")
            mode.moved(toOffset: offset)
            self.mode = mode
            shownOffset = mode.offset
            await apply()
            return
        }
        mode.moved(toOffset: offset, cursor: .init(column: hit.column, row: offset + hit.row))
        self.mode = mode
        shownOffset = mode.offset
        await apply()
    }

    // MARK: - the surface

    /// Make the surface show `mode`: the viewport first, then the selection,
    /// then the cursor.
    private func apply() async {
        guard let mode, let surface = surface() else { return }
        let drag = mode.drag
        let changed = !same(drag, appliedDrag)
        if changed, let drag {
            await select(drag, showing: mode.offset, on: surface)
        } else {
            await scroll(to: mode.offset, on: surface)
            if changed { clearSelection(on: surface) }
        }
        appliedDrag = drag
        placeCursor()
    }

    private func select(
        _ drag: (from: CopyMode.Cell, to: CopyMode.Cell), showing offset: Int, on surface: TerminalSurface
    ) async {
        guard let mode else { return }
        // The button has to go down on the anchor, so the anchor has to be on
        // screen for that one moment, wherever the cursor has got to.
        var pressOffset = offset
        if drag.from.row < offset { pressOffset = drag.from.row }
        if drag.from.row >= offset + mode.rows { pressOffset = drag.from.row - mode.rows + 1 }
        await scroll(to: pressOffset, on: surface)
        guard self.mode != nil else { return }

        let forward = (drag.to.row, drag.to.column) >= (drag.from.row, drag.from.column)
        clearSelection(on: surface, awayFrom: (drag.from.column, drag.from.row - pressOffset))
        move(to: drag.from.column, drag.from.row - pressOffset, edge: forward ? 0.05 : 0.95, on: surface)
        surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: Self.held)
        isPressed = true
        await scroll(to: offset, on: surface)
        // Left while the viewport was on its way: `leave` let the button go.
        guard self.mode != nil else { return }
        move(to: drag.to.column, drag.to.row - offset, edge: forward ? 0.95 : 0.05, on: surface)
        release()
    }

    private static let held: TerminalInputModifiers = [.shift]
    private var isPressed = false

    private func release() {
        guard isPressed else { return }
        isPressed = false
        surface()?.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: Self.held)
    }

    /// A click with nothing dragged: it clears the selection, and being far
    /// from `cell` it makes the press that follows a first click, not a second.
    private func clearSelection(on surface: TerminalSurface, awayFrom cell: (column: Int, row: Int)? = nil) {
        guard let mode else { return }
        let cell = cell ?? (mode.cursor.column, mode.viewportRow)
        click(
            column: cell.column >= mode.columns / 2 ? 0 : mode.columns - 1,
            row: cell.row >= mode.rows / 2 ? 0 : mode.rows - 1, on: surface)
    }

    private func click(column: Int, row: Int, on surface: TerminalSurface) {
        move(to: column, row, edge: 0.5, on: surface)
        surface.sendMouseButton(state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT, modifiers: Self.held)
        surface.sendMouseButton(state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT, modifiers: Self.held)
    }

    private func move(to column: Int, _ row: Int, edge: Double, on surface: TerminalSurface) {
        let cell = cellSize
        surface.sendMousePos(
            x: Double(padding.x) + (Double(column) + edge) * Double(cell.width),
            y: Double(padding.y) + (Double(row) + 0.5) * Double(cell.height),
            modifiers: Self.held)
    }

    // MARK: - scrolling, and waiting for it

    private func scroll(to offset: Int, on surface: TerminalSurface) async {
        guard offset != shownOffset else { return }
        _ = surface.performBindingAction("scroll_to_row:\(offset)")
        await settle(on: offset)
        shownOffset = offset
    }

    /// Wait for the scrollbar to report `offset` (or, with nil, to report
    /// anything), and no longer than `settleSeconds`.
    private func settle(on offset: Int?) async {
        waits += 1
        let id = waits
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiting = (id, offset, continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleSeconds) { [weak self] in
                guard let self, let waiting = self.waiting, waiting.id == id else { return }
                self.waiting = nil
                waiting.resume.resume()
            }
        }
    }

    private func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The emulator reported its scrollbar. Called by the pane for every
    /// report, in copy mode or not: entering needs the last one.
    func scrolled(_ bar: TerminalScrollbar) {
        scrollbar = bar
        if let waiting, waiting.offset == nil || waiting.offset == Int(bar.offset) {
            self.waiting = nil
            waiting.resume.resume()
            return
        }
        // The wheel, in copy mode: the cursor stays on screen.
        guard var mode, !busy, waiting == nil, Int(bar.offset) != shownOffset else { return }
        mode.moved(toOffset: Int(bar.offset))
        self.mode = mode
        shownOffset = mode.offset
        placeCursor()
    }

    // MARK: - geometry

    private func viewportLines() -> [String] {
        (viewportText() ?? "").components(separatedBy: "\n")
    }

    /// A cell, in points. The emulator's own measure when it has given one;
    /// otherwise the text area divided by the grid, which overstates a cell
    /// by a rounding remainder (`ClickableTerminalView.cell(at:)`).
    private var cellSize: CGSize {
        let scale = terminal.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        if let metrics, metrics.cellWidthPixels > 0, metrics.cellHeightPixels > 0 {
            return CGSize(
                width: CGFloat(metrics.cellWidthPixels) / scale, height: CGFloat(metrics.cellHeightPixels) / scale)
        }
        guard let mode else { return CGSize(width: 8, height: 17) }
        return CGSize(
            width: (terminal.bounds.width - padding.x * 2) / CGFloat(mode.columns),
            height: (terminal.bounds.height - padding.y * 2) / CGFloat(mode.rows))
    }

    private func placeCursor() {
        guard let mode else { return }
        let cell = cellSize
        let top = padding.y + CGFloat(mode.viewportRow) * cell.height
        cursorView.frame = CGRect(
            x: padding.x + CGFloat(mode.cursor.column) * cell.width,
            y: terminal.isFlipped ? top : terminal.bounds.height - top - cell.height,
            width: cell.width, height: cell.height)
    }

    /// The cursor's cell in the viewport: what a test looks at.
    var cursorCell: (column: Int, row: Int)? { mode.map { ($0.cursor.column, $0.viewportRow) } }
    /// True while keys are still being answered: what a test waits on.
    var isBusy: Bool { busy || !queue.isEmpty }

    private func same(
        _ a: (from: CopyMode.Cell, to: CopyMode.Cell)?, _ b: (from: CopyMode.Cell, to: CopyMode.Cell)?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return a.from == b.from && a.to == b.to
        default: return false
        }
    }
}

/// Copy mode's cursor: an outline around one cell, in the accent green, with
/// a wash of it inside so it reads over a selection as well as over text.
/// Square, and never the mouse's.
final class CopyModeCursorView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 1.5
        // Appearance-aware, by `Appearance.swift`'s rule: never a CGColor by hand.
        layerBorderColor = Theme.accent
        layerBackgroundColor = Theme.accent.withAlphaComponent(0.28)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not a nib") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
