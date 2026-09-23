# ⌃V with an image on the clipboard, in a remote lane, does what ⌘V does

The owner (2026-09-23): *"I have an image in my local buffer and I'm trying to
`ctrl-v` to a relay-tty session that's running a claude code session. Claude in
the remote session is stating I don't have an image in the clipboard."*

## Why

⌃V is Claude Code's own paste-image shortcut, and it reads the clipboard of the
machine it runs on. In a remote lane that machine is the box, which has no
image. Max Pane sends ⌃V through as the control character it is (literal-next
in a shell, page down in vim), so the keystroke reaches Claude Code and fails
honestly. ⌘V already does the right thing since ADR-0027: uploads the image
through the relay server and pastes the remote path. The muscle memory is ⌃V.

## Acceptance Criteria

- In a **remote** lane (a pane on a relay server), a ⌃V keystroke while the
  clipboard holds **an image and neither files nor text** is handled as ⌘V's
  image paste (`TerminalPaneController.paste(image:)` → upload → path), and the
  control character is **not** sent.
- Every other ⌃V is sent to the pty exactly as today: any text or file on the
  clipboard, an empty clipboard, a local lane (where Claude Code's own ⌃V
  works and must keep working), a terminal with mouse or key capture that
  wants the raw byte (no special-casing needed: the rule is only "image-only
  clipboard, remote lane").
- `paste_images_as_files = false` turns this off too; ⌃V is then always the
  byte.
- One notice line names what happened (`⌃V · uploading image to WSL…`), the
  same notice the ⌘V path shows, so the user learns the two are one.
- The decision is a pure function (`TerminalPaste.ctrlVIsImagePaste(isRemote:,
  clipboard:, settings:)`) with tests for each branch; the key interception
  lives beside Paste Slowly's Esc swallow in `ClickableTerminalView.keyDown`
  (check the byte: ⌃V is 0x16, and the event carries `.control` with `v`).
- README: one sentence in "Pasting into a terminal" under the image paragraph,
  and one in the remote section. CHANGELOG: Added.

## Constraints

- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
- Tests never touch `NSPasteboard.general`.
