import Foundation

/// What the address bar shows, and what typing into it means.
///
/// Pure and viewless, because every interesting decision an address bar makes is
/// a decision about strings: which run of a URL is worth contrast in a field
/// 300 pt wide, whether `swift actors` is an address or a question, and whether
/// `http://` is a detail or a warning. Those are worth tests; the pixels are
/// worth a screenshot.
enum BrowserAddress {
    // MARK: - what to show

    /// A URL split into the three runs the field draws differently.
    ///
    /// The emphasised run is the *registrable* domain, not the whole host:
    /// `evenrealities.com` out of `www.evenrealities.com`, which is what
    /// Vivaldi emphasises and — the reason it matters — the only part of a URL
    /// an attacker cannot choose. `login.google.com.evil.example` puts the
    /// contrast on `evil.example`, which is the whole point.
    struct Display: Equatable {
        var dimLead: String
        var strong: String
        var dimTail: String

        var plain: String { dimLead + strong + dimTail }
    }

    static func display(_ raw: String) -> Display {
        guard let url = URL(string: raw), let host = url.host, !host.isEmpty else {
            // `about:blank`, a data: URL, or something unparseable. Nothing in
            // it is a domain, so nothing in it gets the emphasis.
            return Display(dimLead: "", strong: "", dimTail: raw)
        }

        // `https://` is dropped and `http://` is kept. Not symmetry for its own
        // sake: https is the state of ~every page, so showing it spends eight
        // characters of a narrow field on no information, while http is the
        // one scheme a reader needs to notice. Hiding *that* is how a downgrade
        // goes unseen.
        let scheme = url.scheme?.lowercased() ?? ""
        var lead = scheme == "https" ? "" : "\(scheme)://"

        let (sub, registrable) = splitHost(host)
        lead += sub

        var tail = ""
        if let port = url.port { tail += ":\(port)" }
        // `url.path` drops a trailing slash that was in the original and adds
        // one that was not, so the tail comes off the raw string instead: the
        // address bar has to show what the page's address actually is.
        if let range = raw.range(of: host + (url.port.map { ":\($0)" } ?? "")) {
            tail += String(raw[range.upperBound...])
        } else {
            tail += url.path + (url.query.map { "?\($0)" } ?? "")
        }

        return Display(dimLead: lead, strong: registrable, dimTail: tail)
    }

    /// `www.bbc.co.uk` → (`www.`, `bbc.co.uk`).
    ///
    /// Two labels, or three when the suffix is one of the registry suffixes that
    /// are themselves two labels — `co.uk`, `com.au`, `ac.jp`. This is a short
    /// list rather than the Public Suffix List, which is 10 000 lines and a
    /// dependency; the cost of missing an entry is that `bbc.co.uk` emphasises
    /// `co.uk`, which is ugly and not dangerous.
    ///
    /// The two-letter test on the last label is what keeps the list from firing
    /// on a host it was not meant for: second-level registry suffixes live
    /// essentially only under country codes, so `a.b.com.evil` is read as
    /// `com.evil` — the actual registrable name — rather than as `b.com.evil`.
    static func splitHost(_ host: String) -> (subdomain: String, registrable: String) {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2 else { return ("", host) }
        let isCountryCode = labels[labels.count - 1].count == 2
        let secondLevel = labels[labels.count - 2].lowercased()
        let keep = isCountryCode && twoLabelSuffixes.contains(secondLevel) ? 3 : 2
        let registrable = labels.suffix(keep).joined(separator: ".")
        let head = labels.dropLast(keep)
        return (head.isEmpty ? "" : head.joined(separator: ".") + ".", registrable)
    }

    private static let twoLabelSuffixes: Set<String> = [
        "co", "com", "net", "org", "gov", "edu", "ac", "mil",
    ]

    // MARK: - what it means

    /// The padlock's job, with the padlock removed.
    enum Security: Equatable {
        /// https. Shows nothing: a lock on every page is a lock nobody reads,
        /// and the state worth a glyph is its *absence*.
        case secure
        /// http, or https that failed. A warning, and the only one the bar draws.
        case insecure
        /// `file://` — local, so "secure" is the wrong word and so is "insecure".
        case local
        /// `about:`, `data:`, a blank pane. Nothing to say.
        case none
    }

    static func security(of raw: String) -> Security {
        guard let scheme = URL(string: raw)?.scheme?.lowercased() else { return .none }
        switch scheme {
        case "https": return .secure
        case "http":
            // A dev server on this machine is not a man-in-the-middle risk, and
            // warning about `localhost:3000` twenty times a day is how a warning
            // stops being read.
            let host = URL(string: raw)?.host?.lowercased() ?? ""
            return isLoopback(host) ? .none : .insecure
        case "file": return .local
        default: return .none
        }
    }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    // MARK: - what Return does

    /// Where Return in the address field should go.
    enum Destination: Equatable {
        case url(String)
        case search(String)
    }

    /// A portrait lane has room for one text field, so this one has to be both
    /// Vivaldi's address bar and its search box. The rule for telling them apart
    /// is *not* written fresh here: `OmniText.looksLikeURL` already
    /// decides what a URL looks like for ⌘T, and an app where `make` means a
    /// command in one field and a website in another is an app that has to be
    /// learned twice.
    static func destination(for typed: String) -> Destination? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // `view-source:`, `data:` and friends go through untouched; WebKit
        // refuses what it will not load, which is a better answer than this
        // function guessing on its behalf.
        if explicitScheme(text) != nil { return .url(text) }
        guard OmniText.looksLikeURL(text) else { return .search(text) }
        // A bare host gets a scheme. https, except on the loopback — a dev
        // server almost never has a certificate, and https://localhost:3000
        // fails in a way that looks like the server is down.
        let host = text.split(separator: "/").first.map(String.init) ?? text
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        return .url((isLoopback(bare.lowercased()) ? "http://" : "https://") + text)
    }

    /// The scheme the user actually typed, or nil.
    ///
    /// `localhost:3000` parses as a scheme by RFC 3986's grammar and is not one,
    /// so a scheme whose body is all digits is read as a port.
    static func explicitScheme(_ text: String) -> String? {
        guard let colon = text.firstIndex(of: ":"), colon != text.startIndex else { return nil }
        let head = String(text[text.startIndex..<colon])
        guard head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }),
              head.first?.isLetter == true
        else { return nil }
        let rest = text[text.index(after: colon)...]
        // `localhost:3000`, `192.168.0.4:8080/health` — a port, not a scheme.
        let port = rest.prefix { $0.isNumber }
        if !port.isEmpty, port.endIndex == rest.endIndex || rest[port.endIndex] == "/" { return nil }
        return head.lowercased()
    }

    /// A query, in whatever engine the config names.
    ///
    /// Google by default because that is what the bar's Vivaldi is set to, and a
    /// search box that answers differently from the one it is replacing is a
    /// downgrade dressed as a principle. `%s` is the placeholder, which is what
    /// every browser's custom-engine field uses.
    static func searchURL(for query: String, template: String) -> String {
        let escaped = query.addingPercentEncoding(
            withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~"))) ?? query
        guard template.contains("%s") else { return template + escaped }
        return template.replacingOccurrences(of: "%s", with: escaped)
    }

    /// Resolve a typed line all the way to something loadable.
    static func resolve(_ typed: String, searchTemplate: String) -> String? {
        switch destination(for: typed) {
        case .url(let url): return url
        case .search(let q): return searchURL(for: q, template: searchTemplate)
        case nil: return nil
        }
    }
}
