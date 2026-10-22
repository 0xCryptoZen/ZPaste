# ZPaste

A small native macOS clipboard history tool built with SwiftUI, AppKit, and SwiftData. Runtime dependencies are Apple system frameworks only. Requires macOS 14 or later.

## Local encrypted history

- History is local only. There is no CloudKit synchronization, analytics, link preview fetching, or plaintext file export.
- Text, source application identifiers, and folder names are encrypted with CryptoKit AES-256-GCM before reaching SwiftData. Each write uses a fresh nonce. IDs, timestamps, pin status, folder relationships, record type, and format version are authenticated operational metadata; they remain visible in the database.
- The random 256-bit key is stored in the macOS Data Protection Keychain with `WhenUnlockedThisDeviceOnly`, synchronization disabled, and `userPresence` access control. Reading the key itself requires Touch ID or the system password; an application-only authentication dialog is not used as a substitute.
- The app starts locked. Unlock explicitly to view history and record future copies. Screen lock, sleep, user switching, or Lock Now stops recording, cancels pending delivery and queries, hides history, and releases plaintext/key references. This does not guarantee that Swift or macOS zeroed every memory copy.
- The app clears the system clipboard on lock only if it still contains ZPaste's own most recent write. It never clears a later copy made by another app.
- Keychain denial, missing keys, authentication failures, corrupted ciphertext, and storage errors fail closed. There is no plaintext fallback and no automatic replacement of a missing key for an existing store.

The main threats addressed are readable history files, casual unauthorized access, accidental plaintext persistence, and misdirected paste. Encryption does not defeat malware controlling the logged-in session, privileged processes, screen capture, or other apps reading the system clipboard after you copy. Per-record authentication does not provide rollback protection for entire database snapshots.

Direct paste is retained and needs Accessibility permission. This distribution does **not** claim full App Sandbox isolation. Offline application code is not an OS-enforced network firewall. Hardened Runtime is enabled in the project; Developer ID signing and notarization require your own signing identity and are separate release checks.

## Upgrading old history

On the first authenticated unlock, ZPaste opens only the exact historical SwiftData default store, with saving and CloudKit disabled. It imports records in batches into a separate encrypted store, retaining text, dates, pins, source IDs, folders, and relationships without applying new limits during migration. Each imported record is checked, then the complete encrypted store is reopened and verified before the commit marker is published and old SQLite files are removed.

Interrupted, uncommitted imports restart from the untouched original. Unknown or unreadable stores stop migration and remain in place. ZPaste does not create a plaintext backup or attempt to infer arbitrary store paths. Keep the bundle identifier stable across upgrades so the original default location and Keychain identity remain discoverable.

Deleting old local files cannot erase SSD remnants, Time Machine copies, or past CloudKit data. Old iCloud copies require separate management in the relevant Apple account; this version never connects to CloudKit to delete them. Migration is not an encrypted cross-device backup feature.

**Losing the device-only key makes the history unreadable.** Moving the database to another Mac, changing signing/access-group identity, or deleting the Keychain item can prevent access. No recovery password, exported key, cloud key synchronization, or silent key reset is provided. Preserve the original Mac/key and stable signing identity. Storage or key errors never authorize automatic deletion of the encrypted database.

## Recording and limits

- New installations default to 7 days and 500 unpinned items. Existing installations keep their old policy until they explicitly confirm changes. Settings offers the recommended limits with a destructive-cleanup confirmation.
- New text is limited to 256 KiB of UTF-8. Encrypted payload capacity is 20 MiB; this is a logical payload limit, not a promise that SQLite/WAL files occupy exactly that much disk space. Up to 100 new pins are allowed.
- Existing oversized records and excess pins are retained during migration. Over-capacity histories pause new recording until you remove items or explicitly apply a suitable retention policy. Pins are never removed by automatic retention or Clear Unpinned History.
- Oversized legacy text can have a shortened UI preview. Copy and paste retrieve the complete authenticated text; stored data is not truncated. A single deliberately opened legacy record can temporarily exceed the normal display-cache budget.
- Pause and lock stop the 300 ms capture timer. Resuming records future changes only. Polling has a 50 ms tolerance; cleanup is scheduled separately while unlocked.
- Confidential, transient, and autogenerated clipboard markers are filtered by default. Add sensitive apps to the ignored-app list. Unknown sources and copies around an observed app transition are skipped. Polling cannot reliably establish clipboard ownership or detect all passwords, private keys, recovery phrases, browser password fields, or unmarked secrets.

Settings includes Clear Unpinned History and Delete ALL History. The latter includes pins and folders, requires confirmation and a fresh Keychain authentication, then locks the app. Removal is logical deletion, not guaranteed secure erasure of historical encrypted pages or backups.

## Using history

- `⌘⇧V` opens the reusable compact search panel. The global shortcut can be changed in Settings; registration conflicts leave the old shortcut intact.
- Type to search, use arrows to select, Return to execute the configured copy/paste action, and Escape to hide the app. Single click selects; double click executes. The full history window supports Space to preview, an explicit Copy button, pinning, and folders.
- Choose a destination input before opening ZPaste. Automatic paste rechecks the target process, unlock state, cancellation, and clipboard change count before sending `⌘V`. Without Accessibility access, text is copied and you can paste manually.
- The menu panel shows eight recent items. Full history is paged in groups of 100. Search is debounced by 150 ms and decrypts bounded batches while unlocked; no persistent plaintext search index exists. A bounded, ephemeral keyed fingerprint map accelerates duplicate lookup and is discarded on lock.

## Build and validation

```sh
brew install xcodegen
xcodegen generate
open ZPaste.xcodeproj
```

Use a stable bundle ID and a signing identity appropriate for macOS Data Protection Keychain access. Do not remove the Keychain ACL or switch to a less protected Keychain to make an unsigned development build work. Unsigned CI artifacts prove compilation and synthetic tests only; Keychain, Touch ID/system password, lock-screen behavior, and Accessibility require signed, on-device validation.

```sh
bash scripts/test-policies.sh
bash scripts/test-presentation.sh
bash scripts/test-cipher.sh
# Full Xcode is required for SwiftData macros:
bash scripts/test-storage.sh
bash scripts/test-vault-storage.sh
bash scripts/test-vault-session.sh
```

Tests use synthetic content and disposable stores. They cover authenticated metadata, corruption/wrong-key rejection, migration and restart behavior, plaintext marker scans of stored files, retention/pin preservation, paging/search, and cancellation across lock/authentication boundaries. Fake Keychain tests verify orchestration only; they do not prove OS-enforced authentication.

CI builds an unsigned Release app and uploads it as `ZPaste-macOS`. Never describe that archive as signed, notarized, or validated against real user credentials. Before distribution, sign with Developer ID, notarize and staple the result, verify its actual entitlements/runtime flags, and complete the signed-device checklist in [VALIDATION.md](VALIDATION.md).

For visual checks, copy the CI app to a disposable bundle with a distinct identifier and open it with `--ui-preview`. Preview uses an in-memory encrypted store and synthetic data, skips real Keychain authentication, and does not register a hotkey, record, or write the system clipboard. Never use the normal installed app's identity or live database for previews.
