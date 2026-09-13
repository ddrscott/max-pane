//! Reading another browser's saved passwords, without being able to read one.
//!
//! The thing worth pinning here is not the SQL — it is **which rows are not
//! credentials**. `logins` holds three kinds of row that look like a saved
//! password and are not one, and putting any of them in someone's Keychain
//! would be putting a thing there that has no password in it:
//!
//! - a "Never for this site" refusal (`blacklisted_by_user`, 35 of the owner's
//!   480 rows),
//! - a federated "Sign in with Google" entry, which names a provider,
//! - an empty `password_value` from a Chromium version that spells either of
//!   the above differently.
//!
//! The second thing is the epoch, for the same reason it is tested for history:
//! Chromium's clock starts in 1601 and getting it wrong yields dates, not
//! errors.

use laned_core::logins::{self, LoginSource};
use rusqlite::Connection;
use std::path::{Path, PathBuf};

/// The real `logins` schema, trimmed to the columns this crate names. The
/// column set has grown to 30-odd across Chromium versions and the order is not
/// stable, which is why the reader names every column and why this fixture can
/// safely leave the rest out.
fn login_data(dir: &Path, rows: &[Row]) -> PathBuf {
    let path = dir.join("Login Data");
    let conn = Connection::open(&path).unwrap();
    conn.execute_batch(
        "CREATE TABLE logins(origin_url VARCHAR NOT NULL, action_url VARCHAR,
                             username_element VARCHAR, username_value VARCHAR,
                             password_element VARCHAR, password_value BLOB,
                             signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL,
                             blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL,
                             date_last_used INTEGER NOT NULL DEFAULT 0,
                             federation_url VARCHAR);",
    )
    .unwrap();
    for r in rows {
        conn.execute(
            "INSERT INTO logins(origin_url, signon_realm, username_value, password_value,
                                scheme, date_created, date_last_used, blacklisted_by_user,
                                federation_url)
             VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                r.origin,
                r.realm,
                r.user,
                r.secret,
                r.scheme,
                r.created,
                r.last_used,
                r.blacklisted,
                r.federation
            ],
        )
        .unwrap();
    }
    path
}

struct Row {
    origin: &'static str,
    realm: &'static str,
    user: &'static str,
    secret: Vec<u8>,
    scheme: i64,
    created: i64,
    last_used: i64,
    blacklisted: i64,
    federation: &'static str,
}

impl Row {
    fn form(origin: &'static str, user: &'static str) -> Self {
        Row {
            origin,
            realm: "https://example.com/",
            user,
            // `v10` and sixteen bytes, which is the shape every one of the
            // owner's 442 real rows has. Nothing here can open it.
            secret: b"v10\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10".to_vec(),
            scheme: 0,
            created: CREATED_RAW,
            last_used: 0,
            blacklisted: 0,
            federation: "",
        }
    }
}

/// 2021-07-15T18:06:28Z in Chromium's clock, and what it means.
const CREATED_RAW: i64 = (1_626_372_388_000 + 11_644_473_600_000) * 1000;
const CREATED_MS: i64 = 1_626_372_388_000;

fn source(path: &Path) -> LoginSource {
    LoginSource {
        name: "Vivaldi".into(),
        profile: Some("Default".into()),
        path: path.to_string_lossy().into_owned(),
        safe_storage_service: "Vivaldi Safe Storage".into(),
        size_bytes: 0,
        blocked: None,
    }
}

#[test]
fn only_rows_that_actually_hold_a_password_come_back() {
    let dir = tempfile::tempdir().unwrap();
    let mut refused = Row::form("https://bank.example/login", "");
    refused.blacklisted = 1;
    refused.secret = Vec::new();
    let mut federated = Row::form("https://sso.example/login", "scott@trifectadb.com");
    federated.secret = Vec::new();
    federated.federation = "https://accounts.google.com";
    let mut empty = Row::form("https://empty.example/login", "scott");
    empty.secret = Vec::new();

    let path = login_data(
        dir.path(),
        &[
            Row::form("https://example.com/login", "scott"),
            refused,
            federated,
            empty,
        ],
    );

    let out = logins::read(&source(&path), Some(dir.path().join("ledger.db").as_path())).unwrap();
    assert_eq!(out.len(), 1);
    assert_eq!(out[0].origin, "https://example.com/login");
    assert_eq!(out[0].username, "scott");
    assert!(out[0].is_html_form);
    assert_eq!(out[0].created_ms, CREATED_MS);
    // Never used is 0 and stays 0 — not 1601.
    assert_eq!(out[0].last_used_ms, 0);
    // The blob comes back byte for byte, prefix and all. Anything that
    // "helpfully" stripped the `v10` here would be a layer deciding it
    // understood the format, which is the one thing this crate must not do.
    assert_eq!(&out[0].secret[..3], b"v10");
    assert_eq!(out[0].secret.len(), 19);
}

#[test]
fn an_http_auth_row_is_marked_as_one() {
    let dir = tempfile::tempdir().unwrap();
    let mut auth = Row::form("https://nas.example/", "admin");
    auth.scheme = 1;
    auth.realm = "nas.example:443/Home NAS";
    let path = login_data(dir.path(), &[auth]);

    let out = logins::read(&source(&path), Some(dir.path().join("ledger.db").as_path())).unwrap();
    assert_eq!(out.len(), 1);
    // The distinction matters on the far side: a form login and an HTTP-auth
    // credential become different kinds of Keychain item, and the only field
    // that tells them apart is this one.
    assert!(!out[0].is_html_form);
    assert_eq!(out[0].signon_realm, "nas.example:443/Home NAS");
}

#[test]
fn the_copy_does_not_outlive_the_call_that_made_it() {
    let dir = tempfile::tempdir().unwrap();
    let path = login_data(dir.path(), &[Row::form("https://example.com/login", "scott")]);
    let ledger = dir.path().join("ledger.db");

    let out = logins::read(&source(&path), Some(ledger.as_path())).unwrap();
    assert_eq!(out.len(), 1);
    // `Snapshot` puts its copy beside the ledger and deletes it on drop. A
    // `Login Data` copy left behind is a file full of the owner's real
    // passwords, so its absence is an assertion and not an implementation
    // detail.
    assert!(!dir.path().join("import-snapshot").exists());
}

#[test]
fn a_source_we_cannot_read_says_so_instead_of_failing_obscurely() {
    let dir = tempfile::tempdir().unwrap();
    let path = login_data(dir.path(), &[]);
    let mut src = source(&path);
    src.blocked = Some("macOS is withholding it.".into());
    let err = logins::read(&src, None).unwrap_err();
    assert!(err.to_string().contains("withholding"));
}

#[test]
fn detection_finds_a_profile_and_names_its_keychain_item() {
    let home = tempfile::tempdir().unwrap();
    let profile = home.path().join("Library/Application Support/Google/Chrome/Default");
    std::fs::create_dir_all(&profile).unwrap();
    std::fs::write(profile.join("Login Data"), b"not really sqlite").unwrap();

    let found = logins::detect_in(home.path());
    assert_eq!(found.len(), 1);
    assert_eq!(found[0].name, "Google Chrome");
    assert_eq!(found[0].profile.as_deref(), Some("Default"));
    // Three spellings of one browser, and this is the one that is not derivable
    // from the others: the directory is `Google/Chrome`, the Dock says "Google
    // Chrome", the Keychain says "Chrome Safe Storage".
    assert_eq!(found[0].safe_storage_service, "Chrome Safe Storage");
    assert!(found[0].blocked.is_none());
}
