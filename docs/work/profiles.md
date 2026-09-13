# One `--profile` instead of four environment variables

## Problem

> "let's add a profile argument to better enable app sessions so we can test
> without pointing to my main default profile. I'm going to start using this
> full time and don't want the extra test interference."

The mechanism already exists and is the wrong shape. Isolating an instance today
means setting **four** variables consistently — `MAXPANE_LEDGER`,
`MAXPANE_SOCKET`, `MAXPANE_CONFIG`, `MAXPANE_DATA_SALT` — plus `MAXPANE_APP` to
avoid demolishing a running bundle. Forgetting any one is silent and each has a
different failure:

- no `MAXPANE_SOCKET` → the CLI talks to **his** running app instead of the test one
- no `MAXPANE_DATA_SALT` → the test instance derives **exactly** the cookie-jar
  UUIDs the real app uses. The test audit found the test *process* one WebKit
  release away from opening his Gmail jar, which is why `scripts/test.sh` now
  exports a salt
- no `MAXPANE_LEDGER` → the test writes into his live strip

He is about to use this full time, so the cost of getting it wrong goes up.

## Decisions the owner has made

- **Full Relay isolation if possible**, falling back to per-profile session
  tracking. See the research below — this is the hard part and it may require a
  proposal rather than a change.
- **Everything moves under `profiles/`**, including the default. He chose the
  migration over the compatibility shim, so the migration has to be safe: back
  up first, verify after, and be reversible. His live strip is in it.

## What is already known about Relay isolation

`relay-pty-host` derives its data directory from the environment, and there is
**no override**:

```rust
// crates/pty-host/src/main.rs:1516
let home = env::var("HOME").unwrap_or_else(|_| "/".to_string());
let data_dir = PathBuf::from(&home).join(".relay-tty");
let sockets_dir = data_dir.join("sockets");
let sessions_dir = data_dir.join("sessions");
```

So a profile's sessions can be isolated by spawning `relay-pty-host` with a
different `HOME` — and `relay-tty` is a **read-only dependency** (PRD §0.3:
write a proposal in `docs/proposals/` and stop), so adding a `RELAY_DATA_DIR`
ourselves is not an option.

The catch, which is the whole design problem: **the child shell inherits that
`HOME`**, so a test terminal would have the wrong home directory — no
`~/.zshrc`, wrong paths, a shell that is not the shell being tested. That is
worse than the interference it avoids.

The promising route: `RelaySessionSpawner.buildArgs` already composes the child
command line, so it can put the real home back for the child only — roughly
`env HOME=<real home> $SHELL -li -c '<cmd>'` — while `pty-host` itself keeps the
profile's `HOME` for its data directory. Verify that actually works rather than
assuming; anything that reads `HOME` before that prefix takes effect sees the
wrong one, and `pty-host` sets several variables for the child itself.

If it does not work cleanly, fall back to **tracking**: the profile records the
session ids it spawned so it can list and stop exactly its own, and write the
`RELAY_DATA_DIR` proposal in `docs/proposals/` per §0.3.

## Acceptance criteria

- `maxpane --profile <name> …` and a matching way to launch the app select a
  profile, deriving ledger, config, cookie jars, control socket and snapshots
  from it. One argument, not five.
- The CLI and the app agree: `maxpane --profile test ls` talks to the instance
  launched with that profile, never to the default one.
- **No profile named on the command line means the default profile**, and that
  is the one he is working in.
- A named profile's cookie jars are provably separate: a login in one is absent
  in the other. The existing `DataStorePool` salting is the mechanism.
- Relay sessions: either a named profile's sessions do not appear in his real
  `relay ls` at all, or `maxpane --profile <name> reap` stops exactly the
  sessions that profile spawned and nothing else. Say which was achieved.
- **The migration is safe.** Back up the ledger with `sqlite3 .backup` (not a
  file copy — the WAL held 4 MB the one time it mattered), verify lane and pane
  counts match afterwards, and leave the backup in place. If anything does not
  match, stop and leave the original untouched.
- `README.md` documents it, and the four env variables either become aliases or
  are removed with their uses in `scripts/` updated.
- The window says which profile it is when it is not the default. Several agents
  have driven the wrong instance today because two windows were identical.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/StripStore.swift` — `defaultLedgerPath`
- `swift/MaxPane/Sources/MaxPaneKit/Config.swift` — `Config.path`
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/OpenServer.swift` — `socketPath`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift` — `DataStorePool`
- `swift/MaxPane/Sources/MaxPaneKit/Terminal/RelaySessionSpawner.swift` — `buildArgs`
- `crates/maxpane-open/` — the CLI's argument parsing
- `swift/MaxPane/Sources/MaxPane/AppDelegate.swift` — launch arguments
- `scripts/test.sh`, `scripts/build-app.sh` — both set these variables today

## Constraints

- **Never modify anything under `/Users/spierce/code/relay-tty`.** It is a
  read-only external dependency; a needed change there is a proposal in
  `docs/proposals/`, per PRD §0.3.
- His live sessions must not be touched by any test of this.
- `MAXPANE_APP` stays separate — it selects which *bundle* is built, which is a
  different axis from which profile that bundle runs, and conflating them is how
  a rebuild demolishes the app he is using.
