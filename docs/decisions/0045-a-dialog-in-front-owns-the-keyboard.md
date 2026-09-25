# ADR 0045 — A dialog in front owns the keyboard

**Status:** Accepted · 2026-09-25

## What happened

The owner: *"When using ⌘O and then ⌘V the paste goes to the background pane
instead of the foreground dialog! I think this is a fundamental issue with all
dialogs where input is missed by the dialog. Please correct this once and for
all."*

He was right that it was one issue. Two routes let what you type into a dialog
reach the strip behind it.

**The Edit menu's routed actions.** ⌘V is not a plain `paste:`. It first sends
`pasteIntoTerminalPane:` down the responder chain with no target, so a terminal
can take the paste the safe way (`TerminalPaste`), and falls back to `paste:`
only when nothing answers. ⌥⌘C, copy mode, the Paste Special items and ⌘C in a
web pane work the same way (`TerminalPasteTarget`, `TerminalCopyTarget`,
`WebCopyTarget`). AppKit resolves a nil-targeted action by searching the
**key** window's responder chain and then the **main** window's. The ⌘O picker
is a key panel over the strip, so when its field did not claim the routed
action, AppKit went on to the strip window. The strip window's first responder
does not change when a panel takes the keyboard; only which window is key
does. So its first responder was still the terminal, the terminal's container
answered, and the paste landed there. A sheet laid over a pane had the same
fault from the other side: the pane's container sits up the responder chain
from the sheet's text boxes, so it answered first.

**The menu's strip commands.** Nothing in `canPerform` asked which window had
the keyboard, so ⌘W with the picker open closed the lane behind it, and ⌘J
moved focus behind it. The key monitor for second chords and web-app chords
already refused while a palette was up (`installAlternateShortcuts`: *"a
palette on screen owns the keyboard"*). The rule was known; it had not reached
the menu.

Advanced Paste had found the first route and patched it for itself, by
implementing the terminal's routed paste so it answered first. That one-sheet
fix is the pattern this ADR ends.

## Decision

**A pane takes a routed Edit-menu action only while it has the keyboard**:
its window is the key window, and that window's first responder is the pane's
own view or something inside it (`keyboardIsIn`). Each container answers
`responds(to:)` with that for its routed protocols' methods, recognised by
protocol so a method added later is covered. Declining in `responds(to:)`
rather than taking the action and doing nothing matters: AppKit's search goes
on to whatever does have the keyboard, `sendAction` reports that no terminal
took it, and the Edit menu's plain `paste:` reaches the picker's field or the
sheet's box.

**From the menu, a strip command runs only while the strip's window is key**
(`canPerformFromMenu`). Commands in the app menu and Help run from anywhere.
`canPerform` itself is unchanged, because the ⌘E picker is a key panel whose
whole job is to run strip commands and it asks `canPerform` about each row.

Advanced Paste's own copy of the routed paste is gone; its test now asserts
that nothing answers from its text box.

## What was rejected

- **Patching each dialog.** That is what Advanced Paste did, and every new
  picker, sheet and popover would need the same patch, written by someone who
  had first hit the bug.
- **Checking inside the action and doing nothing.** `sendAction` would still
  report that a terminal took the paste, and the Edit menu would not fall back
  to `paste:`, so the dialog's field would get nothing.
- **Gating `canPerform`.** It would grey every row of ⌘E, which is itself a key
  panel.
- **Moving focus to mouse-up, or Esc-first dismissal.** Not the problem: the
  keys were reaching the wrong window, not arriving at the wrong time.

## Consequences

- A picker, sheet, popover, confirmation or another window in front gets
  ⌘V, ⌘C, ⌘X and ⌘A, and the strip does not.
- Strip commands grey out in the menu while something else has the keyboard.
  With Settings or History in front, ⌘W no longer closes a lane; it does
  nothing, since those windows have no close command of their own. Click the
  strip first to run a strip command.
- Commands run by the CLI, the control socket and ⌘E's own rows are not keyboard
  input and are unaffected.
- Tests use a window that reports key when told to, since test windows never
  are; in an ordinary one the window half of the rule declines every case and
  the first-responder half would never be exercised. With the gate switched
  off, the picker test fails on all five terminal actions, which is the
  reported bug.

## What would make us revisit

A dialog that genuinely wants a strip command to reach past it. Then that
command belongs in `isAppLevel`'s set, or the dialog forwards it explicitly;
the default stays that the dialog owns the keyboard.
