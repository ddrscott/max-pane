//! `maxpane-open` — the `BROWSER` shim.
//!
//! Same code as `maxpane`; `argv[0]` is what selects the single-purpose
//! behaviour, so `BROWSER` can point straight at a binary that only ever takes
//! a URL.
fn main() {
    maxpane_open::run()
}
