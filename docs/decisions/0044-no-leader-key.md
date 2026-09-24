# ADR 0044 — No leader key: ⌘E is the second vocabulary, and one is enough

**Status:** Accepted · 2026-09-23
**Decides:** that Max Pane does not get a `⌘;` leader with a which-key
overlay; that a command reached by name in ⌘E, and bound to a real chord
from there, is the whole of the answer to "the chords are learnable, not
guessable"; what would reopen this.
**Evidence:** the Omarchy critique
[`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F4 (the proposal) and
§ 2 (*"⌘/ is generated from the enum so it cannot drift; Super+K is a
hand-kept list"*); the work item
[`docs/work/omarchy-f4-leader.md`](../work/omarchy-f4-leader.md), which carries
explicit leave to reject itself;
[`docs/work/omarchy-f3-run-command.md`](../work/omarchy-f3-run-command.md) and
the ⌘E it shipped (`f1dfaca`; README › Run Command), which took no ADR of its
own and is half the reason this one exists; ADR-0042 (the keymap's second
source);
`Commands.swift` (83 cases, `defaultShortcut`, `yieldsToPage`, `MenuSection`);
`Keymap.swift` (`KeyChord.init?(_:)`, `KeyBindings`, `reserved`, `shifted`);
`Views/AppScope.swift`, `Views/OmniPicker.swift` (the APP scope and ⌘⌫);
`Views/HelpPanel.swift` (`body()`); `StripWindowController.installAlternateShortcuts`.

## The problem

F4 is the one finding in the Omarchy round that asks for a *second way to
press a key that already exists*. Omarchy reaches every action from one
modifier; Max Pane spends seven modifier flavours (`⌘`, `⇧⌘`, `⌥⌘`, `⌃⌘`,
`⌃⇧⌘`, `⌥⇧⌘`, `⌃⌥⌘`), so `[` and `]` carry four meanings and the paste
family spans five chords. The proposal: `⌘;` opens a 300 ms which-key
overlay at the foot of the focused lane, families by letter (`d` dock,
`p` paste, `s` sessions, `l` lane size, `t` theme), each sequence an alias
for an existing `Command`, spelled `"cmd+; d l"` in `[keys]`.

The critique was written before F3 landed. ⌘E now lists **every** command by
the name the menu gives it, with **the chord `[keys]` currently gives it** on
the right and `—` for one with none, greyed with its reason when it cannot
run, ranked over title, `keys` name and menu section — and **⌘⌫ on a row binds
a chord to it** through the same recorder Settings › Keyboard uses, refusing a
collision by name. So the question this ADR answers is not "is a leader nice"
but "does a leader earn a second vocabulary now that ⌘E exists".

## Decisions

**No leader. The count does not justify one.** `Command` has 83 cases; 64
ship with a chord and 19 without. Of the five families F4 names:

| family | commands | already keyed |
|---|---|---|
| `d` dock | 5 | 5 |
| `p` paste | 9 | 4 |
| `s` sessions | 6 | 6 |
| `l` lane size | 4 | 1 |
| `t` theme | **0** | — |

Twenty-four commands, sixteen of them already on a chord the menu bar and ⌘/
advertise. The eight that are not are precisely the ones `Commands.swift`
argues, case by case, should not be — *"reached for a few times a month, from
the menu, by name"*, *"flipped once for the one site whose page a rule breaks,
and then left"* — each closing with the same sentence: **"`keys` binds it."**
A leader would give those eight a third route (menu, ⌘E, leader) to something
whose first route is a config line the file already tells you to write. And
`t` theme has no `Command` to alias at all: after ADR-0043 the terminal theme
is `terminal_theme_dark` / `terminal_theme_light`, `Config` rows reached from
Settings › Appearance and a `THEMES` section in ⌘E. One of the five families
the spec names cannot be built as the spec spells it.

**A leader would be hand-kept, which is the flaw the critique itself names.**
§ 2 of the same document praises this app over Omarchy because *"⌘/ is
generated from the enum so it cannot drift; Super+K is a hand-kept list."*
Everything keyboard-facing here is derived: the menu bar, ⌘/ and ⌘E's sections
all come from `Command.menu`, six `MenuSection` cases. F4's families are a
*seventh taxonomy* that cuts across those six — dock lives in Navigate and
View, paste in Edit, lane size in View — so it cannot be generated from
anything that exists. Someone assigns `d l`, keeps 83 sequences collision-free,
and keeps them right as commands are added. That is Super+K, reintroduced
inside the app that was better than Super+K. Auto-deriving the letters was the
tempting escape and is worse: `laneSizeSmall`, `laneSizeMedium` and
`laneSizeLarge` all want `l`, and a sequence that silently moves when a new
command lands is a binding worse than no binding.

**The overlay cannot "reuse the ⌘/ renderer", so the drift guard in the spec
is not available.** `HelpPanel` is an `NSTextView` of one
`NSAttributedString` built by `body()`, whose `heading`/`row` are local
closures inside that function; there is no row renderer a second surface can
call, and an attributed-text blob cannot be filtered to one family. The
promise that "the two cannot drift" would first cost an extraction of
`HelpPanel.body()` into a row model — real work, for a surface whose reason
for existing is the argument above.

**The spelling collides with the grammar that ships.** `KeyChord.init?(_:)`
is single-chord only: `"cmd+; d l"` fails to parse and is reported *"is not a
chord"*. `KeyBindings` already spends both of its shapes — a string is one
chord, a list is **alternates** (`openAnything = ["cmd+k", "cmd+t"]`), and
Settings › Keyboard's field splits on whitespace to mean *alternates* too. A
sequence needs a third shape whose separator means the opposite of what the
separator already means on the same surface.

**The one thing a leader would genuinely add is worth nothing.** Its novel
capability is reaching a command inside a web pane whose chord the page eats.
Exactly four commands yield to a page (`yieldsToPage`): `advancedPaste`,
`copyWithStyles`, `copyMode`, `clearScrollback`. All four are terminal
business — `Commands.swift` says of `advancedPaste` that in a web pane "the
command, which has nothing to do there, is grey", and the other three are a
terminal's copy, its copy mode and its clear. The leader would rescue, in a
web pane, four commands nobody wants in a web pane.

**⌘; is free, and that is not a reason.** Neither `Commands.swift` nor
`Keymap.reserved` holds it, no macOS chord claims it in an app with no
Spelling menu, and no page's chrome does. Recorded here so the next reader
does not re-derive it — and with one trap: `Keymap.shifted` maps `";"` to
`":"`, so anything taking ⌘; takes ⇧⌘; with it.

## Consequences

- Nothing is built and nothing moves. Every chord, menu item, ⌘/ row and ⌘E
  row is exactly where it was.
- The app keeps **one** keyboard vocabulary: a chord per command, declared in
  `Commands.swift`, moved by `[keys]`, shown by the menu bar and ⌘/, and
  searched, taught and *bound* by ⌘E. The answer to "I cannot guess the chord"
  is ⌘E and the name; the answer to "I want this on a chord" is ⌘⌫ on that row.
- `Command.menu` stays the only grouping, so the six sections remain the one
  thing that has to be right when a command is added.
- F4 joins the critique's § 4: not worth doing, for this app, at this count.

**What would reopen it.** Any of: the owner reporting he hunts the menu bar
for the *same family* repeatedly rather than typing a name; a modal surface
arriving whose natural entry is a prefix (copy mode already has a keyboard of
its own, and a second such mode would make a leader the obvious door); command
count growing past what naming can serve, where "which of these forty is it"
beats "what is it called"; or a family whose members genuinely have no useful
names, which is the case a which-key overlay is actually for.
