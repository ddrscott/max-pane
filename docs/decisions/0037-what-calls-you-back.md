# ADR 0037 — What calls you back: the agent notification, ⌘J and the ATTENTION list

**Status:** Accepted · 2026-09-23
**Decides:** what "away" means for an agent's notification; what the banner
says and when it is taken down; the order ⌘J walks; what the ATTENTION list
holds and what ⌫ may do to it; what the Dock badge counts.
**Evidence:** the Omarchy critique [`docs/critiques/omarchy.md`](../critiques/omarchy.md) § F1;
the work item [`docs/work/omarchy-f1-attention.md`](../work/omarchy-f1-attention.md);
`Terminal/Attention.swift`, `Views/AttentionPopup.swift`, `Web/WebNotifications.swift`;
`AttentionTests.swift`.

## The problem

The moment the owner was in another app, the one thing the product exists
for — an agent stopped — reached him as a single Dock bounce he could miss.
Web pages could post to Notification Center (ADR-0034's neighbour, the
Notification API); the app's own agents could not. There was no "next thing
that needs me" key, only a click on `N BLOCKED` in the status bar.

## Decisions

**Away is `NSApp.isActive == false`, and nothing else.** The detail file
asked whether a lane folded away (ADR-0024) or scrolled off the strip also
counts. It does not: such a lane is in a window that is in front, where the
sidebar chip, the status bar's count and the Dock badge are all on screen,
and a banner over them would be a fourth voice for one fact. `agent_notify`
is `away` (the default), `always` — frontmost too, for every pane but the one
with the keyboard, which is the one being looked at — or `never`. Read at
each transition, so the setting applies live.

**The banner fires on the transition into BLOCKED or DONE**, from
`SessionRegistry.onStateChange`, which is not called for a session's first
reading — so a relaunch under ten waiting agents posts nothing — and which
reports a session on a server that has stopped answering as `.unknown`
(ADR-0023), so a dead server posts nothing. A server coming back with an
agent that finished during the outage *does* post: nobody could have known.
Title: the session's title, or its command. Subtitle: `BLOCKED · ~/code/x`
(a remote session's path as the server gave it, prefixed with the server).
Body: the last non-empty row on the pane's screen — a prompt's question, a
finish's last line — or `Waiting on you` / `Finished` for a pane with no
screen to read. One identifier per session, so a DONE after a BLOCKED
replaces the banner rather than stacking, and **the banner is taken down the
moment the session moves on** — answered, looked at, working again — so
Notification Center never says what the sidebar has stopped saying. The Dock
bounce stays as it was. macOS is asked for permission at the first post,
never at launch, through the same once-per-process gate a site's first grant
uses. A click activates the app and goes to the session the way the sidebar
does: fold opened, gather left, a lane attached if it had none.

**⌘J walks one ring: every BLOCKED session with a lane, in strip order, then
every DONE, in strip order.** Strip order is the ledger's, folded and docked
lanes included, because "the next one along" is a question about the strip,
not about time. From a lane in the ring, ⌘J is the one after it and ⇧⌘J the
one before, wrapping at both ends; from a lane outside it, ⌘J is the first
BLOCKED to the right (wrapping), else the first DONE the same way, and ⇧⌘J
the mirror. The only attention being the focused lane itself is the answer:
⌘J then goes nowhere, which is the truth. Sessions with no lane are not in
the ring — ⌘J moves focus between lanes, as ⌘[ and ⌘] do — but they are in
the list.

**The ATTENTION list (⌥⌘J) is a square mono popover hung from the status
bar's count**, centred when the count is empty. One row per BLOCKED or DONE
session, lane or not: BLOCKED first, then DONE; within each, lanes in strip
order, then lane-less sessions newest first. Rows are grey; the BLOCKED chip
is the sidebar's filled, breathing one; DONE is the only orange. ↑ ↓ move,
↩ goes (attaching a lane-less session), ⌫ dismisses the selected DONE, ⌘⌫
every DONE. **⌫ never touches a BLOCKED**: a DONE is dismissed by looking at
it, and the list is looking; a BLOCKED is a question, and stays until it is
answered. The list follows the registry while open, so a prompt answered
from a phone leaves it as it leaves the sidebar; emptied, it says
`Nothing needs you.` rather than closing under the pointer.

**The Dock badge is the BLOCKED count, and nothing at zero.** DONE is news,
not a request, and a badge that never reaches zero is one nobody reads.
Offline sessions are `.unknown` and do not count.

## Consequences

- Three new commands under Navigate, rebindable under `[keys]`: ⌘J, ⇧⌘J,
  ⌥⌘J. ⌘J was nobody's — macOS leaves it to apps, no browser chrome binds
  it, nothing here did.
- `NotificationPosting.post` gained a `subtitle`; a page's is empty.
- `WebNotificationCenter` routes clicks it does not own by identifier
  prefix. There is one `UNUserNotificationCenter` delegate per process, and
  it was already this one.
- The status bar's `N BLOCKED` click is unchanged: it still goes to the next
  blocked agent (ADR-0024). The popover is one key further.
