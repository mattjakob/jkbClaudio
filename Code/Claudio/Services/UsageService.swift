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

/// Polls the Anthropic OAuth usage endpoint.
///
/// Auth strategy (designed to NEVER prompt the keychain unless absolutely
/// necessary):
///  - Normal path: read access token from KeychainService cache/mirror.
///  - Proactive: if `expiresAt` shows the token is within 5 min of expiring,
///    refresh BEFORE making the request — avoids the 401 round-trip entirely.
///  - On 401: refresh via OAuth using our cached refresh_token. No keychain.
///  - On refresh failure: as a last resort, recover from keychain (which may
///    prompt). Happens only when our refresh_token has been invalidated
///    externally (e.g., user re-authed via Claude Code on another machine).
actor UsageService {
    private let apiURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Per the official Claude Code SDK, the canonical refresh endpoint is
    /// `platform.claude.com`. Older code used `console.anthropic.com` which
    /// may still work but is no longer the published endpoint.
    private let refreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func fetchUsage() async throws -> UsageResponse {
        let token = try await currentAccessToken()
        return try await request(with: token, hasRefreshed: false)
    }

    /// Returns a non-expired access token. Refreshes proactively if needed.
    private func currentAccessToken() async throws -> String {
        let creds = try KeychainService.shared.getCredentials()
        if creds.needsRefresh() {
            if let token = try? await refresh(using: creds.claudeAiOauth.refreshToken) {
                return token
            }
            // Proactive refresh failed — fall through and let the request hit
            // 401 so the recovery path runs.
        }
        return creds.claudeAiOauth.accessToken
    }

    private func request(with token: String, hasRefreshed: Bool) async throws -> UsageResponse {
        var req = URLRequest(url: apiURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("Claudio/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }

        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(UsageResponse.self, from: data)

        case 401:
            guard !hasRefreshed else { throw UsageError.authExpired }
            let newToken = try await acquireFreshToken(stale: token)
            return try await request(with: newToken, hasRefreshed: true)

        case 429:
            throw UsageError.rateLimited

        default:
            throw UsageError.serverError(http.statusCode)
        }
    }

    /// Tries our cached refresh_token first (silent). Falls back to keychain
    /// recovery only if our refresh fails (rare — happens when Claude Code
    /// rotated tokens and invalidated ours).
    private func acquireFreshToken(stale: String) async throws -> String {
        if let token = try? await refreshWithCachedRefreshToken() {
            return token
        }

        // Our refresh failed. Last resort: re-read the keychain.
        guard let recovered = KeychainService.shared.recoverFromKeychain() else {
            throw UsageError.authExpired
        }
        let access = recovered.claudeAiOauth.accessToken
        if access != stale { return access }
        // Keychain returned the same stale token — try refreshing with the
        // recovered refresh_token (might be newer than ours).
        return try await refresh(using: recovered.claudeAiOauth.refreshToken)
    }

    private func refreshWithCachedRefreshToken() async throws -> String {
        let refreshToken = try KeychainService.shared.getRefreshToken()
        return try await refresh(using: refreshToken)
    }

    private func refresh(using refreshToken: String) async throws -> String {
        var req = URLRequest(url: refreshURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId
        ])

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UsageError.authExpired
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?           // seconds until expiry
            let expires_at: Double?        // ms epoch (some servers send this)
        }
        let decoded = try JSONDecoder().decode(RefreshResponse.self, from: data)
        let newRefresh = decoded.refresh_token ?? refreshToken
        let nowMs = Date().timeIntervalSince1970 * 1000
        let expiresAt: Double? = decoded.expires_at
            ?? decoded.expires_in.map { nowMs + Double($0) * 1000 }

        // Preserve fields from the prior credential record so we don't lose
        // subscriptionType / scopes that the keychain item carries.
        let prior = (try? KeychainService.shared.getCredentials())?.claudeAiOauth
        let updated = OAuthCredentials(
            claudeAiOauth: .init(
                accessToken: decoded.access_token,
                refreshToken: newRefresh,
                expiresAt: expiresAt ?? prior?.expiresAt,
                subscriptionType: prior?.subscriptionType,
                scopes: prior?.scopes
            )
        )
        if let encoded = try? JSONEncoder().encode(updated) {
            KeychainService.shared.updateMirror(with: encoded)
        }
        return decoded.access_token
    }
}
