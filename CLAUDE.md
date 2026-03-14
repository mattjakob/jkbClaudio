# CLAUDE.md

## Rules
**Execute ONLY what is explicitly requested. No more, no less.**
- Read existing code before modifying; follow existing patterns exactly
- Keep files under 600 lines; one responsibility per file
- No unrequested features, documentation, emojis in code
- Run linting and tests after changes

## Tech Stack
| Layer | Technology |
|-------|------------|
| Language | Swift 6.2, async/await, `@Observable` |
| Framework | SwiftUI (`MenuBarExtra`), AppKit |
| Platform | macOS 26+ |
| Build | Swift Package Manager (`Package.swift`) |
| Auth | OAuth 2.0 via Keychain (Claude Code tokens) |
| Telemetry | OTel receiver (local HTTP), Telegram bridge |

## Architecture
Menu bar app that polls the Anthropic usage API every 120 s and displays 5-hour and weekly token utilization. `AppViewModel` (`@Observable`, `@MainActor`) owns all state and coordinates services. `BridgeCoordinator` watches Claude Code sessions via hooks and forwards events to Telegram.

## Project Structure
```
Code/
├── Package.swift
├── build.sh              # Debug build + ad-hoc sign
├── build-release.sh      # Release build, sign, DMG, notarize, GitHub release
└── Claudio/
    ├── ClaudioApp.swift  # Entry point — MenuBarExtra scene
    ├── ViewModel/        # AppViewModel (single ViewModel)
    ├── Models/           # UsageData, Session, SDKMessage, etc.
    ├── Services/         # UsageService, SessionService, BridgeCoordinator,
    │                     #   KeychainService, OTelReceiver, TelegramService, etc.
    └── Views/            # PopoverView, MenuBarLabel, SessionCard, UsageCard, etc.
```

## Commands
| Command | Purpose |
|---------|---------|
| `./build.sh` | Debug build + ad-hoc sign, outputs `.app` bundle |
| `swift build` | Compile only |
| `swift test` | Run tests |
| `./build-release.sh [x.y.z]` | Release build, notarize, publish GitHub release |

## Commit Format
```
<tag>: Short summary (<=72 chars)
Tags: feat, fix, refactor, docs, style, test, chore
```
