import Testing
import AppKit
@testable import MaxPaneKit

/// Turning a ⌘-click into a grid cell.
///
/// The way this goes quietly wrong is the y axis: AppKit measures from the
/// bottom and the grid counts rows from the top, so a version that forgets to
/// flip still returns a plausible row for every click and opens the wrong
/// file, most obviously never the one under the pointer.
@Suite("terminal click geometry")
@MainActor
struct ClickableTerminalViewTests {
    /// An 80x24 grid with 6/4pt padding: cells land on exactly 8 x 17pt.
    private let padding = CGPoint(x: 6, y: 4)
    private let size = CGSize(width: 652, height: 416)

    private func cell(_ x: CGFloat, _ y: CGFloat) -> (row: Int, column: Int)? {
        ClickableTerminalView.cell(
            at: CGPoint(x: x, y: y),
            columns: 80, rows: 24,
            viewSize: size, padding: padding)
    }

    @Test("the top-left cell is the first character, not the last row")
    func originIsTopLeft() {
        // y = 412 is 4pt below the top edge: the first text row.
        let hit = cell(7, 412)
        #expect(hit?.row == 0)
        #expect(hit?.column == 0)
    }

    @Test("a click halfway down lands halfway down the grid")
    func rowsCountFromTheTop() {
        // Row 12 starts 4 + 12*17 = 208pt from the top.
        #expect(cell(7, 416 - 208 - 8)?.row == 12)
        #expect(cell(7, 416 - 208 - 8)?.column == 0)
    }

    @Test("columns step one cell at a time")
    func columnsCountFromTheLeft() {
        #expect(cell(6 + 10 * 8 + 2, 412)?.column == 10)
        #expect(cell(6 + 79 * 8 + 2, 412)?.column == 79)
    }

    @Test("a click in the padding is not a cell")
    func paddingIsNotTheGrid() {
        #expect(cell(2, 412) == nil)     // left gutter
        #expect(cell(7, 415) == nil)     // above the first row
        #expect(cell(650, 412) == nil)   // right gutter
        #expect(cell(7, 2) == nil)       // below the last row
    }

    @Test("a grid Ghostty has not measured yet yields nothing")
    func emptyGridIsRejected() {
        #expect(ClickableTerminalView.cell(
            at: CGPoint(x: 10, y: 10), columns: 0, rows: 0,
            viewSize: size, padding: padding) == nil)
    }

    @Test("a view smaller than its own padding yields nothing")
    func degenerateViewIsRejected() {
        // A pane mid-collapse: the padding alone is wider than the view.
        #expect(ClickableTerminalView.cell(
            at: .zero, columns: 80, rows: 24,
            viewSize: CGSize(width: 4, height: 4), padding: padding) == nil)
    }
}
