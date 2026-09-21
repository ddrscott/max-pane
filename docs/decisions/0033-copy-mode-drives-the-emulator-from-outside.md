# ADR 0033 — ⌘C is the pane's copy, and copy mode drives the emulator from outside

**Status:** Accepted · 2026-09-21
**Decides:** who copies a terminal selection and what it cleans; where styled
text comes from; how a keyboard copy mode is built on a library with no call
that sets a selection; and what that mode cannot do.
**Evidence:** the work item [`docs/work/terminal-copy-side.md`](../work/terminal-copy-side.md);
`TerminalCopy.swift`, `CopyMode.swift`, `CopyModeDriver.swift`;
`TerminalCopyTests.swift`, whose `FINDING` test and real-surface suite are the
measurements below.

## The facts

Measured on a real surface (libghostty-spm at Ghostty `82938b63`), not read
from documentation.

1. **The emulator's copy was already clean.** `copy_to_clipboard` joins a
   soft-wrapped line into one, trims trailing spaces per line
   (`clipboard-trim-trailing-spaces`, default true), adds no final newline,
   and copies a rectangle (⌥-drag) as one line per row. It also writes an
   HTML flavour, which the library puts on the pasteboard under the type
   `text/html`: not `public.html`, so no app ever read it.
2. **`TerminalSurface.readSelection()` is not the same text.** It joins wraps
   but keeps trailing spaces. Paste history (ADR-0031) read the selection that
   way, so it kept text the clipboard never held.
3. **The library writes to `NSPasteboard.general` by name.** The pane's
   injected pasteboard, which every paste honours, was bypassed by every copy.
4. **What libghostty-spm exposes for a selection**, in full:
   `TerminalSurface.hasSelection()`, `readSelection()`,
   `performBindingAction(_:)` (any Ghostty keybind action by name: `select_all`,
   `adjust_selection:<dir>`, `copy_to_clipboard[:plain|vt|html|mixed]`,
   `scroll_to_row:N`, `scroll_page_lines:N`, `scroll_to_top|bottom`,
   `search:<text>`, `navigate_search:next|previous`, `end_search`),
   `sendMousePos`, `sendMouseButton`, `sendMouseScroll`, `isMouseCaptured`,
   `InMemoryTerminalSession.readViewportText()` (the visible rows, wherever the
   viewport is scrolled to), `TerminalSurfaceScrollbarDelegate` (total, offset
   and length in rows) and `TerminalSurfaceGridResizeDelegate` (the cell size
   in pixels, which the session's resize callback reports as zero).
5. **What it does not expose.** No call sets a selection from cell
   coordinates. Nothing says where the terminal's cursor is. The C API's
   `ghostty_surface_read_text` can read any rows including scrollback, and the
   wrapper keeps the `ghostty_surface_t` it needs internal. Cell attributes
   and colours are reachable only as the HTML of a copy. Search reports
   (`GHOSTTY_ACTION_SEARCH_TOTAL`, `_SEARCH_SELECTED`) stop at
   `TerminalCallbackBridge` and there is no match position at all.
6. **Scrolls are asynchronous.** `scroll_to_row` returns before the viewport
   has moved; a read straight after sees the old rows. The scrollbar delegate
   reports the new offset 10 to 30 ms later.
7. **A drag is pinned to text, not to the screen.** Press, scroll, move,
   release selects from the pressed cell to the released one across any
   distance. A press within a cell of the last one is a double click and
   selects a word. With ⇧ held nothing is reported to a program that asked
   for the mouse.
8. `adjust_selection:left|right` skips cells nothing was written to and wraps
   across rows, so it cannot stand in for a cursor.

## Decision

**⌘C is the pane's.** `ClickableTerminalView.copy` asks the pane first: it
reads the selection from the surface, runs `TerminalCopy.clean` (trailing
spaces and tabs off every line when `copy_trim_trailing`, nothing else, never
an added newline), writes plain text to the pane's pasteboard, and records
that same text in paste history. Joining wrapped lines stays the emulator's:
it is the only party that knows which rows were wrapped. The library's copy is
no longer called. `copy_on_select` still copies inside the emulator, so the
terminals' configuration hands Ghostty `clipboard-trim-trailing-spaces` from
the same setting. OSC 52 is untouched (ADR-0028).

**Copy with Styles reads the emulator's HTML and writes its own.**
`copy_to_clipboard:html` is the one road to colours. The pane fires it, reads
`text/html` back from the general pasteboard in the same turn,
parses it into runs (`TerminalCopy.parse`, which refuses anything that is not
that exact shape), and writes plain text, RTF and HTML under the standard
types, in the configured font. In the app the general pasteboard is the pane's
pasteboard, so the intermediate write is overwritten at once.

**Copy mode is a pure state machine and a driver.** `CopyMode` answers every
key with no terminal in it: rows are absolute (the scrollbar's count), so a
selection across screens is two cells. `CopyModeDriver` makes a surface show
it: `scroll_to_row`, then wait for the scrollbar to confirm; a selection as a
synthesized ⇧-drag from the anchor to the cursor, preceded by a click far away
so the press is never a double click; when the anchor is off screen, scroll to
it, press, scroll back, release (fact 7). The cursor is an outline the driver
draws. Keys are answered one at a time, each after the last is on screen.
`keyDown`, `keyUp` and `flagsChanged` are all swallowed while it is on.

**Output is held while copy mode is on**, and fed in order when it ends (4 MB
waiting ends it). Every cell the mode names would otherwise be a different
cell a moment later. tmux does the same.

**Find uses the emulator's search** (`search:`, `navigate_search:`), which
highlights and scrolls. The cursor goes to the occurrence in view nearest to
where it was (`CopyMode.nearest`), because nothing says which match the
emulator made current.

**⌥⌘C and ⇧⌘C yield to a page** (`Command.yieldsToPage`, ADR-0032): Safari's
page source and every browser's inspector.

## What was refused, and the call that is missing

- **Starting on the terminal's own cursor.** No cursor position is exposed.
  Copy mode starts on the last line with text.
- **Landing on the emulator's current match.** Needs `SEARCH_SELECTED`
  forwarded and a match position.
- **Reading scrollback without showing it**, which would let `w`, `b` and `$`
  work on rows not in view and a find be done without the emulator's search.
  Needs `ghostty_surface_read_text` reachable, which means the wrapper's
  surface pointer. Off-screen rows have no text here: `$` goes to the margin.
- **Patching the library checkout** to get any of these.

## Consequences

- A selection taller than the viewport flashes the anchor's screen for a frame
  or two on each key, because the press has to happen where the anchor is.
- A program that set XTSHIFTESCAPE would be sent the synthesized ⇧-clicks.
  None has been seen to.
- Wide characters count as one column in `w`, `b`, `^` and `$`.
- If a libghostty update changes the HTML's shape, Copy with Styles degrades
  to plain text and says so; `TerminalCopyTests` pins the shape.

## What would make us revisit

- libghostty-spm exposing a selection setter, the cursor position, a
  scrollback read, or search results: each removes one item above, and the
  first removes the synthesized drag.
- The held output surprising someone: a long-running job that looks hung
  because ⇧⌘C was left on in its lane. The chip is there to prevent it.
