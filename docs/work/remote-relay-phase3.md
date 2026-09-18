# Remote relay, Phase 3: start Claude Code on the remote server from Max Pane

Phase 3 of [`docs/plans/remote-relay-servers.md`](../plans/remote-relay-servers.md),
on top of Phases 1–2. The owner's goal ends: *"so I can move my Claude Code
sessions to that server."* This phase is that.

## Outcome

⌘O, type `claude`, pick the server, ↩: Claude Code starts on the remote box,
in the directory you meant, as a lane here, and goes BLOCKED in the sidebar
when it asks something. ⌘T and ⌘D beside a remote lane start on that lane's
server in that lane's directory. A remote project gathers with itself.

## The bar, and the feel (plan §0)

The owner can already open the relay-tty web app in a web lane. This phase is
worth landing if it does, feature for feature, what that cannot; the report
says in one paragraph what a user gets here that the web pane does not, and
what the web pane still does better. Not a benchmark.

And: **a remote session feels like a local one, with one simple mark.** Same
header, chips, keys, menu, gallery and dock behaviour. The only difference is
the server's name where the directory tag sits in the lane header and on the
sidebar group. No new colour, no icon language. Anything that cannot work on
a remote lane yet says so in one line when tried, never with a permanent badge.

## Acceptance Criteria

- **Spawn seam.** `SessionSpawning` protocol over the three `spawn` overloads
  in `RelaySessionSpawner`; `LocalSpawner` is today's code moved;
  `RemoteSpawner` is `POST /api/sessions {command,args,cwd,cols,rows}` with
  the cookie; 201 is readiness (no `waitForSocket`), followed by
  `GET /api/sessions/:id` for the on-disk metadata.
- **The no-`exec` wrapper is preserved remotely.** Send
  `command: "$SHELL", args: ["-li", "-c", "<line>\nexit $?"]` (the server
  resolves `$SHELL`), for the reason in `RelaySessionSpawner.swift:176-186`:
  an exec'd agent becomes the session leader and is never classified
  BLOCKED. Prove it: a remote `claude` session reaches `agentState:
  "blocked"` in the sidebar when it asks a question. A bare shell gets
  `--login` as locally.
- **⌘O knows about servers.** The command row shows where it will run; the
  default is the focused lane's server (local if the focused lane is local
  or there is none); a way to choose another server from the picker (a
  prefix like `@name ` or a server column, whichever fits `OmniPicker`'s
  existing grammar, documented in the ⌘/ sheet). The cwd for a remote spawn
  is the focused remote lane's cwd, else the server's home as reported by
  the server, never this Mac's `homeDirectoryForCurrentUser`. Recents
  remember the server and are offered only when that server is connected.
- **⌘T / ⌘D / `maxpane run`.** Beside a remote lane, ⌘T and ⌘D spawn on that
  lane's server in that lane's cwd. `maxpane run` from a *local* terminal
  keeps spawning locally; from a remote shell the CLI is absent (Phase 4).
- **Project root.** A remote lane's project root is `host:path`, source
  `cwd`, so gather (`Core::gather`) groups a remote project with itself and
  never with a local path that matches. If the server offers no git-root
  answer, use the cwd itself as the root and say so in the ADR; do not run
  `git rev-parse` inside the user's session.
- **Errors.** A failed remote spawn is one line naming the server and the
  server's error body; the picker stays open with the typed line intact.
- **The whole path, by hand, on the real box** (`ssh yorkshire-wsl`, the
  server from the spike): start `claude` there from ⌘O, see it BLOCKED, answer
  it, close the lane, reattach from ⌘O. Report what was seen and what was
  not.
- README: "Remote servers" gains starting things there; CHANGELOG; ADR-0022
  on the spawn wrapper over the API and the project-root rule.
- Tests against the fake server: the POST body for a command line, a bare
  shell, and a `--login` shell; the cwd rule for each ⌘O/⌘T/⌘D case; the
  project root rule in Rust.

## Constraints

- Never commit a token; never launch the app from the agent's shell; never
  touch `/Applications/MaxPane.app`.
- Nothing local changes when no server is configured.
