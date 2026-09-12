# RelayTTY integration reference

Reference for writing a **third-party client** (MaxPane, Swift/macOS) against RelayTTY
without modifying RelayTTY.

Source of truth for every statement below is the RelayTTY tree at
`/Users/spierce/code/relay-tty` at version `1.21.0`. Citations are `path:line`.

**`PROTOCOL.md` is stale and must not be trusted.** See [Protocol drift](#protocol-drift).

The authoritative implementations are:

| Role | File | Language |
|---|---|---|
| PTY owner, socket server, ring buffer, replay, metadata writer | `crates/pty-host/src/main.rs` | Rust |
| Wire constants | `shared/types.ts` | TS |
| Unix socket framing | `shared/framing.ts` | TS |
| Reference client state machine | `shared/client/session-stream.ts` | TS |
| Payload codecs | `shared/client/messages.ts` | TS |
| WS ⇄ Unix socket bridge (adds PONG + SESSION_UPDATE) | `server/ws-handler.ts` | TS |
| Session discovery from disk | `shared/client/directory-disk-node.ts` | TS |
| HTTP API | `server/api.ts` | TS |
| Auth | `server/auth.ts` | TS |

`crates/pty-host/src/main.rs:2` states the Rust host is drop-in compatible with the
deleted `server/pty-host.ts`; there is no other PTY host.

---

## 1. Unix socket framing

`shared/framing.ts:1-30`, mirrored by `crates/pty-host/src/main.rs:1430-1436` (write) and
`:2357-2365` / `:2411-2418` (read).

```
Frame on the Unix socket:

  +--------+--------+--------+--------+--------+--------+ ... +
  |          uint32 BE payload_len    |  type  |     data      |
  +--------+--------+--------+--------+--------+--------+ ... +
  |<---------- 4 bytes -------------->|<---- payload_len ----->|

  payload_len  = 1 (type byte) + len(data)     <-- INCLUDES the type byte
  endianness   = big-endian, always
  type         = one byte, the WS_MSG code
```

* Length prefix width: **4 bytes**, `uint32`, **big-endian** (`framing.ts:11`,
  `main.rs:1431-1434`).
* The length **includes the 1-byte type**. `parseFrames` slices `payload = pending[4 .. 4+msgLen]`
  and then dispatches `handler(payload[0], payload.subarray(1))` (`framing.ts:24-27`).
* A frame with `payload_len == 0` carries no type byte and **must be skipped**, not
  treated as an error (`framing.ts:26`, `main.rs:2367-2369`).
* Frames may be split across reads and multiple frames may arrive in one read. Accumulate
  and re-parse; return the unconsumed tail (`framing.ts:20-29`).

### WebSocket framing

There is **no length prefix on WebSocket**. One binary WS message == one payload
(`[type][data]`) (`shared/client/transport-ws.ts:23-26`; bridge at
`server/ws-handler.ts:386-423` strips the prefix, `:465-470` adds it back).

Text WS frames are never session protocol and must be ignored
(`transport-ws.ts:17`). `/ws/events` sends the literal text `"sessions-changed"`
(`ws-handler.ts:119`).

---

## 2. Full message table

`WS_MSG` constants: `shared/types.ts:41-86`. Rust mirror: `main.rs:34-53`.

Direction column: **C→H** client to pty-host, **H→C** pty-host to client,
**S→C** synthesized by the Node WS server only (never present on a Unix socket).

Handling column is for a **read-only / lightly-interactive attach client**:
MUST = protocol breaks without it, SHOULD = user-visible degradation, MAY = optional.

| Name | Hex | Dir | Payload layout | Handling |
|---|---|---|---|---|
| `DATA` | `0x00` | C→H / H→C | raw bytes (PTY output, or keystrokes inbound) | **MUST** |
| `RESIZE` | `0x01` | C→H / H→C | `[u16 BE cols][u16 BE rows]` (4 B) | **MUST** (see §10) |
| `EXIT` | `0x02` | H→C | `[i32 BE exit_code]` (4 B) | **MUST** |
| `BUFFER_REPLAY` | `0x03` | H→C | raw terminal bytes | **MUST** |
| `TITLE` | `0x04` | H→C | UTF-8 title | SHOULD |
| `NOTIFICATION` | `0x05` | H→C | UTF-8 text | MAY |
| `RESUME` | `0x10` | C→H | `[f64 BE offset]` (8 B) **or** `[f64 BE offset][f64 BE maxReplayBytes]` (16 B) | **MUST send** |
| `SYNC` | `0x11` | H→C | `[f64 BE offset]` (8 B) | **MUST** |
| `SESSION_STATE` | `0x12` | H→C | `[u8]` `0x00`=idle, `0x01`=active (1 B) | MAY |
| `BUFFER_REPLAY_GZ` | `0x13` | H→C | gzip member (see §4) | **MUST** |
| `SESSION_METRICS` | `0x14` | H→C | `[f64 bps1][f64 bps5][f64 bps15][f64 totalBytes]` (32 B, all BE) | MAY |
| `SESSION_UPDATE` | `0x15` | **S→C only** | UTF-8 JSON of a full `Session` | SHOULD (only live-cwd push, WS only) |
| `CLIPBOARD` | `0x16` | C↔ / H→C | UTF-8 text | MAY |
| `IMAGE` | `0x17` | H→C | `[u32 BE id_len][id UTF-8][mime UTF-8][0x00][raw image bytes]` | MAY |
| `SPARKLINE_REQUEST` | `0x18` | C→H | *(none)* | MAY |
| `SPARKLINE_HISTORY` | `0x19` | H→C | `[u16 BE count][count × f64 BE bps1]` oldest-first | MAY |
| `PING` | `0x20` | C→**S** | *(none)* — 1-byte frame | **WS only**, see §5 |
| `PONG` | `0x21` | **S**→C | *(none)* — 1-byte frame | **WS only** |
| `DETACH` | `0x22` | C→H | *(none)* | MAY (destructive, see below) |
| `CLEAR_SCROLLBACK` | `0x23` | C→H **and** H→C | *(none)* | **MUST** handle inbound |
| `SET_TITLE` | `0x24` | C→H | UTF-8 title; empty payload unpins | MAY |
| `SIGNAL` | `0x25` | C→H | `[u8 signal_number]` (1 B) | MAY |
| `OBSERVE` | `0x26` | C→H | *(none)*, **first frame only** | SHOULD for passive panes |

### Per-message detail

**`DATA` (0x00)** — `main.rs:1843-1847` (out), `:2606-2608` (in). Outbound bytes are
post-OSC-extraction: OSC 9, OSC 52 and OSC 1337 have been *removed* from the stream and
re-emitted as `NOTIFICATION` / `CLIPBOARD` / `IMAGE` (`main.rs:1792-1818`, `:965-995`).
**OSC 0/2 (title) and OSC 7 (cwd) are NOT removed** — they stay inline in `DATA` and in
replays. Inbound `DATA` is written verbatim to the PTY master (`main.rs:1896-1905`).

**`RESIZE` (0x01)** — bidirectional despite what `PROTOCOL.md` says. The host sends it
*before every replay* (`main.rs:2526-2535`) and broadcasts it to all clients on any accepted
resize (`main.rs:1926-1929`). Decoder: `messages.ts:64-67`. Payloads shorter than 4 bytes are
ignored (`session-stream.ts:353-355`).

**`EXIT` (0x02)** — `[i32 BE]`. `128 + signal` when killed by a signal, `-1` when unknown
(`main.rs:1865-1876`). Also sent immediately after the handshake if the session already exited
(`main.rs:2340-2350`), and synthesized by the WS bridge from session JSON when the socket is
gone (`ws-handler.ts:353-358`). After `EXIT` the reference client sets `exited = true` and
**never reconnects** (`session-stream.ts:330-333`, `:127`, `:153-156`).

**`BUFFER_REPLAY` (0x03)** — see §12 for exactly what bytes. **Sent only when the replay body
is non-empty** (`main.rs:2544`). A fully-caught-up delta produces no replay frame at all.

**`TITLE` (0x04)** — §11.

**`NOTIFICATION` (0x05)** — OSC 9 text lifted out of the stream (`main.rs:1793-1797`), plus a
synthetic `"Session idle"` when `bps5 > 100` decays to `bps1 < 1.0` (`main.rs:2167-2176`).

**`RESUME` (0x10)** — encoder `messages.ts:26-34`. 9-byte frame (`[0x10][f64]`) or 17-byte
(`[0x10][f64][f64]`). Parser `main.rs:2437-2448`: `< 8` bytes of payload ⇒ malformed ⇒ full
replay. `maxReplayBytes` defaults to `0.0` for the 8-byte form and clamps **full replays only**
(`main.rs:2483`, `:2498`); deltas are never clamped (`main.rs:2490-2493`).

**`SYNC` (0x11)** — `f64` BE, `NaN`/short payload ignored (`messages.ts:61`,
`session-stream.ts:315-316`). Two distinct meanings: authoritative offset after a replay
(`main.rs:2577-2587`), or **cache reset** when the value is `0` and the client's offset was `> 0`
(`main.rs:2508-2515`, `session-stream.ts:317-320`).

**`SESSION_STATE` (0x12)** — 1 byte. Active flips to `0x01` on the first output after idle
(`main.rs:1836-1840`); flips to `0x00` after `IDLE_TIMEOUT_MS = 60_000` of no output, checked on
a 5 s timer (`main.rs:60`, `:2072-2088`). Also sent once at the end of every handshake
(`main.rs:2596-2600`). Decode: `p.length > 0 && p[0] === 1` (`session-stream.ts:341`).

**`BUFFER_REPLAY_GZ` (0x13)** — §4.

**`SESSION_METRICS` (0x14)** — 32-byte payload, decoder rejects `< 32` (`messages.ts:69-78`).
Emitted at 1 Hz but only while any of `bps1/bps5/bps15 >= 0.5`, plus one trailing frame on the
transition to all-zero (`main.rs:2151-2165`). Also forced after `CLEAR_SCROLLBACK`
(`main.rs:1968-1981`).

**`SESSION_UPDATE` (0x15)** — **pty-host never emits this.** The constant does not exist in
`main.rs:34-53`. It is synthesized by `server/ws-handler.ts:65-77` from the `PtyManager`
`"session-update"` event, which comes from an `fs.watch` on `~/.relay-tty/sessions` with a
200 ms debounce (`server/pty-manager.ts:292-319`, `:332-382`). Consequences:

* Available **only over WebSocket**, never on a Unix socket.
* Broadcast to **every** WS client on the server (`wss.clients.forEach`,
  `ws-handler.ts:72-76`), not just clients of that session, and also to `/ws/events`
  subscribers. **Filter on `session.id` yourself.**
* Payload is the full merged `Session` JSON, so it does carry `cwd`, `title`, `cols`, `rows`,
  `agentState`, `foregroundProcess`. Decoder tolerates garbage by returning null
  (`messages.ts:80-86`).

**`CLIPBOARD` (0x16)** — from the host it is OSC 52 lifted out of the stream
(`main.rs:1798-1802`). Client→server `CLIPBOARD` is **not forwarded to the PTY**; the WS server
fans it out to the other WS clients of the same session, capped at 1 MiB
(`ws-handler.ts:457-464`, `:18-19`). Over a raw Unix socket an outbound `CLIPBOARD` is ignored by
`process_client_message` (`main.rs:2631-2633`).

**`IMAGE` (0x17)** — layout `main.rs:1805-1817`, decoder `messages.ts:101-112`:

```
[0x17][u32 BE id_len][id: id_len bytes UTF-8][mime: UTF-8, NUL-terminated][raw image bytes]
```

The MIME field has no length; scan forward to the first `0x00` from `4 + id_len`. Empty image
bytes ⇒ discard. Missing MIME defaults to `image/png` (`messages.ts:111`). Max 10 MiB
(`main.rs:626`).

**`SPARKLINE_REQUEST` (0x18) / `SPARKLINE_HISTORY` (0x19)** — 3600-slot ring of 1 s `bps1`
samples (`main.rs:1235`, `:1278-1286`). Special case: sending `SPARKLINE_REQUEST` as the **first**
frame answers directly with no replay and no `SYNC` (`main.rs:2310-2315`) — that is how the
server's `fetchSparkline` works (`pty-manager.ts:250-269`).

**`PING` (0x20) / `PONG` (0x21)** — see §5. **pty-host does not implement either**; over a Unix
socket `PING` falls into the ignore arm of `process_client_message` (`main.rs:2631-2633`) and
nothing comes back. Only the WS server answers (`ws-handler.ts:453-456`, read-only path
`:327-330`).

**`DETACH` (0x22)** — `SIGHUP`s the PTY foreground process group **if it differs from the
session's own child pid** (`main.rs:1938-1948`). This kills whatever TUI is running (Claude Code,
vim, htop) and returns the shell prompt. **Do not send this on a passive pane close.** The CLI
sends it only for an explicit Ctrl+`]` detach (`cli/attach.ts:129-138`).

**`CLEAR_SCROLLBACK` (0x23)** — inbound from a client it empties the ring and resets the
*reported* `totalBytesWritten` to 0, but **not** the monotonic `total_written` offset
(`main.rs:1461-1474`). The host then broadcasts, in order: `CLEAR_SCROLLBACK`,
`SYNC(total_written)`, `SESSION_METRICS` (`main.rs:1954-1981`). A client receiving
`CLEAR_SCROLLBACK` clears its terminal and sets `offset = 0` (`session-stream.ts:361-364`); the
immediately following `SYNC` restores the real offset. **Do not send a `RESUME` in response.**

**`SET_TITLE` (0x24)** — §11.

**`SIGNAL` (0x25)** — one byte, `signal & 0xff` (`messages.ts:54`). Delivered as
`kill(-pgrp, sig)` to the foreground process group, falling back to the child pid
(`main.rs:2015-2027`). Values `<= 0` are dropped.

**`OBSERVE` (0x26)** — must be the very first frame (`main.rs:2305-2309`). The host sends **no
replay, no `SYNC`, no `TITLE`, no `SESSION_STATE`** — only live broadcast frames — and does not
increment `clients_attached`, which keeps the session out of the agent-state `Done → Idle`
transition (`main.rs:2336-2338`, `:2389`, `agent_state.rs:108-113`). Correct choice for a
monitoring pane; wrong for anything a person reads, because there is no initial screen content.

---

## 3. Handshake and offset accounting

### 3.1 Connect sequence (client side)

`session-stream.ts:126-159` is the canonical implementation.

1. Open the transport (Unix socket connect, or WS upgrade).
2. **On open, immediately and as the first frame**, send `RESUME(offset)` — or `OBSERVE` in
   observer mode (`session-stream.ts:137`). Set `lastServerMessage = now` (`:136`).
3. Read frames until the handshake tail arrives (see 3.2). The reference client treats `SYNC`
   as "handshake complete" (`cli/directory.ts:113-114`).
4. Send `RESIZE(cols, rows)` **after** connected — the CLI does this on every
   `status === "connected"` (`cli/attach.ts:160-163`, `:119-123`). See §10 before you copy this.

### 3.2 The 100 ms deadline — exact semantics

`RESUME_TIMEOUT_MS = 100` (`main.rs:63`), applied at `main.rs:2294-2298`:

```rust
let resume_result = tokio::time::timeout(
    Duration::from_millis(RESUME_TIMEOUT_MS),
    read_first_message(&mut reader, &mut pending),
).await;
```

Outcomes (`main.rs:2300-2334`):

| First frame within 100 ms | Host behaviour |
|---|---|
| `RESUME` (0x10) | `handle_resume` — delta or full (`:2302-2304`) |
| `OBSERVE` (0x26) | no replay, no SYNC; observer mode (`:2305-2309`) |
| `SPARKLINE_REQUEST` (0x18) | sparkline reply only, no replay (`:2310-2315`) |
| any other type | **full replay first**, then that message is processed (`:2316-2321`) |
| socket closed | client dropped (`:2323-2326`) |
| **nothing (timeout)** | **full replay** (`:2327-2334`) |

**Critical**: after the timeout path, the host enters the normal read loop, where
`process_client_message` has **no `RESUME` arm** — `RESUME` falls into `_ => {}`
(`main.rs:2631-2633`). A late `RESUME` is therefore **silently discarded**, and you have already
been handed a full replay. Missing the 100 ms window costs you the delta, not just latency.

### 3.3 Server-side handshake output order

`send_replay` (`main.rs:2524-2602`) always emits, in this order:

```
 1. RESIZE(cols, rows)                     always, even if the replay body is empty  (:2526-2535)
 2. BUFFER_REPLAY | BUFFER_REPLAY_GZ       only if the body is non-empty             (:2544-2575)
 3. SYNC(total_written)                    always                                    (:2577-2587)
 4. TITLE(title)                           only if a title is known                  (:2588-2594)
 5. SESSION_STATE(0|1)                     always                                    (:2596-2600)
```

Prepended by `SYNC(0.0)` when the requested offset is too old (`main.rs:2495-2502`,
`send_cache_reset` `:2508-2515`). Appended by `EXIT(code)` when the session already exited
(`main.rs:2340-2350`).

So the two full wire sequences are:

```
fresh attach   (RESUME offset=0):
  RESIZE -> [REPLAY|REPLAY_GZ]? -> SYNC(total) -> TITLE? -> SESSION_STATE

stale reconnect (RESUME offset too old):
  SYNC(0) -> RESIZE -> [REPLAY|REPLAY_GZ]? -> SYNC(total) -> TITLE? -> SESSION_STATE
```

### 3.4 Offset accounting — exact rules

`_offset` is a float64 byte counter initialised from `initialOffset ?? 0`
(`session-stream.ts:97`). The **only** four things that change it
(`session-stream.ts:296-373`):

| Event | Effect on `offset` | Line |
|---|---|---|
| `BUFFER_REPLAY` (0x03) | **no change** | `:303-305` |
| `BUFFER_REPLAY_GZ` (0x13) | **no change** | `:306-313` |
| `SYNC(v)` where `v == 0 && offset > 0` | `offset = 0`, emit `cacheReset` | `:317-320` |
| `SYNC(v)` otherwise | `offset = v` (absolute assignment) | `:321` |
| `DATA(p)` | `offset += p.length` | `:327` |
| `CLEAR_SCROLLBACK` (0x23) | `offset = 0` | `:362` |

Everything else — `RESIZE`, `TITLE`, `EXIT`, `NOTIFICATION`, `SESSION_STATE`,
`SESSION_METRICS`, `SESSION_UPDATE`, `CLIPBOARD`, `IMAGE`, `SPARKLINE_HISTORY`, `PONG` —
**does not touch the offset.**

Why replays do not count: the host computes the replay body and then reports `total_written`
in the trailing `SYNC`. The `SYNC` is an **absolute assignment**, so it already accounts for
every byte the replay contained. If you also added `replay.length` you would double-count and
the next reconnect would request bytes you never received (lost output).

### 3.5 Delta classification

```ts
case WS_MSG.BUFFER_REPLAY:
  this.emit("replay", p, { isDelta: this._offset > 0 });
```
`session-stream.ts:303-305`.

`isDelta` is decided from the offset **at the moment the frame arrives**, before any `SYNC`.
For the gzip variant the flag is captured **synchronously before** the async inflate resolves
(`session-stream.ts:307-311`) — do the same in Swift, or a concurrent `SYNC` will flip the
classification.

* `isDelta == false` ⇒ the body is a full screen dump; **reset the terminal emulator** and feed
  it. Preceded by `SYNC(0)` in the cache-reset case, which is what drives `offset` back to 0.
* `isDelta == true` ⇒ append to existing content; do **not** clear.

### 3.6 Reconnect

`session-stream.ts:144-158`, `:248-266`.

1. On transport close with code `4001` or `1008` ⇒ auth error, **no reconnect**, status closed.
2. If `exited` (an `EXIT` was seen) or disposed ⇒ no reconnect.
3. Otherwise consult `shouldReconnect()`, then back off: `baseMs * factor^n` capped at `maxMs`.
   CLI local policy `{ base 500, max 5000, factor 1.5 }` (`cli/attach.ts:47`,
   `cli/directory.ts:55`, `:70`); browser `{ base 1000, max 15000, factor 1.5 }`
   (`app/lib/browser-stream.ts:10`). Library defaults are `1000 / 10000 / 1.5`
   (`session-stream.ts:79-81`).
4. On the new connection, send `RESUME(currentOffset)` again — the same code path, so a
   reconnect is just another handshake.

The CLI's `shouldReconnect` stops retrying once the socket file is gone or the session JSON
says `status === "exited"` (`cli/attach.ts:48-57`) — replicate this or you will spin forever
against a dead session.

### 3.7 Duplication and loss hazards at attach

* The broadcast subscription for a client is created at **accept** time
  (`main.rs:2197`), before `handle_client` runs. Live `DATA` frames can therefore be written
  by the broadcast task **interleaved with, or ahead of,** the replay body. Expect a small
  amount of duplicated output at attach; the reference client simply writes both to the
  terminal (`cli/attach.ts:143-151`). The trailing `SYNC` makes the offset correct regardless.
* The broadcast channel holds **256 frames** (`main.rs:1630`). A slow reader gets
  `RecvError::Lagged(n)` and those `n` frames are **dropped silently** to that client, with
  only a rate-limited stderr log (`main.rs:2213-2224`). Because `offset` advances only on
  frames actually received, a subsequent reconnect + `RESUME(offset)` repairs the gap exactly —
  which is the only recovery. **Drain the socket promptly**, and treat a suspected stall as a
  reason to reconnect.

---

## 4. Gzip: `BUFFER_REPLAY_GZ` is **gzip-wrapped**, not raw deflate

`crates/pty-host/src/main.rs:2545-2556`:

```rust
if cleaned.len() >= GZIP_THRESHOLD {
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&cleaned).ok();
    if let Ok(compressed) = encoder.finish() {
        if compressed.len() < cleaned.len() {
            let mut msg = Vec::with_capacity(1 + compressed.len());
            msg.push(WS_MSG_BUFFER_REPLAY_GZ);
            msg.extend_from_slice(&compressed);
```

`flate2::write::GzEncoder` (imported `main.rs:18-19`) produces a complete **RFC 1952 gzip
member**: 10-byte header starting `1f 8b 08`, deflate stream, 8-byte trailer (CRC32 + ISIZE).
It is **not** raw deflate and **not** zlib/RFC 1950.

Confirmed on the consuming side: Node uses `zlib.gunzipSync` (`cli/attach.ts:8`, `:37`), the
browser uses `new DecompressionStream("gzip")` (`app/lib/browser-stream.ts:15`).

Emission rules:

| Condition | Frame sent |
|---|---|
| `cleaned.len() < 4096` (`GZIP_THRESHOLD`, `main.rs:59`) | `BUFFER_REPLAY` (0x03) |
| `>= 4096` and `compressed.len() < cleaned.len()` | `BUFFER_REPLAY_GZ` (0x13) |
| `>= 4096` and compression did not help | `BUFFER_REPLAY` (0x03) (`main.rs:2557-2565`) |
| `cleaned` empty | **no frame at all** (`main.rs:2544`) |

Both replay types use the same threshold logic — a **delta** can also arrive gzipped, since
`send_replay` is shared (`main.rs:2493`, `:2501`, `:2521`).

### What a Swift client feeds the decompressor

Apple's `Compression` framework has **no gzip container support**. `COMPRESSION_ZLIB` is
*raw DEFLATE* (despite the name), so you must strip the container yourself, or use zlib.

**Recommended — zlib with gzip auto-detect** (libz ships with macOS):

```c
z_stream s = {0};
inflateInit2(&s, 16 + MAX_WBITS);   // 16+15 = gzip only;  32+15 = auto-detect zlib|gzip
// feed the whole 0x13 payload (bytes after the type byte) as next_in
```

**Alternative — `Compression` framework**: strip the header and trailer before inflating raw
deflate.

```
gzip member layout (RFC 1952):

  0    1     2      3      4..7   8    9      variable                    tail
  +----+----+------+------+------+----+----+ ... +-------------------+----+----+
  |1f  |8b  | CM=08| FLG  | MTIME| XFL| OS | [optional fields]       |CRC32|ISIZE|
  +----+----+------+------+------+----+----+ ... +-------------------+----+----+
   <-------- fixed 10-byte header -------->                           <- 8 B ->

  FLG bit 2 (FEXTRA)  -> [u16 LE xlen][xlen bytes]
  FLG bit 3 (FNAME)   -> NUL-terminated name
  FLG bit 4 (FCOMMENT)-> NUL-terminated comment
  FLG bit 1 (FHCRC)   -> 2 bytes
```

flate2 with default options writes `FLG = 0`, so in practice the header is exactly 10 bytes and
the payload is `p[10 ..< p.count-8]` — but parse `FLG` rather than assuming, and always prefer
the zlib path.

---

## 5. Heartbeat and zombie detection

Reference policy (`session-stream.ts:268-294`):

```ts
heartbeat?: { intervalMs: number; zombieMs: number }
// every intervalMs: if (now - lastServerMessage > zombieMs) -> close + scheduleReconnect
//                   else -> send PING (0x20)
```

`lastServerMessage` is refreshed on **every** inbound frame, not just `PONG`
(`session-stream.ts:297`).

| Client | Policy | Source |
|---|---|---|
| Browser (WebSocket) | `intervalMs: 10_000`, `zombieMs: 45_000` | `app/lib/browser-stream.ts:12` |
| CLI remote (WebSocket) | `intervalMs: 10_000`, `zombieMs: 45_000` | `cli/directory.ts:56` |
| CLI local (**Unix socket**) | **no heartbeat configured** | `cli/attach.ts:43-58`, `cli/directory.ts:64-80` |

### Required over WebSocket, forbidden over Unix socket

**pty-host does not implement `PING`/`PONG`.** The constants are absent from `main.rs:34-53`
and `PING` lands in the ignore arm of `process_client_message` (`main.rs:2631-2633`). Only the
Node WS bridge answers, and it answers locally without forwarding
(`ws-handler.ts:452-456`, read-only path `:326-330`).

Therefore:

* **Unix socket**: do **not** enable a heartbeat. A `PING` gets no reply, and on a session that
  produces no output for 45 s the zombie timer would tear down a perfectly healthy connection.
  Detect death via socket EOF plus the pid-liveness rules in §6.
* **WebSocket**: enable it. This is what survives Cloudflare Tunnel's ~100 s idle timeout and
  detects half-open TCP. The WS server independently runs protocol-level WS pings every
  **30 s** and terminates a client that missed the previous one (`ws-handler.ts:13`,
  `:130-144`) — that is transparent to `URLSessionWebSocketTask`, which answers automatically.

`reconnectNow()` (`session-stream.ts:171-183`) is the foreground/network-return hook: if
connected it sends a `PING` to force the zombie check; if a retry is pending it fires it
immediately with the backoff reset. Worth mirroring for macOS wake-from-sleep.

---

## 6. Session discovery

### 6.1 File layout

```
~/.relay-tty/
  sessions/<id>.json      one file per session, pty-host is the ONLY writer
  sockets/<id>.sock       Unix stream socket, one per live session
  project-roots.txt       see §14
  commands.txt            see §14
  upload-dir.txt          upload target override
  notifications.json      server notification store
  scratchpad.hst          web scratchpad history
  uploads/                default upload dir
```

Paths: `shared/client/directory-disk-node.ts:13-15`, `main.rs:1516-1524`.
`<id>` is 8 lowercase hex chars — `randomBytes(4).toString("hex")`
(`cli/spawn.ts:19`, `server/pty-manager.ts:120`). Server routes only match `[a-f0-9]+`
(`server/ws-handler.ts:158`, `server/auth.ts:30-33`).

### 6.2 `sessions/<id>.json` schema

Written by `SessionMeta` (`main.rs:1132-1173`, `#[serde(rename_all = "camelCase")]`), read
as `Session` (`shared/types.ts:3-39`). Fields with `skip_serializing_if` are **absent**, not
null, when unset.

| Field | JSON type | Optional | Meaning / source |
|---|---|---|---|
| `id` | string | no | 8 hex chars |
| `command` | string | no | display command — `RELAY_ORIG_COMMAND` if set, else argv `<command>` (`main.rs:1502`) |
| `args` | string[] | no | display args — `RELAY_ORIG_ARGS` (JSON array) if set (`main.rs:1503-1506`) |
| `cwd` | string | no | **live** cwd of the session leader — §7 |
| `createdAt` | number (epoch ms) | no | `main.rs:1590` |
| `lastActivity` | number (epoch ms) | no | last PTY output (`main.rs:1828`) |
| `status` | `"running"` \| `"exited"` | no | |
| `exitCode` | number (i32) | **yes** | absent while running |
| `exitedAt` | number (epoch ms) | **yes** | |
| `cols` | number (u16) | no | current PTY size |
| `rows` | number (u16) | no | current PTY size |
| `pid` | number (u32) | no from Rust (`?` in TS) | **pty-host's own pid**, not the shell's (`main.rs:1597` = `process::id()`) |
| `startedAt` | string ISO-8601 | no | `main.rs:1598` |
| `totalBytesWritten` | number (**f64**, serializes as `419294.0`) | no | reset to 0 by `CLEAR_SCROLLBACK` (`main.rs:1472`) |
| `lastActiveAt` | string ISO-8601 | no | |
| `bytesPerSecond` | number (f64) | no | legacy alias of `bps1` |
| `title` | string | **yes** | OSC 0/2 or `SET_TITLE` |
| `titlePinned` | bool | **yes — only serialized when `true`** (`main.rs:1156`) | |
| `error` | string | **yes** | **present in Rust, missing from the TS `Session` interface** — set on spawn failure (`main.rs:1159`, `:1563`) |
| `bps1` / `bps5` / `bps15` | number (f64) | no | rolling byte/s over 60 / 300 / 900 s |
| `foregroundProcess` | string | **yes** | §7 |
| `agentState` | `"working"`\|`"blocked"`\|`"done"`\|`"idle"`\|`"unknown"` | no | `agent_state.rs:9-17`, `:82-114` |
| `agentStateChangedAt` | number (epoch ms) | no | |

Writes are atomic (`tmp` + `rename`, `main.rs:2686-2701`), so a reader never sees a torn file —
but it **will** see the `<id>.json.tmp` path appear and vanish. Ignore anything not ending in
`.json` (`directory-disk-node.ts:80`, `:108`), and specifically ignore `.json.tmp`
(`pty-manager.ts:302`).

Flush cadence: dirty metadata every **5 s** (`JSON_WRITE_INTERVAL_MS`, `main.rs:61`,
`:2032-2067`); immediate atomic write on **title change** (`main.rs:1771`), on **`agentState`
transition** (`main.rs:2147`), on **`SET_TITLE`** (`main.rs:1996`, `:2004`), and on **exit**
(`main.rs:1886`).

### 6.3 Liveness rules

`readOne()` in `shared/client/directory-disk-node.ts:49-73` — reproduce this exactly:

```ts
const EXITED_TTL_MS = 60 * 60 * 1000;   // :17

1. read+parse sessions/<id>.json
   - ENOENT           -> gone (null)
   - any other error  -> DELETE the file (corrupt) and return null      (:55-57)
2. if (!meta.cwd) meta.cwd = homedir()                                   (:59)
3. if (status === "running" && !(pid && isPidAlive(pid))):               (:60-66)
       status   = "exited"
       exitCode = -1
       exitedAt = Date.now()
       write the file back
       unlink sockets/<id>.sock
4. if (status === "exited" && now - (exitedAt || createdAt) > 1h):       (:67-71)
       unlink sessions/<id>.json
       unlink sockets/<id>.sock
       return null
```

`isPidAlive` is `process.kill(pid, 0)` in a try/catch (`:21-28`) — in Swift, `kill(pid, 0) == 0`
or `errno == EPERM`.

`scan()` additionally deletes **orphan sockets** — any `sockets/*.sock` with no surviving
session id (`:87-93`) — and sorts newest-first by `createdAt` (`:94`).

`list()` filters out `status === "exited"` unless `includeExited` (`:138-141`).

A third-party client may reasonably choose to perform only the read-only parts (steps 1-2,
plus the pid check as a *display* signal) and leave the destructive cleanup to RelayTTY.
RelayTTY itself expects any reader to do the cleanup, so both behaviours are compatible.

### 6.4 Watching for changes

`directory-disk-node.ts:104-124`. The confirmed numbers:

| Constant | Value | Line |
|---|---|---|
| `DEBOUNCE_MS` | **200 ms** | `:18` |
| `POLL_MS` | **2000 ms** | `:19` |
| `EXITED_TTL_MS` | 1 h | `:17` |

Mechanism, precisely:

1. `startWatching()` primes `known` from a full `scan()` (`:105`).
2. `fs.watch(sessionsDir)` — a directory watcher, **not** per-file. Events for filenames not
   ending in `.json` are dropped (`:107-109`).
3. Per-session-id **200 ms debounce**: each event resets that id's timer; on fire, `reconcile(id)`
   re-reads just that file (`:110-115`).
4. **The 2 s poll is a fallback, not a companion.** `setInterval(refreshAll, POLL_MS)` starts
   only if `fs.watch` throws at setup (`:121-123`) or emits an `error` afterwards, in which case
   the watcher is discarded (`:117-120`). A healthy watcher means **no polling**.
5. Watching stops when the last subscriber unsubscribes (`:148-151`).

Events are derived by `reconcileOne` / `reconcileSnapshot`
(`shared/client/session-directory.ts:39-80`):

| Condition | Event |
|---|---|
| not previously known | `{ type: "created", session }` |
| `prev.status === "running" && next.status === "exited"` | `{ type: "exited", session }` |
| any other field differs (JSON-stringify compare, `id` excluded) | `{ type: "updated", session, changed[] }` |
| present in `known` but absent from the snapshot | `{ type: "removed", id }` |

On macOS, `FSEventStreamCreate` on `~/.relay-tty/sessions` or a
`DispatchSource.makeFileSystemObjectSource(.write)` on the directory fd is the equivalent.
Keep the 200 ms debounce: the atomic `rename` plus the 5 s flush produce bursts.

**Remote alternative**: `GET {base}/api/sessions` (+ `?includeExited=1`) and a WS to
`/ws/events`, which delivers the text `"sessions-changed"` on membership changes and binary
`SESSION_UPDATE` frames on metadata changes (`shared/client/directory-remote.ts:1-70`,
`ws-handler.ts:174-182`, `:55-57`).

---

## 7. CWD reporting — definitive

### Answer

**(b): `cwd` in `sessions/<id>.json` is updated live as the user `cd`s** — for shell
sessions. It is not merely the launch cwd. Two independent writers, both inside pty-host:

**Writer 1 — OSC 7, immediate.** `main.rs:1782-1789`:

```rust
// Parse OSC 7 CWD notification
if let Some(new_cwd) = parse_osc7_cwd(data) {
    let mut s = state_pty.write().await;
    if s.meta.cwd != new_cwd {
        s.meta.cwd = new_cwd;
        s.meta_dirty = true;
    }
}
```

Runs on every PTY read chunk. `parse_osc7_cwd` accepts `ESC ] 7 ; file://host/path BEL` or
`... ST`, percent-decodes the path (`main.rs:562-620`). Note it only sets `meta_dirty` — it does
**not** force a disk write, so it reaches disk at the next 5 s flush.

**Writer 2 — `/proc`-equivalent polling, every 5 s.** `main.rs:2036-2051`:

```rust
// Poll shell process CWD — works even without OSC 7 support.
// Query the shell (child_pid) since it tracks `cd` changes.
let polled_cwd = get_process_cwd(child_pid);
...
if let Some(ref new_cwd) = polled_cwd {
    if s.meta.cwd != *new_cwd {
        s.meta.cwd = new_cwd.clone();
        s.meta_dirty = true;
    }
}
```

`get_process_cwd` (`main.rs:1087-1128`) uses `proc_pidinfo(PROC_PIDVNODEPATHINFO)` on macOS
(struct size 2352, cwd path at offset 152) and `readlink /proc/<pid>/cwd` on Linux. This works
with no shell cooperation at all, which is why a plain `zsh` session shows a live cwd here.

**Effective latency: ≤ 5 s**, both paths, because both only mark `meta_dirty` and the flush task
is on a 5 s interval. An unrelated `agentState` transition can flush earlier (`main.rs:2147`).

### The important caveat: which pid is polled

`get_process_cwd(child_pid)` polls the **session leader**, i.e. whatever pty-host `exec`'d, not
the current foreground process. What that is depends on how the session was created
(`shared/spawn-utils.ts:45-70`):

| Session kind | argv to pty-host | `child_pid` is | `cwd` behaviour |
|---|---|---|---|
| Shell (`zsh`, `bash`, …) | `[id, cols, rows, cwd, /bin/zsh, --login]` | the interactive shell | **tracks `cd` live** |
| Non-shell (`claude`, `htop`, …) | `[id, cols, rows, cwd, $SHELL, -li, -c, "exec claude …"]` | `exec` replaces the shell, so it is **the command itself** | effectively **static** at the launch dir, unless that program chdirs |

Both example session files on this machine bear this out: a `/bin/zsh` session and a `claude`
session each carry a real project path, but only the shell one will move.

### Does `SESSION_UPDATE` (0x15) push an updated cwd?

**Yes — but only over WebSocket, and never from pty-host.**

* pty-host has no `0x15` constant (`main.rs:34-53`) and never emits it.
* `server/ws-handler.ts:45-52` subscribes to `PtyManager`'s `"session-update"`;
  `:65-77` serialises the **entire merged `Session`** (cwd included) as
  `[0x15][UTF-8 JSON]` and sends it to **all** WS clients.
* That event originates from `fs.watch` on the sessions dir with a 200 ms debounce and a
  field diff (`pty-manager.ts:292-319`, `:332-382`).

So over WS the cwd push latency is **pty-host flush (≤ 5 s) + watcher debounce (200 ms)**.

### `foregroundProcess` — how it is derived

`main.rs:2102-2119`, in the 1 Hz metrics task:

```rust
let fg_pgrp = unsafe { libc::tcgetpgrp(master_raw_fd) };
let fg_process = if fg_pgrp > 0 && fg_pgrp != child_pid {
    get_process_name(fg_pgrp)
} else {
    None
};
```

* `tcgetpgrp` on the **master** fd returns the slave's foreground process group.
* **Absent when the session leader is itself in the foreground** — i.e. a shell sitting at its
  prompt has no `foregroundProcess`, and a non-shell session (where `child_pid` *is* the program)
  also reports none.
* `get_process_name` (`main.rs:1050-1079`) is `libproc proc_name()` on macOS
  (`/proc/<pid>/comm` on Linux) — the **comm name**, truncated, not argv.
* Practical consequence, and the reason `agent_state.rs:71-80` exists: Claude Code's native
  binary reports its comm name as its version string, so you will literally see
  `"foregroundProcess": "2.1.268"` in the JSON. `is_semver_name()` treats a bare
  `MAJOR.MINOR.PATCH` as Claude Code.
* Reaches disk only via `meta_dirty` (5 s flush) — but an `agentState` change forces an
  immediate write, and those usually coincide.

### What MaxPane can know about live cwd with **no protocol change**

| Scenario | Mechanism | Latency | Reliability |
|---|---|---|---|
| **LOCAL** (same Mac, Unix socket) | Watch `~/.relay-tty/sessions/<id>.json`; read `cwd` | ≤ 5 s (+ your debounce) | High for shell sessions; static for wrapped-command sessions |
| **LOCAL**, sub-second | **Sniff OSC 7 out of the `DATA` stream yourself** | immediate | Requires the shell to emit OSC 7 (zsh with `precmd`, fish, iTerm2 shell integration). pty-host reads OSC 7 but does **not** strip it — the extractor removes only OSC 9 / 52 / 1337 (`main.rs:965-995`, `:978-980`), so the `ESC]7;file://…` bytes are still in `DATA` and in replays. |
| **REMOTE** (WS to the relay server) | `SESSION_UPDATE` (0x15) on any `/ws/sessions/:id` or `/ws/events` socket; filter by `session.id` | ≤ 5 s + 200 ms | Same shell/command caveat |
| **REMOTE**, fallback | Poll `GET {base}/api/sessions` | your interval | Same |

There is **no** protocol frame that pushes cwd from pty-host over a Unix socket. For a local
pane the file watcher is the baseline; add the OSC 7 sniff if you want it instant. Combining
both is safe — OSC 7 is authoritative and immediate, the file is the floor.

---

## 8. Spawning a new session

### Path (a) — HTTP POST to the local relay server

**Discovering the base URL.** `cli/config.ts:5-39`:

```ts
const CONFIG_DIR  = path.join(os.homedir(), ".config", "relay-tty");
const SERVER_FILE = path.join(CONFIG_DIR, "server.json");

export function readServerInfo(): ServerInfo | null   // { url, pid, startedAt }
export function resolveHost(explicit?: string): string
// 1. explicit --host
// 2. ~/.config/relay-tty/server.json .url
// 3. "http://localhost:7680"
```

`~/.config/relay-tty/server.json` is written by the server on listen and removed on shutdown
(`server.js:33-44`, `:187`). Its shape:

```json
{ "url": "http://localhost:7680", "pid": 12345, "startedAt": 1789209706105 }
```

Port default `7680`, overridable with `PORT` (`server.js:12`). Treat the file's presence as
"a server is (probably) running" and verify `pid` liveness before trusting it — nothing else
does.

**Request.**

```
POST {base}/api/sessions
Content-Type: application/json

{
  "command": "/bin/zsh",     // required; the literal "$SHELL" is resolved server-side
  "args":    [],             // optional, default []
  "cwd":     "/Users/me/code/max-pane",   // optional, default process.env.HOME || "/"
  "cols":    80,             // optional, default 80
  "rows":    24              // optional, default 24
}
```

`server/api.ts:107-130`. `"$SHELL"` → `process.env.SHELL || "/bin/sh"` (`:117-119`).
Missing `command` ⇒ `400 {"error":"command is required"}`.

**Response** `201`:

```json
{
  "session": { /* full Session, see §6.2 — but only the fields pty-manager fills in */ },
  "url": "http://localhost:7680/sessions/a7ab2d3b"
}
```

The `session` object here is the one `PtyManager.spawn` constructed
(`pty-manager.ts:143-153`) — `id, command, args, cwd, createdAt, lastActivity, status, cols,
rows` — **not** the richer on-disk metadata. Read `sessions/<id>.json` for the rest.

**Readiness**: the server `await`s socket connectability before responding
(`pty-manager.ts:158-161`, `waitForSocket` at `:414-...` with the same 50→500 ms backoff and 3 s
deadline as the CLI). On `201`, `~/.relay-tty/sockets/<id>.sock` is connectable.

**Auth**: none needed from localhost — see §9.

### Path (b) — direct spawn of `relay-pty-host`

**argv** (`main.rs:5`, `:1482-1499`):

```
relay-pty-host <id> <cols> <rows> <cwd> <command> [args...]
```

built by `shared/spawn-utils.ts:45-70`:

```ts
if (isShellCommand(command))                       // basename in {sh,bash,zsh,fish,ksh,tcsh,csh,dash}
  return [id, cols, rows, cwd, command, "--login", ...args];

const userShell = resolveShell();                  // $SHELL if executable, else /bin/sh
const fullCmd = args.length
  ? `exec ${shellEscape(command)} ${args.map(shellEscape).join(" ")}`
  : `exec ${shellEscape(command)}`;
return [id, cols, rows, cwd, userShell, "-li", "-c", fullCmd];
```

`--login` is consumed by pty-host, not passed to the child: it sets `argv[0]` to `-<basename>`
(`main.rs:1495-1499`, `:1349-1359`).

**id**: `randomBytes(4).toString("hex")` — 8 lowercase hex chars (`cli/spawn.ts:19`). Must match
`[a-f0-9]+` or the server's WS/API routes will not accept it.

**Socket path**: chosen by pty-host itself as `$HOME/.relay-tty/sockets/<id>.sock`; the sessions
and sockets dirs are created if missing and a stale socket at that path is unlinked first
(`main.rs:1516-1527`). Callers merely predict it (`cli/spawn.ts:32`).

**env** (`cli/spawn.ts:25-29`, `server/pty-manager.ts:125-140`):

```
inherit the parent environment, plus:
  RELAY_SESSION_ID    = <id>
  RELAY_ORIG_COMMAND  = <command>                  # display metadata only
  RELAY_ORIG_ARGS     = JSON.stringify(args)       # display metadata only
```

pty-host reads and then **deletes** the two `RELAY_ORIG_*` vars so they do not leak to the child,
and re-asserts `RELAY_SESSION_ID` unconditionally (`main.rs:1501-1514`). It also forces
`TERM=xterm-256color` and `TERM_PROGRAM=relay-tty` in the child (`main.rs:1336-1337`).

Spawn **detached** with stdio ignored (`cli/spawn.ts:25-30`).

**Binary location** (`shared/spawn-utils.ts:79-105`), in order:

1. `<projectRoot>/crates/pty-host/target/release/relay-pty-host`
2. `<projectRoot>/bin/relay-pty-host`

For an installed npm package that is `<npm prefix>/lib/node_modules/relay-tty/bin/relay-pty-host`.
A robust discovery for MaxPane: `realpath(which relay)` → `…/relay-tty/dist/cli/index.js` → up
three levels → `bin/relay-pty-host`. Verified present on this machine at
`/Users/spierce/.nvm/versions/node/v22.23.2/lib/node_modules/relay-tty/bin/relay-pty-host`.
Make it a user-overridable setting; there is no stable well-known path.

**Waiting for readiness** (`cli/spawn.ts:42-71`):

```
deadline = now + 3000ms; delay = 50ms
loop while now < deadline:
    if pid known and not alive        -> fail immediately ("exited before socket became ready")
    if socket file exists:
        try connect(); on success -> READY
    sleep(delay); delay = min(delay*2, 500)
return timeout
```

Existence of the `.sock` file is **not** sufficient — a successful `connect()` is the test.

### Recommendation for MaxPane

**Use (b), direct spawn, as the primary path; fall back to (a) only if the binary cannot be
located.**

Reasons:

1. **No dependency on the Node server process.** `~/.config/relay-tty/server.json` may be stale
   or absent; the file is only removed on a clean shutdown (`server.js:43`). A pane that cannot
   open a terminal because a web server is not running is a bad failure mode.
2. **No HTTP or auth surface.** The localhost bypass is IP-based and explicitly fragile
   (`server/auth.ts:44-55`); staying off it avoids ever depending on it.
3. **Identical result.** The server's own `spawn` is the same three lines — `resolveRustBinaryPath`
   + `buildSpawnArgs` + detached `child_process.spawn` (`pty-manager.ts:132-141`) — and the CLI's
   `relay run` uses the direct path too (`cli/commands/run.ts:36`).
4. **The server still sees it.** `PtyManager`'s file watcher auto-discovers CLI-spawned sessions
   and starts a monitor for them (`pty-manager.ts:338-347`), and `ensureMonitor` handles a WS
   client arriving first (`:210-243`). A MaxPane-spawned session shows up in the web UI.

The one real cost is locating the binary. Use (a) as the fallback when `server.json` exists and
its pid is alive, since it needs no binary path at all.

---

## 9. Auth

`server/auth.ts`. **Nothing is required from localhost, for both HTTP and WS.**

**HTTP** — `authMiddleware` (`auth.ts:335-339`) short-circuits:

```ts
export function authMiddleware(req, res, next) {
  if (isLocalhost(req)) { next(); return; }
  ...
```

installed before the API router (`server.js:69`, `:78`).

**WebSocket** — `verifyWsAuth` (`auth.ts:421-429`):

```ts
const ip = req.socket.remoteAddress || "";
const isLocal = ip === "127.0.0.1" || ip === "::1" || ip === "::ffff:127.0.0.1";
const isCfTunnel    = isLocal && !!req.headers["cf-connecting-ip"];
const isRelayTunnel = isLocal && !!req.headers["x-relay-tunnel"];
if (isLocal && !isCfTunnel && !isRelayTunnel) return true;
```

called at the upgrade in `server.js:178` (skipped entirely for `/ws/share`).

`isLocalhost` (`auth.ts:57-76`) accepts `127.0.0.1`, `::1`, `::ffff:127.0.0.1`, `localhost`,
then **revokes** the bypass if `Cf-Connecting-Ip` or `X-Relay-Tunnel` is present — those mean
the request arrived through a tunnel even though the TCP peer is loopback. Do not send either
header.

Remote / non-localhost requires one of:

| Credential | Scope | Where |
|---|---|---|
| `session` cookie — HS256 JWT, `iss: "relay-tty"`, optional `exp` | full owner access | `auth.ts:84-120`, `:365-372`, minted via `GET /api/auth/callback?token=…` (`server.js:96`) |
| `relay_grant` cookie — `<grantId>.<HMAC-SHA256>` | **one session only**, plus `/api/pair/logout` and `/api/pair/whoami` | `auth.ts:304-313`, `:374-393`, `:440-452` |
| `?token=` share JWT on `/ws/share` | one session, **read-only** (only `RESUME` is forwarded) | `ws-handler.ts:199-246`, `:270-342` |

If `JWT_SECRET` is unset the server is wide open (`auth.ts:326`, `:341-344`, `:429`).

**WS auth failures**: `/ws/share` completes the upgrade and then closes with **4001** plus a
reason (`ws-handler.ts:226-232`); the reference client treats close codes **4001** and **1008**
as terminal auth errors and stops reconnecting (`session-stream.ts:148-152`). Other upgrade
rejections just destroy the socket, which the client sees as an ordinary close.

**MaxPane**: connecting to the Unix socket directly bypasses all of this — pty-host performs
**no authentication whatsoever**; filesystem permissions on `~/.relay-tty/sockets/` (mode 755,
owned by the user) are the only control.

---

## 10. RESIZE semantics — one PTY, last writer wins

There is **no per-client viewport.** A PTY has exactly one `winsize`.

`main.rs:1911-1931`:

```rust
while let Some((new_cols, new_rows)) = resize_rx.recv().await {
    let s = state_resize.read().await;
    if s.meta.cols == new_cols && s.meta.rows == new_rows {
        continue;              // Skip redundant resize — avoids SIGWINCH -> full TUI redraw
    }
    drop(s);
    resize_pty(master_raw_fd, new_cols, new_rows);
    ... s.meta.cols = new_cols; s.meta.rows = new_rows;
    // Broadcast RESIZE to all clients so read-only viewers stay in sync
```

* **Last writer wins**, globally. Every client's `RESIZE` goes into one shared mpsc channel
  (`main.rs:1639`, `:2609-2614`); the most recent non-redundant one defines the PTY size for
  everybody.
* Redundant resizes are dropped, so a client re-asserting the size already in effect is free.
* Each accepted resize does `ioctl(TIOCSWINSZ)` **and** an explicit
  `kill(-fg_pgrp, SIGWINCH)` (`main.rs:1400-1426`) — belt and suspenders for NeoVim/libuv. Full
  TUI redraws follow.
* The new size is broadcast as `RESIZE` (0x01) to all clients (`main.rs:1926-1929`), and is also
  the first frame of every replay (`main.rs:2526-2535`). **The host is authoritative; believe
  the inbound frame.**
* `notify_resize()` discards captured alt-screen content on resize, because it is about to be
  redrawn (`main.rs:287-292`, `:1923`).

### Consequence for narrow portrait panes

The reference CLI sends `RESIZE` on **every** transition to `connected`
(`cli/attach.ts:160-163`) and on every `SIGWINCH` (`:94`, `:119-123`). A phone on the same
session does the same from the browser. If MaxPane also asserts its narrow width, the three
clients will fight, and every flip triggers a full redraw of whatever TUI is running.

Options, in descending order of politeness:

1. **Observer mode** (`OBSERVE`, 0x26) and never send `RESIZE`. The pane is read-only and
   uncounted. Cost: no replay at attach, so the pane starts blank until new output arrives —
   usually disqualifying for a visible pane.
2. **Attach normally, never send `RESIZE`.** Render at whatever `cols`/`rows` the host reports
   (the leading `RESIZE` frame, plus `cols`/`rows` in the session JSON) and letterbox, scale the
   font, or horizontally scroll inside the narrow column. This is the recommended default for
   MaxPane.
3. **Send `RESIZE` only on explicit user action** ("claim this session"), never automatically on
   connect, focus, or window resize.

Whichever you choose, always honour inbound `RESIZE` — it is the only way to learn that a phone
just reshaped the PTY under you.

---

## 11. TITLE and `titlePinned`

### OSC title → `TITLE` (0x04)

`main.rs:1761-1780`, on every raw PTY read chunk:

```rust
if let Some(new_title) = parse_osc_title(data) {
    let title_changed = !s.title_pinned && s.title.as_deref() != Some(&new_title);
    if title_changed {
        s.title = Some(new_title.clone());
        s.meta.title = Some(new_title.clone());
        atomic_write_json(&session_path_pty, &s.meta);   // immediate flush, for discovery
        // broadcast TITLE
    }
}
```

* `parse_osc_title` matches `ESC ] 0 ;` or `ESC ] 2 ;` terminated by `BEL` (0x07) or `ST`
  (`ESC \`), and returns only the **first** match in the chunk (`main.rs:529-557`). A chunk
  containing two title changes reports one.
* It runs on the **raw** chunk, before OSC extraction — and the title OSC is **not removed**
  from `DATA`. Your embedded terminal will see and honour it too.
* The title is written to disk **immediately** (not on the 5 s tick) because discovery depends
  on it.
* Suppressed entirely while pinned.
* The current title is replayed at the end of every handshake, but **only if one is known**
  (`main.rs:2588-2594`). No title ⇒ no `TITLE` frame.

### `SET_TITLE` (0x24) and pinning

`main.rs:1989-2011`:

| Payload | Effect |
|---|---|
| non-empty UTF-8 | trimmed (`main.rs:2623`); `title` and `meta.title` set; `title_pinned = true`; `meta.titlePinned = true`; immediate atomic JSON write; **`TITLE` broadcast to all clients** |
| empty | `title_pinned = false` and `meta.titlePinned = false` only — the current title is **kept**, the next OSC title will overwrite it, and **no `TITLE` frame is broadcast** (`main.rs:1992-1998`) |

`titlePinned` is serialized only when `true`
(`#[serde(default, skip_serializing_if = "std::ops::Not::not")]`, `main.rs:1156-1157`), so treat
an absent key as `false` (`shared/types.ts:38`).

Encoder for reference: `encodeSetTitle` is `[0x24] + UTF-8 bytes` (`messages.ts:53`).

---

## 12. Scrollback: ring buffer and replay contents

### Sizes

| Buffer | Size | Line |
|---|---|---|
| Main ring (`BUFFER_SIZE`) | **10 MiB** (`10 * 1024 * 1024`) | `main.rs:57` |
| Alt-screen capture (`ALT_BUFFER_CAP`) | **2 MiB** | `main.rs:58` |
| Agent-state tail sample | 4 KiB | `main.rs:64` |
| Sparkline ring | 3600 × f64 | `main.rs:1235` |

The main buffer is a fixed-size circular `Vec<u8>` with `write_pos` + `filled`
(`main.rs:68-85`, `:220-250`). A single write larger than the ring keeps only its last 10 MiB
(`:225-231`). `total_written` is a monotonic `f64` across both buffers and **is never reset**,
including by `clear()` (`main.rs:104-115`) and `CLEAR_SCROLLBACK` (`:1461-1474`).

Alt-screen content is captured separately and **discarded on alt-screen exit** and on resize
(`main.rs:167-175`, `:287-292`); over-cap alt content is drained from the front with
`alt_content_start` advanced to match (`:253-262`).

### Full replay — `OutputBuffer::read()` → preamble → clamp → strip → maybe gzip

Pipeline for `RESUME(offset <= 0)` or any fallback (`main.rs:2480-2485`, `:2517-2522`):

```
1. read()                     main.rs:298-325
   a. not wrapped (filled == false):  bytes [0 .. write_pos]           — no sanitization
   b. wrapped     (filled == true) :  linearize [write_pos..] ++ [..write_pos]
                                      then sanitize_start()
   c. if in alt screen and alt_buf non-empty: append alt_buf
   d. find_last_screen_clear(): scan backwards for the LAST  ESC [ 2 J
      and truncate everything before it                                main.rs:269-284, :320-324

2. with_replay_preamble()     main.rs:334-347
   - if in alt screen and the body no longer contains an alt-enter: prepend ESC [ ? 1 0 4 9 h
   - prepend TermModes::preamble() — every non-default mode the app had set

3. clamp_replay_tail(body, maxReplayBytes)   main.rs:2457-2470   (full replays only)

4. strip_terminal_queries()   main.rs:485-524, called at :2538-2542

5. gzip if len >= 4096 and it helps                                §4
```

**`sanitize_start` — the "skip to first `\n` after wrap" rule** (`main.rs:471-481`):

```rust
fn sanitize_start(buf: Vec<u8>) -> Vec<u8> {
    if let Some(idx) = buf.iter().position(|&b| b == b'\n') {
        if idx == 0 { buf } else { buf[idx + 1..].to_vec() }
    } else {
        buf
    }
}
```

Applied **only when the ring has wrapped**, and only to the main buffer. It drops everything up
to **and including** the first `\n`, because the wrap boundary can fall inside a multi-byte UTF-8
sequence or an ANSI escape. If the linearized buffer contains no `\n` at all, it is returned
unchanged — the guarantee is best-effort.

**`clamp_replay_tail`** (`main.rs:2457-2470`) applies the same idea to the `maxReplayBytes`
tail: take the last N bytes, then skip past the first `\n` (`&tail[pos + 1..]`), or return the
slice as-is if there is no newline. `max_bytes <= 0` or non-finite ⇒ no clamping.

**`strip_terminal_queries`** (`main.rs:485-524`) removes, from **both** full and delta replays,
CSI sequences that would make the client answer a stale query:

* DSR: final byte `n` with params `6` or `?6` (cursor position report)
* DA: final byte `c` with params empty, `>`, `=` or `0` (device attributes)

### Delta replay — `read_from(offset)`

`main.rs:351-406`, reached from `RESUME(offset > 0)` (`main.rs:2486-2504`):

| Situation | Result |
|---|---|
| `offset >= total_written` | `Some(empty)` — fully caught up; **no replay frame is sent at all**, just `RESIZE` + `SYNC` + … |
| in alt screen and `offset >= alt_content_start` | `Some(alt_buf[skip..])` |
| in alt screen and `offset <` that | `Some(main_delta ++ entire alt_buf)` |
| normal mode | `Some(main_raw[skip..])` via `read_from_main` |
| `offset < main_start` (bytes overwritten) | **`None`** ⇒ `SYNC(0)` cache reset, then a **full** replay |

A delta:

* is **raw** — no `sanitize_start`, no `ESC[2J` truncation, no mode preamble
  (`main.rs:2488-2493`, `:424-432`);
* is **never clamped**, even with `maxReplayBytes` set — truncating a delta would corrupt the
  offset contract (`main.rs:2490-2491`, and the note test at `:2833`);
* **is** still passed through `strip_terminal_queries` and **may still be gzipped**, because
  `send_replay` is shared.

### Summary table

| | Full replay | Delta replay |
|---|---|---|
| Trigger | `RESUME(0)`, malformed `RESUME`, non-`RESUME` first frame, 100 ms timeout, offset too old | `RESUME(offset > 0)` still in the ring |
| Wrap sanitization (`skip to first \n`) | yes, when wrapped | **no** |
| Truncate at last `ESC[2J` | yes | **no** |
| Alt-screen re-enter + mode preamble | yes | **no** |
| `maxReplayBytes` clamp | yes | **never** |
| `strip_terminal_queries` | yes | yes |
| gzip when ≥ 4 KiB | yes | yes |
| Client action | reset the emulator, then feed | append |
| Preceded by `SYNC(0)`? | only on cache reset | no |

---

## 13. Gotchas for a non-JS client

1. **Offsets are IEEE-754 float64, big-endian — not `u64`.** `RESUME` (`messages.ts:31-32`),
   `SYNC` (`messages.ts:61`), `SESSION_METRICS` and `SPARKLINE_HISTORY` all use `f64` BE.
   Rationale in `PROTOCOL.md`: JS `Number` is f64, exact to 2^53. Swift:
   `Double(bitPattern: UInt64(bigEndian: raw))` and `value.bitPattern.bigEndian` to write.
   `totalBytesWritten` in the JSON likewise serializes as `419294.0` — **parse session JSON
   numbers as `Double`**, not `Int`; a strict integer decoder will throw.

2. **The frame length includes the type byte.** `payload_len = 1 + data.len()`. Off-by-one here
   desynchronises the stream permanently.

3. **Partial frames across reads, and multiple frames per read.** The host writes each frame with
   a single `write_all`, but the socket may split anywhere. Keep a pending buffer and loop
   `while pending.count >= 4` (`framing.ts:20-29`, `main.rs:2357-2379`). Also parse **before**
   the next read, not only after — the handshake read can leave complete frames buffered
   (`main.rs:2352-2354`).

4. **Zero-length frames must be skipped, not treated as errors** (`framing.ts:26`,
   `main.rs:2367-2369`).

5. **UTF-8 is split across `DATA` frames.** PTY reads are chunked at 64 KiB with up to 256 KiB
   coalesced per readable event (`main.rs:1706`, `:1734-1737`); a multi-byte character can land
   on any boundary. Never decode a single `DATA` payload as a standalone `String` — feed bytes
   into an incremental decoder or straight into the terminal emulator. The same applies across
   the replay/`DATA` seam.

6. **Escape sequences split across frames too.** `sanitize_start` only guarantees a full replay
   starts after a `\n`; nothing guarantees escape-sequence integrity at a **delta** boundary, or
   when the linearized ring has no `\n` at all.

7. **pty-host never answers `PING`.** Do not run a zombie timer over a Unix socket (§5).

8. **Missing the 100 ms `RESUME` window is unrecoverable for that connection** — a late `RESUME`
   is silently dropped and you get a full replay (§3.2). Send it in the connect completion
   handler, before any `await`.

9. **A caught-up delta produces no replay frame.** Do not block waiting for `BUFFER_REPLAY`;
   gate the handshake on `SYNC` (`cli/directory.ts:113-114`).

10. **Replays must not advance your offset.** `SYNC` is an absolute assignment (§3.4). Adding
    replay length double-counts and loses output on the next reconnect.

11. **Compute `isDelta` synchronously, before inflating.** `session-stream.ts:307` captures the
    flag before the async gunzip.

12. **`SESSION_UPDATE` is broadcast to every WS client of every session.** Filter on
    `session.id` (`ws-handler.ts:72-76`).

13. **Live `DATA` can interleave with or precede the replay body** (broadcast subscription starts
    at accept, `main.rs:2197`). A few duplicated bytes at attach are normal.

14. **Slow readers lose frames silently.** The broadcast channel holds 256 frames; overflow is
    `Lagged(n)` and those frames are dropped for that client with only an stderr log
    (`main.rs:2213-2224`). Your offset stays consistent (it only counts frames you received), so
    reconnect + `RESUME` repairs it — but you must notice. Drain the socket on a dedicated
    reader.

15. **`CLEAR_SCROLLBACK` inbound is followed by `SYNC`.** Set `offset = 0`, clear the emulator,
    and let the `SYNC` restore the real value. Do not send `RESUME`.

16. **`DETACH` (0x22) is destructive** — it `SIGHUP`s the foreground process group. Never send it
    on an incidental pane close.

17. **`OBSERVE` gives you nothing to render.** No replay, no `SYNC`, no `TITLE`, no
    `SESSION_STATE` (`main.rs:2305-2309`).

18. **`exitCode` is a signed `i32` BE.** `-1` = unknown, `128 + signal` = killed by signal
    (`main.rs:1865-1871`).

19. **`pid` in session JSON is pty-host's own pid**, not the shell's (`main.rs:1597`). That is
    what the liveness check tests, and it is *not* the pid whose cwd is polled (`child_pid`, never
    written to disk).

20. **`error` exists on disk but not in the TS `Session` type** (`main.rs:1159`). Decode session
    JSON permissively; unknown keys will appear.

21. **`titlePinned` and every `Option` field are absent, not `null`, when unset.** Use optional
    Swift properties, not `Bool` with a default decoder that requires the key.

22. **`foregroundProcess` is a comm name and can be nonsense** — Claude Code reports
    `"2.1.268"` (`agent_state.rs:71-80`). Do not display it raw.

23. **Atomic writes create `<id>.json.tmp`.** A directory watcher will see it. Filter to
    `.json` and explicitly exclude `.json.tmp` (`directory-disk-node.ts:80`, `:108`,
    `pty-manager.ts:302`).

24. **Socket files outlive dead hosts.** The socket is unlinked on `SIGTERM` (`main.rs:1686`) and
    one second after PTY exit (`main.rs:2256-2261`), but not after a `SIGKILL` or crash. Always
    pair "socket exists" with a pid-liveness check, and prefer "connect succeeded" as the real
    test (`cli/spawn.ts:53-65`).

25. **Session ids must be lowercase hex.** Server routes are `[a-f0-9]+`
    (`ws-handler.ts:158`, `auth.ts:30-33`).

26. **OSC 0/2 and OSC 7 remain inline in `DATA` and in replays**; OSC 9, 52 and 1337 are stripped
    and re-emitted as their own frames (`main.rs:965-995`). Your emulator must tolerate the
    former; you can exploit OSC 7 for instant cwd (§7).

27. **`RESIZE` is bidirectional and inbound at handshake time** — the very first frame after a
    `RESUME` is always `RESIZE`, even when the replay body is empty (`main.rs:2526-2535`).
    Handle it before you handle the replay.

28. **The `--login` argument is consumed by pty-host**, not passed to the child
    (`main.rs:1495-1499`); and non-shell commands are wrapped in `$SHELL -li -c "exec …"`
    (`spawn-utils.ts:62-69`), which changes what `child_pid` points at (§7).

29. **`SESSION_METRICS` goes quiet on idle.** It stops once all three bps values fall below 0.5,
    after one trailing zero frame (`main.rs:2151-2165`). Absence of metrics is not absence of the
    session.

30. **Close codes 4001 and 1008 mean "stop reconnecting"** (`session-stream.ts:148-152`). Every
    other close is retryable.

---

## 14. `~/.relay-tty/project-roots.txt` and `commands.txt`

### `project-roots.txt`

* **Written by** `server/projects.ts` — seeded on first read if missing
  (`seedProjectRootsFile`, `:157-173`) and overwritten by
  `PUT /api/project-roots` (`writeProjectRoots`, `:147-151`; route `server/api.ts:984-992`).
* **Format**: one absolute directory per line; blank lines and `#` comments ignored
  (`projects.ts:120-126`). The seed writes a three-line comment header, then every entry from
  `DEFAULT_ROOT_NAMES` (`projects.ts:12-20`) — uncommented if the directory exists, commented
  out otherwise.
* **Consumed by** `discoverProjects()` (`projects.ts:30-91`): each root is scanned **one level
  deep** for git repos (`source: "discovered"`), merged with `cwd`s harvested from all session
  JSON files (`source: "recent"`, excluding `$HOME` and `/`, ranked by
  `lastActivity || createdAt`), de-duplicated via `realpath`. 30 s cache
  (`:23-24`), invalidated on session create (`api.ts:122`).
* Exposed as `GET /api/projects` → `{ projects: Project[] }` and
  `GET /api/project-roots` → `{ content: string }` (`api.ts:974-981`).
  `Project` = `{ path, name, label, source, lastUsed? }` (`shared/types.ts:105-111`); `label`
  is the path with `$HOME` collapsed to `~`.

Current contents on this machine: `/Users/spierce/code`, `/Users/spierce/projects`,
`/Users/spierce/src`, plus commented-out defaults.

**Reusable for MaxPane project tagging**: yes, and `discoverProjects`' own "recent" logic is the
better half to copy — deriving the project list from the `cwd` fields of
`~/.relay-tty/sessions/*.json` needs no server at all, and matches what the relay UI shows.
Treat `project-roots.txt` as user configuration you may **read** and should not rewrite (the
web settings UI owns it).

### `commands.txt`

* **Written by** `PUT /api/commands` only (`server/api.ts:636-646`), which joins the posted
  array with `\n`. Nothing seeds it; absence is normal.
* **Read by** `readCustomCommands()` (`api.ts:44-54`): one command per line, trimmed, blank and
  `#` lines dropped. Exposed as `GET /api/commands` → `{ commands: string[] }`.
* It is the user's quick-launch list for the web "new session" picker; it is **not** the list of
  available tools — that is `GET /api/available-commands`, which probes `command -v` for a
  hardcoded set of agents and shells (`api.ts:649-682`).

Current contents: `htop`, `rolo`.

Siblings, for completeness: `upload-dir.txt` (single path, default `~/.relay-tty/uploads`,
`api.ts:34-41`), `notifications.json`, `scratchpad.hst`, `push/`, `uploads/`.

---

## Protocol drift

`PROTOCOL.md` (last meaningful edit predates the Rust host) is wrong or incomplete in the
following specific ways. It must not be used as a spec.

| # | `PROTOCOL.md` says | Reality | Evidence |
|---|---|---|---|
| 1 | 7 message types | **23** are defined | `shared/types.ts:41-86` |
| 2 | Omits `NOTIFICATION`, `SESSION_STATE`, `BUFFER_REPLAY_GZ`, `SESSION_METRICS`, `SESSION_UPDATE`, `CLIPBOARD`, `IMAGE`, `SPARKLINE_REQUEST`, `SPARKLINE_HISTORY`, `PING`, `PONG`, `DETACH`, `CLEAR_SCROLLBACK`, `SET_TITLE`, `SIGNAL`, `OBSERVE` | all live | `shared/types.ts`, `main.rs:34-53` |
| 3 | `RESIZE` is "Client → Server" | **bidirectional**; sent before every replay and broadcast on every accepted resize | `main.rs:1926-1929`, `:2526-2535` |
| 4 | `RESUME` is `[8B offset]` | 16-byte variant `[8B offset][8B maxReplayBytes]` exists | `messages.ts:26-34`, `main.rs:2437-2448` |
| 5 | Handshake response is "`BUFFER_REPLAY`, `SYNC`, `TITLE`" | actual order is `RESIZE` → `[REPLAY\|REPLAY_GZ]?` → `SYNC` → `TITLE?` → `SESSION_STATE`, optionally prefixed by `SYNC(0)` and suffixed by `EXIT` | `main.rs:2495-2502`, `:2524-2602`, `:2340-2350` |
| 6 | "Client sends `RESIZE` after `RESUME`" as step 5 | true of the CLI, but it is optional and actively harmful with multiple clients | §10, `cli/attach.ts:160-163` |
| 7 | Silent on the 100 ms timeout consequence | after the timeout a late `RESUME` is **silently ignored** (`process_client_message` has no `RESUME` arm) | `main.rs:2631-2633` |
| 8 | No mention of gzip | replays ≥ 4 KiB are sent as gzip-wrapped `BUFFER_REPLAY_GZ` (0x13) | `main.rs:2545-2556` |
| 9 | "Offset too old ⇒ falls back to full replay" | it first sends `SYNC(0)` as an explicit cache-reset signal, **then** the full replay | `main.rs:2495-2502` |
| 10 | Full replay "skips to the first `\n` after the wrap boundary" | true, but omits: truncation at the last `ESC[2J`, the alt-screen re-enter + `TermModes` preamble, the `maxReplayBytes` clamp, and `strip_terminal_queries` | `main.rs:298-347`, `:2457-2470`, `:485-524` |
| 11 | "Delta replay returns raw bytes without sanitization" | raw with respect to wrap/clear/preamble, but **still** `strip_terminal_queries`'d and possibly gzipped | `main.rs:2538-2542`, `:2545` |
| 12 | Ring buffer "10MB default" only | also a separate 2 MiB alt-screen buffer with its own offset accounting | `main.rs:58`, `:253-262`, `:356-373` |
| 13 | Implies `PING`/`PONG` are part of the pty-host protocol (by omission of the distinction) | pty-host implements neither; only the Node WS bridge answers | `main.rs:34-53`, `ws-handler.ts:452-456` |
| 14 | Implies `SESSION_UPDATE` is a host message (by omission) | synthesized only by the WS server from a file watcher, never on a Unix socket | `ws-handler.ts:45-77` |
| 15 | WS endpoint table lists only `/ws/sessions/:id` and `/ws/share` | `/ws/events` and `/ws/desktop` also exist | `ws-handler.ts:174-193` |
| 16 | "Cookie JWT or localhost" with no detail | the localhost bypass is revoked by `Cf-Connecting-Ip` or `X-Relay-Tunnel`; a scoped `relay_grant` cookie is a third credential | `auth.ts:57-76`, `:374-393` |
| 17 | Describes `server/pty-host.ts` implicitly | the host is Rust: `crates/pty-host/src/main.rs` | `main.rs:1-3` |

Also note two type-level drifts between the Rust writer and the TS reader:
`SessionMeta.error` exists in Rust but not in the TS `Session` interface
(`main.rs:1159` vs `shared/types.ts:3-39`), and `pid` is non-optional `u32` in Rust but `pid?:
number` in TS (`main.rs:1148` vs `shared/types.ts:15`).
