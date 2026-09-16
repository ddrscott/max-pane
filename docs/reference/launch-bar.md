# The launch bar

What "Call of Duty screenshots" were for Claude of Duty, these pages are for
Max Pane's Product Hunt launch: real, inspectable pages, captured as pixels on
2026-09-15, that every builder and critic in this run is judged against.

Screenshots live in the run scratchpad:
`/private/tmp/claude-503/-Users-spierce-code-max-pane/cb74c737-a423-47ad-bbc4-36b4db5e2b00/scratchpad/bar/`.
All are 1293×924 viewport captures (PNG) unless noted. Product Hunt pages were
captured logged out, so upvote counts are the public figures at capture time.

How they were verified: each landing page and Product Hunt page was opened in
Chrome and screenshotted; text quoted below was read off the rendered page or
from a fetch of the same URL. Where the two disagreed (gallery counts, day
rank), the screenshot wins and the discrepancy is noted. Nothing is quoted
from memory.

Candidates checked and set aside:

- **Zed** (zed.dev): Zed 1.0 launched 2026-05-01 and placed #2 of the day
  (317 upvotes, 12 comments). It is an editor, not an agent-supervision
  surface, and the closer terminal-shaped analogs below make it redundant.
  Not captured.
- **Warp**: kept as the one #1-of-the-day terminal launch, but its landing page
  has since pivoted to "cloud software factories" (see §5), so its 2022 launch
  page, not its landing page, is the reference.
- Other 2025–2026 "run many agents" launches found on Product Hunt, none of
  which beat the four below on rank plus closeness: Shepherd Terminal (#7),
  Maestri (#8, native macOS infinite canvas, $18 lifetime Pro), Parallel Code
  (#6), Baton (#15), agent-manager (#13), Notchcode (#24), Mozzie (#24),
  AgentGrid, Coddo, Orca (#45). Two #1-of-the-day launches in the adjacent
  "voice for your agents" niche: SKI (2026-07-30, 594 upvotes) and Heard
  (2026-07-25, 339 upvotes).

---

## 1. Ghostty — the native terminal that launched on a landing page, a README and a DMG

**URLs**

- Landing: https://ghostty.org
- Download: https://ghostty.org/download
- Product Hunt: https://www.producthunt.com/products/ghostty (launched
  2024-12-27)
- Source: https://github.com/ghostty-org/ghostty

**Screenshots**

- `ghostty-landing.png` (776×555, 0.6-scale capture)
- `ghostty-download.png`
- `ghostty-producthunt.png`

**Product Hunt tagline (58 chars):**
"A fast, feature-rich, and cross-platform terminal emulator"

**Product Hunt description (as shown):**
"Ghostty is a terminal emulator that differentiates itself by being fast,
feature-rich, and native. While there are many excellent terminal emulators
available, they all force you to choose between speed, features, or native
UIs. Ghostty provides all three."

**Result:** #10 Day Rank badge on the page (a third-party dashboard says #9),
159 points, 5 comments, 13 reviews at 5.0, 172 followers. Category
"Terminals". Launch tags: Productivity · Software Engineering · GitHub.
Hunted by "Mo" (Hunter badge), not by the maker.

**Hero structure (ghostty.org), top to bottom:**

1. No headline. A mock macOS window (traffic lights, title "👻 Ghostty")
   containing the ghost logo rendered as ASCII art in purple and white on
   black. It fills most of the viewport.
2. One line of small grey text under the window: "Ghostty is a fast,
   feature-rich, and cross-platform terminal emulator that uses
   platform-native UI and GPU acceleration."
3. Two buttons: **Download** (outlined, purple) and **Documentation**.
4. Nothing else above the fold; the page is otherwise empty. Nav on the
   download page reads Docs · Discord · GitHub · Download.

**Gallery on Product Hunt:** 3 dots visible in the carousel (a fetch of the
page reported 4). No video. In order: (1) the ASCII ghost in a terminal
window, same as the landing hero; (2) the GitHub README header ("Fast,
native, feature-rich terminal emulator pushing modern features" with
About · Download · Documentation links); (3) the "Roadmap and Status" table
from the README.

**Maker's first comment:** none. The pinned comment is the hunter's, 4
sentences, roughly 70 words: a note that Ghostty is Mitchell Hashimoto's
passion project worked on in his free time, quoting his line that it is not
a full-time job for anyone, and asking people to remember that when
interacting with the project. The other comments are Chris Messina asking
"How does this differ in goals from iTerm?" and the hunter replying with a
link to the About doc.

**Install / CTA path:** landing → **Download** (click 1) → download page
("Download Ghostty", "Version 1.3.1 - Release Notes"; macOS card: "A
universal binary that works on both Apple Silicon and Intel machines.
Requires macOS 13+ (Ventura or later)") → **Universal Binary** (click 2)
which is a direct link to `https://release.files.ghostty.org/1.3.1/Ghostty.dmg`.
Open the DMG, drag to Applications, launch. The docs state the official
macOS binaries are signed and notarized by the Ghostty project, and offer
`brew install --cask ghostty` as an equivalent. Two clicks to a DMG, no
account, no dependency.

**Pricing / licence:** "Free" label on Product Hunt. MIT.

---

## 2. Conductor — the closest positioning: many Claude Codes, supervised, on a Mac

**URLs**

- Landing: https://www.conductor.build
- Pricing: https://www.conductor.build/pricing
- Install docs: https://www.conductor.build/docs/installation
- Product Hunt: https://www.producthunt.com/products/conductor-aa77ddef-e6d3-4805-a179-7b2e17b6e22e
  (launched 2025-08-27)
- Also launched on YC Launch and Show HN ("Show HN: Conductor, a Mac app that
  lets you run a bunch of Claude Codes at once").

**Screenshots**

- `conductor-landing.png`
- `conductor-pricing.png`
- `conductor-producthunt.png`
- `conductor-producthunt-maker-comment.png`

**Product Hunt tagline (39 chars):**
"Run a bunch of Claude Codes in parallel"

**Product Hunt description (as shown):**
"Conductor lets you run a bunch of Claude Codes all at once, on your Mac.
Each Claude gets an isolated copy of your codebase. See at a glance what
they're working on, then review and merge their changes."

**Result:** #7 Day Rank, 303 points, 53 comments, 21 reviews at 5.0, 388
followers. Launch tags: Productivity · Developer Tools · Artificial
Intelligence. Badged "Y Combinator". Hunted by the maker.

**Hero structure (conductor.build, as it is today), top to bottom:**

1. Nav: Changelog · Docs · Pricing · Enterprise · Join Us · **Download**.
2. A pixel-font "CONDUCTOR" wordmark, then a two-line headline with a
   typewriter effect on the second line: "Run a team of coding agents" /
   "on your Mac." (it cycles; the page title says "in the cloud").
   40 chars in the "on your Mac." state.
3. One CTA button: **Get Conductor →** (links to `/pricing`, not to a file).
4. A one-line testimonial in italics: "feels like going from typing with two
   fingers to having eight arms" — Frank, Product Designer, Thinking
   Machines.
5. The hero image: a full-width screenshot of the app (a `.webp`; the
   screenshot's own chat transcript says 3462×2128, compressed to 316 KB).
   It shows a sidebar of named workspaces with ages ("Landing page copy
   10h"), an agent transcript in the middle ("Done and pushed." with a
   bulleted summary and PR link), and a right-hand diff panel headed
   "#8376 · Ready to merge · Merge" with a file list and +/- counts.
6. Below the fold: "Trusted by 100k+ builders" with Linear, Vercel, Notion,
   Ramp, Y Combinator, Square, PostHog, Spotify logos; then sections headed
   "Ludwig has entered the chat." (multiplayer), "A cloud sandbox for every
   agent.", "Bring your own subscriptions and keys." ("Conductor runs the
   first-party Claude Code, Codex, Cursor, and OpenCode agents under the
   hood."), and "Conduct from anywhere." (an iPhone render).

**Gallery on Product Hunt:** 5 dots. The first item is a **video** (play
button over an app screenshot with the workspace sidebar). Second is a
collage of tweets praising the product. The remaining three are app
screenshots.

**Maker's first comment:** Charlie Holtz, badged Conductor · Maker, pinned.
Six short paragraphs, about 200 words, 10 upvotes:

1. Story: "Back in June, we started doing most of our dev work through
   Claude Code. It's been so productive we even declared it a member of the
   team :)"
2. Problem: wanted more Claude, tooling was tedious, tried cloning the repo
   into three directories; "it felt like driving a Subaru with a jet engine
   strapped on."
3. Turn: "We needed a tool that would push Claude to its limits and that we'd
   enjoy working in all day. So we built Conductor!"
4. Proof: they use Conductor to build Conductor; "I've merged thousands of
   lines of code with Conductor in the past month".
5. Offer: "It's free—we use your existing Claude Code login. You can download
   for Mac now."
6. Ask: "Can't wait to hear what you think!"

**Install / CTA path:** landing **Download** (click 1) starts the download;
docs say "Press D or click Download Conductor. Drag the Conductor app to
your Applications folder. Open Conductor." On first open the app checks for
GitHub auth in the terminal environment (`gh auth status`) and at least one
agent login (`claude /login`, `codex login`, or a Cursor key) and "walks you
through setup" if anything is missing. So: one click to the artifact, then a
drag, then a first-run checklist that depends on tools you already have.
The docs do not name the file extension; the drag-to-Applications step
implies a DMG. Mac only.

**Pricing / licence:** "Free" label on Product Hunt. Pricing page: **Free
$0** ("Run multiple coding agents in parallel", "Local workspaces on your
Mac", "Integrate with the newest frontier and open source models", "Bring
your own subscriptions and keys"), **Pro $50/mo** (Conductor Cloud,
Multiplayer, API, mobile app "coming very soon"), **Teams $60/mo/user**,
**Enterprise Custom**. Closed source.

---

## 3. cmux — the closest build: native Swift/AppKit terminal for agents, with a browser inside it

**URLs**

- Landing: https://cmux.com
- Getting started: https://cmux.com/docs/getting-started
- Product Hunt: https://www.producthunt.com/products/cmux (launched
  2026-02-28)
- Source: https://github.com/manaflow-ai/cmux (27.1k stars shown in the
  site nav at capture)
- Also a Show HN that reached #2 on Hacker News, and a YC Launch.

**Screenshots**

- `cmux-landing.png`
- `cmux-landing-scrolled.png` (the product mosaic and FAQ)
- `cmux-producthunt.png`
- `cmux-producthunt-maker-comment.png`

**Product Hunt tagline (48 chars):**
"The open-source terminal built for coding agents"

**Product Hunt description (as shown):**
"cmux is the open-source terminal built for multitasking with coding agents.
It has vertical tabs, notifications, a built-in browser, and it's built on
Ghostty. When Claude Code needs you, the pane glows blue and the sidebar
tells you why. No Electron/Tauri. Just Swift/Appkit."

**Result:** #14 Day Rank, 88 points, 7 comments, 1 review, 73 followers.
Category "Terminals". Launch tags: Productivity · Developer Tools ·
Artificial Intelligence. Product Hunt was not the channel that grew cmux;
GitHub and HN were.

**Hero structure (cmux.com), top to bottom:**

1. Nav: Docs · Blog · Changelog · Community · Jobs · GitHub · a GitHub star
   count pill · **Download for Mac** (Apple icon, dropdown) · theme toggle.
2. App icon + "cmux" wordmark.
3. Headline with a typewriter cursor, cycling: "The terminal built for
   coding agents" (36 chars) / "The terminal built for multitasking,
   organization, and programmability."
4. Subhead: "Free and open source native macOS terminal built on Ghostty.
   Vertical tabs, notification rings when agents need attention, split
   panes, and a CLI for programmability."
5. Two CTAs: **Download for Mac** (Apple icon, dropdown chevron) and
   **View on GitHub**.
6. A "Features" list of ten bold-lead bullets, still above the fold:
   Vertical tabs, Notification rings, In-app browser, Split panes,
   Programmable, GPU-accelerated, Lightweight ("native Swift + AppKit, no
   Electron"), Open source ("free and GPL-licensed"), Keyboard shortcuts,
   iOS companion.
7. Below the fold: a large mosaic screenshot of the app (sidebar of agent
   sessions with PR titles, several terminal panes, a GitHub PR view in the
   built-in browser, an iPhone showing the companion app), then a 17-question
   FAQ ("How does cmux relate to Ghostty?", "What coding agents does cmux
   work with?", "Is cmux free?" ...), then Community.

The hero is text-first, left-aligned, monochrome, with no hero image until
the reader scrolls.

**Gallery on Product Hunt:** 5 dots. The first is a **video** (play button
over a dark app screenshot). The rest are app screenshots.

**Maker's first comment:** Austin Wang, badged Manaflow · Maker, pinned.
About 230 words, 6 upvotes:

1. "Hey Product Hunt!" then "We're Austin and Lawrence, the creators of
   cmux."
2. Story/problem: they ran many Claude Code and Codex sessions in Ghostty
   split panes and relied on macOS notifications, but "Claude Code's
   notification body is always just 'Claude is waiting for your input' with
   no context. With enough tabs open, we couldn't even read the titles
   anymore."
3. Why not the alternatives: orchestrators were Electron/Tauri and slow;
   "GUI orchestrators lock you into their workflow".
4. Turn: "So we built cmux as a native macOS app in Swift/AppKit. No
   Electron/Tauri." followed by four bullets: Vertical tabs · Blue rings
   around panes that need attention · Built-in browser · Based on Ghostty.
5. Technical proof: libghostty rendering, reads your Ghostty config,
   scriptable browser ("Agents can snapshot the accessibility tree, click
   elements, fill forms, and evaluate JS, all from the terminal").
6. Offer: "It's completely free & open source (AGPL)." plus the one-line
   install `brew install --cask manaflow-ai/cmux/cmux`.
7. Ask: feedback, questions, and a GitHub star, with the repo link.

Replies on the page: "Any plans to build a mobile app for remote
monitoring?", "Been using this very day, new daily driver", and a Ghostty
fan saying "I also hate electron".

**Install / CTA path:** **Download for Mac** (click 1) → a
"Thanks for downloading cmux!" page that auto-starts
`https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg`
(53.1 MB at v0.64.8). Open the DMG, drag to Applications; first launch shows
the standard Gatekeeper "identified developer" confirmation, then "A terminal
window with a vertical tab sidebar on the left" and "One initial workspace
already open." Auto-updates via Sparkle. Or `brew tap manaflow-ai/cmux &&
brew install --cask cmux`. Requires macOS 14.0 or later, Apple Silicon or
Intel. No sign-in, no dependency. One click to a DMG.

**Pricing / licence:** "Free" label on Product Hunt. Landing page says
"free and GPL-licensed"; the maker comment says AGPL; GitHub shows "License:
Other".

---

## 4. 1Code — the #1-of-the-day "run Claude Codes in parallel" launch

**URLs**

- Product Hunt: https://www.producthunt.com/products/1code-cursor-like-ui-for-claude-code
  (launched 2026-01-16)
- Landing: https://1code.dev now returns a 308 redirect to
  https://github.com/21st-dev/1code, which carries the banner "This
  repository was archived by the owner on Jul 7, 2026. It is now
  read-only." The landing page that won the day no longer exists.
- Show HN: https://news.ycombinator.com/item?id=46637723 (75 points, 49
  comments)

**Screenshots**

- `1code-producthunt.png`
- `1code-producthunt-maker-comment.png`
- `1code-landing-redirects-to-github.png` (905×647, 0.7-scale capture; the
  archived repo, which is what the landing URL resolves to today)

**Product Hunt tagline (42 chars):**
"Open source Cursor-like UI for Claude Code"

**Product Hunt description (as shown):**
"Whats 1Code? An app to run your Claude Code agents in parallel that works
on Mac and Web. On Mac - run locally, with or without worktrees. On Web -
run in remote sandboxes with live previews of your app, mobile included, so
you can check on agents from anywhere. Running multiple Claude Codes in
parallel dramatically sped up how we build features."

**Result:** **#1 Day Rank**, 574 points on the page today (597 on a
third-party dashboard), 53 comments, 905 followers. Categories: AI Coding
Agents · AI Code Editors. Launch tags: Developer Tools · Artificial
Intelligence · GitHub. Badged "Y Combinator". Hunted by the maker (Serafim).

**Hero structure:** not recoverable; the landing page is gone. The GitHub
README that replaced it opens "Open-source coding agent client. Run Claude
Code, Codex, and more - locally or in the cloud." and its first section
headings are Highlights, Features, "Run coding agents the right way", "UI
that finally respects your code", "Plan mode that actually helps you think".

**Gallery on Product Hunt:** 6 dots. The first is a **video** (play button
over the app: a chat transcript with an agent, dark UI). Second is a diff
view with a code panel; third is an editor/code view. The remaining three
are app screenshots.

**Maker's first comment:** Serafim, badged 21st · Maker, pinned. About 170
words, 19 upvotes, with inline section labels:

1. Credentials first: "Hi It's Serafim and Sergey from 21st.dev, in the last
   10 months we've built and launched 9 products, getting over 1 millions
   total users, $200k in revenue, and 10k GitHub stars."
2. "Motivation": "Claude Code has been our go-to for 4 months. When Opus 4.5
   dropped, parallel agents stopped needing babysitting. You could finally
   run multiple and trust them. But the more agents we ran, the more the CLI
   felt like a limitation, not a feature."
3. Turn: "So we built 1Code.dev"
4. "What's next:" bug bot, QA agent, OpenCode/Codex support, an API for
   remote sandboxes.
5. "Try it:" "We're open-source, so you can just bun build it. Paid tiers
   exist too - for us it's gonna be highest signal that we're on the right
   track."
6. Ask: "Either way, we'd love to hear your feedback!"

The first reply asks whether it works with a regular Anthropic subscription;
the co-maker answers that it wraps the Claude Code CLI so it accepts whatever
Claude Code accepts.

**Install / CTA path (at launch, per the README and HN post):** build from
source with Bun (`bun install`, `bun run claude:download`, `bun run build`)
or subscribe at 1code.dev for pre-built releases. Electron app. No DMG link
on the README today. This is the weakest install path of the four and it
still won the day, on the strength of a video, a YC badge, and the makers'
track record.

**Pricing / licence:** "Free Options" label on Product Hunt. Apache-2.0 on
GitHub. HN post: Pro $20/mo for hosted web with live previews.

---

## 5. Warp — the only terminal that won Product of the Day (2022), for the maker-comment template

**URLs**

- Product Hunt launch thread (the launch page itself returned "Oops,
  something went wrong on our end" at capture):
  https://www.producthunt.com/p/warp/warp
- Product page: https://www.producthunt.com/products/warp
- Landing today: https://www.warp.dev
- Download: https://www.warp.dev/download · Pricing: https://www.warp.dev/pricing

**Screenshots**

- `warp-producthunt-2022-thread.png`
- `warp-producthunt-2022-maker-comment.png`
- `warp-landing.png` (the 2026 page, which no longer sells a terminal
  above the fold)

**Product Hunt tagline, 2022 launch (33 chars):**
"The terminal for the 21st century"

**Description (as shown on the thread):**
"Warp is a modern Rust-based terminal that's fast, easy to use, and built
for teams. 1) Commands and outputs are grouped like a data notebook 2) Input
is a modern code-editor with tab completions 3) Share outputs via links 4)
Save and run team commands"

**Result:** #1 Product of the Day, 2022-04-06. 737 upvotes and 106 comments
on the thread today (718 at the time per a third-party dashboard). Hunted by
Ellen Chisa. Later a 2022 Golden Kitty. The product page now carries the
tagline "The open-source ADE" and lists six launches; Warp 2.0 (2025-06-25)
and Warp Open-Source (2026-05-11) did not repeat the #1.

**Hero structure (warp.dev today):** headline "Open infrastructure for cloud
software factories"; subhead "Build on Warp: factories as code, any model or
harness, with evals, benchmarks, and self-improvement built in."; CTAs
**request early access** (primary, black) and **download warp terminal**
(secondary, outlined); a line "Get up to $10,000 in free factory usage";
hero media is an animated "[ fig. 1 — the factory ]" grid diagram labelled
"FACTORY.YAML · LIVE" with a status line "112 tasks · 1 agents active ·
1,422 PRs shipped"; then "trusted by 800k+ devs at" with Asana, Docker,
GitHub, VMware, Amplitude, Teamworks, Nvidia, Ramp logos. Monospace type on
a dotted grid. The terminal is a secondary CTA on its own maker's homepage.

**Gallery:** not recoverable from the launch page (error page at capture).

**Maker's first comment:** Zach Lloyd, badged Warp · Maker. About 370 words,
the longest of the set, with bold section headers:

1. Thanks the hunter by handle, then "👋🏼 Hi Product Hunt community, I'm
   Zach, founder here at Warp, and I'm excited to launch Warp to the
   community today." plus the one-line description.
2. **Warp's origin** — three dashed bullets: the terminal hasn't changed in
   40 years; unlock CLI power for all developers; bring collaboration to the
   terminal (his GDocs lead-engineer credential).
3. **Making terminals easy to use** — "Warp reimagines the terminal from the
   ground up." then six emoji bullets (editor-like input, grouped
   commands/outputs, Workflows and natural-language command generation,
   history search, command palette, theme picker).
4. **Making terminals work for teams** — two emoji bullets (share outputs
   via link, project Workflows) and what's coming.
5. Tech footer: built in Rust with GPU-accelerated graphics, works with zsh,
   fish and bash.
6. Ask: what do you think, what else would you like; Discord and Twitter
   links.

The top-voted reply (24 upvotes) is a three-point objection: telemetry,
closed source, "VC investors is not the formula I'd like my terminal to be
built on", with a Warp employee answering each point.

**Install / CTA path:** download page offers `.dmg` or
`brew install --cask warp`; macOS 10.14+. One click to a DMG.

**Pricing / licence (today):** Free $0 · Build $20/mo · Max $200/mo ·
Business $50/user/mo · Enterprise. The client is now open source per the
product page tagline.

---

## The bar, in one sentence

**Conductor is the closest analog for Max Pane**, because it is the only one
of the five that sells the same job (watch several coding agents run on your
Mac and know which one needs you) to the same buyer, on a landing page whose
hero is one screenshot of that job being done, with a free tier that
piggybacks on the Claude Code login you already have and a maker comment
that tells the origin story in six short paragraphs. cmux is the closest
build (native Swift/AppKit, terminal plus browser, DMG plus cask, no account)
and sets the install bar; Ghostty sets the bar for a landing page that is
nothing but the product and a Download button.

## What a #1-of-the-day launch has that Max Pane currently lacks

Facts from the captures above against the repo at commit `89b72f8`
(README, `scripts/release.sh`, `packaging/Casks/max-pane.rb`, `docs/`).

- [ ] **A published release artifact.** The README links
      `github.com/ddrscott/max-pane/releases/tag/v0.5.0`; `gh release list`
      on that repo returns nothing. Ghostty, cmux and Warp each resolve their
      Download button to a DMG URL in one or two clicks.
- [ ] **A notarised, stapled DMG.** `release.sh` prints "NOT notarised —
      strangers will see a Gatekeeper warning" when stapling is absent;
      Ghostty's docs state the binaries are signed and notarised; cmux's
      first-run doc shows only the standard identified-developer prompt.
- [ ] **A Homebrew cask that a stranger can tap.** `packaging/Casks/max-pane.rb`
      exists in the repo; cmux (`brew install --cask manaflow-ai/cmux/cmux`),
      Ghostty (`brew install --cask ghostty`) and Warp (`brew install --cask
      warp`) each publish theirs.
- [ ] **A single-artifact install.** Max Pane's README install is three steps
      and the first is a `curl | bash` for relay-tty, a separate daemon.
      None of the five references require a second install before the app
      opens; Conductor's first-run checklist only asks for logins to tools the
      buyer already has.
- [ ] **A landing page.** Max Pane has a README only. Four of five references
      have a dedicated landing page with a hero screenshot or diagram and a
      Download button above the fold; even 1Code had one at launch.
- [ ] **A hero image.** README.md embeds `docs/launch/hero.png`, which is
      not in the tree. Conductor's hero is a 3462×2128 app screenshot; cmux's
      is a product mosaic; Ghostty's is the ASCII ghost.
- [ ] **A video as the first gallery item.** Conductor, cmux and 1Code all
      lead their Product Hunt gallery with a video; 1Code's Show HN also led
      with a YouTube link. Max Pane has no video or GIF in the repo.
- [ ] **A 5–7 item gallery.** Conductor 5, cmux 5, 1Code 6, Ghostty 3. Max
      Pane has three round PNGs in `docs/` (`round1-statusbar.png`,
      `round2-merged.png`, `round2-picker.png`) and one bar image.
- [ ] **A Product Hunt tagline of 33–58 characters that names the job.** The
      five taglines above run 33, 39, 42, 48 and 58 characters; three of the
      five name the agent ("Claude Codes", "coding agents", "Claude Code").
      Max Pane has no tagline drafted in the repo.
- [ ] **A maker's first comment.** Every launch except Ghostty's has one,
      170–370 words, in the order story → problem → "so we built X" →
      proof → offer (free, uses your existing login) → ask. Ghostty's absence
      of one coincides with its #10.
- [ ] **A free-tier statement that names the login it reuses.** Conductor:
      "we use your existing Claude Code login." 1Code: wraps the Claude Code
      CLI. cmux: "completely free & open source". Max Pane's README says
      nothing about Claude Code login or cost.
- [ ] **An "install to first agent" line in the docs.** cmux: "One initial
      workspace already open." Conductor: numbered first-workspace steps. Max
      Pane's README step 3 is close ("Press ⌘O, type `claude`, press ↩") but
      sits after the unpublished DMG.
- [ ] **A licence line on the listing.** All five show Free / Free Options
      and a licence (MIT, AGPL/GPL, Apache-2.0). Max Pane's LICENSE is MIT
      and the README links it; nothing states it on a launch surface yet
      because there is no launch surface.
- [ ] **Social proof on the page.** Conductor "Trusted by 100k+ builders"
      with eight logos and a named testimonial; cmux a live GitHub star count
      in the nav; Warp "trusted by 800k+ devs". Max Pane's README says "Built
      and used daily by one person."
- [ ] **A minimum macOS version stated next to the download.** Ghostty
      "Requires macOS 13+", cmux "macOS 14.0 or later", Warp "10.14+". Max
      Pane's README states macOS 14 or newer, but under Install, not beside a
      button.
