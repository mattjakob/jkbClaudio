import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .itemNotFound: "Claude Code credentials not found"
        case .unexpectedData: "Unexpected credential format"
        case .decodingFailed(let error): "Failed to decode credentials: \(error)"
        }
    }
}

/// Reads OAuth credentials shared with Claude Code.
///
/// Resolution order (designed to NEVER prompt the keychain unless absolutely
/// necessary):
///   1. In-memory cache (fastest)
///   2. File mirror — `~/.claude/widget-credentials.json` (chmod 600). This
///      is our durable store between launches and after refreshes.
///   3. Claude Code's own credentials file — `~/.claude/.credentials.json`.
///      Some installs (Linux, certain macOS configs) put credentials here
///      instead of the keychain. No prompt.
///   4. Claude Code's keychain item — last resort. May prompt.
///
/// Token refresh is owned by `UsageService`; new tokens get written back here
/// via `updateMirror(with:)` so the keychain stays untouched on the hot path.
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private static let sourceService = "Claude Code-credentials"
    private static let mirrorPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/widget-credentials.json"
    }()
    private static let credentialsFilePath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/.credentials.json"
    }()

    private let cache = ManagedCache()

    private final class ManagedCache: @unchecked Sendable {
        private var credentials: OAuthCredentials?
        private let lock = NSLock()

        func get() -> OAuthCredentials? {
            lock.lock(); defer { lock.unlock() }
            return credentials
        }

        func set(_ creds: OAuthCredentials) {
            lock.lock(); defer { lock.unlock() }
            credentials = creds
        }

        func clear() {
            lock.lock(); defer { lock.unlock() }
            credentials = nil
        }
    }

    // MARK: - Read

    /// Returns credentials from cache, mirror, or Claude Code's own credentials
    /// file without ever prompting. Falls back to the keychain (which may
    /// prompt) only if no other source is available — first-launch case.
    func getCredentials() throws -> OAuthCredentials {
        if let cached = cache.get() { return cached }
        if let creds = readJSONFile(at: Self.mirrorPath) {
            cache.set(creds); return creds
        }
        if let creds = readJSONFile(at: Self.credentialsFilePath) {
            cache.set(creds)
            // Persist to our mirror so subsequent reads stay consistent.
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            return creds
        }
        return try readKeychainPrompting()
    }

    func getAccessToken() throws -> String {
        try getCredentials().claudeAiOauth.accessToken
    }

    func getRefreshToken() throws -> String {
        try getCredentials().claudeAiOauth.refreshToken
    }

    /// Writes new credentials to the mirror and updates the cache.
    /// Used by UsageService after a successful OAuth refresh.
    func updateMirror(with data: Data) {
        saveMirror(data)
        if let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            cache.set(creds)
        }
    }

    /// LAST resort recovery: re-read from Claude Code's keychain. May prompt
    /// the user if the ACL has been reset by a Claude Code token rotation.
    /// Used only when our own OAuth refresh has failed.
    func recoverFromKeychain() -> OAuthCredentials? {
        cache.clear()
        // Try the credentials file once more in case Claude Code re-authed.
        if let creds = readJSONFile(at: Self.credentialsFilePath) {
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            cache.set(creds)
            return creds
        }
        if let creds = try? readKeychainSilent() { return creds }
        return readKeychainViaSecurityCLI()
    }

    // MARK: - Private

    private func readJSONFile(at path: String) -> OAuthCredentials? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(OAuthCredentials.self, from: data)
    }

    /// Direct read with UI prompt allowed. Throws if anything goes wrong.
    private func readKeychainPrompting() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.sourceService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.itemNotFound }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return try decodeAndCache(data)
    }

    /// Silent read — fails (without prompting) if the ACL forbids us.
    private func readKeychainSilent() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.sourceService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError.itemNotFound }
        guard let data = result as? Data else { throw KeychainError.unexpectedData }
        return try decodeAndCache(data)
    }

    /// Reads via `/usr/bin/security`. Generally won't prompt because the user
    /// has already authorized the binary against their login keychain, but
    /// will prompt the FIRST time after Claude Code recreates the item.
    /// 3-second hard timeout prevents hangs (observed on macOS 26.3+).
    private func readKeychainViaSecurityCLI() -> OAuthCredentials? {
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", Self.sourceService, "-w"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        let timeoutTask = DispatchWorkItem { [weak proc] in
            guard let proc, proc.isRunning else { return }
            proc.terminate()
            // SIGKILL after 200ms if SIGTERM didn't take.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0, execute: timeoutTask)

        proc.waitUntilExit()
        timeoutTask.cancel()

        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return try? decodeAndCache(data)
    }

    @discardableResult
    private func decodeAndCache(_ data: Data) throws -> OAuthCredentials {
        do {
            let creds = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            saveMirror(data)
            cache.set(creds)
            return creds
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    private func saveMirror(_ data: Data) {
        let url = URL(fileURLWithPath: Self.mirrorPath)
        try? data.write(to: url, options: .atomic)
        chmod(Self.mirrorPath, 0o600)
    }
}
