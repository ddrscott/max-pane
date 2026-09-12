# Pane header critique — `bar-headers.png` vs `maxpane-headers.png`

Blind comparison. Judged from pixels: crops at 3–5x, plus hex sampling of every accent
colour in both header strips. Task assumed throughout: three terminal columns, three AI
coding agents, three projects, watched all day from the header bars alone.

---

## 1. Verdict

**`maxpane-headers.png` wins, moderately confidently** — it loses the title race badly but
wins the two needs that break down structurally under three columns of the same repo
(*which directory*) and under all-day watching (*is it alive*), and it wins them by design
decisions rather than by luck of what was in the screenshot.

Confidence is *moderate*, not high, for two honest reasons: `maxpane-headers.png` shows
only two panes and neither is an AI agent (it is `htop` and a Google page), while
`bar-headers.png` shows three real agent columns; and one of maxpane's two headers — the
focused Google one — is roughly 700px of empty bar with nothing in it at all.

Neither image serves the single most valuable need on the list. See §3.

---

## 2. The six needs

### Need 1 — Which column has stopped and needs me? **Both fail. Tie at zero.**

There is no "waiting for input" state anywhere in either header, and no such state in
either app's vocabulary.

The damning evidence is in `bar-full.png`, because bar actually *captured* a stalled
column and did nothing with it. Column 2's content pane reads, in amber, `API Error: Your
computer went to sleep mid-response. The response above may be incomplete.` followed by a
highlighted `> continue` input box — a column parked and burning wall-clock. Its header dot
is `#22C55D`. Pixel-identical to column 3's dot, which is running fine. The header did not
change one pixel for the one event that matters most.

maxpane cannot be convicted the same way — no stalled pane was captured — but it earns no
credit either. Its full state vocabulary, read off `maxpane-sidebar.png`, is `IDLE`,
a throughput figure, and `WEB`. Lane headers count `2 RUNNING`. Nothing counts *blocked*.
"Idle" is not "needs you"; an agent that finished cleanly and an agent frozen on `(y/n)`
both render `IDLE`.

The only structural edge, and it is thin: maxpane's terminal header already owns a
right-hand meta slot that renders live state text (`616B/s`). That is where a `NEEDS YOU`
chip goes. bar's right-hand slot is spent on a path, so bar has nowhere to put one without
a redesign.

### Need 2 — What is it, what is it doing? **bar wins, clearly.**

bar's column 3 header reads `✻ SSH tunnelling setup for 192.168.68.10` — 38 characters of
task description, complete, no ellipsis. Column 2: `✻ Latest commit changes`. These are
rolling summaries of what the agent is *doing*, which is the actual question.

maxpane's headers read `$ htop` and `Google`. Four characters and six. Correct for what
those panes are, but they name a process, not a task. maxpane does carry agent-style titles
(its sidebar shows `Latest commit cha…`, `askscottpierce.co…`) — tail-truncated at ~17
characters. Unknown whether the pane header is tighter or looser; not captured.

One deduction from bar: the `✻` glyph appears on every Claude session in both its header and
its sidebar. Three agent columns means three identical `✻`. Two character-widths spent, zero
bits returned.

### Need 3 — Which project/directory? **maxpane wins, decisively. This is the big one.**

bar prints the absolute path, right-aligned, tail-truncated:

```
/Users/spierce/code/max-pane          (column 1, fits)
/Users/spierce/code/trifecta-…        (column 2, does not)
```

Measured off `bar-full.png`: the path slot in a 627px column is ~230px, about 31
monospace characters. `/Users/spierce/code/` is 20 of those 31 — 65% of the budget spent on
a string that is byte-identical on every column on the screen. The ellipsis then lands
precisely where the repo names begin to diverge. The sidebar confirms the two repos in play
are `trifecta-artifacts` and `trifecta-discovery`. Open both as columns and their headers
render *the same 30 characters*. The one field whose job is to tell two columns apart
truncates away the only part that does.

maxpane prints `~/code/max-pane`. The tilde costs 1 character instead of 15 for the
invariant prefix; `~/code/` is 7 invariant characters, not 20. In the same 31-character
budget it would render `~/code/trifecta-discovery` (25 chars) whole. And maxpane's lane
headers in `maxpane-sidebar.png` head-truncate — `…TRIFECTA-ARTIFACTS`,
`…TRIFECTA-DISCOVERY` — keeping the discriminating tail and dropping the shared prefix,
which is the correct direction and legible at a glance.

Against maxpane: its focused Google header carries no path and no meta at all — green
square, globe, `Google`, then ~700px of nothing, then `···`. Whatever the reason, one of
the two headers on offer answers Need 3 with a blank.

Neither app shows branch or worktree, so neither actually solves "several columns are the
same repository" — only "several columns are different repositories".

### Need 4 — Is it alive? **maxpane wins.**

maxpane's header shows `616B/s`. That is a number produced by the process being alive; it
is evidence, not an assertion. bar's header shows a 6px `#22C55D` dot and nothing else —
an assertion, and one that survived a stalled column unchanged (Need 1). bar has the
throughput data — its sidebar renders `1.7KB/s` — and chose not to put it in the header.

Both lift the focused header's background, which is a second passive cue:
bar `#0A0A10` → `#1A1A2E`, maxpane `#1C1C1C` → `#303030`.

### Need 5 — Which column has focus? **maxpane wins on legibility; both have a colour collision.**

- maxpane: 4 device px (2 logical) full-perimeter `#D86628` ring, plus the background lift.
  Reads across a room.
- bar: 1 device px `#22C55D` ring, inset 4px from the top edge, plus the background lift.
  Verified at x=407 and x=1041, y=20.

Both are full-perimeter, so neither commits the bent-rail tell. But:

**bar's collision is hex-exact.** The focus ring at x=407 is `#22C55D`. The running-status
dot at x=417–420, ten pixels away in the same header, is `#22C55D`. Identical value, two
meanings, adjacent on screen.

**maxpane's collision is worse in count and worse in kind.** `#D76628` is the focus border,
the `$` prompt glyph, *and* the `616B/s` throughput figure — three meanings inside one
20px-tall strip. Worse than the count: orange is the colour a header like this must reserve
for Need 1, and maxpane has already spent it on a routine state. An orange alarm chip
dropped into an orange-bordered header containing orange text would not read as an alarm.
bar's double-booking is at least two flavours of "everything is fine" and leaves amber free.

### Need 6 — Per-column actions. **Effectively a tie, marginal maxpane.**

Both offer exactly one affordance: a `···` overflow at the far right. Neither surfaces
close, pin or rename inline, so every action is a menu round-trip. maxpane's glyph is three
solid squares at `#999999`; bar's is three thin dots at roughly `#A4A8B4` on `#1A1A2E`, and
at 1x it nearly disappears into the path text beside it. Slight edge maxpane on findability.

---

## 3. THE SINGLE BIGGEST GAP (in `bar-headers.png`)

**The header has no third state. A blocked agent and a working agent render the same
`#22C55D` dot, and bar proved it by shipping a screenshot where that is literally true.**

Column 2 of `bar-full.png` is stopped — amber API error, a `> continue` box waiting for a
keystroke — and its header is indistinguishable from column 3, which is running. The most
valuable signal on the screen is encoded as: nothing.

Concrete, actionable tomorrow: bar's header right-hand slot currently holds
`/Users/spierce/code/trifecta-…`, of which 20 characters are identical on every column
(§Need 3). That is the lowest-value real estate in the header and it sits in the highest-
value position. Take it. When a session is awaiting input, replace the path with an amber
or red chip carrying a word and a clock — `● NEEDS YOU · 4m` — and let the path fall back
to the tooltip. Amber is unused in bar's chrome, so it is free; the elapsed counter is what
converts "one of three needs me" into "the one that has been stuck longest needs me first".
Keep the `#22C55D` dot for running and leave the focus ring alone; the chip carries the
signal, not the colour of the border.

Fix this and bar owns the #1-ranked need outright while maxpane still has nothing for it,
and the verdict flips.

---

## 4. Three smaller things, ranked

1. **bar truncates the wrong end of the path.** `/Users/spierce/code/trifecta-…` spends 65%
   of its character budget on a shared prefix and then ellipsizes exactly at the point of
   divergence; two trifecta columns render identically. Switch to `~` abbreviation plus
   head truncation — `…trifecta-discovery` — which is what maxpane's own lane headers
   already do.
2. **maxpane triple-books `#D76628`.** Focus border, `$` glyph and throughput number are the
   same hex within a 20px strip. Reserve orange for "needs you". Focus is already carried
   by the `#1C1C1C` → `#303030` background lift; make the ring neutral (a 2px white-at-60%
   outline) and orange is freed for the one signal that deserves it.
3. **maxpane renders the same datum in two colours.** `616B/S` is green `#5EC269` in the
   sidebar and orange `#D76628` in the pane header. One number, one app, two encodings —
   which teaches the eye that the colour means nothing.

---

## 5. What I could not judge from a static screenshot

- **Motion.** Whether bar's dot pulses, and whether maxpane's byte counter actually ticks.
  I credited maxpane's `616B/s` as a liveness *proof* on the assumption it changes. If it is
  a stale number, that credit is wrong and Need 4 is closer to a tie.
- **maxpane's header truncation direction under overflow.** `~/code/max-pane` fit; I never
  saw the pane header overflow. Its lane headers head-truncate correctly, but the pane
  header may not share that code path. bar's overflow behaviour I saw directly and it is bad.
- **Whether either app has a blocked state that simply was not captured.**
  `maxpane-headers.png` contains no agent pane at all — `htop` and a browser — so its
  agent-column behaviour was inferred from its sidebar vocabulary, which is weaker evidence
  than what I had against bar. bar showed three real agent columns; maxpane showed two
  non-agent panes. That asymmetry works in bar's favour and is the main reason confidence
  is moderate rather than high.
- **Hit targets and interaction.** Whether `···` is 16px or 28px of clickable area, whether
  either header double-clicks to rename, whether either is drag-reorderable, and whether
  either has a keyboard path to the menu. All of Need 6 is guesswork beyond "there is one
  button".
- **Colour-vision safety.** I can report `#22C55D` and `#D76628`, but not whether either
  separates from a future red or amber under deuteranopia — which is the decisive question
  the moment "blocked" gets encoded by hue.
- **Behaviour at other widths and column counts.** Both were captured at exactly one layout.
  bar's path truncation gets worse as columns narrow; maxpane's `~/` abbreviation degrades
  more gracefully, but I am reasoning about that, not seeing it.
