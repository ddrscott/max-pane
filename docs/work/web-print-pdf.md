# Print and Save as PDF for a web pane

## Problem
⌘P does nothing in a web pane. No `printOperation`, `createPDF` or
`NSPrintOperation` in the sources. Boarding passes, receipts and invoices are
a weekly reason to open another browser.

## Acceptance Criteria
- `Command.printPage` (⌘P by default, in the File menu, bindable through
  `keys`) runs `WKWebView.printOperation(with:)` for the focused web pane as a
  sheet on the window, with the standard macOS print panel — which already has
  "Save as PDF" in its PDF menu, so a separate command is not needed. A popup
  dialog's page prints too.
- The print info defaults to the page's own size and margins; the operation is
  scoped so `printOperation` is not left unretained (it must be held until
  `runModal` completes, or WebKit crashes; see Apple's notes).
- `Command.savePDF` (no default key) writes `createPDF` of the full page to a
  file chosen through `NSSavePanel`, default name from the page title, and hands
  the result to the existing downloads surface so it appears where a download
  would.
- A terminal pane on ⌘P does nothing and the menu item is disabled; the
  command's `menu` and validation follow the existing `Command` conventions.
- Tests: the command exists, is in the File menu, and is refused for a
  terminal pane; a real-WebKit test renders a loopback page to PDF with
  `createPDF` and asserts the data starts with `%PDF` and contains the page's
  text.

## Relevant Files
- `swift/MaxPane/Sources/MaxPaneKit/Commands.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebPaneController.swift`
- `swift/MaxPane/Sources/MaxPaneKit/Web/WebDownloads.swift`
- `swift/MaxPane/Sources/MaxPane/AppDelegate.swift` (menu construction)

## Constraints
- Do not build a custom print UI; the system panel is the feature.
- `KeymapTests` refuses chords macOS owns — check ⌘P is not on that list before
  choosing it.
