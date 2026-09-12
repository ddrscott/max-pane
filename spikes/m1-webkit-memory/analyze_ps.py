#!/usr/bin/env python3
"""Summarise the external ps cross-check CSV: total RSS by process kind over
time, so the in-app phys_footprint numbers can be sanity-checked against an
independent tool, and so post-suspension memory decay is visible.
Usage: uv run analyze_ps.py <ps-samples.csv> [baseline_pids_comma_sep]"""
import csv, collections, sys

rows = list(csv.DictReader(open(sys.argv[1])))
baseline = set(sys.argv[2].split(",")) if len(sys.argv) > 2 and sys.argv[2] else set()
by = collections.defaultdict(lambda: collections.defaultdict(lambda: [0, 0]))
for r in rows:
    if r["pid"] in baseline:
        continue
    e = by[int(r["ts"])][r["kind"]]
    e[0] += 1
    e[1] += int(r["rss_kb"])
ts = sorted(by)
t0 = ts[0]
print("| t+s | app RSS MB | WebContent n | WebContent RSS MB | Networking RSS MB | GPU RSS MB | TOTAL RSS MB |")
print("|---:|---:|---:|---:|---:|---:|---:|")
for t in ts:
    d = by[t]
    def g(k, i=1):
        return d[k][i] / 1024 if k in d else 0
    tot = sum(v[1] for v in d.values()) / 1024
    print(f"| {t-t0} | {g('app'):.0f} | {d.get('WebContent',[0,0])[0]} | {g('WebContent'):.0f} | "
          f"{g('Networking'):.0f} | {g('GPU'):.0f} | {tot:.0f} |")
