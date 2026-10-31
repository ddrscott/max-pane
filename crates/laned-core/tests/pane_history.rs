//! Back and forward through focus, as the shell drives them: `focus_pane` and
//! `note_focus` for going somewhere, a step and then a focus for going back.
//! The list's own rules are tested beside it, in `src/pane_history.rs`.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// A new lane, which takes focus the way ⌘O does, and its one pane.
fn pane(core: &Core, kind: PaneKind) -> String {
    let url = (kind == PaneKind::Web).then(|| "https://example.com/".to_owned());
    core.create_lane(Placement::End, kind, None, url, None).unwrap().lanes.last().unwrap().panes[0].id.clone()
}

/// The shell's half of a step.
fn back(core: &Core) -> Option<String> {
    let target = core.pane_history_back().unwrap()?;
    core.focus_pane(target.clone()).unwrap();
    Some(target)
}

fn forward(core: &Core) -> Option<String> {
    let target = core.pane_history_forward().unwrap()?;
    core.note_focus(target.clone()).unwrap();
    Some(target)
}

fn focused(core: &Core) -> Option<String> {
    core.state().unwrap().focused_pane_id
}

#[test]
fn opening_clicking_and_keys_all_count_and_terminals_and_pages_mix() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let a = pane(&core, PaneKind::Pty);
    let b = pane(&core, PaneKind::Web);
    let c = pane(&core, PaneKind::Pty);
    core.note_focus(a.clone()).unwrap();
    core.focus_pane(b.clone()).unwrap();

    assert_eq!(back(&core), Some(a.clone()));
    assert_eq!(back(&core), Some(c.clone()));
    assert_eq!(back(&core), Some(b.clone()));
    assert_eq!(back(&core), Some(a.clone()));
    assert_eq!(back(&core), None, "the far end does nothing");
    assert_eq!(focused(&core), Some(a.clone()));
    assert_eq!(forward(&core), Some(b.clone()));
}

#[test]
fn back_then_forward_comes_home_without_growing_it() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let a = pane(&core, PaneKind::Pty);
    let b = pane(&core, PaneKind::Pty);
    for _ in 0..5 {
        assert_eq!(back(&core), Some(a.clone()));
        assert_eq!(forward(&core), Some(b.clone()));
    }
    assert_eq!(forward(&core), None);
    assert_eq!(back(&core), Some(a.clone()));
    assert_eq!(back(&core), None, "five round trips left two entries");
}

#[test]
fn focusing_by_hand_after_going_back_drops_forward() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let a = pane(&core, PaneKind::Pty);
    let b = pane(&core, PaneKind::Pty);
    let c = pane(&core, PaneKind::Pty);
    back(&core);
    back(&core);
    core.note_focus(c.clone()).unwrap();
    assert_eq!(forward(&core), None);
    assert_eq!(back(&core), Some(a));
    assert_ne!(focused(&core), Some(b));
}

#[test]
fn a_closed_pane_is_never_landed_on() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let a = pane(&core, PaneKind::Pty);
    let b = pane(&core, PaneKind::Web);
    let c = pane(&core, PaneKind::Pty);
    let d = pane(&core, PaneKind::Pty);
    back(&core);
    back(&core);
    back(&core); // on a, with b c d ahead
    core.close_pane(c).unwrap();
    assert_eq!(forward(&core), Some(b.clone()));
    assert_eq!(forward(&core), Some(d.clone()));
    core.close_pane(b).unwrap();
    assert_eq!(back(&core), Some(a));
}

#[test]
fn closing_the_focused_pane_counts_the_heir_as_accessed() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let a = pane(&core, PaneKind::Pty);
    let b = pane(&core, PaneKind::Pty);
    let c = pane(&core, PaneKind::Pty);
    core.close_pane(c).unwrap();
    assert_eq!(focused(&core), Some(b.clone()));
    assert_eq!(back(&core), Some(a), "closed c is skipped, b is where we are");
}

#[test]
fn every_pane_gone_is_a_quiet_no_op() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(back(&core), None);
    let a = pane(&core, PaneKind::Pty);
    core.close_pane(a).unwrap();
    assert_eq!(back(&core), None);
    assert_eq!(forward(&core), None);
}

#[test]
fn it_survives_an_unclean_exit_with_the_cursor_where_it_was() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b, c) = {
        let core = Core::open(db(&dir)).unwrap();
        let (a, b, c) = (pane(&core, PaneKind::Pty), pane(&core, PaneKind::Web), pane(&core, PaneKind::Pty));
        back(&core);
        (a, b, c)
    };
    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(focused(&core), Some(b));
    assert_eq!(forward(&core), Some(c));
    back(&core);
    assert_eq!(back(&core), Some(a));
}

#[test]
fn a_ledger_from_before_this_goes_back_to_what_was_focused() {
    // No history key is what every existing ledger has on its first launch.
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = {
        let core = Core::open(db(&dir)).unwrap();
        (pane(&core, PaneKind::Pty), pane(&core, PaneKind::Pty))
    };
    {
        let conn = rusqlite::Connection::open(db(&dir)).unwrap();
        conn.execute("DELETE FROM app_state WHERE key = 'pane_history'", []).unwrap();
    }
    let core = Core::open(db(&dir)).unwrap();
    core.note_focus(a.clone()).unwrap();
    assert_eq!(back(&core), Some(b));
    assert_eq!(forward(&core), Some(a));
}
