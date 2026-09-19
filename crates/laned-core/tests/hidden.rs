//! Lanes a collapsed sidebar group hides (ADR-0024).
//!
//! The shell decides *which* lanes — a sidebar group is a session's cwd, and
//! only the shell hears that — and the core decides what hidden means: out of
//! the snapshot, in the ledger, nothing about the lane written, the set itself
//! persisted, a docked lane never, and focus handed to the nearest lane still
//! on the strip.

use laned_core::eviction::{MemoryReport, PaneAction, Viewport};
use laned_core::model::*;
use laned_core::Core;

const GB: u64 = 1024 * 1024 * 1024;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

fn lane(core: &Core, title: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{title}")), None)
        .unwrap();
    let id = st.lanes.last().unwrap().id.clone();
    core.set_lane_title(id.clone(), Some(title.into())).unwrap();
    id
}

fn titles(st: &StripState) -> Vec<String> {
    st.lanes.iter().map(|l| l.title.clone().unwrap_or_default()).collect()
}

fn focused_title(core: &Core) -> String {
    let st = core.state().unwrap();
    let pane = st.focused_pane_id.unwrap();
    core.all_lanes()
        .unwrap()
        .into_iter()
        .find(|l| l.panes.iter().any(|p| p.id == pane))
        .and_then(|l| l.title)
        .unwrap_or_default()
}

#[test]
fn hiding_narrows_the_snapshot_and_writes_nothing_about_a_lane() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c", "d"].iter().map(|t| lane(&core, t)).collect();
    core.set_lane_width(ids[1].clone(), 700).unwrap();
    let before = core.all_lanes().unwrap();

    let st = core.set_hidden_lanes(vec![ids[1].clone(), ids[3].clone()], false).unwrap();
    assert_eq!(titles(&st), ["a", "c"]);
    assert_eq!(st.hidden_lane_ids, [ids[1].clone(), ids[3].clone()], "in ordinal order");
    assert_eq!(core.all_lanes().unwrap(), before, "a hidden lane is in the ledger exactly as it was");

    let st = core.set_hidden_lanes(vec![], false).unwrap();
    assert_eq!(titles(&st), ["a", "b", "c", "d"], "same order");
    assert_eq!(st.lanes, before, "same widths, same everything");
    assert!(st.hidden_lane_ids.is_empty());
}

#[test]
fn the_hidden_set_survives_a_relaunch_and_so_do_the_collapsed_groups() {
    let dir = tempfile::tempdir().unwrap();
    let hidden;
    {
        let core = Core::open(db(&dir)).unwrap();
        lane(&core, "a");
        hidden = lane(&core, "b");
        core.set_hidden_lanes(vec![hidden.clone()], false).unwrap();
        core.set_sidebar_collapsed(vec!["~/code/b".into(), "yorkshire:".into()]).unwrap();
    }
    let core = Core::open(db(&dir)).unwrap();
    let st = core.state().unwrap();
    assert_eq!(titles(&st), ["a"], "the first snapshot after a relaunch is already narrowed");
    assert_eq!(st.hidden_lane_ids, [hidden]);
    assert_eq!(core.sidebar_collapsed().unwrap(), ["yorkshire:", "~/code/b"]);
}

#[test]
fn a_docked_lane_is_never_hidden() {
    let core = Core::open_in_memory().unwrap();
    let music = lane(&core, "music");
    let work = lane(&core, "work");
    core.dock_lane(music.clone(), DockSide::Left, DockMode::Overlay, None).unwrap();
    let st = core.set_hidden_lanes(vec![music.clone(), work.clone()], false).unwrap();
    assert_eq!(titles(&st), ["music"]);
    assert_eq!(st.hidden_lane_ids, [work], "only what was actually taken out is reported");
}

#[test]
fn a_gather_and_a_collapse_narrow_together_and_nothing_is_counted_twice() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    let b = lane(&core, "b");
    let c = lane(&core, "c");
    core.set_manual_tag(a.clone(), Some("/src/foo".into())).unwrap();
    core.set_manual_tag(b.clone(), Some("/src/foo".into())).unwrap();
    core.set_manual_tag(c.clone(), Some("/src/bar".into())).unwrap();
    core.set_hidden_lanes(vec![b.clone(), c.clone()], false).unwrap();
    let st = core.gather("/src/foo".into()).unwrap();
    assert_eq!(titles(&st), ["a"]);
    assert_eq!(st.hidden_lane_ids, [b.clone()], "c was the gather's, not the collapse's");
    let st = core.ungather().unwrap();
    assert_eq!(titles(&st), ["a"]);
    assert_eq!(st.hidden_lane_ids, [b, c]);
}

#[test]
fn focus_goes_to_the_nearest_lane_still_there_right_first() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c", "d", "e"].iter().map(|t| lane(&core, t)).collect();
    let pane_of = |i: usize| core.lane(ids[i].clone()).unwrap().panes[0].id.clone();

    // b has the keyboard; b and c go. d is the nearest to the right.
    core.focus_pane(pane_of(1)).unwrap();
    core.set_hidden_lanes(vec![ids[1].clone(), ids[2].clone()], true).unwrap();
    assert_eq!(focused_title(&core), "d");

    // d has it; d and e go as well. Nothing to the right: a, to the left.
    core.set_hidden_lanes(ids[1..].to_vec(), true).unwrap();
    assert_eq!(focused_title(&core), "a");

    // A focused lane that is staying keeps the keyboard.
    core.set_hidden_lanes(vec![], true).unwrap();
    core.focus_pane(pane_of(0)).unwrap();
    core.set_hidden_lanes(vec![ids[4].clone()], true).unwrap();
    assert_eq!(focused_title(&core), "a");

    // Everything goes: there is nobody to hand it to, and it stays put.
    core.set_hidden_lanes(ids.clone(), true).unwrap();
    assert_eq!(focused_title(&core), "a");
}

#[test]
fn a_recount_leaves_focus_alone() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    lane(&core, "b");
    let pane = core.lane(a.clone()).unwrap().panes[0].id.clone();
    core.focus_pane(pane.clone()).unwrap();
    let st = core.set_hidden_lanes(vec![a], false).unwrap();
    assert_eq!(st.focused_pane_id, Some(pane));
}

#[test]
fn search_and_export_still_see_a_hidden_lane() {
    let core = Core::open_in_memory().unwrap();
    lane(&core, "visible");
    let hidden = lane(&core, "needle");
    core.set_hidden_lanes(vec![hidden.clone()], false).unwrap();
    assert!(core.search("needle".into(), 5).unwrap().iter().any(|h| h.lane_id == hidden));
    assert!(core.export_strip().unwrap().contains("needle"));
}

#[test]
fn a_hidden_page_is_planned_for_as_further_than_any_lane() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c"].iter().map(|t| lane(&core, t)).collect();
    // b is hidden. The strip the shell laid out is [a, c]; both are on screen.
    core.set_hidden_lanes(vec![ids[1].clone()], false).unwrap();
    let calm = MemoryReport {
        web_content_rss_bytes: GB,
        soft_budget_bytes: 9 * GB,
        hard_budget_bytes: 12 * GB,
        target_bytes: 6 * GB,
        pane_footprints: Vec::new(),
    };
    let plan = core.plan_eviction(Viewport { first_visible: 0, last_visible: 1 }, calm).unwrap();
    let action = |id: &str| plan.iter().find(|d| d.lane_id == id).unwrap().action;
    assert_eq!(action(&ids[0]), PaneAction::Keep);
    assert_eq!(action(&ids[2]), PaneAction::Keep, "c is index 1 of the strip, not 2: b holds no slot");
    assert_eq!(action(&ids[1]), PaneAction::Unparent);

    // Over the hard mark it is the hidden page that goes, not one in view.
    let over = MemoryReport {
        web_content_rss_bytes: 13 * GB,
        soft_budget_bytes: 9 * GB,
        hard_budget_bytes: 12 * GB,
        target_bytes: 12 * GB,
        pane_footprints: Vec::new(),
    };
    let plan = core.plan_eviction(Viewport { first_visible: 0, last_visible: 1 }, over).unwrap();
    let action = |id: &str| plan.iter().find(|d| d.lane_id == id).unwrap().action;
    assert_eq!(action(&ids[1]), PaneAction::Evict);
    assert_eq!(action(&ids[0]), PaneAction::Keep);

    // Evicted and hidden: never rehydrated until it is back on the strip.
    let pane = core.lane(ids[1].clone()).unwrap().panes[0].id.clone();
    core.mark_evicted(pane, None, None).unwrap();
    let calm = MemoryReport {
        web_content_rss_bytes: GB,
        soft_budget_bytes: 9 * GB,
        hard_budget_bytes: 12 * GB,
        target_bytes: 6 * GB,
        pane_footprints: Vec::new(),
    };
    let plan = core.plan_eviction(Viewport { first_visible: 0, last_visible: 1 }, calm.clone()).unwrap();
    assert_eq!(plan.iter().find(|d| d.lane_id == ids[1]).unwrap().action, PaneAction::Keep);
    core.set_hidden_lanes(vec![], false).unwrap();
    let plan = core.plan_eviction(Viewport { first_visible: 0, last_visible: 2 }, calm).unwrap();
    assert_eq!(plan.iter().find(|d| d.lane_id == ids[1]).unwrap().action, PaneAction::Rehydrate);
}
