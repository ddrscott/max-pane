//! Where the M3 round-trip time actually goes.
//!
//! Spike M3 measures ~2.4 ms for a 300-lane / 400-pane `state()` called from
//! Swift. This splits that between the Rust half (SQLite query + building the
//! snapshot) and everything uniffi does on top of it, so an optimisation has
//! somewhere to aim. Run with `cargo test --release --test snapshot_cost -- --nocapture`.

use laned_core::model::*;
use laned_core::Core;
use std::time::Instant;

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    sorted[(((sorted.len() - 1) as f64) * p).round() as usize]
}

#[test]
fn rust_side_snapshot_cost() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(dir.path().join("ledger.db").to_string_lossy().into_owned()).unwrap();

    let mut lane_ids: Vec<String> = Vec::new();
    for i in 0..300 {
        let placement = match lane_ids.last() {
            Some(prev) => Placement::RightOf { lane_id: prev.clone() },
            None => Placement::End,
        };
        let kind = if i % 7 == 0 { PaneKind::Pty } else { PaneKind::Web };
        let st = core
            .create_lane(
                placement,
                kind,
                if kind == PaneKind::Pty { Some(format!("sess{i}")) } else { None },
                if kind == PaneKind::Web {
                    Some(format!("https://example.com/page/{i}?q=some+realistic+query"))
                } else {
                    None
                },
                None,
            )
            .unwrap();
        let id = st.lanes.last().unwrap().id.clone();
        core.set_lane_title(id.clone(), Some(format!("lane {i} — a realistically long tab title"))).unwrap();
        core.set_manual_tag(id.clone(), Some(format!("/Users/spierce/code/project-{}", i % 12))).unwrap();
        lane_ids.push(id);
    }
    for j in 0..100 {
        core.add_pane(
            lane_ids[j % 300].clone(),
            PaneKind::Web,
            None,
            Some(format!("https://example.com/stacked/{j}")),
        )
        .unwrap();
    }

    let st = core.state().unwrap();
    let panes: usize = st.lanes.iter().map(|l| l.panes.len()).sum();
    assert_eq!(st.lanes.len(), 300);
    assert_eq!(panes, 400);

    for _ in 0..5 {
        let _ = core.state().unwrap();
    }
    let mut samples: Vec<f64> = Vec::with_capacity(200);
    for _ in 0..200 {
        let t = Instant::now();
        let s = core.state().unwrap();
        samples.push(t.elapsed().as_secs_f64() * 1000.0);
        std::hint::black_box(s);
    }
    samples.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let mean: f64 = samples.iter().sum::<f64>() / samples.len() as f64;
    println!(
        "\nRust-only state() at 300 lanes / 400 panes: mean {:.3} ms  p50 {:.3}  p95 {:.3}  max {:.3}",
        mean,
        percentile(&samples, 0.50),
        percentile(&samples, 0.95),
        samples.last().copied().unwrap_or(0.0)
    );
    println!("(Swift-side round-trip measured in spikes/m3-uniffi-ffi; the difference is uniffi's.)\n");

    // A regression guard, not a benchmark assertion: generous enough to survive
    // a loaded machine, tight enough to catch an accidental O(n^2).
    assert!(
        percentile(&samples, 0.95) < 5.0,
        "Rust-side snapshot alone has eaten the whole M3 budget: {:.3} ms",
        percentile(&samples, 0.95)
    );
}
