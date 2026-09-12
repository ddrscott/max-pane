# Gauntlet — functional parity with the RelayTTY web app

**Goal (Scott, verbatim):** "We should be at least as functional as Relay TTY web app."

**The bar:** `~/Downloads/SCR-20260912-hups.png` — RelayTTY web app v1.21.0,
ten live sessions, three terminal columns. Every round is judged against it.

**Stop condition:** Scott stops the run. Not a round count.

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

| Round | Piece | Builder | Critic verdict | Biggest remaining gap |
|---|---|---|---|---|
| 0 | — | — | baseline recorded above | everything in the gap table |

---

## How to watch / stop

```sh
# what the app currently shows
./build/MaxPane.app/Contents/Helpers/maxpane ls

# run it
MAXPANE_WINDOWED=1 ./build/MaxPane.app/Contents/MacOS/MaxPane
```

Scott stops the run. Say so and it stops.
