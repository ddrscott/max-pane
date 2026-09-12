# Spike M2 — SwiftTerm ↔ RelayTTY attach

**Question (PRD §12):** SwiftTerm ↔ Relay attach: latency, resize correctness, 30 concurrent sessions.
**Pass criterion:** usable; no protocol changes needed.

**Verdict: PASS.** Attach to a 5.3 MB-scrollback session puts pixels on screen in **210 ms p50**;
a normal session in **5.5 ms p50**. Keystroke→echo is **0.33 ms p50 / 3.4 ms p95** through a real
zsh. Resize is cell-exact at every width from 40 to 100 columns. 30 concurrent sessions cost
**0.06 % of one core idle** and lost **zero bytes** — client offset matched the host's
`total_written` on 30/30 sessions across 137 712 sequence-numbered lines.

**No protocol change is required**, and none is proposed. `docs/proposals/` stays empty.

Two decisions come out of this with evidence:

- **§14 — SwiftTerm, not Relay's web client in a `WKWebView`.** A terminal pane costs
  **1.17 MB**. M1 measured a web pane at **≈27 MB** for light pages and **≈95 MB** for real
  sites. That is 23–80× per pane, and memory is the *weakest* of the four arguments (§9).
- **The resize conflict is real, is not fixable in the protocol, and does not need to be.**
  MaxPane must **never send `RESIZE`**, and must size the *lane* to the session rather than the
  session to the lane. §8 has the measurements and the concrete rule.

---

## Environment

| | |
|---|---|
| Machine | Mac15,7 — Apple M3 Pro, 36 GB |
| OS | macOS 26.6.2 (25G83), Darwin 25.6.0, arm64 |
| Swift | swift-driver 1.148.6, Apple Swift 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101) |
| Xcode | **none** — Command Line Tools only; `xcodebuild` was never used |
| SwiftTerm | `migueldeicaza/SwiftTerm`, pinned `exact: "1.20.0"` |
| RelayTTY | 1.21.0; pty-host binary `~/.nvm/versions/node/v22.23.2/lib/node_modules/relay-tty/bin/relay-pty-host` |
| Build | `swift build -c release`; the windowed harness is a hand-assembled `.app` + `codesign -s -` |

All numbers are milliseconds unless stated. "MB" is MiB. Memory is `phys_footprint`
(`task_info(TASK_VM_INFO)`) or RSS (`MACH_TASK_BASIC_INFO`), labelled per table. CPU is
`getrusage(RUSAGE_SELF)` user+system divided by wall time, expressed as a percentage of one core.

### Safety

Scott's eight live sessions were never resized, never written to, and never killed. Exactly one
of them (`a46eee7b`, a `zsh` running Claude Code) was attached **read-only** — `RESUME` with a
256 KiB replay clamp, then nothing sent for the rest of the connection — to get real content for
§8. Every other session in this document was spawned by the spike into `$TMPDIR` and killed
afterwards; all 126 exited session files were removed at the end, leaving the original eight
running and untouched.

## How to re-run

```sh
cd spikes/m2-relay-attach
./build.sh                                  # library + bench + M2Harness.app

./.build/release/m2bench smoke              # protocol sanity on one spawned session
./.build/release/m2bench attach 25 5        # §3  — 25 attaches, 5 MB scrollback
./.build/release/m2bench echo 150           # §4
./.build/release/m2bench resize             # §5
./.build/release/m2bench conflict           # §8
./.build/release/m2bench load 30 200        # §6
./.build/release/m2bench lagged             # §7
./.build/release/m2bench utf8               # §2.2
./.build/release/m2bench observe <id>       # READ ONLY, safe on a live session

./M2Harness.app/Contents/MacOS/M2Harness        # §3.3, §9, §8 screenshots -> out/harness.md
./M2Harness.app/Contents/MacOS/M2Harness cpu    # §6.2                    -> out/harness-cpu.md
```

Raw output is in `spikes/m2-relay-attach/out/`. `M2_SCROLLBACK=<lines>` overrides the per-pane
SwiftTerm scrollback used by `load`.

---

## 1. What was built

`Sources/RelayClient` is a complete Swift client for the Unix-socket protocol, written from
`docs/reference/relay-integration.md` (not from `PROTOCOL.md`, which is stale):

- 4-byte big-endian length prefix **including the type byte**; zero-length frames skipped, not
  errored; partial frames carried across reads.
- `RESUME` written **in the connect completion path with no `await` in between**. Measured:
  the first frame leaves **0.021 ms** after `connect()` starts, against the host's 100 ms
  deadline (`RESUME_TIMEOUT_MS`). Missing it is unrecoverable for that connection, so this is
  the one piece of the client that must never grow an `async` hop.
- Handshake gated on **`SYNC`**, never on a replay. Confirmed necessary: a fresh `zsh` session
  and a caught-up delta both produce `RESIZE → SYNC → SESSION_STATE` with **no replay frame at
  all**, and a session with no title produces no `TITLE`.
- Offset accounting exactly as specified: `DATA` adds its length, `BUFFER_REPLAY` and
  `BUFFER_REPLAY_GZ` add nothing, `SYNC(v)` assigns absolutely, `CLEAR_SCROLLBACK` zeroes.
  §6 proves this empirically.
- `isDelta` captured **synchronously before** inflate.
- `BUFFER_REPLAY_GZ` inflated with zlib `inflateInit2(&s, 16 + MAX_WBITS)` through a small C
  shim (`Sources/CRelayGzip`). Apple's `Compression` framework was not used; `COMPRESSION_ZLIB`
  is raw DEFLATE and cannot read these frames.
- One dedicated `DispatchSourceRead` per session on its own serial queue, draining to `EAGAIN`.
- Session discovery from `~/.relay-tty/sessions/*.json` (numbers decoded as `Double`, optionals
  absent rather than null) and direct spawn of `relay-pty-host` with `connect()` as the
  readiness test.

`Sources/M2Harness` is a windowed AppKit app hosting real `SwiftTerm.TerminalView`s, built as a
hand-assembled bundle (`Contents/MacOS/M2Harness`, `Info.plist` with `CFBundlePackageType APPL`
and `NSPrincipalClass NSApplication`, ad-hoc signed). `build.sh` reproduces it.

### 2. Stream integrity

### 2.1 Frame handling

No desynchronisation in any run, including one at **89.8 MB over 15 s through a single session**
(87 875 `DATA` frames). The 0-length-frame and split-frame paths are exercised constantly at
that rate.

### 2.2 UTF-8 and escape sequences split across frames

`fixtures/utf8gen.pl` emits a deterministic stream of box-drawing, CJK, Hangul, combining marks,
and astral-plane emoji, and writes the **byte-identical** stream to a file as ground truth. The
PTY's `ONLCR` turns every `LF` into `CRLF`, so the ground truth gets the same translation before
comparison.

| path | bytes | frames | ground truth present verbatim |
|---|---|---|---|
| live `DATA` | 355 767 received vs 355 500 expected (+267 B of shell-wrapper preamble) | 1 226 | **YES** |
| `BUFFER_REPLAY_GZ` | 24 579 B wire → 355 767 B inflated | 1 | **YES** |

Feeding raw bytes straight into SwiftTerm is correct; nothing needs an incremental decoder in
the client.

One SwiftTerm defect found, and it matters for PRD §7.5 — see §9.3.

---

## 3. Attach latency

25 attaches per row, release build, machine otherwise idle. Two sessions: a `zsh` at a prompt
(917 B replay, under the 4 KiB gzip threshold) and a generator that had written **5 542 907 B
(5.29 MB)** and gone quiet (replay **1 400 164 B on the wire → 5 542 907 B inflated**, gzipped —
a 3.96× ratio on realistic terminal output).

### 3.1 Protocol and emulator, headless

| metric | n | min | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|
| **small** — connect → `SYNC`, protocol only | 25 | 0.173 | 0.440 | 0.443 | 0.547 | 0.576 | 0.576 |
| **small** — connect → replay parsed into `Terminal` | 25 | 0.166 | 0.513 | 0.304 | 1.087 | 2.675 | 2.675 |
| **big** — connect → `SYNC`, protocol only | 25 | 50.335 | 58.095 | 51.646 | 85.778 | 118.420 | 118.420 |
| **big** — connect → replay frame arrives | 25 | 44.719 | 47.783 | 46.889 | 55.108 | 58.515 | 58.515 |
| **big** — gzip inflate (1.4 MB → 5.5 MB) | 25 | 3.862 | 4.173 | 4.086 | 4.748 | 4.830 | 4.830 |
| **big** — connect → replay decoded | 25 | 48.699 | 51.956 | 51.141 | 59.938 | 62.601 | 62.601 |
| **big** — SwiftTerm parses 5.5 MB | 25 | 105.048 | 109.394 | 109.171 | 111.410 | 123.845 | 123.845 |
| **big** — connect → replay in the emulator | 25 | 155.210 | 161.393 | 160.209 | 172.380 | 183.828 | 183.828 |
| **reconnect** — caught-up delta, connect → `SYNC` | 25 | 0.070 | 0.178 | 0.150 | 0.314 | 0.320 | 0.320 |

### 3.2 Where the 160 ms goes

| stage | p50 | share |
|---|---|---|
| socket + host builds and gzips a 5.5 MB replay + transfer | 46.9 ms | 29 % |
| gzip inflate | 4.1 ms | 3 % |
| **SwiftTerm parses 5.5 MB of terminal output** | 109.2 ms | **68 %** |

**The protocol is not the cost; the emulator is.** 5.5 MB in 109 ms is ~50 MB/s of ANSI parsing,
which is respectable — it is just a lot of bytes. The `RESUME` 16-byte variant's
`maxReplayBytes` clamp is the lever: §8's read-only attach to a real session asked for 256 KiB
and got a **0.21 ms** inflate instead of 4.1 ms, and a proportionally smaller parse.

### 3.3 Through a real `TerminalView`, to pixels

Windowed `M2Harness.app`, 80×40 grid, 12 pt Menlo, view parented in a visible `NSWindow`.
"Paint" is a forced synchronous `NSView.display()` immediately after the feed; SwiftTerm's own
path defers the same drawing to the next run-loop display pass, which adds at most one frame
(8.3 ms at 120 Hz).

| session | metric | n | min | mean | p50 | p95 | max |
|---|---|---|---|---|---|---|---|
| small | connect → replay fed | 25 | 0.25 | 0.78 | 0.83 | 1.30 | 1.51 |
| small | paint the 80×40 grid | 25 | 1.52 | 4.42 | 4.88 | 7.61 | 7.66 |
| small | **connect → pixels on screen** | 25 | 1.77 | 5.20 | **5.54** | 8.72 | 8.97 |
| big (5.3 MB) | connect → replay fed | 25 | 174.22 | 205.82 | 208.04 | 217.63 | 218.17 |
| big (5.3 MB) | paint the 80×40 grid | 25 | 1.27 | 1.59 | 1.57 | 1.77 | 1.97 |
| big (5.3 MB) | **connect → pixels on screen** | 25 | 175.88 | 207.41 | **209.61** | 219.13 | 219.92 |

The small session's paint (4.88 ms) is slower than the big session's (1.57 ms) because those
25 iterations ran first and paid SwiftTerm's glyph-atlas warm-up; by the time the big-session
loop ran, the atlas was hot. Treat 4.88 ms as the cold-start paint and 1.57 ms as the steady
state.

A pane with a normal amount of scrollback is on screen in **5.5 ms**. The worst case measured —
attaching to a session holding half the 10 MiB ring — is **210 ms**, inside PRD §10.1's 3 s
relaunch budget with room for 14 such panes in series, and panes attach in parallel.

---

## 4. Input → echo round-trip

Keystroke written as `DATA`, timed until the echoed byte comes back in an inbound `DATA` frame.
150 samples after 10 discarded warm-ups, `a` sent then erased with `0x7f` each cycle. **Zero
misses** in either run.

| session | n | min | mean | p50 | p95 | p99 | max |
|---|---|---|---|---|---|---|---|
| `zsh`, interactive, ZLE doing its redraw | 150 | 0.150 | 0.725 | **0.332** | **3.364** | 7.913 | 10.456 |
| `cat`, bare PTY echo (the floor) | 150 | 0.050 | 0.092 | 0.073 | 0.109 | 0.155 | 2.370 |

The protocol + socket + PTY floor is **73 µs**. Everything above it is the shell. A p95 of
3.4 ms is a third of one 120 Hz frame — the terminal will feel local, because it effectively is.
This was the number that decided whether the pane feels alive, and it is not close.

---

## 5. Resize correctness

`fixtures/ruler.zsh` paints a full-screen ruler whose every cell position is known: row 0 reports
`tput`'s idea of the size, row 1 holds `(col+1) % 10` at every column with `#` in the last one,
rows 2..r-2 have `|` in columns 0 and c-1, and the bottom row is `=` with `E` in the last cell.
The client resizes its `Terminal` **when the inbound `RESIZE` broadcast arrives**, never when it
sends one, so the emulator's grid changes at the same point in the byte stream as the PTY's.

Widths chosen to cover the PRD §8 lane range (420–900 pt ≈ 40–128 columns, §9.4):

| target | host `RESIZE` echo | SwiftTerm grid | `tput` in the app | ruler cell-exact | bottom row | corruption |
|---|---|---|---|---|---|---|
| 80×40 | 80×40 | 80×40 | `SIZE 80x40 gen=1 winch=0` | yes | yes | none |
| 100×50 | 100×50 | 100×50 | `SIZE 100x50 gen=2 winch=1` | yes | yes | none |
| 64×50 | 64×50 | 64×50 | `SIZE 64x50 gen=3 winch=2` | yes | yes | none |
| 50×50 | 50×50 | 50×50 | `SIZE 50x50 gen=4 winch=3` | yes | yes | none |
| 44×30 | 44×30 | 44×30 | `SIZE 44x30 gen=5 winch=4` | yes | yes | none |
| 40×24 | 40×24 | 40×24 | `SIZE 40x24 gen=6 winch=5` | yes | yes | none |
| 92×60 | 92×60 | 92×60 | `SIZE 92x60 gen=7 winch=6` | yes | yes | none |
| 57×45 | 57×45 | 57×45 | `SIZE 57x45 gen=8 winch=7` | yes | yes | none |
| 80×40 | 80×40 | 80×40 | `SIZE 80x40 gen=9 winch=8` | yes | yes | none |

**Every size cell-exact.** `winch` increments 1→8, so the explicit
`kill(-fg_pgrp, SIGWINCH)` reached the app on every single resize.

| metric | n | min | mean | p50 | p95 | max |
|---|---|---|---|---|---|---|
| `RESIZE` sent → host `RESIZE` broadcast back | 8 | 0.138 | 0.172 | 0.167 | 0.223 | 0.223 |
| `RESIZE` sent → first redraw byte from the app | 8 | 22.095 | 27.946 | 29.333 | 32.208 | 32.208 |

Two operational facts fell out:

- **A redundant `RESIZE` is free.** 20 `RESIZE` frames at the size already in effect produced
  **0 bytes** of `DATA`. Re-asserting a size costs nothing; *changing* it costs a full redraw.
- **`sessions/<id>.json` is stale for live size.** Throughout the table above the JSON lagged
  the real size by one or two steps — the metadata flush is on a 5 s timer. The inbound `RESIZE`
  frame, which precedes every replay and every broadcast, is the only authority. This is not a
  subtlety: a pane that sizes itself from the JSON will render at the wrong width for up to five
  seconds after any change.

---

## 6. 30 concurrent sessions

### 6.1 Headless: 30 sessions, 30 emulators, one process

30 `zsh` sessions spawned by the spike, each attached to its own `SwiftTerm.Terminal` with a
500-line scrollback. Load is generated by `exec`ing `fixtures/gen.pl`, which stamps every line
with a monotonic sequence number.

| phase | CPU (% of one core) | RSS | `phys_footprint` | throughput |
|---|---|---|---|---|
| baseline before attaching | — | 14.6 MB | — | — |
| **30 attached, shells idle at a prompt** | **0.06 %** | 26.0 MB (+11.4 MB for 30 panes) | 17.5 MB | 0 |
| **30 × ~200 lines/s** | **9.30 %** | 57.5 MB | 49.0 MB | 0.27 MB/s aggregate |

### 6.2 Windowed: 20 live panes parented in a real `NSWindow`

This is the configuration PRD §10.1 actually describes. Measured with the run loop genuinely
blocked between events, not spinning — an earlier version of this harness polled the run loop
and reported 5.70 %, which was the measurement loop's own cost, not the app's.

| condition | CPU (% of one core) | RSS |
|---|---|---|
| empty window, 0 panes (baseline) | 0.02 | 45.3 MB |
| **20 panes attached + parented + visible, shells idle** | **0.03** | 59.7 MB |
| the same 20 attached but unparented (off-screen lane) | 0.01 | 61.5 MB |
| 3 of the 20 emitting 20 lines/s (a working agent) | 0.76 | 64.6 MB |
| all 20 emitting 200 lines/s (nothing like real use) | 7.83 | 84.1 MB |

**Against PRD §10.1's "≈20 pty lanes, idle CPU < 2 %": 0.03 %, about 65× under budget.** Even
three agents producing output continuously stays at 0.76 %. PRD §10.2's "pty panes stay parented;
SwiftTerm is cheap" is confirmed — parented and unparented differ by 0.02 percentage points at
idle, which is noise.

### 6.3 Correctness: did anything get lost?

The rigorous test is not "did the text look right". `SYNC` at handshake assigns the client's
offset absolutely, and from then on the offset advances **only on frames actually received**.
So after the generators stop and everything quiesces, `client.offset == totalBytesWritten` is an
exact, protocol-level proof that no frame was dropped. The sequence numbers are the second,
independent check.

| check | result |
|---|---|
| sessions where client offset ≠ host `total_written` | **0 / 30** |
| sequence-numbered lines observed | 137 712 |
| sequence gaps (dropped-frame evidence) | **0** |
| duplicate sequence numbers | 0 |

No client hit the 256-frame `Lagged` drop at this rate. §7 establishes what it takes to.

---

## 7. The `Lagged(n)` hazard — deliberately provoked

"Zero drops" is worthless unless the detector can detect one, so the same rig was run against a
single session generating flat out, with two readers.

| reader | received in 15 s | SEQ lines | gaps | final offset vs host `total_written` |
|---|---|---|---|---|
| drains every readable event | **89 820 174 B** (87 875 frames) | 1 377 490 | 0 | exact |
| sleeps 50 ms per `DATA` frame | **13 312 B** (13 frames) | 203 | 0 | **91 848 207 B behind — 80.9 % of the session** |

A single well-behaved client sustained **~6 MB/s** from one session with zero loss. The stalled
client did not skip frames — it was throttled by socket back-pressure and fell 92 MB behind
inside 15 seconds, receiving essentially nothing. That is worse than dropping frames: the ring
buffer is 10 MiB, so a client 92 MB behind can no longer be repaired by `RESUME(offset)` at all.
Its next reconnect gets `SYNC(0)` plus a full replay, and the intervening output is gone.

**Implementation rule this produces:** the socket reader must never do work that can block. Feed
bytes into SwiftTerm from the reader queue (measured at ~50 MB/s, fast enough) and do everything
else — search-index pushes, OSC 7 sniffing, ledger writes — on another queue. Treat a client
whose offset falls more than a few MB behind `totalBytesWritten` as a reason to reconnect, not
as a transient.

---

## 8. The resize conflict

### 8.1 What was measured

The reference establishes that the PTY has exactly one `winsize` and that every client's
`RESIZE` feeds one channel, last writer wins. This spike put numbers on what that costs.

Two clients attached to one spike-owned session and alternately asserted 50×50 (a MaxPane
portrait lane) and 100×30 (a phone). A third client, attached and never resizing, counted the
redraw traffic it was forced to receive.

| session content | flips | host broadcast each time | **redraw forced on every other client, per flip** |
|---|---|---|---|
| `fixtures/ruler.zsh` | 8 | followed the last writer exactly | **825 bytes** |
| `htop` (a real full-screen TUI) | 8 | followed the last writer exactly | **6 271 bytes** |

Every flip is a full `TIOCSWINSZ` + `SIGWINCH` + complete TUI repaint, delivered to all clients.
Two clients disagreeing at 1 Hz is a permanent ~6 KB/s redraw storm on a real TUI and a
permanently reflowing screen for both of them. Nobody can read that.

The loser's position is worse than "a bit narrow". Client A asked for 50 columns and was then fed
a **100-column** screen with nowhere to put it. And the session JSON still said 50×50 for
several seconds afterwards, so a pane that trusted the JSON would have been wrong about its own
width too.

### 8.2 The proposed mitigation, built and measured

A fourth client attached normally, **never sent `RESIZE`**, and let the phone reshape the PTY
twice (72×36, then 100×30):

| session | sizes learned, purely from inbound `RESIZE` | redraw received | `SIGWINCH`s it caused |
|---|---|---|---|
| ruler fixture | `72x36`, `100x30` | 1 459 B | **0** |
| `htop` | `72x36`, `100x30` | 12 175 B | **0** |

It works exactly as the reference predicts. The host is authoritative, the inbound `RESIZE`
arrives before every replay and on every change, and a silent client is invisible to the
session. `OBSERVE` (0x26) is *not* the right tool here — it suppresses the replay, so a visible
pane would start blank; a plain `RESUME` attach that simply never writes is both read-only in
practice and fully populated.

### 8.3 So how does a wide session look in a narrow lane?

Measured against **real content**: a live Claude Code session (`a46eee7b`), attached read-only,
its PTY at 73×62. Claude Code — like every TUI — wraps to the terminal width, so the screen is
*dense at whatever width the PTY happens to be*:

- 53 non-blank rows, **median non-blank width 69 of 73 columns**
- **44 of 53 lines wider than 50 columns**, 20 wider than 70

Cell width by font and size, from `TerminalView.getOptimalFrameSize()` (Menlo; SF Mono and
JetBrains Mono are not installed on this machine and were skipped):

| size | cell w × h (pt) | cols @420 pt | cols @600 pt | cols @900 pt |
|---|---|---|---|---|
| 9 | 5.00 × 11.00 | **84** | 120 | 180 |
| 10 | 6.00 × 12.00 | 70 | 100 | 150 |
| 11 | 7.00 × 13.00 | 60 | 85 | 128 |
| 12 | 7.00 × 14.00 | 60 | 85 | 128 |
| 13 | 8.00 × 16.00 | 52 | 75 | 112 |
| 14 | 8.00 × 17.00 | 52 | 75 | 112 |

Three renderings of that real 73-column screen, screenshotted from the harness
(`out/lane-*.png`):

| option | font | cols visible in a 420 pt lane | verdict |
|---|---|---|---|
| **A — clip** | 12 pt | 60 of 73 | **No.** `out/lane-A-clip-12pt.png`: 13 columns amputated from the right of every line. Because the TUI wrapped to 73, the cut lands mid-word on 44 of 53 lines. Prose becomes unreadable, not merely truncated. |
| **B — horizontal scroll** | 12 pt | 60 of 73 | **No.** `out/lane-B-hscroll-12pt.png` is identical until you scroll, and scrolling sideways to finish every sentence in a pane you are *supervising, not driving* is the opposite of the point. A supervision surface is read at a glance. |
| **C — scale the font to fit** | 9 pt | **84 of 73 — fits** | **Yes.** `out/lane-C-shrink-to-fit.png` shows the whole 73-column screen inside the minimum 420 pt lane, colour, italics and box-drawing intact. |

### 8.4 The finding that makes this easy

At 12 pt Menlo a cell is 7.00 pt wide, so **73 columns want 511 pt** — comfortably inside the
PRD's 420–900 pt lane range. The real sessions on this machine run **52 to 73 columns**. Every
one of them fits in a PRD lane at a normal font size:

| host cols | lane width needed at 12 pt | inside 420–900 pt? |
|---|---|---|
| 52 | 364 pt → clamps to LANE_MIN 420 | yes, with slack |
| 73 | 511 pt | yes |
| 100 | 700 pt | yes |
| 128 | 896 pt | yes, at the very top |
| > 128 | > 900 pt | no — scale the font |

**The lane should be sized to the session, not the session to the lane.** Font scaling is the
fallback for the rare > 128-column session, not the primary mechanism, which means option C's
9 pt only ever appears when someone attaches a genuinely huge terminal.

### 8.5 Recommendation

1. **Never send `RESIZE` automatically.** Not on attach, not on focus, not on lane resize, not
   on window resize, not on reconnect. This is a deliberate divergence from `cli/attach.ts`,
   which asserts its size on every transition to connected — correct for a single-client CLI,
   actively harmful with a phone on the same session.
2. **Take `cols`/`rows` from the inbound `RESIZE` frame.** It is the first frame of every
   handshake and is broadcast on every change. Never read live size from `sessions/<id>.json`;
   §5 measured it lagging by seconds.
3. **Derive the lane's default width from the session:** `clamp(hostCols × cellWidth + gutter,
   LANE_MIN, LANE_MAX)`. Re-derive on every inbound `RESIZE` — but animate it, because a phone
   can change it under the user.
4. **Scale the font only when `hostCols × cellWidth > LANE_MAX`,** down to a floor of 9 pt
   (84 columns at 420 pt, 180 at 900 pt). Below that floor, clip with a visible affordance
   rather than shrinking further. Do not make horizontal scroll the default; keep it as a manual
   gesture for the clipped case.
5. **Offer one explicit escape hatch:** a "claim this session at this width" command that sends
   exactly one `RESIZE`, shown as a deliberate, visible act. Re-asserting the size already in
   effect is free (§5), so a claimed pane may safely re-assert on reconnect; it must not
   re-assert a *different* size without the user asking again.
6. **Do not use `OBSERVE` for visible panes** — no replay means a blank pane. It remains correct
   for a purely metrics-driven indicator.

### 8.6 Why no protocol proposal is being filed

A per-client viewport in RelayTTY would be the real fix, and it is the kind of change PRD §0.3
exists to prevent. It is not needed: §8.2 shows a silent client already gets everything MaxPane
needs — authoritative size, full replay, live output — and §8.4 shows the PRD's own lane range
already accommodates every real session width without compromise. `docs/proposals/` stays empty.

If Phase 1 daily-driving shows the phone genuinely reshaping sessions often enough to be
disruptive, the cheaper non-protocol answer is a MaxPane-side convention (a pinned preferred
size stored in `laned-core`, re-asserted only on explicit user action) before anything in
RelayTTY is touched.

---

## 9. SwiftTerm viability, and the §14 decision

### 9.1 Memory per pane

30 `TerminalView`s at 80×45, each fed 3 000 lines of output, never parented
(`phys_footprint` delta):

| scrollback (lines) | total delta | **per view** |
|---|---|---|
| 200 | 17.20 MB | **0.57 MB** |
| 500 (SwiftTerm default) | 35.00 MB | **1.17 MB** |
| 2 000 | 129.72 MB | **4.32 MB** |
| 5 000 | 273.61 MB | **9.12 MB** |

Parenting 8 of them into a live window added 10.36 MB, about 1.3 MB per visible view for the
backing store.

Cost is almost entirely the scrollback ring, and it is linear: **1.6–2.1 KB per 80-column
line** across all four steps. That
is a **tunable**, and PRD §7.5 only needs the last 200 lines for search. Note that Relay already
holds 10 MiB of scrollback per session and replays it on demand — SwiftTerm's buffer does not
need to be the archive.

### 9.2 The §14 decision: SwiftTerm, decisively

M1 measured a `WKWebView` pane at **≈27 MB `phys_footprint` for light fixture pages and ≈95 MB
for real sites**, and at least one OS process per pane.

| | SwiftTerm pane | Relay's web client in a `WKWebView` |
|---|---|---|
| memory per terminal pane | **1.17 MB** (500-line scrollback) | ≥ 27 MB (M1's *light-page* figure; a JS terminal emulator over a WebSocket is not a light page) |
| OS processes per pane | 0 | ≥ 1 |
| ratio | 1× | **23×, realistically worse** |

Memory is the *weakest* of the four arguments:

1. **Scrollback for PRD §7.5.** The search index needs the last 200 lines of each pty pane "from
   SwiftTerm's buffer". With SwiftTerm that is three public calls and **0.47 ms** (§9.3). Inside
   a `WKWebView` it is an async JS bridge hop per pane, per debounce, forever.
2. **Input latency.** §4 measured 0.33 ms p50 keystroke→echo with bytes going straight from
   `NSEvent` to the socket. A WebView adds a main-thread → WebContent IPC hop in both directions
   for every keystroke, and it cannot be faster than the path that does not have it.
3. **A second frontend is a second thing to keep true.** Relay's web client already tracks
   Relay's protocol; MaxPane would inherit its assumptions, including `cli/attach.ts`'s
   resize-on-connect, which §8 shows is exactly wrong for MaxPane.
4. Memory.

The only thing the WebView route buys is speed-to-first-pane, and this spike built a working
client in a day. **Recommendation: SwiftTerm. Write the ADR.**

### 9.3 Scrollback extraction — works, with one defect

PRD §7.5's "last 200 lines from SwiftTerm's buffer" is reachable through public API:
`Terminal.buffer.totalLinesTrimmed` + `Terminal.getTopVisibleRow()` + `Terminal.rows` gives the
scroll-invariant index of the last line; `Terminal.getScrollInvariantLine(row:)` walks back from
there.

| extraction path | 200 lines | astral-plane correctness |
|---|---|---|
| `BufferLine.translateToString(trimRight:skipNullCellsFollowingWide:)` | 0.483 ms | **broken** |
| per-cell `Terminal.getCharacter(col:row:)` | 0.474 ms | correct |

Fed `EMOJI A😀B 🇺🇸 日本`:

```
translateToString  ->  "EMOJI A  B    日 本 "      <- emoji silently dropped
getCharacter       ->  "EMOJI A😀B 🇺🇸 日本"        <- correct
```

`translateToString` loses any scalar stored in SwiftTerm's side-table (anything above the BMP:
emoji, flags). The per-cell path is correct and **costs the same**. Use it for the search index;
do not use `translateToString`.

Second caveat for §7.5: a fresh attach does **not** reliably give 200 lines. The read-only
attach to the real session yielded **125**, because a full replay is truncated at the last
`ESC[2J` and that session had cleared recently. The index must be fed incrementally from live
`DATA` as well as seeded from the attach replay.

### 9.4 Other SwiftTerm observations

- Rendering of real Claude Code output is correct: 256-colour SGR, italics, box drawing, the
  `✳`/`⏺`/`▶▶` glyphs, and the wrapped-prose layout all survive the round trip
  (`out/lane-C-shrink-to-fit.png`).
- `TerminalView.draw(_:)` is `public`, not `open`, so it cannot be overridden to timestamp
  paints from outside the module. §3.3 forces the paint with `NSView.display()` instead.
- `cellDimension` is internal; cell size must be derived from the public
  `getOptimalFrameSize()`. Worth a one-line helper in the app.
- `feed(byteArray:)` is safe from a background thread and parses at ~50 MB/s.
- Resize handling is exact (§5) and `Terminal.resize` driven from the inbound `RESIZE` frame
  keeps the emulator's grid and the PTY's `winsize` in lockstep with no reflow artefacts.

---

## 10. Pass / fail

| M2 criterion | result |
|---|---|
| Attach latency **usable** | **PASS** — 5.5 ms p50 to pixels for a normal session; 210 ms p50 for a 5.3 MB scrollback |
| Input latency **usable** | **PASS** — 0.33 ms p50, 3.4 ms p95 keystroke→echo through a real shell |
| Resize correctness | **PASS** — cell-exact at 40–100 columns, `SIGWINCH` delivered every time, no corruption |
| 30 concurrent sessions | **PASS** — 0.06 % idle CPU, 26 MB RSS, 0/30 offset mismatches, 0 dropped frames in 137 712 lines |
| PRD §10.1 (≈20 pty lanes, idle CPU < 2 %) | **PASS** — 0.03 % with 20 parented, visible, live panes |
| **No protocol changes needed** | **PASS** — the whole client is built against the existing wire protocol; `docs/proposals/` is empty |

The resize conflict is a **design constraint, not a failure**: it is fully mitigable on the
client side (§8), and the mitigation was built and measured, not merely proposed.

---

## 11. Threats to validity

- **One machine, idle.** M3 Pro, 36 GB, release build, nothing else running. The four Phase 0
  spikes were run at overlapping times but each measurement here was taken with the others
  quiescent; M3's own re-run under contention degraded ~12 %, and the same order of degradation
  should be assumed for these numbers. Nothing here has less than 3× headroom against its target.
- **Synthetic load.** `gen.pl` produces uniformly-shaped lines with a little SGR. Real agent
  output is burstier, uses alt-screen, and repaints; `htop` was used wherever a real TUI mattered
  (§8.1), and one real Claude Code session was measured read-only (§8.3), but the 30-session load
  is synthetic.
- **The 30-session load is light in absolute terms** — 0.27 MB/s aggregate. §7 pushed a single
  session to 6 MB/s cleanly, so headroom exists, but 30 sessions × 6 MB/s was not tried.
- **`Lagged(n)` was never actually observed.** The stalled-reader test produced socket
  back-pressure rather than broadcast-channel overflow. The recovery path for a genuine
  `Lagged` — a sequence gap repaired by reconnect + `RESUME` — is therefore **untested**, and
  the gap detector has only ever returned zero. §7's back-pressure result is a real failure mode
  and is arguably worse, but it is not the same failure mode.
- **Render timing is a forced synchronous paint.** §3.3's "pixels on screen" calls
  `NSView.display()` rather than waiting for AppKit's own display pass, because SwiftTerm's
  `draw(_:)` cannot be overridden. The natural path adds up to one frame (8.3 ms at 120 Hz) and
  is not measured.
- **No sleep/wake, no reconnect-after-death, no `EXIT` handling under load.** That is M5's
  brief; the client implements `EXIT` and the reconnect contract but neither was exercised here.
- **Font coverage is Menlo and Monaco only.** SF Mono and JetBrains Mono are not installed on
  this machine, so §8.3's cell-width table does not cover the fonts MaxPane may actually ship
  with. Cell widths quantise to whole points in SwiftTerm, so the table's *shape* will hold, but
  the exact column counts must be re-derived for whatever font is chosen.
- **The read-only attach to a live session was one session, once.** It is a realism check, not a
  sample.
- **`getrusage` CPU is process-wide**, including the spike's own bookkeeping. The §6.2 baseline
  row (0.02 %) bounds that contamination.
