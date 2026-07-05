import Testing
import Foundation
@testable import Claudio

@Suite struct AgentClassificationTests {
    @Test func directChildIsSubagent() {
        let result = SessionService.classifyAgents(pids: [100, 200], parentMap: [200: 100, 100: 1])
        #expect(result.primaries == [100])
        #expect(result.childCounts == [100: 1])
    }

    @Test func nestedChildRollsUpToTopmostPrimary() {
        // 100 (terminal session) -> 200 (subagent) -> 300 (sub-subagent),
        // with a shell in between: 300's parent is 250 (zsh) under 200.
        let parents = [100: 1, 200: 100, 250: 200, 300: 250]
        let result = SessionService.classifyAgents(pids: [100, 200, 300], parentMap: parents)
        #expect(result.primaries == [100])
        #expect(result.childCounts == [100: 2])
    }

    @Test func independentSessionsStaySeparate() {
        let parents = [100: 1, 200: 2, 300: 200]
        let result = SessionService.classifyAgents(pids: [100, 200, 300], parentMap: parents)
        #expect(result.primaries == [100, 200])
        #expect(result.childCounts == [200: 1])
    }

    @Test func cycleSafety() {
        let parents = [100: 200, 200: 100]
        let result = SessionService.classifyAgents(pids: [100], parentMap: parents)
        #expect(result.primaries == [100])
    }
}

@Suite struct RefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func activeSessionsPollFast() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func recentPopoverPollsFast() {
        let opened = now.addingTimeInterval(-200)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 120)
    }

    @Test func idlePollsSlow() {
        let opened = now.addingTimeInterval(-3600)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: opened,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
        #expect(RefreshPolicy.interval(hasActiveSessions: false, lastPopoverOpen: nil,
                                       lowPowerMode: false, thermalState: .nominal, now: now) == 900)
    }

    @Test func lowPowerAndThermalOverride() {
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: true, thermalState: .nominal, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .critical, now: now) == 1800)
        #expect(RefreshPolicy.interval(hasActiveSessions: true, lastPopoverOpen: now,
                                       lowPowerMode: false, thermalState: .serious, now: now) == 1800)
    }
}
