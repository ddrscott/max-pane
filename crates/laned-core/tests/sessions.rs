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

// ---- one namespace per server (ADR-0020) ----------------------------------

fn remote(core: &Core, server: &str, session: &str) -> Result<String, String> {
    core.attach_remote_session(Placement::End, server.into(), session.into(), None)
        .map(|st| st.lanes.last().unwrap().id.clone())
        .map_err(|e| e.to_string())
}

/// Ids are eight hex characters minted per machine. The same id on two
/// servers is two sessions, and neither one is the local session of that id.
#[test]
fn the_same_id_on_two_servers_is_two_sessions() {
    let core = Core::open_in_memory().unwrap();
    pty(&core, Some("0368d543")).unwrap();
    remote(&core, "yorkshire", "0368d543").unwrap();
    remote(&core, "alien", "0368d543").unwrap();

    let lanes = core.all_lanes().unwrap();
    assert_eq!(lanes.len(), 3);
    let servers: Vec<Option<String>> = lanes.iter().map(|l| l.panes[0].relay_server.clone()).collect();
    assert_eq!(servers, vec![None, Some("yorkshire".into()), Some("alien".into())]);
    assert!(lanes.iter().all(|l| l.panes[0].relay_session_id.as_deref() == Some("0368d543")));
}

#[test]
fn a_remote_session_already_on_the_strip_is_refused_on_its_own_server_only() {
    let core = Core::open_in_memory().unwrap();
    remote(&core, "yorkshire", "0368d543").unwrap();

    let refused = remote(&core, "yorkshire", "0368d543").unwrap_err();
    assert!(refused.contains("0368d543 on yorkshire is already on the strip"), "{refused}");
    assert_eq!(core.all_lanes().unwrap().len(), 1);

    // The refusal is keyed on the pair, in a split too.
    let docs = web(&core, "https://docs");
    assert!(core.add_remote_pane(docs.clone(), "yorkshire".into(), "0368d543".into()).is_err());
    core.add_remote_pane(docs, "alien".into(), "0368d543".into()).unwrap();
    assert_eq!(panes_on(&core, "0368d543"), 2);
}

/// The relay_server column survives a close and reopen: a remote lane comes
/// back knowing which box it is on, which is what lets the shell attach it
/// over the right transport at launch.
#[test]
fn a_remote_lane_survives_a_relaunch() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.sqlite");
    {
        let core = Core::open(path.to_str().unwrap().into()).unwrap();
        remote(&core, "yorkshire", "0368d543").unwrap();
    }
    let core = Core::open(path.to_str().unwrap().into()).unwrap();
    let lanes = core.all_lanes().unwrap();
    assert_eq!(lanes.len(), 1);
    assert_eq!(lanes[0].panes[0].relay_server.as_deref(), Some("yorkshire"));
    assert_eq!(lanes[0].panes[0].relay_session_id.as_deref(), Some("0368d543"));
}

/// A remote cwd is only a path on the remote machine: the tag is `host:path`,
/// never the result of walking this machine's tree for it.
#[test]
fn a_remote_lane_is_tagged_host_path_without_walking_the_local_tree() {
    let core = Core::open_in_memory().unwrap();
    let lane = remote(&core, "yorkshire", "0368d543").unwrap();
    // A directory that is a git repository *here*: the walk would find it.
    let here = env!("CARGO_MANIFEST_DIR").to_string();

    assert!(core.observe_cwd(lane.clone(), here.clone()).unwrap());
    let tagged = core.all_lanes().unwrap()[0].clone();
    assert_eq!(tagged.project_root, Some(format!("yorkshire:{here}")));
    assert_eq!(tagged.project_source, ProjectSource::Cwd);

    // Unchanged cwd is a no-op, as for a local lane.
    assert!(!core.observe_cwd(lane.clone(), here).unwrap());

    // And a local lane in the same directory does not share the tag.
    let local = pty(&core, Some("aaaaaaaa")).unwrap();
    core.observe_cwd(local, env!("CARGO_MANIFEST_DIR").into()).unwrap();
    let roots: Vec<Option<String>> = core.all_lanes().unwrap().iter().map(|l| l.project_root.clone()).collect();
    assert_ne!(roots[0], roots[1]);
    assert!(roots[1].as_deref().map(|r| !r.contains(':')).unwrap_or(false), "{roots:?}");
}
