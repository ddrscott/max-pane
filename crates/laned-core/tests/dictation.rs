//! Dictation history's table (ADR-0049): what is kept, what never is, the
//! same text moving to the top, the cap, and deletion.

use laned_core::model::*;
use laned_core::Core;

fn terminal(core: &Core) -> String {
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    st.lanes.last().unwrap().panes[0].id.clone()
}

fn contents(core: &Core) -> Vec<String> {
    core.dictation_history(200).unwrap().into_iter().map(|d| d.content).collect()
}

#[test]
fn entries_are_listed_newest_first() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    assert!(core.record_dictation(pane.clone(), "fix the tests".into(), 200).unwrap());
    assert!(core.record_dictation(pane, "then ship it\nand tell me".into(), 200).unwrap());
    assert_eq!(contents(&core), ["then ship it\nand tell me", "fix the tests"]);
}

#[test]
fn an_edit_is_a_new_entry_and_the_original_stays() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    core.record_dictation(pane.clone(), "run the build".into(), 200).unwrap();
    core.record_dictation(pane, "run the release build".into(), 200).unwrap();
    assert_eq!(contents(&core), ["run the release build", "run the build"]);
}

#[test]
fn the_same_text_again_moves_to_the_top() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    for text in ["a", "b", "a"] {
        core.record_dictation(pane.clone(), text.into(), 200).unwrap();
    }
    assert_eq!(contents(&core), ["a", "b"]);
}

#[test]
fn blank_huge_private_unknown_and_off_are_refused() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    assert!(!core.record_dictation(pane.clone(), "  \n\t".into(), 200).unwrap());
    assert!(!core.record_dictation(pane.clone(), "x".repeat(64 * 1024 + 1), 200).unwrap());
    assert!(!core.record_dictation(pane.clone(), "said with history off".into(), 0).unwrap());
    assert!(!core.record_dictation("no-such-pane".into(), "to nowhere".into(), 200).unwrap());
    let st = core.create_private_web_lane(Placement::End, "https://mail.example/".into(), None, None).unwrap();
    let private = st.lanes.last().unwrap().panes[0].id.clone();
    assert!(!core.record_dictation(private, "said in private".into(), 200).unwrap());
    assert!(contents(&core).is_empty());
}

#[test]
fn a_secret_shape_is_kept_as_said() {
    // Speech, not a paste: a recalled entry that came back as `•••` would be
    // no use, and nobody reads a token aloud by accident.
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    let text = "sk-abcdefghijklmnopqrstuvwxyz";
    assert!(core.record_dictation(pane, text.into(), 200).unwrap());
    assert_eq!(contents(&core), [text]);
}

#[test]
fn the_cap_keeps_the_newest() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    for n in 0..5 {
        core.record_dictation(pane.clone(), format!("entry {n}"), 3).unwrap();
    }
    assert_eq!(contents(&core), ["entry 4", "entry 3", "entry 2"]);
    // A smaller cap at read time ages the rest away.
    let two: Vec<String> = core.dictation_history(2).unwrap().into_iter().map(|d| d.content).collect();
    assert_eq!(two, ["entry 4", "entry 3"]);
}

#[test]
fn a_deleted_entry_is_gone() {
    let core = Core::open_in_memory().unwrap();
    let pane = terminal(&core);
    core.record_dictation(pane.clone(), "keep".into(), 200).unwrap();
    core.record_dictation(pane, "drop".into(), 200).unwrap();
    let drop = core.dictation_history(200).unwrap()[0].id;
    core.delete_dictation(drop).unwrap();
    assert_eq!(contents(&core), ["keep"]);
}
