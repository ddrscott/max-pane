//! Where the keyboard goes when the focused pane closes.
//!
//! The rule reads up, then left: the pane above, else the new top pane, else
//! the bottom pane of the nearest lane on the strip to the left, else to the
//! right. It is what makes ⌘D, run a thing, ⌘W land back where you started.
//! "On the strip" is the same test a sidebar collapse hands focus by: not
//! docked, not hidden, inside the gather.

use laned_core::model::*;
use laned_core::Core;

/// A terminal lane at the end of the strip, titled `name`, and its id.
fn lane(core: &Core, name: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Pty, Some(name.into()), None, None)
        .unwrap();
    let id = st.lanes.last().unwrap().id.clone();
    core.set_lane_title(id.clone(), Some(name.into())).unwrap();
    id
}

/// ⌘D: one more pane at the bottom of `lane_id`'s stack, and its id.
fn split(core: &Core, lane_id: &str, name: &str) -> String {
    let st = core.add_pane(lane_id.into(), PaneKind::Pty, Some(name.into()), None).unwrap();
    st.lanes.iter().find(|l| l.id == lane_id).unwrap().panes.last().unwrap().id.clone()
}

fn panes(core: &Core, lane_id: &str) -> Vec<String> {
    core.lane(lane_id.into()).unwrap().panes.iter().map(|p| p.id.clone()).collect()
}

/// The session name of the focused pane, which every helper here names panes by.
fn focused(core: &Core) -> String {
    let id = core.state().unwrap().focused_pane_id.expect("something has focus");
    core.all_lanes()
        .unwrap()
        .into_iter()
        .flat_map(|l| l.panes)
        .find(|p| p.id == id)
        .and_then(|p| p.relay_session_id)
        .unwrap_or_else(|| format!("<gone: {id}>"))
}

#[test]
fn split_then_close_lands_back_where_the_split_was_made() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    let b = lane(&core, "b");
    let _c = lane(&core, "c");
    let start = panes(&core, &b)[0].clone();
    core.focus_pane(start.clone()).unwrap();

    let new = split(&core, &b, "b2");
    assert_eq!(core.state().unwrap().focused_pane_id.as_deref(), Some(new.as_str()), "⌘D focuses the split");
    core.close_pane(new).unwrap();
    assert_eq!(core.state().unwrap().focused_pane_id, Some(start.clone()));

    // Again from the bottom of a stack of two.
    let below = split(&core, &a, "a2");
    core.focus_pane(below.clone()).unwrap();
    let new = split(&core, &a, "a3");
    core.close_pane(new).unwrap();
    assert_eq!(core.state().unwrap().focused_pane_id, Some(below));
}

#[test]
fn the_middle_pane_hands_up_and_the_top_pane_hands_to_the_new_top() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "top");
    split(&core, &a, "middle");
    split(&core, &a, "bottom");
    let ids = panes(&core, &a);

    core.focus_pane(ids[1].clone()).unwrap();
    core.close_pane(ids[1].clone()).unwrap();
    assert_eq!(focused(&core), "top");

    core.close_pane(ids[0].clone()).unwrap();
    assert_eq!(focused(&core), "bottom", "the pane that was below is now on top");
}

#[test]
fn a_lanes_last_pane_hands_to_the_bottom_of_the_lane_to_its_left() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a-top");
    split(&core, &a, "a-bottom");
    let b = lane(&core, "b");
    let _c = lane(&core, "c");
    let only = panes(&core, &b)[0].clone();
    core.focus_pane(only.clone()).unwrap();

    let st = core.close_pane(only).unwrap();
    assert_eq!(st.lanes.len(), 2, "the lane went with its last pane");
    assert_eq!(focused(&core), "a-bottom");
}

#[test]
fn the_leftmost_lanes_last_pane_hands_to_the_bottom_of_the_lane_to_its_right() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    let b = lane(&core, "b-top");
    split(&core, &b, "b-bottom");
    let only = panes(&core, &a)[0].clone();
    core.focus_pane(only.clone()).unwrap();

    core.close_pane(only).unwrap();
    assert_eq!(focused(&core), "b-bottom");
}

#[test]
fn hidden_docked_and_gathered_out_lanes_are_never_heirs() {
    let core = Core::open_in_memory().unwrap();
    let far = lane(&core, "far");
    let hidden = lane(&core, "hidden");
    let docked = lane(&core, "docked");
    let other = lane(&core, "other-project");
    let closing = lane(&core, "closing");
    let right = lane(&core, "right");
    for id in [&far, &hidden, &docked, &closing, &right] {
        core.set_manual_tag(id.to_string(), Some("/src/foo".into())).unwrap();
    }
    core.set_manual_tag(other.clone(), Some("/src/bar".into())).unwrap();
    core.set_hidden_lanes(vec![hidden.clone()], false).unwrap();
    core.dock_lane(docked.clone(), DockSide::Left, DockMode::Inset, None).unwrap();
    core.gather("/src/foo".into()).unwrap();

    let pane = panes(&core, &closing)[0].clone();
    core.focus_pane(pane.clone()).unwrap();
    core.close_pane(pane).unwrap();
    assert_eq!(focused(&core), "far", "skipped the other project, the dock and the hidden lane");

    // Nothing left of `right` that is on the strip but `far`; with `far` gone
    // too the heir is to the right, and the skipped lanes are still skipped.
    core.close_pane(panes(&core, &far)[0].clone()).unwrap();
    assert_eq!(focused(&core), "right");
}

#[test]
fn closing_an_unfocused_pane_leaves_focus_alone() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a-top");
    split(&core, &a, "a-bottom");
    let b = lane(&core, "b");
    let a_panes = panes(&core, &a);
    core.focus_pane(a_panes[1].clone()).unwrap();

    core.close_pane(panes(&core, &b)[0].clone()).unwrap();
    assert_eq!(focused(&core), "a-bottom");
    core.close_pane(a_panes[0].clone()).unwrap();
    assert_eq!(focused(&core), "a-bottom");
}

#[test]
fn a_docks_stack_hands_up_inside_the_dock_and_its_last_pane_hands_back_to_the_strip() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    let b = lane(&core, "b");
    let dock = lane(&core, "dock-top");
    split(&core, &dock, "dock-bottom");
    core.dock_lane(dock.clone(), DockSide::Right, DockMode::Inset, None).unwrap();

    // `a` is the strip lane that last had the keyboard, though `b` is nearer.
    core.focus_pane(panes(&core, &b)[0].clone()).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(3));
    core.focus_pane(panes(&core, &a)[0].clone()).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(3));

    let dp = panes(&core, &dock);
    core.focus_pane(dp[1].clone()).unwrap();
    core.close_pane(dp[1].clone()).unwrap();
    assert_eq!(focused(&core), "dock-top");

    core.close_pane(dp[0].clone()).unwrap();
    assert_eq!(focused(&core), "a");
}

#[test]
fn the_last_pane_anywhere_leaves_nothing_to_focus() {
    let core = Core::open_in_memory().unwrap();
    let a = lane(&core, "a");
    let only = panes(&core, &a)[0].clone();
    core.focus_pane(only.clone()).unwrap();
    let st = core.close_pane(only).unwrap();
    assert!(st.lanes.is_empty());
}
