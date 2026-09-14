# ADR 0012 — `config.toml` is edited by a line editor in Swift, not `toml_edit` over uniffi

**Status:** Accepted · 2026-09-13
**Decides:** how the settings window writes `config.toml` without losing what a
person put in it.
**Evidence:** the work item [`docs/work/settings-ui.md`](../work/settings-ui.md),
whose decisions (TOML, the path, comment-preserving writes, the JSON migration,
every key editable) are the owner's and are not re-opened here; and the tests in
`SettingsTests.swift`, which are what "preserves comments" is measured against.

## Decision

`TomlDocument` (`swift/MaxPane/Sources/MaxPaneKit/ConfigToml.swift`) holds the
file as its lines. Reading parses each line into a table header, a
`key = value`, or trivia. Writing replaces **the characters of one value** on
the line that holds it, appends a new key at the end of its own table, or
deletes one line. Nothing else in the file is touched, and the tests hold it to
that byte for byte: the key's spelling, the comment after the value, comments
above, blank lines, ordering, unknown keys, CRLF line endings, and lines it
cannot read at all.

It reads the subset a settings file needs: top-level keys, `[table]` headers,
dotted keys, basic and literal strings, integers, floats, booleans and
single-line arrays. A multi-line string, an inline table, a date or an array of
tables is reported as a problem on its line and is **never rewritten**. The
settings window shows those problems and does not edit around them.

No new dependency.

## Why not `toml_edit` in `laned-core`

`toml_edit` is the better TOML parser. It is not the better fit here, for
reasons specific to this app:

| | In-house line editor | `toml_edit` over uniffi |
|---|---|---|
| New dependency | none | `toml_edit` plus its parser crates, now in `Cargo.lock` |
| When the config is read | before the ledger opens, in Swift | the core would have to be loaded first, or a second uniffi entry point added that works without a ledger |
| Shape of the API | `set(key, table, value)` on a Swift value | a document handle across FFI, and bindings regenerated for every change to it |
| What it must handle | the file this app writes and documents | all of TOML |
| Failure on a construct it does not know | refuses that line, leaves it alone | none |

- **The file is small and its shape is fixed.** It has twenty-one flat keys and
  one `[keys]` table of strings and string lists. Everything the settings window
  writes is a scalar or a list of strings. A general format-preserving TOML
  engine would be doing a job this file does not have.
- **Config is read before the core exists.** `AppDelegate` reads `config.toml`
  to decide `theme` and `lane_default_pt` *before* `StripStore` opens the
  ledger, because the ledger needs the default width. `laned-core`'s uniffi
  surface is built around the ledger. Putting config parsing there means
  either reordering launch or adding a ledger-free FFI entry point, only to
  parse a text file.
- **ADR-0002 accepted uniffi for the ledger boundary.** That boundary carries
  the ledger, ordinals, search and imports: state that has to be shared with a
  future non-Mac client. How the Mac app's settings window edits a text file is
  not that kind of state. If a Linux client arrives it will read the same file
  with its own platform's TOML library, and the file format is the contract,
  not a Rust type.
- **The risk is bounded, and it is on the safe side.** A line editor's failure
  mode is a construct it does not understand. Here that construct is reported
  and preserved, never rewritten. The failure a person would actually mind is a
  write that loses their comment, and that is what the tests cover.

## What was rejected

- **A serializer** (decode to `Config`, encode back out). Rejected by the
  owner's requirement, and it would be wrong anyway: it drops comments,
  reorders keys, and pins every default into the file, so a later default change
  would never reach anyone who had once opened the window.
- **Keeping JSON.** Rejected by the owner (JSON has no comments). `config.json`
  is still decoded, by the same per-key `Config.init(from:)`, but only to
  migrate it.

## Consequences

- Removing a key is how "default" is written. The key leaves the file and
  follows the app's default from then on.
- A write goes through a symlink to the file it names, then replaces that file
  atomically. A config kept in a dotfiles repo stays a link.
- `ConfigField` is the one table mapping Swift property names to snake_case TOML
  keys. A test fails if `Config` gains a stored property without a row.

## Revisit if

- The file needs a construct the subset refuses: nested tables beyond `[keys]`,
  arrays of tables, or multi-line strings that someone actually writes. Take
  `toml_edit` then, behind the same `TomlDocument` API, and keep the tests.
- A second client needs to *write* the file with the same guarantees. At that
  point one shared implementation is worth the FFI.
