# Launch screenshots

Retina (2x) PNGs, dark theme, captured from a throwaway copy of the bundle on a
throwaway profile named `main`, windowed at 1728×1085 pt on the built-in
display. Every terminal is a stand-in: two native programs named `claude`
(one mid-turn, one stopped on a permission prompt) that relay-tty classifies
WORKING and BLOCKED for real, a scripted `tail -f relay.log`, and the repo's
own `git log --oneline`. Web panes are public pages (Claude Code docs, MDN,
doc.rust-lang.org, docs.rs). Sidebar sessions are stand-ins under
`~/Developer/…`, spawned before the app so their ages differ. No real session,
path, handle or account appears.

| File | Pixels | Shows |
|------|--------|-------|
| `hero.png` | 3456×2170 | Full window. Sidebar: a Bookmarks group with the kept page, then four project groups with the BLOCKED row at the top and working rows carrying live throughput. Strip: the BLOCKED `claude` lane focused and centred at size **m** so its "Do you want to proceed? ❯ 1. Yes" prompt reads at 600 px, the working `claude` lane at **s** to its left, the Claude Code docs lane to its right. |
| `sidebar.png` | 1380×2170 | Crop of `hero.png`: the session sidebar beside the working lane; BLOCKED chip on the top row, `N BLOCKED` on the group header and in the status bar. |
| `web-pane.png` | 1340×2010 | One web lane: header with the `s m xl` switch, the docs page, the find bar with `terminal` typed and the match highlighted, the chrome bar with the address and the ★ lit for a kept page. |
| `gallery.png` | 3456×2170 | ⌘G with eight lanes in a 4×2 grid, four terminals and four pages, all live; no orphan row. |
| `omni.png` | 3456×2170 | ⌘O with `docs` typed: the RUN and OPEN rows for the text, then three visited pages and the kept page (★), counts in the footer. |
| `bug-docked-sliver.png` | 360×900 | The torn sliver described below. |
| `thumbnail-240.png` | 240×240 | Pre-existing Product Hunt thumbnail, not from this pass. |

`hero.png`, `sidebar.png`, `web-pane.png` and `gallery.png` are copied to
`site/img/` for the landing page.

## Two states on the BLOCKED row

The BLOCKED row's right-hand slot reads `IDLE · 5m ago` while its chip says
BLOCKED. That is the app's behaviour, not a staging artefact: the slot is the
throughput slot and shows a rate only while the derived state is WORKING,
otherwise the word `idle`; the chip carries the state. See the comment above
`badgeIsThroughput` in
`swift/MaxPane/Sources/MaxPaneKit/Terminal/SessionTelemetry.swift` ("A session
can read `idle` here and `BLOCKED` on its chip at the same time") and the
"Green means the agent is actually working" paragraph in the README.

## Possible bug

`bug-docked-sliver.png` is a crop of a docked-lane capture at the seam. That capture and the settings crop were dropped from the launch set after a critic found the sliver and a third-party ad in one and a mid-lane crop in the other
between the sidebar and the first strip lane. After docking, a strip of the
lane that used to sit there is left behind: a `⋯` menu button, a `⋮` grip and
a few glyphs of page text (`al,`) drawn in the gutter, with nothing to own
them. Reproduced three times, on two different lanes:

1. Strip of 7–8 lanes, sidebar open, window 1728 pt wide, windowed
   (`MAXPANE_WINDOWED=1`).
2. Focus a web lane in the middle of the strip (⌘] from its neighbour), so it
   is centred.
3. ⌃⌘] to dock it right.
4. The strip re-lays out with the inset dock; the sliver appears between the
   sidebar and the leftmost visible lane and stays until the next scroll.

Undocking (⌃⌘] again) clears it. Not investigated further; not fixed.
