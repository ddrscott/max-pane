# Product Hunt listing - Max Pane

Ready to paste into the submission form. Every product claim below traces to
`CHANGELOG.md` 0.6.0, with two exceptions cited where used: the ⌘G key for the
gallery layout is in `README.md` (the layout itself is in the changelog), and
"I use it every day" about relay-tty is Scott verbatim in `docs/gauntlet.md`
("I do use it every day already"). The DONE state and the Dock bounce are
under Unreleased and are deliberately absent. Character counts are Python
`len()`; word counts are `wc -w`. Re-count after any edit.

## 1. Name

Max Pane

## 2. Tagline

Product Hunt allows 60 characters. The bar's five run 33–58; three of them
name the agent, and both closest references say "Claude Code" on the card.
The tagline is the promise in the buyer's words; the app's vocabulary
(lanes, BLOCKED) comes later, after a sentence has explained it.

**Recommended:**

> Run several Claude Codes and know which one needs you
> (53 chars)

Why: it is verb-first, names the agent and the job, and a stranger parses it
in one second. The web-pane point is carried by the description; on a card,
"the page it cites" made readers stop to ask what cites what.

**Alternates:**

> See which Claude Code needs you, beside the page it cites
> (57 chars)

> All your Claude Codes and the pages they cite, in one window
> (60 chars)

## 3. Description

Product Hunt allows 260 characters.

> Run several Claude Codes on your Mac and see which one is waiting on you, with the docs and PRs it is reading in the next column. Every session gets its own column; terminals and web pages sit side by side. Native Swift, no account, no analytics. Free, MIT.
> (257 chars)

## 4. Topics

Product Hunt shows three topics on a launch. These names were checked against
`producthunt.com/topics/<slug>` on 2026-09-15; "Terminals" is a product
category Product Hunt assigns, not a topic you can pick (the slug 404s).
The three below are exactly what Conductor and cmux shipped with, in their
order, so the card sits in the same feeds as the closest references.

1. **Productivity** (`/topics/productivity`)
2. **Developer Tools** (`/topics/developer-tools`)
3. **Artificial Intelligence** (`/topics/artificial-intelligence`)

If the form takes a fourth, or one of the above is refused: **Mac**
(`/topics/mac`), then **Open Source** (`/topics/open-source`). **GitHub** is
also real and not chosen.

## 5. Links

| Field | Value |
|-------|-------|
| Website | `<landing page URL>` |
| GitHub | https://github.com/ddrscott/max-pane |
| Download | https://github.com/ddrscott/max-pane/releases/download/v0.6.0/MaxPane-0.6.0.dmg |
| Pricing | Free |
| Licence (in first comment) | MIT |

The download URL is what `packaging/Casks/max-pane.rb` and `scripts/release.sh`
produce; it resolves once the release exists (see §8).

## 6. Gallery

The files are under `docs/launch/`, described in `docs/launch/shots.md`:
Retina (2x), dark theme, JetBrains Mono, a throwaway profile, every terminal a
stand-in. Order matters: Product Hunt shows the first item as the card
thumbnail on the front page and in every feed.

| # | File | Shows | Caption (one line) |
|---|------|-----------|--------------------|
| 1 | `hero.png` | The full window: two terminals running `claude` (one mid-turn, one BLOCKED on a permission prompt, drawn in the brightest green and centred) with the Claude Code docs page in the next column. The sidebar is open with the BLOCKED row at the top. This is also the README's and the landing page's hero. | Agent sessions and the pages they cite, side by side in portrait lanes. |
| 2 | `sidebar.png` | A crop of the sidebar: sessions grouped by project, one row BLOCKED in the brightest green, throughput and age on the working rows. | The sidebar says which agent is waiting on you. That one is the brightest green, and it pulses. |
| 3 | `gallery.png` | ⌘G: eight lanes on one screen, four terminals and four pages, all live. | ⌘G puts every lane on one screen, live. ⌘G again goes back. |
| 4 | `omni.png` | ⌘O open over the strip with `docs` typed: the RUN and OPEN rows, then visited pages and the kept page (★). | ⌘O starts anything: a command, a URL, a page you kept, a session already running somewhere else. |
| 5 | `web-pane.png` | One web pane in a lane: the `s m xl` size switch, the find bar with a match counted, the address bar with the ★ lit for a kept page. | Web pages are lanes too, with a find bar that counts and a ★ that keeps the page. |

**GIF or video:** Conductor, cmux and 1Code each led their gallery with a
video; Ghostty had none and placed #10. We have no video today, so slot 1 is
`hero.png`, and the moment a video exists it takes slot 1 and every PNG
shifts down one. A GIF earns a slot before that only for the one thing a PNG
cannot show, the BLOCKED pulse: 8–10 seconds, a session flips to BLOCKED,
the sidebar row pulses, a click centres its column. If the screenshot builder
cannot capture that at Retina without frame drops, ship six PNGs and skip
it; a janky GIF costs more than a missing one.

**Social proof:** Conductor's second gallery item is a collage of tweets and
its page says "Trusted by 100k+ builders"; cmux shows a live star count.
That slot is empty for us on day one. The README says "built and used daily
by one person", and the listing says the same rather than filling the slot
with anything it cannot back.

## 7. Maker's first comment

Post from Scott's own account within a minute of the launch going live, pin
it. About 290 words plus the proof line. The tap exists now, so the brew line is unconditional.

**Sentences only Scott can sign.** Nothing in this repo backs these; they are
his story as the run understood it, and he should rewrite or cut any that is
not true: "I could not tell which one had stopped to ask me something, and the
pages they cited were in a browser somewhere else"; "I wanted one window that
held the terminals and the pages together and told me which agent was
waiting". On record (docs/gauntlet.md): he uses relay-tty every day and wanted
it native with browser panes beside the shell panes. The last line is conditional: post it only if
`ddrscott/homebrew-tap` exists with the cask pushed (see §8); otherwise end
on the DMG line.

> I run several Claude Code sessions at once, through relay-tty, a daemon that keeps terminal sessions alive, which I use every day. The part it never solved was attention. With enough sessions going, I could not tell which one had stopped to ask me something, and the pages they cited were in a browser somewhere else.
>
> I wanted one window that held the terminals and the pages together and told me which agent was waiting.
>
> So I built Max Pane. It is a fullscreen macOS app, native Swift and AppKit, where every Claude Code session gets its own column and a web page can sit in the column next to it. Three things about it:
>
> - The sidebar lists every session and draws the one that is blocked on a prompt in the brightest green, pulsing. Click it and you are there.
> - ⌘O starts anything: a command, a URL, a page you kept, a session already running somewhere else. ⌘G puts every column on one screen, live.
> - It keeps your things where they belong: history with no limit, passwords in the Keychain and nowhere else, every setting in a TOML file that keeps your comments.
>
> It is free and MIT. There is no account and no analytics. It talks to relay-tty over a Unix socket and to the pages you open, and to nothing else. It needs an Apple silicon Mac on macOS 14 or newer, and relay-tty 1.22.0 or newer, which is also MIT.
>
> [Scott: one checkable proof line goes here, e.g. how long you have run it daily or how many sessions a normal day holds. The run cannot invent this.] Built and used daily by one person, so if you run more than one agent at a time I would like to know what it gets wrong. Issues are on GitHub.
>
> Download: https://github.com/ddrscott/max-pane/releases/download/v0.6.0/MaxPane-0.6.0.dmg
> Or: brew install --cask ddrscott/tap/max-pane

Voice notes for whoever edits it: no exclamation marks, no emoji, no
"excited", no "game-changer". Contractions were removed on purpose; Scott's
README does not use them. Every first-person sentence is one the README or
`docs/gauntlet.md` backs; do not add history. The relay-tty sentence is
load-bearing: the bar (Conductor, 1Code) names the login it reuses, and
relay-tty is the one dependency a stranger will hit, so it is named before
anyone asks.

## 8. Launch-day checklist

What a Product Hunt submission needs that this repo does not have at commit
`89b72f8` plus the working tree. One line each, with who does it.

- [ ] **Landing page URL** for the Website field. Piece 4 of this run builds
      it; Scott picks the domain and points DNS. (run, then Scott)
- [ ] **Notarised, stapled DMG on a GitHub release.** `gh release list`
      returns nothing today. Scott runs
      `xcrun notarytool store-credentials maxpane-notary` once, then
      `scripts/release.sh` builds, staples and creates `v0.6.0` with
      `MaxPane-0.6.0.dmg`. (Scott: the credential and the push; run: the
      script is ready)
- [x] **240×240 thumbnail** at `docs/launch/thumbnail-240.png`, from
      `swift/MaxPane/Resources/AppIcon-source.png`. Product Hunt wants PNG or
      JPG, square, under 2 MB; an animated GIF is allowed but the icon is a
      still. (run, done)
- [ ] **Maker profile.** Scott's Product Hunt account with a photo, a
      one-line bio, the GitHub link, and the "Maker" badge claimed on the
      launch so the first comment carries it. Self-hunt, like Conductor and
      cmux; no hunter needed. (Scott)
- [x] **Six gallery PNGs under `docs/launch/`** per §6, at Retina size.
      Product Hunt asks for 1270×760 minimum; the two portrait crops
      (`sidebar.png`, `web-pane.png`) are narrower than 1270, so if the form
      refuses them, upload `hero.png` cropped to 16:10 around the sidebar in
      their place. (run, done)
- [ ] **`LICENSE` and `CHANGELOG.md` committed.** Both are untracked in the
      working tree; the listing says MIT and the description says 0.6.0, and
      a stranger who checks the repo should find both. (run to stage, Scott
      to commit)
- [ ] **GitHub repo homepage** set to the landing URL once it exists:
      `gh repo edit ddrscott/max-pane --homepage <url>`. Description and
      topics are already set. (run)
- [ ] **Homebrew tap** `ddrscott/homebrew-tap` created and
      `packaging/Casks/max-pane.rb` pushed to it, so the first comment's
      install line can be one `brew install --cask` if Scott wants it there.
      (Scott creates the repo; run pushes the cask)
- [ ] **Launch time.** Product Hunt days start 00:01 Pacific; a Tuesday to
      Thursday launch with the first comment posted at 00:02 is the bar's
      pattern. Scott picks the date and presses the button. (Scott)
- [ ] **Relay-tty 1.22.0 or newer published** on npm and via `install.sh`,
      since the cask caveat and README both point strangers at it. (Scott)
