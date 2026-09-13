# Spike M5 — a lane as a gallery thumbnail

Can a lane be drawn smaller without resizing anything, and does it stay sharp
and cheap? Answers the question `docs/work/gallery-layout.md` rests on:
**layer transform vs. a smaller backing**, for a Ghostty surface and a
`WKWebView`.

Results doc: `docs/spikes/05-gallery-scale.md`.

## Build

```sh
./build.sh          # swift build -c release + hand-assembled GalleryScale.app + ad-hoc codesign
```

Pinned to the exact libghostty-spm the app resolves.

## Run

```sh
./run.sh out/1x                   # every phase, at the connected panel's scale
BACKING=2 ./run.sh out/2x         # every phase, rendered as a 2× panel would
BACKING=2 ./run.sh out/2x grid    # one phase
```

It is safe to run on a machine someone is using. The app is an `LSUIElement`
agent launched with `open -g`; it never activates, and its one window sits below
the desktop picture. Nothing it does takes focus or a keystroke.

## Phases

| Phase | Measures |
|---|---|
| `grid` | the grid Ghostty reports under each approach, with a positive control |
| `pixels` | Ghostty's own IOSurface, composited through `CARenderer` with each minification filter, against a Lanczos reference; PNGs of all of it |
| `cost` | CPU and footprint for 12 terminals, idle and streaming, full size vs. transform vs. smaller backing |
| `web` | `innerWidth`, `devicePixelRatio` and snapshot size under transform, `pageZoom` and magnification |

Output is `results.json`, `run.log`, and the PNGs, in the directory you name.

## Two things it emulates, and why that is fair

- **2×** — `BACKING=2` overrides the window's `backingScaleFactor`. Ghostty reads
  its content scale from that property and nothing else, so it renders exactly
  as it would on a 2× panel. Needed because the only panel AppKit reported as
  connected when this was run was a 1× one.
- **Smaller backing** — libghostty-spm keeps `scaleFactor` internal. A frame of
  lane × s with the font at × s is the same pixel arithmetic Ghostty would do at
  content scale × s, which is how it is measured.
