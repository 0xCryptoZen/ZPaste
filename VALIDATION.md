# Validation and release gates

Automated tests and the unsigned CI app are development evidence. This checklist records the additional evidence required before a security release. Unchecked items are **not verified**.

## Signed device checks

- [ ] Stable bundle identifier and Developer ID identity; inspect actual signature, entitlements, and Hardened Runtime. No debug entitlement in the Release build.
- [ ] Fresh installation: creating a Keychain item still requires authentication before recording or showing history.
- [ ] With Touch ID unavailable, authenticate using the system password. Cancellation and failed authentication leave history locked.
- [ ] Revoke Keychain access or temporarily hide the original key in an isolated test account. Existing history must remain intact; no replacement key or plaintext store is created. Restore the original key afterward.
- [ ] Lock the screen, sleep/wake, switch users, and use Lock Now while searching, previewing, authenticating, or waiting to paste. History disappears; no stale completion unlocks the app or delivers text.
- [ ] Copies made while paused/locked are not recorded after resume. Capture timer is stopped while paused/locked.
- [ ] Lock after a ZPaste clipboard write: it clears only that unchanged write. Copy something else before locking: the newer copy survives.
- [ ] Test ignored apps, confidential markers, unknown sources, and rapid app transitions. Do not label this a universal secret detector.
- [ ] Test direct paste, cancellation, target closure/change, clipboard replacement, missing Accessibility access, keyboard-only operation, VoiceOver, light/dark mode, and the compact panel.
- [ ] Migrate a disposable real legacy store, including duplicate timestamps, multiple folders, oversized text and excess pins. Confirm all content and associations before allowing deletion of the synthetic old files.
- [ ] Interrupt migration, simulate low disk space, and deny removal of old sidecar files. No incomplete store becomes active and no unverified original is deleted.
- [ ] Plaintext scans include SQLite, WAL, SHM, application logs, app-owned temporary files, and bundle resources. Only synthetic markers are used; do not print real history or keys.
- [ ] Delete ALL History requires confirmation and fresh system authentication; cancels capture and delivery, removes pins/folders, and locks afterward.
- [ ] Notarization accepted, ticket stapled, Gatekeeper validation succeeds for the distributed archive.

## Performance evidence

Record the commit, macOS/Xcode version, hardware, fixture byte sizes, and Release configuration. Use synthetic 500, 1,000, and 5,000 item histories. Record p50/p95 for recent-eight queries and worst-case search. Initial target for 1,000 items is <=200 ms; this measures data retrieval, not full UI activation.

Measure actual panel activation separately on the signed device. Compare the same machine and fixture to the baseline commit `ae99a1fbc5ebe5f40b2c324ef7c9f39c7647e423`. Record app/archive sizes, RSS, idle CPU, timer wakeups, and Energy Impact with recording enabled, paused, and locked. Do not infer idle power from a query benchmark or claim UI timing from a repository test.

- [ ] Release app/archive size compared to baseline.
- [ ] Signed-device RSS, idle CPU, wakeups, and Energy Impact recorded.
- [ ] Paused/locked capture timer count is zero.
- [ ] Warm compact-panel activation <=200 ms at 1,000 items.
- [ ] Search result publication <=200 ms at 1,000 items, with the 150 ms debounce reported separately.

No runtime third-party dependency may be introduced. Encryption protects stored content; authenticated operational metadata remains visible. The display payload budget is separate from process RSS, SwiftData internals, and transient decryption of a large migrated record.
