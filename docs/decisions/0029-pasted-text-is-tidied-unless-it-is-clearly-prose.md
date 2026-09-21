# ADR 0029 — Pasted text is tidied unless it is clearly prose, the pane says what it did, and there is no undo

**Status:** Accepted · 2026-09-20
**Decides:** which copied text has its smart punctuation straightened, its
copied prompt removed and its stray whitespace trimmed on the way into a
terminal; what "looks like a command" means; what a long dash becomes; and why
the notice that says so has no `as copied` action.
**Evidence:** the work item [`docs/work/paste-text-hygiene.md`](../work/paste-text-hygiene.md);
the `// MARK: - tidying` section of `TerminalPaste.swift`; `PasteTidyTests.swift`.

## The facts

1. A command copied out of Slack, Notion, Docs or a WordPress page arrives with
   `“ ”`, `’`, `—` or `–` where `"`, `'` and `--` were typed, a non-breaking
   space where a space was, and sometimes a zero-width character nobody can
   see. A shell fails on each in a way that looks like a typo. Docs prefix
   commands with `$ `, and a selection drags blank lines and trailing spaces.
2. iTerm has these as transforms in Advanced Paste, which you have to open. The
   owner wants to stop needing iTerm, and wants the quieter answer where one
   fits: they should mostly just happen, and say that they did.
3. The same characters are *right* in prose. A terminal is also where a
   paragraph is pasted into an agent's prompt or an editor.
4. There is no bracketed paste (ADR-0026), so a multi-line paste is already
   held in a sheet, which shows what will be sent.

## Decision

**Only copied text is tidied.** `TerminalPaste.Clipboard.isCopiedText` is set
by the one place that reads the pasteboard's string. Paths made from copied or
dropped files, and a saved or uploaded picture's path, are this app's words,
already quoted, and a `’` in a file's name is the file's name.

**Three transforms, each a pure function with a stable name**, so that Paste
Special, paste history and Advanced Paste can compose them:
`straightenPunctuation`, `stripPrompt`, `trimStray`, and `tidy`, which is the
three in that order with the counts the notice is made of. `tidy` is
idempotent, and a test holds it to that over awkward samples.

**The prose guard.** Punctuation is straightened when the paste is one line, or
every line looks like a command; otherwise it is left exactly as copied. One
line is never "clearly prose": it is what a copied command is, and a sentence
with straight quotes is still the sentence. Empty lines are not judged, nor is
a line that continues the one before it (that one ended in an odd number of
`\`).

**`looksLikeCommand(line)`.** Indentation and one leading prompt are set aside.
A line starting with `#` passes (a comment or a root prompt: it came out of a
script). Otherwise the first word must be an assignment (`NAME=…`) or start
with a lowercase ASCII letter or one of `. / ~ $ _ ( ) { } [ | & !`; must not
be a bare `$`, hold a non-ASCII letter, end in `,` `:` `?`, or end in a letter
followed by `.` or `!`; and must not be one of about sixty words that start
sentences and are neither commands nor shell keywords (`the`, `this`,
`please`, `when`; not `if`, `for`, `as`, `at`, `which`, `yes`, `time`). And the
line must not end in a letter followed by `.` `?` `!` or `,`. It errs toward
"not a command": `Rscript x.R` fails, and the cost is that a multi-line paste
holding it is left as copied.

**The dash rule.** A long dash (`–` `—` `―`) becomes `--` when it starts a word
(start of text, or whitespace before it) and an ASCII letter or digit follows:
`—force`, `git commit –amend`. macOS and Word make an em dash of a typed `--`
and WordPress makes an en dash of it, so both count. Anywhere else it is one
`-`: `a — b`, `2020–2024`, and `–-flag`, where one hyphen survived and the pair
is already `--`. The cost: a source that turned `-rf` into `–rf` would come out
`--rf`. None is known to; the ones that are known turn `--` into one dash.

**The prompt.** `$ `, `% ` or `# ` comes off every line only when every
non-empty, non-continuation line starts with the same one at column 0, *and*
what is left of each is shaped like a command (the first-word and
sentence-ending rules above; a `#` comment does not pass here). So a transcript
with output in it, `# A heading`, `# a comment, in words.` and `$ 5 each` are
left alone, and `$ $ ls` is not stripped once per paste. `> ` is never a
prompt. **The known cost:** `# install the deps`, a comment that reads as a
command, loses its `#`. A paste never presses Return, a multi-line one is held
in the sheet showing the stripped lines, and the notice says `removed "# "`.

**Trimming** drops leading blank lines and the whitespace at the end of each
line. Indentation stays, and so does an escaped space (`\ `) at a line's end.

**Order: tidy, then decide whether to ask.** The question is asked of the
tidied text and the sheet previews the tidied text, with a line saying what was
tidied. A line whose only tab was trailing asks nothing.

**It says so.** `pasted · straightened 4 quotes · removed "$ "`, in the pane's
notice line for five seconds, as the bytes go; nothing when nothing changed,
and nothing when the sheet was cancelled.

**⌥⌘V, Paste Without Asking, also skips tidying**: it is "the clipboard, as
copied". `paste_tidy = false` turns tidying off; it is read at each paste.

**No `as copied` undo.** The work item offered one, on condition: erase what
was pasted with that many backspaces *only if the far end echoed exactly the
pasted bytes*. That condition cannot be checked here. What comes back from a
prompt is not the bytes that went in: zsh with syntax highlighting, fish, and
any prompt with autosuggestions re-colour and redraw the line with escape
sequences as it grows; Claude Code and every other TUI repaint a whole input
box; a line that wraps is redrawn; a remote lane's echo arrives late and in
pieces mixed with other output; and the unit of erasure is the line editor's
idea of a character, not a byte. A matcher loose enough to pass those would
also pass cases where the backspaces eat the wrong thing, and in a shell a
wrong erase followed by a re-paste is worse than the untidied text ever was. A
multi-line paste has already run. So there is no action on the notice. The
way back is ⌃U (or the program's own clear) and ⌥⌘V.

## Consequences

- A capitalised command, or a script with one prose-looking line, is not
  straightened in a multi-line paste. The sheet shows it as it will go.
- Whoever builds a text paste from somewhere other than the pasteboard's
  string (middle-click, paste history) decides whether it is copied text by
  setting `isCopiedText`; the default is not.
- Reopen the undo if relay-tty ever reports the line editor's buffer, or the
  pane gains a reliable "prompt is empty again" signal (OSC 133).
