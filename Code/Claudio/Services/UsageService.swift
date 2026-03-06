import Foundation

enum UsageError: Error, LocalizedError {
    case rateLimited
    case serverError(Int)
    case authExpired

    var errorDescription: String? {
        switch self {
        case .rateLimited: nil
        case .serverError(let code): "Usage API returned \(code)"
        case .authExpired: "Session expired — relaunch Claude Code to re-authenticate"
        }
    }
}

actor UsageService {
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://console.anthropic.com/api/oauth/token")!
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private var hassynced = false

    func fetchUsage() async throws -> UsageResponse {
        // Sync from keychain on first call to pick up tokens refreshed by Claude Code
        if !hassynced {
            hassynced = true
            let _ = KeychainService.shared.reloadFromKeychainSilently()
        }
        let token = try KeychainService.shared.getAccessToken()
        return try await request(with: token, retryCount: 0)
    }

    private func request(with token: String, retryCount: Int) async throws -> UsageResponse {
        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Claudio/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }

        if http.statusCode == 401 {
            guard retryCount < 2 else { throw UsageError.authExpired }
            let newToken = try await resolveAuth(staleToken: token)
            return try await self.request(with: newToken, retryCount: retryCount + 1)
        }

        if http.statusCode == 429 {
            // On first 429, try keychain — stale token may be rate-limited per-token
            if retryCount == 0,
               let fresh = KeychainService.shared.reloadFromKeychainSilently(),
               fresh.claudeAiOauth.accessToken != token {
                return try await self.request(with: fresh.claudeAiOauth.accessToken, retryCount: retryCount + 1)
            }
            throw UsageError.rateLimited
        }

        guard http.statusCode == 200 else {
            throw UsageError.serverError(http.statusCode)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    /// Resolves a fresh access token: keychain reload first, then OAuth refresh.
    private func resolveAuth(staleToken: String) async throws -> String {
        // 1. Re-read from keychain — Claude Code may have refreshed
        if let fresh = KeychainService.shared.reloadFromKeychainSilently(),
           fresh.claudeAiOauth.accessToken != staleToken {
            return fresh.claudeAiOauth.accessToken
        }

        // 2. Try OAuth token refresh
        return try await refreshAccessToken()
    }

    private func refreshAccessToken() async throws -> String {
        let refreshToken = try KeychainService.shared.getRefreshToken()

        // Try refreshing with current token
        if let token = try? await doRefresh(with: refreshToken) {
            return token
        }

        // Current refresh token failed — try keychain's if different
        if let fresh = KeychainService.shared.reloadFromKeychainSilently() {
            let keychainRefresh = fresh.claudeAiOauth.refreshToken
            if keychainRefresh != refreshToken,
               let token = try? await doRefresh(with: keychainRefresh) {
                return token
            }
            // Return keychain's access token as last resort
            return fresh.claudeAiOauth.accessToken
        }

        throw UsageError.authExpired
    }

    private func doRefresh(with refreshToken: String) async throws -> String {
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UsageError.authExpired
        }

        struct RefreshResponse: Codable {
            let access_token: String
            let refresh_token: String?
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let newToken = refreshResponse.access_token
        let newRefreshToken = refreshResponse.refresh_token ?? refreshToken

        let updated = OAuthCredentials(
            claudeAiOauth: .init(accessToken: newToken, refreshToken: newRefreshToken)
        )
        if let encoded = try? JSONEncoder().encode(updated) {
            KeychainService.shared.updateMirror(with: encoded)
        }

        return newToken
    }
}
