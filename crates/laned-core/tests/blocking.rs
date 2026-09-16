//! Which sites the ad blocker is switched off for.
//!
//! The rule list itself is the shell's cache of a downloaded file and is not
//! in the ledger; the *decision* to let a site's ads through is, so that it
//! survives a restart and a throwaway instance starts with none.

use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

#[test]
fn nothing_is_exempt_until_somebody_says_so() {
    let core = Core::open_in_memory().unwrap();
    assert!(core.blocking_exempt_domains().unwrap().is_empty());
    // Turning on a site that was never off is not an error: on is the default,
    // and the absence of a row already says it.
    core.set_blocking_exempt("example.com".into(), false).unwrap();
    assert!(core.blocking_exempt_domains().unwrap().is_empty());
}

#[test]
fn an_exemption_survives_a_restart_and_is_one_row_however_often_it_is_said() {
    let dir = tempfile::tempdir().unwrap();
    {
        let core = Core::open(db(&dir)).unwrap();
        let before = core.revision();
        core.set_blocking_exempt("YouTube.com".into(), true).unwrap();
        core.set_blocking_exempt("youtube.com ".into(), true).unwrap();
        core.set_blocking_exempt("news.example".into(), true).unwrap();
        assert_eq!(core.revision(), before, "no snapshot: the pane reloads itself");
    }
    let core = Core::open(db(&dir)).unwrap();
    // Lowercased and trimmed on the way in, so the shell's comparison is a
    // plain string equality; sorted, so the list reads the same every time.
    assert_eq!(core.blocking_exempt_domains().unwrap(), vec!["news.example", "youtube.com"]);

    core.set_blocking_exempt("youtube.com".into(), false).unwrap();
    drop(core);
    let core = Core::open(db(&dir)).unwrap();
    assert_eq!(core.blocking_exempt_domains().unwrap(), vec!["news.example"]);
}
