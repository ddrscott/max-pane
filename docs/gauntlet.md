# Gauntlet — functional parity with the RelayTTY web app

**Goal (Scott, verbatim):** "We should be at least as functional as Relay TTY
web app." And, on what it is *for*: "I do use it every day already and want to
make it Mac native so I can have browser panes with the shell panes."

That second sentence is the product. Max Pane is not a new thing competing with
RelayTTY — it is **RelayTTY's daily workflow, native, with web panes as peers**.
Which sets the acceptance test: Scott moves over and does not miss anything.

**The bar, in two parts:**

1. `docs/bar-relaytty.png` — his *actual* workspace: ten live sessions, three
   terminal columns. What matters in practice, not in principle.
2. **`~/code/relay-tty` itself** — Scott has opened the source as reference. The
   bar is therefore not "what one screenshot shows" but **every capability that
   app has**, inventoried in
   [`reference/relaytty-web-features.md`](reference/relaytty-web-features.md).

**Stop condition:** Scott stops the run. Not a round count.

**Why the daily-driver framing changes the ranking:** a feature Scott touches
every day and a feature that exists are not the same weight. The inventory ranks
by "what would a heavy user notice missing within a day", and rounds are ordered
by that ranking, not by what is easy.

---

## What the bar actually demonstrates

Read off the screenshot, not from memory.

### Sidebar — a session *browser*, not a list

| | |
|---|---|
| `+ New` · shuffle · filter · `↑↓ Created` | actions and sort, always visible |
| `▼ ~/code/max-pane` … `1 running` | **grouped by project directory, always**, with a running count per group, collapsible |
| `● ◑ Pane terminal s…` `1.7KB/s` `6s ago` | status dot · agent-state glyph · title · **live throughput** · **relative age** |
| `● ✻ trifecta ask` `idle` `13h ago` | when not moving, the throughput slot shows the **agent state** instead |
| `v1.21.0` ⚙ | version and settings, pinned to the bottom |

### Toolbar

`☰` · six view modes · **`10 sessions`** · split controls · `↓ Created` · `🗂 All projects` · fullscreen · `+`

### Pane header

`● ✻ Latest commit changes` ………… `/Users/spierce/code/trifecta-…` `⋯`

status dot · agent glyph · title · **full cwd path, right-aligned** · **overflow menu**.
The focused pane carries a coloured border.

---

## Judging while the screen is locked

The method wants critics to judge pixels. macOS will not composite windows while
the screen is locked — `screencapture` returns black and the accessibility API
reports zero windows, even though the app is running fine and answering
`maxpane ls`. Verified, not assumed.

So a critic has two modes, and must say which it used:

- **Visual** (screen unlocked): screenshot the running app beside the bar, blind
  A/B, pick the better one. The real thing.
- **Functional** (screen locked): drive the app through `maxpane` and the
  ledger, read the code, and judge against the *inventory* — can the capability
  be reached at all, with what metadata, in how many keystrokes. This catches
  missing function but says nothing about whether it looks right.

A functional pass is never a substitute for a visual one. It is what can be done
meanwhile.

## What this parity means — and what it does not

**Functional parity, not a visual clone.** Max Pane has its own identity —
square corners, Signal Orange, JetBrains Mono, `// CAPS` section headers — and
that is not up for negotiation. RelayTTY uses rounded cards and blue accents;
copying those would be a regression, not parity.

So the question every critic asks is:

> **Can you see and do, in Max Pane, everything the RelayTTY screenshot lets you
> see and do — at the same glance-ability?**

Not "does it look the same".

---

## The gap, round 0

Measured against the bar before any work:

| Capability the bar has | Max Pane, round 0 |
|---|---|
| Sessions grouped by project, always, with running counts | flat list; groups only past 50 lanes |
| Status dot per session | none |
| Agent state (idle / active / done) | none |
| Live throughput (KB/s) | none |
| Relative age ("6s ago", "13h ago") | none |
| Session count | none |
| `+ New` in the UI | keyboard only |
| Sort control | none — ordinal only |
| Version / settings footer | none |
| cwd path in the pane header | project basename only |
| Pane overflow menu | none |
| Attach picker showing all sessions grouped | flat list, no metadata |

Every one of those facts is already in `~/.relay-tty/sessions/*.json` or on the
wire (`SESSION_STATE` 0x12, `SESSION_METRICS` 0x14). Max Pane reads almost none
of it. That is the round-1 foundation.

---

## Decomposition

Lead's split. Piece 1 is the data everything else displays, so it lands first;
2–5 then run in parallel, each with its own builder and its own fresh-context
critic that looks at screenshots of the running app beside the bar.

| # | Piece | Depends on |
|---|---|---|
| 1 | **Session telemetry** — agent state, throughput, activity age, liveness, cwd, flowing from Relay into the UI | — |
| 2 | **Sidebar** — grouped session browser with counts, dots, state, throughput, age, sort, `+ New`, footer | 1 |
| 3 | **Pane header** — status dot, agent glyph, full cwd path, overflow menu | 1 |
| 4 | **Session picker (⌘O)** — the grouped, metadata-rich browser you use to find one of ten sessions | 1 |
| 5 | **Status bar** — session count, version, settings/help | 1 |

---

## Rounds

| Round | Piece | Result | Biggest remaining gap |
|---|---|---|---|
| 0 | — | baseline recorded above | everything in the gap table |
| 1 | Session telemetry | `SessionRegistry` merges the ≤5 s session file with the live wire (`SESSION_METRICS` 0x14) | the state model was wrong — see below |
| 1 | Status footer | `2 lanes · 9 sessions · N BLOCKED` | — |
| 2 | Agent state, corrected | `blocked` was missing entirely; `active` should have been `working`. Both parsed as `unknown`, so the headline signal was silently absent | — |
| 2 | pty-host selection | Max Pane was spawning the **March** binary, which has no classifier at all | — |
| 3 | Sidebar | session browser: every session, grouped by cwd, counts, dots, throughput, age, blocked-first under every sort | width capped by the split's 220pt minimum; controls do not persist |
| 3 | Lane header | liveness square, kind glyph, state chip, title, throughput, path, `⋯` menu | `WORKING`/`DONE` chips never seen on live data |
| 3 | Palettes | ⌘O grouped picker with quick-launch; ⌘P two-line rows | ⌘P still ranks by the Rust core's loose scorer |
| 3 | New-session sizing | sessions are born at the lane's size, using SwiftTerm's own cell metric | — |

### Two failures worth remembering

**The state model was built from a screenshot and was wrong.** `blocked` — the
single most valuable thing RelayTTY does — did not exist in the enum, and
`working` was called `active`. Both fell through to `unknown`. Nothing errored;
the information simply was not there. Reading `crates/pty-host/src/agent_state.rs`
would have caught it on day one, and the screenshot never could have.

**Three builders each reported "I never saw a BLOCKED chip" and all three blamed
pty-host.** The real cause was a line in Max Pane's own spawner: a RelayTTY
checkout carries two `relay-pty-host` binaries, `bin/` (March, no classifier) and
`crates/pty-host/target/release/` (September, has it), and we picked the first.
Every session Max Pane created was blind by construction. The lesson is not about
binaries — it is that three independent agents converging on the same wrong
explanation is a signal to go and measure, not to accept the consensus.

---

## How to watch / stop

```sh
# what the app currently shows
./build/MaxPane.app/Contents/Helpers/maxpane ls

# run it
MAXPANE_WINDOWED=1 ./build/MaxPane.app/Contents/MacOS/MaxPane
```

Scott stops the run. Say so and it stops.
