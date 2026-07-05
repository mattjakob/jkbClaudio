import Testing
import Foundation
@testable import Claudio

@Suite struct TokenScannerTests {
    private func makeRoot() throws -> String {
        let dir = NSTemporaryDirectory() + "claudio-scan-\(UUID().uuidString)/projects/proj-a"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func line(id: String, req: String, model: String = "claude-sonnet-5",
                      input: Int, output: Int, timestamp: String? = nil) -> String {
        let ts = timestamp ?? ISO8601DateFormatter.standard.string(from: Date())
        return """
        {"type":"assistant","timestamp":"\(ts)","requestId":"\(req)","message":\
        {"id":"\(id)","model":"\(model)","usage":{"input_tokens":\(input),"output_tokens":\(output)}}}
        """
    }

    @Test func aggregatesTodayByModel() async throws {
        let root = try makeRoot()
        let content = [
            line(id: "m1", req: "r1", input: 10, output: 5),
            #"{"type":"user","message":{"content":"hi"}}"#,
            line(id: "m2", req: "r2", model: "claude-opus-4-8", input: 100, output: 50)
        ].joined(separator: "\n") + "\n"
        try content.write(toFile: root + "/s1.jsonl", atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.today["claude-sonnet-5"] == TokenCounts(input: 10, output: 5))
        #expect(snap.today["claude-opus-4-8"] == TokenCounts(input: 100, output: 50))
        #expect(snap.todayTotal.total == 165)
    }

    @Test func streamingChunksDedupLastWins() async throws {
        let root = try makeRoot()
        let content = [
            line(id: "m1", req: "r1", input: 10, output: 1),
            line(id: "m1", req: "r1", input: 10, output: 25)
        ].joined(separator: "\n") + "\n"
        try content.write(toFile: root + "/s1.jsonl", atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 10, output: 25))
    }

    @Test func incrementalTailParseOnly() async throws {
        let root = try makeRoot()
        let path = root + "/s1.jsonl"
        try (line(id: "m1", req: "r1", input: 10, output: 5) + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        _ = await scanner.snapshot()

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data((line(id: "m2", req: "r2", input: 7, output: 3) + "\n").utf8))
        try handle.close()

        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 17, output: 8))
    }

    @Test func partialTrailingLineIsNotConsumed() async throws {
        let root = try makeRoot()
        let path = root + "/s1.jsonl"
        let full = line(id: "m1", req: "r1", input: 10, output: 5) + "\n"
        let partial = String(line(id: "m2", req: "r2", input: 99, output: 99).prefix(40))
        try (full + partial).write(toFile: path, atomically: true, encoding: .utf8)

        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        var snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 10, output: 5))

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        let rest = String(line(id: "m2", req: "r2", input: 99, output: 99).dropFirst(40)) + "\n"
        handle.write(Data(rest.utf8))
        try handle.close()

        snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts(input: 109, output: 104))
    }

    @Test func oldDaysExcludedFromToday() async throws {
        let root = try makeRoot()
        let content = line(id: "m1", req: "r1", input: 500, output: 500,
                           timestamp: "2020-01-01T00:00:00Z") + "\n"
        try content.write(toFile: root + "/old.jsonl", atomically: true, encoding: .utf8)
        let scanner = TokenScanner(roots: [String(root.dropLast("/proj-a".count))],
                                   cachePath: root + "/cache.json")
        let snap = await scanner.snapshot()
        #expect(snap.todayTotal == TokenCounts())
    }
}
