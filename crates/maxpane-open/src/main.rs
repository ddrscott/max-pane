//! `maxpane-open` — the `BROWSER` shim from PRD §7.1.
//!
//! A terminal pane runs with `BROWSER=maxpane-open`, so anything that opens a
//! URL the polite way (`xdg-open`, `gh browse`, most CLIs, and `open` when
//! aliased) hands it here instead of to Safari. This posts it to the running
//! Max Pane, which turns it into a web lane immediately right of the terminal
//! that asked — tagged with that terminal's project.
//!
//! Reads a URL from argv or stdin, writes what it did to stdout, and exits
//! non-zero when it could not deliver. If Max Pane is not running it falls back
//! to the system handler, because a shim that swallows URLs when the app is
//! closed is worse than no shim.
//!
//! ```text
//! maxpane-open https://example.com
//! echo https://example.com | maxpane-open
//! maxpane-open --print-socket
//! ```

use std::env;
use std::io::{self, BufRead, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

/// Where the app listens. Under Application Support next to the ledger, so the
/// two things that define a running Max Pane live together.
fn socket_path() -> PathBuf {
    if let Ok(p) = env::var("MAXPANE_SOCKET") {
        return PathBuf::from(p);
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/MaxPane/open.sock")
}

fn usage() -> ! {
    eprintln!(
        "usage: maxpane-open [URL]

Opens URL as a web lane in the running Max Pane, immediately right of the
terminal that asked. With no URL, reads one per line from stdin.

Falls back to the system handler when Max Pane is not running.

options:
  --print-socket   print the control socket path and exit
  -h, --help       this message"
    );
    std::process::exit(2)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();

    match args.first().map(String::as_str) {
        Some("-h") | Some("--help") => usage(),
        Some("--print-socket") => {
            println!("{}", socket_path().display());
            return;
        }
        _ => {}
    }

    let urls: Vec<String> = if args.is_empty() {
        let mut buf = String::new();
        if io::stdin().read_to_string(&mut buf).is_err() {
            eprintln!("maxpane-open: could not read stdin");
            std::process::exit(1);
        }
        buf.lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect()
    } else {
        args.into_iter().filter(|a| !a.starts_with('-')).collect()
    };

    if urls.is_empty() {
        usage();
    }

    let mut failures = 0;
    for url in &urls {
        match deliver(url) {
            Ok(()) => println!("{url}\tmaxpane"),
            Err(reason) => {
                // The app is not there. Do not eat the URL.
                match fallback(url) {
                    Ok(()) => println!("{url}\tsystem\t{reason}"),
                    Err(e) => {
                        eprintln!("maxpane-open: {url}: {reason}; fallback failed: {e}");
                        failures += 1;
                    }
                }
            }
        }
    }
    if failures > 0 {
        std::process::exit(1);
    }
}

/// One line of JSON per request, newline-terminated; one line of reply.
///
/// Hand-rolled rather than pulling in serde: the message has three string fields
/// and this binary is worth being able to build and trust at a glance.
fn deliver(url: &str) -> Result<(), String> {
    let path = socket_path();
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("max pane not listening at {}: {e}", path.display()))?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).map_err(|e| e.to_string())?;

    // RELAY_SESSION_ID is set in every session pty-host starts, which is how the
    // app knows which terminal this came from without us having to ask.
    let session = env::var("RELAY_SESSION_ID").unwrap_or_default();
    let cwd = env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();

    let request = format!(
        "{{\"op\":\"open\",\"url\":{},\"session\":{},\"cwd\":{}}}\n",
        json_string(url),
        json_string(&session),
        json_string(&cwd)
    );
    stream.write_all(request.as_bytes()).map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())?;

    let mut reply = String::new();
    io::BufReader::new(&stream).read_line(&mut reply).map_err(|e| e.to_string())?;
    if reply.contains("\"ok\":true") {
        Ok(())
    } else {
        Err(format!("max pane refused: {}", reply.trim()))
    }
}

fn fallback(url: &str) -> Result<(), String> {
    // `open` with no -a goes to the user's default handler, which is what they
    // would have got without the shim.
    let status = Command::new("/usr/bin/open").arg(url).status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("open exited {status}"))
    }
}

/// Minimal JSON string escaping — enough for URLs, paths and session ids.
fn json_string(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escapes_what_json_requires() {
        assert_eq!(json_string("a\"b"), r#""a\"b""#);
        assert_eq!(json_string("a\\b"), r#""a\\b""#);
        assert_eq!(json_string("a\nb"), r#""a\nb""#);
        // Control characters become \uXXXX, built here rather than written
        // as an escape so the expectation cannot be mangled in turn.
        let expected = String::from("\"") + "\\u0001" + "\"";
        assert_eq!(json_string("\u{1}"), expected);
    }

    #[test]
    fn leaves_ordinary_urls_alone() {
        assert_eq!(json_string("https://example.com/a?b=c&d=e#f"), r#""https://example.com/a?b=c&d=e#f""#);
    }

    #[test]
    fn builds_a_request_line_that_is_one_line() {
        // A URL with a newline in it must not be able to inject a second
        // request into the stream.
        let line = format!(
            "{{\"op\":\"open\",\"url\":{},\"session\":{},\"cwd\":{}}}\n",
            json_string("https://x/\n{\"op\":\"quit\"}"),
            json_string("abcd1234"),
            json_string("/tmp")
        );
        assert_eq!(line.matches('\n').count(), 1, "request must be exactly one line");
        assert!(line.ends_with("}\n"));
    }
}
