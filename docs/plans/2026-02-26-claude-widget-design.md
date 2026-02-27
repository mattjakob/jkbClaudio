# ClaudeWidget Design — macOS 26 Menu Bar Monitor

## Overview

A native SwiftUI macOS 26 menu bar app that monitors Claude Code usage and active sessions. Shows weekly utilization in the menu bar; clicking opens a Liquid Glass popover with detailed stats.

## Data Sources

### 1. OAuth Usage API (primary)

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth-access-token>
anthropic-beta: oauth-2025-04-20
```

Returns `five_hour` and `seven_day` utilization percentages (0-100) with reset timestamps. Token retrieved from macOS Keychain (`Claude Code-credentials`). Polls every 60 seconds.

### 2. Local Session Files

- `~/.claude/projects/*/sessions-index.json` — session metadata, message counts, timestamps, summaries
- `~/.claude/stats-cache.json` — aggregated daily metrics, token usage by model
- `~/.claude/history.jsonl` — chronological interaction log

Watched via FSEvents for real-time updates.

### 3. Process Detection

`ps aux | grep claude` to identify active Claude Code processes and correlate with session files.

### 4. OpenTelemetry (optional)

Lightweight HTTP server on port 4318 accepting OTLP metrics when `CLAUDE_CODE_ENABLE_TELEMETRY=1` is configured. Provides real-time token usage, cost, and session metrics.

## Menu Bar Presence

- SF Symbol `terminal.fill` (template rendering)
- Weekly utilization percentage next to icon
- Color-coded: white (0-60%), yellow (60-80%), red (80-100%)

## Glass Popover Layout

Four sections, each in a `.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))`:

1. **Header** — "Claude Code" + connection status
2. **Usage Card** — 5-hour and weekly utilization bars with reset times
3. **Active Sessions** — per-project sessions with branch, message count, duration, active/idle status
4. **Weekly Stats** — sessions count, messages, token totals, daily activity sparkline

## Architecture

```
ClaudeWidget/
├── ClaudeWidgetApp.swift          # @main, MenuBarExtra scene
├── Views/
│   ├── MenuBarLabel.swift         # Menu bar icon + percentage
│   ├── PopoverView.swift          # Main glass popover layout
│   ├── UsageCard.swift            # 5-hour + weekly bars
│   ├── SessionCard.swift          # Active sessions list
│   ├── StatsCard.swift            # Weekly stats summary
│   └── SettingsView.swift         # Preferences window
├── Services/
│   ├── UsageService.swift         # OAuth + API polling
│   ├── SessionService.swift       # Local file monitoring
│   ├── KeychainService.swift      # Keychain token retrieval
│   └── OTelReceiver.swift         # Optional OTel HTTP server
├── Models/
│   ├── UsageData.swift            # API response models
│   ├── Session.swift              # Session model
│   └── WeeklyStats.swift          # Aggregated stats
├── ViewModel/
│   └── AppViewModel.swift         # @Observable state
└── Info.plist                     # LSUIElement = true
```

## Technical Decisions

- **State**: `@Observable` (Swift 5.9+)
- **Keychain**: Security framework (no deps)
- **File watching**: `DispatchSource.makeFileSystemObjectSource` (FSEvents)
- **Process detection**: `Process` + `ps`
- **Token refresh**: Automatic via refresh_token (8h expiry)
- **Network**: `URLSession` async/await
- **OTel**: Optional SwiftNIO HTTP server
- **Persistence**: `UserDefaults` for preferences
- **Dependencies**: Zero third-party (except optional SwiftNIO for OTel)
- **macOS target**: macOS 26+ only (Liquid Glass APIs)
