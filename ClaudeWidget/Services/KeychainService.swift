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

struct KeychainService: Sendable {
    static let serviceName = "Claude Code-credentials"

    static func getCredentials() throws -> OAuthCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
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
            return try JSONDecoder().decode(OAuthCredentials.self, from: data)
        } catch {
            throw KeychainError.decodingFailed(error)
        }
    }

    static func getAccessToken() throws -> String {
        try getCredentials().claudeAiOauth.accessToken
    }

    static func getRefreshToken() throws -> String {
        try getCredentials().claudeAiOauth.refreshToken
    }
}
