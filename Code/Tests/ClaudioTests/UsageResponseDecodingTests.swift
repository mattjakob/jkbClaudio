import Testing
import Foundation
@testable import Claudio

@Suite struct UsageResponseDecodingTests {
    @Test func decodesFlatWindowsAndSonnet() throws {
        let json = """
        {"five_hour":{"utilization":42.5,"resets_at":"2026-07-05T15:00:00.000Z"},
         "seven_day":{"utilization":80,"resets_at":null},
         "seven_day_sonnet":{"utilization":12,"resets_at":null},
         "unknown_future_key":{"foo":1}}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.fiveHour?.utilization == 42.5)
        #expect(response.sevenDaySonnet?.utilization == 12)
    }

    @Test func decodesLimitsArray() throws {
        let json = """
        {"limits":[{"kind":"weekly_scoped","percent":33.3,
          "resets_at":"2026-07-08T00:00:00Z","is_active":false,
          "scope":{"model":{"id":"claude-fable-5","display_name":"Fable"}}},
         {"kind":"mystery","percent":null}]}
        """
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        #expect(response.limits?.count == 2)
        let scoped = response.scopedWindows()
        #expect(scoped.count == 1)
        #expect(scoped[0].name == "Fable")
        #expect(scoped[0].utilization == 33.3)
        #expect(scoped[0].resetsAt != nil)
    }

    @Test func limitsAbsentIsNil() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8))
        #expect(response.limits == nil)
        #expect(response.scopedWindows().isEmpty)
    }
}
