//! Another browser's saved passwords, read but never understood.
//!
//! # The one rule this file exists to keep
//!
//! **Nothing in this module can read a password, and that is deliberate.** A
//! Chromium password is AES encrypted under a key that lives in the macOS
//! Keychain, and this crate is the platform-agnostic half of the app — it has
//! no Keychain, so it cannot have the key. So the split is not an accident of
//! layering, it is the design: Rust copies the file, reads the rows and hands
//! back **ciphertext**; the Swift side reads the one Keychain item that holds
//! the key, decrypts in the app process, and writes each credential straight
//! into the Keychain. A plaintext password never exists in this crate, never
//! crosses the FFI, and is never a value any code here could log by accident.
//!
//! # Why the copy, again
//!
//! `Login Data` lives in the same profile directory as `History`, and it is
//! locked the same way: Chromium opens it with `PRAGMA locking_mode =
//! EXCLUSIVE` and holds that for the life of the process, so the backup API
//! answers `database is locked` and nothing else. [`crate::import::Snapshot`]
//! already solved this — file copy plus the `-journal`/`-wal`/`-shm` siblings,
//! opened read-write so a hot journal can roll back — and it is reused here
//! rather than reimplemented, including its `Drop`, which is what guarantees a
//! file full of someone's passwords does not outlive the call that made it.
//!
//! It lands beside the ledger rather than in `/tmp` for the same reason the
//! history snapshot does, only more so.
//!
//! # What the ciphertext looks like, measured
//!
//! Against the owner's real Vivaldi profile — 480 rows, 442 with a password,
//! 35 "never save for this site" entries — **every** `password_value` begins
//! with the three ASCII bytes `v10` and the remainder is an exact multiple of
//! 16 bytes. That is AES-**CBC** with PKCS#7 padding, not GCM: a GCM blob
//! carries a 12-byte nonce and a 16-byte tag and would not be block-aligned.
//! The ticket said GCM, which is true of Chromium on Windows and not here. The
//! measurement is recorded because the two schemes fail differently — a wrong
//! guess about GCM yields an authentication error, a wrong guess about CBC
//! yields plausible garbage.

use crate::error::{CoreError, Result};
use crate::import::{Snapshot, CHROMIUM_FAMILY};
use rusqlite::Connection;
use std::path::{Path, PathBuf};

/// One browser profile whose saved passwords we could import.
///
/// Deliberately **not** [`crate::import::HistorySource`] with two more fields
/// on it. A history source answers "which browsers can I read the past from",
/// and the answer includes Safari and Firefox; a login source answers "which
/// browsers keep passwords in a form we can decrypt", and the answer is the
/// Chromium family alone. Safari's passwords are already Keychain items — there
/// is nothing to import, reading the Keychain *is* the import — and Firefox's
/// are behind NSS, which is a different mechanism and not in this round. One
/// record that meant a different thing depending on which list it came out of
/// is the shape that would let a Safari row reach this code at all.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct LoginSource {
    /// "Vivaldi", "Google Chrome" — the name on the user's Dock.
    pub name: String,
    /// The browser's own name for the profile, when it has more than one.
    pub profile: Option<String>,
    /// Absolute path to `Login Data`.
    pub path: String,
    /// The generic-password item holding this browser's AES key, by service
    /// name: "Vivaldi Safe Storage", "Chrome Safe Storage".
    ///
    /// It is here rather than derived in Swift because the service name is not
    /// the name on the Dock — Google Chrome's item says "Chrome Safe Storage"
    /// — and the two mappings (directory, keychain service) belong in the one
    /// table that already knows about this browser family.
    pub safe_storage_service: String,
    /// Bytes, for a screen that is about to copy it.
    pub size_bytes: u64,
    /// Why we cannot read it, when we cannot. The row is still offered, with
    /// the sentence that says what to do.
    pub blocked: Option<String>,
}

/// One saved login, with the password still sealed.
///
/// `secret` is the raw `password_value` blob exactly as Chromium wrote it,
/// `v10` prefix and all. This crate cannot open it; see the module doc.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SourceLogin {
    /// The page the form was on: `https://example.com/login`.
    pub origin: String,
    /// Chromium's own key for the site — `https://example.com/` for a form, or
    /// `example.com:443/realm` for an HTTP-auth entry. Kept because it is the
    /// only field that distinguishes those two, and they become different kinds
    /// of Keychain item.
    pub signon_realm: String,
    /// The user name. May be empty: Chromium stores password-only logins.
    pub username: String,
    /// The sealed password. Ciphertext, always.
    pub secret: Vec<u8>,
    /// Chromium's `scheme` column: 0 is an HTML form, anything else is an
    /// HTTP-auth realm (basic, digest, and the rest).
    pub is_html_form: bool,
    pub created_ms: i64,
    pub last_used_ms: i64,
}

/// µs since 1601-01-01, the clock `Login Data` shares with `History`.
const WINDOWS_TO_UNIX_MS: i64 = 11_644_473_600_000;

fn to_epoch_ms(raw: i64) -> i64 {
    if raw == 0 {
        return 0;
    }
    raw / 1000 - WINDOWS_TO_UNIX_MS
}

/// Every Chromium profile on this machine that has saved passwords.
pub fn detect() -> Vec<LoginSource> {
    match std::env::var("HOME") {
        Ok(home) => detect_in(Path::new(&home)),
        Err(_) => Vec::new(),
    }
}

/// [`detect`] against an arbitrary home directory, which is what makes it
/// testable — the real one holds whatever this developer happens to have
/// installed.
pub fn detect_in(home: &Path) -> Vec<LoginSource> {
    let support = home.join("Library/Application Support");
    let mut out = Vec::new();

    for (name, dir, safe_storage) in CHROMIUM_FAMILY {
        let root = support.join(dir);
        if !root.is_dir() {
            continue;
        }
        let mut profiles: Vec<(Option<String>, PathBuf)> = Vec::new();
        if root.join("Login Data").is_file() {
            profiles.push((None, root.join("Login Data")));
        }
        if let Ok(entries) = std::fs::read_dir(&root) {
            let mut dirs: Vec<PathBuf> =
                entries.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect();
            dirs.sort();
            for d in dirs {
                let file = d.join("Login Data");
                if file.is_file() {
                    profiles.push((d.file_name().map(|n| n.to_string_lossy().into_owned()), file));
                }
            }
        }
        for (profile, path) in profiles {
            out.push(describe(name, profile, safe_storage, &path));
        }
    }
    out
}

fn describe(name: &str, profile: Option<String>, service: &str, path: &Path) -> LoginSource {
    let size_bytes = std::fs::metadata(path).map(|m| m.len()).unwrap_or(0);
    // The same up-front permission question `import::describe` asks, for the
    // same reason: a TCC denial reaches SQLite as "unable to open database
    // file", which in a dialog is indistinguishable from a corrupt profile.
    let blocked = match std::fs::File::open(path) {
        Ok(_) => None,
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => Some(format!(
            "macOS is withholding {name}'s saved passwords. Give Max Pane Full Disk Access \
             in System Settings → Privacy & Security, then reopen this window."
        )),
        Err(e) => Some(format!("{}: {e}", path.display())),
    };
    LoginSource {
        name: name.to_string(),
        profile,
        path: path.to_string_lossy().into_owned(),
        safe_storage_service: service.to_string(),
        size_bytes,
        blocked,
    }
}

/// Snapshot `source` and read every sealed login out of it.
///
/// The snapshot's lifetime is this function. It is taken, read, and dropped —
/// and dropping it deletes the copy — before the rows are handed back, so no
/// caller has to remember that a copy of `Login Data` is a file full of the
/// owner's passwords.
pub fn read(source: &LoginSource, ledger: Option<&Path>) -> Result<Vec<SourceLogin>> {
    if let Some(why) = &source.blocked {
        return Err(CoreError::Invalid { message: why.clone() });
    }
    let snapshot = Snapshot::take(Path::new(&source.path), ledger)?;
    let conn = snapshot.open()?;
    read_logins(&conn)
}

/// The `logins` table, minus everything that is not a credential.
///
/// Three kinds of row are dropped, and all three are dropped for the same
/// reason — putting one in the Keychain would be putting something there that
/// is not a password:
///
/// - **`blacklisted_by_user`**: the user pressed "Never for this site". The row
///   exists to record a refusal and its `password_value` is empty. 35 of the
///   owner's 480.
/// - **a federated login**: "Sign in with Google". There is no password; the
///   row names an identity provider.
/// - **an empty `password_value`**: the same shape as the two above from a
///   Chromium version that spells them differently.
///
/// Columns are named rather than `SELECT *`: this schema has grown to 30
/// columns across Chromium versions and the order is not stable between them.
pub fn read_logins(conn: &Connection) -> Result<Vec<SourceLogin>> {
    let mut stmt = conn.prepare(
        "SELECT origin_url, signon_realm, username_value, password_value, scheme, \
                date_created, date_last_used, blacklisted_by_user, \
                COALESCE(federation_url, '') \
         FROM logins \
         ORDER BY origin_url, username_value",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, Vec<u8>>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
            row.get::<_, i64>(6)?,
            row.get::<_, i64>(7)?,
            row.get::<_, String>(8)?,
        ))
    })?;

    let mut out = Vec::new();
    for row in rows {
        let (origin, realm, username, secret, scheme, created, last_used, blacklisted, federation) =
            row?;
        if blacklisted != 0 || secret.is_empty() || !federation.is_empty() {
            continue;
        }
        out.push(SourceLogin {
            origin,
            signon_realm: realm,
            username,
            secret,
            is_html_form: scheme == 0,
            created_ms: to_epoch_ms(created),
            last_used_ms: to_epoch_ms(last_used),
        });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn windows_epoch_lands_in_this_century() {
        // 2021-07-15T18:06:28Z, the creation date of the owner's own Safe
        // Storage item, in Chromium's clock.
        let raw = (1_626_372_388_000 + WINDOWS_TO_UNIX_MS) * 1000;
        assert_eq!(to_epoch_ms(raw), 1_626_372_388_000);
        // Chromium writes 0 for "never used", and 0 must not become 1601.
        assert_eq!(to_epoch_ms(0), 0);
    }
}
