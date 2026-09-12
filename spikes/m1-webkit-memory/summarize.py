#!/usr/bin/env python3
"""Turn a report-*.json from the M1 spike into the markdown tables used in
docs/spikes/01-m1-webkit-memory.md. Usage: uv run summarize.py <report.json>"""
import json, sys

r = json.load(open(sys.argv[1]))
m = r["meta"]
print(f"## meta\nmode={m['mode']} views={m['views']} parented={m['parented']} "
      f"lane={m['lane_w']:.0f}x{m['lane_h']:.0f} stores={m['store_count']} ({m['store_kind']})")
print(f"screen_locked_at_start={m.get('screen_locked_at_start')} display_asleep_at_start={m.get('display_asleep_at_start')}")
print(f"window_ever_visible={r.get('window_ever_visible')} valid_for_visibility={r.get('valid_for_visibility_measurements')}")
print(f"loads: {r.get('load_ok')} ok / {r.get('load_failed')} failed")

print("\n## memory snapshots")
print("| stage | WebContent procs | app MB | WebContent MB | Networking MB | GPU MB | TOTAL footprint MB | TOTAL RSS MB |")
print("|---|---:|---:|---:|---:|---:|---:|---:|")
for s in r["snapshots"]:
    bk = s["by_kind"]
    def g(k, f="footprint_mb"):
        return f"{bk[k][f]:.0f}" if k in bk else "-"
    print(f"| {s['label']} | {s['webcontent_count']} | {g('app')} | {g('WebContent')} | "
          f"{g('Networking')} | {g('GPU')} | {s['total_footprint_mb']:.0f} | {s['total_rss_mb']:.0f} |")

snaps = {s["label"]: s for s in r["snapshots"]}
order = [s for s in r["snapshots"] if s["label"].startswith("parented_") and "unparented" not in s["label"]]
if len(order) >= 2:
    print("\n## marginal cost per added web pane (all parented)")
    print("| from -> to | Δ views | Δ footprint MB | MB / view (marginal) | MB / view (cumulative) |")
    print("|---|---:|---:|---:|---:|")
    prev = None
    for s in order:
        n = int(s["label"].split("_")[1])
        if prev:
            dn = n - prev[0]; df = s["total_footprint_mb"] - prev[1]
            print(f"| {prev[0]} -> {n} | {dn} | {df:.0f} | {df/dn:.1f} | {s['total_footprint_mb']/n:.1f} |")
        prev = (n, s["total_footprint_mb"])

for k in ("idle_quiescent", "idle_with_animating_pages"):
    if k in r:
        d = r[k]
        print(f"\n## {k}\nmean {d['mean_pct_one_core']:.2f}% of one core, max {d['max_pct_one_core']:.2f}%, "
              f"min {d['min_pct_one_core']:.2f}% over {d['windows']} x {d['window_secs']:.0f}s windows")

if "latency_summary" in r:
    print("\n## re-parent latency (ms)")
    print("| measure | n | min | median | p95 | max | mean |")
    print("|---|---:|---:|---:|---:|---:|---:|")
    for k, v in r["latency_summary"].items():
        if not v.get("n"): print(f"| {k} | 0 | - | - | - | - | - |"); continue
        print(f"| {k} | {v['n']:.0f} | {v['min']:.1f} | {v['median']:.1f} | {v['p95']:.1f} | {v['max']:.1f} | {v['mean']:.1f} |")

if "suspension" in r:
    print("\n## rendering suspension")
    print("| phase | view | role | rAF frames | window s | rAF fps | setInterval(100ms) ticks | visibilityState |")
    print("|---|---:|---|---:|---:|---:|---:|---|")
    for x in r["suspension"]:
        print(f"| {x['phase']} | {x['view']} | {x['role']} | {x['raf_delta']} | {x['seconds']:.1f} | "
              f"{x['raf_fps']:.2f} | {x['tick_delta']} | {x['visibility_state']} |")

if "eviction" in r:
    e = r["eviction"]
    print(f"\n## eviction (destroy WKWebView)\nbefore: {e['before_footprint_mb']:.0f} MB footprint / "
          f"{e['before_webcontent']} WebContent; after: {e['after_footprint_mb']:.0f} MB / {e['after_webcontent']} WebContent; "
          f"reclaimed {e['reclaimed_mb_per_view']:.1f} MB per destroyed view")

fp = r.get("final_webcontent_footprints_mb") or []
if fp:
    fp = sorted(fp)
    print(f"\n## per-WebContent-process footprint (n={len(fp)}) MB")
    print(f"min {fp[0]:.1f} / p25 {fp[len(fp)//4]:.1f} / median {fp[len(fp)//2]:.1f} / "
          f"p95 {fp[int(len(fp)*0.95)]:.1f} / max {fp[-1]:.1f} / mean {sum(fp)/len(fp):.1f}")
