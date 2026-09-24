# ADR-0042: A chord per web app — `[[apps]]`, refused rather than taken

**Status:** Accepted
**Date:** 2026-09-23
**Context:** [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F8

## The problem

Omarchy's "Install › Web App" gives a page a `Super+Shift+E` of its own, and
what makes such a key worth learning is that it means one thing forever. Max
Pane had no such thing. A bookmark is a ★ row in ⌘O and `⌘4` opens the fourth
row **of the current ranking** — which is a different page every hour. Nothing
in the app was "go to Gmail" whether or not Gmail was open.

## The decision

`[[apps]]` in `config.toml`, the third array of tables after `[keys]` and
`[[servers]]`: `name`, `url`, optional `key`, optional `docked = "left" |
"right"`. The chord **focuses** the lane that app is already on and opens one
only when there is none, so pressing it twice is pressing it once.

### Refused, not taken

The keymap now has two sources. `[keys]` resolves first, exactly as it did —
configured commands, then defaults — and `[[apps]]` is laid down over the
result. A chord a command already holds is **refused to the app and named**
(`⌘G: the app Gallery does not get it — toggleGallery has it`), as is one
`Keymap.reserved` lists and one an earlier `[[apps]]` table took.

The alternative — the app wins, the command yields, which is what `[keys]`
itself does for a key you set over a key that was only a default — was
rejected. A command's chord is in the menu bar and on the ⌘/ sheet; an app's
is in neither, so an app quietly taking ⌘G would leave the Gallery item
advertising a key that no longer fires, which is the exact failure the whole
keymap file exists to prevent. Refusal costs the app its key and nothing else:
it keeps its row in ⌘E, its line in Settings and its name on the control
socket, because an app you cannot reach by key is still an app you want to
reach. Each of the three refusals is one line on stderr and one line on that
app's Settings row.

Because a chord is never shared with a command, there is nothing for
`Command.yieldsToPage` to arbitrate: an app's ⌘-chord goes into `Keymap.claimed`
whole, its shifted-punctuation twin included, and a page never sees it — the
same rule, and the same reason, as ⌘O.

### Matched by registrable domain

"The lane it is already on" is decided by `ContentBlocker.domain(of:)`, the
eTLD+1 rule the per-site ad-blocking exemption already switches on. **No second
matcher**: one that could disagree with the blocker's about what `bbc.co.uk` is
would be worse than either. Exact-URL matching was rejected for opening a
second Gmail lane the moment you click into a message. The cost is stated
rather than hidden: two apps under one registrable domain (`docs.google.com`
and `mail.google.com`) find each other's lanes, which is the honest reading of
a rule expressed in domains.

**Several matching lanes: the most recently focused** (`lastFocusAt`, what
eviction and ⌘P already rank by). Not the leftmost, which would make the chord
depend on where a lane happens to sit; not the newest, which sends you to the
copy you have never looked at.

`docked` applies only when the chord *opens* the lane. A lane already up is
focused where it is — the chord goes to the app, it does not rearrange the
strip behind it, so a lane you undocked stays undocked.

### Read at launch

Names, addresses and `docked` apply the moment the file is written, like a
server's. The **chord** is read at launch, like `[keys]` and for the same
reason (the menu bakes its key equivalents at `buildMenu`), so a changed one is
marked `relaunch to apply` in Settings and in ⌘E.

## The surfaces

`// APPS` in the ⌘/ sheet, listing only the apps that got a key — the one part
of that sheet that comes from the reader's file rather than from the binary,
which is why `HelpPanel.body(apps:)` takes it as a parameter. **Settings ›
Apps**: name, address, the chord with the same `rec` / `none` recorder the
Keyboard section has (`ChordRecorder`, now reached through a `ChordRecording`
row protocol so one key monitor serves both kinds of row), and `strip | left |
right`. **⌘E** lists every app, chord on the right, `—` for none, and the
second line saying whether ↩ will `focus` or `open`; ⌘⌫ records a chord into
`[[apps]]`. **`maxpane app NAME`** on the control socket, resolving a name
exactly first and then as the only prefix that fits, and printing whether it
focused or opened.

## Rejected

- **A `Command` case per app.** `Command` is an enum in the binary and the
  guarantee that every action declares a key; a set that changes with a config
  file cannot live there.
- **Beside the pages in ⌘O.** ↩ on an app is not ↩ on a page — it goes to a
  lane when one exists. Two rows that look alike and behave differently is
  what the scopes exist to keep apart.
- **An icon, and an "Install Web App" wizard.** Omarchy's version installs a
  desktop entry with an icon it fetches. Four lines of TOML and a Settings
  section is the whole feature here; a lane already wears its page's title.

## What would make us revisit

An owner who wants an app's chord to beat a command's — a real case would be a
command they never use on a key they want. The mechanism is one branch in
`Keymap.init(overrides:apps:)`, and the complaint already names both sides.
