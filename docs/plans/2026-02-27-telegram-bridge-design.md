# Telegram Bridge Design

Two-way messaging bridge between Claude Code agents running locally and Telegram, built into Claudio.

## Goals

- Receive Claude Code agent messages, tool outputs, permission requests, and elicitation dialogs via Telegram
- Approve/deny permissions from Telegram with inline buttons
- Answer elicitation dialogs (choose between options) from Telegram
- Start new remote Claude Code sessions from Telegram with full two-way I/O
- Reply to idle sessions with text prompts

## Architecture

```
Claudio (Swift macOS app)
├── Existing: Menu Bar UI, UsageService, SessionService, OTelReceiver
└── New: Bridge Module
    ├── TelegramService       — Bot API client (long polling + send)
    ├── HookServer            — Local HTTP server (:19876) for Claude Code hooks
    ├── SessionWatcher        — DispatchSource file monitors on JSONL files
    ├── RemoteSessionManager  — Spawn/manage Claude subprocess for remote sessions
    ├── StdinInjector         — Inject keystrokes into terminal sessions (best-effort)
    └── BridgeCoordinator     — Routes events between all services
```

## Event Flow

### Outbound: Claude Code -> Telegram

Two event sources:

**JSONL file watcher (transcript events):**
- `type == "assistant"` with text content -> formatted message
- `type == "assistant"` with tool_use -> tool name + summary
- Rate-limited: batch within 1-2s to avoid flooding

**Hook server (interactive events):**

| Hook Event | Telegram Action |
|---|---|
| PermissionRequest | Message with Approve/Deny inline buttons. HTTP held open until response. |
| Notification(idle_prompt) | "Session idle" message |
| Notification(elicitation_dialog) | Question text with numbered option buttons |
| Notification(permission_prompt) | Forward notification text |
| Stop | "Agent finished" summary |
| SessionStart | "New session started: {project}" |
| SessionEnd | "Session ended: {project}" |

### Inbound: Telegram -> Claude Code

| User Action | What Happens |
|---|---|
| Tap Approve/Deny button | HookServer returns decision to blocked hook |
| Tap elicitation option button | StdinInjector types option into terminal |
| Text reply to idle session | StdinInjector types message into terminal |
| `/run {project} {prompt}` | RemoteSessionManager spawns claude process |
| Text during remote session | Writes to spawned process stdin |

## Components

### TelegramService (~250 lines)

Raw URLSession actor. No external dependencies.

- `getUpdates(timeout:)` — long polling
- `sendMessage(chatId:text:parseMode:replyMarkup:)` — send with optional inline keyboard
- `answerCallbackQuery(id:text:)` — acknowledge button press
- `editMessageReplyMarkup(chatId:messageId:)` — remove buttons after action
- `startPolling(handler:)` — async loop calling getUpdates

Codable types: TGUpdate, TGMessage, TGCallbackQuery, TGUser, TGChat, TGInlineKeyboardMarkup, TGInlineKeyboardButton (~80 lines in TelegramModels.swift).

### HookServer (~200 lines)

Lightweight HTTP server using NWListener (Network.framework) on port 19876.

Endpoints:
- `POST /hook/permission` — receives PermissionRequest JSON, holds connection, returns decision
- `POST /hook/notification` — receives Notification JSON, responds immediately
- `POST /hook/stop` — receives Stop JSON, responds immediately
- `POST /hook/session-start` — receives SessionStart JSON
- `POST /hook/session-end` — receives SessionEnd JSON

For permission requests: stores a pending continuation, resolves when Telegram callback arrives.

### SessionWatcher (~150 lines)

Per-file DispatchSource monitors using `O_EVTONLY` + `.extend`/`.write` event mask.

- Seeks to end of file on start (only new data)
- Parses new bytes as JSONL lines
- Handles file deletion/rename (re-watch)
- Managed by BridgeCoordinator: watchers added/removed as sessions appear/disappear

### RemoteSessionManager (~200 lines)

Spawns `claude` as a child Process with piped stdin/stdout/stderr.

- `/run {project} {prompt}` starts: `claude -p "{prompt}" --output-format stream-json` in project dir
- Ongoing remote session: `claude --output-format stream-json` with stdin pipe for follow-up messages
- Stream JSON output parsed and forwarded to Telegram
- Process lifecycle managed (kill on timeout, cleanup on exit)

### StdinInjector (~100 lines)

Best-effort keystroke injection with fallback chain:

1. Check `tmux` — `tmux list-panes` to find Claude's pane, then `tmux send-keys`
2. Check Terminal.app — AppleScript `keystroke` to target window
3. Check iTerm2 — AppleScript `write text` to target session
4. Fail gracefully — tell user to use remote session

Requires: matching Claude PID to terminal session/pane.

### BridgeCoordinator (~200 lines)

Central router. Owns references to all services.

- On app launch: starts TelegramService polling + HookServer
- When sessions change: starts/stops SessionWatcher instances
- Routes hook events -> TelegramService
- Routes Telegram callbacks -> HookServer (permissions) or StdinInjector (text)
- Routes remote session commands -> RemoteSessionManager
- Manages message deduplication (JSONL watcher + hooks may overlap)

## Configuration

### One-time setup flow

1. User creates Telegram bot via @BotFather, gets token
2. User enters token in Claudio settings
3. User sends `/start` to bot — Claudio captures chat_id
4. Claudio auto-installs hooks in `~/.claude/settings.json`

### Hook configuration (auto-installed)

```json
{
  "hooks": {
    "PermissionRequest": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "curl -s -X POST http://localhost:19876/hook/permission -d @-",
        "timeout": 120
      }]
    }],
    "Notification": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "curl -s -X POST http://localhost:19876/hook/notification -d @-"
      }]
    }],
    "Stop": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "curl -s -X POST http://localhost:19876/hook/stop -d @-"
      }]
    }],
    "SessionStart": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "curl -s -X POST http://localhost:19876/hook/session-start -d @-"
      }]
    }],
    "SessionEnd": [{
      "matcher": "",
      "hooks": [{
        "type": "command",
        "command": "curl -s -X POST http://localhost:19876/hook/session-end -d @-"
      }]
    }]
  }
}
```

### Settings UI

Section in popover or separate view:
- Telegram Bot Token (text field)
- Connection status + chat ID
- Hooks installed (yes/no + Install button)
- Event filter toggles
- Master enable/disable toggle

## New Files

```
Services/
  TelegramService.swift       (~250 lines)
  HookServer.swift            (~200 lines)
  SessionWatcher.swift        (~150 lines)
  RemoteSessionManager.swift  (~200 lines)
  StdinInjector.swift         (~100 lines)
  BridgeCoordinator.swift     (~200 lines)

Models/
  TelegramModels.swift        (~80 lines)
  HookEvent.swift             (~60 lines)

Views/
  BridgeSettingsView.swift    (~100 lines)
```

Estimated: ~1,340 lines across 9 new files.

## Decisions

- **Raw URLSession** over Telegram libraries (zero deps, ~250 lines, Swift 6 native)
- **DispatchSource** over FSEvents for file watching (per-file, instant, simpler API)
- **NWListener** for HTTP server (Network.framework, no deps)
- **curl-based hooks** (simplest, no custom binary needed, works everywhere)
- **Best-effort stdin injection** with graceful fallback to remote sessions

## Risks

- Hook installation modifies `~/.claude/settings.json` (must merge, not overwrite)
- StdinInjector is inherently fragile (terminal detection, window targeting)
- Claude Code hook API may change between versions
- Long-polling Telegram + HTTP server + file watchers = multiple async loops to manage
- Message deduplication between JSONL watcher and hooks needs care
