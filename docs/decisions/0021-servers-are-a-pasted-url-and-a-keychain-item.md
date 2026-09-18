# ADR 0021 — A server is added by pasting the line it printed; the token lives in the Keychain and nowhere else; `[[servers]]` applies live

**Status:** Accepted · 2026-09-17
**Decides:** how a remote relay-tty server gets into Max Pane, where its
credential is kept, and how a change to the set of servers reaches the
running app. Phase 2 of
[`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md),
on the owner's decision §4.4 (*"the token is pasted from the server's startup
URL"*).
**Evidence:** the work item
[`docs/work/remote-relay-phase2.md`](../work/remote-relay-phase2.md);
`RelayServerBookTests.swift` (the pasted line, the file, the live path
against the fake server, the window); `RelayServerBook.swift`, the one door.

## The facts

1. **relay-tty has one credential and prints it once.** The server mints a
   `session` JWT with no expiry and prints it at startup inside an auth URL,
   `https://<slug>.relaytty.com/api/auth/callback?token=…`, for a browser to
   visit and have set as a cookie. There is no token endpoint and no device
   flow (plan §5.5). Everything a native client can do starts from that line.
2. **The line arrives dirty.** It is copied out of a terminal, so it comes
   with the label before it (`Auth URL (1y):`), the colour codes around it,
   a prompt in front, and whatever punctuation closed the sentence it was
   pasted into. A field that wanted exactly the URL would be refusing the
   thing the owner actually has on his clipboard.
3. **The app already has a credential store with the right properties.**
   `KeychainPasswords` keeps internet passwords per origin with no service
   attribute of ours, so items are shared with Safari, listed and deleted in
   System Settings → Passwords, and protected by macOS's access control. The
   passwords feature (ADR on passwords) chose it over any store of ours for
   exactly the reasons a relay token has: one secret, one host, no reason to
   own the ciphertext.
4. **The config file is watched, and the watch is what "live" already means
   here.** `theme` applies the moment `config.toml` is saved, from the
   settings window or a text editor, because `ConfigStore` owns a
   `ConfigWatch` and posts one notification either way. Any second mechanism
   for servers would be a second definition of "the file changed".

## The decision

**One field, one paste.** Settings › Servers takes the whole line and
`RelayServerTokens.parse` finds the URL in it: strip ANSI, take from the first
`http(s)://` to the next whitespace, drop trailing sentence punctuation, then
`URLComponents`. The base is scheme, lowercase host and port; a path, query,
fragment and userinfo never reach the file. The `token` query item, when
present, must look like a JWT (letters, digits, `.`, `_`, `-`) or the line is
refused — a token with a space in it is a paste that went wrong, not a
credential. A bare URL is accepted as a server with no token, because that is
a LAN server with no `JWT_SECRET`. The name defaults to the host's first label
and is a field the user can change before or after.

**The token is a Keychain item and nothing else.** `kSecClassInternetPassword`
for the server's host and port, account `relay-tty`, realm `relay-tty session`
so it is never mistaken for a site login on the same host. `config.toml`
carries `name`, `url` and `enabled` — three facts a person may read, edit and
commit to a dotfiles repository — and the file, the log and every error
message are checked never to contain the token: the parse function is the one
place that holds it as a `String` outside the store call. Removing a server
removes the item, unless another server shares the host, whose token it also
is. Renaming a server touches no item, because the item is keyed on the host
and the name is the file's. A server whose table is in the file but whose item
is gone (a new Mac, a Keychain reset) is a row that says `no token` with a
paste button, not a silent 401.

**`[[servers]]` applies live, through the store, from every door.** Add,
remove, enable, disable and rename are edits to the file made through
`ConfigStore` (which keeps the file's comments, as it does for every key), and
the store's own `didChange` reaches `RelayServerBook.reconcile`, which diffs
the enabled entries against the endpoints it holds and starts or stops one
`RemoteSessionSource` per difference. The settings window, `maxpane server
add`, and a hand edit of the file therefore do the same thing by the same
path; there is no "relaunch to apply" and no second notification. A pasted
token is the one change the file cannot see, so it names its server to the
same `reconcile` explicitly. The strip hears which servers changed and
re-attaches every pane on them: a pane on a server that is now gone attaches
through a transport that fails at once with `server not configured`, so the
lane stays where it was with a one-line banner, and comes back when the
server does.

**The connection test is the source's first fetch.** Nothing in the window or
the book talks to a server. The row reads the registry's state and the
source's last error, and the source's `GET /api/sessions` on its own
`URLSession` is the "test" the acceptance criteria asked for. This is what
keeps synchronous network off the main thread with no separate code path to
keep honest.

## What was considered and not done

- **A separate token file under `~/.config` with mode 0600.** Simpler to
  test, and wrong for the same reasons a passwords file was: it would be a
  second credential store on this Mac, outside Keychain Access, outside
  System Settings, and a `git add -A` away from a repository.
- **Storing the token in `config.toml` behind a comment.** The file is the
  one thing here a person is meant to open in an editor and keep in dotfiles.
- **A refusal that stays until relaunch.** Phase 1 stopped a refused source
  for good; Phase 2 keeps the stop (retrying a 401 is only refused again)
  but makes a pasted token build a new source under the same name, so the
  fix is a paste and not a relaunch.
- **Renaming as remove-plus-add.** It would have left every lane on the old
  name saying `server not configured`. The core gained one door,
  `rename_relay_server`, that moves `pane.relay_server` and the `old:path`
  cwd tags (never a manual tag) in one statement each, and the book runs it
  before the file write so the panes are already under the new name when
  `reconcile` re-attaches them.
- **Per-server rows in the settings as `ConfigField`s.** A server is three
  facts that belong together and a row you act on (paste, remove), not three
  keys with defaults; the schema-coverage test exempts `servers` beside
  `keys` and says why.

## Consequences

- The sidebar draws each enabled server as its own header above its project
  groups, local groups first; a refused or unreachable server is a header
  with the state and no rows; a disabled server is not drawn. A click on the
  header opens Settings › Servers on that row. A 401 empties the server's
  slice of the registry, so ⌘O carries nothing from a server that has refused
  us.
- Through relaytty.com the session WebSocket is still accepted without the
  cookie (spike M7 §4). relay-tty 1.23.0 reads `?token=` on `/ws/share` only,
  so every relaytty.com row in Settings carries the one-line notice; the token
  is sent on the upgrade regardless, and nothing here changes when the server
  starts checking it (Phase 0b).
- The tests never touch the login keychain (`PasswordTests` states the rule):
  `RelayServerTokens.store` is a seam the app fills with the Keychain and the
  tests with a dictionary, and the assertions are about which origin an item
  is filed under, when it is removed, and that no file or message carries it.
