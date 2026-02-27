import Foundation

actor RemoteSessionManager {
    private struct RemoteSession {
        let process: Process
        let stdin: FileHandle
        let projectPath: String
    }

    private var session: RemoteSession?

    private(set) var onOutput: (@Sendable (String) async -> Void)?

    func setOnOutput(_ handler: @escaping @Sendable (String) async -> Void) {
        onOutput = handler
    }

    var hasActiveSession: Bool { session != nil }

    var activeProject: String? { session?.projectPath }

    func start(projectPath: String, prompt: String) async throws {
        await stop()

        guard let claudePath = findClaude() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "claude executable not found"
            ])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", prompt, "--output-format", "stream-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let callback = onOutput
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await callback?(text) }
        }

        process.terminationHandler = { [weak self] _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            Task { await self?.clearSession() }
        }

        try process.run()

        session = RemoteSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            projectPath: projectPath
        )
    }

    func sendInput(_ text: String) {
        guard let handle = session?.stdin,
              let data = "\(text)\n".data(using: .utf8) else { return }
        handle.write(data)
    }

    func stop() async {
        guard let session else { return }
        session.process.terminate()
        session.process.waitUntilExit()
        self.session = nil
    }

    private func clearSession() {
        session = nil
    }

    private nonisolated func findClaude() -> String? {
        let candidates = [
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            "/opt/homebrew/bin/claude"
        ]

        let fm = FileManager.default
        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }

        // Fall back to `which claude`
        let pipe = Pipe()
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["claude"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice

        do { try which.run(); which.waitUntilExit() } catch { return nil }

        guard which.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let result, !result.isEmpty else { return nil }
        return result
    }
}
