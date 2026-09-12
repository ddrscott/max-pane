//! `maxpane` — talk to the running Max Pane from a terminal.
//!
//! Two names, one binary, chosen by `argv[0]`:
//!
//! - **`maxpane-open <url>`** is the `BROWSER` shim from PRD §7.1. A terminal
//!   pane runs with `BROWSER=maxpane-open`, so anything that opens a URL the
//!   polite way (`xdg-open`, `gh browse`, most CLIs) hands it here instead of to
//!   Safari, and it becomes a web lane immediately right of the terminal that
//!   asked, tagged with that terminal's project.
//! - **`maxpane <subcommand>`** is the same channel with a fuller surface, for
//!   driving the app by hand or from a script.
//!
//! ```text
//! maxpane open google.com          # a web lane
//! maxpane run htop                 # a terminal lane running htop
//! maxpane run                      # a terminal lane running your shell
//! maxpane ls                       # what is on the strip
//! echo https://example.com | maxpane-open
//! ```
//!
//! Reads from argv or stdin, writes what it did to stdout, exits non-zero when
//! it could not deliver. If Max Pane is not running, `open` falls back to the
//! system handler — a shim that swallows URLs when the app is closed is worse
//! than no shim.

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
        "usage: maxpane <command> [args]
       maxpane-open [URL]          (the BROWSER shim)

commands:
  open URL              open URL as a web lane, right of the calling terminal
  run [COMMAND...]      new terminal lane running COMMAND (default: your shell)
  ls                    list what is on the strip
  socket                print the control socket path

With no URL, `open` reads one per line from stdin. When Max Pane is not running,
`open` falls back to the system browser."
    );
    std::process::exit(2)
}

/// Entry point for both binaries. Dispatch is by `argv[0]`.
pub fn run() {
    let argv0 = env::args().next().unwrap_or_default();
    let invoked_as_shim = PathBuf::from(&argv0).file_name().map(|n| n == "maxpane-open").unwrap_or(false);

    let args: Vec<String> = env::args().skip(1).collect();

    // `maxpane-open <url>`: BROWSER passes a bare URL and nothing else.
    if invoked_as_shim {
        if matches!(args.first().map(String::as_str), Some("--print-socket")) {
            println!("{}", socket_path().display());
            return;
        }
        return open_command(&args);
    }

    match args.first().map(String::as_str) {
        None | Some("-h") | Some("--help") => usage(),
        Some("socket") | Some("--print-socket") => println!("{}", socket_path().display()),
        Some("open") => open_command(&args[1..]),
        Some("run") => run_command(&args[1..]),
        Some("ls") => list_command(),
        Some(other) => {
            eprintln!("maxpane: unknown command {other:?}");
            usage()
        }
    }
}

// ---- open ------------------------------------------------------------------

fn open_command(args: &[String]) {
    let urls: Vec<String> = if args.is_empty() {
        let mut buf = String::new();
        if io::stdin().read_to_string(&mut buf).is_err() {
            eprintln!("maxpane: could not read stdin");
            std::process::exit(1);
        }
        buf.lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from).collect()
    } else {
        args.iter().filter(|a| !a.starts_with('-')).cloned().collect()
    };

    if urls.is_empty() {
        usage();
    }

    let mut failures = 0;
    for url in &urls {
        let normalized = normalize_url(url);
        let payload = format!(
            "{{\"op\":\"open\",\"url\":{},\"session\":{},\"cwd\":{}}}",
            json_string(&normalized),
            json_string(&session_id()),
            json_string(&cwd())
        );
        match request(&payload) {
            Ok(_) => println!("{normalized}\tmaxpane"),
            Err(reason) => {
                // The app is not there. Do not eat the URL.
                match fallback(&normalized) {
                    Ok(()) => println!("{normalized}\tsystem\t{reason}"),
                    Err(e) => {
                        eprintln!("maxpane: {normalized}: {reason}; fallback failed: {e}");
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

/// What the user typed, as something a web pane can load.
///
/// Done here as well as in the app so `maxpane open google.com` behaves the same
/// as typing it into ⌘L, and so a fallback to the system browser gets a real URL
/// rather than a bare hostname.
fn normalize_url(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.contains("://") {
        return trimmed.to_string();
    }
    // A bare hostname gets a scheme; anything with a space is a search.
    if trimmed.contains(' ') || !trimmed.contains('.') {
        let q: String = trimmed
            .chars()
            .map(|c| match c {
                ' ' => "+".to_string(),
                c if c.is_alphanumeric() || "-_.~".contains(c) => c.to_string(),
                c => {
                    let mut buf = [0u8; 4];
                    c.encode_utf8(&mut buf).bytes().map(|b| format!("%{b:02X}")).collect()
                }
            })
            .collect();
        return format!("https://duckduckgo.com/?q={q}");
    }
    format!("https://{trimmed}")
}

// ---- run -------------------------------------------------------------------

/// `maxpane run htop` — a new terminal lane running `htop`.
///
/// The session is started by the *app*, not here, so it inherits the app's
/// environment and gets `BROWSER` pointed back at this binary. Starting it here
/// would produce a session with no lane attached to it.
fn run_command(args: &[String]) {
    let command = args.first().cloned().unwrap_or_default();
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();
    let json_args: String = rest.iter().map(|a| json_string(a)).collect::<Vec<_>>().join(",");

    let payload = format!(
        "{{\"op\":\"run\",\"command\":{},\"args\":[{}],\"session\":{},\"cwd\":{}}}",
        json_string(&command),
        json_args,
        json_string(&session_id()),
        json_string(&cwd())
    );

    match request(&payload) {
        Ok(reply) => {
            let id = field(&reply, "session").unwrap_or_default();
            let shown = if command.is_empty() { "$SHELL".to_string() } else { args.join(" ") };
            println!("{id}\t{shown}");
        }
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1);
        }
    }
}

// ---- ls --------------------------------------------------------------------

/// One line per lane, tab-separated, so it pipes.
fn list_command() {
    match request("{\"op\":\"ls\"}") {
        Ok(reply) => {
            if let Some(lanes) = field(&reply, "lanes") {
                print!("{lanes}");
                if !lanes.ends_with('\n') && !lanes.is_empty() {
                    println!();
                }
            }
        }
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1);
        }
    }
}

// ---- transport -------------------------------------------------------------

/// One line of JSON out, one line back.
fn request(payload: &str) -> Result<String, String> {
    let path = socket_path();
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("max pane not listening at {}: {e}", path.display()))?;
    stream.set_read_timeout(Some(Duration::from_secs(10))).map_err(|e| e.to_string())?;

    stream.write_all(payload.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(b"\n").map_err(|e| e.to_string())?;
    stream.flush().map_err(|e| e.to_string())?;

    let mut reply = String::new();
    io::BufReader::new(&stream).read_line(&mut reply).map_err(|e| e.to_string())?;
    if reply.contains("\"ok\":true") {
        Ok(reply)
    } else {
        Err(format!(
            "max pane refused: {}",
            field(&reply, "error").unwrap_or_else(|| reply.trim().to_string())
        ))
    }
}

/// `RELAY_SESSION_ID` is set in every session pty-host starts, which is how the
/// app knows which terminal asked without us having to tell it.
fn session_id() -> String {
    env::var("RELAY_SESSION_ID").unwrap_or_default()
}

fn cwd() -> String {
    env::current_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
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

// ---- tiny JSON -------------------------------------------------------------

/// Pull one string field out of a reply. Enough for `{"ok":true,"session":"…"}`;
/// this binary is worth being able to build and trust at a glance, so it does
/// not carry serde.
fn field(json: &str, name: &str) -> Option<String> {
    let key = format!("\"{name}\":\"");
    let start = json.find(&key)? + key.len();
    let mut out = String::new();
    let mut chars = json[start..].chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next() {
                Some('n') => out.push('\n'),
                Some('t') => out.push('\t'),
                Some(other) => out.push(other),
                None => break,
            },
            c => out.push(c),
        }
    }
    None
}

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
        // Control characters become \uXXXX, built here rather than written as an
        // escape so the expectation cannot be mangled in turn.
        let expected = String::from("\"") + "\\u0001" + "\"";
        assert_eq!(json_string("\u{1}"), expected);
    }

    #[test]
    fn leaves_ordinary_urls_alone() {
        assert_eq!(json_string("https://example.com/a?b=c&d=e#f"), r#""https://example.com/a?b=c&d=e#f""#);
    }

    #[test]
    fn builds_a_request_line_that_is_one_line() {
        // A URL with a newline in it must not inject a second request.
        let line = format!(
            "{{\"op\":\"open\",\"url\":{},\"session\":{},\"cwd\":{}}}\n",
            json_string("https://x/\n{\"op\":\"quit\"}"),
            json_string("abcd1234"),
            json_string("/tmp")
        );
        assert_eq!(line.matches('\n').count(), 1, "request must be exactly one line");
    }

    #[test]
    fn a_bare_hostname_gets_a_scheme() {
        assert_eq!(normalize_url("google.com"), "https://google.com");
        assert_eq!(normalize_url("  docs.rs/rusqlite  "), "https://docs.rs/rusqlite");
    }

    #[test]
    fn a_full_url_is_left_alone() {
        assert_eq!(normalize_url("https://example.com/a?b=c"), "https://example.com/a?b=c");
        assert_eq!(normalize_url("http://localhost:8080"), "http://localhost:8080");
    }

    #[test]
    fn something_that_is_not_a_url_becomes_a_search() {
        assert!(normalize_url("rust lifetime elision").starts_with("https://duckduckgo.com/?q="));
        assert!(normalize_url("htop").starts_with("https://duckduckgo.com/?q="));
    }

    #[test]
    fn reads_a_field_out_of_a_reply() {
        assert_eq!(field(r#"{"ok":true,"session":"a7ab2d3b"}"#, "session"), Some("a7ab2d3b".into()));
        assert_eq!(field(r#"{"ok":false,"error":"no such thing"}"#, "error"), Some("no such thing".into()));
        assert_eq!(field(r#"{"ok":true}"#, "session"), None);
    }

    #[test]
    fn socket_path_is_overridable() {
        // The app sets this when it listens somewhere else, e.g. under test.
        unsafe { env::set_var("MAXPANE_SOCKET", "/tmp/x.sock") };
        assert_eq!(socket_path(), PathBuf::from("/tmp/x.sock"));
        unsafe { env::remove_var("MAXPANE_SOCKET") };
    }
}
