# Passwords: use the macOS Keychain, store nothing ourselves

## The owner's decision

> "i don't mind integrating into Mac keychain. let's just not invent a new way
> to store passwords."

That settles the question the auth work left open. Credentials live in the
**macOS Keychain** as `kSecClassInternetPassword` items. Max Pane keeps no
credential store of its own — not in the ledger, not in a plist, not in a file.
The existing rule from the HTTP-auth work stands and gets stronger: nothing
sensitive is written anywhere we invented.

## What this changes, and what it does not

The auth work already holds HTTP credentials in memory for the process lifetime
and uses `.forSession` deliberately, so CFNetwork does *not* write them to the
login keychain behind our back. That was the right call **when there was no
considered storage decision**. Now there is one, so saving becomes something the
user is asked about and consents to, rather than something that happens
invisibly. `.forSession` versus `.permanent` should be a choice offered, not a
default either way.

## The part that is easy, and the part that is not

**Storing is easy.** `SecItemAdd` / `SecItemCopyMatching` with
`kSecClassInternetPassword`, keyed by server, protocol, port, account. This is
the same class Safari uses, so items are shared with it — decide deliberately
whether that is wanted (one login list across both) or whether Max Pane should
use its own service attribute to stay separate. Sharing is probably right for
someone making this their full time browser; say which was chosen and why.

**Filling is the hard part, and it is the whole feature.** `WKWebView` does no
password autofill. There is no public API that fills a form the way Safari does;
Password AutoFill with associated domains is for native app fields, not for a
browser rendering arbitrary sites. So the realistic mechanism is injecting into
the page, and that has to be done deliberately:

- **Never automatically.** A credential injected into a page's JavaScript
  context on load is a credential handed to whatever is on that page. Fill
  should be an explicit act — a key, or a control in the chrome bar — aimed at
  the form the user is looking at.
- Match on the **origin**, not the page's own claim about itself.
- An `<iframe>` from a different origin must not receive the parent's
  credential.
- Decide what happens on a page that has a password field and no saved
  credential, and on one with several forms.

A defensible v1 is: explicit fill only, no autofill, no save prompt on submit —
and say plainly in the README that it is not Safari's autofill and why.

## Importing from other browsers

Two very different jobs, and one of them is nearly free:

- **Safari**: its passwords are *already* `kSecClassInternetPassword` items in
  the login keychain. There is nothing to import — reading the Keychain is the
  import. The only work is access and consent.
- **Chromium (Vivaldi, Chrome, Brave, Edge)**: passwords are **not** individual
  Keychain items. They sit in `~/Library/Application Support/<Browser>/Default/
  Login Data` (SQLite, table `logins`), with each password AES-GCM encrypted
  under a single key stored in the Keychain as `<Browser> Safe Storage`. So an
  import means: read that one Keychain item (macOS will prompt him), derive the
  key, decrypt each row, then write each credential as its own Keychain item.
  The file is locked while the browser runs — copy it first, as with history.
- **Firefox**: `logins.json` plus `key4.db`, encrypted through NSS. A different
  mechanism again, and reasonable to leave out of a first version.

## Acceptance criteria

- No credential is written anywhere except the macOS Keychain. A grep of the
  ledger, the config and the logs after using the feature finds nothing.
- Saving a credential is something the user is asked about, once, per site.
- Filling is explicit, origin-matched, and refuses a cross-origin frame.
- Debug logging never prints a credential, an account name, or the contents of
  a password field — the existing auth work already limits itself to the
  protection space and the kind of question; hold that line.
- If Chromium import is built: it works against a real Vivaldi profile, the
  source file is copied rather than read in place, and the copy is deleted
  afterwards.
- The README says what this is and is not.

## Relevant files

- `swift/MaxPane/Sources/MaxPaneKit/Web/` — the auth work from the five silent
  failures lives here; read how it handles `URLCredential` and `.forSession`
  before changing any of it
- `swift/MaxPane/Sources/MaxPaneKit/Views/WebChromeBar.swift` — where an
  explicit fill control would live
- `Commands.swift` — if fill gets a key

## Constraints

- **Do not invent a credential store.** That is the whole point of this entry.
- Do not weaken the HTTP-auth work's guarantees while extending them.
- A copy of a browser's `Login Data` is a file full of passwords. Copy it to a
  temporary path, use it, delete it, and do not leave it in `/tmp` — an agent
  already left 2 GB of browsing history there today and it had to be swept.
