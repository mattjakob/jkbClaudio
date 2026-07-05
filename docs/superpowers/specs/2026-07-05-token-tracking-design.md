# Token Tracking v2 — Design

Date: 2026-07-05
Status: Approved (scope and design approved by Matt; patterns adapted from steipete/CodexBar's Claude provider)

## Goal

Streamlined, safe, correct realtime monitoring of Claude token usage in Claudio:

1. **Part A** — harden the existing usage-API polling: never break Claude Code's auth, no retry storms, fresher data with fewer wasted polls, forward-compatible response parsing.
2. **Part B** — add realtime local token counts (actual input/output/cache tokens per model per day) from Claude Code's session JSONL transcripts.

Non-goals: other providers, cost estimation in dollars, new settings UI.

## Part A — API polling hardening

### A1. Read-only stance on Claude Code's credentials

Today `UsageService` refreshes with Claude Code's refresh token, rotating it out from under the CLI — the root cause of the recurring auth races (commits 5091b71, b0d1b5a). New expiry handling, in order:

1. **Piggyback**: re-read `~/.claude/.credentials.json` and, silently (no UI prompt), the `Claude Code-credentials` keychain item. Compare a SHA-256 fingerprint of each source against the last-seen fingerprint; if changed, Claude Code refreshed already — adopt its credentials into the mirror and proceed.
2. **Delegated refresh**: spawn the `claude` CLI in a PTY, send `/status\r`, poll the credentials fingerprint every 0.2/0.5/0.8 s for up to ~2 s until it changes, then kill the process and adopt the new credentials. `/status` makes no model call, so this costs no tokens.
3. **Direct refresh (last resort)**: only when the `claude` binary is missing or delegation failed, POST `platform.claude.com/v1/oauth/token` with the mirror's refresh token (current behavior), writing results only to Claudio's mirror.

`KeychainService` gains: `fingerprint()` (SHA-256 over the raw bytes of each source), and a documented guarantee that background reads never present a keychain prompt (`kSecUseAuthenticationUISkip`; the `security` CLI fallback stays for recovery only).

### A2. Failure gates

New `RefreshGates` (persisted in `UserDefaults`):

- **Auth gate**: an OAuth refresh answering `invalid_grant` (or delegation + direct refresh both failing with auth errors) blocks further refresh attempts until the credentials fingerprint changes (i.e., the user re-authenticated). No timed retries against a dead refresh token.
- **Transient gate**: network/5xx refresh failures back off exponentially, 5 min doubling to a 6 h cap; cleared on success or fingerprint change.
- **429 gate**: on HTTP 429 from the usage endpoint, parse `Retry-After` (delta-seconds or HTTP-date; default 5 min when absent) and persist `blockedUntil`. Background polls short-circuit before the request while blocked; a user-initiated refresh (popover open) bypasses the gate. Cleared on first success.

### A3. Fresher data, fewer wasted polls

- **Reset-boundary refresh**: after each successful fetch, if the nearest `resets_at` lands before the next scheduled tick, schedule a one-shot refresh at `resets_at + 2 s` (dedup per boundary), so bars drop to 0% promptly.
- **Adaptive cadence** (replaces the fixed 120 s timer), a pure function of app state re-evaluated each tick:
  - **2 min** — any active Claude Code session (hook signal from `BridgeCoordinator`/`SessionService`) or popover opened within the last 5 min
  - **15 min** — otherwise
  - **30 min** — Low Power Mode on, or thermal state serious/critical (overrides the above)
  - Popover open always triggers an immediate refresh (bypassing the 429 gate; still subject to the auth gate).

### A4. Forward-compatible parsing and headers

- Decode `seven_day_sonnet` and the newer `limits[]` array: `{kind, group, percent, resets_at, scope.model.{id, display_name}}`. Do not filter on `is_active` (observed unreliable). Flat keys remain primary; `limits[]` entries surface as additional named windows when they carry data the flat keys don't.
- All new fields optional; unknown keys ignored (tolerant decoding).
- `User-Agent: claude-code/<version>` — detected once per launch via `claude --version` (2 s timeout), falling back to a hardcoded recent version string.

## Part B — Realtime local token counts

### TokenScanner (new actor, `Services/TokenScanner.swift`)

- **Roots**: `$CLAUDE_CONFIG_DIR` (comma-separated, `/projects` appended), else `~/.claude/projects` and `~/.config/claude/projects`; scans `**/*.jsonl`.
- **Incremental**: per-file cache `{mtime, size, parsedBytes}` persisted at `~/Library/Caches/Claudio/token-scan-v1.json`. Unchanged files are skipped; grown files parse only the appended tail; shrunk/replaced files reparse from 0.
- **Cheap line filter**: a line is JSON-decoded only if its bytes contain both `"type":"assistant"` and `"usage"`. Max line 512 KB.
- **Extraction**: from `message.usage` — `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`; keyed by `message.model` and local day (`timestamp` field).
- **Streaming dedup**: chunks of one API call share `message.id` + `requestId`; the last-seen chunk's cumulative usage wins (store per-key, overwrite).
- **Triggers**: rescan on hook events from `HookServer` (debounced 2 s) and on each poll tick. No timer of its own.

### Model (`Models/TokenUsage.swift`)

`TokenCounts {input, output, cacheCreate, cacheRead}` with `total`; `TokenUsageSnapshot { today: [model: TokenCounts], todayTotal: TokenCounts }`. Formatting helper for compact display (`12.4K`, `1.2M`).

### UI (`Views/TokenStatsCard.swift`)

One new popover card: today's total tokens (input / output / cache read / cache write) plus a per-model breakdown, updating live while sessions stream. Follows existing card styling (`UsageCard`/`SessionCard` patterns, glass effects).

## Data flow

```
adaptive timer ──┐
popover open ────┼─> AppViewModel.refresh() ─> UsageService.fetchUsage() ─> windows/limits → UI
resets_at+2s ────┘                        └─> TokenScanner.snapshot()  ─> token counts → UI
hook event (debounced) ──────────────────────^
```

Auth: `UsageService` → `KeychainService` (cache → mirror → credentials file → silent keychain) → piggyback/delegate/direct per A1, gated per A2.

## Error handling

- Transient fetch failures keep the last good snapshot; UI never blanks (existing behavior, preserved).
- Scanner I/O errors skip the offending file for that pass; cache corruption → delete cache and full rescan.
- Delegation PTY failures (no binary, timeout) fall through silently to direct refresh; all gates persisted so relaunch doesn't reset backoff.

## Files

| Change | File | Notes |
|---|---|---|
| Modify | `Services/UsageService.swift` | A1 auth order, A2 gate checks, A4 UA |
| Modify | `Services/KeychainService.swift` | fingerprints, credential adoption |
| Modify | `Models/UsageData.swift` | `seven_day_sonnet`, `limits[]` |
| Modify | `ViewModel/AppViewModel.swift` | adaptive timer, reset-boundary one-shot, scanner wiring |
| Modify | `Views/PopoverView.swift` | add TokenStatsCard |
| New | `Services/RefreshGates.swift` | A2 gates (429 + refresh failure), persisted |
| New | `Services/ClaudeDelegatedRefresh.swift` | PTY `/status` probe |
| New | `Services/TokenScanner.swift` | Part B scanner |
| New | `Models/TokenUsage.swift` | Part B model |
| New | `Views/TokenStatsCard.swift` | Part B card |

All files stay under 600 lines; one responsibility each.

## Testing & verification

- `swift build` clean; add unit tests for: JSONL line parsing + dedup, incremental tail parsing (`parsedBytes` behavior), `Retry-After` parsing, adaptive cadence function, `limits[]` decoding fixtures.
- End-to-end: `./build.sh`, replace `/Applications/Claudio.app`, relaunch; confirm live token counts move during an active Claude Code session and utilization bars still populate.
