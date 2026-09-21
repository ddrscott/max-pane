import AppKit

/// ⌘C from a terminal, as a selector of the pane's own.
///
/// The same arrangement as `TerminalPasteTarget`: the container is the
/// terminal's next responder, so a nil-targeted send reaches a terminal pane
/// with the keyboard and nothing at all when a web pane has it.
@MainActor
@objc public protocol TerminalCopyTarget {
    /// ⌥⌘C, Edit › Copy with Styles.
    func copyWithStylesFromTerminalPane(_ sender: Any?)
    /// ⇧⌘C, Edit › Copy Mode: on, or off again.
    func toggleCopyModeInTerminalPane(_ sender: Any?)
}

/// What a copy out of a terminal puts on the clipboard (ADR-0033).
///
/// The way in is `TerminalPaste`; this is the way out, and it is shaped the
/// same: everything that decides what lands is a pure function, and the
/// pasteboard is handed in.
///
/// **What the emulator gives.** `ghostty_surface_read_selection` joins a
/// soft-wrapped line back into one (a wrap is the terminal's doing and is
/// not in the text), separates rows with `\n`, leaves out cells nothing was
/// ever written to, adds no final newline, and **keeps trailing spaces a
/// program printed**. A rectangular selection (⌥-drag) comes back as one
/// line per row. So joining is the emulator's and is not redone here; the
/// trailing spaces are what is left to clean.
///
/// **A program's copy is the program's.** OSC 52 goes through
/// `ProgramClipboard` and is never cleaned.
enum TerminalCopy {
    /// The selection as it should land: trailing spaces and tabs dropped from
    /// every line when `trimTrailing`, and nothing else changed. No final
    /// newline is ever added; one that was selected is kept, because a blank
    /// line selected on purpose is content.
    static func clean(_ text: String, trimTrailing: Bool) -> String {
        guard trimTrailing else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex {
                    let before = line.index(before: end)
                    guard line[before] == " " || line[before] == "\t" else { break }
                    end = before
                }
                return line[line.startIndex..<end]
            }
            .joined(separator: "\n")
    }

    // MARK: - styled text

    struct RGB: Equatable {
        var r: UInt8, g: UInt8, b: UInt8
        var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
        var color: NSColor {
            NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }

    /// A stretch of text in one style. Newlines are in `text`.
    struct Run: Equatable {
        var text: String
        var foreground: RGB?
        var background: RGB?
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var faint = false
    }

    /// A selection with its colours: the runs, and the terminal's own
    /// foreground and background behind them.
    struct Styled: Equatable {
        var runs: [Run]
        var foreground: RGB?
        var background: RGB?

        var plain: String { runs.map(\.text).joined() }
    }

    /// Read the HTML libghostty writes for `copy_to_clipboard:html`.
    ///
    /// That flavour is the only styled text the library gives out: one outer
    /// `<div style="…">` carrying the terminal's colours, and inside it plain
    /// text and `<div style="display: inline;…">` runs. This reads exactly
    /// that, and gives nil for anything else, so a future format change says
    /// "copied without styles" rather than copying rubbish.
    static func parse(html: String) -> Styled? {
        var styled = Styled(runs: [])
        var stack: [Run] = []
        var rest = Substring(html)
        var sawOuter = false

        func append(_ raw: Substring) {
            guard !raw.isEmpty, let style = stack.last else { return }
            let text = decodeEntities(String(raw))
            if var last = styled.runs.last, sameStyle(last, style) {
                last.text += text
                styled.runs[styled.runs.count - 1] = last
            } else {
                var run = style
                run.text = text
                styled.runs.append(run)
            }
        }

        while let open = rest.firstIndex(of: "<") {
            append(rest[rest.startIndex..<open])
            guard let close = rest[open...].firstIndex(of: ">") else { return nil }
            let tag = rest[rest.index(after: open)..<close]
            rest = rest[rest.index(after: close)...]
            if tag.hasPrefix("/") {
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
            } else if tag.hasPrefix("div") {
                let css = properties(in: attribute("style", of: tag) ?? "")
                var run = stack.last ?? Run(text: "")
                if !sawOuter {
                    sawOuter = true
                    styled.foreground = css["color"].flatMap(colour)
                    styled.background = css["background-color"].flatMap(colour)
                } else {
                    if let c = css["color"].flatMap(colour) { run.foreground = c }
                    if let c = css["background-color"].flatMap(colour) { run.background = c }
                    if css["font-weight"] == "bold" { run.bold = true }
                    if css["font-style"] == "italic" { run.italic = true }
                    if css["opacity"] != nil { run.faint = true }
                    let decoration = (css["text-decoration"] ?? "") + " " + (css["text-decoration-line"] ?? "")
                    if decoration.contains("underline") { run.underline = true }
                    if decoration.contains("line-through") { run.strikethrough = true }
                }
                stack.append(run)
            } else if tag.hasPrefix("br") {
                append("\n")
            } else {
                return nil
            }
        }
        guard sawOuter, stack.isEmpty else { return nil }
        return styled
    }

    /// `clean`, for styled text: trailing blanks go from every line, except
    /// blanks with a background of their own, which are a bar somebody drew.
    static func clean(_ styled: Styled, trimTrailing: Bool) -> Styled {
        guard trimTrailing else { return styled }
        // One run per line piece, so a line's tail can be walked backwards.
        var pieces: [Run] = []
        for run in styled.runs {
            let parts = run.text.replacingOccurrences(of: "\r\n", with: "\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                if i > 0 { pieces.append(Run(text: "\n")) }
                var piece = run
                piece.text = String(part)
                pieces.append(piece)
            }
        }
        var out: [Run] = []
        var i = pieces.count - 1
        var atLineEnd = true
        while i >= 0 {
            var piece = pieces[i]
            if piece.text == "\n" {
                atLineEnd = true
            } else if atLineEnd, piece.background == nil {
                piece.text = clean(piece.text, trimTrailing: true)
                if !piece.text.isEmpty { atLineEnd = false }
            } else if !piece.text.isEmpty {
                atLineEnd = false
            }
            if !piece.text.isEmpty { out.append(piece) }
            i -= 1
        }
        var merged: [Run] = []
        for piece in out.reversed() {
            if var last = merged.last, sameStyle(last, piece) {
                last.text += piece.text
                merged[merged.count - 1] = last
            } else {
                merged.append(piece)
            }
        }
        return Styled(runs: merged, foreground: styled.foreground, background: styled.background)
    }

    /// The HTML flavour: the same runs, in the terminal's font, as one `<pre>`.
    static func html(_ styled: Styled, fontName: String, fontSize: Double) -> String {
        var outer = "font-family: '\(fontName.replacingOccurrences(of: "'", with: ""))', monospace; "
            + "font-size: \(format(fontSize))pt; white-space: pre; margin: 0;"
        if let bg = styled.background { outer += " background-color: \(bg.hex);" }
        if let fg = styled.foreground { outer += " color: \(fg.hex);" }
        var body = ""
        for run in styled.runs {
            var css: [String] = []
            if let fg = run.foreground { css.append("color: \(fg.hex)") }
            if let bg = run.background { css.append("background-color: \(bg.hex)") }
            if run.bold { css.append("font-weight: bold") }
            if run.italic { css.append("font-style: italic") }
            if run.faint { css.append("opacity: 0.5") }
            let lines = [run.underline ? "underline" : nil, run.strikethrough ? "line-through" : nil].compactMap { $0 }
            if !lines.isEmpty { css.append("text-decoration: " + lines.joined(separator: " ")) }
            let text = encodeEntities(run.text)
            body += css.isEmpty ? text : "<span style=\"\(css.joined(separator: "; "))\">\(text)</span>"
        }
        return "<meta charset=\"utf-8\"><pre style=\"\(outer)\">\(body)</pre>"
    }

    /// The RTF flavour's source: the same runs as an attributed string.
    static func attributed(_ styled: Styled, fontName: String, fontSize: Double) -> NSAttributedString {
        let size = CGFloat(fontSize)
        let base = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let out = NSMutableAttributedString()
        for run in styled.runs {
            var traits: NSFontTraitMask = []
            if run.bold { traits.insert(.boldFontMask) }
            if run.italic { traits.insert(.italicFontMask) }
            let font = traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
            var attributes: [NSAttributedString.Key: Any] = [.font: font]
            if var fg = (run.foreground ?? styled.foreground)?.color {
                if run.faint { fg = fg.withAlphaComponent(0.5) }
                attributes[.foregroundColor] = fg
            }
            if let bg = (run.background ?? styled.background)?.color { attributes[.backgroundColor] = bg }
            if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return out
    }

    /// Put a copy on `pasteboard`: plain text always, and with `styled` the
    /// RTF and HTML flavours beside it, under the types apps read
    /// (`public.rtf`, `public.html`).
    static func write(
        _ plain: String, styled: Styled? = nil, fontName: String = "", fontSize: Double = 13,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        pasteboard.setString(plain, forType: .string)
        guard let styled else { return }
        let rich = attributed(styled, fontName: fontName, fontSize: fontSize)
        if let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(html(styled, fontName: fontName, fontSize: fontSize), forType: .html)
    }

    /// The type libghostty writes its HTML under: the MIME name, as given,
    /// which is not the `public.html` an app asks for.
    static let libraryHTMLType = NSPasteboard.PasteboardType("text/html")

    // MARK: - parsing helpers

    private static func sameStyle(_ a: Run, _ b: Run) -> Bool {
        var a = a, b = b
        a.text = ""
        b.text = ""
        return a == b
    }

    private static func attribute(_ name: String, of tag: Substring) -> String? {
        guard let start = tag.range(of: "\(name)=\"") else { return nil }
        let value = tag[start.upperBound...]
        guard let end = value.firstIndex(of: "\"") else { return nil }
        return decodeEntities(String(value[value.startIndex..<end]))
    }

    private static func properties(in style: String) -> [String: String] {
        var out: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            out[pair[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                pair[1].trimmingCharacters(in: .whitespaces).lowercased()
        }
        return out
    }

    /// `rgb(r, g, b)` or `#rrggbb`; nil for anything else (a palette variable).
    static func colour(_ value: String) -> RGB? {
        if value.hasPrefix("#"), value.count == 7, let n = UInt32(value.dropFirst(), radix: 16) {
            return RGB(r: UInt8(n >> 16 & 0xff), g: UInt8(n >> 8 & 0xff), b: UInt8(n & 0xff))
        }
        guard value.hasPrefix("rgb("), value.hasSuffix(")") else { return nil }
        let parts = value.dropFirst(4).dropLast().split(separator: ",")
            .map { UInt8($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let r = parts[0], let g = parts[1], let b = parts[2] else { return nil }
        return RGB(r: r, g: g, b: b)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[rest.startIndex..<amp]
            let tail = rest[amp...]
            guard let semi = tail.firstIndex(of: ";"), tail.distance(from: amp, to: semi) <= 10 else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
                continue
            }
            let name = tail[tail.index(after: amp)..<semi]
            let decoded: String?
            switch name {
            case "lt": decoded = "<"
            case "gt": decoded = ">"
            case "amp": decoded = "&"
            case "quot": decoded = "\""
            case "apos": decoded = "'"
            case "nbsp": decoded = "\u{a0}"
            default:
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
                } else if name.hasPrefix("#") {
                    decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
                } else {
                    decoded = nil
                }
            }
            if let decoded {
                out += decoded
                rest = rest[rest.index(after: semi)...]
            } else {
                out += "&"
                rest = rest[rest.index(after: amp)...]
            }
        }
        return out + rest
    }

    private static func encodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func format(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(size)
    }
}
