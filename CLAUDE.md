# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Deploy

All commands run from `Code/`:

```bash
cd Code

# Debug build → .app bundle (ad-hoc signed)
./build.sh

# Release build → signed + notarized DMG
./build-release.sh 1.0.0
```

After every code change, always: build, quit running Claudio, replace `/Applications/Claudio.app`, relaunch:

```bash
cd Code && bash build.sh && osascript -e 'tell application "Claudio" to quit' 2>/dev/null; sleep 1; rm -rf /Applications/Claudio.app && cp -R .build/arm64-apple-macosx/debug/Claudio.app /Applications/Claudio.app && open /Applications/Claudio.app
```

No Xcode project — this is a pure Swift Package Manager build (`Package.swift`). Target: macOS 26+, Swift 6.2, strict concurrency.

## Architecture

Menu bar app (`MenuBarExtra` with `.window` style) that monitors Claude Code usage and sessions.

### Data Flow

```
ClaudioApp (entry point, owns AppViewModel)
  └─ PopoverView (main UI, 320×620)
       ├─ UsageChartCard — 7-day/5-hour chart with Swift Charts
       ├─ ExtraUsageBar — extra usage spending (conditional)
       ├─ SessionCard → SessionRow — active Claude Code sessions
       └─ BridgeSettingsView — Telegram bridge config (settings screen)
```

`AppViewModel` is the single `@Observable @MainActor` state container. It owns all services and polls every 60s.

### Services (all actors or Sendable)

| Service | Role |
|---------|------|
| `UsageService` | Fetches utilization from Anthropic OAuth API, handles token refresh |
| `KeychainService` | Reads Claude Code's Keychain credentials, maintains file mirror at `~/.claude/widget-credentials.json` |
| `SessionService` | Discovers active `claude` processes via `pgrep`/`lsof`/`ps`, parses `.jsonl` session files for rich stats |
| `UsageHistoryService` | Persists usage readings to `~/.claude/widget-usage-history.json` (7-day rolling) |
| `BridgeCoordinator` | Orchestrates Telegram bridge — owns HookServer, TelegramService, SessionWatcher, RemoteSessionManager |
| `HookServer` | Local HTTP server on port 19876 receiving Claude Code hook events (NWListener, raw HTTP parsing) |
| `TelegramService` | Telegram Bot API client with long-polling |
| `SessionWatcher` | Monitors `.jsonl` files via `DispatchSource` for real-time session output |
| `RemoteSessionManager` | Spawns headless `claude` processes from Telegram `/run` commands |
| `StdinInjector` | Injects text into terminal sessions (tmux → Terminal.app → iTerm2 fallback chain) |
| `OTelReceiver` | Listens on port 4318 for OpenTelemetry metrics (placeholder, not consumed yet) |

### Telegram Bridge Flow

```
Claude Code hook events → HookServer (localhost:19876) → BridgeCoordinator → TelegramService → Telegram Bot API
Telegram messages → TelegramService polling → BridgeCoordinator → RemoteSessionManager / StdinInjector
```

Hook installation writes to `~/.claude/settings.json`. The `PermissionRequest` hook blocks (up to 110s) waiting for Telegram approval callback.

### Key Patterns

- **Strict Swift concurrency**: services are `actor`s, UI types are `@MainActor`. `nonisolated` used for process/shell helpers.
- **No app sandbox**: entitlements disable sandbox (needs filesystem, process, and network access).
- **Glass effect UI**: all cards use `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))` with `.padding(14)`.
- **Settings stored in**: `UserDefaults` (bridge enabled/token/chatId), Keychain (OAuth), file system (usage history).
- **Color thresholds**: >=80% → red (`widgetRed`), >=60% → yellow (`widgetYellow`), <60% → white. Defined in `Colors.swift`.

## Project Structure

```
Code/
├── Package.swift              # SPM manifest (macOS 26, Swift 6.2)
├── build.sh                   # Debug build + .app bundle
├── build-release.sh           # Release build + DMG + notarization
└── Claudio/
    ├── ClaudioApp.swift       # @main entry, MenuBarExtra
    ├── Info.plist / .entitlements
    ├── Models/                # Data types (UsageData, Session, HookEvent, TelegramModels)
    ├── Services/              # All backend logic (actors)
    ├── ViewModel/             # AppViewModel (single state container)
    ├── Views/                 # SwiftUI views
    └── Resources/             # AppIcon.icns
```
