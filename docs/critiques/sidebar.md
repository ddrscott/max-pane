# Sidebar critique: bar-sidebar vs maxpane-sidebar

Blind comparison. I did not build either. Judged from the PNGs at 1:1 and from crops at 3-4x.

---

## 1. Verdict

**`maxpane-sidebar.png` wins — moderately confidently.** It fits the entire ten-session fleet on screen at once, marks which session you are currently looking at, and keeps the distinguishing part of each project path; `bar-sidebar.png` does none of those three and physically slices its tenth row in half.

Confidence is *moderate*, not high, for one reason: **neither image serves need #1 at all.** The verdict is therefore decided by needs 3, 4 and 5 — the cheaper ones. If `bar` shipped a blocked-state indicator tomorrow, the verdict would flip, and nothing else on this list would save maxpane.

---

## 2. The five needs, scored

### Need 1 — "Which agent has stopped and is waiting on me?"  → **Neither. 0 / 0.**

This is the whole point of the screen and both applications fail it.

- `bar-sidebar.png`: ten rows, ten status dots, **every single dot is the same green**. Nine of the ten right-hand chips read `idle` in the same grey. There is no third state anywhere in the frame.
- `maxpane-sidebar.png`: ten rows. Nine green squares plus one hollow square (the `Google` / `WEB` row). Eight chips read `IDLE`, three read throughput (`616B/S`, `1.5KB/S`, `1B/S`). Again no amber, no red, no "waiting" word, no attention glyph.

So in both, an agent parked on `Do you want to proceed? (y/n)` renders as green + idle — identical to an agent that finished cleanly an hour ago.

`bar` is caught doing it on camera. In **`bar-full.png`**, the centre pane (`Latest commit changes`, `/Users/spierce/code/trifecta-…`) contains an amber block reading *"API Error: Your computer went to sleep mid-response. The response above may be incomplete."* That session is broken and needs a human. Its sidebar row, four inches to the left, is a **green dot, an asterisk, `Latest commit chan…`, `idle`, `10h ago`** — pixel-for-pixel identical to `trifecta ask` and `Simplify CLAUDE.md…`, which are fine. The sidebar had the information and threw it away.

I cannot convict maxpane the same way only because no maxpane session happens to be blocked in its frame. That is luck, not merit. Neither scores.

### Need 2 — working / idle / dead  → **Near tie, thin edge to `maxpane`.**

The vocabularies are the same idea: a coloured status mark, plus a right-hand chip that is either a word or a live byte rate.

- `bar`: `Pane terminal s…` shows `1.7KB/s` in green plus a half-filled `◑` glyph; the other nine show `✳` and `idle`. The `◑` is redundant with the throughput number sitting 20px to its right — it encodes nothing the chip doesn't already say.
- `maxpane`: `htop 616B/S` and `Pane terminal… 1.5KB/S` in green, `trifecta monitor 1B/S`, the rest `IDLE`. The `1B/S` row is a genuinely useful distinction `bar` cannot make from its frame: barely-alive is not the same as idle.

Neither shows a dead/exited session. The thin edge goes to maxpane on one piece of evidence only: its status square is demonstrably *capable of varying* — the `Google` row is a hollow outlined square, not a filled green one. Every bar dot in both frames is the same green, so I have zero evidence bar's dot ever changes. Weak evidence, but it is the only evidence there is.

### Need 3 — where each one lives  → **`maxpane`, clearly.**

Two separate wins.

**Contrast.** maxpane's group headers are bold caps in near-white with an orange `//` in front: `// ~/CODE/MAX-PANE`, `// ~/CODE/RELAY-TTY`. They read as a different *class* of object from the rows. bar's headers (`~/code/max-pane`, `~/code/relay-tty`) are small dim grey — and critically, **the same grey as the `idle` chips and the same grey as the `13h ago` timestamps**. Three unrelated meanings rendered in one colour at one weight. Scanning bar's list for a project boundary means reading, not glancing.

**Truncation direction.** bar truncates project paths from the *right*: `~/code/trifecta-artif…` and `~/code/trifecta-disco…`. Every group in the list starts `~/code/`, so bar spends seven characters per header on a prefix that carries no information, then runs out of room exactly where the names diverge. maxpane truncates from the *left*: `…TRIFECTA-ARTIFACTS`, `…TRIFECTA-DISCOVERY` — both full names survive intact. With five or six projects under one root, maxpane's rule is simply correct and bar's is simply wrong.

Row-level titles are a wash: bar's `Github project man…` gets one more character than maxpane's `Github project ma…`, which is not worth anything.

### Need 4 — how long since it did anything  → **`bar`, narrowly. Its only win.**

bar resolves seconds and low minutes: `6s ago`, `2m ago`, `3m ago`, `29m ago`, `10h ago`, `13h ago`. maxpane's shortest bucket is the word `now` — both `~/code/max-pane` rows read `now`, and its next step up is `53m ago`. Minute granularity clearly exists in maxpane (`53m ago`), but nothing in the frame proves it can distinguish "stopped 20 seconds ago" from "stopped 50 seconds ago", and that band is exactly when you want to know whether something just stalled.

Caveat that keeps this narrow: bar's `6s ago` sits on a row that is *also* showing `1.7KB/s`, where the timestamp is redundant. The precision is demonstrated in the one place it does not matter.

Placement, size and colour of the timestamps are equivalent in both — second line, right-aligned, dim grey.

### Need 5 — getting to the one you want, fast  → **`maxpane`, decisively.**

Three things, in descending order of how much they matter.

1. **bar's sidebar does not show you where you are.** `bar-full.png` has three sessions visibly open in panes — `…top and URL` (max-pane), `Latest commit changes` (trifecta), `SSH tunnelling setup` (life) — and the centre pane carries a bright focus border. In the sidebar, the rows for those three sessions are **indistinguishable from the seven that are not on screen**: same card fill, same border, same dot. There is no selection state, no open state, no focus ring, nothing. maxpane marks the focused row unmistakably — `Google` sits on a warm brown fill with a 4px orange rail down its left edge — and differentiates `htop` from the rest with an orange `$` where the other nine rows carry a grey `+`. Whatever the exact semantics, you can see at a glance that two of the ten rows are special and which one has focus. In bar you cannot.
2. **bar cannot show the fleet.** At the bottom of `bar-sidebar.png` the tenth row (`askscottpierce.com`) is **cut horizontally through the middle of its own text** by the `v1.21.0` footer bar — visible in the crop as a green dot and the top halves of the letters. Row pitch is ~70px against maxpane's ~40px, mostly spent on rounded-card insets and 8px inter-card gaps that carry no signal. maxpane renders 6 headers + 10 rows in its top ~62% and leaves the bottom 38% empty. For a developer with ten agents, "one of them is always below the fold" is a structural defect, and bar hit it at exactly ten.
3. **Affordances.** maxpane's footer reads `v0.1.0  1/9 SESSIONS` and `maxpane-window.png` advertises `⌘/ shortcuts` bottom-right. bar's footer is `v1.21.0` and a gear — no count, no shortcut hint anywhere in the sidebar. maxpane's `+ NEW` is an orange outlined button; bar's `+ New` is dim grey text at the same value as the disabled-looking sort controls. Toolbars are otherwise identical in function (new / collapse / filter / sort-by-Created).

---

## 3. THE SINGLE BIGGEST GAP — `bar-sidebar.png`

**There is no "this one is waiting on you" state. The status dot has exactly one value, green, and the chip has exactly one non-numeric value, `idle` — so blocked-on-a-prompt, crashed, and finished-successfully are the same pixels.**

The receipt is in `bar-full.png`: the `Latest commit changes` session is sitting on *"API Error: Your computer went to sleep mid-response"* and its sidebar row says green + `idle` + `10h ago`, identical to `trifecta ask` which is merely done. That row is the single most valuable pixel on the screen and it is lying.

Concretely actionable tomorrow:

- Add a **third status value** distinct in *hue and shape*, not just hue — an amber/red filled triangle or a ring, so it survives a green/red colour deficiency — driven by "the pane's last output ends in a pending prompt, or the process is blocked on stdin, or the last event was an error."
- Replace the chip text on those rows with a word, not a symbol: `NEEDS YOU` beats any glyph at 1-second glance.
- **Sort or pin blocked rows to the top of the list**, above the group headers if necessary. With ten sessions and one below the fold, a state you have to scroll to find is a state you do not have.
- Fix the group-header count to say what it means — `1 waiting` is worth reading; `1 running` above a row marked `idle` is not (see below).

Do that and bar wins need #1 outright, because maxpane doesn't have it either, and the verdict flips.

---

## 4. Three smaller things, ranked

1. **Both apps' group-header counts contradict their own rows.** bar: `~/code/relay-tty   1 running` sits directly above `Github project man…  idle`. maxpane: `// ~/CODE/RELAY-TTY  1 RUNNING` above `Github project ma…  IDLE`. Across bar's whole list the headers claim 13 "running" while nine of ten rows say `idle`. "Running" is being used to mean "exists" and "idle" to mean "not producing output", and the two words sit 15 pixels apart. Pick one meaning for "running" or drop the header count.
2. **maxpane's orange is carrying four jobs at once** — the `//` in every header, the `$` on `htop`, the focus rail on `Google`, and the `+ NEW` button. Three of those are status signals and one is a control. A fifth meaning and the colour stops meaning anything; the focus rail in particular should not have to compete with decorative `//` marks three rows above it.
3. **`1/9 SESSIONS` in maxpane's footer is ambiguous while ten rows are on screen.** Is that "1 of 9 selected", "session 1 of 9", "1 running of 9"? And the tenth row (`Google`) is apparently not counted. bar's footer at least doesn't mislead — it says nothing at all, which is its own smaller problem.

---

## 5. What I could not judge from a static screenshot

- **Whether anything moves.** A pulsing dot, a spinner, or a flashing row would change need #1 entirely, and bar's `◑` glyph may well be a rotating spinner frame — I have one frame and cannot tell.
- **Whether a blocked session triggers anything outside the sidebar** — a dock badge, a sound, a notification, a row that jumps to the top. Either app could already solve need #1 off-screen.
- **Live updating**: whether throughput and `6s ago` / `now` tick continuously or update on an interval, and how quickly a state change lands.
- **Keyboard navigation**: maxpane advertises `⌘/ shortcuts` but I cannot see what they do; bar advertises nothing but may still have them. Need #5 could be decided entirely by a fuzzy-jump palette that neither screenshot shows.
- **Scroll behaviour past ten sessions** — sticky group headers, whether the list auto-scrolls to the active session, whether bar's clipped tenth row is a one-off or the steady state.
- **Hover and click targets**, collapse/expand of groups, what the filter and sort controls actually offer.
- **Behaviour at other widths**, and whether either truncation rule adapts when the sidebar is dragged wider.
- **Whether either has a non-colour mode.** Both encode "alive" purely as green; I can see that, but I cannot see whether a setting exists to fix it.
