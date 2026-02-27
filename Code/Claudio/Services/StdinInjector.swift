import Foundation

enum StdinInjector {
    enum InjectionResult: Sendable {
        case success
        case failed(String)
    }

    static func inject(text: String, forPid pid: String) async -> InjectionResult {
        // 1. Try tmux
        if let pane = findTmuxPane(pid: pid) {
            let result = runShell("/usr/bin/tmux", args: ["send-keys", "-t", pane, text, "Enter"])
            if case .success = result { return .success }
        }

        // 2. Try Terminal.app
        let terminalScript = """
            tell application "System Events"
                if not (exists process "Terminal") then return "skip"
            end tell
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t contains "\(escaped(pid))" then
                            do script "\(escaped(text))" in t
                            return "ok"
                        end if
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        let termResult = runAppleScript(terminalScript)
        if case .success = termResult { return .success }

        // 3. Try iTerm2
        let itermScript = """
            tell application "System Events"
                if not (exists process "iTerm2") then return "skip"
            end tell
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s contains "\(escaped(pid))" then
                                tell s to write text "\(escaped(text))"
                                return "ok"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "notfound"
            """
        let itermResult = runAppleScript(itermScript)
        if case .success = itermResult { return .success }

        return .failed("Could not find terminal for PID \(pid). Use a remote session instead.")
    }

    // MARK: - Helpers

    private static func findTmuxPane(pid: String) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmux")
        process.arguments = ["list-panes", "-a", "-F", "#{pane_id} #{pane_pid}"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run(); process.waitUntilExit() } catch { return nil }
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        for line in output.components(separatedBy: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")
            guard parts.count == 2 else { continue }
            if parts[1] == pid {
                return parts[0]
            }
        }
        return nil
    }

    private static func runShell(_ path: String, args: [String]) -> InjectionResult {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run(); process.waitUntilExit() } catch {
            return .failed(error.localizedDescription)
        }

        if process.terminationStatus == 0 {
            return .success
        }
        return .failed("Process exited with status \(process.terminationStatus)")
    }

    private static func runAppleScript(_ source: String) -> InjectionResult {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run(); process.waitUntilExit() } catch {
            return .failed(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.contains("ok") {
            return .success
        }
        return .failed(output)
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
