import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case decodingFailed(Error)

    var errorDescription: String? {
        switch self {
        case .itemNotFound: "Claude Code credentials not found in Keychain"
        case .unexpectedData: "Unexpected credential format"
        case .decodingFailed(let error): "Failed to decode credentials: \(error)"
        }
    }
}

final class KeychainService: Sendable {
    static let shared = KeychainService()

    private static let sourceService = "Claude Code-credentials"
    private static let mirrorPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/widget-credentials.json"
    }()

    private let cache = ManagedCache()

    private final class ManagedCache: @unchecked Sendable {
        private var credentials: OAuthCredentials?
        private let lock = NSLock()

        func get() -> OAuthCredentials? {
            lock.lock()
            defer { lock.unlock() }
            return credentials
        }

        func set(_ creds: OAuthCredentials) {
            lock.lock()
            defer { lock.unlock() }
            credentials = creds
        }
    }

    func getCredentials() throws -> OAuthCredentials {
        if let cached = cache.get() {
            return cached
        }

        // Try file mirror first (no prompt)
        if let data = FileManager.default.contents(atPath: Self.mirrorPath),
           let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            cache.set(creds)
            return creds
        }

        // Fall back to Claude Code's Keychain item (prompts once)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.sourceService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            throw KeychainError.itemNotFound
        }

        guard let data = result as? Data else {
            throw KeychainError.unexpectedData
        }

        do {
            let creds = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            // Save to file mirror for future prompt-free reads
            saveMirror(data)
            cache.set(creds)
            return creds
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    func updateMirror(with data: Data) {
        saveMirror(data)
        if let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            cache.set(creds)
        }
    }

    func getAccessToken() throws -> String {
        try getCredentials().claudeAiOauth.accessToken
    }

    func getRefreshToken() throws -> String {
        try getCredentials().claudeAiOauth.refreshToken
    }

    // MARK: - Private

    private func saveMirror(_ data: Data) {
        FileManager.default.createFile(atPath: Self.mirrorPath, contents: data)
        // Restrict permissions to owner only (chmod 600)
        chmod(Self.mirrorPath, 0o600)
    }
}
