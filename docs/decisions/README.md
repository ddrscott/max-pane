# Decisions

One ADR per open decision in PRD §14, written before the affected component is
implemented (PRD §0.7).

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-swiftterm-over-web-terminal.md) | SwiftTerm vs. Relay's web terminal in a `WKWebView` | — |
| [0002](0002-uniffi-over-cbindgen.md) | uniffi vs. cbindgen for the FFI | Accepted |
| [0003](0003-website-data-store-sharding.md) | How many `WKWebsiteDataStore`s, and the assignment rule | — |
| [0004](0004-strip-view-strategy.md) | Virtualized strip (`NSCollectionView`) vs. `NSScrollView` with manual recycling | — |
| [0005](0005-cwd-for-relay-sessions.md) | How cwd is obtained for Relay sessions | Accepted |
| [0006](0006-placeholder-snapshots.md) | Snapshot format and resolution for placeholders | — |

Each ADR states the decision, what evidence decided it (usually a spike, by
number), what was rejected and why, and what would make us revisit.
