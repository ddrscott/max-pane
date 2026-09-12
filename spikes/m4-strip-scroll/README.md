# Spike M4 — fullscreen strip scroll with 150 lanes

Measures horizontal strip scrolling with 150 varied-width lane views under three
strategies, to answer PRD §12 M4 and the §14 decision
"virtualized strip (`NSCollectionView`) vs plain `NSScrollView` with manual view recycling".

Results doc: `docs/spikes/04-m4-strip-scroll.md`.

## Build

```sh
./build.sh          # swift build -c release + hand-assembled StripBench.app + ad-hoc codesign
```

No Xcode is required; `xcodebuild` is not used.

## Run

```sh
./run-matrix.sh results    # the full 3-variant x 2-screen matrix used in the doc
./analyze.py results       # render the markdown comparison tables

# one variant by hand:
./run.sh recycled 0 out/one.json --lanes 150 --velocity 6000 --idle-seconds 60
```

## Flags

| Flag | Default | Meaning |
|---|---|---|
| `--variant naive\|recycled\|collection` | `recycled` | A-naive / A-recycled / B-collectionview |
| `--lanes N` | 150 | lane count |
| `--screen N` | 0 | index into `NSScreen.screens` |
| `--velocity PT` | 6000 | scripted scroll speed, points/second |
| `--buffer N` | 2 | lanes attached beyond the viewport (recycled variant) |
| `--idle-seconds N` | 60 | idle-CPU sample length |
| `--settle N` | 2 | seconds at rest before the sweep |
| `--fs-mode borderless\|native\|none` | `borderless` | how the window covers the screen |
| `--no-force-display` | off | skip the per-frame `displayIfNeeded()` |
| `--out PATH` | `results.json` | JSON results; `PATH.log` gets a phase trace |
