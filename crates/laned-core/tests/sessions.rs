//! A Relay session is on the strip at most once.
//!
//! The owner's ledger held six lanes on one session, five of them created inside
//! three seconds. The doors that attach a session — the sidebar and the ⌘O
//! picker — asked "is it already on the strip?" of a snapshot a gather view had
//! narrowed, so a session tagged elsewhere looked unattached, a click attached
//! it again, and the new lane was hidden by the same gather. These pin the
//! core's half: the refusal, and a lane list that no filter can narrow.

use laned_core::model::*;
use laned_core::Core;

fn pty(core: &Core, session: Option<&str>) -> Result<String, String> {
    core.create_lane(Placement::End, PaneKind::Pty, session.map(Into::into), None, None)
        .map(|st| st.lanes.last().unwrap().id.clone())
        .map_err(|e| e.to_string())
}

fn web(core: &Core, url: &str) -> String {
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some(url.into()), None).unwrap();
    st.lanes.last().unwrap().id.clone()
}

fn panes_on(core: &Core, session: &str) -> usize {
    core.all_lanes()
        .unwrap()
        .iter()
        .flat_map(|l| &l.panes)
        .filter(|p| p.relay_session_id.as_deref() == Some(session))
        .count()
}

#[test]
fn a_session_already_on_the_strip_does_not_get_a_second_lane() {
    let core = Core::open_in_memory().unwrap();
    pty(&core, Some("s1")).unwrap();

    let refused = pty(&core, Some("s1")).unwrap_err();
    assert!(refused.contains("already on the strip"), "{refused}");
    assert_eq!(panes_on(&core, "s1"), 1);
    assert_eq!(core.state().unwrap().lanes.len(), 1, "the refused attach still wrote a lane");
}

#[test]
fn nor_a_second_pane_in_someone_elses_stack() {
    let core = Core::open_in_memory().unwrap();
    pty(&core, Some("s1")).unwrap();
    let docs = web(&core, "https://docs");

    let refused = core.add_pane(docs, PaneKind::Pty, Some("s1".into()), None);
    assert!(refused.is_err());
    assert_eq!(panes_on(&core, "s1"), 1);
}

/// The case that produced the owner's five lanes, reproduced: the session's lane
/// is tagged one project, a gather is showing another, and the attach arrives.
#[test]
fn a_gather_that_hides_the_lane_does_not_hide_it_from_the_check() {
    let core = Core::open_in_memory().unwrap();
    let agent = pty(&core, Some("s1")).unwrap();
    core.set_manual_tag(agent.clone(), Some("/src/max-pane".into())).unwrap();
    let docs = web(&core, "https://docs");
    core.set_manual_tag(docs, Some("/src/trifecta".into())).unwrap();

    let gathered = core.gather("/src/trifecta".into()).unwrap();
    assert!(gathered.lanes.iter().all(|l| l.id != agent), "the gather did not hide the lane");

    for _ in 0..5 {
        assert!(pty(&core, Some("s1")).is_err());
    }
    core.ungather().unwrap();
    assert_eq!(panes_on(&core, "s1"), 1);
}

#[test]
fn all_lanes_is_the_strip_a_gather_is_not_showing() {
    let core = Core::open_in_memory().unwrap();
    let agent = pty(&core, Some("s1")).unwrap();
    core.set_manual_tag(agent.clone(), Some("/src/max-pane".into())).unwrap();
    let docs = web(&core, "https://docs");
    core.set_manual_tag(docs.clone(), Some("/src/trifecta".into())).unwrap();

    let shown: Vec<String> = core.gather("/src/trifecta".into()).unwrap().lanes.into_iter().map(|l| l.id).collect();
    let every: Vec<String> = core.all_lanes().unwrap().into_iter().map(|l| l.id).collect();
    assert_eq!(shown, [docs.clone()]);
    assert_eq!(every, [agent, docs], "all_lanes narrowed with the gather, or lost ordinal order");
}

#[test]
fn a_pty_lane_with_no_session_is_not_a_session() {
    let core = Core::open_in_memory().unwrap();
    pty(&core, None).unwrap();
    pty(&core, None).expect("two sessionless lanes were treated as one session");
}

#[test]
fn closing_the_lane_lets_the_session_back_on() {
    let core = Core::open_in_memory().unwrap();
    let lane = pty(&core, Some("s1")).unwrap();
    core.close_lane(lane).unwrap();
    pty(&core, Some("s1")).expect("a closed lane still held its session");
}
