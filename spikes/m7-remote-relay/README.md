# Spike M7 — one remote relay-tty session through relaytty.com

The program behind `docs/spikes/07-m7-remote-relay.md`. Kept, as every spike
is, so the numbers there can be re-obtained.

`Sources/RelayClient` and `Sources/CRelayGzip` are **symlinks into
`swift/MaxPane/Sources`**: `m7` links the app's own `WebSocketTransport` and
`UnixSocketTransport` under the app's own `RelaySession`, so what it measures
is what the app runs.

```
swift build -c release
RELAY_TOKEN=$(ssh yorkshire-wsl 'grep -o "callback?token=[A-Za-z0-9._-]*" ~/relay-server.log | tail -1 | cut -d= -f2')
export RELAY_TOKEN

.build/release/m7 probe   --base https://yourslug.relaytty.com --id 0368d543 --auth none     # §4
.build/release/m7 echo    --base https://yourslug.relaytty.com --id <cat session> --n 200     # §2
.build/release/m7 echo    --unix /tmp/m7h/.relay-tty/sockets/a7000001.sock --id a7000001
.build/release/m7 stream  --base … --id <generator> --seconds 40 --trigger '\r'               # §1 live
.build/release/m7 replay  --base … --id <generator> --out replay.bin                          # §1 replay
.build/release/m7 paste   --base … --id <raw reader> --bytes 65536                            # §6
.build/release/m7 watch   --base … --id <agent> --seconds 8 --type 'Do you want to proceed?\r' --after 2   # §5
.build/release/m7 reconnect --base … --id 0368d543 --seconds 500                              # §3
```

Every command prints its log to stderr and one JSON line to stdout. The token
comes from `RELAY_TOKEN` only; nothing prints it, and the JSON says `token=set`.

`box/tap.mjs` is the same client for the far end (node 22, on the relay host):
it speaks the pty-host's Unix socket directly, and the server's WebSocket with
a `Cookie` header, which is how the LAN-direct auth control was run against
the box's non-loopback address from the box itself.

`run.sh` runs §1, §2, §4, §5 and §6 end to end into `out/<stamp>/`. §3 is by
hand: start `m7 reconnect`, then on the box `kill -STOP <server pid>` for
10 s, 60 s and 180 s with `kill -CONT` between, and read the log.

`out/` holds the runs the report was written from (`out/auth`, `out/echo`,
`out/exact`, `out/paste`, `out/agent`, `out/reconnect`). The two `.bin`
replays are not kept; their sha256 is in the JSON beside them.
