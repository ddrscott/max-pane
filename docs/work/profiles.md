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

- **Relay is out of scope.** A profile isolates the app's own state and nothing
  else; test sessions go on appearing in `relay ls` and are cleaned up by hand,
  exactly as now. See below for why, so nobody spends a day rediscovering it.
- **Everything moves under `profiles/`**, including the default. He chose the
  migration over the compatibility shim, so the migration has to be safe: back
  up first, verify after, and be reversible. His live strip is in it.

## Why Relay is out of scope (do not re-investigate)

`relay-pty-host` derives its data directory from the environment, and there is
**no override**:

```rust
// crates/pty-host/src/main.rs:1516
let home = env::var("HOME").unwrap_or_else(|_| "/".to_string());
let data_dir = PathBuf::from(&home).join(".relay-tty");
let sockets_dir = data_dir.join("sockets");
let sessions_dir = data_dir.join("sessions");
```

The only lever is `HOME`, and pulling it breaks the thing being isolated: **the
child shell inherits it**, so a test terminal would have the wrong home
directory — no `~/.zshrc`, wrong paths, a shell that is not the shell being
tested. That is worse than the interference it avoids. Adding a `RELAY_DATA_DIR`
is not ours to do either; `relay-tty` is a read-only dependency (PRD §0.3).

The owner's call: **leave it.** A profile isolates the app, and Relay sessions
stay shared.

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
