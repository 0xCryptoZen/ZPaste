# z-paste

A menu-bar clipboard manager for macOS built with SwiftUI + SwiftData + CloudKit, featuring global hotkeys, folder grouping, and automatic iCloud sync.

A clipboard history tool for macOS that mirrors the user-visible behavior of [Paste](https://pasteapp.io/) (Paste.app), implemented independently from scratch (contains no Paste code).

> Clipboard history, global hotkey, search, pin, folders, ignored apps, launch at login, and iCloud sync.

## Features

- Clipboard history (text)
- Global hotkey `⌘⇧V` to open the history window
- Menu-bar resident (no Dock icon)
- Search
- Pin
- Folders / groups
- Ignore sensitive apps (deny list — copies are not recorded)
- Launch at login (SMAppService)
- iCloud sync (SwiftData + CloudKit)

## Requirements

- macOS 14.0+
- Xcode 15+ (16/26 recommended)
- iCloud sync requires an Apple Developer account + iCloud container

## Layout

```
z-paste/
├── ZPasteApp.swift           # @main entry point, MenuBarExtra
├── Store.swift               # SwiftData container (CloudKit → local fallback)
├── Models.swift              # Clip / Folder entities
├── ClipboardMonitor.swift    # Pasteboard polling + dedup + ignore list
├── HotKeyManager.swift       # Carbon global hotkey ⌘⇧V
├── AppDelegate.swift         # Launch setup + hosts the history window
├── MenuBarView.swift         # Menu-bar drop-down panel
├── HistoryView.swift         # Main window (search / folders / pin / copy / paste)
├── SettingsView.swift        # Settings (launch at login / ignore list)
├── ZPaste.entitlements       # iCloud CloudKit entitlement template
├── Info.plist                # Info.plist used by XcodeGen (includes LSUIElement)
├── project.yml               # XcodeGen project definition
└── README.md
```

## Quick build (recommended)

Generate the project with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
cd z-paste
xcodegen generate
open ZPaste.xcodeproj
```

Then press `⌘R`. Local runs need no signing; iCloud sync must be enabled separately (see step 5 below).

## Manual build (without XcodeGen)

The repo does not commit a `.xcodeproj`. Create one in Xcode in about 5 minutes:

1. **New project**: Xcode → File → New → Project → macOS → **App**.
   - Product Name: `ZPaste`
   - Interface: `SwiftUI`, Language: `Swift`
   - Uncheck "Use Core Data" and "Include Tests".

2. **Add sources**: delete the template's `ContentView.swift`; drag all the `.swift` files in this folder into the project (drop them into the `ZPaste` group), check "Copy items if needed", and add them to the `ZPaste` target.
   - `ZPasteApp.swift` overrides the template's `@main` entry file.

3. **Minimum deployment**: select the target → General → Minimum Deployments → **macOS 14.0**.

4. **Menu-bar app (no Dock icon)**: select the target → Info tab, add a row
   - Key: `Application is agent (UIElement)`, Value: `YES`
   (equivalent to `LSUIElement = true` in Info.plist)

5. **(Optional; skip for local runs) Enable iCloud sync**:
   - target → Signing & Capabilities → select your Team (requires an Apple Developer account)
   - `+ Capability` → **iCloud** → check **CloudKit** → add a container under Containers, e.g. `iCloud.com.yourname.zpaste`
   - or use this folder's `ZPaste.entitlements` (replace `iCloud.com.example.zpaste` with your own container id) and point Build Settings → Code Signing Entitlements at it

6. **Run**: `⌘R`. The app won't appear in the Dock; it appears in the menu bar (📋 icon).

## Usage

- Copy some text and it will show up in the history window.
- Click the menu-bar icon → "Open History", or press `⌘⇧V`.
- Right-click an entry: Copy / Copy & Paste to frontmost app / Move to folder / Delete.
- "Copy & Paste" synthesizes `⌘V` and requires the **Accessibility** permission: System Settings → Privacy & Security → Accessibility → enable z-paste.

## FAQ

- **Concurrency / actor-isolation compile errors**: set Build Settings → Swift Language Version to **Swift 5** (the template default), or annotate the relevant types as `@MainActor`.
- **iCloud isn't syncing**: confirm you selected a Team, added the iCloud capability and a container, and that the container id in the entitlements matches the developer portal; sign in to the same iCloud account on first sync.
- **No clipboard entries**: press `⌘⇧V` to open the window and confirm the app is running in the menu bar; some full-screen/protected apps may not trigger.
- **"Copy & Paste" does nothing**: check that the Accessibility permission is granted, then restart the app.

## Disclaimer

This project is for learning and research only and is an independent implementation; it contains no code from Paste or its team. Paste is a trademark of Paste Team ApS.