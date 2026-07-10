import CryptoKit
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
///   4. Claude Code's keychain item — last resort. Read silently (no dialog)
///      unless the caller explicitly allows a prompt on a user-initiated flow.
///
/// Token refresh is owned by `UsageService`; new tokens get written back here
/// via `updateMirror(with:)` so the keychain stays untouched on the hot path.
/// Nothing here shells out to `/usr/bin/security` — that binary prompts with
/// its own code identity and was the source of recurring password dialogs.
final class KeychainService: Sendable {
    static let shared = KeychainService()

    private static let sourceService = "Claude Code-credentials"

    private let mirrorPath: String
    private let credentialsFilePath: String
    /// Prompt-free keychain byte reader. Injectable for tests; the default
    /// performs a silent (no-UI) SecItemCopyMatching.
    private let keychainReader: @Sendable () -> Data?

    private let cache = ManagedCache()

    init(credentialsFileOverride: String? = nil,
         keychainReader: (@Sendable () -> Data?)? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.credentialsFilePath = credentialsFileOverride ?? "\(home)/.claude/.credentials.json"
        self.mirrorPath = (credentialsFileOverride.map { $0 + ".mirror" })
            ?? "\(home)/.claude/widget-credentials.json"
        self.keychainReader = keychainReader ?? Self.silentKeychainBytes
    }

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
    /// file without ever prompting. The keychain is the last resort: it is
    /// read silently (no dialog) unless `allowPrompt` is set, which callers do
    /// only on user-initiated flows so background polling never shows UI.
    func getCredentials(allowPrompt: Bool = false) throws -> OAuthCredentials {
        if let cached = cache.get() { return cached }
        if let creds = readJSONFile(at: mirrorPath) {
            cache.set(creds); return creds
        }
        if let creds = readJSONFile(at: credentialsFilePath) {
            cache.set(creds)
            // Persist to our mirror so subsequent reads stay consistent.
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            return creds
        }
        if allowPrompt { return try readKeychainPrompting() }
        return try readKeychainSilent()
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

    /// LAST resort recovery: re-read from Claude Code's credentials file, then
    /// the keychain. The keychain is read silently unless `allowPrompt` is set.
    /// A prompt is only ever needed when Claude Code recreated its keychain
    /// item (full re-login), which resets the ACL and defeats the silent read;
    /// callers pass `allowPrompt` on user-initiated flows only, so this never
    /// pops a dialog from background polling.
    func recoverFromKeychain(allowPrompt: Bool = false) -> OAuthCredentials? {
        cache.clear()
        // Try the credentials file once more in case Claude Code re-authed.
        if let creds = readJSONFile(at: credentialsFilePath) {
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            cache.set(creds)
            return creds
        }
        if let creds = try? readKeychainSilent() { return creds }
        if allowPrompt, let creds = try? readKeychainPrompting() { return creds }
        return nil
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
        guard let data = Self.silentKeychainBytes() else { throw KeychainError.itemNotFound }
        return try decodeAndCache(data)
    }

    /// Prompt-free raw read of Claude Code's keychain item. Returns nil on
    /// any failure (including ACL-denied) without ever showing UI.
    private static func silentKeychainBytes() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sourceService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    // MARK: - External change detection

    /// SHA-256 over the raw bytes of Claude Code's credentials file and its
    /// keychain item (silent read only — never prompts). Changes whenever
    /// Claude Code refreshes or the user re-authenticates.
    func externalFingerprint() -> String {
        var hasher = SHA256()
        hasher.update(data: FileManager.default.contents(atPath: credentialsFilePath) ?? Data())
        hasher.update(data: Data([0]))
        hasher.update(data: keychainReader() ?? Data())
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Re-reads Claude Code's own sources (credentials file, then silent
    /// keychain) and adopts the result into cache + mirror. Never prompts.
    /// Returns nil when neither source is readable.
    @discardableResult
    func reloadFromExternalSources() -> OAuthCredentials? {
        if let creds = readJSONFile(at: credentialsFilePath) {
            if let data = try? JSONEncoder().encode(creds) { saveMirror(data) }
            cache.set(creds)
            return creds
        }
        if let data = keychainReader(),
           let creds = try? JSONDecoder().decode(OAuthCredentials.self, from: data) {
            saveMirror(data)
            cache.set(creds)
            return creds
        }
        return nil
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
        // Create the temp with 0600 from the outset, then atomically rename it
        // into place. `Data.write(.atomic)` would rename a temp created with
        // umask-default perms over the destination, briefly exposing the token
        // file as world/group-readable; rename(2) of a 0600 inode has no such
        // window and is atomic on the same filesystem.
        let fm = FileManager.default
        let tmpPath = mirrorPath + ".tmp"
        fm.createFile(atPath: tmpPath, contents: data,
                      attributes: [.posixPermissions: 0o600])
        if rename(tmpPath, mirrorPath) != 0 {
            try? data.write(to: URL(fileURLWithPath: mirrorPath), options: [])
            chmod(mirrorPath, 0o600)
            try? fm.removeItem(atPath: tmpPath)
        }
    }
}
