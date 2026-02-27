import Foundation

actor UsageService {
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private let refreshURL = URL(string: "https://console.anthropic.com/api/oauth/token")!
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    func fetchUsage() async throws -> UsageResponse {
        let token = try KeychainService.shared.getAccessToken()
        return try await request(with: token)
    }

    private func request(with token: String) async throws -> UsageResponse {
        var request = URLRequest(url: apiURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Claudio/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode == 401 {
            let newToken = try await refreshAccessToken()
            return try await self.request(with: newToken)
        }

        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func refreshAccessToken() async throws -> String {
        let refreshToken = try KeychainService.shared.getRefreshToken()

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
            // Refresh token is stale — try reloading fresh credentials from Keychain
            if let fresh = try? KeychainService.shared.reloadFromKeychain() {
                return fresh.claudeAiOauth.accessToken
            }
            throw URLError(.userAuthenticationRequired)
        }

        struct RefreshResponse: Codable {
            let access_token: String
            let refresh_token: String?
        }

        let refreshResponse = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let newToken = refreshResponse.access_token
        let newRefreshToken = refreshResponse.refresh_token ?? refreshToken

        // Update mirror with refreshed token
        let updated = OAuthCredentials(
            claudeAiOauth: .init(accessToken: newToken, refreshToken: newRefreshToken)
        )
        if let encoded = try? JSONEncoder().encode(updated) {
            KeychainService.shared.updateMirror(with: encoded)
        }

        return newToken
    }
}
