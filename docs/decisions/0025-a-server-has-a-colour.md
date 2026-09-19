# ADR 0025 — A server has a colour; the colour is the mark, and the name stays where nothing else says it

**Status:** Accepted · 2026-09-19
**Decides:** what marks a remote session now that the grey name chip has had a
day of use; what the colours are and why two suggested ones were dropped; where
the colour is stored, how a server gets one and how a change applies; where it
is picked; and what it is never allowed to touch.
**Amends:** [ADR-0023](0023-one-truth-per-server-and-the-server-chip.md) §5,
which put a grey `WSL` chip on every surface and refused a colour per server
"until the owner wants more after living with the chip"; and
[ADR-0015](0015-one-green-family.md), whose one green family gains a stated,
bounded exception. Everything else in both stands: one truth per server, what
disconnected looks like, greens for state, Signal Orange for DONE and nothing
else.
**Evidence:** the work item [`docs/work/server-colour.md`](../work/server-colour.md);
`ServerColourTests.swift` (the palette's distances and contrast, the TOML round
trip, the bad value, auto-assignment, the live change, every surface, the menu,
the socket op); the render sheets `server-colour-*.png` from
`./scripts/test.sh shots`, looked at in light and dark.

## The facts

1. **The owner, after a day with the chip (2026-09-19):** "I don't think we
   should remove the label of the server everywhere. Can't we use color coding
   or something? Add a submenu to the server's session bar and let the user pick
   a new color."
2. The chip was **too much where the context already names the server** — six
   rows under `// WSL`, each saying `WSL` — and **not enough as a glance-mark**:
   grey text in a grey outline among grey text.
3. ADR-0015 spends green on state and ADR-0023 kept the chip grey for that
   reason. That reasoning holds: a server's mark must not read as a state.

## Decision

### 1. One rule: a small solid square in the server's colour is the mark

`ServerMark`, defined once: a 9 pt square (8 pt on the sidebar row's 9 pt
second line), square-cornered, solid in the server's colour, tooltip the
server's name. It replaces the name where the server is already named nearby
and the name keeps its chip, tinted, where it is not:

| Surface | Shows |
|---|---|
| Sidebar header `// WSL` | the slashes in the server's colour; name, count and state chip unchanged (the chip is state: green) |
| Sidebar rows under it | the square on line two, where the chip was, so the row keeps its grid; **no name** |
| Lane header, and so the gallery tile | `ServerChip`, outline and text in the colour: the one place with no section above it. The square alone when the tile is under 0.6× (a 9 pt name is then under six points on screen) or the header cannot keep ten characters of title beside the name; the tile's square is drawn larger in lane points, as the focus outline is drawn thicker there, so it lands near its size on the strip |
| ⌘O and ⌘P rows | the tinted chip: those lists mix servers, so the name is needed |
| `// LOCAL`, local rows and lanes | unchanged. This Mac has no colour and no square |
| Offline | the square goes hollow — a 1 pt outline in the same colour at 0.55 alpha — and the chip's text and outline drop to the same alpha: still that server, visibly not live, in the shape ADR-0023 already gave "nothing vouches for this" |

The chip is an outline and never a fill: a filled block in a header is
BLOCKED's. No lane border, focus ring, status square or terminal content is
tinted; there is no single-edge rail and no gradient.

### 2. The palette, and the two colours that were replaced

Eight names, fixed, one value per appearance, defined in `Theme.server(_:)`:

| name | dark | light |
|---|---|---|
| `slate` | `Theme.dimText` | `Theme.dimText` |
| `cyan` | `#22D3EE` | `#006BA0` |
| `blue` | `#60A5FA` | `#1D4ED8` |
| `violet` | `#9F85FF` | `#6D28D9` |
| `magenta` | `#F06BE0` | `#B5179E` |
| `rose` | `#FB7185` | `#BE185D` |
| `lemon` | `#FDE047` | `#7A6200` |
| `ink` | `#F4F4F5` | `#18181B` |

`slate` is "no colour": exactly the grey chip ADR-0023 drew. The bar for the
other seven, held by `ServerColourPaletteTests` in both appearances:

- **ΔE\*ab (CIE76) ≥ 40** from `accent`, `working`, `blocked`, `alive` and
  `done`. Forty is "nobody would call these the same colour"; the closest pair
  that passed is light `lemon` to DONE at 42.
- **ΔE ≥ 25** between any two of the seven, so two servers are told apart.
- **4.5:1** as text on the lane ground and on the strip ground, because the
  chip's name is set in the colour at 9 pt.

The work item suggested `amber` and `teal`. Both failed, in numbers and in the
sheet: light amber (`#92400E`) is ΔE 18 from DONE's `#B84800` and dark amber is
ΔE 13 from the web bars' warning amber; light teal (`#0F766E`) is ΔE 16 from
`working` and dark teal ΔE 36 from `alive` — a teal square beside a green
status square is a second status square. The hue circle has no room left
between the greens and the orange, so the two replacements differ by lightness
instead: **`lemon`**, a yellow light enough (dark) or olive enough (light) to be
neither orange nor green, and **`ink`**, the strongest neutral — near-white in
dark, near-black in light — which no state uses. Light cyan was darkened from
`#0077A3` (4.4:1 on the strip) to `#006BA0`. `rose` takes its light value from
the pink side (`#BE185D`) because the red side was ΔE 38 from DONE. `pink`,
`indigo` and `sky` were each within ΔE 25 of a neighbour and were not added.

`lemon` in light mode is the weakest of the eight: an olive-brown, 42 from
DONE's burnt orange. It passed the bar and reads apart in the sheet, as a
square beside a DONE square and as a chip beside a DONE chip; if it is ever
confused in use it is the one to replace.

### 3. Stored in the file, assigned once, applied live

`color = "violet"` on the server's `[[servers]]` table — American in the file,
like every key — written in place by the TOML line editor with comments kept
(ADR-0012). Absent is `slate`. A value that is not one of the eight costs the
colour and nothing else: the server is kept, drawn in slate, the problem is
reported on that line with the eight listed, and the text is left for its owner
to fix.

**A server is never left indistinguishable by default.** `RelayServerBook.add`
gives a new server the first of the seven hues no other server has
(`ServerColour.firstUnused`; all seven taken, the least used). A table with no
`color` line — every table written before this ADR, the owner's `WSL` included
— gets one the same way the first time the book reads it, written to the file
once. A colour somebody chose is never reassigned, `slate` included, and
neither is a bad value.

**Live, through the one road everything about a server already takes.** A
colour is a line in the file; `ConfigStore` posts the change, the book
reconciles, `RelayServers.reload` — the one place a name meets its table —
publishes the colours to `ServerColours` and posts `ServerColours.didChange`.
Every `ServerMark` and `ServerChip` on screen hears that, re-reads its colour
and cross-fades (`Motion.fade`); the sidebar remakes its cells under the same
fade so the header's slashes follow; Settings redraws its swatches. A colour is
not an endpoint, so no source restarts and no lane re-attaches. A hand edit
takes the same road through the config watch.

The colour is looked up by name at the view rather than threaded through
`SidebarModel`, `LaneHeaderModel` and the pickers' candidates: three of the
surfaces (a ⌘O launch row, a ⌘P search hit, a lane restored while its server
was already gone) have no telemetry to carry it, so a lookup was needed
anyway, and one lookup is one truth. This is `ServerChip.hosts`' pattern, with
the one hazard of a process-wide map handled: a set of servers only ever
removes the names it put there.

### 4. Picked from the server's sidebar header

A **right-click on `// WSL`**, in the context menu every sidebar header already
has (the sidebar's headers have no `⋯`, so none was invented): **Color ▸** the
eight, each with its square and its name and the current one ticked; then
**Rename…**, **Disable**, **Server Settings…**; then the header's existing
Collapse All / Expand All. Each item calls what Settings › Servers calls —
`RelayServerBook.setColour`, `rename` (the ledger's half first, through the
same closure the settings window is handed), `setEnabled`, and the
`onOpenServer` a plain click already runs. There is no second code path.

The same control is on the server's row in Settings › Servers as eight square
swatches, the chosen one in a full-perimeter frame, and on the socket as
`maxpane server color NAME COLOR` (`server-color`; the app, not the CLI, knows
the eight and lists them in the refusal). `maxpane server ls` prints the colour
between the URL and the state.

### 5. With no server configured nothing changes, pixel for pixel

No mark or chip is built for a local session and `ServerColours` is empty.
Verified as ADR-0023 was: every sheet that renders only local things — lane
headers at three widths, the no-servers sidebars, the bookmarks bar, the
gallery, the toolbar, the popups — rendered before and after and compared
byte for byte.

## Rejected

- **Tinting the lane's border, header ground or focus ring.** Those are focus
  and structure, and a violet focus ring is a second meaning for the one mark
  that says "the keyboard is here".
- **A coloured rail down the sidebar rows of a server.** A single-edge rail is
  the thing this project does not draw, and it would sit beside the status
  square, which is state.
- **Colouring the status square.** It would make identity and state share a
  mark, and BLOCKED, working and DONE would stop meaning one thing each.
- **A free colour well.** Eight tested names survive both appearances and mean
  the same thing in a file on any machine; an arbitrary hex would be chosen
  against one ground and could be a green.
- **Deriving the colour from a hash of the name.** Two servers can collide, a
  rename would change the colour, and it cannot be argued with.

## Revisit if

- A colour is mistaken for a state in use: light `lemon` first.
- Someone runs more than seven servers and wants them all distinct. The family
  has no room for an eighth hue at these distances; it would need a second
  form (a glyph in the square), not another colour.
