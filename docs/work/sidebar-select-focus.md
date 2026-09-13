# Selecting from the session sidebar reveals a lane without focusing it

## Problem

> "browser panes should also be highlighted when they are the active pane."
>
> "They appear if I select the pane with mouse on the pane itself, but doesn't
> appear when using the session sidebar."

The second sentence is the actual bug, and it is **not browser-specific** — it
just shows up there first, because a terminal at least blinks a cursor while a
page looks identical whether or not it has the keyboard.

`StripWindowController` wires the sidebar like this:

```swift
sidebar.onSelect = { [weak self] laneId in self?.strip.reveal(laneId: laneId, flash: true) }
```

`reveal` scrolls the lane into view and flashes its border for a moment. It does
not touch focus. So picking a session from the sidebar puts you in front of a
lane that does not have the keyboard, is not outlined, and will not receive what
you type — while the lane you were in before is still the focused one, now
somewhere off screen.

The right shape already exists two hundred lines away, in `revealNextAsking`:

```swift
reveal(laneId: laneId, flash: true)
try? store.focusPane(paneId)
```

## Why the flash makes it worse

`flash: true` briefly lights the lane's border in the same Signal Orange the
focus ring uses. So selecting from the sidebar looks like it focused the lane
for about a third of a second and then silently gives up. That is a worse
failure than doing nothing visible, because the first press of a key is what
tells you it did not work.

## Acceptance criteria

- Selecting a session in the sidebar focuses that lane's pane: the border stays
  lit, and typing goes there without a further click.
- True for a web pane and a terminal pane alike.
- For a lane with several stacked panes, the choice of which pane gets focus is
  defined and defensible — the lane's first pane, or the one whose session the
  sidebar row actually names, which is the better answer where a row maps to a
  specific pty session.
- The lane still scrolls into view as it does now, and the reveal and the focus
  read as one action rather than two.
- Focus survives the strip recycling the lane view — see
  `TerminalPaneController.applyPendingFocus`, which had to re-assert focus on
  window attach because reparenting a view hands first-responder back to the
  window, and `WebPaneController`, which was given the same treatment later.
- A sidebar row for a session that is **not on the strip** must keep doing what
  it does today (attach it) rather than trying to focus a lane that does not
  exist.

## Worth deciding while in here

Focus is currently shown only as a 2pt border around the whole **lane**, and
nothing marks which pane inside a stacked lane is active — for terminals either.
Now that ⇧⌘D renders its split and lanes routinely hold several panes, "which of
these three has the keyboard" is a real question with no answer on screen. That
is arguably a separate task, but the reporter reached for it here, so decide
deliberately rather than by omission: either add a per-pane marker in the house
vocabulary (`Views/Theme.swift` — Signal Orange is reserved for focus and
attention, which this is), or write down why the lane border is enough.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/StripWindowController.swift` — `sidebar.onSelect`
- `swift/MaxPane/Sources/MaxPaneKit/Views/StripViewController.swift` — `reveal`,
  `revealNextAsking` (the shape to copy), `focus(_:)`
- `swift/MaxPane/Sources/MaxPaneKit/Views/SidebarViewController.swift` — what a
  row knows about the pane it names
- `swift/MaxPane/Sources/MaxPaneKit/Views/LaneView.swift` — `isFocused`, `flash()`

## Constraints

- Do not make `reveal` focus on its own. It is called from several places that
  deliberately move the viewport without stealing the keyboard — the snap and
  peek work, and `ensureVisible` for arrow-key focus, both depend on that
  separation.
- Focus is a ledger write (`store.focusPane`), and the strip's own diff is what
  gives the pane first-responder afterwards. Do not call `takeFocus()` directly
  from the sidebar and bypass the ledger; that is how the two disagree.
