//! What the strip is supposed to remember between launches, beyond the layout:
//! what each web pane was doing, and what the user has launched before.
//!
//! Both are things the app used to lose on every restart — a web pane came back
//! at the top of its page with no history, and the picker had nothing to offer.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// One web lane, and the id of its pane.
fn web_pane(core: &Core, url: &str) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some(url.to_string()), None)
        .unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

// ---- browser sessions -------------------------------------------------------

#[test]
fn a_web_panes_session_survives_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    // WebKit's blob is opaque to us, so the test treats it as exactly that.
    let session: Vec<u8> = vec![0x00, 0xff, 0x10, 0x42, 0x00, 0x99];

    let pane_id = {
        let core = Core::open(db(&dir)).unwrap();
        let id = web_pane(&core, "https://example.com");
        core.set_pane_interaction_state(id.clone(), Some(session.clone())).unwrap();
        id
    };

    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(
        core.pane_interaction_state(pane_id).unwrap(),
        Some(session),
        "the pane came back without the session it was in"
    );
}

#[test]
fn a_pane_that_never_had_a_session_reports_none() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = web_pane(&core, "https://example.com");
    assert_eq!(core.pane_interaction_state(id).unwrap(), None);
}

#[test]
fn a_session_can_be_cleared() {
    // A pane that navigates somewhere unrelated should not be restored into
    // the history of the page it used to be.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = web_pane(&core, "https://example.com");
    core.set_pane_interaction_state(id.clone(), Some(vec![1, 2, 3])).unwrap();
    core.set_pane_interaction_state(id.clone(), None).unwrap();
    assert_eq!(core.pane_interaction_state(id).unwrap(), None);
}

#[test]
fn the_session_blob_stays_out_of_the_layout_snapshot() {
    // It is tens of kilobytes per pane and read once per launch. If it ever
    // joins `Pane`, every keystroke that publishes a snapshot starts copying
    // every pane's history across the FFI.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let id = web_pane(&core, "https://example.com");
    core.set_pane_interaction_state(id, Some(vec![7; 64_000])).unwrap();

    let st = core.state().unwrap();
    let pane = &st.lanes[0].panes[0];
    assert_eq!(pane.url.as_deref(), Some("https://example.com"));
    // Nothing to assert against directly — the guard is that `Pane` has no
    // field for it, so this is a compile-time fact the test pins by reading
    // every field the record does have.
    let Pane {
        id: _,
        lane_id: _,
        position: _,
        kind: _,
        relay_session_id: _,
        url: _,
        scroll_y: _,
        data_store_id: _,
        snapshot_path: _,
        state: _,
        // A ratio, eight bytes. Deliberately in the record where the session
        // blob is deliberately not: the shell needs it to lay out every frame,
        // and a `f64` per pane is the cheapest thing that crosses the FFI.
        height_weight: _,
        // Same bargain, same reason: a pane has to be built at the right scale,
        // and one that comes back at the wrong size is one you fix by hand on
        // every launch.
        zoom: _,
        // One byte, for the same reason again: the user agent is set before
        // the first request, so the shell has to know at build time.
        mobile: _,
    } = pane.clone();
}

// ---- recents ----------------------------------------------------------------

#[test]
fn recents_come_back_most_recent_first() {
    let dir = tempfile::tempdir().unwrap();

    {
        let core = Core::open(db(&dir)).unwrap();
        core.note_recent(RecentKind::Command, "htop".into(), Some("/src".into())).unwrap();
        core.note_recent(RecentKind::Url, "https://news.ycombinator.com".into(), None).unwrap();
        core.note_recent(RecentKind::Command, "npm test".into(), Some("/src/web".into())).unwrap();
    }

    let core = Core::open(db(&dir)).unwrap();
    let recents = core.recents(10).unwrap();
    assert_eq!(recents.len(), 3);
    assert_eq!(recents[0].value, "npm test");
    assert_eq!(recents[0].cwd.as_deref(), Some("/src/web"));
    assert_eq!(recents[1].kind, RecentKind::Url);
    assert_eq!(recents[2].value, "htop");
}

#[test]
fn relaunching_moves_an_entry_to_the_top_without_duplicating_it() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "htop".into(), Some("/src".into())).unwrap();
    core.note_recent(RecentKind::Command, "npm test".into(), Some("/src".into())).unwrap();
    core.note_recent(RecentKind::Command, "htop".into(), Some("/src".into())).unwrap();

    let recents = core.recents(10).unwrap();
    assert_eq!(recents.len(), 2, "the same command must not occupy two slots");
    assert_eq!(recents[0].value, "htop");
    assert_eq!(recents[0].use_count, 2);
}

#[test]
fn a_commands_directory_follows_it() {
    // `npm test` run in a different repo should offer that repo next time.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "npm test".into(), Some("/src/a".into())).unwrap();
    core.note_recent(RecentKind::Command, "npm test".into(), Some("/src/b".into())).unwrap();
    assert_eq!(core.recents(10).unwrap()[0].cwd.as_deref(), Some("/src/b"));
}

#[test]
fn the_same_text_as_a_command_and_as_a_url_are_different_entries() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "localhost:3000".into(), None).unwrap();
    core.note_recent(RecentKind::Url, "localhost:3000".into(), None).unwrap();
    assert_eq!(core.recents(10).unwrap().len(), 2);
}

#[test]
fn blank_entries_are_not_remembered() {
    // Otherwise Return on an empty picker burns a numeric shortcut on nothing.
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "   ".into(), None).unwrap();
    core.note_recent(RecentKind::Command, "".into(), None).unwrap();
    assert!(core.recents(10).unwrap().is_empty());
}

#[test]
fn surrounding_whitespace_does_not_make_a_second_entry() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "htop".into(), None).unwrap();
    core.note_recent(RecentKind::Command, "  htop  ".into(), None).unwrap();
    assert_eq!(core.recents(10).unwrap().len(), 1);
}

#[test]
fn the_limit_is_honoured() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    for i in 0..40 {
        core.note_recent(RecentKind::Command, format!("cmd {i}"), None).unwrap();
    }
    assert_eq!(core.recents(10).unwrap().len(), 10);
    assert_eq!(core.recents(10).unwrap()[0].value, "cmd 39");
}

#[test]
fn an_entry_can_be_forgotten() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    core.note_recent(RecentKind::Command, "rm -rf ~/typo".into(), None).unwrap();
    core.note_recent(RecentKind::Command, "htop".into(), None).unwrap();
    core.forget_recent(RecentKind::Command, "rm -rf ~/typo".into()).unwrap();

    let recents = core.recents(10).unwrap();
    assert_eq!(recents.len(), 1);
    assert_eq!(recents[0].value, "htop");
}

#[test]
fn an_existing_ledger_gains_both_without_losing_anything() {
    // The migration runs against a real strip, not an empty file.
    let dir = tempfile::tempdir().unwrap();
    let lane_id = {
        let core = Core::open(db(&dir)).unwrap();
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some("https://old".into()), None)
            .unwrap();
        st.lanes[0].id.clone()
    };

    let core = Core::open(db(&dir)).unwrap();
    let st = core.state().unwrap();
    assert_eq!(st.lanes[0].id, lane_id);
    assert_eq!(st.lanes[0].panes[0].url.as_deref(), Some("https://old"));
    assert!(core.recents(10).unwrap().is_empty());
    assert_eq!(core.pane_interaction_state(st.lanes[0].panes[0].id.clone()).unwrap(), None);
}
