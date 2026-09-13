import Foundation

/// How many matches ⌘F found, counted honestly.
///
/// ## Why this is not a line in the find bar
///
/// `WKWebView.find` answers with a `WKFindResult`, and `WKFindResult` carries
/// `matchFound` and nothing else — no count, no index, no wrap flag. Rounds 1
/// and 2 both left the bar saying nothing for that reason, which is defensible
/// and still costs the reader the thing they wanted: *"one hit and forty look
/// the same."*
///
/// So the count has to be taken in the page, and a second search that can
/// disagree with the one WebKit is highlighting is a real way to be wrong. Three
/// rules keep it from becoming a lie:
///
/// 1. **WebKit is the authority on whether there is a match.** This only ever
///    supplies a number next to a `matchFound` that is already true. If the
///    count comes back zero while WebKit says it found something — an iframe, a
///    `<slot>`, some normalisation this does not do — the bar says *nothing*
///    rather than `0`. A readout that contradicts the highlight on screen is
///    worse than the silence it replaced.
/// 2. **The index comes from WebKit's own selection, not from a counter.** The
///    obvious `n` is "how many times has ↩ been pressed", and it is wrong the
///    first time the page scrolls, the user clicks, or the search wraps. Instead
///    the script locates `window.getSelection()` — which *is* the match WebKit
///    just highlighted — inside the text it walked, and reports how many matches
///    start at or before it. When the selection cannot be placed, the index is
///    omitted and the total is shown alone.
/// 3. **A count that cannot see everything says so**, with a trailing `+`.
///    `find` searches subframes; script reaches the main frame only, and macOS
///    `WKWebView` exposes no way to enumerate frames. So the script reports
///    whether the document holds any frame at all, and one character admits the
///    count is a floor rather than pretending it is a total.
///
/// ## How the script below was checked
///
/// Not by a live ⌘F: the owner's instance held the front for the whole of this
/// work and input was aborted rather than risked. The Swift tests reach `label`
/// and `tally` and stop at the language boundary, so the counter itself was run
/// in a real JavaScript engine against a hand-built DOM — 17 cases, all passing,
/// including the two that decide whether the number is worth showing at all: a
/// match spanning `<b>fo</b>o` **is** counted, and one spanning
/// `<p>fo</p><p>o</p>` is **not**. Also checked: `<script>` and hidden subtrees
/// skipped, `max   pane` matching text that wrapped between the words, `aa` in
/// `aaaa` counting 2 rather than 3, and the index landing on the right match
/// when the selection sits in the second of two blocks.
///
/// That harness is deliberately not in `scripts/test.sh`. It needs Node, and
/// this machine's toolchain is Command Line Tools by design — adding a second
/// language runtime to the edit loop to guard one function is a worse trade than
/// re-running it by hand when this script changes.
enum FindCount {
    /// The reading of one page.
    struct Tally: Equatable, Sendable {
        /// Matches found in the main frame.
        var total: Int
        /// Which match WebKit has highlighted, 1-based. Zero when the selection
        /// could not be located, which is the signal to show the total alone.
        var index: Int
        /// The document holds frames this count could not reach.
        var partial: Bool

        static let none = Tally(total: 0, index: 0, partial: false)
    }

    /// What the find bar shows, given what WebKit said and what the page
    /// counted.
    ///
    /// Deliberately terse. This sits in a 26 pt row inside a lane that can be
    /// dragged to 420 pt, between the query field and three buttons — `3/17` is
    /// four characters and `3 of 17 matches` is a second row. Every browser's
    /// find bar has trained the same four characters.
    static func label(matchFound: Bool, tally: Tally) -> String {
        guard matchFound else { return "" }
        // Rule 1: never contradict the highlight.
        guard tally.total > 0 else { return "" }
        let suffix = tally.partial ? "+" : ""
        guard tally.index > 0 else { return "\(tally.total)\(suffix)" }
        return "\(tally.index)/\(tally.total)\(suffix)"
    }

    /// Read a tally back out of what `evaluateJavaScript` returned.
    ///
    /// Tolerant on purpose: the script is the only thing that produces this
    /// shape, but it runs in a page WebKit may be tearing down, and a partial
    /// dictionary should read as "no count" rather than as a crash in a find
    /// bar.
    static func tally(from result: Any?) -> Tally {
        guard let dictionary = result as? [String: Any],
              let total = (dictionary["total"] as? NSNumber)?.intValue
        else { return .none }
        return Tally(
            total: max(0, total),
            index: max(0, (dictionary["index"] as? NSNumber)?.intValue ?? 0),
            partial: (dictionary["partial"] as? NSNumber)?.boolValue ?? false)
    }

    /// The script, with the query embedded as a JSON string.
    ///
    /// JSON rather than escaping by hand: a find query is arbitrary user text
    /// and this is the one place in the find path where it crosses into another
    /// language. `JSONSerialization` on a one-element array is the shortest way
    /// to get a correctly quoted JS string literal out of Foundation — a bare
    /// string is not valid top-level JSON on every OS version, so the brackets
    /// are trimmed off an array instead.
    static func javaScript(for query: String) -> String {
        let literal = jsString(query)
        return "(" + body + ")(" + literal + ")"
    }

    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text]),
              let json = String(data: data, encoding: .utf8),
              json.count >= 2
        else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// The counter.
    ///
    /// ## Why the text is walked in chunks rather than read whole
    ///
    /// `document.body.textContent` in one string over-counts and under-counts at
    /// once. It joins text across block boundaries, so a paragraph ending `fo`
    /// followed by one starting `o` reports a match for `foo` that no reader can
    /// see; and it includes `<script>` and hidden subtrees, which WebKit's find
    /// skips. So the walk flushes its buffer at every block-level element and
    /// skips what is not rendered — which also keeps matches that span *inline*
    /// elements, `<b>fo</b>o`, counted, because those are exactly the joins
    /// WebKit does make.
    ///
    /// ## Why whitespace is collapsed
    ///
    /// Source indentation is not text the reader sees, and a query with a space
    /// in it would miss every match broken across a newline in the markup. The
    /// collapse is what makes `max pane` match markup that wrapped between the
    /// two words. It is also the one place the selection offset can drift by a
    /// character or two on pathological whitespace — which costs the `n`, never
    /// the `m`, and the `n` is already omitted when it cannot be placed.
    private static let body = #"""
    function (needleRaw) {
      var out = { total: 0, index: 0, partial: false };
      if (!needleRaw) { return out; }
      var needle = needleRaw.toLowerCase().replace(/\s+/g, " ").trim();
      if (!needle) { return out; }
      var doc = document;
      if (!doc || !doc.body) { return out; }
      out.partial = doc.querySelector("iframe, frame, object[data], embed") !== null;

      var selNode = null, selOffset = 0;
      var sel = window.getSelection();
      if (sel && sel.rangeCount > 0) {
        var range = sel.getRangeAt(0);
        selNode = range.startContainer;
        selOffset = range.startOffset;
      }

      var BLOCK = {
        ADDRESS:1, ARTICLE:1, ASIDE:1, BLOCKQUOTE:1, BODY:1, BR:1, CAPTION:1,
        DD:1, DETAILS:1, DIALOG:1, DIV:1, DL:1, DT:1, FIELDSET:1, FIGCAPTION:1,
        FIGURE:1, FOOTER:1, FORM:1, H1:1, H2:1, H3:1, H4:1, H5:1, H6:1,
        HEADER:1, HR:1, LI:1, MAIN:1, NAV:1, OL:1, OPTION:1, P:1, PRE:1,
        SECTION:1, SUMMARY:1, TABLE:1, TBODY:1, TD:1, TEXTAREA:1, TFOOT:1,
        TH:1, THEAD:1, TR:1, UL:1
      };
      var SKIP = { SCRIPT:1, STYLE:1, NOSCRIPT:1, TEMPLATE:1, HEAD:1, TITLE:1, SELECT:1 };

      // The buffer for the block being walked, the offset the selection landed
      // at inside it, and the running total of every block already counted.
      var buf = "", selAt = -1, total = 0, index = 0;

      function collapse(text) { return text.replace(/\s+/g, " "); }

      function append(node) {
        var text = collapse(node.data || "");
        if (!text) { return; }
        if (node === selNode) {
          // Where the selection sits once this node's own whitespace has been
          // collapsed the same way the buffer's was.
          var head = collapse((node.data || "").slice(0, selOffset));
          selAt = buf.length + head.length;
        }
        buf += text;
      }

      function flush() {
        if (buf) {
          var hay = buf.toLowerCase();
          var from = 0, at;
          while ((at = hay.indexOf(needle, from)) !== -1) {
            total += 1;
            // Rule 2: the index is where WebKit's own selection is, not a
            // count of keypresses. `<=` because the selection starts exactly at
            // the match WebKit highlighted, and a little drift from the
            // whitespace collapse should still land on it rather than past it.
            if (selAt >= 0 && at <= selAt) { index = total; }
            from = at + needle.length;
          }
        }
        buf = "";
        selAt = -1;
      }

      function visible(element) {
        if (typeof element.checkVisibility === "function") {
          return element.checkVisibility({ checkVisibilityCSS: true });
        }
        var style = window.getComputedStyle(element);
        return !style || (style.display !== "none" && style.visibility !== "hidden");
      }

      function walk(node) {
        for (var child = node.firstChild; child; child = child.nextSibling) {
          if (child.nodeType === 3) { append(child); continue; }
          if (child.nodeType !== 1) { continue; }
          var tag = child.tagName ? child.tagName.toUpperCase() : "";
          if (SKIP[tag]) { continue; }
          if (!visible(child)) { continue; }
          var isBlock = BLOCK[tag] === 1;
          if (isBlock) { flush(); }
          walk(child);
          if (isBlock) { flush(); }
        }
      }

      try { walk(doc.body); } catch (e) { return out; }
      flush();
      out.total = total;
      out.index = index;
      return out;
    }
    """#
}
