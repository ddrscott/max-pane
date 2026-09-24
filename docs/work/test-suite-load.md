# The full test run fails 15–22 tests under its own load, and every one passes alone

## Problem

Cutting 0.8.0 needed three runs to tell a regression from noise. `./scripts/test.sh`
reported **22 issues**, then **15**, from the same tree; every failing suite
passed in isolation (143 tests, two runs, green). The suites are always the
same families:

`RemoteSpawnTests`, `RemotePresenceTests`, `RemoteRelayTests`,
`RelayServerBookTests`, `PasteImageTests`, `CapturePaneTests`,
`WebPrintTests`, `WebFullscreenTests`, `WebPopupDialogTests`,
`AdvancedPasteTests`, `SidebarCollapseHidesLanesTests`, `WebAppChordTests`.

What they have in common: each stands up a real loopback HTTP or WebSocket
server, a real `WKWebView` content process, a real libghostty surface, or a
wall-clock timer — and swift-testing runs suites in parallel, so a dozen of
them contend for the same machine at once. The deadlines were chosen on a quiet
machine (5 s spins, 8 s `eventually`, a 30 s PDF).

**The cost is not the failures, it is the signal.** A run that fails 20 tests
for no reason is a run nobody reads, and a real regression hides in it. It has
already been waved away once per release this month.

## Acceptance Criteria

- **Find out which it is**, and say so with evidence, before fixing: (a) the
  deadlines are too tight for a loaded machine, (b) the suites collide over a
  real resource (ports, the shared general pasteboard stand-in, the WebKit
  process limit, a profile directory), or (c) both. Run the suite with
  parallelism off (`swift test --no-parallel` through `test.sh`) and compare;
  that one measurement decides most of it.
- **Then fix the cause, not the symptom.** Acceptable outcomes, in order of
  preference: serialise the suites that own a real resource (`.serialized` on
  the suite, or one shared fixture server instead of one per suite); replace
  wall-clock deadlines with a condition plus a generous ceiling; give the
  real-network and real-WebKit families their own pass in `test.sh` after the
  parallel one. Raising every timeout until the noise stops is the last resort
  and needs its numbers stated.
- **The bar: ten consecutive full runs with zero failures** on a machine that
  is also running Max Pane and a build. Report the ten results. If ten clean
  runs cannot be reached, say which suite still fails and how often, and make
  `test.sh` print that suite as "known load-sensitive" so the next release
  knows the difference between noise and a regression without three runs.
- No test may be deleted or made vacuous to reach the bar, and none may stop
  exercising the real thing it exists to exercise (real WebKit, a real
  surface, a real socket). A test that becomes a mock instead is a regression
  in coverage; say so and leave it.
- README's Test section records what runs where and what "load-sensitive"
  means now.

## Constraints

- Do not quit, replace or launch the installed app; build to
  `MAXPANE_APP=build/verify.app` and do not run it.
- The owner is using the machine; the ten runs will take a while and that is
  expected.
