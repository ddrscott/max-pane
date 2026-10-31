//! Browser-style back and forward through the panes you have been in.
//!
//! A list of pane ids and a cursor on the one you are in, and nothing else:
//! the rules are the ones a browser's history has, so going back three and
//! forward one lands where anyone would expect.
//!
//! - Focusing a pane appends it after the cursor and drops whatever was ahead.
//! - A step only moves the cursor. The focus it causes then arrives at
//!   [`PaneHistory::visit`] naming the pane already under the cursor, which is
//!   a no-op, so stepping can never grow the list. There is no "I am stepping"
//!   flag to get wrong on one of the many paths that focus a pane.
//! - Closed panes are not hunted down on every path that can end one (close,
//!   end session, purge, import, a lane going with its panes). A step calls
//!   [`PaneHistory::compact`] with what is alive right then.

/// The oldest entries fall off past this. The list is rewritten on every
/// focus change, so it stays a size that write does not notice.
pub const PANE_HISTORY_MAX: usize = 256;

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct PaneHistory {
    entries: Vec<String>,
    cursor: usize,
}

impl PaneHistory {
    /// What `app_state` holds. Anything unreadable is an empty history: this
    /// is a convenience, and never a reason for the ledger not to open.
    pub fn parse(raw: &str) -> Self {
        let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
            return Self::default();
        };
        let entries: Vec<String> = value["entries"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
            .unwrap_or_default();
        let cursor = value["cursor"].as_u64().unwrap_or(0) as usize;
        Self { cursor: cursor.min(entries.len().saturating_sub(1)), entries }
    }

    pub fn to_json(&self) -> String {
        serde_json::json!({ "entries": self.entries, "cursor": self.cursor }).to_string()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// The pane the cursor is on.
    pub fn current(&self) -> Option<&str> {
        self.entries.get(self.cursor).map(String::as_str)
    }

    /// A pane took focus. Returns false when that changed nothing, which is
    /// what a step's own focus and a click inside the current pane both are.
    pub fn visit(&mut self, pane_id: &str) -> bool {
        if self.current() == Some(pane_id) {
            return false;
        }
        self.entries.truncate(self.cursor + 1);
        self.entries.push(pane_id.to_owned());
        if self.entries.len() > PANE_HISTORY_MAX {
            let excess = self.entries.len() - PANE_HISTORY_MAX;
            self.entries.drain(..excess);
        }
        self.cursor = self.entries.len() - 1;
        true
    }

    /// Drop every entry `alive` refuses, and the repeats that leaves side by
    /// side: A B A with B gone is one A, or Back would land on the pane you
    /// are already in. The cursor stays on its pane, or moves to the nearest
    /// survivor before it.
    pub fn compact(&mut self, alive: impl Fn(&str) -> bool) {
        let mut kept: Vec<String> = Vec::with_capacity(self.entries.len());
        let mut cursor = 0;
        for (index, id) in self.entries.iter().enumerate() {
            if alive(id) && kept.last() != Some(id) {
                kept.push(id.clone());
            }
            if index == self.cursor {
                cursor = kept.len().saturating_sub(1);
            }
        }
        self.entries = kept;
        self.cursor = cursor;
    }

    /// Move one entry towards the old end. `None` at the end of the list.
    pub fn back(&mut self) -> Option<&str> {
        self.cursor = self.cursor.checked_sub(1)?;
        self.current()
    }

    /// Move one entry towards the new end. `None` at the end of the list.
    pub fn forward(&mut self) -> Option<&str> {
        if self.cursor + 1 >= self.entries.len() {
            return None;
        }
        self.cursor += 1;
        self.current()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn walked(ids: &[&str]) -> PaneHistory {
        let mut history = PaneHistory::default();
        for id in ids {
            history.visit(id);
        }
        history
    }

    #[test]
    fn back_three_forward_one() {
        let mut h = walked(&["a", "b", "c", "d", "e"]);
        assert_eq!(h.back(), Some("d"));
        assert_eq!(h.back(), Some("c"));
        assert_eq!(h.back(), Some("b"));
        assert_eq!(h.forward(), Some("c"));
    }

    #[test]
    fn a_new_pane_after_going_back_drops_what_was_ahead() {
        let mut h = walked(&["a", "b", "c"]);
        h.back();
        h.back();
        assert!(h.visit("z"));
        assert_eq!(h.forward(), None);
        assert_eq!(h.back(), Some("a"));
    }

    #[test]
    fn stepping_does_not_grow_the_list() {
        let mut h = walked(&["a", "b"]);
        let before = h.clone();
        let there = h.back().unwrap().to_owned();
        assert!(!h.visit(&there), "the step's own focus is a no-op");
        let again = h.forward().unwrap().to_owned();
        assert!(!h.visit(&again));
        assert_eq!(h, before);
    }

    #[test]
    fn refocusing_the_current_pane_keeps_what_is_ahead() {
        let mut h = walked(&["a", "b"]);
        h.back();
        assert!(!h.visit("a"));
        assert_eq!(h.forward(), Some("b"));
    }

    #[test]
    fn both_ends_stop_and_stay_put() {
        let mut h = walked(&["a", "b"]);
        assert_eq!(h.forward(), None);
        assert_eq!(h.current(), Some("b"));
        h.back();
        assert_eq!(h.back(), None);
        assert_eq!(h.current(), Some("a"));
        let mut empty = PaneHistory::default();
        assert_eq!(empty.back(), None);
        assert_eq!(empty.forward(), None);
    }

    #[test]
    fn compact_skips_a_closed_pane_each_way() {
        let mut h = walked(&["a", "b", "c", "d", "e"]);
        h.back();
        h.back(); // on c
        h.compact(|id| id != "b" && id != "d");
        assert_eq!(h.current(), Some("c"));
        assert_eq!(h.back(), Some("a"));
        assert_eq!(h.forward(), Some("c"));
        assert_eq!(h.forward(), Some("e"));
    }

    #[test]
    fn compact_folds_the_repeat_a_closed_pane_leaves() {
        let mut h = walked(&["a", "b", "a"]);
        h.compact(|id| id != "b");
        assert_eq!(h.current(), Some("a"));
        assert_eq!(h.back(), None);
    }

    #[test]
    fn compact_moves_the_cursor_off_a_closed_pane() {
        let mut h = walked(&["a", "b", "c"]);
        h.back(); // on b
        h.compact(|id| id != "b");
        assert_eq!(h.current(), Some("a"));
        assert_eq!(h.forward(), Some("c"));
        let mut all_gone = walked(&["a", "b"]);
        all_gone.compact(|_| false);
        assert!(all_gone.is_empty());
        assert_eq!(all_gone.back(), None);
    }

    #[test]
    fn the_oldest_fall_off_the_end() {
        let mut h = PaneHistory::default();
        for i in 0..PANE_HISTORY_MAX + 10 {
            h.visit(&i.to_string());
        }
        assert_eq!(h.current(), Some((PANE_HISTORY_MAX + 9).to_string().as_str()));
        let mut steps = 0;
        while h.back().is_some() {
            steps += 1;
        }
        assert_eq!(steps, PANE_HISTORY_MAX - 1);
        assert_eq!(h.current(), Some("10"));
    }

    #[test]
    fn it_round_trips_and_garbage_is_empty() {
        let mut h = walked(&["a", "b", "c"]);
        h.back();
        assert_eq!(PaneHistory::parse(&h.to_json()), h);
        assert_eq!(PaneHistory::parse("not json"), PaneHistory::default());
    }
}
