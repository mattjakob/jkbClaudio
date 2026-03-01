import Foundation

actor RemoteSessionManager {
    private struct RemoteSession {
        let process: Process
        let stdin: FileHandle
        let projectPath: String
        let generation: Int
    }

    private var session: RemoteSession?
    private var generation: Int = 0
    private var lineBuffer = Data()

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

        generation += 1
        let currentGen = generation
        lineBuffer = Data()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["-p", prompt, "--output-format", "stream-json"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.handleChunk(data) }
        }

        process.terminationHandler = { [weak self] _ in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            Task { await self?.clearSession(generation: currentGen) }
        }

        try process.run()

        session = RemoteSession(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            projectPath: projectPath,
            generation: currentGen
        )
    }

    /// Buffer incoming chunks and emit complete lines to the output handler.
    private func handleChunk(_ data: Data) async {
        lineBuffer.append(data)

        let newline: UInt8 = 0x0A
        var start = lineBuffer.startIndex

        for i in lineBuffer.indices where lineBuffer[i] == newline {
            let lineData = lineBuffer[start..<i]
            if !lineData.isEmpty, let text = String(data: Data(lineData), encoding: .utf8) {
                await onOutput?(text)
            }
            start = lineBuffer.index(after: i)
        }

        // Keep unconsumed remainder
        if start < lineBuffer.endIndex {
            lineBuffer = Data(lineBuffer[start...])
        } else {
            lineBuffer = Data()
        }
    }

    func sendInput(_ text: String) {
        guard let handle = session?.stdin,
              let data = "\(text)\n".data(using: .utf8) else { return }
        handle.write(data)
    }

    func stop() async {
        guard let session else { return }
        session.process.terminate()
        await withCheckedContinuation { continuation in
            if !session.process.isRunning {
                continuation.resume()
                return
            }
            session.process.terminationHandler = { _ in
                continuation.resume()
            }
        }
        self.session = nil
        lineBuffer = Data()
    }

    /// Only clears session if generation matches — prevents stale handlers from killing new sessions.
    private func clearSession(generation gen: Int) {
        guard session?.generation == gen else { return }
        session = nil
    }

    private nonisolated func findClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/claude",
            "/usr/local/bin/claude",
            home + "/.claude/local/claude",
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
