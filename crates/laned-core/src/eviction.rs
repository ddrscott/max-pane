//! Which web panes to destroy when WebKit's content processes get expensive.
//!
//! The policy lives here rather than in the shell so that the rule is one thing
//! that can be reasoned about and tested, and so a future non-macOS shell gets
//! the same behaviour. The shell supplies the two facts only it knows — measured
//! memory and where the viewport is — and carries out whatever comes back.

use crate::model::{Lane, PaneKind, PaneState};

/// What the shell measured just before asking.
#[derive(Debug, Clone, uniffi::Record)]
pub struct MemoryReport {
    /// Resident bytes across every WebKit content process.
    pub web_content_rss_bytes: u64,
    /// Evict until we are under this. The shell derives it from physical RAM.
    pub budget_bytes: u64,
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
pub const RELEASE_DISTANCE: u32 = 6;
/// PRD §10.3: rehydrate an evicted pane once it comes within this many lanes.
pub const REHYDRATE_DISTANCE: u32 = 2;

/// What the shell should do about one pane, this frame.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PaneAction {
    /// Keep the view in the hierarchy and rendering.
    Keep,
    /// Remove the view from the hierarchy but keep the `WKWebView` alive.
    /// WebKit stops rendering an unparented view, which is most of the win for
    /// none of the cost of a reload.
    Unparent,
    /// Snapshot, record scroll, destroy the `WKWebView`.
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

/// Decide what to do with every pane on the strip.
///
/// Two independent rules, applied in order:
///
/// 1. *Distance.* Far-off-screen web panes get unparented; evicted panes that
///    have come back within [`REHYDRATE_DISTANCE`] get rehydrated. This runs on
///    every scroll and is free.
/// 2. *Budget.* If measured WebKit memory is over budget, evict the
///    least-valuable unparented panes until the estimate is back under. Value is
///    distance first, then how recently the lane was focused.
///
/// pty panes and pinned lanes never appear with `Evict`.
pub fn plan(lanes: &[Lane], viewport: &Viewport, memory: &MemoryReport) -> Vec<PaneDirective> {
    let mut directives: Vec<PaneDirective> = Vec::new();
    // (index into lanes, pane index) of things we could still evict, worst first.
    let mut candidates: Vec<(u32, usize, usize)> = Vec::new();

    for (li, lane) in lanes.iter().enumerate() {
        let d = distance(li as u32, viewport);
        for (pi, pane) in lane.panes.iter().enumerate() {
            let action = match (pane.kind, pane.state) {
                // Terminals are cheap and hold live process state; they are
                // never unparented and never evicted.
                (PaneKind::Pty, _) => PaneAction::Keep,

                (_, PaneState::Evicted) | (PaneKind::Placeholder, _) => {
                    if d <= REHYDRATE_DISTANCE {
                        PaneAction::Rehydrate
                    } else {
                        PaneAction::Keep
                    }
                }

                (PaneKind::Web, PaneState::Live) => {
                    if d > RELEASE_DISTANCE {
                        if !lane.pinned {
                            candidates.push((d, li, pi));
                        }
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

    if memory.web_content_rss_bytes <= memory.budget_bytes || candidates.is_empty() {
        return directives;
    }

    // Furthest from the viewport first; ties broken by least recently focused.
    candidates.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then_with(|| lanes[a.1].last_focus_at.cmp(&lanes[b.1].last_focus_at))
    });

    // We cannot know a single pane's real cost without asking WebKit per
    // process, so assume the overage is spread evenly across the live web panes
    // we are allowed to touch and evict enough of them to clear it.
    let live_web = directives
        .iter()
        .filter(|d| matches!(d.action, PaneAction::Keep | PaneAction::Unparent))
        .count()
        .max(1) as u64;
    let per_pane = (memory.web_content_rss_bytes / live_web).max(1);
    let overage = memory.web_content_rss_bytes - memory.budget_bytes;
    let to_evict = ((overage + per_pane - 1) / per_pane) as usize;

    for (_, li, pi) in candidates.into_iter().take(to_evict) {
        let pane_id = &lanes[li].panes[pi].id;
        if let Some(d) = directives.iter_mut().find(|d| &d.pane_id == pane_id) {
            d.action = PaneAction::Evict;
        }
    }
    directives
}

/// Lanes between `index` and the visible range. 0 when on screen.
fn distance(index: u32, vp: &Viewport) -> u32 {
    if index < vp.first_visible {
        vp.first_visible - index
    } else if index > vp.last_visible {
        index - vp.last_visible
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Pane, ProjectSource};

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

    fn under_budget() -> MemoryReport {
        MemoryReport { web_content_rss_bytes: 1, budget_bytes: u64::MAX }
    }

    #[test]
    fn onscreen_panes_are_kept() {
        let lanes = strip(30);
        let vp = Viewport { first_visible: 10, last_visible: 12 };
        let plan = plan(&lanes, &vp, &under_budget());
        assert_eq!(plan[11].action, PaneAction::Keep);
    }

    #[test]
    fn far_offscreen_web_panes_are_unparented() {
        let lanes = strip(30);
        let vp = Viewport { first_visible: 10, last_visible: 12 };
        let plan = plan(&lanes, &vp, &under_budget());
        // Lane 0 is 10 lanes left of the viewport, well past RELEASE_DISTANCE.
        assert_eq!(plan[0].action, PaneAction::Unparent);
        // Lane 16 is 4 away: inside the release distance, still parented.
        assert_eq!(plan[16].action, PaneAction::Keep);
    }

    #[test]
    fn pty_panes_are_never_unparented_or_evicted() {
        let lid = "l0".to_string();
        let lanes = vec![lane(&lid, vec![pane("p0", &lid, PaneKind::Pty, PaneState::Live)], false, 0)];
        let vp = Viewport { first_visible: 50, last_visible: 50 };
        let over = MemoryReport { web_content_rss_bytes: 100, budget_bytes: 1 };
        let plan = plan(&lanes, &vp, &over);
        assert_eq!(plan[0].action, PaneAction::Keep);
    }

    #[test]
    fn pinned_lanes_are_never_evicted() {
        let mut lanes = strip(30);
        lanes[0].pinned = true;
        let vp = Viewport { first_visible: 25, last_visible: 27 };
        let over = MemoryReport { web_content_rss_bytes: 100 * 1024 * 1024 * 1024, budget_bytes: 1 };
        let plan = plan(&lanes, &vp, &over);
        assert_eq!(plan[0].action, PaneAction::Unparent, "pinned lane must not be evicted");
    }

    #[test]
    fn evicted_panes_rehydrate_when_they_come_close() {
        let mut lanes = strip(30);
        lanes[10].panes[0].kind = PaneKind::Placeholder;
        lanes[10].panes[0].state = PaneState::Evicted;
        let vp = Viewport { first_visible: 11, last_visible: 13 };
        let plan = plan(&lanes, &vp, &under_budget());
        assert_eq!(plan[10].action, PaneAction::Rehydrate);
    }

    #[test]
    fn evicted_panes_stay_evicted_while_far_away() {
        let mut lanes = strip(30);
        lanes[0].panes[0].kind = PaneKind::Placeholder;
        lanes[0].panes[0].state = PaneState::Evicted;
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let plan = plan(&lanes, &vp, &under_budget());
        assert_eq!(plan[0].action, PaneAction::Keep);
    }

    #[test]
    fn over_budget_evicts_the_furthest_lane_first() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        // One pane's worth of overage.
        let total = 40u64 * 1024 * 1024;
        let over = MemoryReport { web_content_rss_bytes: total, budget_bytes: total - 1024 * 1024 };
        let plan = plan(&lanes, &vp, &over);
        let evicted: Vec<&str> = plan
            .iter()
            .filter(|d| d.action == PaneAction::Evict)
            .map(|d| d.lane_id.as_str())
            .collect();
        assert_eq!(evicted, vec!["l0"], "furthest-from-viewport lane should go first");
    }

    #[test]
    fn under_budget_evicts_nothing() {
        let lanes = strip(40);
        let vp = Viewport { first_visible: 20, last_visible: 22 };
        let plan = plan(&lanes, &vp, &under_budget());
        assert!(plan.iter().all(|d| d.action != PaneAction::Evict));
    }
}
