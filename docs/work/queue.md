# Work Queue

- [x] Dock a lane to the left or right, overlaying or insetting the strip — [detail](docked-panes.md) — both halves merged, audio proved
- [x] The five silent web failures: dialogs, file inputs, downloads, camera/mic, HTTP auth — merged in 36be318
- [x] One `--profile` instead of four environment variables — [detail](profiles.md) — everything under profiles/, migration verified with sqlite3 .backup
- [x] Selecting from the session sidebar reveals a lane without focusing it — [detail](sidebar-select-focus.md) — focuses the row's own pane, and a split lane now marks which pane has the keyboard
- [ ] ⌘O sometimes opens with no rows — reproduce first, it works in the common case — [detail](omni-empty-on-open.md)
- [ ] A docked lane's page is laid out at the wrong width and runs off screen — [detail](dock-lane-width.md)
- [ ] Browser chrome round 2: a failed navigation says nothing, ⌘L is dead, ⌘-click loses your place — [detail](chrome-round-2.md)
- [ ] History round 2: search the whole corpus, substring ranking, client-side redirects, real dates — [detail](history-round-2.md)
- [ ] Every shortcut configurable, with the current ones as defaults — [detail](configurable-hotkeys.md)
- [ ] `maxpane run "a | pipeline"` returns a session id, logs a lane, and produces none
- [ ] Import history from another browser, with a merge-or-replace wizard — [detail](import-history.md) — blocked on history round 2 raising the row cap
- [ ] Bookmarks: a store, a way to add and reach them, then import from other browsers
- [ ] Passwords: decide whether Max Pane stores credentials at all before any import — the auth work deliberately stores none
- [x] Split down (⇧⌘D) adds a pane that never appears — [detail](split-down-invisible.md) — fixed in a4d414d
