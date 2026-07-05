import Testing
import Foundation
@testable import Claudio

@Suite struct TokenLineParserTests {
    private let assistantLine = """
    {"type":"assistant","timestamp":"2026-07-05T10:00:00.000Z","requestId":"req_1",\
    "message":{"id":"msg_1","model":"claude-sonnet-5","usage":{"input_tokens":10,\
    "output_tokens":20,"cache_creation_input_tokens":30,"cache_read_input_tokens":40}}}
    """

    @Test func quickFilterMatchesOnlyAssistantUsageLines() {
        #expect(TokenLineParser.quickFilter(Data(assistantLine.utf8)))
        #expect(!TokenLineParser.quickFilter(Data(#"{"type":"user","message":{}}"#.utf8)))
        #expect(!TokenLineParser.quickFilter(Data(#"{"type":"assistant","message":{"id":"m"}}"#.utf8)))
    }

    @Test func parsesUsageFields() {
        let parsed = TokenLineParser.parse(Data(assistantLine.utf8), calendar: .current)
        #expect(parsed != nil)
        #expect(parsed?.model == "claude-sonnet-5")
        #expect(parsed?.dedupKey == "msg_1|req_1")
        #expect(parsed?.counts == TokenCounts(input: 10, output: 20, cacheCreate: 30, cacheRead: 40))
    }

    @Test func missingUsageOrModelReturnsNil() {
        let noUsage = #"{"type":"assistant","timestamp":"2026-07-05T10:00:00Z","message":{"id":"m","model":"x"}}"#
        #expect(TokenLineParser.parse(Data(noUsage.utf8), calendar: .current) == nil)
    }

    @Test func dedupKeyFallsBackWhenIdsMissing() {
        let line = """
        {"type":"assistant","timestamp":"2026-07-05T10:00:00Z",\
        "message":{"model":"m1","usage":{"input_tokens":1,"output_tokens":2}}}
        """
        let parsed = TokenLineParser.parse(Data(line.utf8), calendar: .current)
        #expect(parsed != nil)
        #expect(parsed!.dedupKey.hasPrefix("line|"))
    }

    @Test func countsAddAndTotal() {
        var a = TokenCounts(input: 1, output: 2, cacheCreate: 3, cacheRead: 4)
        a.add(TokenCounts(input: 10, output: 20, cacheCreate: 30, cacheRead: 40))
        #expect(a.total == 110)
    }

    @Test func compactFormatting() {
        #expect(compactTokens(950) == "950")
        #expect(compactTokens(12_400) == "12.4K")
        #expect(compactTokens(1_200_000) == "1.2M")
    }
}
