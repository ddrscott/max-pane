# ADR 0027 — A pasted picture becomes a path, on the machine the session runs on

**Status:** Accepted · 2026-09-20
**Decides:** what ⌘V does in a terminal when the clipboard holds a picture and
nothing a terminal could already take; where the file goes for a local
session and for a session on a relay server; and which relay-tty endpoint
carries it.
**Evidence:** the work item [`docs/work/paste-clipboard-image.md`](../work/paste-clipboard-image.md);
`TerminalPaste.clipboard(_:images:)` and `Terminal/PastedImages.swift`;
`PasteImageTests.swift`; relay-tty `server/api.ts:707-790` (`POST /api/upload`)
and its web client's `uploadOne`, `app/routes/sessions.$id.tsx:733-762`; a live
upload through the relaytty.com tunnel on 2026-09-20 (1 951 bytes in 0.16 s,
sha256 equal on the box, 401 with a wrong token).

## The facts

1. A screenshot taken to the clipboard has no text flavour, so ⌘V in a terminal
   did nothing. The programs the owner pastes into (Claude Code above all) take
   an image as a *path*.
2. A path means something only on the machine that reads it. For a session on
   a relay server, a path under this Mac's `~/Library` is noise.
3. The plan's rule (`docs/plans/remote-relay-servers.md` §4.5): remote files go
   through the relay server's API, the way the relay-tty web app does it.
   relay-tty has exactly one way in: `POST /api/upload`, raw body, the name in
   `X-Filename`, answering `{"ok", "path", "name", "size"}` with the absolute
   path it wrote, renaming rather than overwriting, 100 MB at most. An optional
   `X-Upload-Dir` overrides the destination; without it the file goes to the
   server's configured upload directory (`~/.relay-tty/uploads` by default).
   There is no endpoint that deletes an upload.

## Decision

### 1. Files, then text, then a picture

`TerminalPaste.clipboard` reads file URLs first, then the string, and only
then a picture. A browser's Copy Image usually carries the picture *and* a
string, and a copy out of a document carries words and a rendering of them; in
both the text is what was meant for a prompt. So an image paste happens only
when there is nothing else, which is exactly the screenshot case. `public.png`
is written byte for byte; TIFF, JPEG and anything else `NSImage` can read are
re-encoded, so the file is always a PNG.

### 2. Local: the profile's Caches, never overwritten, pruned at launch

`~/Library/Caches/app.ljs.maxpane/paste/paste-YYYYMMDD-HHMMSS.png` for the
default profile and `…/app.ljs.maxpane/profiles/<name>/paste/` for another.
Caches because these are copies of a clipboard. A name taken gets `-2`, `-3`,
and the write itself is exclusive. Files older than `paste_image_keep_days`
(7; 0 keeps them) go at launch, off the main thread; only `paste-*.png`
directly in that directory, so a profile never reaches another's.

### 3. Remote: `POST /api/upload`, the server's directory, no copy here

The pane uploads the PNG with the server's Keychain token as the `session`
cookie and pastes the `path` the server answers with. Three choices inside
that, each of which someone may want to reopen:

- **No `X-Upload-Dir`.** Putting the screenshot in the session's cwd would
  make for shorter paths and would also fill a git working tree with
  screenshots. Where uploads land is the server owner's setting
  (`PUT /api/upload-dir`, the relay-tty settings page), and this app honours
  it rather than overriding it.
- **No local copy.** The picture goes from the clipboard to the server and is
  not also written here: a file nothing refers to is only something to prune.
- **Nothing over there is pruned.** There is no endpoint to do it with, and
  the directory is shared with the web app's uploads. If the server grows a
  delete or an expiry, this is the line to revisit.

The upload is off the main thread; the pane's notice line says
`uploading 1.2 MB to NAME…` until it ends, and one picture goes up at a time.
The path arrives at the cursor when the server answers, after anything typed
meanwhile. **A failure pastes nothing** and says why in one line naming the
server; so does a pane whose server is no longer in `config.toml`.

### 4. Limits and the off switch

`paste_image_max_mb` (25; 0 refuses nothing) is measured on the PNG that would
be written, and refuses in one line before anything is written or sent.
`paste_images_as_files = false` makes an image-only clipboard paste nothing,
as before. Both are read at each paste. An image path is one shell word with
no control character in it, so it never raises ADR-0026's sheet, and like
every paste it carries no markers and no Return.

## Consequences

- `RelayUpload` is the first caller of the server's file API (plan Phase 4).
  A drop of local files onto a remote lane is the same call per file and is
  not done here: a drop still pastes this Mac's paths.
- A Windows relay server would answer with a path that does not start with
  `/`, and `RelayUpload.path(in:)` refuses it as no path at all. None exists
  today.
- Dragging a picture (not a file) onto a pane is still not accepted; the pane
  registers for file URLs only.
