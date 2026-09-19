# A server has a colour; the colour is the mark, and the label stays where it is needed

The owner, after a day with ADR-0023's grey `WSL` chip on every remote row
(2026-09-19):

> I don't think we should remove the label of the server everywhere. Can't we
> use color coding or something? Add a submenu to the server's session bar and
> let the user pick a new color.

## Reading of it

The text chip on every surface is too much where the context already names the
server, and not enough as a glance-mark. Colour carries identity at a glance;
the label remains where there is no other context. So: **each server has a
colour, chosen from a submenu on its sidebar header; the colour marks
everything that belongs to that server; the name appears once per context, not
once per row.**

This amends ADR-0023 (which refused a colour per server "until the owner wants
more after living with the chip" — he has) and carves a stated exception out of
ADR-0015's one green family: state is still green, DONE is still Signal Orange,
and a server colour is *identity*, never state. Write ADR-0025 saying so.

## Acceptance Criteria

### The colour

- A fixed palette of eight, defined once (`ServerColour` or similar), each with
  a light-mode and dark-mode value tuned for contrast on the sidebar and lane
  header backgrounds, none of them confusable with the state greens
  (`Theme.accent`, the alive/blocked greens) or Signal Orange `#E85D00`:
  suggest `slate` (the default: today's at-rest grey, i.e. "no colour"),
  `cyan`, `blue`, `violet`, `magenta`, `rose`, `amber`, `teal`. Check each
  against the greens and the orange side by side in a render sheet and replace
  any that read as state.
- Stored as `color = "violet"` on the server's `[[servers]]` table in
  `config.toml` (American spelling in the file, to match every other key),
  default absent = `slate`. Bad value: reported on that row the way the schema
  reports any other, falls back to `slate`. Applies live through
  `RelayServerBook`/`ConfigWatch` like every other server edit, no relaunch.
- A new server gets the first palette colour no other server is using, so two
  servers are distinguishable without anyone opening a menu. (The owner's
  existing `WSL` entry has none set: it gets one assigned on first load and
  written to the file.)

### Picking it

- **A menu on the server's sidebar header** (`// WSL`): right-click, and a `⋯`
  affordance on hover if the local group headers or lane headers have one to
  mirror (follow what exists; do not invent a new control). Items: **Color ▸**
  a submenu of the eight, each with a small square swatch and its name, the
  current one ticked; then **Rename…**, **Disable**, **Server Settings…**
  (opens Settings › Servers on that row, which a plain click on the header
  does today). Reuse the actions Settings already has; no second code path.
- The same colour control appears on the server's row in Settings › Servers
  (a row of eight square swatches), so it is discoverable from there too.
- `maxpane server color NAME COLOUR` over the control socket, so it is
  drivable without the screen, and `maxpane server ls` prints the colour.

### Where the colour shows

One rule: **a small solid square in the server's colour is the mark.** It is
the same 8–9 pt square everywhere, defined once, replacing the grey text chip
on surfaces where the server is already named nearby, and *preceding* the name
where it is not.

| Surface | Today (ADR-0023) | Now |
|---|---|---|
| Sidebar server header `// WSL` | green slashes, grey name | the slashes in the server's colour, the name as today, the state chip unchanged (still green: it is state) |
| Sidebar session rows under a server | grey `WSL` text chip on line two | **no text chip.** The row is already under `// WSL`. The colour square sits on line two where the chip was, or leads the row, whichever keeps the row's grid; tooltip is the server's name |
| Lane header | grey `WSL` chip beside the path | the chip stays, **tinted**: outline and text in the server's colour, preceded by nothing. This is the one place with no section context, so it keeps the label |
| Gallery tile header | same chip | same as the lane header; when the tile is too small for text, the square alone |
| ⌘O and ⌘P rows | grey chip leading the detail line | the tinted chip, as the lane header: these lists mix servers, so the name is needed |
| `// LOCAL` | green slashes | unchanged; local has no colour and no square |
| Offline rows/lanes | grey, hollow | the colour square goes hollow (outline only) in the same colour at reduced alpha: still identifiable, visibly not live |

- Do not tint terminal content, lane borders, focus rings or the status
  square: those are state or focus and stay as they are. No single-edge
  coloured rail anywhere. No gradients.
- With no servers configured, the app is unchanged pixel for pixel (the
  existing byte-compare of local sheets still passes).
- Transitions: a colour change cross-fades (`Motion.fade`), never snaps.

## Tests

- Palette: eight entries, each distinct from the greens and the orange by a
  stated minimum colour distance in both appearances; the default is slate.
- Config: round trip through the TOML line editor with comments intact; bad
  value falls back and is reported; auto-assignment picks an unused colour and
  writes it once; live change reaches the sidebar model, lane header model and
  ⌘O rows without a relaunch.
- Surfaces: the table above, per surface, in the model tests; the chip is
  absent from rows under a server section and present (tinted) in lane header
  and ⌘O rows; offline is hollow.
- The menu: items present, current colour ticked, each action calls the same
  entry point Settings uses.
- The socket op and its CLI parse.
- Render sheets (`MAXPANE_SHOTS`): the sidebar with two servers in two
  colours, connected and offline; lane headers in each of the eight; the
  palette beside the greens and the orange, light and dark. Look at them and
  say what you saw, including any colour you replaced.

## Docs

README "Remote servers" (the colour, the menu, the CLI line, the `color` key),
the settings reference, CHANGELOG (Changed: the row chip became a colour
square), ADR-0025, and a one-line amendment note at the top of ADR-0023 and in
ADR-0015's "what would make us revisit".

## Constraints

- The owner's app is installed and running; he is using it remotely. Do not
  quit, replace or launch any Max Pane. Build to `MAXPANE_APP=build/verify.app`
  and do not run it. The orchestrator installs.
- His config has a server named `WSL`; do not edit his `config.toml` from
  your shell. Tests use their own config directories.
