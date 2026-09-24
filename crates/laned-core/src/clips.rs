//! Paste history: what decides whether a piece of text may be kept, and in
//! what form (ADR-0031, widened to web panes by ADR-0041).
//!
//! Everything here is pure. The table is `clip` (migration 0016); the one
//! writer is [`crate::ledger::Ledger::record_clip`], and it goes through
//! [`admit`] first, so no caller can put into the file what this module would
//! have refused or redacted.
//!
//! **The secret shapes are a net, not a guarantee.** A password is eight
//! characters of anything and looks like nothing. What can be recognised is a
//! token whose issuer gave it a prefix, and those are recognised:
//!
//! | shape | what it is |
//! |---|---|
//! | `sk-` and 20 or more of `A-Z a-z 0-9 _ -` | OpenAI, Anthropic (`sk-ant-…`) |
//! | `ghp_` `gho_` `ghu_` `ghs_` `ghr_` and 30 or more letters and digits; `github_pat_` and 20 or more | GitHub |
//! | `AKIA` or `ASIA` and 16 of `A-Z 0-9` | an AWS access key id |
//! | `-----BEGIN …-----` | a PEM header, whatever it begins |
//! | `eyJ….eyJ….…` | a JWT: two base64url JSON objects and a signature |
//! | `xoxb-` `xoxp-` `xoxa-` `xoxr-` `xoxs-` and 10 or more | Slack |
//! | `glpat-` and 20 or more | GitLab |
//!
//! A prefix counts only at the start of a word, so `task-…` is not `sk-…`.
//! The whole entry is redacted when any part of it matches: `export KEY=sk-…`
//! is kept as `expo•••`. What else was in it goes too, since deciding which
//! half of a line is safe is exactly the judgment this module does not have.

use crate::model::{ClipKind, ClipSource};

/// Nothing bigger is kept. A paste that size is a file, and a history of files
/// is a second copy of somebody's disk.
pub const MAX_BYTES: usize = 64 * 1024;

/// What stands in for the content of an entry that looked like a secret.
pub const REDACTION: &str = "•••";

/// A piece of text as the table will hold it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Admitted {
    pub content: String,
    pub redacted: bool,
    pub line_count: u32,
    pub byte_count: u64,
}

/// `text` as it may be stored, or `None` when it may not be stored at all:
/// nothing but whitespace, or more than [`MAX_BYTES`].
pub fn admit(text: &str) -> Option<Admitted> {
    if text.trim().is_empty() || text.len() > MAX_BYTES {
        return None;
    }
    let redacted = secret_shape(text).is_some();
    Some(Admitted {
        content: if redacted { redact(text) } else { text.to_string() },
        redacted,
        line_count: line_count(text),
        byte_count: text.len() as u64,
    })
}

/// Lines as a person counts them: a trailing line ending does not start
/// another, and CRLF is one ending.
pub fn line_count(text: &str) -> u32 {
    let body = text.trim_end_matches(['\n', '\r']);
    if body.is_empty() {
        return 1;
    }
    let mut lines = 1u32;
    let mut after_return = false;
    for c in body.chars() {
        match c {
            '\r' => {
                lines += 1;
                after_return = true;
            }
            '\n' => {
                if !after_return {
                    lines += 1;
                }
                after_return = false;
            }
            _ => after_return = false,
        }
    }
    lines
}

/// The first four characters and `•••`, so the list shows that something was
/// there. A control character among the four is a space: the row is one line.
pub fn redact(text: &str) -> String {
    let head: String = text
        .trim_start()
        .chars()
        .take(4)
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect();
    format!("{head}{REDACTION}")
}

/// Which secret shape `text` contains, by name, or `None`.
pub fn secret_shape(text: &str) -> Option<&'static str> {
    let b = text.as_bytes();
    for i in 0..b.len() {
        // Every shape starts with one of these; skip the rest of the text fast.
        if !matches!(b[i], b's' | b'g' | b'A' | b'-' | b'e' | b'x') {
            continue;
        }
        let at_word_start = i == 0 || !(b[i - 1].is_ascii_alphanumeric() || b[i - 1] == b'_');
        let rest = &b[i..];
        if rest.starts_with(b"-----BEGIN ") {
            let label = run(&rest[11..], |c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == b' ');
            if label > 0 && rest[11 + label..].starts_with(b"-----") {
                return Some("pem");
            }
        }
        if !at_word_start {
            continue;
        }
        let token = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c == b'-';
        if rest.starts_with(b"sk-") && run(&rest[3..], token) >= 20 {
            return Some("sk");
        }
        for prefix in [&b"ghp_"[..], b"gho_", b"ghu_", b"ghs_", b"ghr_"] {
            if rest.starts_with(prefix) && run(&rest[4..], |c| c.is_ascii_alphanumeric()) >= 30 {
                return Some("github");
            }
        }
        if rest.starts_with(b"github_pat_") && run(&rest[11..], token) >= 20 {
            return Some("github");
        }
        if (rest.starts_with(b"AKIA") || rest.starts_with(b"ASIA"))
            && run(&rest[4..], |c| c.is_ascii_uppercase() || c.is_ascii_digit()) >= 16
        {
            return Some("aws");
        }
        if rest.starts_with(b"xox")
            && rest.len() > 5
            && matches!(rest[3], b'a' | b'b' | b'p' | b'r' | b's')
            && rest[4] == b'-'
            && run(&rest[5..], token) >= 10
        {
            return Some("slack");
        }
        if rest.starts_with(b"glpat-") && run(&rest[6..], token) >= 20 {
            return Some("gitlab");
        }
        if is_jwt(rest) {
            return Some("jwt");
        }
    }
    None
}

/// `eyJ….eyJ….sig`: a header and a payload that are each base64url of a JSON
/// object (`{"` encodes as `eyJ`), and a signature.
fn is_jwt(rest: &[u8]) -> bool {
    let b64 = |c: u8| c.is_ascii_alphanumeric() || c == b'_' || c == b'-';
    if !rest.starts_with(b"eyJ") {
        return false;
    }
    let header = run(rest, b64);
    if header < 10 || rest.get(header) != Some(&b'.') {
        return false;
    }
    let rest = &rest[header + 1..];
    if !rest.starts_with(b"eyJ") {
        return false;
    }
    let payload = run(rest, b64);
    if payload < 10 || rest.get(payload) != Some(&b'.') {
        return false;
    }
    run(&rest[payload + 1..], b64) >= 10
}

fn run(bytes: &[u8], keep: impl Fn(u8) -> bool) -> usize {
    bytes.iter().take_while(|c| keep(**c)).count()
}

pub(crate) fn kind_str(kind: ClipKind) -> &'static str {
    match kind {
        ClipKind::Paste => "paste",
        ClipKind::Copy => "copy",
    }
}

pub(crate) fn kind_from(s: &str) -> ClipKind {
    if s == "copy" {
        ClipKind::Copy
    } else {
        ClipKind::Paste
    }
}

pub(crate) fn source_str(source: ClipSource) -> &'static str {
    match source {
        ClipSource::Pty => "pty",
        ClipSource::Web => "web",
    }
}

/// Anything that is not `web` is a terminal's, which is what every row
/// written before migration 0018 was.
pub(crate) fn source_from(s: &str) -> ClipSource {
    if s == "web" {
        ClipSource::Web
    } else {
        ClipSource::Pty
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_secret_shape_is_caught() {
        let cases = [
            ("sk-ant-api03-abcdefghijklmnopqrstuvwx", "sk"),
            ("export OPENAI_API_KEY=sk-proj1234567890abcdefghij", "sk"),
            ("ghp_abcdefghijklmnopqrstuvwxyz0123456789", "github"),
            ("gho_abcdefghijklmnopqrstuvwxyz0123456789", "github"),
            ("github_pat_11ABCDEFG0abcdefghijkl_mnop", "github"),
            ("aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE", "aws"),
            ("ASIAIOSFODNN7EXAMPLE", "aws"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n", "pem"),
            ("-----BEGIN CERTIFICATE-----", "pem"),
            (
                "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
                "jwt",
            ),
            ("xoxb-1234567890-abcdefghij", "slack"),
            ("glpat-abcdefghij0123456789", "gitlab"),
        ];
        for (text, shape) in cases {
            assert_eq!(secret_shape(text), Some(shape), "{text}");
            let kept = admit(text).unwrap();
            assert!(kept.redacted, "{text}");
            assert!(kept.content.ends_with(REDACTION));
            assert_eq!(kept.content.chars().count(), 4 + 3, "{text}");
            assert_eq!(kept.byte_count, text.len() as u64);
        }
    }

    #[test]
    fn ordinary_text_is_not_a_secret() {
        for text in [
            "ls -la",
            "/Users/you/code/task-list-of-everything-that-is-long.md",
            "risk-assessment-of-the-whole-long-thing-2026",
            "sk-short",
            "AKIA",
            "MAKIAIOSFODNN7EXAMPLEX",
            "----- BEGIN -----",
            "eyJhbGciOiJIUzI1NiJ9 alone is a header and no token",
            "git commit -m 'xoxo-love'",
            "ghp_short",
        ] {
            assert_eq!(secret_shape(text), None, "{text}");
            let kept = admit(text).unwrap();
            assert!(!kept.redacted);
            assert_eq!(kept.content, text);
        }
    }

    #[test]
    fn redaction_keeps_four_characters_and_one_line() {
        assert_eq!(redact("export KEY=sk-…"), "expo•••");
        assert_eq!(redact("  a\nbcdef"), "a bc•••");
        assert_eq!(redact("ab"), "ab•••");
        assert_eq!(redact("日本語のテキスト"), "日本語の•••");
    }

    #[test]
    fn nothing_and_too_much_are_refused() {
        assert_eq!(admit(""), None);
        assert_eq!(admit(" \n\t"), None);
        assert!(admit(&"a".repeat(MAX_BYTES)).is_some());
        assert_eq!(admit(&"a".repeat(MAX_BYTES + 1)), None);
    }

    #[test]
    fn lines_are_counted_as_a_person_would() {
        assert_eq!(line_count("one"), 1);
        assert_eq!(line_count("one\n"), 1);
        assert_eq!(line_count("one\ntwo"), 2);
        assert_eq!(line_count("one\r\ntwo\r\n"), 2);
        assert_eq!(line_count("one\rtwo\n\nfour"), 4);
    }
}
