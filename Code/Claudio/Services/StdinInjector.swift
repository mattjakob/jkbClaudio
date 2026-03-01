import Foundation
import AppKit

enum StdinInjector {
    enum InjectionResult: Sendable {
        case success
        case failed(String)
    }

    /// Check if an app is currently running by name.
    @MainActor
    private static func isAppRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == name
        }
    }

    /// Inject text into the terminal session of a given PID.
    /// Resolves PID → TTY, then tries: tmux send-keys, iTerm2 write text, Terminal.app keystroke.
    static func inject(text: String, forPid pid: String) async -> InjectionResult {
        guard let tty = resolveTTY(pid: pid) else {
            return .failed("Could not resolve TTY for PID \(pid)")
        }

        let ttyPath = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        // 1. tmux — send-keys writes to PTY master, Enter is a proper keypress
        if let pane = findTmuxPane(tty: ttyPath) {
            let result = tmuxSendKeys(pane: pane, text: text)
            if case .success = result { return .success }
        }

        // 2. iTerm2 — only attempt if actually running
        let itermRunning = await isAppRunning("iTerm2")
        if itermRunning {
            let itermResult = await iterm2Inject(text: text, ttyPath: ttyPath)
            if case .success = itermResult { return itermResult }
        }

        // 3. Terminal.app — only attempt if actually running
        let termRunning = await isAppRunning("Terminal")
        if termRunning {
            let termResult = await terminalAppInject(text: text, ttyPath: ttyPath)
            if case .success = termResult { return termResult }
            // Surface actual error instead of generic message
            return termResult
        }

        return .failed("No supported terminal running for TTY \(ttyPath)")
    }

    // MARK: - TTY resolution

    private static func resolveTTY(pid: String) -> String? {
        let pipe = Pipe()
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", pid, "-o", "tty="]
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice

        do { try ps.run(); ps.waitUntilExit() } catch { return nil }
        guard ps.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !output.isEmpty, output != "??" else { return nil }
        return output
    }

    // MARK: - tmux

    private static func findTmuxPane(tty: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            guard parts.count == 2 else { continue }
            if parts[0] == tty { return parts[1] }
        }
        return nil
    }

    private static func tmuxSendKeys(pane: String, text: String) -> InjectionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "send-keys", "-t", pane, "-l", text]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do { try process.run(); process.waitUntilExit() } catch {
            return .failed(error.localizedDescription)
        }
        guard process.terminationStatus == 0 else { return .failed("tmux send-keys failed") }

        let enter = Process()
        enter.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        enter.arguments = ["tmux", "send-keys", "-t", pane, "Enter"]
        enter.standardOutput = FileHandle.nullDevice
        enter.standardError = FileHandle.nullDevice

        do { try enter.run(); enter.waitUntilExit() } catch {
            return .failed(error.localizedDescription)
        }

        return .success
    }

    // MARK: - iTerm2

    /// Match session by TTY, then `write text` which sends as though the user typed it.
    private static func iterm2Inject(text: String, ttyPath: String) async -> InjectionResult {
        let script = """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(escaped(ttyPath))" then
                                tell s to write text "\(escaped(text))"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        return await runAppleScriptOnMain(script)
    }

    // MARK: - Terminal.app

    /// Find tab by TTY, focus it, type text + Enter via System Events keystroke.
    /// Requires Accessibility permission — opens System Settings on first denial.
    private static func terminalAppInject(text: String, ttyPath: String) async -> InjectionResult {
        // Pre-check: keystroke silently fails without Accessibility
        guard AXIsProcessTrusted() else {
            await MainActor.run {
                let _ = AXIsProcessTrustedWithOptions(
                    ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                )
            }
            return .failed("Accessibility permission required. Grant it in System Settings > Privacy & Security > Accessibility, then retry.")
        }

        let focusScript = """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(escaped(ttyPath))" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "notfound"
            """

        let focusResult = await runAppleScriptOnMain(focusScript)
        guard case .success = focusResult else { return focusResult }

        try? await Task.sleep(for: .milliseconds(200))

        let typeScript = """
            tell application "System Events"
                tell process "Terminal"
                    keystroke "\(escaped(text))"
                    delay 0.05
                    key code 36
                end tell
            end tell
            return "ok"
            """

        let typeResult = await runAppleScriptOnMain(typeScript)

        // If Accessibility permission denied (error 1002)
        if case .failed(let msg) = typeResult, msg.contains("1002") {
            let alreadyListed = AXIsProcessTrusted()
            // Prompt via native API (shows dialog if not trusted)
            await MainActor.run {
                let _ = AXIsProcessTrustedWithOptions(
                    ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                )
            }
            let hint = alreadyListed
                ? "Accessibility entry is stale (app was rebuilt). Toggle Claudio off and on in System Settings > Accessibility, then retry."
                : "Accessibility permission required. Grant it in the dialog or System Settings, then retry."
            return .failed(hint)
        }

        return typeResult
    }

    // MARK: - Helpers

    /// Runs AppleScript on the main thread via NSAppleScript.
    /// Must be on main thread for Automation permission dialogs to appear.
    private static func runAppleScriptOnMain(_ source: String) async -> InjectionResult {
        await MainActor.run {
            var errorInfo: NSDictionary?
            let script = NSAppleScript(source: source)
            let result = script?.executeAndReturnError(&errorInfo)

            if let errorInfo {
                let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
                let code = errorInfo[NSAppleScript.errorNumber] as? Int
                let detail = code.map { " (error \($0))" } ?? ""
                return InjectionResult.failed("\(message)\(detail)")
            }

            let output = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            if output == "ok" { return .success }
            if output == "skip" || output == "notfound" {
                return .failed(output)
            }

            return .failed(output.isEmpty ? "No output from AppleScript" : output)
        }
    }

    /// Escape for AppleScript string literals.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
