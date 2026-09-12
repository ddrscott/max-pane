# Spike M2 — SwiftTerm ↔ RelayTTY attach

Everything here is a measurement rig for
[`docs/spikes/02-m2-relay-attach.md`](../../docs/spikes/02-m2-relay-attach.md).

```
Sources/
  CRelayGzip/    zlib shim — inflateInit2(&s, 16 + MAX_WBITS) for BUFFER_REPLAY_GZ
  RelayClient/   the protocol client: framing, handshake, offset accounting, discovery, spawn
  m2bench/       headless measurements (no window needed)
  M2Harness/     windowed AppKit app hosting real SwiftTerm TerminalViews
fixtures/
  ruler.zsh      full-screen ruler with known column positions (reflow checking)
  gen.pl         synthetic output with a monotonic SEQ number (drop detection)
  utf8gen.pl     multi-byte UTF-8 stream + a byte-identical ground-truth file
out/             results
```

## Re-run

```sh
./build.sh                       # swift build -c release + the .app bundle

./.build/release/m2bench smoke     # protocol sanity on one spawned session
./.build/release/m2bench attach 25 5
./.build/release/m2bench echo 150
./.build/release/m2bench resize
./.build/release/m2bench conflict
./.build/release/m2bench load 30 200
./.build/release/m2bench lagged
./.build/release/m2bench utf8
./.build/release/m2bench observe <id>       # READ ONLY, safe on a live session

./M2Harness.app/Contents/MacOS/M2Harness    # windowed; writes out/harness.md + PNGs
```

`M2_SCROLLBACK=<lines>` overrides the per-pane SwiftTerm scrollback used by `load`.

Every subcommand spawns its own sessions and kills them on exit (including on
SIGINT/SIGTERM). `observe` is the only one that touches a session it did not
create, and it sends nothing — no `RESIZE`, no `DATA`.
