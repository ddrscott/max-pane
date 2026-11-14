# ADR 0049 — Dictation is a box in front of the terminal

**Status:** Accepted · 2026-11-14

## What happened

The owner wanted to talk to his agents: *"Apple dictation into a text area
that makes it easy for me to edit the dictation details (or not). Then type
the results into a terminal session."* A hot key (F5, or the microphone key)
opens it and starts listening, Esc stops, Send types it, Send One Line strips
the returns the way the paste handler does, and past entries can be recalled,
edited and sent, an edit being a new entry.

Dictating straight into a terminal already works, and is the problem: the
system types each word into the pane as it's recognized, and an agent's
prompt reads a misheard word before anyone can take it back.

## Decision

**A popup with a plain text box, Apple's own dictation, and a history list
beside it.** Esc stops listening and a second Esc closes; ⌘↩ sends;
⇧⌘↩ sends as one line (`TerminalPaste.oneLine`, the same join Paste as One
Line uses). What's sent goes through the pane's paste door with `asking:
false`, as Advanced Paste's does, for the same reason: the box was the
question.

**Apple's dictation, not the Speech framework.** `NSApplication` answers
`startDictation:` and `stopDictation:`, the actions Edit › Start Dictation
sends, and the system types into whichever text view is first responder. That
means no microphone or speech-recognition permission, no entitlement, no
`NSMicrophoneUsageDescription`, and the language, vocabulary and on-device
model the person already set up in System Settings. The cost is that the app
can't ask the system whether it's listening: the popup keeps its own flag,
set when it starts and cleared when it stops. If dictation ends some other
way (the system's own key, a timeout), the flag says listening until the next
Esc, which then stops nothing and a second Esc closes. It's one extra key
press in a rare case, against owning a recognizer.

**History is its own table, not paste history.** Paste history is what a pane
sent, capped by age and netted for secrets so a token never reaches the disk.
Dictation is speech you may want to say again, edited, into another pane: a
recalled `•••` would be useless, and age is the wrong cap for phrasing you
reuse. So migration 0020 adds `dictation` (id, content, at), capped by count
(`dictation_history_keep`, 200), refused for a private lane's pane, blank text
or over 64 KB. What a send types still lands in paste history, through the
pane's paste, like any paste.

**Nothing said is lost.** A send keeps the text as it stood (lines, not the
one-line join). A close keeps the box when it isn't blank and isn't exactly
the entry it was loaded from. Recalling an entry keeps whatever the box held
first. The same text again moves to the top, so an entry recalled and sent
unchanged rises, and one recalled and closed untouched doesn't move.

**F5, with the microphone key as an alternate.** F5 is free in macOS and in
this keymap. It has no ⌘, so it's matched in the window's key monitor and not
carried by the menu, like Esc. F-keys became named keys (`f1`–`f12`) so the
config file and the ⌘/ sheet can spell them, and a chord's mask now keeps
only ⌘ ⌃ ⌥ ⇧: an F-key arrives with `.function` set and Caps Lock adds
`.capsLock`, either of which made a typed chord unequal to the declared one.
The microphone key has no character; it's matched by key code 176 and spelled
`mic` (`🎤` in the sheet). macOS normally keeps that key for its own
dictation, and then the app never sees it. So the strip window also answers
`startDictation:` on its way up the responder chain: with a terminal's
keyboard it opens Dictate, and anywhere else it passes on to the system.
Whether the microphone key itself travels that road was not measured when
this was written.

## Consequences

- One more popup that is `.explicitOnly`: a click on the strip doesn't close
  it, because it's listening to you and the click may be to read the agent.
- One more ledger table and setting. Clear Paste History doesn't touch it;
  `dictation_history_keep = 0`, or ⌘⌫ per entry, does.
- Dictate needs a terminal with the keyboard. Dictating into a page is the
  system's, unchanged.
