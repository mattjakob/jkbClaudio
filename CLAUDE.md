# CLAUDE.md

macOS menu bar app showing Anthropic 5-hour and weekly token utilization, with a Telegram bridge to Claude Code sessions.

## Tech Stack
| Layer | Technology |
|-------|------------|
| Language | Swift 6.2, async/await, actors, `@Observable` |
| Framework | SwiftUI (`MenuBarExtra`), AppKit |
| Platform | macOS 26+ |
| Build | Swift Package Manager (`Code/Package.swift`) |
| Auth | OAuth 2.0 via Keychain (Claude Code tokens) |
| Bridge | Local hook server (HTTP :19876) + Telegram Bot API |

## Architecture
`AppViewModel` (`@Observable`, `@MainActor`) owns all state and coordinates services. `UsageService` polls the Anthropic usage API.

- **Adaptive refresh**: `RefreshPolicy` picks the poll interval — 120 s while Claude Code sessions are active (or popover opened <5 min ago), 900 s idle, 1800 s under low-power/thermal pressure. `RefreshGates` persists backoff state in UserDefaults so rate-limit/auth/transient failures don't retry-storm across relaunches.
- **Token tracking**: `TokenScanner` (actor) incrementally aggregates token usage from Claude Code transcript JSONL files — rescans only files whose size/mtime changed, parses just the appended tail, and persists offsets/dedup state to a cache file; files older than 2 days are skipped. `UsageHistoryService` persists readings to `~/.claude/widget-usage-history.json` (7-day window).
- **Telegram bridge**: `BridgeCoordinator` (`@MainActor`) wires it together: `HookServer` receives Claude Code hook events and holds permission requests open (`CheckedContinuation`) until a UI/Telegram action or 110 s timeout; `SessionWatcher` tails session transcript files via DispatchSource and emits new JSONL lines; `SDKSessionCoordinator` spawns and tracks headless sessions, each a `ClaudeProcess` wrapping a `claude -p` subprocess streaming JSON over stdio. `StdinInjector` answers prompts in an existing terminal session by resolving PID → TTY, then trying tmux send-keys → iTerm2 → Terminal.app.

## Project Structure
```
Code/
├── Package.swift
├── build.sh              # Debug build + ad-hoc sign
├── build-release.sh      # Release build, sign, DMG, notarize, GitHub release
├── Tests/ClaudioTests/   # swift test target
└── Claudio/
    ├── ClaudioApp.swift  # Entry point — MenuBarExtra scene
    ├── ViewModel/        # AppViewModel (single ViewModel)
    ├── Models/           # UsageData, Session, SDKMessage, etc.
    ├── Services/         # UsageService, SessionService, BridgeCoordinator, HookServer,
    │                     #   TokenScanner, SessionWatcher, SDKSessionCoordinator,
    │                     #   ClaudeProcess, StdinInjector, RefreshPolicy/Gates,
    │                     #   KeychainService, TelegramService, etc.
    └── Views/            # PopoverView, MenuBarLabel, SessionCard, UsageCard, etc.
```

## Commands
| Command | Purpose |
|---------|---------|
| `./build.sh` | Debug build + ad-hoc sign, outputs `.app` bundle |
| `swift build` | Compile only |
| `swift test` | Run tests |
| `./build-release.sh [x.y.z]` | Release build, notarize, publish GitHub release |

Run all of these from `Code/`.
