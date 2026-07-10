import Foundation

enum UsageError: Error, LocalizedError {
    case rateLimited
    case serverError(Int)
    case authExpired
    /// Fetch skipped by a gate (backoff/rate-limit window). Not shown as an
    /// error — the UI keeps the previous snapshot.
    case backoff(until: Date?)

    var errorDescription: String? {
        switch self {
        case .rateLimited: nil
        case .serverError(let code): "Usage API returned \(code)"
        case .authExpired: "Session expired — relaunch Claude Code to re-authenticate"
        case .backoff: nil
        }
    }
}

/// Polls the Anthropic OAuth usage endpoint.
///
/// Auth strategy (designed to never prompt the keychain and never rotate
/// Claude Code's refresh token on the normal path):
///  1. Cached credentials still valid -> use them.
///  2. Piggyback: Claude Code refreshed externally -> adopt its token
///     (fingerprint change on credentials file / keychain item).
///  3. Delegate: `claude` CLI PTY probe refreshes for us, keeping refresh
///     token ownership with Claude Code.
///  4. Last resort: direct OAuth refresh with our mirror's refresh token.
/// All refresh attempts run behind persisted RefreshGates (invalid_grant
/// blocks until credentials change; transient failures back off; 429
/// honors Retry-After).
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

    private let gates = RefreshGates()
    private let delegatedRefresh = ClaudeDelegatedRefresh()
    private var userAgent: String?

    func fetchUsage(userInitiated: Bool = false) async throws -> UsageResponse {
        if !userInitiated, let until = gates.rateLimitedUntil() {
            throw UsageError.backoff(until: until)
        }
        let token = try await currentAccessToken(userInitiated: userInitiated)
        return try await request(with: token, hasRefreshed: false, userInitiated: userInitiated)
    }

    /// Returns a non-expired access token per the piggyback -> delegate ->
    /// direct order documented on the actor.
    private func currentAccessToken(userInitiated: Bool) async throws -> String {
        let creds = try KeychainService.shared.getCredentials(allowPrompt: userInitiated)
        guard creds.needsRefresh() else { return creds.claudeAiOauth.accessToken }

        // 1. Piggyback on an external refresh (common case: Claude Code
        //    is in active use and refreshes its own token).
        if let fresh = KeychainService.shared.reloadFromExternalSources(),
           !fresh.needsRefresh() {
            gates.clearFailures()
            return fresh.claudeAiOauth.accessToken
        }

        let fingerprint = KeychainService.shared.externalFingerprint()
        if gates.isAuthBlocked(currentFingerprint: fingerprint) {
            throw UsageError.authExpired
        }
        if !userInitiated, let until = gates.transientBlockedUntil() {
            throw UsageError.backoff(until: until)
        }

        // 2. Delegate the refresh to the claude CLI (keeps ownership of the
        //    refresh token with Claude Code).
        if await delegatedRefresh.attempt(fingerprint: {
            KeychainService.shared.externalFingerprint()
        }) {
            if let fresh = KeychainService.shared.reloadFromExternalSources(),
               !fresh.needsRefresh() {
                gates.clearFailures()
                return fresh.claudeAiOauth.accessToken
            }
        }

        // 3. Last resort: direct refresh against our mirror's refresh token.
        do {
            let token = try await refresh(using: creds.claudeAiOauth.refreshToken)
            gates.clearFailures()
            return token
        } catch UsageError.authExpired {
            gates.recordAuthFailure(fingerprint: fingerprint)
            throw UsageError.authExpired
        } catch {
            gates.recordTransientFailure()
            throw error
        }
    }

    private func request(with token: String, hasRefreshed: Bool,
                         userInitiated: Bool) async throws -> UsageResponse {
        var req = URLRequest(url: apiURL)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(await resolvedUserAgent(), forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }

        switch http.statusCode {
        case 200:
            gates.clearRateLimit()
            return try JSONDecoder().decode(UsageResponse.self, from: data)

        case 401:
            guard !hasRefreshed else { throw UsageError.authExpired }
            let newToken = try await recoverToken(stale: token, userInitiated: userInitiated)
            return try await request(with: newToken, hasRefreshed: true,
                                     userInitiated: userInitiated)

        case 429:
            gates.recordRateLimit(retryAfterHeader:
                http.value(forHTTPHeaderField: "Retry-After"))
            throw UsageError.rateLimited

        default:
            throw UsageError.serverError(http.statusCode)
        }
    }

    /// 401 with a token we thought was valid: external sources first, then
    /// delegation, then direct refresh, then keychain recovery. The keychain
    /// recovery only shows a dialog when `userInitiated` — background polling
    /// stays silent and surfaces `authExpired` instead of nagging.
    private func recoverToken(stale: String, userInitiated: Bool) async throws -> String {
        if let fresh = KeychainService.shared.reloadFromExternalSources(),
           fresh.claudeAiOauth.accessToken != stale {
            return fresh.claudeAiOauth.accessToken
        }
        if await delegatedRefresh.attempt(fingerprint: {
            KeychainService.shared.externalFingerprint()
        }), let fresh = KeychainService.shared.reloadFromExternalSources(),
           fresh.claudeAiOauth.accessToken != stale {
            return fresh.claudeAiOauth.accessToken
        }
        if let token = try? await refreshWithCachedRefreshToken() {
            gates.clearFailures()
            return token
        }
        guard let recovered = KeychainService.shared.recoverFromKeychain(allowPrompt: userInitiated) else {
            throw UsageError.authExpired
        }
        let access = recovered.claudeAiOauth.accessToken
        if access != stale { return access }
        // Keychain returned the same stale token — try refreshing with the
        // recovered refresh_token (might be newer than ours).
        return try await refresh(using: recovered.claudeAiOauth.refreshToken)
    }

    private func resolvedUserAgent() async -> String {
        if let userAgent { return userAgent }
        let version = await ClaudeCLI.detectVersion() ?? "2.1.0"
        let ua = "claude-code/\(version)"
        userAgent = ua
        return ua
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
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.serverError(0)
        }
        guard http.statusCode == 200 else {
            struct OAuthErrorBody: Decodable { let error: String? }
            let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data)
            if body?.error == "invalid_grant" {
                throw UsageError.authExpired
            }
            throw UsageError.serverError(http.statusCode)
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
