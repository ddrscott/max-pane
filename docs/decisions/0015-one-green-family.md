# ADR 0015 — One green family; BLOCKED is the brightest green, and it breathes

**Status:** Accepted · 2026-09-13
**Decides:** the app's colours for focus, state and every other highlight, and
how BLOCKED stays findable once it shares a hue with everything else.
**Evidence:** the work item
[`docs/work/green-palette.md`](../work/green-palette.md), whose roles are the
owner's and are not re-opened here; `PaletteTests.swift`; and the render sheets
from `./scripts/test.sh shots`, looked at in light and dark.

## Decision

**No orange anywhere.** The owner: *"I don't like the orange highlight color.
Let's ensure we stick with the green and shades of green so we're not too
colorful."* This overrides his global visual signature (Signal Orange as the
accent) for this project, on his instruction. A later change must not "restore"
the orange on the strength of that signature.

`Theme` names roles, each defined once, each with a dark and a light value:

| Role | Dark | Light | Carries |
|---|---|---|---|
| `working` | `#16A34A` | `#4D7C5F` | the filled status square, WORKING chip, a moving rate, load and download hairlines |
| `accent` | `#22C55E` | `#15773A` | the focus outline, default and `+ NEW` buttons, `//` slashes, the `$` marker, selection, drop indicators, the terminal cursor, the ⌘P flash, the lit toolbar switch |
| `blocked` | `#4ADE80` | `#166534` | BLOCKED chips, the `N BLOCKED` counts, the header's blocked mark, the memory bar's armed band |
| `onBlocked` | `#052E16` | white | the word on a filled BLOCKED mark |
| `alive` | `#2E8C4F` | `#6B9A7A` | a running session with nothing to say |

`Theme.flowing` and the inline green in `agentStateColor` were folded into
`working`. DONE stays slate and EXITED dim.

**The greens are told apart by form, not only shade.** Focus is an *outline*
around a pane. Working is a muted *filled* square. BLOCKED is the loudest, a
*filled* block, and *moving*. The header sheet's pair that must survive a glance,
a blocked unfocused lane next to a focused idle one, still reads apart in both
appearances: one has a bright block in its header and the other has none.

**The pulse** (`BlockedPulse`, `PulseLabel`) is a Core Animation opacity
animation on the render server, not a timer. One breath lasts 1.8 s and eases
between 100 % and 60 % opacity, so the mark never goes out. It runs on the
header's chip (word or `!`), the sidebar row's chip, a collapsed group's count,
the sidebar footer's `N BLOCKED`, and the status bar's attention count. The
label adds it when it enters a window and drops it when it leaves. Clearing the
blocked state removes it and eases back to full over `Motion.pane`. The
accessibility notification re-reads Reduce Motion live. Under Reduce Motion
there is no animation: BLOCKED is steady at full strength and marked by
brightness plus a fill.

Every animation starts at the phase the clock is in (`timeOffset = now mod
period`). This is not decoration. A sidebar row is rebuilt as a new cell when
its age ticks, and a pulse restarted from full on each rebuild would twitch once
a second. Phase-locking also means every blocked mark on screen breathes
together.

## Light mode has its own greens

The ticket's shades are dark-mode shades. On the light lane ground `#4ADE80` is
1.7:1 and `#22C55E` is 2.2:1, which fails as text and as a 1 pt outline. In light
mode the *order of loudness* is kept, but loudness there means contrast and
saturation, not lightness. So BLOCKED is the strongest ink of the three
(`#166534`, 7.0:1 on a lane), the accent is `#15773A` (5.5:1 on a lane, 4.9:1 on
the strip), and working is a greyed `#4D7C5F` (4.7:1 on a lane). The ticket's
suggested light accent, `#15803D`, is 4.4:1 on the strip's 0.94 ground, which is
under the bar. `PaletteTests` holds these numbers: accent and blocked text at
≥ 4.5:1 on both grounds in both appearances, working ≥ 4.0:1, the word on a
BLOCKED fill ≥ 4.5:1, and the order of loudness in each appearance.

## Where building it departed from the work item

- **The sidebar's BLOCKED chip is now solid**, not an 18 % tint. A tinted green
  word among green words was the collision this ADR exists to prevent.
- **The header's `!` glyph is filled too**, for the width at which the word does
  not fit. Otherwise, under Reduce Motion, a narrow blocked lane would show one
  more green character and nothing else.
- **ASKING shares the status bar's ink and breath.** It already shared the
  column because it is the same sentence (*something stopped and waits on you*).
  Two alarms in two greens would each be half as loud.
- **The ⌘P and ⌘O rows do not pulse.** Their BLOCKED chips and counts use the
  blocked green, but a list being read should not move under the reader, and
  it is open for seconds.
- **Two colours outside the family remain on purpose.** Amber (`#E0A010`, the
  web bars' `http://` and "no password saved" warnings) is a warning about the
  page, not a highlight, and a green there would read as *secure*. Red marks the
  memory bar past its hard limit, where a green would say the opposite of what
  is true. Neither is the removed accent, and neither is used for focus or
  state.

## Rejected

- **One value per role in both appearances.** Fails contrast in light mode, as
  above.
- **Pulsing by animating the background colour.** An animation's endpoints are
  snapshots, so a mid-pulse appearance switch would leave the old mode's green
  breathing until the next state change. Opacity has no colour in it, so the
  dynamic colours underneath keep following the appearance.
- **A timer.** It would run main-thread work for every blocked mark, including
  off-screen ones, and it would cost ten lanes ten timers.
- **Keeping orange for BLOCKED alone.** This is the "two loud hues" the owner
  asked to be rid of.

## Revisit if

- Relay's web client changes its BLOCKED colour and the owner wants the two to
  match.
- A fourth state needs a highlight. The family has no room for another shade
  that stays tellable apart, so it would need another form (a shape or a glyph),
  not another green.
