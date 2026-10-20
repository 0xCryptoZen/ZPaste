# z-paste

A menu-bar clipboard manager for macOS built with SwiftUI + SwiftData + CloudKit, featuring global hotkeys, folder grouping, and automatic iCloud sync.

一个功能类似 [Paste](https://pasteapp.io/)（Paste.app）的 macOS 剪贴板管理工具，复刻其用户可见功能，从零独立实现（不包含 Paste 官方代码）。

> 剪贴板历史、全局快捷键、搜索、固定、文件夹分组、忽略敏感应用、开机自启、iCloud 同步。

## 功能

- 剪贴板历史（文本）
- 全局快捷键 `⌘⇧V` 呼出历史窗口
- 菜单栏常驻（无 Dock 图标）
- 搜索
- 固定（pin）
- 文件夹 / 分组
- 忽略敏感应用（黑名单，复制时不记录）
- 开机自启（SMAppService）
- iCloud 同步（SwiftData + CloudKit）

## 环境要求

- macOS 14.0+
- Xcode 15+（建议 16/26）
- iCloud 同步需要 Apple Developer 账号 + iCloud container

## 目录

```
z-paste/
├── ZPasteApp.swift           # @main 入口，MenuBarExtra
├── Store.swift               # SwiftData 容器（CloudKit → 本地回退）
├── Models.swift              # Clip / Folder 实体
├── ClipboardMonitor.swift    # 轮询剪贴板 + 去重 + 忽略敏感应用
├── HotKeyManager.swift       # Carbon 全局快捷键 ⌘⇧V
├── AppDelegate.swift         # 监听启动 + 托管历史窗口
├── MenuBarView.swift         # 菜单栏下拉面板
├── HistoryView.swift         # 主窗口（搜索/文件夹/固定/复制/粘贴）
├── SettingsView.swift        # 设置（自启/忽略列表）
├── ZPaste.entitlements       # iCloud CloudKit 权限模板（开启同步时用）
├── Info.plist                # XcodeGen 路径用的 Info.plist（含 LSUIElement）
├── project.yml               # XcodeGen 工程定义
└── README.md
```

## 快速构建（推荐）

用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 自动生成工程：

```bash
brew install xcodegen
cd z-paste
xcodegen generate
open ZPaste.xcodeproj
```

然后 `⌘R` 即可运行。本地运行无需签名；iCloud 同步需另行开启（见下方步骤 5）。

## 手动构建（不用 XcodeGen）

仓库没有提交 `.xcodeproj`，按下面步骤在 Xcode 里新建即可，5 分钟内搞定：

1. **新建工程**：Xcode → File → New → Project → macOS → **App**。
   - Product Name：`ZPaste`
   - Interface：`SwiftUI`，Language：`Swift`
   - 取消勾选 “Use Core Data” 和 “Include Tests”

2. **替换/添加源码**：删除模板生成的 `ContentView.swift`；把本目录下的所有 `.swift` 文件拖进工程（在导航器里拖入 `ZPaste` group），勾选 “Copy items if needed”，并勾选加入 `ZPaste` target。
   - `ZPasteApp.swift` 会覆盖模板里同名的 `@main` 入口文件。

3. **设最低系统版本**：选中 target → General → Minimum Deployments → **macOS 14.0**。

4. **设为菜单栏应用（无 Dock 图标）**：选中 target → Info 标签页，新增一行
   - Key：`Application is agent (UIElement)`，Value：`YES`
   （等价于 Info.plist 里 `LSUIElement = true`）

5. **（可选，本地运行可跳过）开启 iCloud 同步**：
   - target → Signing & Capabilities → 选择你的 Team（需要 Apple Developer 账号）
   - `+ Capability` → **iCloud** → 勾选 **CloudKit** → 在 Containers 里添加一个容器，例如 `iCloud.com.yourname.zpaste`
   - 或者直接用本目录的 `ZPaste.entitlements`（把里面的 `iCloud.com.example.zpaste` 改成你自己的容器 id），并在 Build Settings → Code Signing Entitlements 里指向它

6. **运行**：`⌘R`。应用不会出现在 Dock，会出现在菜单栏（📋 图标）。

## 使用

- 随便复制一段文字，历史窗口里就会出现记录。
- 点菜单栏图标 → “打开历史”，或按 `⌘⇧V` 呼出历史窗口。
- 右键某条记录：复制 / 复制并粘贴到前台 App / 移动到文件夹 / 删除。
- “复制并粘贴”会合成 `⌘V`，需要授予**辅助功能**权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 z-paste。

## 常见问题

- **编译报并发/actor 隔离错误**：把 Build Settings → Swift Language Version 设为 **Swift 5**（模板默认就是 5），或按报错把相关类型标注为 `@MainActor`。
- **iCloud 不同步**：确认已选 Team、已加 iCloud 能力并选了容器、entitlements 里的容器 id 与开发者后台一致；首次同步需登录同一 iCloud 账号。
- **收不到剪贴板记录**：`⌘⇧V` 呼出窗口后确认应用在菜单栏运行；某些全屏/受保护应用可能不触发。
- **`复制并粘贴` 没反应**：检查辅助功能权限是否已授予，然后重启应用。

## 免责声明

本项目仅用于学习与研究，是独立实现，不包含 Paste 或其团队的代码。Paste 是 Paste Team ApS 的商标。