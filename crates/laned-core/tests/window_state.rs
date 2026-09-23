//! The window's last state (ADR-0036): one `app_state` key the shell writes
//! and reads back as it is. The core does not parse it — screens are the
//! shell's — so what is checked here is only that the ledger keeps it, that a
//! ledger never told reads as nothing (the first launch), and that the last
//! write wins.

use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

#[test]
fn a_fresh_ledger_remembers_no_window() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(core.window_state().unwrap(), None);
}

#[test]
fn the_last_write_survives_a_reopen() {
    let dir = tempfile::tempdir().unwrap();
    {
        let core = Core::open(db(&dir)).unwrap();
        core.set_window_state(r#"{"fullscreen":true}"#.into()).unwrap();
        core.set_window_state(r#"{"fullscreen":false,"frame":[10,20,1600,1000],"screen":"1"}"#.into())
            .unwrap();
    }
    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(
        core.window_state().unwrap().as_deref(),
        Some(r#"{"fullscreen":false,"frame":[10,20,1600,1000],"screen":"1"}"#)
    );
}
