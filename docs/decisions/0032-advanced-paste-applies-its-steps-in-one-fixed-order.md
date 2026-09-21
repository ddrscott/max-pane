# ADR 0032 — Advanced Paste applies its steps in one fixed order, and its chord is a page's to keep

**Status:** Accepted · 2026-09-21
**Decides:** the order the steps of an Advanced Paste are applied in, whatever
order they were switched on in; where the regular expression sits in it; what a
step that cannot be done does; what paste history keeps; and what ⌥⇧⌘V does in
a web pane.
**Evidence:** the work item [`docs/work/paste-advanced-dialog.md`](../work/paste-advanced-dialog.md);
the `// MARK: - advanced paste` section of `TerminalPaste.swift`;
`AdvancedPasteSheet.swift`; `AdvancedPasteTests.swift`.

## The facts

1. The transforms exist and are pure (ADR-0026, 0029, 0030):
   `straightenPunctuation`, `stripPrompt`, `trimStray`, `tabsToSpaces`,
   `oneLine`, `escaped`, `base64Encoded`, `base64Decoded`.
2. They do not commute. Escaping before One Line quotes the newlines One Line
   was asked to remove. Tabs to Spaces before a pattern holding `\t` leaves the
   pattern nothing to match. Base64 of escaped text and escaped base64 are two
   different pastes.
3. A sheet with eight toggles has 8! orders if the order is the order of
   clicking, and the person cannot see which one they are in.
4. A focused `WKWebView` is only denied the ⌘-chords `Command.claims` names,
   and until now that was every chord in `Commands.swift`.

## Decision

**One order, fixed, and the sheet's column is that order top to bottom.**
`TerminalPaste.Advanced.Step`, by raw value:

| | Step | Why here |
|---|---|---|
| 1 | Decode Base64 | It unwraps. What comes out is the text the rest is for. |
| 2 | Straighten Punctuation | ⌘V's tidying, in ⌘V's order (ADR-0029). |
| 3 | Strip Prompt | |
| 4 | Trim Whitespace | |
| R | the regular expression | On tidied text that still has its lines and its tabs: `^`, `$` and `\t` mean what they say, and a `"` in the pattern meets a straight one. |
| 5 | Tabs to Spaces | Layout, after everything that reads the text by line. |
| 6 | One Line | Needs the lines trimmed first, or the join keeps their strays. |
| 7 | Escape | Quotes what is final. Before One Line it would quote the newlines. |
| 8 | Encode Base64 | It wraps. Nothing textual can be done to base64. |

Straighten Punctuation here is `straightenPunctuation` with no prose guard:
the guard exists because ⌘V was not asked, and this was asked by name.

**`compose` adds nothing but the order and `substitute`.** The sheet shows
`preview(compose(content, toggles))` and sends `bytes(for: compose(…))`, the
same value, so the preview cannot disagree with the wire. The test
`outputIsTheComposition` holds the two together.

**The regular expression** is `NSRegularExpression` (ICU) with
`anchorsMatchLines`, and its replacement is the class's template (`$1`, `\$`).
An empty pattern is off; there is no ninth toggle. A pattern that does not
compile is `.invalid` with one line, shown under the row. No match is the text
unchanged and `0 replacements: no match`.

**A step that cannot be done pastes nothing.** An invalid pattern, or Decode
Base64 of text that is not base64, leaves `text` empty and a `problem`; PASTE
does nothing and the sheet stays up saying why. The alternative, skipping the
step and sending the rest, sends something the person did not ask for to a
shell.

**What it sends goes by the door unasked and untidied**
(`paste(_:asking: false)`): the sheet was the question, put about the exact
bytes, and tidying is three of its toggles. **History keeps what was sent**
(ADR-0031), and nothing when the pasteboard was marked secret, whatever was
edited in the sheet afterwards. With Encode Base64 on, the text *before* that
step is what the secret net is asked about, as Paste as Base64 asks about its
source.

**It remembers the toggles and the pattern until the app quits**
(`AdvancedPasteMemory`, a value in memory) and never the content. Tab width is
read from the config at each opening.

**⌥⇧⌘V yields to a page.** It is iTerm's key for the same sheet and no macOS
system shortcut, but it is Paste and Match Style by app convention and a page
may bind it. `Command.yieldsToPage` is true for this one command, and
`Keymap.claimedChords` leaves its chords out, so in a web pane the page gets
the key and the command is grey in the menu. The other terminal pastes sit on
chords no page binds and stay claimed.

## Costs

- A person who wants another order (escape, *then* a pattern over the quoted
  word) cannot have it in one paste. They can paste into the content box what
  a first pass made. Reopen this if that turns out to be common.
- `^` and `$` match at each line with no way to turn it off but the pattern's
  own `(?-m)`.
- Rebinding another command onto ⌥⇧⌘V makes it claimed again, which is right
  for that command and means the page loses it.
- The content box wraps long lines; only the preview shows where Return is.
