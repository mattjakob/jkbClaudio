import Testing
import Foundation
@testable import Claudio

@Suite struct ClaudeCLITests {
    @Test func parsesVersionFromCLIOutput() {
        #expect(ClaudeCLI.parseVersion(from: "2.1.34 (Claude Code)") == "2.1.34")
        #expect(ClaudeCLI.parseVersion(from: "claude 3.0.1\n") == "3.0.1")
        #expect(ClaudeCLI.parseVersion(from: "no digits here") == nil)
    }

    @Test func pollDetectsFingerprintChange() async {
        let box = FingerprintBox(values: ["a", "a", "b"])
        let changed = await ClaudeDelegatedRefresh.pollForChange(
            initial: "a", fingerprint: { box.next() },
            delays: [0.01, 0.01, 0.01])
        #expect(changed)
    }

    @Test func pollTimesOutWithoutChange() async {
        let changed = await ClaudeDelegatedRefresh.pollForChange(
            initial: "a", fingerprint: { "a" }, delays: [0.01, 0.01])
        #expect(!changed)
    }
}

final class FingerprintBox: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()
    init(values: [String]) { self.values = values }
    func next() -> String {
        lock.lock(); defer { lock.unlock() }
        return values.count > 1 ? values.removeFirst() : values[0]
    }
}
