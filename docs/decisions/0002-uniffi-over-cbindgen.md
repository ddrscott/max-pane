# ADR 0002 — uniffi over cbindgen, with snapshot-free hot paths

**Status:** Accepted · 2026-09-12
**Decides:** PRD §14 — "uniffi vs. cbindgen for the FFI."
**Evidence:** [Spike M3](../spikes/03-m3-uniffi-ffi.md).

## Decision

Use **uniffi 0.32 in proc-macro mode** (`#[uniffi::export]`, no UDL) to expose
`laned-core` to Swift.

Separately, and because of what M3 measured: **do not put a full `StripState` on
the hot paths.** `Core` also exposes `revision()`, `lane(id)` and `note_focus(id)`,
none of which marshal the strip. The full snapshot is for structural change —
create, close, move, evict — and nothing else.

## Why

M3 measured a 300-lane / 400-pane `state()` round-trip at **2.445 ms p95**,
against a 5 ms budget. That is a pass, and it is also only 2× headroom, so the
split matters:

| Half | p95 | share |
|---|---|---|
| Rust: SQLite query + build the snapshot | 0.288 ms | 12% |
| uniffi: serialise, copy, allocate Swift structs and `String`s | ~2.16 ms | **88%** |

The database is not the cost. The boundary is. Two facts pin that down:

- Walking every field in Swift afterwards costs nothing measurable (2.461 vs
  2.445 ms p95) — uniffi decodes eagerly, so there is no lazy path to exploit.
- `observe_cwd`, which returns a `bool`, runs in **0.009 ms** — 270× faster. The
  per-call overhead is nil; the 300 lanes × 9 fields × string allocation is
  everything.

cbindgen would move the same bytes. Hand-writing the marshalling could buy back
roughly 2 ms per mutation, in exchange for maintaining a hand-rolled C ABI for
every record in §6 — `Option<f64>`, nested `Vec<Pane>`, six enums, and a growing
error type — forever, with no compiler checking the two sides agree. That is a
permanent cost against a problem that has a cheaper fix.

The cheaper fix is to call it less. A revision check is a `u64` comparison; a
focus change touches two rows and does not change the shape of the strip. Both
were added in response to this measurement.

The budget is comfortable either way: at 120 Hz a frame is 8.3 ms, structural
mutations are user-initiated, and nobody creates lanes at 120 Hz.

## Also decided by this

- **Proc-macro mode, not UDL.** UDL is a third place for the type definitions to
  drift from. Proc-macro mode has the Rust signature as the only source.
- **A SwiftPM package, not an XCFramework.** There is no Xcode on this machine
  (`xcodebuild -create-xcframework` is unavailable), and none is needed: the
  `staticlib` links via `Package.swift` linker settings.
- **The FFI module must be named `laned_coreFFI`.** The generated Swift does
  `#if canImport(laned_coreFFI)`. Any other name compiles the bindings with no
  FFI symbols at all and fails at link time with an unhelpful error.

## Rejected

- **cbindgen with hand-written marshalling.** ~2 ms per structural mutation, in
  exchange for an unchecked ABI maintained by hand across a data model that is
  still moving. Revisit only if the strip routinely exceeds 300 lanes *and* the
  snapshot-free paths turn out not to cover the hot ones.
- **Serialising `StripState` as JSON or protobuf across a thin C boundary.** Adds
  an encode/decode on both sides to avoid a copy; strictly worse than what uniffi
  already does.

## What would make us revisit

- A structural mutation measurably dropping frames in the real app (not the
  spike) — the spike is uncontended and the real one will not be.
- The strip routinely holding more than 300 lanes.
- uniffi gaining, or losing, lazy decoding for records.
