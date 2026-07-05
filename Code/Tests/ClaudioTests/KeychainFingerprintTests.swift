import Testing
import Foundation
@testable import Claudio

@Suite struct KeychainFingerprintTests {
    private func tempCredsFile(token: String) throws -> String {
        let dir = NSTemporaryDirectory() + "claudio-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/.credentials.json"
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r1","expiresAt":9999999999999}}
        """
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func fingerprintChangesWhenFileChanges() throws {
        let path = try tempCredsFile(token: "a1")
        let svc = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        let fp1 = svc.externalFingerprint()
        try """
        {"claudeAiOauth":{"accessToken":"a2","refreshToken":"r2","expiresAt":9999999999999}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let fp2 = svc.externalFingerprint()
        #expect(fp1 != fp2)
        #expect(svc.externalFingerprint() == fp2)
    }

    @Test func fingerprintIncludesKeychainBytes() throws {
        let path = try tempCredsFile(token: "a1")
        let a = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        let b = KeychainService(credentialsFileOverride: path, keychainReader: { Data("kc".utf8) })
        #expect(a.externalFingerprint() != b.externalFingerprint())
    }

    @Test func reloadAdoptsChangedFile() throws {
        let path = try tempCredsFile(token: "a1")
        let svc = KeychainService(credentialsFileOverride: path, keychainReader: { nil })
        _ = try svc.getCredentials()
        try """
        {"claudeAiOauth":{"accessToken":"a2","refreshToken":"r2","expiresAt":9999999999999}}
        """.write(toFile: path, atomically: true, encoding: .utf8)
        let reloaded = svc.reloadFromExternalSources()
        #expect(reloaded?.claudeAiOauth.accessToken == "a2")
        #expect(try svc.getCredentials().claudeAiOauth.accessToken == "a2")
    }
}
