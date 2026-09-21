import AppKit

/// Copy mode's keys, as a state machine with no terminal in it (ADR-0033).
///
/// ⇧⌘C puts a keyboard cursor on the terminal; this decides where each key
/// takes it. Rows are **absolute**: row 0 is the oldest line of scrollback
/// and `offset` is the row at the top of the viewport, which is how the
/// emulator's scrollbar counts them, so a selection that starts on one screen
/// and ends on another is two ordinary cells. What carries a state onto a
/// real surface is `CopyModeDriver`; nothing here
/// knows a surface exists, and every key is answered here before anything
/// could be sent anywhere, which is why none reaches the pty.
struct CopyMode: Equatable {
    struct Cell: Equatable {
        var column: Int
        var row: Int
    }

    enum Selecting: Equatable {
        /// `v`: from this cell to the cursor.
        case characters(Cell)
        /// `V`: whole lines, from this row to the cursor's.
        case lines(Int)
    }

    /// A key, already reduced from an `NSEvent` (`CopyMode.key(for:)`).
    enum Key: Equatable {
        case character(Character)
        /// ⌃ and a letter, lowercased.
        case control(Character)
        case escape, enter, backspace
        case up, down, left, right, pageUp, pageDown, home, end
    }

    enum Effect: Equatable {
        /// Copy what is selected.
        case copy
        /// Leave copy mode.
        case leave
        /// `/needle↩`: search for it, towards older text.
        case find(String)
        /// `n` and `N`: the match before, or after.
        case findAgain(older: Bool)
    }

    /// The viewport's grid.
    let columns: Int
    let rows: Int
    /// Every row there is, scrollback and screen.
    let total: Int
    /// The row at the top of the viewport.
    private(set) var offset: Int
    private(set) var cursor: Cell
    private(set) var selecting: Selecting?
    /// What is being typed after `/`, or nil when no search is being typed.
    private(set) var needle: String?
    /// The last thing searched for.
    private(set) var found: String?

    init(columns: Int, rows: Int, total: Int, offset: Int, cursor: Cell) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.total = max(self.rows, total)
        self.offset = min(max(0, offset), self.total - self.rows)
        self.cursor = cursor
        clamp()
        reveal()
    }

    /// The cursor's row in the viewport.
    var viewportRow: Int { cursor.row - offset }

    /// The selection as a drag: where the button goes down and where it comes
    /// up. Line-wise is a drag from one margin to the other.
    var drag: (from: Cell, to: Cell)? {
        switch selecting {
        case nil:
            return nil
        case .characters(let anchor):
            return (anchor, cursor)
        case .lines(let row):
            return cursor.row >= row
                ? (Cell(column: 0, row: row), Cell(column: columns - 1, row: cursor.row))
                : (Cell(column: columns - 1, row: row), Cell(column: 0, row: cursor.row))
        }
    }

    /// One line for the pane's notice: the mode, or the search being typed.
    var status: String {
        if let needle { return "/\(needle)" }
        switch selecting {
        case nil: return "copy mode · v V select · y copy · / find · Esc leaves"
        case .characters: return "copy mode · selecting · y copies · Esc leaves"
        case .lines: return "copy mode · selecting lines · y copies · Esc leaves"
        }
    }

    /// Answer a key. `text` is the text of an absolute row when the row is on
    /// screen, and nil when it is not: only `w`, `b`, `^` and `$` read it.
    mutating func press(_ key: Key, text: (Int) -> String? = { _ in nil }) -> [Effect] {
        if needle != nil { return type(key) }
        switch key {
        case .escape, .character("q"):
            return [.leave]
        case .enter, .character("y"):
            return selecting == nil ? [] : [.copy, .leave]

        case .character("h"), .left: cursor.column -= 1
        case .character("l"), .right: cursor.column += 1
        case .character("j"), .down: cursor.row += 1
        case .character("k"), .up: cursor.row -= 1
        case .character("0"): cursor.column = 0
        case .character("^"): cursor.column = Self.firstWord(in: text(cursor.row) ?? "") ?? 0
        case .character("$"):
            cursor.column = text(cursor.row).map { max(0, Self.width(of: $0) - 1) } ?? columns - 1
        case .character("w"): forwardWord(text)
        case .character("b"): backWord(text)
        case .character("g"), .home: cursor = Cell(column: 0, row: 0)
        case .character("G"), .end: cursor = Cell(column: 0, row: total - 1)
        case .control("u"): page(-max(1, rows / 2))
        case .control("d"): page(max(1, rows / 2))
        case .control("b"), .pageUp: page(-rows)
        case .control("f"), .pageDown: page(rows)

        case .character("v"):
            if case .characters = selecting { selecting = nil } else { selecting = .characters(cursor) }
        case .character("V"):
            if case .lines = selecting { selecting = nil } else { selecting = .lines(cursor.row) }

        case .character("/"):
            needle = ""
        case .character("n"):
            return found == nil ? [] : [.findAgain(older: true)]
        case .character("N"):
            return found == nil ? [] : [.findAgain(older: false)]
        default:
            // Swallowed like the rest. Copy mode has no key that types.
            break
        }
        clamp()
        reveal()
        return []
    }

    /// The viewport moved without a key: a search landed, or the wheel turned.
    /// The cursor goes to `cell` when there is one, and otherwise stays on its
    /// row if that is still on screen, or comes to the nearest edge.
    mutating func moved(toOffset newOffset: Int, cursor cell: Cell? = nil) {
        offset = min(max(0, newOffset), total - rows)
        if let cell { cursor = cell }
        clamp()
        cursor.row = min(max(cursor.row, offset), offset + rows - 1)
    }

    // MARK: - the search line

    private mutating func type(_ key: Key) -> [Effect] {
        switch key {
        case .escape:
            needle = nil
        case .backspace:
            if needle?.isEmpty == false { needle?.removeLast() } else { needle = nil }
        case .enter:
            let typed = needle ?? ""
            needle = nil
            guard !typed.isEmpty else { return [] }
            found = typed
            return [.find(typed)]
        case .character(let c):
            needle?.append(c)
        default:
            break
        }
        return []
    }

    // MARK: - movement

    private mutating func page(_ delta: Int) {
        // The view moves with the cursor, so the cursor keeps its place on
        // screen, as ⌃U and ⌃D do in vi.
        let before = offset
        offset = min(max(0, offset + delta), total - rows)
        cursor.row += (offset == before) ? delta : offset - before
    }

    private mutating func clamp() {
        cursor.row = min(max(0, cursor.row), total - 1)
        cursor.column = min(max(0, cursor.column), columns - 1)
    }

    private mutating func reveal() {
        if cursor.row < offset { offset = cursor.row }
        if cursor.row >= offset + rows { offset = cursor.row - rows + 1 }
    }

    /// Words are what whitespace separates: a path, a hash and a URL are each
    /// one word, which is what is being copied out of a terminal.
    private mutating func forwardWord(_ text: (Int) -> String?) {
        let line = Array(text(cursor.row) ?? "")
        var i = cursor.column
        while i < line.count, !line[i].isWhitespace { i += 1 }
        while i < line.count, line[i].isWhitespace { i += 1 }
        if i < line.count {
            cursor.column = i
        } else if cursor.row < total - 1 {
            cursor.row += 1
            cursor.column = Self.firstWord(in: text(cursor.row) ?? "") ?? 0
        }
    }

    private mutating func backWord(_ text: (Int) -> String?) {
        let line = Array(text(cursor.row) ?? "")
        var i = min(cursor.column, line.count) - 1
        while i >= 0, line[i].isWhitespace { i -= 1 }
        while i > 0, !line[i - 1].isWhitespace { i -= 1 }
        if i >= 0, i < cursor.column {
            cursor.column = i
        } else if cursor.row > 0 {
            cursor.row -= 1
            let above = Array(text(cursor.row) ?? "")
            var j = above.count - 1
            while j >= 0, above[j].isWhitespace { j -= 1 }
            while j > 0, !above[j - 1].isWhitespace { j -= 1 }
            cursor.column = max(0, j)
        }
    }

    private static func firstWord(in line: String) -> Int? {
        Array(line).firstIndex { !$0.isWhitespace }
    }

    /// The line's length with trailing blanks left off.
    private static func width(of line: String) -> Int {
        var chars = Array(line)
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        return chars.count
    }

    // MARK: - keys

    /// Reduce a key event. nil for a chord with ⌘ in it: those are commands,
    /// the menu's, and copy mode leaves them alone.
    static func key(for event: NSEvent) -> Key? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil }
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 126: return .up
        case 125: return .down
        case 123: return .left
        case 124: return .right
        case 116: return .pageUp
        case 121: return .pageDown
        case 115: return .home
        case 119: return .end
        default: break
        }
        if flags.contains(.control) {
            guard let c = event.charactersIgnoringModifiers?.lowercased().first else { return .character("\0") }
            // Some layouts report the control character itself: ⌃U as 0x15.
            if let ascii = c.asciiValue, ascii < 0x20 { return .control(Character(UnicodeScalar(ascii + 0x60))) }
            return .control(c)
        }
        guard let c = event.characters?.first else { return .character("\0") }
        return .character(c)
    }

    /// Where a search landed: the occurrence of `needle` nearest to `cursor`
    /// among the viewport's `lines`, as a viewport cell. Case is ignored, as
    /// the emulator's search ignores it.
    static func nearest(_ needle: String, in lines: [String], to cursor: (column: Int, row: Int)) -> (column: Int, row: Int)? {
        let want = Array(needle.lowercased())
        guard !want.isEmpty else { return nil }
        var best: (column: Int, row: Int)?
        var bestDistance = Int.max
        for (row, line) in lines.enumerated() {
            let chars = Array(line.lowercased())
            guard chars.count >= want.count else { continue }
            for column in 0...(chars.count - want.count) where Array(chars[column..<column + want.count]) == want {
                let distance = abs(row - cursor.row) * 10_000 + abs(column - cursor.column)
                if distance < bestDistance {
                    bestDistance = distance
                    best = (column, row)
                }
            }
        }
        return best
    }
}
