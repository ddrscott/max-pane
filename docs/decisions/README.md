# Decisions

One ADR per open decision in PRD §14, written before the affected component is
implemented (PRD §0.7).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-swiftterm-over-web-terminal.md) | SwiftTerm vs. Relay's web terminal in a `WKWebView` | Accepted |
| [0002](0002-uniffi-over-cbindgen.md) | uniffi vs. cbindgen for the FFI | Accepted |
| [0003](0003-website-data-store-sharding.md) | How many `WKWebsiteDataStore`s, and the assignment rule | Accepted |
| [0004](0004-strip-view-strategy.md) | Virtualized strip (`NSCollectionView`) vs. `NSScrollView` with manual recycling | Accepted |
| [0005](0005-cwd-for-relay-sessions.md) | How cwd is obtained for Relay sessions | Accepted |
| [0006](0006-placeholder-snapshots.md) | Snapshot format and resolution for placeholders | Accepted |
| [0007](0007-terminal-panes-never-resize-the-pty.md) | Terminal panes never resize the PTY (**amends PRD §11**) | Accepted |
| [0008](0008-no-multi-display-yet.md) | Multi-display is not built (PRD §13 Phase 3 is gated) | Accepted |
| [0009](0009-libghostty-over-swiftterm.md) | libghostty replaces SwiftTerm as the emulator (**supersedes 0001**) | Accepted |

Each ADR states the decision, what evidence decided it (usually a spike, by
number), what was rejected and why, and what would make us revisit.

ADR-0009 is not one of §14's open decisions either. It supersedes ADR-0001's
choice of emulator, which §14 did ask about — the rejected alternative there
(Relay's web terminal in a `WKWebView`) is still rejected, for the same reasons.

ADR-0007 is not one of §14's open decisions. It records a PRD requirement that
turned out to contradict the system it depends on, surfaced per §0.6 rather than
quietly reinterpreted. [`docs/acceptance.md`](../acceptance.md) tabulates every
such conflict.
