//! Paste history's table (ADR-0031, ADR-0041): what is kept, what never is,
//! which pane it came from, caps, ageing, deletion, and that none of it
//! leaves in a strip export.

use laned_core::model::*;
use laned_core::Core;

fn terminal(core: &Core) -> String {
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

fn web(core: &Core) -> String {
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some("https://example.com/".into()), None)
        .unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

fn contents(core: &Core) -> Vec<String> {
    core.clip_history(200, 30).unwrap().into_iter().map(|c| c.content).collect()
}

#[test]
fn pastes_and_copies_are_listed_newest_first() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    assert!(core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, "/tmp/a path".into(), 200, 30).unwrap());
    assert!(core.record_clip(pane.clone(), ClipKind::Copy, ClipSource::Pty, "one\ntwo\n".into(), 200, 30).unwrap());
    let all = core.clip_history(200, 30).unwrap();
    assert_eq!(all.len(), 2);
    assert_eq!(all[0].content, "one\ntwo\n");
    assert_eq!(all[0].kind, ClipKind::Copy);
    assert_eq!(all[0].line_count, 2);
    assert_eq!(all[0].byte_count, 8);
    assert!(!all[0].redacted);
    assert_eq!(all[1].kind, ClipKind::Paste);
}

#[test]
fn a_web_pane_records_as_web_and_a_terminal_as_pty() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    let page = web(&core);
    assert!(core.record_clip(pane, ClipKind::Copy, ClipSource::Pty, "from a prompt".into(), 200, 30).unwrap());
    assert!(core.record_clip(page, ClipKind::Copy, ClipSource::Web, "from a page".into(), 200, 30).unwrap());
    let all = core.clip_history(200, 30).unwrap();
    assert_eq!(all[0].source, ClipSource::Web);
    assert_eq!(all[0].kind, ClipKind::Copy);
    assert_eq!(all[1].source, ClipSource::Pty);
}

#[test]
fn a_private_web_lane_and_a_secret_are_refused_from_a_web_pane_too() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_private_web_lane(Placement::End, "https://mail.example/".into(), None, None).unwrap();
    let private = st.lanes.last().unwrap().panes[0].id.clone();
    assert!(!core.record_clip(private, ClipKind::Copy, ClipSource::Web, "a token on a dashboard".into(), 200, 30).unwrap());
    let page = web(&core);
    let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789";
    assert!(core.record_clip(page, ClipKind::Copy, ClipSource::Web, secret.into(), 200, 30).unwrap());
    let all = core.clip_history(200, 30).unwrap();
    assert_eq!(all.len(), 1);
    assert!(all[0].redacted);
    assert_eq!(all[0].content, "ghp_•••");
    assert_eq!(all[0].source, ClipSource::Web);
}

#[test]
fn the_same_text_again_moves_to_the_top() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    for text in ["a", "b", "a"] {
        core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, text.into(), 200, 30).unwrap();
    }
    assert_eq!(contents(&core), ["a", "b"]);
    // Across panes too: one row, and it is the newer copy's.
    let page = web(&core);
    core.record_clip(page, ClipKind::Copy, ClipSource::Web, "b".into(), 200, 30).unwrap();
    let all = core.clip_history(200, 30).unwrap();
    assert_eq!(all.len(), 2);
    assert_eq!(all[0].content, "b");
    assert_eq!(all[0].source, ClipSource::Web);
}

#[test]
fn a_private_lane_and_an_unknown_pane_record_nothing() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_private_web_lane(Placement::End, "https://mail.example/".into(), None, None).unwrap();
    let private = st.lanes.last().unwrap().panes[0].id.clone();
    assert!(!core.record_clip(private, ClipKind::Paste, ClipSource::Pty, "in private".into(), 200, 30).unwrap());
    assert!(!core.record_clip("no-such-pane".into(), ClipKind::Copy, ClipSource::Pty, "from nowhere".into(), 200, 30).unwrap());
    assert!(contents(&core).is_empty());
    // The same call from an ordinary lane records: the refusal is the lane's.
    let pane = terminal(&core);
    assert!(core.record_clip(pane, ClipKind::Paste, ClipSource::Pty, "in public".into(), 200, 30).unwrap());
    assert_eq!(contents(&core), ["in public"]);
}

#[test]
fn blank_text_too_much_text_and_keep_zero_record_nothing() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    assert!(!core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, " \n".into(), 200, 30).unwrap());
    assert!(!core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, "x".repeat(64 * 1024 + 1), 200, 30).unwrap());
    assert!(core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, "x".repeat(64 * 1024), 200, 30).unwrap());
    assert!(!core.record_clip(pane, ClipKind::Paste, ClipSource::Pty, "off".into(), 0, 30).unwrap());
    assert_eq!(core.clip_history(200, 30).unwrap().len(), 1);
}

#[test]
fn a_secret_is_stored_as_four_characters_and_never_as_itself() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.db");
    let secret = "export KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx";
    {
        let core = Core::open(path.to_string_lossy().into_owned()).unwrap();
        let pane = terminal(&core);
        assert!(core.record_clip(pane, ClipKind::Paste, ClipSource::Pty, secret.into(), 200, 30).unwrap());
        let all = core.clip_history(200, 30).unwrap();
        assert_eq!(all[0].content, "expo•••");
        assert!(all[0].redacted);
        assert_eq!(all[0].byte_count, secret.len() as u64);
    }
    // Not in the file, the WAL or anything beside it.
    for entry in std::fs::read_dir(dir.path()).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        let needle = b"abcdefghijklmnopqrstuvwx";
        assert!(!bytes.windows(needle.len()).any(|w| w == needle));
    }
}

#[test]
fn the_cap_keeps_the_newest_and_the_setting_is_read_each_time() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    for i in 0..10 {
        core.record_clip(pane.clone(), ClipKind::Paste, ClipSource::Pty, format!("n{i}"), 5, 30).unwrap();
    }
    assert_eq!(contents(&core), ["n9", "n8", "n7", "n6", "n5"]);
    // A smaller cap applies at the next read.
    assert_eq!(core.clip_history(2, 30).unwrap().len(), 2);
    assert_eq!(core.clip_history(200, 30).unwrap().len(), 2);
}

#[test]
fn entries_age_out_and_zero_days_keeps_any_age() {
    use laned_core::ledger::Ledger;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.db");
    let pane = terminal(&Core::open(path.to_string_lossy().into_owned()).unwrap());
    // The ledger itself, so the test says what time it is.
    let ledger = Ledger::open(Some(&path)).unwrap();
    const DAY: i64 = 86_400_000;
    let now = 100 * DAY;
    assert!(ledger.record_clip(&pane, ClipKind::Paste, ClipSource::Pty, "old", 200, 0, now - 31 * DAY).unwrap());
    assert!(ledger.record_clip(&pane, ClipKind::Paste, ClipSource::Pty, "recent", 200, 0, now - 29 * DAY).unwrap());
    assert_eq!(ledger.clips().unwrap().len(), 2, "0 days keeps any age");
    assert_eq!(ledger.prune_clips(200, 30, now).unwrap(), 1);
    let left: Vec<String> = ledger.clips().unwrap().into_iter().map(|c| c.content).collect();
    assert_eq!(left, ["recent"]);
    // Recording prunes too: the next paste is what ages the last one out.
    assert!(ledger.record_clip(&pane, ClipKind::Copy, ClipSource::Pty, "new", 200, 30, now + 2 * DAY).unwrap());
    let left: Vec<String> = ledger.clips().unwrap().into_iter().map(|c| c.content).collect();
    assert_eq!(left, ["new"]);
}

#[test]
fn delete_removes_one_and_clear_removes_all() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    for text in ["a", "b", "c"] {
        core.record_clip(pane.clone(), ClipKind::Copy, ClipSource::Pty, text.into(), 200, 30).unwrap();
    }
    let b = core.clip_history(200, 30).unwrap()[1].id;
    core.delete_clip(b).unwrap();
    assert_eq!(contents(&core), ["c", "a"]);
    assert_eq!(core.clear_clip_history().unwrap(), 2);
    assert!(contents(&core).is_empty());
}

#[test]
fn a_strip_export_has_no_paste_history_in_it() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    core.record_clip(pane, ClipKind::Paste, ClipSource::Pty, "only-in-paste-history".into(), 200, 30).unwrap();
    let exported = core.export_strip().unwrap();
    assert!(!exported.contains("only-in-paste-history"));
}
