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
//! maxpane --profile test ls         # ...on the test instance's strip
//! echo https://example.com | maxpane-open
//! ```
//!
//! `--profile NAME` picks which instance to talk to. Every instance has its own
//! socket under its own profile directory, so naming the profile is the whole of
//! addressing it — there is no second variable to keep in step.
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

/// The profile a launch with no `--profile` gets.
const DEFAULT_PROFILE: &str = "default";

/// Names go into a directory path and into a `sockaddr_un`, whose `sun_path` is
/// 104 bytes on Darwin. Kept in step with `Profile.maximumNameLength` on the
/// Swift side: a name the app accepts and the CLI refuses is worse than either.
const MAX_PROFILE_NAME: usize = 32;

/// Take `--profile <name>` / `--profile=<name>` out of the arguments.
///
/// Removed rather than skipped, because `open` filters its remaining arguments
/// on `!starts_with('-')` — leave the pair in place and the profile's *name*
/// survives that filter and is opened as a URL.
fn take_profile(args: &mut Vec<String>) -> Option<String> {
    let mut found = None;
    let mut i = 0;
    while i < args.len() {
        if args[i] == "--profile" {
            args.remove(i);
            if i < args.len() {
                found = Some(args.remove(i));
            } else {
                eprintln!("maxpane: --profile needs a name");
                std::process::exit(2);
            }
            continue;
        }
        if let Some(name) = args[i].strip_prefix("--profile=") {
            found = Some(name.to_string());
            args.remove(i);
            continue;
        }
        i += 1;
    }
    found
}

/// `--profile`, then `MAXPANE_PROFILE`, then the default — the same three rules
/// the app applies, which is what makes `maxpane --profile test ls` reach the
/// instance launched with `--profile test`.
fn resolve_profile(named: Option<String>) -> String {
    let name = profile_or_default(named.or_else(|| env::var("MAXPANE_PROFILE").ok()));
    // Refused, never sanitised. A name quietly rewritten to something valid
    // points the CLI at whichever instance holds that name's socket, and the
    // whole reason to name a profile is to know which instance you are driving.
    if !is_profile_name(&name) {
        eprintln!("maxpane: {name:?} is not a profile name (letters, digits, '.', '_', '-'; at most {MAX_PROFILE_NAME})");
        std::process::exit(2);
    }
    name
}

fn profile_or_default(named: Option<String>) -> String {
    named.unwrap_or_else(|| DEFAULT_PROFILE.to_string())
}

fn is_profile_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_PROFILE_NAME
        && name != "."
        && name != ".."
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Where the app listens. Under Application Support next to the ledger, so the
/// two things that define a running Max Pane live together.
fn socket_path(profile: &str) -> PathBuf {
    if let Ok(p) = env::var("MAXPANE_SOCKET") {
        return PathBuf::from(p);
    }
    let home = env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    socket_under(&home, profile)
}

/// Split from `socket_path` so the layout can be asserted without a test having
/// to reach for `set_var`: cargo runs tests in threads, and the environment is
/// the one piece of state they all share.
fn socket_under(home: &str, profile: &str) -> PathBuf {
    PathBuf::from(home).join(format!("Library/Application Support/MaxPane/profiles/{profile}/open.sock"))
}

fn usage() -> ! {
    eprintln!(
        "usage: maxpane [--profile NAME] <command> [args]
       maxpane-open [URL]          (the BROWSER shim)

commands:
  open URL              open URL as a web lane, right of the calling terminal
  run [COMMAND...]      new terminal lane running COMMAND (default: your shell)
  run @NAME [COMMAND...] the same, on a remote server (maxpane server ls)
  ls                    list what is on the strip; a web pane making sound
                        reads web[audible], a muted one web[muted]
  mute [LANE|all]       silence a lane's pages without pausing them. LANE is
                        the number `ls` prints, or left / right for a dock.
                        With none, or all: whatever is making sound
  unmute [LANE|all]     the reverse. With none, or all: whatever is muted
  volume LANE 0-100     how loud a lane's pages are; 0 is mute
  capture [LANE] [--full]
                        write a PNG of a lane's focused pane and print its
                        path. With no LANE, the focused pane. --full is the
                        whole page for a web pane, below the fold as well;
                        a terminal has no fold and ignores it. The path is
                        typed at the nearest prompt in that lane too
  sessions              list every session, here and on each server
  attach [NAME:]ID      put a running session on the strip as a lane
  server add NAME URL   add a remote relay-tty server: NAME is what the lane
                        header shows, URL is the auth URL the server printed
                        at startup (…/api/auth/callback?token=…); the token
                        goes to the Keychain, the rest to config.toml
  server ls             list the configured servers, their colour and how
                        they are doing
  server color NAME COLOR
                        the colour NAME is known by: slate, cyan, blue,
                        violet, magenta, rose, lemon or ink
  socket                print the control socket path
  profile               print which profile this would talk to

--profile NAME talks to the instance launched with `--profile NAME`, which has
its own strip, config, logins and socket. Without it, the default profile — the
one you are working in. MAXPANE_PROFILE sets it for a whole shell.

With no URL, `open` reads one per line from stdin. When Max Pane is not running,
`open` falls back to the system browser."
    );
    std::process::exit(2)
}

/// Entry point for both binaries. Dispatch is by `argv[0]`.
pub fn run() {
    let argv0 = env::args().next().unwrap_or_default();
    let invoked_as_shim = PathBuf::from(&argv0).file_name().map(|n| n == "maxpane-open").unwrap_or(false);

    let mut args: Vec<String> = env::args().skip(1).collect();
    // Pulled out before dispatch so `--profile` may sit anywhere — before the
    // subcommand or after it. Requiring one position means the other one fails
    // by talking to the default instance, which is silent and is the whole
    // class of mistake this argument exists to end.
    let profile = resolve_profile(take_profile(&mut args));

    // `maxpane-open <url>`: BROWSER passes a bare URL and nothing else.
    if invoked_as_shim {
        if matches!(args.first().map(String::as_str), Some("--print-socket")) {
            println!("{}", socket_path(&profile).display());
            return;
        }
        return open_command(&args, &profile);
    }

    match args.first().map(String::as_str) {
        None | Some("-h") | Some("--help") => usage(),
        Some("socket") | Some("--print-socket") => println!("{}", socket_path(&profile).display()),
        Some("profile") => println!("{profile}"),
        Some("open") => open_command(&args[1..], &profile),
        Some("run") => run_command(&args[1..], &profile),
        Some("ls") => list_command(&profile),
        Some("sessions") => sessions_command(&profile),
        Some("mute") => sound_command(mute_payload(true, args.get(1).map(String::as_str)), &profile),
        Some("unmute") => sound_command(mute_payload(false, args.get(1).map(String::as_str)), &profile),
        Some("volume") => match volume_payload(&args[1..]) {
            Ok(payload) => sound_command(payload, &profile),
            Err(why) => {
                eprintln!("maxpane: {why}");
                std::process::exit(2)
            }
        },
        Some("capture") => match capture_payload(&args[1..]) {
            Ok(payload) => sound_command(payload, &profile),
            Err(why) => {
                eprintln!("maxpane: {why}");
                std::process::exit(2)
            }
        },
        Some("attach") => attach_command(&args[1..], &profile),
        Some("server") => server_command(&args[1..], &profile),
        Some(other) => {
            eprintln!("maxpane: unknown command {other:?}");
            usage()
        }
    }
}

// ---- open ------------------------------------------------------------------

fn open_command(args: &[String], profile: &str) {
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
        match request(&payload, profile) {
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
fn run_command(args: &[String], profile: &str) {
    // `@NAME` first, ⌘O's own grammar: run it on that server.
    if let Some(server) = args.first().and_then(|a| a.strip_prefix('@')) {
        return run_on_server(server, &args[1..], profile);
    }
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

    match request(&payload, profile) {
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

/// `maxpane run @yorkshire claude`. No session id comes back: the server
/// answers the app after the app has answered this, so the lane turns up in
/// `maxpane ls` a moment later.
fn run_on_server(server: &str, args: &[String], profile: &str) {
    if server.is_empty() || server == "local" {
        return run_command(args, profile);
    }
    let command = args.first().cloned().unwrap_or_default();
    let json_args: String =
        args.iter().skip(1).map(|a| json_string(a)).collect::<Vec<_>>().join(",");
    let payload = format!(
        "{{\"op\":\"run\",\"server\":{},\"command\":{},\"args\":[{}]}}",
        json_string(server),
        json_string(&command),
        json_args
    );
    match request(&payload, profile) {
        Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1);
        }
    }
}

// ---- sessions, attach --------------------------------------------------------

/// One line per session the app knows about, here and on every server.
fn sessions_command(profile: &str) {
    match request("{\"op\":\"sessions\"}", profile) {
        Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1);
        }
    }
}

/// `maxpane attach a7ab2d3b`, `maxpane attach yorkshire:0368d543`.
fn attach_command(args: &[String], profile: &str) {
    let Some(key) = args.first() else {
        eprintln!("maxpane: attach needs a session id (maxpane sessions)");
        usage();
    };
    let (server, id) = match key.split_once(':') {
        Some((server, id)) => (server, id),
        None => ("", key.as_str()),
    };
    let payload = format!(
        "{{\"op\":\"attach\",\"server\":{},\"id\":{}}}",
        json_string(server),
        json_string(id)
    );
    match request(&payload, profile) {
        Ok(reply) => println!("{}", field(&reply, "session").unwrap_or_default()),
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1);
        }
    }
}

// ---- sound -----------------------------------------------------------------

/// The request for `maxpane mute [LANE|all]` and `maxpane unmute [LANE|all]`.
/// No lane is `all`: the app decides what that means (what is audible, or
/// what is muted), because only it knows.
fn mute_payload(muted: bool, lane: Option<&str>) -> String {
    format!(
        "{{\"op\":\"{}\",\"lane\":{}}}",
        if muted { "mute" } else { "unmute" },
        json_string(lane.unwrap_or("all"))
    )
}

/// The request for `maxpane volume LANE 0-100`. The range is checked here so
/// a typo is an answer at the prompt and not a refused request.
fn volume_payload(args: &[String]) -> Result<String, String> {
    let (lane, level) = match args {
        [lane, level] => (lane, level),
        _ => return Err("volume needs LANE and a level, 0 to 100".into()),
    };
    let percent: u32 = level
        .trim_end_matches('%')
        .parse()
        .ok()
        .filter(|p| *p <= 100)
        .ok_or_else(|| format!("volume is 0 to 100, not {level}"))?;
    Ok(format!("{{\"op\":\"volume\",\"lane\":{},\"percent\":{percent}}}", json_string(lane)))
}

/// The request for `maxpane capture [LANE] [--full]`. The flag may come on
/// either side of the lane, because `capture --full 2` and `capture 2 --full`
/// are the same thought and a CLI that accepts only one of them is a CLI you
/// have to remember. No lane at all is the focused pane, which is what an
/// agent asking for a picture of "my pane" means.
fn capture_payload(args: &[String]) -> Result<String, String> {
    let mut lane: Option<&str> = None;
    let mut full = false;
    for arg in args {
        match arg.as_str() {
            "--full" | "-f" => full = true,
            other if other.starts_with('-') => return Err(format!("capture: unknown flag {other}")),
            other if lane.is_none() => lane = Some(other),
            other => return Err(format!("capture takes one lane, not also {other:?}")),
        }
    }
    Ok(format!(
        "{{\"op\":\"capture\",\"lane\":{},\"full\":{full}}}",
        json_string(lane.unwrap_or(""))
    ))
}

fn sound_command(payload: String, profile: &str) {
    match request(&payload, profile) {
        Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
        Err(reason) => {
            eprintln!("maxpane: {reason}");
            std::process::exit(1)
        }
    }
}

// ---- server ----------------------------------------------------------------

/// The request for `maxpane server color NAME COLOR`. The app knows the
/// eight colours and says so when this is not one of them; nothing here
/// keeps a second list to fall out of step.
fn server_color_payload(name: &str, color: &str) -> String {
    format!(
        "{{\"op\":\"server-color\",\"name\":{},\"color\":{}}}",
        json_string(name),
        json_string(color)
    )
}

/// `maxpane server add NAME URL`, `maxpane server ls` and
/// `maxpane server color NAME COLOR`.
///
/// The URL carries the server's token. It goes to the app over the
/// owner-only socket and from there to the Keychain; it is never printed,
/// and the reply echoes the base URL only.
fn server_command(args: &[String], profile: &str) {
    match args.first().map(String::as_str) {
        Some("add") => {
            let (Some(name), Some(url)) = (args.get(1), args.get(2)) else {
                eprintln!("maxpane: server add needs NAME and the server's auth URL");
                usage();
            };
            let payload = format!(
                "{{\"op\":\"server-add\",\"name\":{},\"url\":{}}}",
                json_string(name),
                json_string(url)
            );
            match request(&payload, profile) {
                Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
                Err(reason) => {
                    eprintln!("maxpane: {reason}");
                    std::process::exit(1);
                }
            }
        }
        // `colour` too: the owner spells it that way, and a CLI that refuses
        // a spelling is a CLI that gets aliased.
        Some("color") | Some("colour") => {
            let (Some(name), Some(color)) = (args.get(1), args.get(2)) else {
                eprintln!("maxpane: server color needs NAME and a colour");
                usage();
            };
            match request(&server_color_payload(name, color), profile) {
                Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
                Err(reason) => {
                    eprintln!("maxpane: {reason}");
                    std::process::exit(1);
                }
            }
        }
        Some("ls") | None => match request("{\"op\":\"server-ls\"}", profile) {
            Ok(reply) => print!("{}", field(&reply, "lanes").unwrap_or_default()),
            Err(reason) => {
                eprintln!("maxpane: {reason}");
                std::process::exit(1);
            }
        },
        Some(other) => {
            eprintln!("maxpane: unknown server command {other:?}");
            usage();
        }
    }
}

// ---- ls --------------------------------------------------------------------

/// One line per lane, tab-separated, so it pipes.
fn list_command(profile: &str) {
    match request("{\"op\":\"ls\"}", profile) {
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
fn request(payload: &str, profile: &str) -> Result<String, String> {
    let path = socket_path(profile);
    let mut stream = UnixStream::connect(&path)
        .map_err(|e| format!("max pane not listening at {}: {e}", path.display()))?;
    // Longer than the app's own 35 s answer window, so a slow op reaches its
    // reply rather than being cut off here: `capture` waits on WebKit's
    // snapshot and, on a remote lane, on the upload after it.
    stream.set_read_timeout(Some(Duration::from_secs(40))).map_err(|e| e.to_string())?;

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
    fn server_color_is_one_request_with_the_name_and_the_colour() {
        assert_eq!(
            server_color_payload("WSL", "violet"),
            r#"{"op":"server-color","name":"WSL","color":"violet"}"#
        );
        // Whatever is typed is quoted, never spliced.
        let odd = server_color_payload("a\"b", "x\ny");
        assert_eq!(odd, r#"{"op":"server-color","name":"a\"b","color":"x\ny"}"#);
        assert_eq!(odd.matches('\n').count(), 0);
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
    fn capture_says_which_lane_and_how_much_of_it() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            capture_payload(&args(&[])).unwrap(),
            r#"{"op":"capture","lane":"","full":false}"#,
            "no lane is the focused pane; the app decides what that is"
        );
        assert_eq!(capture_payload(&args(&["2"])).unwrap(), r#"{"op":"capture","lane":"2","full":false}"#);
        assert_eq!(capture_payload(&args(&["left"])).unwrap(), r#"{"op":"capture","lane":"left","full":false}"#);
        // The flag reads the same on either side of the lane.
        assert_eq!(capture_payload(&args(&["2", "--full"])).unwrap(), r#"{"op":"capture","lane":"2","full":true}"#);
        assert_eq!(capture_payload(&args(&["--full", "2"])).unwrap(), r#"{"op":"capture","lane":"2","full":true}"#);
        assert_eq!(capture_payload(&args(&["-f"])).unwrap(), r#"{"op":"capture","lane":"","full":true}"#);
        // A typo is a refusal, not a lane named --fll.
        assert!(capture_payload(&args(&["--fll"])).is_err());
        assert!(capture_payload(&args(&["1", "2"])).is_err());
    }

    #[test]
    fn mute_and_volume_say_which_lane_and_how_loud() {
        assert_eq!(mute_payload(true, Some("3")), r#"{"op":"mute","lane":"3"}"#);
        assert_eq!(mute_payload(true, None), r#"{"op":"mute","lane":"all"}"#, "no lane is everything audible");
        assert_eq!(mute_payload(false, Some("left")), r#"{"op":"unmute","lane":"left"}"#);
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(volume_payload(&args(&["2", "40"])).unwrap(), r#"{"op":"volume","lane":"2","percent":40}"#);
        assert_eq!(volume_payload(&args(&["2", "40%"])).unwrap(), r#"{"op":"volume","lane":"2","percent":40}"#);
        assert_eq!(volume_payload(&args(&["2", "0"])).unwrap(), r#"{"op":"volume","lane":"2","percent":0}"#);
        assert!(volume_payload(&args(&["2", "101"])).is_err());
        assert!(volume_payload(&args(&["2", "loud"])).is_err());
        assert!(volume_payload(&args(&["2"])).is_err(), "a level with no lane is not a request");
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
        assert_eq!(socket_path("default"), PathBuf::from("/tmp/x.sock"));
        unsafe { env::remove_var("MAXPANE_SOCKET") };
    }

    #[test]
    fn each_profile_has_its_own_socket() {
        assert_eq!(
            socket_under("/Users/nobody", "default"),
            PathBuf::from("/Users/nobody/Library/Application Support/MaxPane/profiles/default/open.sock")
        );
        assert_ne!(socket_under("/Users/nobody", "test"), socket_under("/Users/nobody", "default"));
    }

    #[test]
    fn a_name_at_the_cap_still_fits_in_sun_path() {
        // 104 bytes on Darwin, and the longest accepted name must still fit or
        // `bind` fails at launch with the CLI reporting only "not listening".
        let longest = "x".repeat(MAX_PROFILE_NAME);
        assert!(socket_under("/Users/nobody", &longest).as_os_str().len() < 104);
    }

    #[test]
    fn refuses_a_name_that_would_escape_the_profiles_directory() {
        assert!(!is_profile_name("../../../etc"));
        assert!(!is_profile_name(".."));
        assert!(!is_profile_name(""));
        assert!(!is_profile_name(&"x".repeat(MAX_PROFILE_NAME + 1)));
        assert!(is_profile_name("test"));
        assert!(is_profile_name("gauntlet-p1.2_x"));
    }

    #[test]
    fn profile_arguments_are_removed_not_merely_read() {
        // The name must not survive into `open`'s argument list: it does not
        // start with '-', so it would be normalised into a URL and opened.
        let mut args: Vec<String> = ["--profile", "test", "open", "example.com"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(take_profile(&mut args), Some("test".into()));
        assert_eq!(args, vec!["open", "example.com"]);
    }

    #[test]
    fn profile_may_follow_the_subcommand() {
        let mut args: Vec<String> =
            ["ls", "--profile=test"].iter().map(|s| s.to_string()).collect();
        assert_eq!(take_profile(&mut args), Some("test".into()));
        assert_eq!(args, vec!["ls"]);
    }

    #[test]
    fn no_profile_named_is_the_default_profile() {
        let mut args: Vec<String> = ["ls"].iter().map(|s| s.to_string()).collect();
        assert_eq!(take_profile(&mut args), None);
        assert_eq!(profile_or_default(None), DEFAULT_PROFILE);
    }
}
