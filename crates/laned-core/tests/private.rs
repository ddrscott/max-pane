//! A private web lane: on the strip while it stands, in no record once it is
//! gone.
//!
//! Two promises, taken literally. While the lane is up, `state()` renders it
//! like any other and nothing a page does in it reaches history or the
//! session blob. Once the process ends — with the lane still open, because
//! that is the case a `kill -9` leaves — the next open has never heard of it.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

fn private_lane(core: &Core, url: &str) -> Lane {
    let st = core.create_private_web_lane(Placement::End, url.into(), None, None).unwrap();
    st.lanes.last().unwrap().clone()
}

fn web_lane(core: &Core, url: &str) -> Lane {
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some(url.into()), None).unwrap();
    st.lanes.last().unwrap().clone()
}

#[test]
fn a_private_lane_is_on_the_strip_and_says_so() {
    let core = Core::open_in_memory().unwrap();
    let lane = private_lane(&core, "https://mail.example/");
    assert!(lane.is_private);
    assert_eq!(lane.panes.len(), 1);
    assert_eq!(lane.panes[0].kind, PaneKind::Web);
    assert_eq!(lane.panes[0].url.as_deref(), Some("https://mail.example/"));
    assert_eq!(lane.panes[0].data_store_id.as_deref(), Some(format!("private:{}", lane.id).as_str()));
    // Focused, the way every new lane is.
    assert_eq!(core.state().unwrap().focused_pane_id.as_deref(), Some(lane.panes[0].id.as_str()));
    // And an ordinary lane is not private, before and after it.
    assert!(!web_lane(&core, "https://docs.example/").is_private);
}

#[test]
fn a_private_visit_never_reaches_history() {
    let core = Core::open_in_memory().unwrap();
    let private = private_lane(&core, "https://mail.example/");
    let public = web_lane(&core, "https://docs.example/");

    core.record_visit(
        private.panes[0].id.clone(),
        "https://mail.example/inbox".into(),
        Some("Inbox".into()),
        vec!["https://mail.example/login".into()],
    )
    .unwrap();
    assert!(core.history(String::new(), 10).unwrap().is_empty(), "a private visit landed in the pages table");
    assert!(core.history("inbox".into(), 10).unwrap().is_empty());

    // The same call from the lane beside it records, so the refusal is about
    // the lane and not a broken recorder.
    core.record_visit(public.panes[0].id.clone(), "https://docs.example/a".into(), Some("A".into()), vec![])
        .unwrap();
    let urls: Vec<String> = core.history(String::new(), 10).unwrap().into_iter().map(|e| e.url).collect();
    assert_eq!(urls, vec!["https://docs.example/a"]);
}

#[test]
fn a_private_pane_keeps_no_session_blob() {
    let core = Core::open_in_memory().unwrap();
    let private = private_lane(&core, "https://mail.example/");
    let public = web_lane(&core, "https://docs.example/");

    core.set_pane_interaction_state(private.panes[0].id.clone(), Some(vec![1, 2, 3])).unwrap();
    assert_eq!(core.pane_interaction_state(private.panes[0].id.clone()).unwrap(), None);

    core.set_pane_interaction_state(public.panes[0].id.clone(), Some(vec![1, 2, 3])).unwrap();
    assert_eq!(core.pane_interaction_state(public.panes[0].id.clone()).unwrap(), Some(vec![1, 2, 3]));
}

#[test]
fn a_split_in_a_private_lane_is_private_too() {
    let core = Core::open_in_memory().unwrap();
    let private = private_lane(&core, "https://mail.example/");
    let st = core
        .add_pane(private.id.clone(), PaneKind::Web, None, Some("https://mail.example/b".into()))
        .unwrap();
    let lane = st.lanes.iter().find(|l| l.id == private.id).unwrap();
    assert_eq!(lane.panes.len(), 2);
    assert_eq!(lane.panes[1].data_store_id, lane.panes[0].data_store_id, "the split got a jar of its own");
    core.record_visit(lane.panes[1].id.clone(), "https://mail.example/b".into(), None, vec![]).unwrap();
    assert!(core.history(String::new(), 10).unwrap().is_empty());
}

#[test]
fn a_private_lane_is_gone_at_the_next_open() {
    let dir = tempfile::tempdir().unwrap();
    let public_id;
    {
        let core = Core::open(db(&dir)).unwrap();
        public_id = web_lane(&core, "https://docs.example/").id;
        let private = private_lane(&core, "https://mail.example/");
        // A grant decided under the private jar goes with the lane.
        core.set_site_permission(
            format!("private:{}", private.id),
            "https://mail.example".into(),
            SiteFeature::Camera,
            true,
        )
        .unwrap();
        // One under a real jar does not.
        core.set_site_permission("shard-0".into(), "https://docs.example".into(), SiteFeature::Camera, true)
            .unwrap();
        assert_eq!(core.state().unwrap().lanes.len(), 2);
        // No close, no goodbye: the lane is still up when the process ends.
    }

    let core = Core::open(db(&dir)).unwrap();
    let st = core.state().unwrap();
    assert_eq!(st.lanes.iter().map(|l| l.id.as_str()).collect::<Vec<_>>(), vec![public_id.as_str()]);
    assert!(core.all_lanes().unwrap().iter().all(|l| !l.is_private));
    assert!(core
        .site_permissions(format!("private:{}", "anything"), SiteFeature::Camera)
        .unwrap()
        .is_empty());
    assert_eq!(core.site_permissions("shard-0".into(), SiteFeature::Camera).unwrap().len(), 1);
    // The panes went with the lane, not just the row above them: the focused
    // pane is one that exists.
    let focused = st.focused_pane_id.expect("a focused pane");
    assert!(st.lanes.iter().flat_map(|l| &l.panes).any(|p| p.id == focused));
}

#[test]
fn a_sibling_opened_from_a_private_pane_shares_its_jar() {
    let core = Core::open_in_memory().unwrap();
    let opener = private_lane(&core, "https://mail.example/");
    let jar = opener.panes[0].data_store_id.clone().unwrap();
    let st = core
        .create_private_web_lane(
            Placement::RightOf { lane_id: opener.id.clone() },
            "https://mail.example/thread".into(),
            Some(opener.id.clone()),
            Some(jar.clone()),
        )
        .unwrap();
    assert_eq!(st.lanes.len(), 2);
    let sibling = &st.lanes[1];
    assert!(sibling.is_private);
    assert_eq!(sibling.panes[0].data_store_id.as_deref(), Some(jar.as_str()));
}

#[test]
fn closing_a_private_lane_removes_it() {
    let core = Core::open_in_memory().unwrap();
    let private = private_lane(&core, "https://mail.example/");
    let st = core.close_lane(private.id.clone()).unwrap();
    assert!(st.lanes.is_empty());
}
