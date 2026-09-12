#!/usr/bin/env python3
"""Summarize StripBench result JSONs into markdown tables."""
import json, sys, os, glob

def g(d, *ks):
    for k in ks: d = d[k]
    return d

def load(tag, outdir):
    p = os.path.join(outdir, tag + ".json")
    return json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else None

def fmt(x, n=2):
    return "n/a" if x is None else (f"{x:.{n}f}" if isinstance(x, float) else str(x))

VARIANTS = [("naive", "A-naive"), ("recycled", "A-recycled"), ("collection", "B-collectionview")]

def table(outdir, prefix, title):
    rows = []
    ds = {}
    for v, label in VARIANTS:
        d = load(f"{prefix}-{v}", outdir)
        if d: ds[label] = d
    if not ds:
        return f"\n(no results for {title})\n"
    labels = list(ds.keys())
    def line(name, fn):
        return "| " + name + " | " + " | ".join(str(fn(ds[l])) for l in labels) + " |"
    out = [f"\n### {title}\n", "| Metric | " + " | ".join(labels) + " |",
           "|---|" + "---|" * len(labels)]
    m = [
        ("Display / refresh", lambda d: f"{d['windowScreen']} @ {d['windowScreenMaxFPS']} Hz"),
        ("Frame budget (ms)", lambda d: fmt(d['frameBudgetMs'], 3)),
        ("Frames measured (clean sweep)", lambda d: g(d,'cleanScroll','frames')),
        ("Sweep duration (s)", lambda d: fmt(g(d,'cleanScroll','durationSeconds'), 1)),
        ("**Frame interval mean (ms)**", lambda d: fmt(g(d,'cleanScroll','intervalMs','mean'), 2)),
        ("Frame interval p50 (ms)", lambda d: fmt(g(d,'cleanScroll','intervalMs','p50'), 2)),
        ("Frame interval p95 (ms)", lambda d: fmt(g(d,'cleanScroll','intervalMs','p95'), 2)),
        ("Frame interval p99 (ms)", lambda d: fmt(g(d,'cleanScroll','intervalMs','p99'), 2)),
        ("Frame interval max (ms)", lambda d: fmt(g(d,'cleanScroll','intervalMs','max'), 2)),
        ("**Dropped frames (count)**", lambda d: g(d,'cleanScroll','droppedFrames')),
        ("**Dropped frames (%)**", lambda d: fmt(g(d,'cleanScroll','droppedPct'), 2)),
        ("Severe drops (>2.5x budget)", lambda d: g(d,'cleanScroll','severeDrops')),
        ("Wall-clock interval max (ms)", lambda d: fmt(g(d,'cleanScroll','wallIntervalMs','max'), 2)),
        ("Wall-clock drops (count)", lambda d: g(d,'cleanScroll','droppedFramesWallClock')),
        ("Main-thread work/frame mean (ms)", lambda d: fmt(g(d,'cleanScroll','workMs','mean'), 3)),
        ("Main-thread work/frame p99 (ms)", lambda d: fmt(g(d,'cleanScroll','workMs','p99'), 3)),
        ("Main-thread work/frame max (ms)", lambda d: fmt(g(d,'cleanScroll','workMs','max'), 3)),
        ("Frames with work > budget", lambda d: g(d,'cleanScroll','framesWorkOverBudget')),
        ("layout() calls / frame (mean)", lambda d: fmt(g(d,'cleanScroll','layoutCallsPerFrameMean'), 2)),
        ("layout() calls / frame (max)", lambda d: g(d,'cleanScroll','layoutCallsPerFrameMax')),
        ("layout() calls, whole sweep", lambda d: g(d,'cleanScroll','layoutCallsTotal')),
        ("updateConstraints() calls (total)", lambda d: d['updateConstraintsTotal']),
        ("Lane views instantiated (run)", lambda d: d['laneViewsInstantiatedDuringRun']),
        ("Lane configure() calls (run)", lambda d: d['laneConfiguresDuringRun']),
        ("**Peak live lane views / 150**", lambda d: f"{d['peakLiveLaneViews']} / 150"),
        ("RSS at rest (MB)", lambda d: fmt(d['rssAtRestBytes']/1e6, 1)),
        ("Phys footprint at rest (MB)", lambda d: fmt(d['physFootprintAtRestBytes']/1e6, 1)),
        ("RSS after full sweep (MB)", lambda d: fmt(d['rssAfterScrollBytes']/1e6, 1)),
        ("Idle CPU mean (% of 1 core)", lambda d: fmt(d['idleCpuMeanPct'], 3)),
        ("Idle CPU max (% of 1 core)", lambda d: fmt(d['idleCpuMaxPct'], 3)),
        ("Idle sample length (s)", lambda d: fmt(d['idleSeconds'], 0)),
        ("Time to interactive strip, from exec (ms)", lambda d: fmt(d['ttiFromExecMs'], 0)),
        ("Time to interactive strip, from main() (ms)", lambda d: fmt(d['ttiFromMainEntryMs'], 0)),
        ("Strip content width (pt)", lambda d: fmt(d['stripContentWidthPt'], 0)),
        ("Viewport (pt)", lambda d: f"{d['viewportWidthPt']:.0f} x {d['viewportHeightPt']:.0f}"),
    ]
    for name, fn in m:
        out.append(line(name, fn))
    # events
    for kind in ("insert-mid-strip", "resize-mid-scroll"):
        def ev(d, kind=kind, field="workMs"):
            for e in d['events']:
                if e['kind'] == kind: return e
            return None
        out.append(line(f"{kind}: work in that frame (ms)",
                        lambda d, k=kind: fmt((ev(d,k) or {}).get('workMs'), 2)))
        out.append(line(f"{kind}: max interval next 10 frames (ms)",
                        lambda d, k=kind: fmt((ev(d,k) or {}).get('maxIntervalNext10Ms'), 2)))
        out.append(line(f"{kind}: visible hitch?",
                        lambda d, k=kind: "YES" if (ev(d,k) or {}).get('visibleHitch') else "no"))
    out.append(line("Perturbation sweep dropped frames",
                    lambda d: g(d,'perturbScroll','droppedFrames')))
    out.append(line("Perturbation sweep max interval (ms)",
                    lambda d: fmt(g(d,'perturbScroll','intervalMs','max'), 2)))
    out.append(line("Scroll restore exact (3/3 targets)",
                    lambda d: f"{sum(1 for r in d['restore'] if r['exact'])}/{len(d['restore'])}"))
    out.append(line("Screen locked during run",
                    lambda d: "YES" if d['screenLockedAtStart'] else "no"))
    out.append(line("Frames with window occluded",
                    lambda d: f"{d['framesWindowNotVisible']}"))
    return "\n".join(out) + "\n"

if __name__ == "__main__":
    outdir = sys.argv[1] if len(sys.argv) > 1 else "results"
    print(table(outdir, "s0", "Main display"))
    print(table(outdir, "s1", "Secondary display"))
