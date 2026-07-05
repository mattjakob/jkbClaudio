import Foundation

/// Wraps a single `claude -p ...` subprocess that streams JSON over stdio.
///
/// The reader runs as a detached, nonisolated Task using `FileHandle.bytes`
/// so the actor itself stays free to handle concurrent `write`, `interrupt`,
/// and `terminate` calls.
actor ClaudeProcess {
    enum State: Sendable {
        case idle
        case running
        case terminated(code: Int32)
    }

    enum SpawnError: Error, LocalizedError {
        case alreadyRunning
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Process already running"
            }
        }
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var readTask: Task<Void, Never>?

    private(set) var state: State = .idle
    private(set) var sessionId: String?
    private(set) var model: String?
    private(set) var cwd: String?

    private var onMessage: (@Sendable (SDKInbound) async -> Void)?
    private var onExit: (@Sendable (Int32) async -> Void)?

    func setOnMessage(_ handler: @escaping @Sendable (SDKInbound) async -> Void) {
        onMessage = handler
    }

    func setOnExit(_ handler: @escaping @Sendable (Int32) async -> Void) {
        onExit = handler
    }

    func spawn(prompt: String, workingDirectory: String) throws {
        guard case .idle = state else { throw SpawnError.alreadyRunning }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [
            "claude",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--permission-prompt-tool", "stdio",
            "--verbose",
            "-p", prompt
        ]
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        let stdin = Pipe()
        let stdout = Pipe()

        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice

        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { await self?.handleTermination(code: code) }
        }

        try proc.run()

        self.process = proc
        self.stdinPipe = stdin
        self.state = .running

        let reader = stdout.fileHandleForReading
        readTask = Task.detached(priority: .utility) { [weak self] in
            await self?.runReadLoop(reader: reader)
        }
    }

    func write(_ data: Data) {
        guard case .running = state else { return }
        try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
    }

    func interrupt() {
        guard case .running = state else { return }
        if let data = SDKOutbound.interrupt() {
            try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
        }
    }

    func terminate() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
    }

    // MARK: - Private

    /// Nonisolated reader: streams stdout line-by-line without blocking the actor.
    private nonisolated func runReadLoop(reader: FileHandle) async {
        do {
            for try await line in reader.bytes.lines {
                if Task.isCancelled { break }
                guard let data = line.data(using: .utf8), !data.isEmpty else { continue }
                let message = SDKInboundParser.parse(line: data)
                await self.dispatch(message)
            }
        } catch {
            // EOF or pipe error — termination handler closes out the rest.
        }
    }

    /// Hops back to the actor to update state and notify the listener.
    private func dispatch(_ message: SDKInbound) async {
        if case .system(let sid, let m, let c) = message {
            sessionId = sid
            model = m
            cwd = c
        }
        await onMessage?(message)
    }

    private func handleTermination(code: Int32) {
        state = .terminated(code: code)
        readTask?.cancel()
        readTask = nil
        Task { [weak self] in await self?.onExit?(code) }
    }
}
