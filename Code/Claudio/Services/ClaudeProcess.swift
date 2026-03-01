import Foundation

actor ClaudeProcess {
    enum State: Sendable {
        case idle
        case running
        case terminated(code: Int32)
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
        guard case .idle = state else { return }

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

        let handle = stdout.fileHandleForReading
        readTask = Task { [weak self] in
            await self?.readLoop(handle: handle)
        }
    }

    func write(_ data: Data) {
        guard case .running = state else { return }
        stdinPipe?.fileHandleForWriting.write(data)
    }

    func interrupt() {
        guard case .running = state else { return }
        if let data = SDKOutbound.interrupt() {
            stdinPipe?.fileHandleForWriting.write(data)
        }
    }

    func terminate() {
        readTask?.cancel()
        readTask = nil
        process?.terminate()
    }

    // MARK: - Private

    private func readLoop(handle: FileHandle) async {
        var buffer = Data()

        while !Task.isCancelled {
            let chunk: Data = handle.availableData
            guard !chunk.isEmpty else {
                // EOF — process ended
                break
            }

            buffer.append(chunk)

            // Extract complete lines
            let newline: UInt8 = 0x0A
            var start = buffer.startIndex

            for i in buffer.indices where buffer[i] == newline {
                let lineData = Data(buffer[start..<i])
                start = buffer.index(after: i)

                guard !lineData.isEmpty else { continue }
                let message = SDKInboundParser.parse(line: lineData)

                // Update local state from system init
                if case .system(let sid, let m, let c) = message {
                    sessionId = sid
                    model = m
                    cwd = c
                }

                await onMessage?(message)
            }

            // Keep remainder
            if start < buffer.endIndex {
                buffer = Data(buffer[start...])
            } else {
                buffer = Data()
            }
        }
    }

    private func handleTermination(code: Int32) {
        state = .terminated(code: code)
        readTask?.cancel()
        readTask = nil
        Task { await onExit?(code) }
    }
}
