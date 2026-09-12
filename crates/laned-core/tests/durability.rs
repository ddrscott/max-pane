//! The half of the PRD's acceptance tests (§15) that `laned-core` owns on its
//! own — everything about layout surviving a process that stops existing.
//!
//! `kill -9` is simulated by dropping the `Core` without any shutdown path and
//! reopening the same file. That is exactly what the app has after a crash: a
//! ledger file and nothing else.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

/// §15.1 — create 20 lanes, reorder randomly, `kill -9` → order identical.
#[test]
fn strip_order_survives_an_unclean_exit() {
    let dir = tempfile::tempdir().unwrap();

    let expected: Vec<String> = {
        let core = Core::open(db(&dir)).unwrap();
        let mut ids = Vec::new();
        for i in 0..20 {
            let placement = match ids.last() {
                Some(prev) => Placement::RightOf { lane_id: String::clone(prev) },
                None => Placement::End,
            };
            let st = core
                .create_lane(placement, PaneKind::Web, None, Some(format!("https://example.com/{i}")), None)
                .unwrap();
            ids.push(st.lanes.last().unwrap().id.clone());
        }

        // A deterministic shuffle: move every third lane to the front, then a
        // couple of one-step nudges, which is what dragging actually produces.
        for i in (0..20).step_by(3) {
            let head = core.state().unwrap().lanes[0].id.clone();
            if head == ids[i] {
                continue; // already at the front; moving it left of itself is not a move
            }
            core.move_lane(ids[i].clone(), Placement::LeftOf { lane_id: head }).unwrap();
        }
        core.nudge_lane(ids[7].clone(), true).unwrap();
        core.nudge_lane(ids[11].clone(), false).unwrap();

        let order: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
        assert_eq!(order.len(), 20);
        order
        // `core` drops here with no flush, no close, no goodbye.
    };

    let reopened = Core::open(db(&dir)).unwrap();
    let after: Vec<String> = reopened.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(after, expected, "strip order changed across an unclean exit");
}

/// §15.2 — a URL opened from a terminal becomes a web pane immediately right of
/// that terminal, carrying the terminal's project tag.
#[test]
fn a_url_from_a_terminal_lands_right_of_it_and_inherits_the_tag() {
    let core = Core::open_in_memory().unwrap();

    // Three lanes, so "immediately right" is a real claim and not just "last".
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    let term = st.lanes[0].id.clone();
    core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
    core.create_lane(Placement::End, PaneKind::Web, None, Some("https://b".into()), None).unwrap();

    core.set_manual_tag(term.clone(), Some("/Users/scott/src/foo".into())).unwrap();

    let st = core
        .create_lane(
            Placement::RightOf { lane_id: term.clone() },
            PaneKind::Web,
            None,
            Some("https://example.com".into()),
            Some(term.clone()),
        )
        .unwrap();

    let at = st.lanes.iter().position(|l| l.id == term).unwrap();
    let spawned = &st.lanes[at + 1];
    assert_eq!(spawned.panes[0].url.as_deref(), Some("https://example.com"));
    assert_eq!(spawned.project_root.as_deref(), Some("/Users/scott/src/foo"));
    assert_eq!(spawned.project_source, ProjectSource::Inherited);
}

/// §15.3 — `cd` retags the lane without moving it.
#[test]
fn retagging_never_moves_a_lane() {
    let dir = tempfile::tempdir().unwrap();
    let repo = dir.path().join("bar");
    std::fs::create_dir_all(repo.join(".git")).unwrap();
    std::fs::create_dir_all(repo.join("deep/nested")).unwrap();

    let core = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for _ in 0..5 {
        let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s".into()), None, None).unwrap();
        ids.push(st.lanes.last().unwrap().id.clone());
    }
    let target = ids[2].clone();
    let before: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();

    let changed =
        core.observe_cwd(target.clone(), repo.join("deep/nested").to_string_lossy().into_owned()).unwrap();
    assert!(changed, "first observation should set the tag");

    let st = core.state().unwrap();
    let after: Vec<String> = st.lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(after, before, "tagging moved a lane");

    let lane = st.lanes.iter().find(|l| l.id == target).unwrap();
    assert_eq!(lane.project_root, Some(repo.to_string_lossy().into_owned()));
    assert_eq!(lane.project_source, ProjectSource::Cwd);

    // Same cwd again is a no-op, so the shell can skip the render.
    assert!(!core.observe_cwd(target, repo.to_string_lossy().into_owned()).unwrap());
}

/// A manual tag is sticky: the 5-second cwd poll must not stomp it.
#[test]
fn the_cwd_tagger_does_not_overwrite_a_manual_tag() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join(".git")).unwrap();

    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s".into()), None, None).unwrap();
    let lane = st.lanes[0].id.clone();

    core.set_manual_tag(lane.clone(), Some("/my/own/label".into())).unwrap();
    let changed = core.observe_cwd(lane.clone(), dir.path().to_string_lossy().into_owned()).unwrap();

    assert!(!changed);
    let st = core.state().unwrap();
    assert_eq!(st.lanes[0].project_root.as_deref(), Some("/my/own/label"));
    assert_eq!(st.lanes[0].project_source, ProjectSource::Manual);
}

/// §15.7 — gather shows only one project's lanes, contiguous and in true
/// ordinal order; leaving it restores the strip exactly.
#[test]
fn gather_filters_without_writing_an_ordinal() {
    let core = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for i in 0..6 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        let id = st.lanes.last().unwrap().id.clone();
        // Interleave two projects so "contiguous" is a real requirement.
        let root = if i % 2 == 0 { "/src/foo" } else { "/src/bar" };
        core.set_manual_tag(id.clone(), Some(root.into())).unwrap();
        ids.push(id);
    }

    let before = core.state().unwrap();
    let ordinals_before: Vec<f64> = before.lanes.iter().map(|l| l.ordinal).collect();

    let gathered = core.gather("/src/foo".into()).unwrap();
    assert_eq!(gathered.gather_filter.as_deref(), Some("/src/foo"));
    assert_eq!(gathered.lanes.len(), 3);
    assert!(gathered.lanes.iter().all(|l| l.project_root.as_deref() == Some("/src/foo")));
    // True ordinal order, still ascending.
    assert!(gathered.lanes.windows(2).all(|w| w[0].ordinal < w[1].ordinal));

    let restored = core.ungather().unwrap();
    assert!(restored.gather_filter.is_none());
    let ids_after: Vec<String> = restored.lanes.iter().map(|l| l.id.clone()).collect();
    let ordinals_after: Vec<f64> = restored.lanes.iter().map(|l| l.ordinal).collect();
    assert_eq!(ids_after, ids, "gather changed the strip");
    assert_eq!(ordinals_after, ordinals_before, "gather wrote an ordinal");
}

/// §15.6 — an evicted pane keeps everything needed to come back.
#[test]
fn eviction_round_trips_through_the_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let pane_id = {
        let core = Core::open(db(&dir)).unwrap();
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some("https://example.com/deep".into()), None)
            .unwrap();
        let pane = st.lanes[0].panes[0].id.clone();
        core.set_pane_scroll(pane.clone(), 4200.0).unwrap();
        core.mark_evicted(pane.clone(), Some("/tmp/snap.heic".into()), Some(4200.0)).unwrap();
        pane
    };

    let core = Core::open(db(&dir)).unwrap();
    let pane = core.state().unwrap().lanes[0].panes[0].clone();
    assert_eq!(pane.id, pane_id);
    assert_eq!(pane.state, PaneState::Evicted);
    assert_eq!(pane.kind, PaneKind::Placeholder);
    assert_eq!(pane.url.as_deref(), Some("https://example.com/deep"));
    assert_eq!(pane.scroll_y, Some(4200.0));
    assert_eq!(pane.snapshot_path.as_deref(), Some("/tmp/snap.heic"));

    let st = core.mark_live(pane.id.clone()).unwrap();
    let back = &st.lanes[0].panes[0];
    assert_eq!(back.state, PaneState::Live);
    assert_eq!(back.kind, PaneKind::Web);
    assert!(back.snapshot_path.is_none());
    assert_eq!(back.scroll_y, Some(4200.0), "scroll must survive to be restored");
}

/// Closing a lane's last pane closes the lane; closing one of several does not.
#[test]
fn closing_the_last_pane_closes_its_lane() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s".into()), None, None).unwrap();
    let lane = st.lanes[0].id.clone();
    let first = st.lanes[0].panes[0].id.clone();

    let st = core.add_pane(lane.clone(), PaneKind::Web, None, Some("https://x".into())).unwrap();
    let second = st.lanes[0].panes[1].id.clone();
    assert_eq!(st.lanes[0].panes.len(), 2);

    let st = core.close_pane(second).unwrap();
    assert_eq!(st.lanes.len(), 1);
    assert_eq!(st.lanes[0].panes.len(), 1);
    assert_eq!(st.lanes[0].panes[0].position, 0);

    let st = core.close_pane(first).unwrap();
    assert!(st.lanes.is_empty(), "lane should go when its last pane does");
}

/// Widths are clamped to the PRD's bounds, whatever the drag handle reports.
#[test]
fn lane_width_is_clamped_to_the_allowed_range() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://x".into()), None).unwrap();
    let lane = st.lanes[0].id.clone();

    assert_eq!(core.set_lane_width(lane.clone(), 10).unwrap().lanes[0].width_pt, laned_core::LANE_MIN_PT);
    assert_eq!(core.set_lane_width(lane.clone(), 99_999).unwrap().lanes[0].width_pt, laned_core::LANE_MAX_PT);
    assert_eq!(core.set_lane_width(lane, 640).unwrap().lanes[0].width_pt, 640);
}

/// Scroll position and focus are app state, so they come back too.
#[test]
fn scroll_and_focus_survive_a_restart() {
    let dir = tempfile::tempdir().unwrap();
    let focused = {
        let core = Core::open(db(&dir)).unwrap();
        core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
        let st =
            core.create_lane(Placement::End, PaneKind::Web, None, Some("https://b".into()), None).unwrap();
        let pane = st.lanes[1].panes[0].id.clone();
        core.focus_pane(pane.clone()).unwrap();
        core.set_scroll_x(1337.5).unwrap();
        pane
    };

    let core = Core::open(db(&dir)).unwrap();
    let st = core.state().unwrap();
    assert_eq!(st.focused_pane_id, Some(focused));
    assert_eq!(st.scroll_x, 1337.5);
}

/// Nesting depth is 1 (§8): a lane holds panes, and that is the whole tree.
/// Deleting a lane takes its panes with it and leaves nothing dangling.
#[test]
fn deleting_a_lane_cascades_to_its_panes() {
    let dir = tempfile::tempdir().unwrap();
    let core = Core::open(db(&dir)).unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s".into()), None, None).unwrap();
    let lane = st.lanes[0].id.clone();
    core.add_pane(lane.clone(), PaneKind::Web, None, Some("https://x".into())).unwrap();
    core.add_pane(lane.clone(), PaneKind::Web, None, Some("https://y".into())).unwrap();

    core.close_lane(lane).unwrap();
    assert!(core.state().unwrap().lanes.is_empty());

    // Reopen: if the cascade had failed, orphaned panes would surface here.
    let core = Core::open(db(&dir)).unwrap();
    assert!(core.state().unwrap().lanes.is_empty());
}

/// Search finds a lane by title, by URL and by scrollback the shell pushed.
#[test]
fn search_covers_titles_urls_and_scrollback() {
    let core = Core::open_in_memory().unwrap();
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some("https://docs.rs/rusqlite".into()), None)
        .unwrap();
    let web = st.lanes[0].id.clone();
    core.set_lane_title(web, Some("rusqlite docs".into())).unwrap();

    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    let pty_pane = st.lanes[1].panes[0].id.clone();
    core.push_scrollback(pty_pane.clone(), vec!["error: could not compile laned-core".into()]);

    assert!(core.search("rusqlite".into(), 10).unwrap().iter().any(|h| h.field == SearchField::Title));
    assert!(core.search("docs.rs".into(), 10).unwrap().iter().any(|h| h.field == SearchField::Url));

    let hits = core.search("could not compile".into(), 10).unwrap();
    let hit = hits.iter().find(|h| h.field == SearchField::Scrollback).expect("no scrollback hit");
    assert_eq!(hit.pane_id, pty_pane);

    assert!(core.search("zzzznothing".into(), 10).unwrap().is_empty());
}

/// Inserting into the same gap past the ordinal budget renormalizes instead of
/// collapsing the order.
#[test]
fn repeated_inserts_at_one_spot_renormalize_and_stay_ordered() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://l".into()), None).unwrap();
    let left = st.lanes[0].id.clone();
    core.create_lane(Placement::End, PaneKind::Web, None, Some("https://r".into()), None).unwrap();

    // Well past the 30-insert budget of a single gap.
    for i in 0..60 {
        core.create_lane(
            Placement::RightOf { lane_id: left.clone() },
            PaneKind::Web,
            None,
            Some(format!("https://mid/{i}")),
            None,
        )
        .unwrap();
    }

    let st = core.state().unwrap();
    assert_eq!(st.lanes.len(), 62);
    assert!(
        st.lanes.windows(2).all(|w| w[0].ordinal < w[1].ordinal),
        "ordinals stopped being strictly ascending"
    );
    // Every insert went immediately right of `left`, so the newest is next to it.
    let at = st.lanes.iter().position(|l| l.id == left).unwrap();
    assert_eq!(st.lanes[at + 1].panes[0].url.as_deref(), Some("https://mid/59"));
}

/// The snapshot-free hot paths agree with the snapshot-building ones. Spike M3
/// added them to keep 2.4 ms of marshalling off the focus path; they are only
/// worth having if they write the same rows.
#[test]
fn note_focus_matches_focus_pane_and_bumps_the_revision() {
    let core = Core::open_in_memory().unwrap();
    core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://b".into()), None).unwrap();
    let a = st.lanes[0].panes[0].id.clone();
    let b = st.lanes[1].panes[0].id.clone();

    let before = core.revision();
    core.note_focus(a.clone()).unwrap();
    assert_eq!(core.state().unwrap().focused_pane_id, Some(a.clone()));
    assert!(core.revision() > before, "a mutation must move the revision");

    let heavy = core.focus_pane(b.clone()).unwrap();
    assert_eq!(heavy.focused_pane_id, Some(b.clone()));
    assert_eq!(heavy.revision, core.revision());

    // Both paths touch last_focus_at, which is what eviction ranks on.
    let lane_b = core.lane(st.lanes[1].id.clone()).unwrap();
    let lane_a = core.lane(st.lanes[0].id.clone()).unwrap();
    assert!(lane_b.last_focus_at >= lane_a.last_focus_at);
}

/// `lane()` returns the same lane the full snapshot does, panes and all.
#[test]
fn single_lane_read_matches_the_snapshot() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s".into()), None, None).unwrap();
    let id = st.lanes[0].id.clone();
    core.add_pane(id.clone(), PaneKind::Web, None, Some("https://x".into())).unwrap();

    let from_snapshot = core.state().unwrap().lanes[0].clone();
    let direct = core.lane(id).unwrap();
    assert_eq!(direct, from_snapshot);
}

/// The eviction plan is expressed in terms of the lanes the shell is showing.
/// While gathered, that is the filtered list — planning against the full strip
/// would aim the viewport indices at the wrong lanes entirely.
#[test]
fn eviction_planning_follows_the_gather_filter() {
    use laned_core::eviction::{MemoryReport, PaneAction, Viewport};

    let core = Core::open_in_memory().unwrap();
    // 40 lanes, alternating between two projects.
    for i in 0..40 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        let id = st.lanes.last().unwrap().id.clone();
        core.set_manual_tag(id, Some(if i % 2 == 0 { "/src/foo".into() } else { "/src/bar".into() }))
            .unwrap();
    }

    let gathered = core.gather("/src/foo".into()).unwrap();
    assert_eq!(gathered.lanes.len(), 20);

    // The shell is looking at indices 0..2 of the *filtered* strip.
    let vp = Viewport { first_visible: 0, last_visible: 2 };
    let plenty = MemoryReport {
        web_content_rss_bytes: 1,
        soft_budget_bytes: u64::MAX,
        hard_budget_bytes: u64::MAX,
        target_bytes: u64::MAX,
        pane_footprints: Vec::new(),
    };
    let plan = core.plan_eviction(vp, plenty).unwrap();

    // Exactly the gathered lanes get directives, and the first three are on
    // screen and therefore kept.
    assert_eq!(plan.len(), 20, "planned for lanes the shell is not showing");
    let visible_ids: Vec<&str> = gathered.lanes[0..3].iter().map(|l| l.id.as_str()).collect();
    for d in plan.iter().filter(|d| visible_ids.contains(&d.lane_id.as_str())) {
        assert_eq!(d.action, PaneAction::Keep);
    }
    // The far end of the gathered strip is unparented, as it should be.
    let last_id = gathered.lanes.last().unwrap().id.as_str();
    assert_eq!(plan.iter().find(|d| d.lane_id == last_id).unwrap().action, PaneAction::Unparent);
}

/// Drag-reorder is the user's gesture, and PRD §7.2 says the system never
/// reorders. These check that a drop lands exactly where it was aimed, for the
/// two directions that behave differently.
#[test]
fn dragging_a_lane_right_lands_past_the_target() {
    let core = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for i in 0..5 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        ids.push(st.lanes.last().unwrap().id.clone());
    }

    // Drag lane 1 onto lane 3: it should end up immediately right of 3.
    core.move_lane(ids[1].clone(), Placement::RightOf { lane_id: ids[3].clone() }).unwrap();

    let order: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(order, vec![ids[0].clone(), ids[2].clone(), ids[3].clone(), ids[1].clone(), ids[4].clone()]);
}

#[test]
fn dragging_a_lane_left_lands_before_the_target() {
    let core = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for i in 0..5 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        ids.push(st.lanes.last().unwrap().id.clone());
    }

    core.move_lane(ids[3].clone(), Placement::LeftOf { lane_id: ids[1].clone() }).unwrap();

    let order: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(order, vec![ids[0].clone(), ids[3].clone(), ids[1].clone(), ids[2].clone(), ids[4].clone()]);
}

/// Dragging to either end of the strip is the case that tends to break, because
/// there is no neighbour on one side to place against.
#[test]
fn a_lane_can_be_dragged_to_either_end() {
    let core = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for i in 0..4 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        ids.push(st.lanes.last().unwrap().id.clone());
    }

    core.move_lane(ids[2].clone(), Placement::LeftOf { lane_id: ids[0].clone() }).unwrap();
    let order: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(order[0], ids[2], "should be at the far left");

    core.move_lane(ids[2].clone(), Placement::RightOf { lane_id: ids[3].clone() }).unwrap();
    let order: Vec<String> = core.state().unwrap().lanes.iter().map(|l| l.id.clone()).collect();
    assert_eq!(order.last().unwrap(), &ids[2], "should be at the far right");
    assert_eq!(order.len(), 4, "a move must not duplicate or lose a lane");
}

/// Pairing is a fact about two panes and never a container (§6, §13 Phase 2).
/// The thing to prove is that it changes nothing about layout.
#[test]
fn pairing_links_two_panes_without_touching_layout() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    let pty = st.lanes[0].panes[0].id.clone();
    let st =
        core.create_lane(Placement::End, PaneKind::Web, None, Some("https://docs".into()), None).unwrap();
    let web = st.lanes[1].panes[0].id.clone();

    let before: Vec<(String, f64)> = st.lanes.iter().map(|l| (l.id.clone(), l.ordinal)).collect();

    core.pair(pty.clone(), web.clone()).unwrap();

    // Visible from either end.
    assert_eq!(core.pairs_of(pty.clone()).unwrap(), vec![web.clone()]);
    assert_eq!(core.pairs_of(web.clone()).unwrap(), vec![pty.clone()]);

    let after: Vec<(String, f64)> =
        core.state().unwrap().lanes.iter().map(|l| (l.id.clone(), l.ordinal)).collect();
    assert_eq!(after, before, "pairing moved something");

    core.unpair(pty.clone(), web.clone()).unwrap();
    assert!(core.pairs_of(pty).unwrap().is_empty());
    assert!(core.pairs_of(web).unwrap().is_empty());
}

/// Closing a paired pane takes the pairing with it, rather than leaving a row
/// pointing at a pane that no longer exists.
#[test]
fn closing_a_paired_pane_removes_the_pairing() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("ledger.db").to_string_lossy().into_owned();

    let (pty, web) = {
        let core = Core::open(db.clone()).unwrap();
        let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
        let pty = st.lanes[0].panes[0].id.clone();
        let st =
            core.create_lane(Placement::End, PaneKind::Web, None, Some("https://docs".into()), None).unwrap();
        let web = st.lanes[1].panes[0].id.clone();
        core.pair(pty.clone(), web.clone()).unwrap();
        core.close_pane(web.clone()).unwrap();
        (pty, web)
    };

    let core = Core::open(db).unwrap();
    assert!(core.pairs_of(pty).unwrap().is_empty(), "a pairing outlived the pane it pointed at");
    assert!(core.pairs_of(web).unwrap().is_empty());
}

/// Pairing does not confuse the gather filter, which is a tag question.
#[test]
fn pairing_does_not_affect_gather() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Pty, Some("s1".into()), None, None).unwrap();
    let pty_lane = st.lanes[0].id.clone();
    let pty = st.lanes[0].panes[0].id.clone();
    let st =
        core.create_lane(Placement::End, PaneKind::Web, None, Some("https://docs".into()), None).unwrap();
    let web = st.lanes[1].panes[0].id.clone();

    core.set_manual_tag(pty_lane, Some("/src/foo".into())).unwrap();
    core.pair(pty, web).unwrap();

    // The web lane is paired but untagged, so gather must not pull it in.
    let gathered = core.gather("/src/foo".into()).unwrap();
    assert_eq!(gathered.lanes.len(), 1);
}

/// §13 Phase 3 — export and import of a strip, through the real ledger.
#[test]
fn a_strip_exports_and_imports_through_the_ledger() {
    let source = Core::open_in_memory().unwrap();
    let mut ids = Vec::new();
    for i in 0..4 {
        let kind = if i % 2 == 0 { PaneKind::Web } else { PaneKind::Pty };
        let st = source
            .create_lane(
                Placement::End,
                kind,
                if kind == PaneKind::Pty { Some(format!("sess{i}")) } else { None },
                if kind == PaneKind::Web { Some(format!("https://example.com/{i}")) } else { None },
                None,
            )
            .unwrap();
        let id = st.lanes.last().unwrap().id.clone();
        source.set_lane_title(id.clone(), Some(format!("lane {i}"))).unwrap();
        source.set_manual_tag(id.clone(), Some(format!("/src/p{i}"))).unwrap();
        source.set_lane_width(id.clone(), 500 + i * 60).unwrap();
        ids.push(id);
    }
    source.set_pinned(ids[2].clone(), true).unwrap();

    let json = source.export_strip().unwrap();

    // A fresh machine.
    let destination = Core::open_in_memory().unwrap();
    let st = destination.import_strip(json).unwrap();

    assert_eq!(st.lanes.len(), 4);
    for (i, lane) in st.lanes.iter().enumerate() {
        assert_eq!(lane.title.as_deref(), Some(format!("lane {i}").as_str()));
        assert_eq!(lane.project_root.as_deref(), Some(format!("/src/p{i}").as_str()));
        assert_eq!(lane.width_pt, 500 + i as u32 * 60);
        assert_eq!(lane.pinned, i == 2);
        // Ids are regenerated, so a strip can be imported next to an existing one.
        assert_ne!(lane.id, ids[i]);
    }
    assert_eq!(st.lanes[1].panes[0].relay_session_id.as_deref(), Some("sess1"));
    assert_eq!(st.lanes[0].panes[0].url.as_deref(), Some("https://example.com/0"));
    assert!(st.lanes.windows(2).all(|w| w[0].ordinal < w[1].ordinal));
}

/// Importing appends, so a strip can be merged into a machine that already has
/// one without losing either.
#[test]
fn importing_appends_rather_than_replacing() {
    let source = Core::open_in_memory().unwrap();
    source.create_lane(Placement::End, PaneKind::Web, None, Some("https://imported".into()), None).unwrap();
    let json = source.export_strip().unwrap();

    let destination = Core::open_in_memory().unwrap();
    destination
        .create_lane(Placement::End, PaneKind::Web, None, Some("https://existing".into()), None)
        .unwrap();

    let st = destination.import_strip(json).unwrap();
    let urls: Vec<&str> = st.lanes.iter().filter_map(|l| l.panes[0].url.as_deref()).collect();
    assert_eq!(urls, vec!["https://existing", "https://imported"]);
}

/// Exporting while gathered gives the whole strip, not the view — the view is a
/// filter, and nobody means "export three of my forty lanes" by pressing ⌘G.
#[test]
fn export_ignores_the_gather_filter() {
    let core = Core::open_in_memory().unwrap();
    for i in 0..4 {
        let st = core
            .create_lane(Placement::End, PaneKind::Web, None, Some(format!("https://{i}")), None)
            .unwrap();
        let id = st.lanes.last().unwrap().id.clone();
        core.set_manual_tag(id, Some(if i % 2 == 0 { "/a".into() } else { "/b".into() })).unwrap();
    }

    core.gather("/a".into()).unwrap();
    assert_eq!(core.state().unwrap().lanes.len(), 2, "gather should be filtering");

    let destination = Core::open_in_memory().unwrap();
    let st = destination.import_strip(core.export_strip().unwrap()).unwrap();
    assert_eq!(st.lanes.len(), 4, "export gave the view rather than the strip");
}

/// A corrupt or foreign file is refused, and refusing leaves the strip alone.
#[test]
fn a_bad_import_changes_nothing() {
    let core = Core::open_in_memory().unwrap();
    core.create_lane(Placement::End, PaneKind::Web, None, Some("https://kept".into()), None).unwrap();
    let before = core.state().unwrap();

    for bad in ["", "{}", "not json", r#"{"format":"something-else","lanes":[]}"#] {
        assert!(core.import_strip(bad.into()).is_err(), "accepted {bad:?}");
    }

    let after = core.state().unwrap();
    assert_eq!(after.lanes.len(), before.lanes.len());
    assert_eq!(after.lanes[0].id, before.lanes[0].id);
}

/// An imported width outside the allowed range is clamped, not trusted.
#[test]
fn imported_widths_are_clamped() {
    let json = r#"{"format":"maxpane.strip","version":1,"lanes":[
        {"width_pt":99999,"panes":[{"kind":"web","url":"https://wide"}]},
        {"width_pt":1,"panes":[{"kind":"web","url":"https://narrow"}]}
    ]}"#;
    let core = Core::open_in_memory().unwrap();
    let st = core.import_strip(json.into()).unwrap();
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_MAX_PT);
    assert_eq!(st.lanes[1].width_pt, laned_core::LANE_MIN_PT);
}

/// §13 Phase 3 — lane spanning. A deliberate, bounded exception to §1's
/// portrait invariant, so the thing to prove is that it stays bounded.
#[test]
fn a_spanned_lane_may_be_twice_as_wide_and_no_wider() {
    let core = Core::open_in_memory().unwrap();
    let st = core
        .create_lane(Placement::End, PaneKind::Web, None, Some("https://dashboard".into()), None)
        .unwrap();
    let lane = st.lanes[0].id.clone();

    // Span 1 is the default and holds the normal bound.
    assert_eq!(st.lanes[0].span, 1);
    assert_eq!(core.set_lane_width(lane.clone(), 99_999).unwrap().lanes[0].width_pt, laned_core::LANE_MAX_PT);

    // Span 2 doubles the ceiling.
    let st = core.set_lane_span(lane.clone(), 2).unwrap();
    assert_eq!(st.lanes[0].span, 2);
    assert_eq!(
        core.set_lane_width(lane.clone(), 99_999).unwrap().lanes[0].width_pt,
        laned_core::LANE_MAX_PT * 2
    );

    // And no further: "2x for the rare landscape site" is the whole exception.
    let st = core.set_lane_span(lane.clone(), 5).unwrap();
    assert_eq!(st.lanes[0].span, 2, "span must stay inside 1..=2");

    // Narrowing back to 1 brings the width back with it, so a lane cannot be
    // left wider than a lane is allowed to be.
    let st = core.set_lane_span(lane, 1).unwrap();
    assert_eq!(st.lanes[0].span, 1);
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_MAX_PT);
}

#[test]
fn span_survives_a_restart_and_an_export() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("ledger.db").to_string_lossy().into_owned();

    let json = {
        let core = Core::open(db.clone()).unwrap();
        let st =
            core.create_lane(Placement::End, PaneKind::Web, None, Some("https://wide".into()), None).unwrap();
        let lane = st.lanes[0].id.clone();
        core.set_lane_span(lane.clone(), 2).unwrap();
        core.set_lane_width(lane, 1800).unwrap();
        core.export_strip().unwrap()
    };

    let core = Core::open(db).unwrap();
    let st = core.state().unwrap();
    assert_eq!(st.lanes[0].span, 2);
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_MAX_PT * 2);

    let elsewhere = Core::open_in_memory().unwrap();
    let st = elsewhere.import_strip(json).unwrap();
    assert_eq!(st.lanes[0].span, 2, "span did not travel with the export");
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_MAX_PT * 2);
}

/// Migration 0002 runs against a ledger written before `span` existed.
#[test]
fn an_old_ledger_gains_span_without_losing_anything() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("ledger.db");

    // A ledger at schema 0001, written by hand the way the old code would have.
    {
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(include_str!("../migrations/0001_initial.sql")).unwrap();
        conn.execute(
            "CREATE TABLE schema_migration (name TEXT PRIMARY KEY, applied_at INTEGER NOT NULL)",
            [],
        )
        .unwrap();
        conn.execute("INSERT INTO schema_migration (name, applied_at) VALUES ('0001_initial', 0)", [])
            .unwrap();
        conn.execute(
            "INSERT INTO lane (id, ordinal, width_pt, title, project_root, project_source,
                               created_at, last_focus_at, pinned)
             VALUES ('old', 0.0, 700, 'from before', '/src/old', 'manual', 1, 2, 1)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO pane (id, lane_id, position, kind, url, state)
             VALUES ('oldpane', 'old', 0, 'web', 'https://old', 'live')",
            [],
        )
        .unwrap();
    }

    let core = Core::open(path.to_string_lossy().into_owned()).unwrap();
    let st = core.state().unwrap();
    assert_eq!(st.lanes.len(), 1);
    assert_eq!(st.lanes[0].id, "old");
    assert_eq!(st.lanes[0].title.as_deref(), Some("from before"));
    assert_eq!(st.lanes[0].project_root.as_deref(), Some("/src/old"));
    assert_eq!(st.lanes[0].width_pt, 700);
    assert!(st.lanes[0].pinned);
    assert_eq!(st.lanes[0].span, 1, "existing lanes must default to span 1");
    assert_eq!(st.lanes[0].panes[0].url.as_deref(), Some("https://old"));
}

/// The config file's `laneDefaultPt` reaches a new lane.
///
/// It did not, for the life of the setting: `create_lane` read the
/// `LANE_DEFAULT_PT` constant and the Swift `Config.laneDefaultPt` was a number
/// nothing consulted. The two agreed, so nothing looked wrong — which is the
/// failure mode a duplicated constant has.
#[test]
fn a_new_lane_is_born_at_the_width_the_shell_asked_for() {
    let core = Core::open_in_memory().unwrap();
    core.set_default_lane_width(700);
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
    assert_eq!(st.lanes[0].width_pt, 700);

    // A width the user chose outlives a later change of default: the strip is
    // theirs, not the config file's.
    let lane = st.lanes[0].id.clone();
    core.set_lane_width(lane, 480).unwrap();
    core.set_default_lane_width(880);
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://b".into()), None).unwrap();
    assert_eq!(st.lanes[0].width_pt, 480, "an existing lane was reflowed by a default");
    assert_eq!(st.lanes[1].width_pt, 880);
}

/// A config file with a silly number in it still opens a readable strip.
#[test]
fn the_default_width_is_clamped_like_a_resize() {
    let core = Core::open_in_memory().unwrap();
    core.set_default_lane_width(40);
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_MIN_PT);

    core.set_default_lane_width(40_000);
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://b".into()), None).unwrap();
    assert_eq!(st.lanes[1].width_pt, laned_core::LANE_MAX_PT);
}

/// Nothing said, nothing changed: a caller that never states a width — the
/// tests, the CLI, a shell that has not read its config yet — gets the constant.
#[test]
fn the_constant_is_still_what_an_unconfigured_caller_gets() {
    let core = Core::open_in_memory().unwrap();
    let st = core.create_lane(Placement::End, PaneKind::Web, None, Some("https://a".into()), None).unwrap();
    assert_eq!(st.lanes[0].width_pt, laned_core::LANE_DEFAULT_PT);
}
