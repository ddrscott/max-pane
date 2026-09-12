//! Which web panes to destroy when WebKit gets expensive.
//!
//! The policy lives here rather than in the shell so the rule is one thing that
//! can be reasoned about and tested, and so a future non-macOS shell gets the
//! same behaviour. The shell supplies the facts only it knows — measured memory
//! and where the viewport is — and carries out whatever comes back.
//!
//! # What spike M1 changed
//!
//! Three measured facts rewrote this module:
//!
//! 1. **Unparenting is not a memory strategy.** Taking a `WKWebView` out of the
//!    view hierarchy reclaims ~3.5 MB — the view's own backing store — whether
//!    the page is a docs page or Slack. Destroying it reclaims 24.7 MB on light
//!    pages and 90.8 MB on real ones, and kills the OS process. Unparenting is
//!    worth doing for CPU and render-tree cost; it is 4% of what eviction buys.
//! 2. **Per-pane cost varies 3.4×** between a documentation page (27 MB) and a
//!    real site (95 MB), so the budget is a fraction of physical RAM, never a
//!    pane count.
//! 3. **Memory drifts enormously on its own.** The same 100 panes measured
//!    5 275 MB, then 2 274 MB three and a half minutes later with no user
//!    action — a 57% swing. A single-threshold policy would oscillate, so this
//!    one has a soft and a hard mark, and will not act on a spike that has not
//!    persisted.

use crate::model::{Lane, PaneKind, PaneState};

/// What the shell measured just before asking.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MemoryReport {
    /// Summed `phys_footprint` of the app and every WebKit helper process.
    pub web_content_rss_bytes: u64,
    /// Start evicting above this. M1 recommends 0.25 × physical RAM: 100 real
    /// sites measured 9.48 GB, and the soft mark should bite right about there.
    pub soft_budget_bytes: u64,
    /// Evict hard above this. M1 recommends 0.35 × physical RAM, which must sit
    /// above the 130-pane design target or it fires constantly.
    pub hard_budget_bytes: u64,
    /// Evict down to here once evicting, so there is something for the
    /// hysteresis window to hold. M1 recommends 0.20 × physical RAM.
    pub target_bytes: u64,
    /// Per-pane measured footprint, where the shell can attribute a WebKit
    /// process to a pane.
    ///
    /// Usually empty. Since M1 established one `WebContent` process per
    /// `WKWebView`, the attribution exists in principle — but the only way to
    /// ask a `WKWebView` for its process id is `_webProcessIdentifier`, which is
    /// private API this app does not use. When it is empty the policy falls back
    /// to distance and recency, which is the ordering the PRD specifies anyway.
    pub pane_footprints: Vec<PaneFootprint>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct PaneFootprint {
    pub pane_id: String,
    pub bytes: u64,
}

/// Where the strip is right now, in lane indices into `StripState.lanes`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Viewport {
    /// First lane index at least partly on screen.
    pub first_visible: u32,
    /// Last lane index at least partly on screen.
    pub last_visible: u32,
}

/// PRD §10.2: unparent web panes further than this many lanes off screen.
///
/// Kept at the PRD's value. M1 measured the saving at 3.5 MB per pane and found
/// it independent of page weight, so this is a CPU and render-tree knob, not a
/// memory one — and window occlusion may well have suspended the pane before
/// this ever fires.
pub const RELEASE_DISTANCE: u32 = 6;

/// PRD §10.3: rehydrate an evicted pane once it comes within this many lanes.
///
/// Kept tight deliberately. Re-parenting a live pane costs 1–2 ms of main-thread
/// work (M1 §7), but rehydrating an *evicted* one is a full page load.
pub const REHYDRATE_DISTANCE: u32 = 2;

/// Do not evict again for this long. M1 §5.5: the same page set swung 57% in
/// three and a half minutes with nobody touching it.
pub const HYSTERESIS_MS: i64 = 120_000;

/// How many consecutive over-budget samples before the soft mark acts. At the
/// shell's 10-second sampling interval this is 30 seconds of genuinely
/// over-budget, not one unlucky reading.
pub const CONSECUTIVE_SAMPLES: u32 = 3;

/// What the shell should do about one pane, this frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PaneAction {
    /// Keep the view in the hierarchy and rendering.
    Keep,
    /// Remove the view from the hierarchy but keep the `WKWebView` alive.
    /// Worth ~3.5 MB and the page's render/CPU cost; the object, its process and
    /// its session all survive, so putting it back is instant.
    Unparent,
    /// Snapshot, record scroll, destroy the `WKWebView`. Worth 24.7–90.8 MB and
    /// one OS process. Coming back is a full page load.
    Evict,
    /// Recreate the `WKWebView` and restore `url` + `scroll_y`.
    Rehydrate,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PaneDirective {
    pub pane_id: String,
    pub lane_id: String,
    pub action: PaneAction,
}

/// Carried between calls so the policy can refuse to act on a spike.
#[derive(Debug, Clone, Default)]
pub struct Hysteresis {
    /// Epoch ms of the last eviction, or 0.
    pub last_eviction_at: i64,
    /// Consecutive samples over the soft mark.
    pub consecutive_over_soft: u32,
}

impl Hysteresis {
    /// Update from this sample and say whether evicting is allowed now.
    fn admit(&mut self, memory: &MemoryReport, now: i64) -> Pressure {
        if memory.web_content_rss_bytes > memory.soft_budget_bytes {
            self.consecutive_over_soft = self.consecutive_over_soft.saturating_add(1);
        } else {
            self.consecutive_over_soft = 0;
            return Pressure::None;
        }

        // The hard mark is an emergency: act immediately, ignore both the
        // sample count and the cooldown. Something is genuinely wrong and
        // waiting 120 seconds to react to it would be the wrong instinct.
        if memory.web_content_rss_bytes > memory.hard_budget_bytes {
            self.last_eviction_at = now;
            return Pressure::Hard;
        }

        if self.consecutive_over_soft < CONSECUTIVE_SAMPLES {
            return Pressure::None;
        }
        if now - self.last_eviction_at < HYSTERESIS_MS {
            return Pressure::None;
        }
        self.last_eviction_at = now;
        Pressure::Soft
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Pressure {
    None,
    Soft,
    Hard,
}

/// Decide what to do with every pane on the strip.
///
/// Two independent rules:
///
/// 1. *Distance.* Far-off-screen web panes get unparented; evicted panes back
///    within [`REHYDRATE_DISTANCE`] get rehydrated. Runs on every scroll and is
///    free.
/// 2. *Budget.* If measured memory has been over the soft mark for
///    [`CONSECUTIVE_SAMPLES`] readings and the cooldown has elapsed — or is over
///    the hard mark at all — evict the least valuable panes until the estimate
///    reaches `target_bytes`. Value is distance first, then least-recently
///    focused, then largest footprint where the shell could measure one.
///
/// pty panes and pinned lanes never appear with `Evict`.
pub fn plan(
    lanes: &[Lane],
    viewport: &Viewport,
    memory: &MemoryReport,
    hysteresis: &mut Hysteresis,
    now: i64,
) -> Vec<PaneDirective> {
    let mut directives: Vec<PaneDirective> = Vec::new();
    // (distance, lane index, pane index) for things we are allowed to evict.
    let mut candidates: Vec<(u32, usize, usize)> = Vec::new();

    for (li, lane) in lanes.iter().enumerate() {
        let d = distance(li as u32, viewport);
        for (pi, pane) in lane.panes.iter().enumerate() {
            let action = match (pane.kind, pane.state) {
                // Terminals are cheap and hold live process state; never
                // unparented, never evicted.
                (PaneKind::Pty, _) => PaneAction::Keep,

                (_, PaneState::Evicted) | (PaneKind::Placeholder, _) => {
                    if d <= REHYDRATE_DISTANCE {
                        PaneAction::Rehydrate
                    } else {
                        PaneAction::Keep
                    }
                }

                (PaneKind::Web, PaneState::Live) => {
                    // Anything off screen may be evicted under pressure, not
                    // only what is past RELEASE_DISTANCE: at the hard mark there
                    // may not be six lanes' worth of slack to give.
                    if d > 0 && !lane.pinned {
                        candidates.push((d, li, pi));
                    }
                    if d > RELEASE_DISTANCE {
                        PaneAction::Unparent
                    } else {
                        PaneAction::Keep
                    }
                }
            };
            directives.push(PaneDirective {
                pane_id: pane.id.clone(),
                lane_id: lane.id.clone(),
                action,
            });
        }
    }

    let pressure = hysteresis.admit(memory, now);
    if pressure == Pressure::None || candidates.is_empty() {
        return directives;
    }

    // Furthest from the viewport first; then least recently focused; then, where
    // the shell could measure it, fattest first. M1 measured per-process
    // footprint spanning 20–116 MB on real sites, so when the information exists
    // it is worth about 5× what ignoring it is.
    candidates.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| lanes[a.1].last_focus_at.cmp(&lanes[b.1].last_focus_at))
            .then_with(|| {
                let fa = footprint_of(memory, &lanes[a.1].panes[a.2].id);
                let fb = footprint_of(memory, &lanes[b.1].panes[b.2].id);
                fb.cmp(&fa)
            })
    });

    // Evict until the estimate reaches the target. Where a pane's real footprint
    // is unknown, assume the average across the live web panes — the best guess
    // available without private API.
    let live_web = directives
        .iter()
        .filter(|d| matches!(d.action, PaneAction::Keep | PaneAction::Unparent))
        .count()
        .max(1) as u64;
    let average = (memory.web_content_rss_bytes / live_web).max(1);

    let mut projected = memory.web_content_rss_bytes;
    for (_, li, pi) in candidates {
        if projected <= memory.target_bytes {
            break;
        }
        let pane_id = &lanes[li].panes[pi].id;
        let freed = footprint_of(memory, pane_id).unwrap_or(average);
        if let Some(d) = directives.iter_mut().find(|d| &d.pane_id == pane_id) {
            d.action = PaneAction::Evict;
        }
        projected = projected.saturating_sub(freed);
    }
    directives
}

fn footprint_of(memory: &MemoryReport, pane_id: &str) -> Option<u64> {
    memory
        .pane_footprints
        .iter()
        .find(|f| f.pane_id == pane_id)
        .map(|f| f.bytes)
}

/// Lanes between `index` and the visible range. 0 when on screen.
fn distance(index: u32, vp: &Viewport) -> u32 {
    if index < vp.first_visible {
        vp.first_visible - index
    } else {
        index.saturating_sub(vp.last_visible)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Pane, ProjectSource};

    const GB: u64 = 1024 * 1024 * 1024;

    fn lane(id: &str, panes: Vec<Pane>, pinned: bool, last_focus_at: i64) -> Lane {
        Lane {
            id: id.into(),
            ordinal: 0.0,
            width_pt: 600,
            title: None,
            project_root: None,
            project_source: ProjectSource::Inherited,
            created_at: 0,
            last_focus_at,
            pinned,
            panes,
        }
    }

    fn pane(id: &str, lane_id: &str, kind: PaneKind, state: PaneState) -> Pane {
        Pane {
            id: id.into(),
            lane_id: lane_id.into(),
            position: 0,
            kind,
            relay_session_id: None,
            url: Some("https://example.com".into()),
            scroll_y: None,
            data_store_id: None,
            snapshot_path: None,
            state,
        }
    }

    fn strip(n: usize) -> Vec<Lane> {
        (0..n)
            .map(|i| {
                let lid = format!("l{i}");
                let p = pane(&format!("p{i}"), &lid, PaneKind::Web, PaneState::Live);
                lane(&lid, vec![p], false, i as i64)
            })
            .collect()
    }

    /// Budgets shaped like M1's recommendation on a 36 GiB machine.
    fn budgets(used: u64) -> MemoryReport {
        MemoryReport {
            web_content_rss_bytes: used,
            soft_budget_bytes: 9 * GB,
            hard_budget_bytes: 12 * GB,
            target_bytes: 7 * GB,
            pane_footprints: Vec::new(),
        }
    }

    /// Run `plan` enough times to clear the consecutive-sample requirement.
    fn plan_under_sustained_pressure(
        lanes: &[Lane],
        vp: &Viewport,
        memory: &MemoryReport,
    ) -> Vec<PaneDirective> {
        let mut h = Hysteresis::default();
        let mut out = Vec::new();
        for i in 0..CONSECUTIVE_SAMPLES {
            out = plan(lanes, vp, memory, &mut h, 1_000_000 + i as i64 * 10_000);
        }
        out
    }

    #[test]
    fn onscreen_panes_are_kept() {
        let lanes = strip(30);
        let vp = Viewport { first_visible: 10, last_visible: 12 };
        let mut h = Hysteresis::default();
        let plan = plan(&lanes, &vp, &budgets(1), &mut h, 0);
        assert_eq!(plan[11].action, PaneAction::Keep);
    }

    #[test]
    fn far_offscreen_web_panes_are_unparented() {
        let lanes = strip(30);
        let vp = Viewport { first_visible: 10, last_visible: 12 };
        let mut h = Hysteresis::default();
        let plan = plan(&lanes, &vp, &budgets(1), &mut h, 0);
        assert_eq!(plan[0].action, PaneAction::Unparent);
        // Four lanes away: inside RELEASE_DISTANCE, still parented.
        assert_eq!(plan[16].action, PaneAction::Keep);
    }

    #[test]
    fn pty_panes_are_never_unparented_or_evicted() {
        let lid = "l0".to_string();
        let lanes = vec![lane(&lid, vec![pane("p0", &lid, PaneKind::Pty, PaneState::Live)], false, 0)];
        let vp = Viewport { first_visible: 50, last_visible: 50 };
        let plan = plan_under_sustained_pressure(&lanes, &vp, &budgets(100 * GB));
        assert_eq!(plan[0].action, PaneAction::Keep);
    }

    #[test]
    fn pinned_lanes_are_never_evicted() {
        let mut lanes = strip(30);
        lanes[0].pinned = true;
        let vp = Viewport { first_visible: 25, last_visible: 27 };
        let plan = plan_under_sustained_pressure(&lanes, &vp, &budgets(100 * GB));
        assert_eq!(plan[0].action, PaneAction::Unparent, "pinned lane must not be evicted");
    }

    #[test]
    fn evicted_panes_rehydrate_when_they_come_close() {
        let mut lanes = strip(30);
        lanes[10].panes[0].kind = PaneKind::Placeholder;
        lanes[10].panes[0].state = PaneState::Evicted;
        let vp = Viewport { first_visible: 11, last_visible: 13 };
        let mut h = Hysteresis::default();
        let plan = plan(&lanes, &vp, &budgets(1), &mut h, 0);
        assert_eq!(plan[10].action, PaneAction::Rehydrate);
    }

    #[test]
    fn evicted_panes_stay_evicted_while_far_away() {
        let mut lanes = strip(30);
        lanes[0].panes[0].kind = PaneKind::Placeholder;
        lanes[0].panes[0].state = PaneState::Evicted;
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let mut h = Hysteresis::default();
        let plan = plan(&lanes, &vp, &budgets(1), &mut h, 0);
        assert_eq!(plan[0].action, PaneAction::Keep);
    }

    #[test]
    fn under_the_soft_mark_evicts_nothing() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let plan = plan_under_sustained_pressure(&lanes, &vp, &budgets(8 * GB));
        assert!(plan.iter().all(|d| d.action != PaneAction::Evict));
    }

    /// M1 §5.5: memory swung 57% in three and a half minutes with no user
    /// action. One reading over the soft mark must not evict anything.
    #[test]
    fn a_single_spike_over_the_soft_mark_is_ignored() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let mut h = Hysteresis::default();

        let plan = plan(&lanes, &vp, &budgets(10 * GB), &mut h, 0);
        assert!(
            plan.iter().all(|d| d.action != PaneAction::Evict),
            "evicted on the first over-budget sample"
        );
        assert_eq!(h.consecutive_over_soft, 1);
    }

    #[test]
    fn sustained_pressure_over_the_soft_mark_evicts() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let plan = plan_under_sustained_pressure(&lanes, &vp, &budgets(10 * GB));
        assert!(plan.iter().any(|d| d.action == PaneAction::Evict));
    }

    #[test]
    fn a_reading_back_under_the_soft_mark_resets_the_count() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let mut h = Hysteresis::default();

        plan(&lanes, &vp, &budgets(10 * GB), &mut h, 0);
        plan(&lanes, &vp, &budgets(10 * GB), &mut h, 10_000);
        plan(&lanes, &vp, &budgets(2 * GB), &mut h, 20_000); // settled
        assert_eq!(h.consecutive_over_soft, 0);

        let plan = plan(&lanes, &vp, &budgets(10 * GB), &mut h, 30_000);
        assert!(
            plan.iter().all(|d| d.action != PaneAction::Evict),
            "the count should have restarted"
        );
    }

    /// The hard mark is an emergency: no sample count, no cooldown.
    #[test]
    fn the_hard_mark_evicts_immediately() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let mut h = Hysteresis::default();
        let plan = plan(&lanes, &vp, &budgets(20 * GB), &mut h, 0);
        assert!(plan.iter().any(|d| d.action == PaneAction::Evict));
    }

    #[test]
    fn the_cooldown_holds_off_a_second_soft_eviction() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let mut h = Hysteresis::default();
        let over = budgets(10 * GB);

        for i in 0..CONSECUTIVE_SAMPLES {
            plan(&lanes, &vp, &over, &mut h, i as i64 * 10_000);
        }
        let at = h.last_eviction_at;

        // Still over budget 30 s later, but inside the 120 s window.
        let inside = plan(&lanes, &vp, &over, &mut h, at + 30_000);
        assert!(inside.iter().all(|d| d.action != PaneAction::Evict));

        // Past the window, it acts again.
        let after = plan(&lanes, &vp, &over, &mut h, at + HYSTERESIS_MS + 1);
        assert!(after.iter().any(|d| d.action == PaneAction::Evict));
    }

    #[test]
    fn eviction_starts_with_the_furthest_lane() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        // One average pane's worth over target.
        let used = 10 * GB;
        let mut memory = budgets(used);
        memory.target_bytes = used - used / 40;
        let plan = plan_under_sustained_pressure(&lanes, &vp, &memory);
        let evicted: Vec<&str> = plan
            .iter()
            .filter(|d| d.action == PaneAction::Evict)
            .map(|d| d.lane_id.as_str())
            .collect();
        assert_eq!(evicted, vec!["l0"], "furthest-from-viewport lane should go first");
    }

    #[test]
    fn eviction_stops_once_the_target_is_reached() {
        let lanes = strip(100);
        let vp = Viewport { first_visible: 50, last_visible: 52 };
        // 100 panes at ~100 MB each; shed about a fifth of it.
        let used = 10 * GB;
        let mut memory = budgets(used);
        memory.target_bytes = 8 * GB;
        let plan = plan_under_sustained_pressure(&lanes, &vp, &memory);
        let evicted = plan.iter().filter(|d| d.action == PaneAction::Evict).count();
        // ~100 MB average, 2 GB to shed: about 20 panes, and nothing like all 100.
        assert!((15..=25).contains(&evicted), "evicted {evicted}, expected about 20");
    }

    /// M1 §5.8: per-process footprint spans 20–116 MB on real sites, so when the
    /// shell can attribute it, the fattest equally-distant pane goes first.
    #[test]
    fn equally_distant_panes_are_evicted_fattest_first() {
        // Two lanes at the same distance and the same focus time; only the
        // measured footprint separates them.
        let mut lanes = strip(9);
        for l in lanes.iter_mut() {
            l.last_focus_at = 0;
        }
        let vp = Viewport { first_visible: 4, last_visible: 4 };

        let used = 10 * GB;
        let mut memory = budgets(used);
        memory.target_bytes = used - 100 * 1024 * 1024;
        memory.pane_footprints = vec![
            PaneFootprint { pane_id: "p0".into(), bytes: 20 * 1024 * 1024 },
            PaneFootprint { pane_id: "p8".into(), bytes: 116 * 1024 * 1024 },
        ];

        let plan = plan_under_sustained_pressure(&lanes, &vp, &memory);
        let evicted: Vec<&str> = plan
            .iter()
            .filter(|d| d.action == PaneAction::Evict)
            .map(|d| d.pane_id.as_str())
            .collect();
        // p0 and p8 are both 4 lanes away; the 116 MB one clears the deficit alone.
        assert_eq!(evicted, vec!["p8"]);
    }

    /// Under enough pressure, a pane that is merely off-screen can go — there is
    /// not always six lanes of slack to find.
    #[test]
    fn severe_pressure_reaches_panes_inside_the_release_distance() {
        let lanes = strip(10);
        let vp = Viewport { first_visible: 5, last_visible: 5 };
        let mut h = Hysteresis::default();
        // Hard mark, target near zero: everything it is allowed to take.
        let mut memory = budgets(30 * GB);
        memory.target_bytes = 1;
        let plan = plan(&lanes, &vp, &memory, &mut h, 0);

        let evicted: Vec<&str> = plan
            .iter()
            .filter(|d| d.action == PaneAction::Evict)
            .map(|d| d.pane_id.as_str())
            .collect();
        assert_eq!(evicted.len(), 9, "everything off screen should be reachable");
        assert!(!evicted.contains(&"p5"), "the visible pane must survive");
    }
}
