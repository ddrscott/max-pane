# Gauntlet — ready for Product Hunt

**Goal (Scott, verbatim):** "let's get this project ready for a producthunt"

**What that means.** A stranger lands on the Product Hunt listing, understands
in five seconds what Max Pane is and who it is for, clicks through to a page
that makes them want it, and has it running on their Mac in under three
minutes without reading a build guide. Everything they meet on that path is
the artifact of this run.

**Stop condition:** Scott stops the run. Not a round count.

## The bar

Best-in-category launches of native developer tools, captured as pixels by a
scout with fresh context: see [`reference/launch-bar.md`](reference/launch-bar.md)
and the screenshots under the run's scratchpad `bar/`. Critics judge blind
against those pages, not against a description of them.

The scout's pick: **Conductor** is the closest analog (same job, same buyer,
one-screenshot hero, six-paragraph maker story); **cmux** sets the install bar
(native Swift, built-in browser, one-click DMG and cask, no account); **Ghostty**
sets the landing bar (nothing but the product and a Download button). Taglines
across the bar run 33-58 characters; maker comments 170-370 words, in the order
story → problem → "so we built X" → proof → free / uses your login → ask.

## Weights — the owner's trade-off

Scott has not stated launch weights, so these are the lead's, written before
any round ran, for the critics to score by:

1. **Install must work for a stranger.** A signed, notarised download that opens
   without a Gatekeeper warning outranks every pixel of copy. RelayTTY is a
   dependency; the install path has to carry it.
2. **Truth over hype.** Every claim on every surface must be a thing the app
   does today (see `CHANGELOG.md` 0.5.0). Nothing "coming soon".
3. **The app's own identity, not a template.** Greens, JetBrains Mono, square
   corners, dark by default. No gradient hero, no bubble cards, no blue.
4. **Scott's voice.** Dry, specific, first person where a maker speaks. The
   README already has it; the launch copy should sound like the same person.

## Facts the run starts from

- Repo `ddrscott/max-pane` is public: no LICENSE file (Cargo.toml says MIT), no
  description, no homepage, no topics, no release, no tag. README is a
  1,515-line developer manual with no screenshot.
- `relay-tty` is public with `curl … install.sh | bash` and `npm i -g`.
- No Homebrew tap exists under `ddrscott`; the cask is written at `packaging/Casks/max-pane.rb` and waits for `ddrscott/homebrew-tap`.
- A Developer ID Application identity exists on this Mac. **No notarytool
  keychain profile exists**, so notarisation is a step Scott has to unlock:
  `xcrun notarytool store-credentials maxpane-notary`.
- 0.5.0 is cut in `CHANGELOG.md`, Info.plist and Cargo.toml, uncommitted.
- Launching the app from a Claude session is safe as of today: the spawner and
  `build-app.sh run` both scrub the Claude session markers. Screenshots are
  taken from a throwaway bundle on a throwaway profile, never the default.

## The split

Each piece has its own builder and a fresh-context critic. The lead picked
these because each can be improved and judged on its own artifact:

| # | Piece | Artifact the critic inspects | Depends on |
|---|-------|------------------------------|------------|
| 1 | Repo front door | `README.md` rendered on GitHub; `gh repo view`; `LICENSE` | screenshots (for the hero) |
| 2 | Distribution | a DMG that opens clean on a Mac; `gh release view v0.6.0`; a brew cask | notarisation credential (Scott) |
| 3 | Screenshots and demo | PNGs under `docs/launch/` at Retina size; a GIF if it earns its place | a built app |
| 4 | Landing page | the page rendered in a browser at desktop and phone width | bar, screenshots |
| 5 | Product Hunt listing | `docs/launch/producthunt.md`: name, tagline, description, topics, gallery order, first comment | bar, screenshots |
| S | Smoothing | the whole path, landing → install → first launch, walked by one fresh agent | 1–5 |

## Rounds

Each round: builder ships, critic compares blind against the bar and names the
single biggest gap, builder fixes, repeat. Rows are appended as they happen.

| Round | Piece | Critic's verdict | Biggest gap named | Status |
|-------|-------|------------------|-------------------|--------|
| 0 | bar | landed: Conductor (closest analog), cmux (install bar), Ghostty (landing bar); 18 screenshots in scratchpad `bar/` | — | done |
| 1 | 1 repo front door | **Max Pane wins** (README beats Ghostty/Zed first screens; repo header loses) | repo description was consultant-speak; use the README lede | fixed by lead; awaiting hero.png |
| 1 | 2 distribution | **Reference wins** (spctl: `rejected, source=Unnotarized Developer ID`) | app is signed without hardened runtime or secure timestamp, so Apple's notary would reject it | make-dmg.sh, release.sh, cask built and verified |
| 2 | 2 distribution | functional proof: hardened runtime + secure timestamp on all three binaries, two entitlements (camera, mic); throwaway launch under the new signing ran htop and fetched a GitHub page title, no sandbox/entitlement log lines; `make-dmg.sh` preflight passes | the DMG is notarisable but not notarised: waits on Scott's `maxpane-notary` credential | visual pass on the hardened bundle owed once the screen unlocks |
| 3 | 2 distribution | **Reference wins** (cmux: one DMG, no dependency, universal) | release.sh jams itself after a dry run (rewrites the tracked cask); arm64-only with no `depends_on arch` and no mention anywhere; the app's missing-relay-tty error points at a config key, not the installer | fixed: release.sh never touches tracked files (cask written to `dist/`, diff printed, copy steps printed after publish); cask gets `depends_on arch: :arm64` and a placeholder sha; timestamp probe prints codesign's stderr; team id derived from the identity; the missing-relay-tty error now leads with the installer. `./scripts/test.sh` green, 825 Swift tests. Lead added "Apple silicon" to README, landing and listing. Note: the installed app predates the error-message change; rebuild at release |
| 1 | 3 screenshots | **Conductor wins the hero; reference wins the set** (UI all real, no impossible state) | at 600 px the BLOCKED lane is the narrowest column and its prompt is illegible; `$ launch-shots` in every footer; five shots are the same full window; owner's GitHub handle in three; stand-in token counter dressed as Claude Code's | seven Retina PNGs under `docs/launch/` (hero, sidebar, web-pane, gallery, omni, docked-lane, settings-toml) plus `shots.md`; four copied to `site/img/`. Agent lanes are stand-ins whose BLOCKED/working states relay-tty classified for real. Throwaway bundle, profile, defaults and 24 stand-in sessions cleaned up |
| 2 | 3 screenshots | **Max Pane wins the hero at 600 px; reference wins the set** (every UI element real, nothing from Unreleased) | `docked-lane.png` carries the render bug at the seam and a Twilio ad; `settings-toml.png` is cropped mid-lane; the stand-in "claude" lanes imitate Claude Code's transcript format, which the listing's context makes a viewer read as real Claude Code | recaptured: BLOCKED lane focused and centred at `m`, prompt legible at 600 px (lead checked); profile `main`; no counters; MDN and docs.rs pages instead of GitHub; gallery 4×2; docked-lane and settings-toml are crops. `docs/launch/bug-docked-sliver.png` + steps in shots.md: a possible render bug for Scott |
| S | smoothing | walked listing → landing → README → DMG → first launch | portrait shots were cropped to nothing by a forced 16:10 frame; download buttons pointed at an empty `releases/latest`; README Requirements gave a different install command than Install; two gallery filenames did not exist; `dist/` DMG predated the spawner fix | all fixed; release.sh now rebuilds before packaging. Lead dropped `docked-lane.png` and `settings-toml.png` from the set and rebuilt bundle + DMG from the current tree |
| 1 | 4 landing page | **cmux wins above the fold; Max Pane wins the whole page** (identity, install honesty, phone render pass) | h1 is the product name and the lede a mechanism; the job is the third thing read. Config excerpt shows an undocumented `[terminal]` table | built: `site/index.html`, no JS, JetBrains Mono, dark/light, verified 1440 and 400 px headless; expects `site/img/{hero,web-pane,sidebar,gallery}.png`; |
| 2 | 4 landing page | **Max Pane wins both** (fold beats cmux and Ghostty; whole page beats cmux; all claims traceable) | the fold cuts the hero at 40%, so the BLOCKED row it exists to show is below the crease | lead trimmed the lede's second sentence and the hero padding; hero composition passed to the screenshot builder | h1 is now "Run several Claude Codes and know which one needs you.", lede leads with the fix; relay-tty moved out of the hero line; config excerpt matches README |
| 1 | 5 PH listing | **Reference wins ×3** (Conductor on card, cmux on comment, Conductor on gallery/topics) | card uses the app's vocabulary before naming Claude Code and the job; comment never says how to get it; seven first-person history claims nothing backs | built: `docs/launch/producthunt.md`, tagline 54 ch, description 233 ch, maker comment 349 words, gallery plan of six shots, launch-day checklist |
| 3 | 5 PH listing | **Max Pane wins the card; Conductor wins the comment** | the comment claimed ⌘O falls back to DuckDuckGo, which is false (that is the CLI shim; ⌘O runs a command line); four first-person history sentences nothing backs; no proof line | lead fixed the false claim and the description's "cites" stumble; marked the history sentences and a proof-line slot for Scott to sign |
| 2 | 5 PH listing | **Max Pane wins 2 of 3** (comment, gallery/topics); Conductor still wins the card | tagline "the page it cites" fails the five-second read; one first-person sentence nobody said | lead applied: tagline is now "Run several Claude Codes and know which one needs you" (53 ch), sentence cut | rewritten: tagline "See which Claude Code needs you, beside the page it cites" (57 ch), description 256 ch, comment 299 words ending on the download line; topics now Productivity · Developer Tools · AI |

## Waiting on Scott

Things the run cannot do or should not decide:

1. ~~Notarisation credential~~ Done 2026-09-16: `dist/MaxPane-0.6.0.dmg` is notarised and stapled, `spctl` says `accepted, source=Notarized Developer ID`. Was: `xcrun notarytool store-credentials maxpane-notary --apple-id <email> --team-id DH6NDWAQQ2 --password <app-specific password>`, then `./scripts/make-dmg.sh`.
2. ~~Create `ddrscott/homebrew-tap`~~ Done 2026-09-16: the tap is public with `Formula/relay-tty.rb` (npm tarball + the release's pre-built pty-host as a resource; installed and audited clean here) and `Casks/max-pane.rb`, which depends on that formula. The cask resolves once the v0.6.0 release exists; `release.sh` writes the shipping hash to `dist/max-pane.rb` for the tap.
3. Sign the maker comment in `docs/launch/producthunt.md`: two origin-story sentences are marked, and a proof line is left as a slot.
4. Pick where `site/` is hosted and set the repo homepage to it.
5. ~~Commit, tag `v0.6.0`, and release~~ Done 2026-09-16: https://github.com/ddrscott/max-pane/releases/tag/v0.6.0 carries the notarised DMG; `brew install --cask ddrscott/tap/max-pane` installs it with relay-tty, verified end to end here.
6. ~~Decide whether 0.5.0 includes the Unreleased work.~~ Resolved 2026-09-16: 0.6.0 was cut with the DONE state, the Dock bounce, the orange mark, Mobile Layout and the carousel click fix. Every launch surface now says 0.6.0.
7. **Decide on the agent lanes in the screenshots.** They are stand-in programs printing a Claude-Code-shaped transcript; relay-tty classified their BLOCKED/working states for real, but the transcripts are not Claude Code and the throughput numbers measure a script. Options: (a) ship as is with a one-line disclosure in the maker comment, or (b) recapture with real `claude` sessions on your Max plan, which costs tokens and a longer burst. The lead recommends (b) for the hero only, under the truth weight.
8. Decide on a universal build. The app is arm64-only today; cmux ships universal. That is a Rust x86_64 target plus a fat Swift binary, which the run has not attempted.

Done by the run without a critic: `docs/launch/thumbnail-240.png`, the Product Hunt thumbnail from the app icon.

## How to stop

Say stop. In-flight builders finish their current edit; nothing is committed
or published by this run without Scott: the release, the tag, the tap push and
the Product Hunt submission itself are all his to press.
