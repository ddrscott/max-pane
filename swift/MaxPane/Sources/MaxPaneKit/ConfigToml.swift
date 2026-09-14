import Foundation

/// One value of the kinds `config.toml` holds.
public enum TomlValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
    case array([TomlValue])

    /// The value as TOML writes it. A string is always a basic (double-quoted)
    /// string, so there is one escaping rule to get right rather than two.
    public var toml: String {
        switch self {
        case .string(let s): return TomlDocument.quoted(s)
        case .integer(let n): return String(n)
        case .float(let d):
            if d.isNaN { return "nan" }
            if d.isInfinite { return d < 0 ? "-inf" : "inf" }
            // `10.0`, not `10`: an integer is a different TOML type, and a
            // float key written as one would read back as a type change.
            return d == d.rounded() && abs(d) < 1e15 ? String(format: "%.1f", d) : "\(d)"
        case .bool(let b): return b ? "true" : "false"
        case .array(let items): return "[" + items.map(\.toml).joined(separator: ", ") + "]"
        }
    }

    /// What it is, for a sentence: "expected a whole number, got a string".
    var kind: String {
        switch self {
        case .string: return "a string"
        case .integer: return "a whole number"
        case .float: return "a number with a fraction"
        case .bool: return "true or false"
        case .array: return "a list"
        }
    }
}

/// `config.toml` as the lines a person wrote, with the values read out of them.
///
/// **An editor, not a serializer.** The file is kept as its lines, and a write
/// changes the characters of one value and nothing else: the key keeps its
/// spelling, the comment after it stays after it, and every line this type does
/// not understand — or understands and has no use for — comes back byte for
/// byte. ADR-0012 says why this is in-house rather than `toml_edit` over uniffi.
///
/// It reads the subset a settings file uses: `key = value` at the top, and
/// `[table]` headers. Values are strings (basic and literal), integers, floats,
/// booleans and single-line arrays of those. Anything else — a multi-line
/// string, an inline table, a date, an array of tables — is reported as a
/// problem on its line and left exactly where it is, never rewritten.
public struct TomlDocument: Sendable {
    /// One `key = value` line.
    public struct Entry: Equatable, Sendable {
        /// `nil` for the top of the file, before any header.
        public let table: String?
        public let key: String
        /// 1-based, for a message a person can find.
        public let line: Int
        /// The value, or why it could not be read.
        public let value: Result<TomlValue, TomlError>
        /// Character offsets of the value within its line, so a write can
        /// replace exactly those characters. `valueEnd` is nil when the value
        /// could not be read, and a write then replaces the rest of the line.
        let valueStart: Int
        let valueEnd: Int?
    }

    public struct TomlError: Error, Equatable, Sendable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// A line that is neither blank, a comment, a header nor a readable
    /// `key = value`.
    public struct Unreadable: Equatable, Sendable {
        public let line: Int
        public let reason: String
    }

    private(set) var lines: [String]
    private var endsWithNewline: Bool

    public private(set) var entries: [Entry] = []
    public private(set) var unreadable: [Unreadable] = []
    /// Every `[header]`, in order, with its line index (0-based).
    private var headers: [(name: String, index: Int)] = []

    public init(_ text: String) {
        endsWithNewline = text.isEmpty || text.hasSuffix("\n")
        var split = text.components(separatedBy: "\n")
        if endsWithNewline, split.last == "" { split.removeLast() }
        // A file saved on Windows. The `\r` is kept on each line so an untouched
        // line still comes back byte for byte; it is only ignored when reading.
        lines = split
        reparse()
    }

    public var text: String {
        lines.joined(separator: "\n") + (endsWithNewline && !lines.isEmpty ? "\n" : "")
    }

    /// The first entry for `key` in `table`.
    public func entry(_ key: String, in table: String? = nil) -> Entry? {
        entries.first { $0.table == table && $0.key == key }
    }

    // MARK: - editing

    /// Give `key` in `table` this value: in place when it is already there,
    /// otherwise on a new line at the end of that table — which is created, at
    /// the end of the file, when the file has none.
    public mutating func set(_ key: String, in table: String? = nil, to value: TomlValue) {
        if let existing = entry(key, in: table) {
            let chars = Array(lines[existing.line - 1])
            let end = existing.valueEnd ?? chars.count
            lines[existing.line - 1] = String(chars[..<existing.valueStart]) + value.toml + String(chars[end...])
            reparse()
            return
        }
        let line = "\(Self.bareOrQuoted(key)) = \(value.toml)"
        if let table {
            guard let header = headers.first(where: { $0.name == table }) else {
                if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty { lines.append("") }
                lines.append("[\(table)]")
                lines.append(line)
                endsWithNewline = true
                reparse()
                return
            }
            let after = entries.filter { $0.table == table && $0.line - 1 > header.index }.map { $0.line - 1 }
            lines.insert(line, at: (after.max() ?? header.index) + 1)
        } else if let lastTop = entries.filter({ $0.table == nil }).map({ $0.line - 1 }).max() {
            lines.insert(line, at: lastTop + 1)
        } else if let first = headers.first {
            // Before the first table, and above the comments that sit directly
            // on top of its header: those describe the table, not this key.
            var at = first.index
            while at > 0, Self.isComment(lines[at - 1]) { at -= 1 }
            // Keep a blank line between the new key and whatever it now sits on.
            lines.insert(contentsOf: [line, ""], at: at)
        } else {
            lines.append(line)
            endsWithNewline = true
        }
        reparse()
    }

    /// Take `key` out of `table`, which is what "back to the default" writes.
    /// Only that line goes; a comment above it stays, because it may be about
    /// more than the one key.
    public mutating func remove(_ key: String, in table: String? = nil) {
        let doomed = entries.filter { $0.table == table && $0.key == key }.map { $0.line - 1 }
        guard !doomed.isEmpty else { return }
        for index in doomed.sorted(by: >) { lines.remove(at: index) }
        reparse()
    }

    // MARK: - reading

    private mutating func reparse() {
        entries = []
        unreadable = []
        headers = []
        var table: String?
        for (index, raw) in lines.enumerated() {
            var chars = Array(raw)
            if chars.last == "\r" { chars.removeLast() }
            var scan = Scanner(chars)
            scan.skipSpace()
            guard let first = scan.peek, first != "#" else { continue }
            if first == "[" {
                if scan.peek(at: 1) == "[" {
                    unreadable.append(.init(line: index + 1, reason: "an array of tables ([[…]]) is not something this file uses"))
                    // Named as written, so its keys are reported under it and
                    // never mistaken for top-level settings.
                    table = raw.trimmingCharacters(in: .whitespaces)
                    continue
                }
                scan.advance()
                guard let name = scan.readKeyPath(), scan.skipSpace(), scan.take("]"), scan.atEndOrComment() else {
                    unreadable.append(.init(line: index + 1, reason: "could not read this table header"))
                    table = "[unreadable]"
                    continue
                }
                table = name.joined(separator: ".")
                headers.append((table!, index))
                continue
            }
            guard let path = scan.readKeyPath(), scan.skipSpace(), scan.take("=") else {
                unreadable.append(.init(line: index + 1, reason: "expected key = value"))
                continue
            }
            scan.skipSpace()
            // A dotted key at the top of the file is a key in that table:
            // `keys.closePane = []` is `closePane` under `[keys]`.
            var entryTable = table
            var key = path.last!
            if path.count > 1 {
                let prefix = path.dropLast().joined(separator: ".")
                entryTable = table.map { "\($0).\(prefix)" } ?? prefix
                key = path.last!
            }
            let start = scan.position
            let value: Result<TomlValue, TomlError>
            var end: Int?
            do {
                let parsed = try scan.readValue()
                scan.skipSpace()
                guard scan.atEndOrComment() else { throw TomlError("unexpected text after the value") }
                end = scan.valueEnd
                value = .success(parsed)
            } catch let error as TomlError {
                value = .failure(error)
            } catch {
                value = .failure(TomlError("\(error)"))
            }
            entries.append(Entry(
                table: entryTable, key: key, line: index + 1, value: value,
                valueStart: start, valueEnd: end))
        }
    }

    // MARK: - spelling

    static func isBare(_ key: String) -> Bool {
        !key.isEmpty && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-"
        }
    }

    static func bareOrQuoted(_ key: String) -> String { isBare(key) ? key : quoted(key) }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
    }
}

/// A cursor over one line.
private struct Scanner {
    let chars: [Character]
    var position = 0
    /// Where the last value read ended, before any trailing space or comment.
    var valueEnd = 0

    init(_ chars: [Character]) { self.chars = chars }

    var peek: Character? { position < chars.count ? chars[position] : nil }
    func peek(at offset: Int) -> Character? {
        position + offset < chars.count ? chars[position + offset] : nil
    }
    mutating func advance() { position += 1 }

    @discardableResult
    mutating func skipSpace() -> Bool {
        while let c = peek, c == " " || c == "\t" { advance() }
        return true
    }

    mutating func take(_ c: Character) -> Bool {
        guard peek == c else { return false }
        advance()
        return true
    }

    func atEndOrComment() -> Bool { peek == nil || peek == "#" }

    typealias TomlError = TomlDocument.TomlError

    /// `a`, `"a b"`, `a.b`, `a . "b"`.
    mutating func readKeyPath() -> [String]? {
        var parts: [String] = []
        repeat {
            skipSpace()
            guard let part = readKey() else { return nil }
            parts.append(part)
            skipSpace()
        } while take(".")
        return parts
    }

    private mutating func readKey() -> String? {
        if peek == "\"" { return try? readBasicString() }
        if peek == "'" { return try? readLiteralString() }
        var out = ""
        while let c = peek, c.isASCII, c.isLetter || c.isNumber || c == "_" || c == "-" {
            out.append(c)
            advance()
        }
        return out.isEmpty ? nil : out
    }

    mutating func readValue() throws -> TomlValue {
        guard let c = peek else { throw TomlError("a key with no value") }
        let value: TomlValue
        switch c {
        case "\"":
            if peek(at: 1) == "\"", peek(at: 2) == "\"" { throw TomlError("a multi-line string is not something this file uses") }
            value = .string(try readBasicString())
        case "'":
            if peek(at: 1) == "'", peek(at: 2) == "'" { throw TomlError("a multi-line string is not something this file uses") }
            value = .string(try readLiteralString())
        case "[":
            value = try readArray()
        case "{":
            throw TomlError("an inline table is not something this file uses")
        default:
            value = try readBare()
        }
        valueEnd = position
        return value
    }

    private mutating func readBasicString() throws -> String {
        advance()
        var out = ""
        while let c = peek {
            advance()
            switch c {
            case "\"": return out
            case "\\":
                guard let e = peek else { throw TomlError("a string that ends in a backslash") }
                advance()
                switch e {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "b": out.append("\u{8}")
                case "f": out.append("\u{c}")
                case "e": out.append("\u{1b}")
                case "u", "U":
                    let count = e == "u" ? 4 : 8
                    guard position + count <= chars.count,
                          let code = UInt32(String(chars[position..<position + count]), radix: 16),
                          let scalar = Unicode.Scalar(code)
                    else { throw TomlError("a \\\(e) escape needs \(count) hex digits") }
                    out.unicodeScalars.append(scalar)
                    position += count
                default: throw TomlError("\\\(e) is not an escape TOML knows")
                }
            default: out.append(c)
            }
        }
        throw TomlError("a string that is never closed")
    }

    private mutating func readLiteralString() throws -> String {
        advance()
        var out = ""
        while let c = peek {
            advance()
            if c == "'" { return out }
            out.append(c)
        }
        throw TomlError("a string that is never closed")
    }

    private mutating func readArray() throws -> TomlValue {
        advance()
        var items: [TomlValue] = []
        while true {
            skipSpace()
            guard let c = peek else { throw TomlError("a list has to close on the line it opens on") }
            if c == "]" { advance(); return .array(items) }
            items.append(try readValue())
            skipSpace()
            if take(",") { continue }
            guard take("]") else {
                throw TomlError(peek == nil ? "a list has to close on the line it opens on" : "expected , or ] in a list")
            }
            return .array(items)
        }
    }

    private mutating func readBare() throws -> TomlValue {
        var word = ""
        while let c = peek, c.isLetter || c.isNumber || "_+-.:".contains(c) {
            word.append(c)
            advance()
        }
        switch word {
        case "": throw TomlError("could not read this value")
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "inf", "+inf": return .float(.infinity)
        case "-inf": return .float(-.infinity)
        case "nan", "+nan", "-nan": return .float(.nan)
        default: break
        }
        if word.contains(":") || word.filter({ $0 == "-" }).count >= 2 && !word.lowercased().contains("e") {
            throw TomlError("a date is not something this file uses")
        }
        // Underscores only between digits, the way TOML allows them.
        let digitsOnly = Array(word)
        for (i, c) in digitsOnly.enumerated() where c == "_" {
            guard i > 0, i < digitsOnly.count - 1, digitsOnly[i - 1].isHexDigit, digitsOnly[i + 1].isHexDigit
            else { throw TomlError("\(word) is not a number") }
        }
        let plain = word.replacingOccurrences(of: "_", with: "")
        let unsigned = plain.hasPrefix("+") || plain.hasPrefix("-") ? String(plain.dropFirst()) : plain
        let negative = plain.hasPrefix("-")
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where unsigned.hasPrefix(prefix) {
            guard plain == unsigned, let n = Int64(unsigned.dropFirst(2), radix: radix) else {
                throw TomlError("\(word) is not a number")
            }
            return .integer(n)
        }
        if let n = Int64(plain) {
            // TOML forbids leading zeros, which is what keeps `010` from meaning
            // eight to one reader and ten to another.
            if unsigned.count > 1, unsigned.hasPrefix("0") { throw TomlError("\(word) has a leading zero") }
            return .integer(n)
        }
        let isFloatShaped = unsigned.contains(".") || unsigned.lowercased().contains("e")
        if isFloatShaped, let d = Double(plain), unsigned.first?.isNumber == true, unsigned.last?.isNumber == true {
            return .float(negative && d == 0 ? -0.0 : d)
        }
        throw TomlError("\(word) is not a value TOML knows — a string needs quotes")
    }
}
