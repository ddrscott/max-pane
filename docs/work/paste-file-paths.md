# ⌘V of a file copied in Finder pastes its full path, quoted when it needs to be

## Problem

Copy a file in Finder (⌘C), paste into a Max Pane terminal (⌘V): only the file
*name* lands on the prompt, not its path. The name alone is useless anywhere
but the file's own directory. iTerm and Terminal paste the full path. The owner
hands files to agents this way all day (a screenshot, a PDF, a log).

## Cause (read, not guessed)

`TerminalPaste.clipboardText` (`Terminal/TerminalPaste.swift`, the last
function) reads `pasteboard.string(forType: .string)` and nothing else. When
Finder copies a file it puts the file URL on the pasteboard as
`public.file-url` (one item per file) *and* a plain-string flavour holding
just the display name. The paste takes the string, so it gets the name.

## Acceptance Criteria

- **File URLs win over the string flavour.** If the pasteboard holds file
  URLs (`readObjects(forClasses: [NSURL.self], options:
  [.urlReadingFileURLsOnly: true])`), the paste is their paths and the string
  flavour is ignored. With no file URLs, behaviour is exactly today's. A
  non-file URL copied from a browser is not a file URL and pastes as text, as
  it does now.
- **The full path**, as `URL.path` gives it: absolute, not `~`-abbreviated,
  not percent-encoded, and not the `/.file/id=…` file-reference form Finder
  sometimes hands over (resolve with `standardizedFileURL` / `filePathURL`).
  Do not stat the file or resolve symlinks; paste what was copied.
- **Quoted only when needed, in double quotes, as the owner asked.**
  - A path made only of characters no POSIX shell treats specially
    (`A–Z a–z 0–9 / . _ - + , : @ %` and non-ASCII letters) pastes bare:
    `/Users/spierce/Downloads/report.pdf`.
  - Anything else is wrapped in double quotes, with the four characters that
    stay live inside double quotes backslash-escaped: `\` `"` `$` `` ` ``.
    So `My File.pdf` becomes `"/Users/spierce/My File.pdf"` and
    `cost $5 "final".txt` becomes `"/…/cost \$5 \"final\".txt"`.
  - `!` is history expansion in interactive bash and zsh even inside double
    quotes and cannot be escaped there. A path containing `!` is the one case
    that gets single quotes instead (with `'` written as `'\''`). Say so in the
    code; it is rare and the alternative is a paste that silently changes.
  - A newline or other control character in a file name: refuse that one file
    and paste the rest; a control character typed into a prompt is a
    keystroke, not text. One line in the pane's existing notice style says
    which was skipped.
- **Several files** paste space-separated, each quoted by the rule above, in
  the pasteboard's order, with no trailing space and no trailing newline. (The
  existing rule that a paste never ends in Return still holds.)
- **It is a pure function with the pasteboard injected**, like the rest of
  `TerminalPaste`: `static func shellWord(for path: String) -> String?` and
  `clipboardText(_:)` choosing between URLs and string. No `FileManager`.
- **Drag and drop:** the terminal view does not accept file drops today
  (`registerForDraggedTypes` appears nowhere under `Terminal/`). If adding a
  drop of files onto a terminal pane is small with the same function (iTerm
  does this, and it is the same user intent), do it: the drop types the quoted
  paths at the cursor, focuses the pane, and must not fight the strip's own
  pane-drag (`Views/PaneDrag.swift`). If it is not small, leave it out and say
  so in the report; do not half-build it.
- **Remote lanes** (a session on a relay server): the path is a path on this
  Mac and means nothing over there. Paste it anyway, unchanged: it is what was
  asked for, and uploading the file through the server's API is plan Phase 4,
  not this task. Note the limitation in the README's remote section in one
  sentence.
- The Edit menu's Paste, ⌘V, and any right-click Paste in a terminal all go
  through the same function (they do today via `pasteFromClipboard`; confirm).
- Tests in `TerminalPasteTests.swift`, with a private named `NSPasteboard` so
  the owner's real clipboard is never touched: one file, a name with a space,
  each of `\ " $ `` ` ``, a `!`, a name with a newline among good ones, three
  files in order, a file URL *and* a string flavour together (URL wins), a web
  URL (string wins), plain text (unchanged), a non-ASCII name (bare), and the
  file-reference URL form.
- README: the terminal paste paragraph gains the file rule and the quoting
  rule. CHANGELOG: Fixed.

## Relevant Files

- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaste.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/TerminalPaneController.swift`
  (`pasteFromClipboard`, ~line 357 area; `container.onPaste`)
- `swift/MaxPane/Tests/MaxPaneKitTests/TerminalPasteTests.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Views/PaneDrag.swift` (only if adding drop)

## Constraints

- No bracketed-paste markers, ever: `TerminalPaste`'s header comment explains
  why, and nothing here changes it. The quoting is what makes a path safe to
  land on a prompt.
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Tests must not write to `NSPasteboard.general`.
