//! Docking a lane to the left or right edge of the window.
//!
//! The acceptance criterion the owner stated is audible — *"i often have a page
//! that's for background music"* — and half of it is the view's. What the core
//! can be held to is here: the page is never destroyed, never taken out of the
//! window, and comes back where it was. So most of this file is the two rules
//! that could silently be wrong — *"the order of the docked lane is remembered
//! so it returns to the same spot"*, and "the eviction policy never touches it"
//! — taken literally, including across a restart done the way `durability.rs`
//! does it: drop the `Core` with no shutdown path and reopen the file.

use laned_core::eviction::{MemoryReport, PaneAction, PaneDirective, Viewport};
use laned_core::model::*;
use laned_core::Core;
use std::path::Path;

const GB: u64 = 1024 * 1024 * 1024;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// A web lane with a recognisable title, and its id.
fn lane(core: &Core, title: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{title}")), None)
        .unwrap();
    let id = st.lanes.last().unwrap().id.clone();
    core.set_lane_title(id.clone(), Some(title.into())).unwrap();
    id
}

/// Titles in strip order, docked lanes excluded — what the strip lays out.
fn strip(core: &Core) -> Vec<String> {
    core.state()
        .unwrap()
        .lanes
        .iter()
        .filter(|l| l.dock.is_none())
        .map(|l| l.title.clone().unwrap_or_default())
        .collect()
}

fn dock_of(core: &Core, lane_id: &str) -> Option<Dock> {
    core.lane(lane_id.to_string()).unwrap().dock
}

// ---- the unit is the lane ---------------------------------------------------

/// Settled by the owner, not inferred: *"a lane may contain several vertically
/// stacked panes … when a lane is docked all its panes are inherently docked
/// with it."* The earlier brief argued both sides; this is the answer, and the
/// test exists so nobody re-litigates it from the brief.
#[test]
fn a_lane_docks_as_a_unit_however_many_panes_it_has() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.add_pane(id.clone(), PaneKind::Web, None, Some("https://queue".into())).unwrap();
    core.add_pane(id.clone(), PaneKind::Pty, None, None).unwrap();

    core.dock_lane(id.clone(), DockSide::Left, DockMode::Inset, None).unwrap();

    let docked = core.lane(id).unwrap();
    assert_eq!(docked.panes.len(), 3, "docking dropped panes on the floor");
    assert!(docked.dock.is_some());
}

/// A docked lane is still a lane: splitting it down, resizing its stack and
/// retitling it all keep working. Docking is a statement about where the lane
/// is, not about what it may do.
#[test]
fn a_docked_lane_can_still_be_split_and_reweighted() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.dock_lane(id.clone(), DockSide::Right, DockMode::Overlay, None).unwrap();

    let st = core.add_pane(id.clone(), PaneKind::Web, None, Some("https://lyrics".into())).unwrap();
    let docked = st.lanes.iter().find(|l| l.id == id).unwrap();
    assert_eq!(docked.panes.len(), 2);

    core.set_pane_heights(vec![
        PaneHeight { pane_id: docked.panes[0].id.clone(), weight: 3.0 },
        PaneHeight { pane_id: docked.panes[1].id.clone(), weight: 1.0 },
    ])
    .unwrap();
    let docked = core.lane(id).unwrap();
    assert_eq!(docked.panes[0].height_weight, 3.0);
    assert!(docked.dock.is_some(), "reweighting a stack undocked its lane");
}

// ---- the order is remembered ------------------------------------------------

/// The plain case, and the sentence it is taken from.
#[test]
fn an_undocked_lane_returns_to_the_spot_it_left() {
    let core = Core::open_in_memory().unwrap();
    for t in ["a", "b", "c", "d", "e"] {
        lane(&core, t);
    }
    let c = core.state().unwrap().lanes[2].id.clone();

    core.dock_lane(c.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    assert_eq!(strip(&core), ["a", "b", "d", "e"], "the docked lane still occupies a slot");

    core.undock_lane(c).unwrap();
    assert_eq!(strip(&core), ["a", "b", "c", "d", "e"]);
}

/// Lanes created on both sides of the remembered position while the lane is
/// docked. A stored ordinal would still be *a* number here; the question is
/// whether it is still the right one.
#[test]
fn lanes_created_either_side_do_not_move_the_remembered_spot() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c", "d"].iter().map(|t| lane(&core, t)).collect();
    let c = ids[2].clone();

    core.dock_lane(c.clone(), DockSide::Right, DockMode::Inset, None).unwrap();

    // Two arrivals before the remembered spot and two after it.
    for (t, at) in [("a2", &ids[0]), ("b2", &ids[1]), ("d2", &ids[3])] {
        let st = core
            .create_lane(
                Placement::RightOf { lane_id: at.clone() },
                PaneKind::Web,
                None,
                Some("https://x".into()),
                None,
            )
            .unwrap();
        let new = st.lanes.iter().find(|l| l.title.is_none()).unwrap().id.clone();
        core.set_lane_title(new, Some(t.into())).unwrap();
    }
    assert_eq!(strip(&core), ["a", "a2", "b", "b2", "d", "d2"]);

    core.undock_lane(c).unwrap();
    assert_eq!(
        strip(&core),
        ["a", "a2", "b", "b2", "c", "d", "d2"],
        "c came back somewhere other than between b2 and d"
    );
}

/// Both former neighbours closed while the lane was docked. There is no "same
/// spot" left to name by its neighbours — only by the order, which is why the
/// lane never leaves it.
#[test]
fn a_lane_whose_neighbours_are_gone_still_returns_in_order() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c", "d", "e"].iter().map(|t| lane(&core, t)).collect();
    let c = ids[2].clone();

    core.dock_lane(c.clone(), DockSide::Left, DockMode::Overlay, None).unwrap();
    core.close_lane(ids[1].clone()).unwrap(); // b
    core.close_lane(ids[3].clone()).unwrap(); // d
    assert_eq!(strip(&core), ["a", "e"]);

    core.undock_lane(c).unwrap();
    assert_eq!(strip(&core), ["a", "c", "e"]);
}

/// The ordinals renormalised underneath it. `ordinal.rs` has a 30-insert budget
/// in one gap before `between` gives up and the whole strip is renumbered — so
/// this forces it rather than asserting it cannot happen. A remembered ordinal
/// would be a number from the old numbering, pointing at nothing.
#[test]
fn a_renormalize_underneath_a_docked_lane_does_not_move_it() {
    let core = Core::open_in_memory().unwrap();
    let first = lane(&core, "first");
    let docked = lane(&core, "docked");
    lane(&core, "last");

    core.dock_lane(docked.clone(), DockSide::Right, DockMode::Inset, None).unwrap();
    let before = core.lane(docked.clone()).unwrap().ordinal;

    // Subdivide one gap past the budget. The 31st insert cannot find a midpoint
    // and renumbers every lane, the docked one included.
    for _ in 0..31 {
        core.create_lane(
            Placement::RightOf { lane_id: first.clone() },
            PaneKind::Web,
            None,
            Some("https://filler".into()),
            None,
        )
        .unwrap();
    }
    let after = core.lane(docked.clone()).unwrap().ordinal;
    assert_ne!(before, after, "the test proved nothing: no renormalize happened");

    core.undock_lane(docked).unwrap();
    let titles = strip(&core);
    let d = titles.iter().position(|t| t == "docked").expect("the docked lane did not come back");
    assert_eq!(titles[0], "first");
    assert_eq!(titles[d + 1], "last", "the docked lane came back on the wrong side of the fillers");
    assert_eq!(d, titles.len() - 2);
}

#[test]
fn a_dock_survives_a_restart_and_undocks_to_the_same_spot() {
    let dir = tempfile::tempdir().unwrap();
    let docked = {
        let core = Core::open(db(&dir)).unwrap();
        for t in ["a", "b", "c", "d"] {
            lane(&core, t);
        }
        let id = core.state().unwrap().lanes[1].id.clone();
        core.dock_lane(id.clone(), DockSide::Left, DockMode::Overlay, Some(360)).unwrap();
        id
        // No flush, no close, no goodbye.
    };

    let core = Core::open(db(&dir)).unwrap();
    let dock = dock_of(&core, &docked).expect("the dock did not survive a restart");
    assert_eq!(dock.side, DockSide::Left);
    assert_eq!(dock.mode, DockMode::Overlay);
    assert_eq!(dock.width_pt, 360);
    assert_eq!(strip(&core), ["a", "c", "d"]);

    core.undock_lane(docked).unwrap();
    assert_eq!(strip(&core), ["a", "b", "c", "d"]);
}

/// ⌘⇧← / ⌘⇧→ move a lane past the lane beside it on screen, and a docked lane
/// is not beside anything. Nudging past one would be a keystroke that appears
/// to do nothing.
#[test]
fn nudging_steps_over_a_docked_lane_rather_than_swapping_with_it() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c"].iter().map(|t| lane(&core, t)).collect();
    core.dock_lane(ids[1].clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    assert_eq!(strip(&core), ["a", "c"]);

    core.nudge_lane(ids[0].clone(), true).unwrap();
    assert_eq!(strip(&core), ["c", "a"], "one press should have moved a past c");
}

#[test]
fn nudging_a_docked_lane_does_nothing() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c"].iter().map(|t| lane(&core, t)).collect();
    core.dock_lane(ids[1].clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    let before = core.lane(ids[1].clone()).unwrap().ordinal;

    core.nudge_lane(ids[1].clone(), true).unwrap();
    core.nudge_lane(ids[1].clone(), false).unwrap();

    assert_eq!(core.lane(ids[1].clone()).unwrap().ordinal, before);
    core.undock_lane(ids[1].clone()).unwrap();
    assert_eq!(strip(&core), ["a", "b", "c"]);
}

// ---- two docks, one per side ------------------------------------------------

#[test]
fn both_edges_can_be_occupied_at_once() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c"].iter().map(|t| lane(&core, t)).collect();
    core.dock_lane(ids[0].clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.dock_lane(ids[2].clone(), DockSide::Right, DockMode::Overlay, None).unwrap();

    assert_eq!(strip(&core), ["b"]);
    assert_eq!(core.docked_lane(DockSide::Left).unwrap().unwrap().id, ids[0]);
    assert_eq!(core.docked_lane(DockSide::Right).unwrap().unwrap().id, ids[2]);
}

/// The two docks are independent. *"another option should allow the pinned pane
/// to hover over the strip, or reduce the space of the strip"* is a per-dock
/// option, so one edge may float while the other takes its width out of the
/// strip.
#[test]
fn the_two_docks_carry_their_own_mode_and_width() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b"].iter().map(|t| lane(&core, t)).collect();
    core.dock_lane(ids[0].clone(), DockSide::Left, DockMode::Overlay, Some(300)).unwrap();
    core.dock_lane(ids[1].clone(), DockSide::Right, DockMode::Inset, Some(500)).unwrap();

    assert_eq!(dock_of(&core, &ids[0]).unwrap(), Dock {
        side: DockSide::Left,
        mode: DockMode::Overlay,
        width_pt: 300
    });
    assert_eq!(dock_of(&core, &ids[1]).unwrap().mode, DockMode::Inset);
    assert_eq!(dock_of(&core, &ids[1]).unwrap().width_pt, 500);
}

/// Docking to an occupied edge displaces the incumbent rather than failing.
/// The user pressed dock-left on this lane; the alternative is a keystroke that
/// refuses, with the reason off screen.
///
/// The displaced lane must land exactly where undocking it by hand would have
/// put it, or docking something else silently loses someone's place.
#[test]
fn docking_to_an_occupied_edge_returns_the_incumbent_to_its_own_spot() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c", "d"].iter().map(|t| lane(&core, t)).collect();

    core.dock_lane(ids[1].clone(), DockSide::Left, DockMode::Inset, Some(300)).unwrap();
    assert_eq!(strip(&core), ["a", "c", "d"]);

    core.dock_lane(ids[2].clone(), DockSide::Left, DockMode::Overlay, Some(400)).unwrap();

    assert!(dock_of(&core, &ids[1]).is_none(), "two lanes are docked to the left edge");
    assert_eq!(dock_of(&core, &ids[2]).unwrap().width_pt, 400);
    assert_eq!(strip(&core), ["a", "b", "d"], "the displaced lane did not land where it left");
}

/// Displacing the incumbent must not disturb the *other* edge.
#[test]
fn taking_one_edge_leaves_the_other_alone() {
    let core = Core::open_in_memory().unwrap();
    let ids: Vec<String> = ["a", "b", "c"].iter().map(|t| lane(&core, t)).collect();
    core.dock_lane(ids[0].clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.dock_lane(ids[1].clone(), DockSide::Right, DockMode::Inset, None).unwrap();

    core.dock_lane(ids[2].clone(), DockSide::Left, DockMode::Inset, None).unwrap();

    assert_eq!(core.docked_lane(DockSide::Right).unwrap().unwrap().id, ids[1]);
    assert_eq!(core.docked_lane(DockSide::Left).unwrap().unwrap().id, ids[2]);
}

/// Moving a docked lane to the other edge is one call, not undock-then-dock,
/// and it must not leave the lane holding both.
#[test]
fn a_docked_lane_can_change_sides() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.dock_lane(id.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.dock_lane(id.clone(), DockSide::Right, DockMode::Inset, None).unwrap();

    assert!(core.docked_lane(DockSide::Left).unwrap().is_none());
    assert_eq!(core.docked_lane(DockSide::Right).unwrap().unwrap().id, id);
}

// ---- width ------------------------------------------------------------------

/// The dock's width and the lane's strip width are two numbers, and both are
/// remembered. Dragging a dock narrow must not overwrite a lane width the user
/// chose deliberately, and undocking must give that width back.
#[test]
fn the_dock_width_and_the_lane_width_are_remembered_separately() {
    let dir = tempfile::tempdir().unwrap();
    let id = {
        let core = Core::open(db(&dir)).unwrap();
        let id = lane(&core, "player");
        core.set_lane_width(id.clone(), 800).unwrap();
        core.dock_lane(id.clone(), DockSide::Right, DockMode::Inset, None).unwrap();
        // Docking must not reflow the page, so the dock is born at the width
        // the lane already had.
        assert_eq!(dock_of(&core, &id).unwrap().width_pt, 800);
        core.set_dock_width(id.clone(), 320).unwrap();
        id
    };

    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(dock_of(&core, &id).unwrap().width_pt, 320, "the dragged dock width did not persist");
    assert_eq!(core.lane(id.clone()).unwrap().width_pt, 800, "the dock width overwrote the lane width");

    core.undock_lane(id.clone()).unwrap();
    assert_eq!(core.lane(id).unwrap().width_pt, 800);
}

/// A dock is not a lane, so it is not held to §8's 420 pt floor — the floor
/// exists so a terminal grid stays readable, and the owner's stated case is a
/// music player. It has a floor of its own so a dock cannot be dragged down to
/// something too small to grab.
#[test]
fn dock_width_is_clamped_to_the_dock_bounds_not_the_lane_bounds() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.dock_lane(id.clone(), DockSide::Left, DockMode::Inset, Some(300)).unwrap();
    assert_eq!(dock_of(&core, &id).unwrap().width_pt, 300, "300 pt is legal for a dock");

    core.set_dock_width(id.clone(), 10).unwrap();
    assert_eq!(dock_of(&core, &id).unwrap().width_pt, laned_core::DOCK_MIN_PT);

    core.set_dock_width(id.clone(), 5_000).unwrap();
    assert_eq!(dock_of(&core, &id).unwrap().width_pt, laned_core::DOCK_MAX_PT);
}

#[test]
fn the_mode_can_be_changed_without_re_docking() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.dock_lane(id.clone(), DockSide::Left, DockMode::Inset, Some(400)).unwrap();
    core.set_dock_mode(id.clone(), DockMode::Overlay).unwrap();

    let dock = dock_of(&core, &id).unwrap();
    assert_eq!(dock.mode, DockMode::Overlay);
    assert_eq!(dock.side, DockSide::Left, "changing mode moved the dock");
    assert_eq!(dock.width_pt, 400, "changing mode resized the dock");
}

/// Editing a dock is editing something that exists. A keystroke aimed at the
/// wrong lane must not hand it an edge of the screen.
#[test]
fn mode_and_width_are_refused_on_a_lane_that_is_not_docked() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "ordinary");
    assert!(core.set_dock_mode(id.clone(), DockMode::Overlay).is_err());
    assert!(core.set_dock_width(id.clone(), 400).is_err());
    assert!(core.lane(id).unwrap().dock.is_none());
}

/// The one caller is a toggle, and a toggle that throws on the half of its
/// range that is already correct has a bug in every call site.
#[test]
fn undocking_a_lane_that_is_not_docked_is_a_no_op() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "ordinary");
    core.undock_lane(id.clone()).unwrap();
    assert_eq!(strip(&core), ["ordinary"]);
}

#[test]
fn closing_a_docked_lane_frees_the_edge() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.dock_lane(id.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.close_lane(id).unwrap();
    assert!(core.docked_lane(DockSide::Left).unwrap().is_none());
}

// ---- gather -----------------------------------------------------------------

/// Gather narrows the strip, and a docked lane is not in the strip.
///
/// The failure this stops is not subtle: the shell retires lane views for
/// anything missing from the snapshot, so a docked lane filtered out by ⌘G is a
/// destroyed `WKWebView` — the music stops because the user looked at a project.
/// The layout could not prevent it, because it would be doing exactly what the
/// snapshot told it.
#[test]
fn a_docked_lane_survives_a_gather_view_it_is_not_part_of() {
    let core = Core::open_in_memory().unwrap();
    let music = lane(&core, "music");
    let work = lane(&core, "work");
    core.set_manual_tag(work, Some("/src/thing".into())).unwrap();
    core.dock_lane(music.clone(), DockSide::Left, DockMode::Overlay, None).unwrap();

    let st = core.gather("/src/thing".into()).unwrap();
    assert!(
        st.lanes.iter().any(|l| l.id == music),
        "the dock fell out of the snapshot, so the shell would retire its view"
    );
    assert_eq!(strip(&core), ["work"], "gather stopped filtering the strip");
}

/// The other half: a docked lane in the gathered project is not listed twice.
#[test]
fn a_docked_lane_in_the_gathered_project_appears_once() {
    let core = Core::open_in_memory().unwrap();
    let music = lane(&core, "music");
    core.set_manual_tag(music.clone(), Some("/src/thing".into())).unwrap();
    core.dock_lane(music.clone(), DockSide::Left, DockMode::Inset, None).unwrap();

    let st = core.gather("/src/thing".into()).unwrap();
    assert_eq!(st.lanes.iter().filter(|l| l.id == music).count(), 1);
}

// ---- the eviction guarantee -------------------------------------------------

fn budgets(used: u64) -> MemoryReport {
    MemoryReport {
        web_content_rss_bytes: used,
        soft_budget_bytes: 9 * GB,
        hard_budget_bytes: 12 * GB,
        // Everything the policy is allowed to take.
        target_bytes: 1,
        pane_footprints: Vec::new(),
    }
}

fn action_for(plan: &[PaneDirective], lane_id: &str) -> PaneAction {
    plan.iter().find(|d| d.lane_id == lane_id).expect("no directive for that lane").action
}

/// The owner's use case, end to end through the real ledger: a page playing
/// music, docked at the left edge, while the strip is scrolled forty lanes away
/// and WebKit is over the hard mark.
///
/// The hard mark is used rather than sustained soft pressure because it is the
/// emergency path — no sample count, no cooldown — and it is the one that would
/// find any hole in the protection first.
#[test]
fn a_docked_lane_is_never_evicted_or_unparented_under_the_hard_mark() {
    let core = Core::open_in_memory().unwrap();
    let music = lane(&core, "music");
    for i in 0..40 {
        lane(&core, &format!("l{i}"));
    }
    core.dock_lane(music.clone(), DockSide::Left, DockMode::Overlay, None).unwrap();

    // The strip lays out 40 lanes; the user is at the far end of them.
    let vp = Viewport { first_visible: 37, last_visible: 39 };
    let plan = core.plan_eviction(vp, budgets(100 * GB)).unwrap();

    assert_eq!(action_for(&plan, &music), PaneAction::Keep, "the music lane was not left alone");
    assert!(
        plan.iter().any(|d| d.action == PaneAction::Evict),
        "the test proved nothing: the policy evicted nothing at all"
    );
}

/// The other half of the guarantee, and the one a reader is likelier to doubt:
/// undocking gives the lane back to the ordinary policy. Protection follows
/// from the dock rather than being written beside it, so there is no flag left
/// behind to leak.
#[test]
fn undocking_returns_the_lane_to_the_ordinary_policy() {
    let core = Core::open_in_memory().unwrap();
    let music = lane(&core, "music");
    for i in 0..40 {
        lane(&core, &format!("l{i}"));
    }
    core.dock_lane(music.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.undock_lane(music.clone()).unwrap();

    // 41 laid-out lanes now, with music back at index 0.
    let vp = Viewport { first_visible: 38, last_visible: 40 };
    let plan = core.plan_eviction(vp, budgets(100 * GB)).unwrap();
    assert_eq!(action_for(&plan, &music), PaneAction::Evict);
}

/// Docking does not write `keep_live`, so undocking cannot clear a flag the
/// user set by hand.
#[test]
fn docking_and_undocking_leave_keep_live_exactly_as_the_user_set_it() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "player");
    core.set_keep_live(id.clone(), true).unwrap();

    core.dock_lane(id.clone(), DockSide::Right, DockMode::Inset, None).unwrap();
    assert!(core.lane(id.clone()).unwrap().keep_live);
    core.undock_lane(id.clone()).unwrap();
    assert!(core.lane(id).unwrap().keep_live, "undocking cleared a flag it never set");
}

// ---- export / import --------------------------------------------------------

#[test]
fn a_dock_travels_with_an_exported_strip() {
    let core = Core::open_in_memory().unwrap();
    let left = lane(&core, "music");
    lane(&core, "middle");
    let right = lane(&core, "notes");
    core.dock_lane(left, DockSide::Left, DockMode::Overlay, Some(280)).unwrap();
    core.dock_lane(right, DockSide::Right, DockMode::Inset, Some(500)).unwrap();
    let json = core.export_strip().unwrap();

    let elsewhere = Core::open_in_memory().unwrap();
    elsewhere.import_strip(json).unwrap();

    let l = elsewhere.docked_lane(DockSide::Left).unwrap().unwrap();
    assert_eq!(l.title.as_deref(), Some("music"));
    assert_eq!(l.dock.unwrap(), Dock { side: DockSide::Left, mode: DockMode::Overlay, width_pt: 280 });
    let r = elsewhere.docked_lane(DockSide::Right).unwrap().unwrap();
    assert_eq!(r.dock.unwrap().width_pt, 500);
    assert_eq!(strip(&elsewhere), ["middle"]);
}

/// Import is a merge, not a replacement — its own doc comment says so — and
/// kicking the user's music player off the screen to install one from a file is
/// the destructive reading of that.
#[test]
fn an_import_never_displaces_a_dock_that_is_already_there() {
    let core = Core::open_in_memory().unwrap();
    let mine = lane(&core, "mine");
    core.dock_lane(mine.clone(), DockSide::Left, DockMode::Inset, Some(333)).unwrap();

    let source = Core::open_in_memory().unwrap();
    let theirs = lane(&source, "theirs");
    source.dock_lane(theirs, DockSide::Left, DockMode::Overlay, Some(444)).unwrap();

    core.import_strip(source.export_strip().unwrap()).unwrap();

    let held = core.docked_lane(DockSide::Left).unwrap().unwrap();
    assert_eq!(held.id, mine);
    assert_eq!(held.dock.unwrap().width_pt, 333);
    assert_eq!(strip(&core), ["theirs"], "the imported lane vanished instead of joining the strip");
}

/// A hand-edited file with two lanes claiming one edge is merged, not refused:
/// the first takes the edge and the second joins the strip. The ledger's unique
/// index would otherwise turn a typo into a failed import.
#[test]
fn two_lanes_claiming_one_edge_in_a_file_do_not_fail_the_import() {
    let json = r#"{
        "format":"maxpane.strip","version":1,
        "lanes":[
          {"width_pt":400,"dock":{"side":"left","mode":"inset","width_pt":300},
           "title":"first","panes":[{"kind":"web","url":"https://a"}]},
          {"width_pt":400,"dock":{"side":"left","mode":"inset","width_pt":300},
           "title":"second","panes":[{"kind":"web","url":"https://b"}]}
        ]
    }"#;
    let core = Core::open_in_memory().unwrap();
    core.import_strip(json.into()).unwrap();

    assert_eq!(core.docked_lane(DockSide::Left).unwrap().unwrap().title.as_deref(), Some("first"));
    assert_eq!(strip(&core), ["second"]);
}

/// A file written before this feature, which is every file anyone has. `pinned`
/// meant what `keep_live` means, so it is read rather than dropped.
#[test]
fn an_older_export_still_carries_its_protection_flag() {
    let json = r#"{
        "format":"maxpane.strip","version":1,
        "lanes":[{"width_pt":700,"pinned":true,"span":1,
                  "panes":[{"kind":"web","url":"https://old"}]}]
    }"#;
    let core = Core::open_in_memory().unwrap();
    let st = core.import_strip(json.into()).unwrap();
    assert!(st.lanes[0].keep_live, "an old export lost the flag it was written with");
    assert!(st.lanes[0].dock.is_none());
}

/// And the other direction, for one release: a strip exported by this build is
/// read correctly by the build already on disk, which knows only `pinned`.
#[test]
fn an_export_is_still_readable_by_a_build_that_only_knows_pinned() {
    let core = Core::open_in_memory().unwrap();
    let id = lane(&core, "protected");
    core.set_keep_live(id, true).unwrap();
    assert!(core.export_strip().unwrap().contains("\"pinned\": true"));
}

// ---- migration --------------------------------------------------------------

/// The migration lands on a ledger with a strip in it — which is every ledger
/// but the one on a machine that has never run the app — and the column it
/// renames is one that already carries a value someone set.
#[test]
fn the_migration_lands_on_a_populated_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let (kept, ordinary) = seed_a_pre_dock_ledger(Path::new(&path));

    let core = Core::open(path).unwrap();
    let st = core.state().unwrap();

    assert_eq!(st.lanes.len(), 2);
    assert_eq!(st.lanes[0].id, kept);
    assert_eq!(st.lanes[0].title.as_deref(), Some("the pinned one"));
    assert_eq!(st.lanes[0].width_pt, 700);
    assert_eq!(st.lanes[0].span, 2);
    assert!(st.lanes[0].keep_live, "the flag lost its value in the rename");
    assert!(!st.lanes[1].keep_live);
    assert_eq!(st.lanes[1].id, ordinary);
    assert_eq!(st.lanes[0].panes[0].url.as_deref(), Some("https://example.com/old"));
    assert_eq!(st.lanes[0].panes[0].zoom, 1.25, "0006's zoom did not survive 0007");

    // Nothing is docked on a ledger that predates docking. An upgrade that
    // invented a dock would hand a third of the screen to a lane nobody chose.
    assert!(st.lanes.iter().all(|l| l.dock.is_none()));

    // And docking works on it.
    core.dock_lane(ordinary.clone(), DockSide::Right, DockMode::Inset, Some(400)).unwrap();
    assert_eq!(core.docked_lane(DockSide::Right).unwrap().unwrap().id, ordinary);
}

/// A migration that re-runs an `ALTER TABLE … RENAME COLUMN` fails on the
/// second launch after a release, when there is no `pinned` left to rename —
/// and by then it is on someone's machine.
#[test]
fn the_migration_runs_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let (kept, _) = seed_a_pre_dock_ledger(Path::new(&path));
    for _ in 0..3 {
        let core = Core::open(path.clone()).unwrap();
        assert!(core.lane(kept.clone()).unwrap().keep_live);
    }
}

/// The unique index is the guarantee that two lanes cannot hold one edge, so it
/// is worth proving it exists rather than trusting the API that respects it.
#[test]
fn the_ledger_itself_refuses_two_lanes_on_one_edge() {
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let ids = {
        let core = Core::open(path.clone()).unwrap();
        let a = lane(&core, "a");
        let b = lane(&core, "b");
        core.dock_lane(a.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
        (a, b)
    };

    // Straight past the API, the way a future caller or a repair script would.
    let conn = rusqlite::Connection::open(&path).unwrap();
    let err = conn
        .execute(
            "UPDATE lane SET dock_side = 'left', dock_mode = 'inset', dock_width_pt = 400 WHERE id = ?1",
            rusqlite::params![ids.1],
        )
        .unwrap_err();
    assert!(format!("{err}").contains("UNIQUE"), "{err}");
}

/// A ledger as it was before this piece: migrations 0001–0006 applied by hand,
/// with a pinned lane, an ordinary one, a span and a zoom in it.
///
/// Built from the SQL the crate ships rather than from a checked-in fixture, so
/// it cannot drift from what a real 0006 ledger looks like.
fn seed_a_pre_dock_ledger(path: &Path) -> (String, String) {
    let conn = rusqlite::Connection::open(path).unwrap();
    conn.pragma_update(None, "foreign_keys", "ON").unwrap();
    conn.execute(
        "CREATE TABLE schema_migration (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
        [],
    )
    .unwrap();
    for (name, sql) in [
        ("0001_initial", include_str!("../migrations/0001_initial.sql")),
        ("0002_lane_span", include_str!("../migrations/0002_lane_span.sql")),
        ("0003_session_and_recents", include_str!("../migrations/0003_session_and_recents.sql")),
        ("0004_history", include_str!("../migrations/0004_history.sql")),
        ("0005_pane_height", include_str!("../migrations/0005_pane_height.sql")),
        ("0006_pane_zoom", include_str!("../migrations/0006_pane_zoom.sql")),
    ] {
        conn.execute_batch(sql).unwrap();
        conn.execute(
            "INSERT INTO schema_migration (name, applied_at) VALUES (?1, 0)",
            rusqlite::params![name],
        )
        .unwrap();
    }

    let kept = "01OLDPINNED0000000000000000";
    let ordinary = "01OLDPLAIN00000000000000000";
    conn.execute(
        "INSERT INTO lane (id, ordinal, width_pt, title, project_root, project_source,
                           created_at, last_focus_at, pinned, span)
         VALUES (?1, 0.0, 700, 'the pinned one', NULL, 'inherited', 1, 1, 1, 2)",
        rusqlite::params![kept],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO lane (id, ordinal, width_pt, title, project_root, project_source,
                           created_at, last_focus_at, pinned, span)
         VALUES (?1, 1024.0, 656, 'an ordinary one', NULL, 'inherited', 1, 1, 0, 1)",
        rusqlite::params![ordinary],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO pane (id, lane_id, position, kind, url, state, height_weight, zoom)
         VALUES ('01OLDPANE00000000000000000', ?1, 0, 'web', 'https://example.com/old', 'live', 1, 1.25)",
        rusqlite::params![kept],
    )
    .unwrap();
    (kept.to_string(), ordinary.to_string())
}
