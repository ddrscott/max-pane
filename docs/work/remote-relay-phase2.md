# Remote relay, Phase 2: managing servers is a good experience

Phase 2 of [`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md),
on top of Phase 1. The owner's goal, verbatim: *"create a great user
experience to manage remote relay connections and connect to it from local
Max Pane app."* This phase is the experience.

## Outcome

Adding a server is: open Settings, paste the URL the server printed at
startup, see it connect and its sessions appear. Removing, disabling and
renaming are as direct. The state of every server is visible where the user
already looks (the sidebar), and every failure says what to do next.

## Acceptance Criteria

- **Settings › Servers.** A section in `SettingsWindow` in the app's own
  vocabulary (`// SERVERS` header style per the identity, square corners,
  greens for state). A list of configured servers: name, URL, state (a dot
  and a word: connected / reconnecting / refused / disabled), session count,
  and last error in one line. Buttons: Add, Remove (confirmed, in the
  existing `ConfirmPopup` style), Enable/Disable toggle, Rename inline.
- **Add is one paste.** One field. It accepts the whole
  `https://<host>/api/auth/callback?token=<jwt>` line the server prints, or
  a bare URL. Max Pane splits base URL and token, stores the token in the
  Keychain, writes `name`/`url`/`enabled` to `[[servers]]` in `config.toml`
  (keeping the user's comments), and immediately tests: `GET /api/sessions`.
  Success shows the count; 401 says "token refused — paste the Auth URL from
  the server's startup output"; unreachable says so with the host. The name
  defaults to the host (`yourslug.relaytty.com` → `yourslug`), editable.
- **Applies live.** Adding, removing, enabling or disabling a server takes
  effect without a relaunch: the registry gains or loses a source, the
  sidebar group appears or goes, lanes attached to a removed server show the
  existing disconnected state rather than vanishing. Editing `config.toml`
  by hand does the same through `ConfigWatch`.
- **Sidebar.** Each remote server is a group with its name and state; a
  disabled server is not shown; a refused one shows its group header with
  the state and no rows. Clicking the header opens Settings › Servers on that
  row. BLOCKED counts include remote sessions.
- **⌘O.** Remote sessions in the session list carry the server name; the
  ranker treats them like local ones. A server that is refused contributes
  nothing and does not slow the picker (no synchronous network in the
  picker path).
- **Token handling.** Never in `config.toml`, never logged, never in an
  error message. Removing a server deletes its Keychain item. A server whose
  token is missing (config present, Keychain item gone) shows "no token" in
  Settings with a Paste button.
- **Tunnel WS auth.** Per §1.4 of the plan, the WS upgrade through
  relaytty.com carries no cookie. Send the cookie anyway (LAN-direct needs
  it) and, if relay-tty has gained `?token=` on the WS paths since the spike
  (check the repo at `~/code/relay-tty`), send that too. If it has not,
  Settings shows a one-line notice on tunnelled servers: "sessions on this
  server are attachable without the token until relay-tty <version>", so
  the owner is never surprised. Say in the commit which case was found.
- README "Remote servers" section rewritten for the UI; ⌘/ sheet if any key
  is added; CHANGELOG. ADR-0021 on the paste-the-URL choice and the Keychain
  as the only token store.
- Tests: URL parsing (with token, without, with trailing junk, wrong host
  path), the config round trip through the line editor with comments intact,
  Keychain store/remove through the existing password store, and the live
  add/remove path against the fake server from Phase 1.

## Constraints

- No blue, no gradients, no rounded bubble cards; follow the Settings
  window's existing controls.
- No synchronous network on the main thread anywhere in this feature.
- Never commit a token; never launch the app from the agent's shell; never
  touch `/Applications/MaxPane.app`.
