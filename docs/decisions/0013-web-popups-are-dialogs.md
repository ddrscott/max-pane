# ADR 0013 — A web page's popup is a dialog over the window, never a lane

**Status:** Accepted · 2026-09-13
**Decides:** where a page's `window.open` popup — the OAuth sign-in window — is
shown, and the points where building it departed from its work item.
**Evidence:** the work item
[`docs/work/web-popups-as-dialogs.md`](../work/web-popups-as-dialogs.md), whose
design is the owner's and is not re-opened here; and
`WebPopupDialogTests.swift`, which drives it through real WebKit with two local
origins.

## Decision

`PopupPolicy` is unchanged: a `window.open` with a size, without chrome, or
from script is a popup; `target=_blank` and ⌘-click are lanes. A popup is now a
`WebPopupDialog`: a `Popup`, `.explicitOnly`, centred over the strip window,
holding the `ChromeWebView` built from the configuration WebKit handed to
`createWebViewWith`. `PopupHandoff`, the pane's adoption path and the lane it
staged are gone. No path turns a popup into a lane or a ledger row.

What the tests hold, against real WebKit, with an opener page and a "provider"
page served from two loopback ports:

- `window.open(url, 'auth', 'width=500,height=600')` shows a dialog of that page
  size plus the 28 pt origin bar, centred in the window. The lane count does
  not change.
- The provider's `window.opener.postMessage` reaches the opener from the
  provider's origin, and the cookie the provider sets is readable by the opener.
  That proves the shared jar.
- The provider's `window.close()` closes the dialog, and the ledger's focus moves
  back to the opener pane from the lane that had it.
- Five `_blank` opens leave one dialog, one child window and no new lanes. The
  four replaced handles read `closed === true` to the opener, so a library
  polling `popup.closed` hears that those attempts ended.
- With the opener's view in no window at all, the dialog is still centred over
  the window.
- A popup opened from the popup is a child dialog over it, and Esc on the
  parent takes both.
- A bare `window.open(url)` is a dialog. A clicked `target=_blank` link is a
  lane.
- The opener navigating to another origin closes the dialog.

## Where the build departed from the work item

1. **⌘C does not copy the address. A click on it does.** The item said "the full
   URL on hover, ⌘C to copy". ⌘C in the dialog belongs to the page, because
   copying a one-time code off a sign-in page is the common case. And
   `performKeyEquivalent` has to answer synchronously, while "does the page have
   a selection" can only be learned by asking its process. So a click on the
   origin copies the full address and the bar says `copied`, and hovering shows
   the address.
2. **The dialog's level is `.normal`, not `.floating`.** Every other popup
   floats. A sign-in page raises windows of its own, like the file panel or the
   Keychain's permission panel behind ⌥⌘L, and a floating dialog would cover the
   one window it is waiting on. As a child window of the strip window, the
   dialog stays above the strip anyway.
3. **"Its opener navigates away" means "to another origin".** Read literally,
   any opener navigation would close it. But single-page apps navigate with
   `pushState` all the time, sometimes while their own sign-in is open. So the
   dialog closes when the opener commits a different scheme, host or port
   (`PopupOpener`), and the same rule closes a child when its parent dialog
   leaves.
4. **Esc answers the page's question first.** If the popup's page has a sheet
   up, Esc is that sheet's Cancel. Only an Esc with nothing asked closes the
   dialog. Otherwise Esc closes it even when typed into the page, as the item
   says.
5. **App shortcuts are sorted, not all passed through.** While the dialog is
   key, the menu would aim a page command at the focused pane, which is the
   opener behind the dialog. So:
   - ⌘W closes the dialog.
   - ⌘R and ⇧⌘R reload the popup.
   - ⌥⌘L fills the popup's form.
   - ⌘L, zoom, ⌘D, ⇧⌘L and close-lane do nothing.
   - Commands about the strip reach the menu, as they do from a pane.
6. **The popup's questions go through its own delegate, not the pane's.** A
   pane's ask handling is an extension of `WebPaneController`, bound to that
   pane's sheet host and queue. Routed through it, a popup's `alert()` would be
   drawn in the opener's lane behind the dialog, holding a completion handler
   nobody can see. So:
   - `WebPopupDelegate.swift` asks inside the dialog, with the same
     `WebAskSheet`, `AskQueue` and `OneShotReply`.
   - It repeats the pane's order for HTTP auth (the session's cache, then the
     Keychain, then the sheet) and its rule for camera and microphone
     (remembered per origin in the opener's jar).
   - File panels, downloads and the "is this response a file" decision are
     forwarded to the pane unchanged.
   - The password fill was extracted into `PasswordFill.fill` rather than
     copied, because it is the one injection in the app.

   A single ask host shared by panes and popups is the refactor this leaves for
   later.
7. **WebKit reuses a named window itself.** A second
   `window.open(url, "auth", …)` navigates the popup that is already open, and
   `createWebViewWith` is never called. Replacement only runs for `_blank` or a
   new name. Either way the result is one dialog.

## Rejected

- **Keep the lane and fix where it lands and what it focuses.** Every symptom
  the owner listed follows from a popup being a ledger row: counted as a lane,
  focused, and restored on relaunch after its opener is gone. Better placement
  fixes none of that.
- **A sheet inside the opener's lane, as `WebAskSheet` is.** The opener may be
  scrolled away, docked, or a 25% gallery tile. A sign-in form has to be
  readable and typeable wherever it came from.
- **A real `NSWindow` per popup.** It gets macOS's rounded chrome, puts sign-in
  windows in the window list, and has no owner to close it with its page.

## Not verified

LinkedIn's "Sign in with Google" needs the owner's account and was not driven.
The local reproduction is `WebPopupDialogTests`. No instance of the app was
launched either, because opening a popup there needs a click in a page.

## Revisit when

A real sign-in flow turns out to need the popup to survive its opener
navigating to another origin, or WebKit gives `WKWebView` a public way to close
its page.
