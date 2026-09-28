//! A terminal pane remembers the agent it was running (ADR-0046).
//!
//! A reboot kills every relay-tty session, and the pane comes back knowing only
//! a session id that no longer exists. These pin the ledger's half of getting
//! the conversation back: the record round trip, that it outlives a quit, that
//! a pane closed on purpose takes it along, and that a resume rebinds the same
//! pane rather than making a new lane.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

fn terminal(core: &Core, session: &str) -> String {
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some(session.into()), None, None).unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

fn agent(pane_id: &str, session: &str) -> PaneAgent {
    PaneAgent {
        pane_id: pane_id.into(),
        cli: "claude".into(),
        session_id: session.into(),
        cwd: "/Users/s/code/max-pane".into(),
        args: vec!["--dangerously-skip-permissions".into(), "--model".into(), "opus".into()],
        name: Some("max-pane fixes".into()),
        updated_at: 1_790_605_798_192,
    }
}

#[test]
fn a_record_reads_back_exactly_as_it_was_written() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core, "a1b2c3d4");
    assert_eq!(core.pane_agent(pane.clone()).unwrap(), None, "a pane has no agent until one is seen");

    let written = agent(&pane, "7b51d6dd-8c19-4faa-af46-45851cf3f809");
    core.record_pane_agent(written.clone()).unwrap();
    assert_eq!(core.pane_agent(pane.clone()).unwrap(), Some(written));
}

#[test]
fn a_newer_sighting_replaces_the_older_one() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core, "a1b2c3d4");
    core.record_pane_agent(agent(&pane, "first")).unwrap();
    let mut second = agent(&pane, "second");
    second.args = vec![];
    second.name = None;
    core.record_pane_agent(second.clone()).unwrap();

    assert_eq!(core.pane_agent(pane).unwrap(), Some(second));
    assert_eq!(core.pane_agents().unwrap().len(), 1, "one pane, one row");
}

#[test]
fn a_record_for_a_pane_that_is_not_there_is_refused() {
    let core = Core::open_in_memory().unwrap();
    assert!(core.record_pane_agent(agent("no-such-pane", "x")).is_err());
    assert!(core.pane_agents().unwrap().is_empty());
}

#[test]
fn forgetting_is_the_agent_exiting_and_is_quiet_about_nothing_to_forget() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core, "a1b2c3d4");
    core.forget_pane_agent(pane.clone()).unwrap();
    core.record_pane_agent(agent(&pane, "s")).unwrap();
    core.forget_pane_agent(pane.clone()).unwrap();
    assert_eq!(core.pane_agent(pane).unwrap(), None);
}

#[test]
fn the_record_survives_a_quit_and_a_relaunch() {
    let dir = tempfile::tempdir().unwrap();
    let pane = {
        let core = Core::open(db(&dir)).unwrap();
        let pane = terminal(&core, "a1b2c3d4");
        core.record_pane_agent(agent(&pane, "survivor")).unwrap();
        pane
    };
    let reopened = Core::open(db(&dir)).unwrap();
    assert_eq!(reopened.pane_agent(pane.clone()).unwrap(), Some(agent(&pane, "survivor")));
}

#[test]
fn closing_the_pane_on_purpose_takes_the_record_with_it() {
    let core = Core::open_in_memory().unwrap();
    let kept = terminal(&core, "aaaa0001");
    let closed = terminal(&core, "aaaa0002");
    core.record_pane_agent(agent(&kept, "kept")).unwrap();
    core.record_pane_agent(agent(&closed, "closed")).unwrap();

    core.close_pane(closed.clone()).unwrap();
    assert_eq!(core.pane_agent(closed).unwrap(), None);
    let lane = core.state().unwrap().lanes[0].id.clone();
    core.close_lane(lane).unwrap();
    assert_eq!(core.pane_agent(kept).unwrap(), None, "closing the lane closes its panes");
    assert!(core.pane_agents().unwrap().is_empty());
}

#[test]
fn every_record_comes_back_in_strip_order() {
    let core = Core::open_in_memory().unwrap();
    let a = terminal(&core, "aaaa0001");
    let b = terminal(&core, "aaaa0002");
    let c = terminal(&core, "aaaa0003");
    // Written out of order, and the last lane moved to the front.
    core.record_pane_agent(agent(&b, "b")).unwrap();
    core.record_pane_agent(agent(&c, "c")).unwrap();
    core.record_pane_agent(agent(&a, "a")).unwrap();
    let first = core.state().unwrap().lanes[0].id.clone();
    let lane_c = core.state().unwrap().lanes[2].id.clone();
    core.move_lane(lane_c, Placement::LeftOf { lane_id: first }).unwrap();

    let order: Vec<String> = core.pane_agents().unwrap().into_iter().map(|r| r.session_id).collect();
    assert_eq!(order, vec!["c", "a", "b"]);
}

#[test]
fn a_resume_rebinds_the_same_pane_in_place() {
    let core = Core::open_in_memory().unwrap();
    let left = terminal(&core, "aaaa0001");
    let pane = terminal(&core, "dead0001");
    let _right = terminal(&core, "aaaa0003");
    core.set_pane_zoom(pane.clone(), 1.5).unwrap();
    let before = core.state().unwrap();
    let lane_before = before.lanes[1].clone();

    let after = core.rebind_pane_session(pane.clone(), "beef0002".into(), None).unwrap();
    assert_eq!(after.lanes.len(), before.lanes.len(), "no new lane");
    let lane_after = &after.lanes[1];
    assert_eq!(lane_after.id, lane_before.id);
    assert_eq!(lane_after.ordinal, lane_before.ordinal);
    let rebound = &lane_after.panes[0];
    assert_eq!(rebound.id, pane);
    assert_eq!(rebound.relay_session_id.as_deref(), Some("beef0002"));
    assert_eq!(rebound.relay_server, None);
    assert_eq!(rebound.zoom, 1.5);
    assert!(after.revision > before.revision, "the shell hears about it");

    // The session another pane holds is refused, as every other door refuses it.
    assert!(core.rebind_pane_session(pane.clone(), "aaaa0001".into(), None).is_err());
    let _ = left;
}

#[test]
fn only_a_terminal_pane_can_be_rebound() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://example.com".into()), None).unwrap();
    let page = st.lanes[0].panes[0].id.clone();
    assert!(core.rebind_pane_session(page, "beef0002".into(), None).is_err());
}

#[test]
fn the_record_survives_its_pane_being_rebound_and_moved() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core, "dead0001");
    let other = terminal(&core, "aaaa0002");
    core.record_pane_agent(agent(&pane, "s")).unwrap();
    core.rebind_pane_session(pane.clone(), "beef0002".into(), None).unwrap();
    let target = core.state().unwrap().lanes[1].id.clone();
    core.move_pane(pane.clone(), target, 1).unwrap();
    assert_eq!(core.pane_agent(pane.clone()).unwrap(), Some(agent(&pane, "s")));
    let _ = other;
}
