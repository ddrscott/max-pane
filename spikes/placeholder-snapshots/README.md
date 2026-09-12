# Placeholder snapshot encoding

Backs [ADR-0006](../../docs/decisions/0006-placeholder-snapshots.md). Measures
encode size, encode time and decode time for the formats an evicted web pane's
snapshot could be stored in, against a synthetic page with the things a real page
has: flat bands, a gradient hero, and a lot of text-like high-frequency detail.

No WebKit — this is the encode side only, which is the half that decides the
format.

```sh
swiftc -O snap.swift -o snap && ./snap
```
