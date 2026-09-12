//! Fuzzy search over lane titles, project roots, pane URLs and terminal
//! scrollback.
//!
//! Scrollback is deliberately *not* in SQLite. It is volatile, it is re-pushed
//! by the shell from SwiftTerm's buffer on every debounce, and it would dominate
//! the ledger's size for something that is never worth restoring. It lives in a
//! capped in-memory map instead.

use crate::model::{Lane, SearchField, SearchHit};
use std::collections::HashMap;

/// PRD §7.5: at most this many lines of scrollback per pane in the index.
pub const SCROLLBACK_LINES_PER_PANE: usize = 200;

#[derive(Default)]
pub struct Index {
    /// pane id -> its most recent scrollback lines, newest last.
    scrollback: HashMap<String, Vec<String>>,
}

impl Index {
    /// Replace a pane's scrollback contribution. Keeps only the last
    /// [`SCROLLBACK_LINES_PER_PANE`] lines.
    pub fn set_scrollback(&mut self, pane_id: &str, mut lines: Vec<String>) {
        if lines.len() > SCROLLBACK_LINES_PER_PANE {
            lines.drain(..lines.len() - SCROLLBACK_LINES_PER_PANE);
        }
        self.scrollback.insert(pane_id.to_string(), lines);
    }

    pub fn forget(&mut self, pane_id: &str) {
        self.scrollback.remove(pane_id);
    }

    /// Best hits for `query`, highest score first, at most `limit`.
    ///
    /// At most one hit per pane: the palette lists places to go, not every line
    /// that happened to match.
    pub fn search(&self, lanes: &[Lane], query: &str, limit: usize) -> Vec<SearchHit> {
        if query.trim().is_empty() {
            return Vec::new();
        }
        let needle = query.to_lowercase();
        let mut best: HashMap<String, SearchHit> = HashMap::new();

        let mut offer = |hit: SearchHit| {
            let e = best.entry(hit.pane_id.clone()).or_insert_with(|| hit.clone());
            if hit.score > e.score {
                *e = hit;
            }
        };

        for lane in lanes {
            // A lane with no panes can still be worth finding, so attribute
            // lane-level matches to the lane's first pane when it has one.
            let anchor = lane.panes.first().map(|p| p.id.clone()).unwrap_or_else(|| lane.id.clone());

            if let Some(t) = &lane.title {
                if let Some(score) = fuzzy_score(&needle, &t.to_lowercase()) {
                    offer(SearchHit {
                        lane_id: lane.id.clone(),
                        pane_id: anchor.clone(),
                        text: t.clone(),
                        field: SearchField::Title,
                        // Titles are what the user actually remembers.
                        score: score + 200,
                    });
                }
            }
            if let Some(root) = &lane.project_root {
                if let Some(score) = fuzzy_score(&needle, &root.to_lowercase()) {
                    offer(SearchHit {
                        lane_id: lane.id.clone(),
                        pane_id: anchor.clone(),
                        text: root.clone(),
                        field: SearchField::ProjectRoot,
                        score: score + 100,
                    });
                }
            }
            for pane in &lane.panes {
                if let Some(url) = &pane.url {
                    if let Some(score) = fuzzy_score(&needle, &url.to_lowercase()) {
                        offer(SearchHit {
                            lane_id: lane.id.clone(),
                            pane_id: pane.id.clone(),
                            text: url.clone(),
                            field: SearchField::Url,
                            score: score + 150,
                        });
                    }
                }
                if let Some(lines) = self.scrollback.get(&pane.id) {
                    // Newest lines first: recent output is what the user is
                    // hunting for.
                    for line in lines.iter().rev() {
                        if let Some(score) = fuzzy_score(&needle, &line.to_lowercase()) {
                            offer(SearchHit {
                                lane_id: lane.id.clone(),
                                pane_id: pane.id.clone(),
                                text: line.trim().to_string(),
                                field: SearchField::Scrollback,
                                score,
                            });
                            break;
                        }
                    }
                }
            }
        }

        let mut hits: Vec<SearchHit> = best.into_values().collect();
        hits.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.text.len().cmp(&b.text.len())));
        hits.truncate(limit);
        hits
    }
}

/// Subsequence fuzzy match, both arguments already lowercased.
///
/// `None` when `needle` is not a subsequence of `haystack`. Otherwise a score
/// that rewards contiguous runs, matches at word boundaries, and short
/// haystacks — the usual command-palette feel.
pub fn fuzzy_score(needle: &str, haystack: &str) -> Option<i32> {
    if needle.is_empty() {
        return Some(0);
    }
    let hay: Vec<char> = haystack.chars().collect();
    let mut score = 0i32;
    let mut hi = 0usize;
    let mut run = 0i32;

    for nc in needle.chars() {
        if nc == ' ' {
            // Spaces in the query separate terms rather than requiring a literal
            // space in the target.
            run = 0;
            continue;
        }
        let found = hay[hi..].iter().position(|&c| c == nc)?;
        let at = hi + found;
        if found == 0 && hi > 0 {
            run += 1;
            score += 10 + run * 5; // contiguous run, accelerating
        } else {
            run = 0;
            score += 1;
        }
        let boundary = at == 0 || matches!(hay[at - 1], ' ' | '/' | '-' | '_' | '.' | ':');
        if boundary {
            score += 15;
        }
        hi = at + 1;
    }
    // Prefer the tighter of two otherwise-equal matches.
    score += (100 - (hay.len() as i32).min(100)) / 4;
    Some(score)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_subsequence_does_not_match() {
        assert!(fuzzy_score("xyz", "hello world").is_none());
    }

    #[test]
    fn subsequence_matches() {
        assert!(fuzzy_score("hlo", "hello").is_some());
    }

    #[test]
    fn contiguous_beats_scattered() {
        let contiguous = fuzzy_score("relay", "relay-tty").unwrap();
        let scattered = fuzzy_score("relay", "r e l a y").unwrap();
        assert!(contiguous > scattered, "{contiguous} !> {scattered}");
    }

    #[test]
    fn word_boundary_beats_mid_word() {
        let boundary = fuzzy_score("core", "laned/core").unwrap();
        let midword = fuzzy_score("core", "xxcorexx").unwrap();
        assert!(boundary > midword, "{boundary} !> {midword}");
    }

    #[test]
    fn spaces_separate_terms() {
        assert!(fuzzy_score("max pane", "maxpane").is_some());
    }

    #[test]
    fn empty_query_finds_nothing() {
        let idx = Index::default();
        assert!(idx.search(&[], "   ", 10).is_empty());
    }

    #[test]
    fn scrollback_is_capped() {
        let mut idx = Index::default();
        let lines: Vec<String> = (0..500).map(|i| format!("line {i}")).collect();
        idx.set_scrollback("p1", lines);
        let kept = idx.scrollback.get("p1").unwrap();
        assert_eq!(kept.len(), SCROLLBACK_LINES_PER_PANE);
        // The tail is what was kept.
        assert_eq!(kept.last().unwrap(), "line 499");
    }
}
