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
    private static let mirrorService = "com.mattjakob.ClaudeWidget.credentials"

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

        // Try our own mirror first (no prompt)
        if let data = readItem(service: Self.mirrorService) {
            if let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
                cache.set(creds)
                return creds
            }
        }

        // Fall back to Claude Code's item (may prompt once)
        guard let data = readItem(service: Self.sourceService) else {
            throw KeychainError.itemNotFound
        }

        do {
            let creds = try JSONDecoder().decode(OAuthCredentials.self, from: data)
            // Mirror to our own item for future prompt-free reads
            writeItem(service: Self.mirrorService, data: data)
            cache.set(creds)
            return creds
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    func updateMirror(with data: Data) {
        writeItem(service: Self.mirrorService, data: data)
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

    private func readItem(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func writeItem(service: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // Delete existing, then add new
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
