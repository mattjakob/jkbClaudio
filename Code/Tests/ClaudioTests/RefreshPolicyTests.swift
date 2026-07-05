import Testing
import Foundation
@testable import Claudio

@Suite struct AgentClassificationTests {
    @Test func directChildIsSubagent() {
        let result = SessionService.classifyAgents(pids: [100, 200], parentMap: [200: 100, 100: 1])
        #expect(result.primaries == [100])
        #expect(result.owners == [200: 100])
    }

    @Test func nestedChildRollsUpToTopmostPrimary() {
        // 100 (terminal session) -> 200 (subagent) -> 300 (sub-subagent),
        // with a shell in between: 300's parent is 250 (zsh) under 200.
        let parents = [100: 1, 200: 100, 250: 200, 300: 250]
        let result = SessionService.classifyAgents(pids: [100, 200, 300], parentMap: parents)
        #expect(result.primaries == [100])
        #expect(result.owners == [200: 100, 300: 100])
    }

    @Test func independentSessionsStaySeparate() {
        let parents = [100: 1, 200: 2, 300: 200]
        let result = SessionService.classifyAgents(pids: [100, 200, 300], parentMap: parents)
        #expect(result.primaries == [100, 200])
        #expect(result.owners == [300: 200])
    }

    @Test func cycleSafety() {
        let parents = [100: 200, 200: 100]
        let result = SessionService.classifyAgents(pids: [100], parentMap: parents)
        #expect(result.primaries == [100])
    }
}

@Suite struct PrimaryTranscriptPickerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)  // process start

    private func f(_ name: String, mtimeOffset: TimeInterval, birthOffset: TimeInterval)
        -> (file: String, mtime: Date, birth: Date) {
        (name, t0.addingTimeInterval(mtimeOffset), t0.addingTimeInterval(birthOffset))
    }

    @Test func prefersPrimaryOverLaterBornSubagents() {
        // Main session born at start, still writing; two subagents born later.
        let picked = SessionService.pickPrimaryTranscript([
            f("main", mtimeOffset: 4000, birthOffset: 5),
            f("reviewer", mtimeOffset: 3990, birthOffset: 3200),
            f("task-agent", mtimeOffset: 3995, birthOffset: 3600)
        ], processStart: t0)
        #expect(picked?.file == "main")
    }

    @Test func ignoresSessionEndedJustBeforeStart() {
        // Regression: a prior session ended 36 s before this process started
        // (earlier birth) must not steal attribution from the live session.
        let picked = SessionService.pickPrimaryTranscript([
            f("stale", mtimeOffset: -36, birthOffset: -52),
            f("main", mtimeOffset: 4000, birthOffset: 5)
        ], processStart: t0)
        #expect(picked?.file == "main")
    }

    @Test func ignoresStaleFileThatStoppedGrowing() {
        // A file written briefly after start but idle for over 10 min loses
        // to the file still being written, even with an earlier birth.
        let picked = SessionService.pickPrimaryTranscript([
            f("stopped", mtimeOffset: 60, birthOffset: -9000),
            f("main", mtimeOffset: 4000, birthOffset: 5)
        ], processStart: t0)
        #expect(picked?.file == "main")
    }

    @Test func resumedSessionKeepsOldBirth() {
        // claude --resume: old birth, actively written -> still wins.
        let picked = SessionService.pickPrimaryTranscript([
            f("resumed", mtimeOffset: 4000, birthOffset: -86_400),
            f("reviewer", mtimeOffset: 3990, birthOffset: 3200)
        ], processStart: t0)
        #expect(picked?.file == "resumed")
    }

    @Test func noProcessStartFallsBackToNewest() {
        let picked = SessionService.pickPrimaryTranscript([
            f("old", mtimeOffset: -500, birthOffset: -900),
            f("new", mtimeOffset: -10, birthOffset: -300)
        ], processStart: nil)
        #expect(picked?.file == "new")
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
