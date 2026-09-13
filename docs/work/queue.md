# Work Queue

- [x] Dock a lane to the left or right, overlaying or insetting the strip — [detail](docked-panes.md) — both halves merged, audio proved
- [x] The five silent web failures: dialogs, file inputs, downloads, camera/mic, HTTP auth — merged in 36be318
- [x] One `--profile` instead of four environment variables — [detail](profiles.md) — everything under profiles/, migration verified with sqlite3 .backup
- [x] Selecting from the session sidebar reveals a lane without focusing it — [detail](sidebar-select-focus.md) — focuses the row's own pane, and a split lane now marks which pane has the keyboard
- [x] ⌘O sometimes opens with no rows — [detail](omni-empty-on-open.md) — it never opened: a focused web pane swallowed ⌘O before the menu, and ⌘T ⌘Y ⌘R ⌘W ⌘B ⌘P ⌘[ ⌘] with it
- [x] A docked lane's page is laid out at the wrong width and runs off screen — [detail](dock-lane-width.md) — not a dock bug: every web pane was laid out at the chrome bar's fitting width and centred
- [x] Windowed, the traffic lights sit on top of + NEW — and on the first lane header when the sidebar is collapsed — [detail](titlebar-overlap.md) — the corner is reserved from whichever of the sidebar or the strip owns it, and given back in fullscreen
- [x] Browser chrome round 2: a failed navigation says nothing, ⌘-click loses your place — [detail](chrome-round-2.md) — items 1–5 done: failures speak, public http loads, ⌘-click opens a sibling lane, an untitled page stops wearing the last page's title
- [x] Browser chrome round 3: address-bar autocomplete, an honest find match count, a context menu macOS has no hook for — [detail](chrome-round-2.md) — all three merged; the menu was never blocked on API, both web views are ours; the zoom readout is still disputed and still needs a human at the keyboard
- [ ] History round 2: search the whole corpus, substring ranking, client-side redirects, real dates — [detail](history-round-2.md)
- [ ] Every shortcut configurable, with the current ones as defaults — [detail](configurable-hotkeys.md)
- [ ] `maxpane run "a | pipeline"` returns a session id, logs a lane, and produces none
- [ ] Import history from another browser, with a merge-or-replace wizard — [detail](import-history.md) — blocked on history round 2 raising the row cap
- [ ] Bookmarks: a store, a way to add and reach them, then import from other browsers
- [ ] Passwords: macOS Keychain only, never our own store; explicit fill, then Chromium import — [detail](passwords.md)
- [x] Split down (⇧⌘D) adds a pane that never appears — [detail](split-down-invisible.md) — fixed in a4d414d
