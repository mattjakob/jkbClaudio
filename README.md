# Claudio

<img src="https://raw.githubusercontent.com/mattjakob/jkbClaudio/main/Code/logo.png" alt="Claudio" width="128">

A macOS menu bar app that monitors Claude Code usage and active sessions in real time.

## What It Does

Claudio sits in your menu bar and displays your current Claude Code utilization percentage. Clicking it opens a popover with:

- **Usage chart** — 7-day and 5-hour utilization history with color-coded thresholds
- **Usage bars** — current utilization with reset countdowns and pace analysis
- **Active sessions** — up to 5 recent Claude Code sessions showing project name, model, git branch, token counts, tool calls, and process stats

It reads your existing Claude Code OAuth credentials (no separate login required) and polls the Anthropic usage API every 60 seconds.

## Install

Download [`Claudio.dmg`](https://github.com/mattjakob/jkbClaudio/releases/latest/download/Claudio.dmg), open it, and drag Claudio to Applications.

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 6.2 (strict concurrency) |
| UI | SwiftUI + Swift Charts |
| Build | Swift Package Manager (no Xcode project) |
| Target | macOS 26+ |

## Build

```bash
cd Code

# Debug
./build.sh
open ".build/arm64-apple-macosx/debug/Claudio.app"

# Release (signed + notarized DMG)
./build-release.sh 1.0.0
```

## Requirements

- macOS 26+
- Claude Code must be authenticated on the machine (credentials are read from its Keychain item)
