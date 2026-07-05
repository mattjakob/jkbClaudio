import Foundation
import Darwin

/// Helpers for the installed `claude` CLI.
enum ClaudeCLI {
    /// Runs `claude --version` (2 s timeout) and extracts "x.y.z".
    static func detectVersion() async -> String? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude", "--version"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let deadline = Task {
            try await Task.sleep(for: .seconds(2))
            if proc.isRunning { proc.terminate() }
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                proc.waitUntilExit()
                deadline.cancel()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil); return
                }
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                                    encoding: .utf8) ?? ""
                continuation.resume(returning: parseVersion(from: output))
            }
        }
    }

    static func parseVersion(from output: String) -> String? {
        guard let range = output.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range])
    }
}

/// Refreshes Claude Code's OAuth token WITHOUT touching the refresh token
/// ourselves: spawns `claude` in a PTY, sends `/status` (no model call, no
/// token cost), and waits for the external credentials fingerprint to
/// change — proof the CLI refreshed and persisted new credentials.
actor ClaudeDelegatedRefresh {
    private var lastAttempt: Date?
    private static let attemptCooldown: TimeInterval = 60

    /// Returns true if the credentials fingerprint changed (CLI refreshed).
    func attempt(fingerprint: @escaping @Sendable () -> String) async -> Bool {
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.attemptCooldown {
            return false
        }
        lastAttempt = Date()

        let initial = fingerprint()
        var master: Int32 = 0
        var slave: Int32 = 0
        guard openpty(&master, &slave, nil, nil, nil) == 0 else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["claude"]
        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        // Drain PTY output so the CLI never blocks on a full buffer.
        masterHandle.readabilityHandler = { handle in _ = handle.availableData }

        defer {
            masterHandle.readabilityHandler = nil
            if proc.isRunning { proc.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak proc] in
                if let proc, proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }

        do { try proc.run() } catch { return false }

        // Give the CLI time to boot; startup alone refreshes an expired
        // token, /status additionally touches the auth path.
        try? await Task.sleep(for: .seconds(2))
        if fingerprint() != initial { return true }
        try? masterHandle.write(contentsOf: Data("/status\r".utf8))

        return await Self.pollForChange(initial: initial, fingerprint: fingerprint,
                                        delays: [0.3, 0.5, 0.8, 1.2, 2.0])
    }

    /// Polls until fingerprint() differs from initial, sleeping through the
    /// given delays. Separated for testability.
    static func pollForChange(initial: String,
                              fingerprint: @Sendable () -> String,
                              delays: [TimeInterval]) async -> Bool {
        for delay in delays {
            try? await Task.sleep(for: .seconds(delay))
            if fingerprint() != initial { return true }
        }
        return fingerprint() != initial
    }
}
