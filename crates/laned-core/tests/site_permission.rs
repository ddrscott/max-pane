//! What a site is allowed to reach for, and who "the user" is when it asks.
//!
//! The interesting property is not that a row round-trips — it is that the
//! **cookie jar is part of the key**. A camera grant made while a pane was in
//! one project's data store is not a grant made in another's, because to the
//! site those are two different people (ADR-0003). A store keyed by origin alone
//! would pass every other test in this file and leak a permission across the
//! boundary the sharding exists to draw.

use laned_core::model::*;
use laned_core::Core;

fn db(dir: &tempfile::TempDir) -> String {
    dir.path().join("ledger.db").to_string_lossy().into_owned()
}

#[test]
fn a_site_nobody_has_answered_about_has_no_answer() {
    let core = Core::open_in_memory().unwrap();
    let answer =
        core.site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Camera).unwrap();
    // `None`, not `Some(false)`. Only "never asked" may raise a prompt, so
    // conflating the two would either prompt forever or deny forever.
    assert_eq!(answer, None);
}

#[test]
fn camera_and_microphone_are_separate_answers() {
    let core = Core::open_in_memory().unwrap();
    core.set_site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Microphone, true)
        .unwrap();

    assert_eq!(
        core.site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Microphone)
            .unwrap(),
        Some(true)
    );
    // "Yes to the microphone, no to the camera" is a real answer, and
    // `getUserMedia({audio: true})` must not be blocked by a camera that has
    // never been asked about.
    assert_eq!(
        core.site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Camera).unwrap(),
        None
    );
}

#[test]
fn a_grant_in_one_cookie_jar_is_not_a_grant_in_another() {
    let core = Core::open_in_memory().unwrap();
    core.set_site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Camera, true)
        .unwrap();

    assert_eq!(
        core.site_permission("shard-3".into(), "https://meet.example".into(), SiteFeature::Camera).unwrap(),
        None
    );
}

#[test]
fn a_remembered_no_is_remembered() {
    let core = Core::open_in_memory().unwrap();
    core.set_site_permission("shard-0".into(), "https://ads.example".into(), SiteFeature::Camera, false)
        .unwrap();
    assert_eq!(
        core.site_permission("shard-0".into(), "https://ads.example".into(), SiteFeature::Camera).unwrap(),
        Some(false)
    );
}

#[test]
fn answering_again_replaces_the_answer() {
    let core = Core::open_in_memory().unwrap();
    for allowed in [true, false, true] {
        core.set_site_permission(
            "shard-0".into(),
            "https://meet.example".into(),
            SiteFeature::Camera,
            allowed,
        )
        .unwrap();
    }
    assert_eq!(
        core.site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Camera).unwrap(),
        Some(true)
    );
}

/// A permission that cannot be revoked is worse than one that is never
/// remembered: a misclicked Block would put the site out of reach forever with
/// no way back.
#[test]
fn forgetting_a_site_clears_every_feature_at_once() {
    let core = Core::open_in_memory().unwrap();
    for feature in [SiteFeature::Camera, SiteFeature::Microphone, SiteFeature::Geolocation] {
        core.set_site_permission("shard-0".into(), "https://meet.example".into(), feature, false).unwrap();
    }
    core.forget_site_permissions("shard-0".into(), "https://meet.example".into()).unwrap();

    for feature in [SiteFeature::Camera, SiteFeature::Microphone, SiteFeature::Geolocation] {
        assert_eq!(
            core.site_permission("shard-0".into(), "https://meet.example".into(), feature).unwrap(),
            None
        );
    }
}

/// PRD §5.2: the shell owns no durable state. A decision the user made once
/// must not have to be made again after a restart, which means it is in the
/// ledger file and not in the process.
#[test]
fn a_decision_survives_an_unclean_exit() {
    let dir = tempfile::tempdir().unwrap();
    {
        let core = Core::open(db(&dir)).unwrap();
        core.set_site_permission("shard-2".into(), "https://meet.example".into(), SiteFeature::Camera, true)
            .unwrap();
        // Dropped with no shutdown path, which is what `kill -9` leaves.
    }
    let reopened = Core::open(db(&dir)).unwrap();
    assert_eq!(
        reopened
            .site_permission("shard-2".into(), "https://meet.example".into(), SiteFeature::Camera)
            .unwrap(),
        Some(true)
    );
}

/// The listing a web pane embeds into its pages, so `Notification.permission`
/// can be read before the page runs. Filtered by jar and by feature: a camera
/// grant is not a notification grant, and another jar's answers are another
/// person's.
#[test]
fn notification_answers_are_listed_per_jar_and_feature() {
    let core = Core::open_in_memory().unwrap();
    core.set_site_permission("shard-0".into(), "https://slack.example".into(), SiteFeature::Notifications, true)
        .unwrap();
    core.set_site_permission("shard-0".into(), "https://ads.example".into(), SiteFeature::Notifications, false)
        .unwrap();
    core.set_site_permission("shard-0".into(), "https://meet.example".into(), SiteFeature::Camera, true)
        .unwrap();
    core.set_site_permission("shard-0".into(), "https://maps.example".into(), SiteFeature::Geolocation, true)
        .unwrap();
    core.set_site_permission("shard-1".into(), "https://mail.example".into(), SiteFeature::Notifications, true)
        .unwrap();

    let listed = core.site_permissions("shard-0".into(), SiteFeature::Notifications).unwrap();
    assert_eq!(
        listed,
        vec![
            SiteGrant { origin: "https://ads.example".into(), allowed: false },
            SiteGrant { origin: "https://slack.example".into(), allowed: true },
        ]
    );
    assert!(core.site_permissions("shard-2".into(), SiteFeature::Notifications).unwrap().is_empty());
    // And the single read agrees with the listing, under the new feature string.
    assert_eq!(
        core.site_permission("shard-0".into(), "https://slack.example".into(), SiteFeature::Notifications)
            .unwrap(),
        Some(true)
    );
}
