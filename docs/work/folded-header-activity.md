# A folded sidebar header carries the activity of what it hides

The owner (2026-09-22): *"When a session folder is collapsed the activity
beneath it should still be indicated on the folder instead of being hidden so
that I can see when a session needs my attention."*

## What a folded header shows today (read from `SidebarModel.Group.countText`)

- Hiding lanes: `N LANES HIDDEN` in grey, plus `N BLOCKED` beside it in the
  blocked green, pulsing (`blockedText`). Nothing for WORKING or DONE.
- Collapsed but not hiding (setting off): `N BLOCKED`, else `N RUNNING`, else
  `N CLOSED`. RUNNING is not activity; DONE is absent.
- The header's own leading mark stays grey whatever is underneath.

So a session that finishes its turn (DONE, Signal Orange, the one state the
owner set aside a colour for) or that is working under a folded group is
invisible until unfolded. BLOCKED is the only state that survives a fold.

## Acceptance Criteria

- **The folded header rolls up every state of the rows it hides, in the
  sidebar's own vocabulary**, so the fold changes nothing about what you can
  see at a glance, only how much room it takes:
  - **BLOCKED** first, as today: `N BLOCKED`, blocked green, pulsing.
  - **DONE** next: `N DONE` in Signal Orange (ADR-0015; `Theme.done`), not
    pulsing, with the same look as a row's DONE chip reduced to the header's
    text size. It clears when the session is acknowledged the way a row's does
    (focus its pane, or `doneHoldSeconds` lapses), so a folded DONE does not
    stay orange forever.
  - **WORKING**: the header's leading mark takes the working green (the filled
    square a row uses), and the count reads `N WORKING`, so a folded group with
    an agent running looks alive without shouting.
  - Idle under it: as today, grey, `N LANES HIDDEN` / `N RUNNING`.
- **Priority when mixed**: the count text says the loudest thing (BLOCKED >
  DONE > WORKING > hidden count), and the quieter ones follow as chips or
  the lane-count in grey, in the header's existing right-hand slot, e.g.
  `1 BLOCKED · 2 DONE · 3 LANES HIDDEN` fitting the width the header has and
  dropping the grey tail first when it does not. Do not invent a new row.
- **Applies to every folded thing**: a project group, a `// NAME` server
  section, `// LOCAL`, whether or not the fold hides lanes
  (`sidebar_collapse_hides_lanes` off still folds the rows).
- **The header's leading mark** takes the brightest state's colour under it:
  blocked (pulsing, as a row's does), else done orange, else working green,
  else grey. One mark, one colour, the row rule applied to the roll-up.
- **Clicking a state on a folded header goes to it**: a click on `N BLOCKED`
  or `N DONE` on the header attaches/reveals the first such session under it
  (unfolding, per ADR-0024's reach-through); a click elsewhere on the header
  still folds/unfolds.
- **Sound** (ADR-0035) is already rolled up onto folded headers; keep it, and
  keep its speaker left of the state text.
- Motion: a state appearing or clearing on a header fades (`Motion.fade`);
  the pulse is the existing `PulseLabel`.
- Tests in `SidebarModel` for the roll-up text and priority, mixed groups,
  sections, a DONE acknowledged clearing, the click targets; a render sheet
  of a folded header in each state, light and dark, looked at.
- README's sidebar section (one paragraph), CHANGELOG (Changed: a folded
  group now shows what is under it), and an amendment line in ADR-0024.

## Constraints

- No new colour; the row's palette exactly (ADR-0015).
- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
