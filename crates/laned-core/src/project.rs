//! Resolving a working directory to a project root.
//!
//! The PRD describes this as `git rev-parse --show-toplevel`, cached. We walk
//! for `.git` directly instead: it is the same answer without a subprocess per
//! poll, and the tagger runs against every pty pane every 5 seconds. A `.git`
//! *file* (worktrees and submodules) counts, because a worktree is a project the
//! user thinks of as its own thing.

use parking_lot::Mutex;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub struct ProjectResolver {
    /// cwd -> resolved root (or `None` for "walked to / and found nothing").
    cache: Mutex<HashMap<PathBuf, Option<String>>>,
}

impl ProjectResolver {
    /// The git root containing `cwd`, or `None` when there isn't one.
    ///
    /// Cached per directory. A directory's answer only changes when a repo is
    /// created or removed under it, which is rare enough to be worth the stale
    /// window; [`Self::invalidate`] exists for when it isn't.
    pub fn root_of(&self, cwd: &str) -> Option<String> {
        let key = PathBuf::from(cwd);
        if let Some(hit) = self.cache.lock().get(&key) {
            return hit.clone();
        }
        let resolved = walk_for_git_root(&key);
        self.cache.lock().insert(key, resolved.clone());
        resolved
    }

    pub fn invalidate(&self) {
        self.cache.lock().clear();
    }

    pub fn cached_entries(&self) -> usize {
        self.cache.lock().len()
    }
}

fn walk_for_git_root(start: &Path) -> Option<String> {
    let mut dir = start;
    loop {
        if dir.join(".git").exists() {
            return Some(dir.to_string_lossy().into_owned());
        }
        dir = dir.parent()?;
    }
}

/// The part of a project root a human reads: its last path component.
pub fn short_name(root: &str) -> &str {
    Path::new(root).file_name().and_then(|s| s.to_str()).unwrap_or(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_root_from_a_nested_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("proj");
        let nested = root.join("a/b/c");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(root.join(".git")).unwrap();

        let r = ProjectResolver::default();
        assert_eq!(r.root_of(nested.to_str().unwrap()), Some(root.to_string_lossy().into_owned()));
    }

    #[test]
    fn a_git_file_counts_as_a_root() {
        // Worktrees and submodules have a `.git` file, not a directory.
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join("wt");
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::write(root.join(".git"), "gitdir: /elsewhere\n").unwrap();

        let r = ProjectResolver::default();
        assert_eq!(r.root_of(root.join("src").to_str().unwrap()), Some(root.to_string_lossy().into_owned()));
    }

    #[test]
    fn nearest_root_wins_for_a_nested_repo() {
        let tmp = tempfile::tempdir().unwrap();
        let outer = tmp.path().join("outer");
        let inner = outer.join("vendor/inner");
        std::fs::create_dir_all(&inner).unwrap();
        std::fs::create_dir_all(outer.join(".git")).unwrap();
        std::fs::create_dir_all(inner.join(".git")).unwrap();

        let r = ProjectResolver::default();
        assert_eq!(r.root_of(inner.to_str().unwrap()), Some(inner.to_string_lossy().into_owned()));
    }

    #[test]
    fn no_repo_resolves_to_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let r = ProjectResolver::default();
        assert_eq!(r.root_of(tmp.path().to_str().unwrap()), None);
    }

    #[test]
    fn answers_are_cached_per_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let r = ProjectResolver::default();
        r.root_of(tmp.path().to_str().unwrap());
        r.root_of(tmp.path().to_str().unwrap());
        assert_eq!(r.cached_entries(), 1);
        r.invalidate();
        assert_eq!(r.cached_entries(), 0);
    }

    #[test]
    fn short_name_is_the_last_component() {
        assert_eq!(short_name("/Users/spierce/code/max-pane"), "max-pane");
    }
}
