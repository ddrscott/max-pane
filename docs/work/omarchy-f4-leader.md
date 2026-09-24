# A ⌘; leader with a which-key overlay, so the chords become a vocabulary

> **Rejected, 2026-09-23 — ⌘E covers it. See [ADR-0044](../decisions/0044-no-leader-key.md).**
>
> The finding predates ⌘E. Run Command now lists every one of the 83 commands
> by its menu name, with *the chord `[keys]` currently gives it* on the right
> and `—` for one with none, greyed with its reason when it cannot run, ranked
> over title, `keys` name and menu section — and **⌘⌫ on a row binds a real
> chord** through the same recorder Settings › Keyboard uses, refusing a
> collision by name. That answers "the chords are learnable, not guessable"
> by name rather than by prefix, which is strictly better for 83 items: you do
> not have to know the family letter, and the row *teaches you the chord you
> already have*.
>
> The count does not carry a second vocabulary. Of the five families the
> finding names, `t` theme has **no `Command` to alias** — ADR-0043 made the
> terminal theme two `Config` rows — and the other four (`d` dock 5, `p` paste
> 9, `s` sessions 6, `l` lane size 4) hold 24 commands of which **16 are
> already chorded**. The 8 that are not are exactly the ones `Commands.swift`
> argues, case by case, should not be, each closing with the same sentence:
> "`keys` binds it." A leader gives those eight a *third* route to something
> whose first route is a config line the file already tells you to write.
>
> Three costs the finding did not see. (1) The families cut across the six
> `MenuSection` cases and cannot be generated from anything that exists, so
> the mapping would be **hand-kept** — the exact flaw § 2 of the same critique
> praises this app for not having ("⌘/ is generated from the enum so it cannot
> drift; Super+K is a hand-kept list"); auto-derived letters are worse, since
> three `laneSize*` want `l` and a sequence that moves when a command lands is
> worse than no binding. (2) "Reuses the ⌘/ renderer so the two cannot drift"
> is not available: `HelpPanel.body()` builds one `NSAttributedString` with
> `heading`/`row` as local closures, so the guard would first cost an
> extraction. (3) `"cmd+; d l"` does not parse — `KeyChord.init?` is
> single-chord — and whitespace already means **alternates** in `[keys]` and
> in Settings › Keyboard's field, so a sequence needs a separator meaning the
> opposite of what it means on the same surface.
>
> Its one novel capability nets zero: reaching a command in a web pane whose
> chord the page eats covers exactly the four `yieldsToPage` commands, and all
> four are terminal business, grey or meaningless in a web pane.
>
> ⌘; itself is free — nothing in `Commands.swift` or `Keymap.reserved`, no
> macOS chord in an app with no Spelling menu — and takes ⇧⌘; with it through
> `Keymap.shifted`. Recorded so the next reader does not re-derive it; it was
> never the reason.
>
> What would change the answer is in the ADR's last paragraph.

From the Omarchy critique, [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F4. Read that finding in full; it is the spec (what Omarchy does, what Max Pane does today with citations, the gap, and the change with its acceptance criteria and size).

## Notes beyond the finding

- **This is the most speculative item in the critique and the one the owner is most likely to veto.** It adds a second way to reach commands that already have chords and a picker (⌘E). Before building: re-read the finding, look at how many commands would actually hang off a leader, and if the honest answer is that ⌘E already covers it, **reject the task** (`- [~]` with the reason) rather than building a vocabulary nobody asked twice for. A rejection with a paragraph of reasoning is a good outcome here.
- If you build it: every leader sequence is an alias for an existing `Command`, spelled in `[keys]` as `"cmd+; d l"`; nothing existing moves or is removed. The overlay is 300 ms delayed, square, mono, `// LEADER`, at the foot of the focused lane, and reuses the ⌘/ renderer so the two cannot drift. Esc cancels; an unknown key shows `? no such key` and stays. Web panes never see the sequence. ⌘; must be checked against `Commands.swift`, `Keymap.reserved` and macOS.

## Constraints (every Omarchy-round task)

- The finding is the spec; where it is silent, the app's own conventions decide
  (README, the ADR index, `Commands.swift` for command/key/menu/⌘/ sheet).
- **The critique predates F3**: where it says `⇧⌘P`, the command picker is
  **`⌘E` Run Command** (commit `f1dfaca`, the picker's APP scope). Add rows
  there, not to a chord that no longer exists.
- Identity: greens for state, Signal Orange only for DONE, grey at rest, square
  corners, `// CAPS` headers, JetBrains Mono, no bubble cards, no single-edge
  rail, no new colour family; no instant transitions (`Motion.*`).
- Every new command: in `Commands.swift`, rebindable under `[keys]`, in a menu,
  in the ⌘/ sheet and in ⌘E; check the chord against existing ones,
  `Keymap.reserved` and macOS.
- Tests as the app tests things (models pure; real-surface/WebKit where the
  claim is about one); render sheets where a surface is new, looked at.
- README section, CHANGELOG entry, ADR only for a decision worth reopening.
- The owner's app is installed and RUNNING at /Applications/MaxPane.app and he
  is using it. Do not quit, replace or launch any MaxPane; build to
  `MAXPANE_APP=build/verify.app` and do not run it. The orchestrator installs.
- Never capture `self` weakly in a callback on an object nobody else holds.

