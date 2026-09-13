//! Moving a pane from one lane to another.
//!
//! The drop half of a pane drag. Everything here is about the two things a
//! reparent can silently get wrong and nothing on screen would show until the
//! next launch: `position` left sparse or duplicated in either lane, and a
//! column left on the strip with nothing in it.
//!
//! One level of nesting is the invariant underneath all of it — lanes hold
//! panes and panes hold nothing — so there is no recursive case to test and
//! `a_pane_never_holds_a_pane` says why that is a fact about the schema rather
//! than a rule anyone has to keep.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// A terminal lane at the end of the strip, and its id.
fn lane(core: &Core, name: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Pty, Some(name.into()), None, None)
        .unwrap();
    let id = st.lanes.last().unwrap().id.clone();
    core.set_lane_title(id.clone(), Some(name.into())).unwrap();
    id
}

/// One more pane at the bottom of `lane_id`'s stack, and its id.
fn pane(core: &Core, lane_id: &str, name: &str) -> String {
    let st = core.add_pane(lane_id.into(), PaneKind::Pty, Some(name.into()), None).unwrap();
    st.lanes
        .iter()
        .find(|l| l.id == lane_id)
        .unwrap()
        .panes
        .last()
        .unwrap()
        .id
        .clone()
}

/// The only pane of a freshly made lane.
fn only_pane(core: &Core, lane_id: &str) -> String {
    core.lane(lane_id.into()).unwrap().panes[0].id.clone()
}

/// Every lane's session names, top to bottom, in strip order.
fn strip(core: &Core) -> Vec<Vec<String>> {
    core.state()
        .unwrap()
        .lanes
        .iter()
        .map(|l| l.panes.iter().map(|p| p.relay_session_id.clone().unwrap_or_default()).collect())
        .collect()
}

/// `position` is dense and ascending in every lane. Asserted after every move,
/// because a hole in it is invisible until `lanes()` next sorts on it.
fn positions_are_dense(core: &Core) {
    for lane in core.state().unwrap().lanes {
        let got: Vec<u32> = lane.panes.iter().map(|p| p.position).collect();
        let want: Vec<u32> = (0..lane.panes.len() as u32).collect();
        assert_eq!(got, want, "lane {} has a hole in its stack", lane.id);
    }
}

#[test]
fn a_pane_moves_into_another_lanes_stack_at_the_index_it_was_given() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let left = lane(&core, "a");
    pane(&core, &left, "b");
    let right = lane(&core, "x");
    pane(&core, &right, "y");
    let moved = only_pane(&core, &right);

    // Between the two panes already in the left-hand lane.
    core.move_pane(moved, left.clone(), 1).unwrap();

    assert_eq!(strip(&core), vec![vec!["a", "x", "b"], vec!["y"]]);
    positions_are_dense(&core);
}

#[test]
fn the_lane_a_pane_was_the_last_of_is_gone() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let keep = lane(&core, "a");
    let empty = lane(&core, "solo");
    let moved = only_pane(&core, &empty);

    let st = core.move_pane(moved, keep.clone(), 0).unwrap();

    assert_eq!(st.lanes.len(), 1, "an empty column was left on the strip");
    assert_eq!(strip(&core), vec![vec!["solo", "a"]]);
}

#[test]
fn a_reorder_inside_one_lane_leaves_every_weight_bit_identical() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = lane(&core, "a");
    pane(&core, &id, "b");
    pane(&core, &id, "c");
    // A stack somebody has arranged by hand.
    core.set_pane_heights(
        core.lane(id.clone())
            .unwrap()
            .panes
            .iter()
            .zip([3.0, 1.0, 2.0])
            .map(|(p, w)| PaneHeight { pane_id: p.id.clone(), weight: w })
            .collect(),
    )
    .unwrap();
    let before: Vec<(String, f64)> = core
        .lane(id.clone())
        .unwrap()
        .panes
        .iter()
        .map(|p| (p.relay_session_id.clone().unwrap(), p.height_weight))
        .collect();

    let top = core.lane(id.clone()).unwrap().panes[0].id.clone();
    core.move_pane(top, id.clone(), 2).unwrap();

    let after: Vec<(String, f64)> = core
        .lane(id.clone())
        .unwrap()
        .panes
        .iter()
        .map(|p| (p.relay_session_id.clone().unwrap(), p.height_weight))
        .collect();
    assert_eq!(strip(&core), vec![vec!["b", "c", "a"]]);
    // Same weights, attached to the same panes, in the new order.
    for (name, weight) in &before {
        let found = after.iter().find(|(n, _)| n == name).unwrap();
        assert_eq!(found.1.to_bits(), weight.to_bits(), "{name}'s share was rewritten");
    }
    positions_are_dense(&core);
}

#[test]
fn a_pane_joining_another_lane_takes_the_mean_of_that_stack() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let target = lane(&core, "a");
    pane(&core, &target, "b");
    core.set_pane_heights(
        core.lane(target.clone())
            .unwrap()
            .panes
            .iter()
            .zip([7.0, 3.0])
            .map(|(p, w)| PaneHeight { pane_id: p.id.clone(), weight: w })
            .collect(),
    )
    .unwrap();

    let source = lane(&core, "x");
    let moved = only_pane(&core, &source);
    core.move_pane(moved.clone(), target.clone(), 2).unwrap();

    let got = core
        .lane(target.clone())
        .unwrap()
        .panes
        .into_iter()
        .find(|p| p.id == moved)
        .unwrap()
        .height_weight;
    assert_eq!(got, 5.0, "the arrival did not take the mean of the stack it joined");
    // And the two that were already there still stand in 7:3.
    let stack = core.lane(target).unwrap().panes;
    assert_eq!(stack[0].height_weight, 7.0);
    assert_eq!(stack[1].height_weight, 3.0);
}

#[test]
fn a_pane_pulled_out_lands_in_a_lane_of_its_own_where_it_was_dropped() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let left = lane(&core, "a");
    let stacked = pane(&core, &left, "b");
    let right = lane(&core, "x");

    // Dropped in the gap to the left of the right-hand lane.
    core.move_pane_to_new_lane(stacked, Placement::LeftOf { lane_id: right }).unwrap();

    assert_eq!(strip(&core), vec![vec!["a"], vec!["b"], vec!["x"]]);
    positions_are_dense(&core);
    // It is a lane of one, at the width the column it came out of had.
    let lanes = core.state().unwrap().lanes;
    assert_eq!(lanes[1].panes.len(), 1);
    assert_eq!(lanes[1].width_pt, lanes[0].width_pt);
    assert_eq!(lanes[1].panes[0].height_weight, 1.0);
}

#[test]
fn pulling_out_the_only_pane_of_a_lane_moves_the_lane_rather_than_rebuilding_it() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let first = lane(&core, "a");
    let solo = lane(&core, "solo");
    let last = lane(&core, "z");
    core.set_lane_width(solo.clone(), 880).unwrap();
    core.set_keep_live(solo.clone(), true).unwrap();
    let moved = only_pane(&core, &solo);

    core.move_pane_to_new_lane(moved, Placement::LeftOf { lane_id: first }).unwrap();

    let lanes = core.state().unwrap().lanes;
    assert_eq!(lanes.len(), 3, "a lane was rebuilt instead of moved");
    // Same lane row: same id, and everything the lane carries came with it.
    assert_eq!(lanes[0].id, solo);
    assert_eq!(lanes[0].title.as_deref(), Some("solo"));
    assert_eq!(lanes[0].width_pt, 880);
    assert!(lanes[0].keep_live);
    assert_eq!(lanes[2].id, last);
}

#[test]
fn a_lane_dragged_out_of_a_dock_stops_holding_the_edge() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let first = lane(&core, "a");
    let music = lane(&core, "music");
    core.dock_lane(music.clone(), DockSide::Right, DockMode::Inset, None).unwrap();
    let moved = only_pane(&core, &music);

    core.move_pane_to_new_lane(moved, Placement::LeftOf { lane_id: first }).unwrap();

    let lanes = core.state().unwrap().lanes;
    assert_eq!(lanes[0].id, music);
    assert!(lanes[0].dock.is_none(), "the lane was dropped in the strip and stayed at the wall");
}

#[test]
fn dropping_a_lane_of_one_against_itself_changes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    lane(&core, "a");
    let solo = lane(&core, "solo");
    lane(&core, "z");
    let moved = only_pane(&core, &solo);
    let before = core.state().unwrap();

    core.move_pane_to_new_lane(moved, Placement::LeftOf { lane_id: solo.clone() }).unwrap();
    core.move_pane_to_new_lane(only_pane(&core, &solo), Placement::RightOf { lane_id: solo })
        .unwrap();

    let after = core.state().unwrap();
    assert_eq!(before.lanes, after.lanes);
}

#[test]
fn the_moved_pane_is_the_one_holding_the_keyboard() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let target = lane(&core, "a");
    let source = lane(&core, "x");
    let stacked = pane(&core, &source, "y");
    // Focus is somewhere else entirely.
    core.focus_pane(only_pane(&core, &target)).unwrap();

    let st = core.move_pane(stacked.clone(), target.clone(), 0).unwrap();

    assert_eq!(st.focused_pane_id.as_deref(), Some(stacked.as_str()));
}

#[test]
fn moving_onto_a_lane_that_is_gone_writes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = lane(&core, "a");
    pane(&core, &id, "b");
    let before = core.state().unwrap();

    assert!(core.move_pane(only_pane(&core, &id), "no-such-lane".into(), 0).is_err());

    assert_eq!(core.state().unwrap().lanes, before.lanes);
}

#[test]
fn an_index_past_the_end_of_the_stack_lands_at_the_bottom() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let target = lane(&core, "a");
    pane(&core, &target, "b");
    let source = lane(&core, "x");

    core.move_pane(only_pane(&core, &source), target, 99).unwrap();

    assert_eq!(strip(&core), vec![vec!["a", "b", "x"]]);
    positions_are_dense(&core);
}

#[test]
fn a_move_survives_a_kill_9() {
    // The same proof `durability.rs` uses: drop the Core with no shutdown path
    // and reopen the file. A move is a layout change, and PRD §6 says a kill -9
    // may cost pixels and may not cost order.
    let dir = tempfile::tempdir().unwrap();
    let path = db(&dir);
    let want = {
        let core = Core::open(path.clone()).unwrap();
        let left = lane(&core, "a");
        pane(&core, &left, "b");
        let right = lane(&core, "x");
        pane(&core, &right, "y");
        core.move_pane(only_pane(&core, &right), left, 1).unwrap();
        strip(&core)
    };

    let core = Core::open(path).unwrap();
    assert_eq!(strip(&core), want);
    positions_are_dense(&core);
}

#[test]
fn a_pane_never_holds_a_pane() {
    // One level of nesting, stated as the thing that makes it true: a pane's
    // only parent column is `lane_id`, which names a row in `lane`. There is no
    // shape in the schema a recursive split could be written into, so nothing
    // above here has to refuse one.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = lane(&core, "a");
    let stacked = pane(&core, &id, "b");
    assert!(core.move_pane(stacked.clone(), stacked, 0).is_err());
}
