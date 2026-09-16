//! Export and import of a whole strip, as JSON (PRD §13 Phase 3).
//!
//! For moving between machines, and — more usefully during the two-week trial —
//! for having a copy of a layout that took days to arrange before doing anything
//! that might disturb it.
//!
//! Deliberately *not* a backup of the ledger file. A ledger is SQLite with
//! ULIDs, a schema version and a snapshot path per pane; a portable strip is
//! what a human would want to move: order, widths, titles, tags, URLs, and which
//! Relay session each terminal was attached to. Ids are regenerated on import,
//! so importing a strip into a machine that already has one merges rather than
//! collides.
//!
//! Hand-rolled JSON rather than serde. The format is nine fields and needs to be
//! readable and hand-editable — someone migrating machines will want to fix a
//! path in it — and this crate does not otherwise carry serde.

use crate::error::{CoreError, Result};
use crate::ledger::{dock_mode_str, dock_side_str, kind_str, parse_dock_mode, project_source_str};
use crate::model::*;

/// The format version, in the file. Bumped only when an old file would be read
/// wrongly rather than merely incompletely.
pub const FORMAT_VERSION: u32 = 1;

/// Serialise a strip.
pub fn export(lanes: &[Lane]) -> String {
    let mut out = String::with_capacity(lanes.len() * 256);
    out.push_str("{\n");
    out.push_str(&format!("  \"format\": \"maxpane.strip\",\n  \"version\": {FORMAT_VERSION},\n"));
    out.push_str("  \"lanes\": [\n");

    for (i, lane) in lanes.iter().enumerate() {
        out.push_str("    {\n");
        out.push_str(&format!("      \"width_pt\": {},\n", lane.width_pt));
        // Written twice on purpose, for one release. `pinned` is what a shipped
        // build reads, and a strip exported here and imported by the copy still
        // on someone's disk would otherwise come back with every protected lane
        // unprotected — silently, since nothing in the file would say so. The
        // format version is not the tool for this: it is for a file an old
        // reader would read *wrongly*, and this one would merely be read
        // incompletely. Drop `pinned` when no build that reads it survives.
        out.push_str(&format!("      \"keep_live\": {},\n", lane.keep_live));
        out.push_str(&format!("      \"pinned\": {},\n", lane.keep_live));
        out.push_str(&format!("      \"span\": {},\n", lane.span));
        // A dock is layout, and layout is the whole of what this format
        // carries: a strip restored without its docks is missing the two things
        // the user looks at most.
        match lane.dock {
            Some(d) => out.push_str(&format!(
                "      \"dock\": {{ \"side\": \"{}\", \"mode\": \"{}\", \"width_pt\": {} }},\n",
                dock_side_str(d.side),
                dock_mode_str(d.mode),
                d.width_pt
            )),
            None => out.push_str("      \"dock\": null,\n"),
        }
        out.push_str(&format!("      \"title\": {},\n", json_opt(lane.title.as_deref())));
        out.push_str(&format!("      \"project_root\": {},\n", json_opt(lane.project_root.as_deref())));
        out.push_str(&format!(
            "      \"project_source\": \"{}\",\n",
            project_source_str(lane.project_source)
        ));
        out.push_str("      \"panes\": [\n");
        for (j, pane) in lane.panes.iter().enumerate() {
            out.push_str("        {\n");
            out.push_str(&format!("          \"kind\": \"{}\",\n", kind_str(pane.kind)));
            out.push_str(&format!(
                "          \"relay_session_id\": {},\n",
                json_opt(pane.relay_session_id.as_deref())
            ));
            out.push_str(&format!("          \"url\": {},\n", json_opt(pane.url.as_deref())));
            out.push_str(&format!(
                "          \"scroll_y\": {},\n",
                pane.scroll_y.map(|v| v.to_string()).unwrap_or_else(|| "null".into())
            ));
            // The split the user arranged is layout, and layout is the whole of
            // what this format carries. A file written before the column existed
            // reads back as 1 everywhere, which is the equal split it described.
            out.push_str(&format!("          \"height_weight\": {},\n", pane.height_weight));
            // Zoom travels with the split for the same reason: how big you made
            // the text is part of how you arranged the strip, not a property of
            // the machine you arranged it on.
            out.push_str(&format!("          \"zoom\": {},\n", pane.zoom));
            // And the layout you asked the site for: a lane kept on the phone
            // page is a lane you arranged that way. A file from before the
            // field existed reads back as the desktop page it was showing.
            out.push_str(&format!("          \"mobile\": {}\n", pane.mobile));
            out.push_str(if j + 1 == lane.panes.len() { "        }\n" } else { "        },\n" });
        }
        out.push_str("      ]\n");
        out.push_str(if i + 1 == lanes.len() { "    }\n" } else { "    },\n" });
    }
    out.push_str("  ]\n}\n");
    out
}

/// One lane from an exported strip, ready to be re-created.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PortableLane {
    pub width_pt: u32,
    pub keep_live: bool,
    /// Where this lane was docked on the machine it came from, if it was.
    /// Honoured on import only when that edge is free; see `Core::import_strip`.
    pub dock: Option<Dock>,
    /// 1 unless the user widened this lane for landscape content.
    pub span: u32,
    pub title: Option<String>,
    pub project_root: Option<String>,
    pub project_source: ProjectSource,
    pub panes: Vec<PortablePane>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PortablePane {
    pub kind: PaneKind,
    pub relay_session_id: Option<String>,
    pub url: Option<String>,
    pub scroll_y: Option<f64>,
    /// This pane's share of its lane's height. 1 for a file written before the
    /// field existed, or hand-edited to drop it.
    pub height_weight: f64,
    pub zoom: f64,
    /// Whether the pane asks for the phone layout. False for a file written
    /// before the field existed.
    pub mobile: bool,
}

/// Parse an exported strip.
///
/// Tolerant on purpose: a file someone hand-edited to fix a path should still
/// import. Unknown keys are ignored, and a missing optional field is `None`
/// rather than an error.
pub fn import(json: &str) -> Result<Vec<PortableLane>> {
    let value = mini_json::parse(json).map_err(|e| CoreError::Invalid { message: e })?;
    let obj = value.object().ok_or_else(|| CoreError::Invalid { message: "not a JSON object".into() })?;

    match obj.iter().find(|(k, _)| k == "format").map(|(_, v)| v.string()) {
        Some(Some("maxpane.strip")) => {}
        _ => {
            return Err(CoreError::Invalid {
                message: "not a Max Pane strip export (missing \"format\": \"maxpane.strip\")".into(),
            })
        }
    }
    if let Some(Some(v)) = obj.iter().find(|(k, _)| k == "version").map(|(_, v)| v.number()) {
        if (v as u32) > FORMAT_VERSION {
            return Err(CoreError::Invalid {
                message: format!("strip was written by a newer Max Pane (version {v})"),
            });
        }
    }

    let lanes = obj
        .iter()
        .find(|(k, _)| k == "lanes")
        .and_then(|(_, v)| v.array())
        .ok_or_else(|| CoreError::Invalid { message: "no \"lanes\" array".into() })?;

    Ok(lanes.iter().filter_map(|l| l.object().map(parse_lane)).collect())
}

fn parse_lane(fields: &[(String, mini_json::Value)]) -> PortableLane {
    let get = |name: &str| fields.iter().find(|(k, _)| k == name).map(|(_, v)| v);
    PortableLane {
        width_pt: get("width_pt").and_then(|v| v.number()).unwrap_or(560.0) as u32,
        // `pinned` is the name this flag had in every file written before
        // ADR-0010. It meant exactly what `keep_live` means, so an old export
        // is read correctly rather than tolerantly.
        keep_live: get("keep_live")
            .or_else(|| get("pinned"))
            .and_then(|v| v.boolean())
            .unwrap_or(false),
        dock: get("dock").and_then(|v| v.object()).and_then(parse_dock),
        span: get("span").and_then(|v| v.number()).unwrap_or(1.0).clamp(1.0, 2.0) as u32,
        title: get("title").and_then(|v| v.string()).map(str::to_string),
        project_root: get("project_root").and_then(|v| v.string()).map(str::to_string),
        project_source: match get("project_source").and_then(|v| v.string()) {
            Some("cwd") => ProjectSource::Cwd,
            Some("manual") => ProjectSource::Manual,
            _ => ProjectSource::Inherited,
        },
        panes: get("panes")
            .and_then(|v| v.array())
            .map(|panes| panes.iter().filter_map(|p| p.object().map(parse_pane)).collect())
            .unwrap_or_default(),
    }
}

/// A dock object, or `None` for a lane that was not docked.
///
/// An unreadable `side` drops the whole dock rather than guessing one: a lane
/// that arrives in the strip is a lane the user can see and dock again, where a
/// lane guessed onto the wrong edge is a lane that has taken over a corner of
/// the screen nobody asked it to.
fn parse_dock(fields: &[(String, mini_json::Value)]) -> Option<Dock> {
    let get = |name: &str| fields.iter().find(|(k, _)| k == name).map(|(_, v)| v);
    let side = match get("side").and_then(|v| v.string()) {
        Some("left") => DockSide::Left,
        Some("right") => DockSide::Right,
        _ => return None,
    };
    Some(Dock {
        side,
        mode: get("mode").and_then(|v| v.string()).map(parse_dock_mode).unwrap_or(DockMode::Inset),
        width_pt: get("width_pt")
            .and_then(|v| v.number())
            .filter(|w| w.is_finite() && *w > 0.0)
            .map(|w| w as u32)
            // The core clamps this on the way in, so an out-of-range hand edit
            // lands at a bound rather than being refused. A missing width is
            // the one thing that needs a value here, and the lane's own width
            // is the same default `Core::dock_lane` would have used.
            .unwrap_or(crate::LANE_MIN_PT),
    })
}

fn parse_pane(fields: &[(String, mini_json::Value)]) -> PortablePane {
    let get = |name: &str| fields.iter().find(|(k, _)| k == name).map(|(_, v)| v);
    PortablePane {
        kind: match get("kind").and_then(|v| v.string()) {
            Some("pty") => PaneKind::Pty,
            // An exported placeholder comes back as a web pane: the snapshot did
            // not travel, and the URL is all that was worth keeping anyway.
            _ => PaneKind::Web,
        },
        relay_session_id: get("relay_session_id").and_then(|v| v.string()).map(str::to_string),
        url: get("url").and_then(|v| v.string()).map(str::to_string),
        scroll_y: get("scroll_y").and_then(|v| v.number()),
        // A hand-edited 0 or a negative would make `Σw` meaningless for the
        // whole lane, so anything that is not a usable ratio falls back to the
        // equal share rather than importing a lane nobody can lay out.
        height_weight: get("height_weight")
            .and_then(|v| v.number())
            .filter(|w| w.is_finite() && *w > 0.0)
            .unwrap_or(1.0),
        zoom: get("zoom")
            .and_then(|v| v.number())
            .filter(|z| z.is_finite() && *z > 0.0)
            .unwrap_or(1.0),
        mobile: get("mobile").and_then(|v| v.boolean()).unwrap_or(false),
    }
}

fn json_opt(s: Option<&str>) -> String {
    match s {
        Some(v) => json_string(v),
        None => "null".into(),
    }
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

/// A JSON reader just large enough for the format above.
///
/// Pulling in serde for one import path would add a derive dependency to a crate
/// that otherwise has none. This handles the whole grammar except numeric
/// exponents, which this format never writes.
mod mini_json {
    #[derive(Debug, Clone, PartialEq)]
    pub enum Value {
        Null,
        Bool(bool),
        Number(f64),
        String(String),
        Array(Vec<Value>),
        Object(Vec<(String, Value)>),
    }

    impl Value {
        pub fn object(&self) -> Option<&[(String, Value)]> {
            match self {
                Value::Object(o) => Some(o),
                _ => None,
            }
        }
        pub fn array(&self) -> Option<&[Value]> {
            match self {
                Value::Array(a) => Some(a),
                _ => None,
            }
        }
        pub fn string(&self) -> Option<&str> {
            match self {
                Value::String(s) => Some(s),
                _ => None,
            }
        }
        pub fn number(&self) -> Option<f64> {
            match self {
                Value::Number(n) => Some(*n),
                _ => None,
            }
        }
        pub fn boolean(&self) -> Option<bool> {
            match self {
                Value::Bool(b) => Some(*b),
                _ => None,
            }
        }
    }

    pub fn parse(input: &str) -> Result<Value, String> {
        let bytes: Vec<char> = input.chars().collect();
        let mut pos = 0;
        let value = parse_value(&bytes, &mut pos)?;
        skip_space(&bytes, &mut pos);
        if pos < bytes.len() {
            return Err(format!("trailing input at character {pos}"));
        }
        Ok(value)
    }

    fn skip_space(b: &[char], pos: &mut usize) {
        while *pos < b.len() && b[*pos].is_whitespace() {
            *pos += 1;
        }
    }

    fn parse_value(b: &[char], pos: &mut usize) -> Result<Value, String> {
        skip_space(b, pos);
        match b.get(*pos) {
            None => Err("unexpected end of input".into()),
            Some('{') => parse_object(b, pos),
            Some('[') => parse_array(b, pos),
            Some('"') => Ok(Value::String(parse_string(b, pos)?)),
            Some('t') => literal(b, pos, "true", Value::Bool(true)),
            Some('f') => literal(b, pos, "false", Value::Bool(false)),
            Some('n') => literal(b, pos, "null", Value::Null),
            Some(_) => parse_number(b, pos),
        }
    }

    fn literal(b: &[char], pos: &mut usize, word: &str, value: Value) -> Result<Value, String> {
        if b[*pos..].starts_with(&word.chars().collect::<Vec<_>>()[..]) {
            *pos += word.len();
            Ok(value)
        } else {
            Err(format!("expected {word} at character {pos}"))
        }
    }

    fn parse_object(b: &[char], pos: &mut usize) -> Result<Value, String> {
        *pos += 1; // '{'
        let mut fields = Vec::new();
        loop {
            skip_space(b, pos);
            match b.get(*pos) {
                Some('}') => {
                    *pos += 1;
                    return Ok(Value::Object(fields));
                }
                Some(',') => {
                    *pos += 1;
                    continue;
                }
                Some('"') => {
                    let key = parse_string(b, pos)?;
                    skip_space(b, pos);
                    if b.get(*pos) != Some(&':') {
                        return Err(format!("expected ':' at character {pos}"));
                    }
                    *pos += 1;
                    fields.push((key, parse_value(b, pos)?));
                }
                _ => return Err(format!("malformed object at character {pos}")),
            }
        }
    }

    fn parse_array(b: &[char], pos: &mut usize) -> Result<Value, String> {
        *pos += 1; // '['
        let mut items = Vec::new();
        loop {
            skip_space(b, pos);
            match b.get(*pos) {
                Some(']') => {
                    *pos += 1;
                    return Ok(Value::Array(items));
                }
                Some(',') => {
                    *pos += 1;
                    continue;
                }
                None => return Err("unterminated array".into()),
                _ => items.push(parse_value(b, pos)?),
            }
        }
    }

    fn parse_string(b: &[char], pos: &mut usize) -> Result<String, String> {
        *pos += 1; // '"'
        let mut out = String::new();
        while let Some(&c) = b.get(*pos) {
            *pos += 1;
            match c {
                '"' => return Ok(out),
                '\\' => {
                    let esc = b.get(*pos).copied().ok_or("unterminated escape")?;
                    *pos += 1;
                    out.push(match esc {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'b' => '\u{8}',
                        'f' => '\u{c}',
                        'u' => {
                            let hex: String = b.get(*pos..*pos + 4).ok_or("short \\u")?.iter().collect();
                            *pos += 4;
                            let code = u32::from_str_radix(&hex, 16).map_err(|_| "bad \\u")?;
                            char::from_u32(code).ok_or("bad code point")?
                        }
                        other => other,
                    });
                }
                c => out.push(c),
            }
        }
        Err("unterminated string".into())
    }

    fn parse_number(b: &[char], pos: &mut usize) -> Result<Value, String> {
        let start = *pos;
        if b.get(*pos) == Some(&'-') {
            *pos += 1;
        }
        while matches!(b.get(*pos), Some(c) if c.is_ascii_digit() || *c == '.') {
            *pos += 1;
        }
        let text: String = b[start..*pos].iter().collect();
        text.parse::<f64>().map(Value::Number).map_err(|_| format!("bad number at character {start}"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lane(title: &str, width: u32, panes: Vec<Pane>) -> Lane {
        Lane {
            id: "ignored".into(),
            ordinal: 0.0,
            width_pt: width,
            title: Some(title.into()),
            project_root: Some("/src/foo".into()),
            project_source: ProjectSource::Manual,
            created_at: 0,
            last_focus_at: 0,
            keep_live: true,
            dock: None,
            span: 1,
            panes,
        }
    }

    fn pane(kind: PaneKind, url: Option<&str>, session: Option<&str>) -> Pane {
        Pane {
            id: "ignored".into(),
            lane_id: "ignored".into(),
            position: 0,
            kind,
            relay_session_id: session.map(str::to_string),
            url: url.map(str::to_string),
            scroll_y: Some(1200.5),
            data_store_id: None,
            snapshot_path: None,
            state: PaneState::Live,
            height_weight: 1.0,
            zoom: 1.0,
            mobile: false,
        }
    }

    #[test]
    fn a_strip_survives_a_round_trip() {
        let lanes = vec![
            lane("docs", 640, vec![pane(PaneKind::Web, Some("https://docs.rs/rusqlite"), None)]),
            lane("agent", 720, vec![pane(PaneKind::Pty, None, Some("a7ab2d3b"))]),
        ];

        let back = import(&export(&lanes)).unwrap();
        assert_eq!(back.len(), 2);

        assert_eq!(back[0].title.as_deref(), Some("docs"));
        assert_eq!(back[0].width_pt, 640);
        assert!(back[0].keep_live);
        assert_eq!(back[0].project_root.as_deref(), Some("/src/foo"));
        assert_eq!(back[0].project_source, ProjectSource::Manual);
        assert_eq!(back[0].panes[0].url.as_deref(), Some("https://docs.rs/rusqlite"));
        assert_eq!(back[0].panes[0].scroll_y, Some(1200.5));

        assert_eq!(back[1].panes[0].kind, PaneKind::Pty);
        assert_eq!(back[1].panes[0].relay_session_id.as_deref(), Some("a7ab2d3b"));
    }

    #[test]
    fn a_lane_with_several_panes_keeps_their_order() {
        let lanes = vec![lane(
            "stack",
            600,
            vec![
                pane(PaneKind::Pty, None, Some("s1")),
                pane(PaneKind::Web, Some("https://a"), None),
                pane(PaneKind::Web, Some("https://b"), None),
            ],
        )];
        let back = import(&export(&lanes)).unwrap();
        let urls: Vec<Option<&str>> = back[0].panes.iter().map(|p| p.url.as_deref()).collect();
        assert_eq!(urls, vec![None, Some("https://a"), Some("https://b")]);
    }

    #[test]
    fn an_evicted_pane_comes_back_as_a_web_pane() {
        // The snapshot does not travel between machines, and the URL is the only
        // part that was worth keeping.
        let mut p = pane(PaneKind::Placeholder, Some("https://x"), None);
        p.state = PaneState::Evicted;
        let back = import(&export(&[lane("evicted", 600, vec![p])])).unwrap();
        assert_eq!(back[0].panes[0].kind, PaneKind::Web);
        assert_eq!(back[0].panes[0].url.as_deref(), Some("https://x"));
    }

    #[test]
    fn titles_with_quotes_and_newlines_survive() {
        let lanes = vec![lane(
            "say \"hi\"\nand \\ bye\t",
            600,
            vec![pane(PaneKind::Web, Some("https://a?b=c&d=e"), None)],
        )];
        let back = import(&export(&lanes)).unwrap();
        assert_eq!(back[0].title.as_deref(), Some("say \"hi\"\nand \\ bye\t"));
        assert_eq!(back[0].panes[0].url.as_deref(), Some("https://a?b=c&d=e"));
    }

    #[test]
    fn an_empty_strip_round_trips() {
        assert!(import(&export(&[])).unwrap().is_empty());
    }

    #[test]
    fn a_hand_edited_file_still_imports() {
        // Someone fixing a path by hand will not reproduce our whitespace, and
        // may leave a key we do not know about.
        let json = r#"{
            "format":"maxpane.strip","version":1,
            "lanes":[{"width_pt":700,"panes":[{"kind":"web","url":"https://moved"}],"note":"edited"}]
        }"#;
        let back = import(json).unwrap();
        assert_eq!(back[0].width_pt, 700);
        assert_eq!(back[0].panes[0].url.as_deref(), Some("https://moved"));
        assert!(back[0].title.is_none());
    }

    #[test]
    fn something_that_is_not_a_strip_is_refused() {
        assert!(import("{}").is_err());
        assert!(import(r#"{"format":"something-else"}"#).is_err());
        assert!(import("not json").is_err());
        assert!(import("").is_err());
    }

    #[test]
    fn a_newer_format_is_refused_rather_than_half_read() {
        let json = r#"{"format":"maxpane.strip","version":99,"lanes":[]}"#;
        let err = import(json).unwrap_err();
        assert!(format!("{err}").contains("newer"), "{err}");
    }
}
