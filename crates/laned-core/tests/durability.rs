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
