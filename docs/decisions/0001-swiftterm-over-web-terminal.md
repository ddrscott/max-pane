# ADR 0001 — SwiftTerm, not Relay's web client in a `WKWebView`

**Status:** Superseded in part by [ADR-0009](0009-libghostty-over-swiftterm.md) ·
2026-09-12. The emulator is now libghostty; the argument below against Relay's
web terminal in a `WKWebView` still stands.
**Decides:** PRD §14 — "SwiftTerm vs. embedding Relay's existing web terminal
client in a `WKWebView`."
**Evidence:** [Spike M2](../spikes/02-m2-relay-attach.md),
[Spike M1](../spikes/01-m1-webkit-memory.md).

## Decision

**SwiftTerm**, attached to RelayTTY over its Unix socket by a Swift protocol
client that MaxPane owns.

## Why

The PRD already preferred SwiftTerm and named the fallback's appeal: it "proves
'second frontend' fastest but costs memory per pane." M2 built the SwiftTerm path
in a day, which removes the speed argument, and then measured the rest.

Four reasons, in order of how much they matter. Memory is last.

### 1. Scrollback for §7.5

The search index needs the last 200 lines of every pty pane. With SwiftTerm that
is three public calls — `totalLinesTrimmed`, `getScrollInvariantLine(row:)`,
`translateToString` — walking back from the bottom in **0.47 ms**.

Inside a `WKWebView` it is an async JavaScript bridge hop per pane, per debounce,
forever. For 20 terminals on a 1.5-second debounce that is a permanent tax on the
main thread to maintain an index nobody sees.

### 2. Input latency

M2 measured **0.33 ms p50 / 3.4 ms p95** keystroke→echo through a real zsh, with
bytes going straight from `NSEvent` to the socket. The bare-PTY floor is 0.073 ms,
so nearly all of that is the shell thinking.

A WebView adds a main-thread → `WebContent` IPC hop in each direction for every
keystroke. It cannot be faster than the path that does not have the hop, and a
terminal that feels slow is a terminal you stop using.

### 3. A second frontend is a second thing to keep true

Relay's web client tracks Relay's protocol correctly *for Relay's own client*.
MaxPane would inherit its assumptions wholesale — including `cli/attach.ts`
asserting its size on every transition to connected, which is right for a
single-client CLI and, per [ADR-0007](0007-terminal-panes-never-resize-the-pty.md),
**actively harmful** for MaxPane. Adopting the web client means adopting that bug
and then fighting it from outside.

### 4. Memory

| | SwiftTerm pane | Relay's web client in a `WKWebView` |
|---|---|---|
| Memory per pane | **1.17 MB** (500-line scrollback) | ≥ 27 MB |
| OS processes per pane | **0** | ≥ 1 |
| Ratio | 1× | **23×, realistically worse** |

The 27 MB is M1's figure for a *light fixture page*. A JavaScript terminal
emulator holding a WebSocket is not a light page; M1's real-site figure is 95 MB.
So 23× is the floor of the comparison, not the middle of it.

SwiftTerm's cost is almost entirely the scrollback ring and it is linear —
1.6–2.1 KB per 80-column line — which makes it a tunable rather than a constant.
Worth remembering: **Relay already holds 10 MiB of scrollback per session and
replays it on demand.** SwiftTerm's buffer does not need to be the archive, so the
default 500 lines can come down if 20 terminals ever start to matter, which at
1.17 MB each they do not.

## What it costs

M2's PASS is not unqualified, and these are the prices:

- **A 5.3 MB-scrollback session takes 210 ms p50 to put pixels on screen.** A
  normal session takes 5.5 ms. The 210 ms is dominated by feeding the replay
  through the emulator, not by the network or by gzip (4.2 ms). Lazy attach on
  scroll-in, which the strip does anyway, keeps this off the launch path.
- **We own a protocol client.** RelayTTY's wire format is a stable external
  dependency we may not change, and now we have a second implementation of it to
  keep correct. [`docs/reference/relay-integration.md`](../reference/relay-integration.md)
  exists so that stays tractable; M2 verified byte-exact fidelity across 137 712
  sequence-numbered lines on 30 concurrent sessions with zero loss.

## Rejected

- **Relay's web client in a `WKWebView`.** 23× the memory at best, an IPC hop per
  keystroke, a JS bridge for every scrollback read, and an inherited resize
  behaviour that is wrong here. Its one advantage — time to first working pane —
  did not survive M2 building the alternative in a day.
- **`OBSERVE` mode (0x26) for visible panes.** No replay, so the pane is blank
  until the next byte of output. Correct for a metrics-only indicator, wrong for
  anything someone looks at.

## What would make us revisit

- SwiftTerm falling behind on escape-sequence support for something Scott's
  agents actually emit. M2 verified colour, italics and box-drawing at every lane
  width from 40 to 100 columns; it did not survey everything.
- Terminal memory becoming significant, which at 1.17 MB a pane against WebKit's
  27–95 MB it is not.
