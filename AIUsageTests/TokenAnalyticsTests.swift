import XCTest
@testable import AIUsage

final class TokenAnalyticsTests: XCTestCase {
    private func read(_ lines: [String], provider: ProviderID) throws -> [TokenUsageEvent] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return TokenLogImporter.read(url, provider: provider).events.sorted { $0.date < $1.date }
    }
    func testCodexUsesCumulativeDeltasAndDoesNotAddCacheOrReasoningTwice() throws {
        let model = #"{"type":"turn_context","payload":{"model":"gpt-6.1-sol"}}"#
        let first = #"{"type":"event_msg","timestamp":"2026-11-12T12:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":110}}}}"#
        let duplicate = first.replacingOccurrences(of: "12:00:00", with: "12:01:00")
        let second = #"{"type":"event_msg","timestamp":"2026-11-12T12:02:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"cached_input_tokens":200,"output_tokens":40,"reasoning_output_tokens":20,"total_tokens":340}}}}"#
        let result = try read([model, first, duplicate, second], provider: .codex)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.reduce(0) { $0 + $1.tokens }, 340)
        XCTAssertEqual(result[1].cached, 120)
        XCTAssertEqual(result[1].output, 30)
        XCTAssertEqual(result[0].apiValue!, (20 * 2 + 80 * 0.1 + 10 * 10) / 1e6, accuracy: 1e-12)
    }
    func testClaudeDeduplicatesStreamingMessageAndPricesHourCacheWrites() throws {
        let first = #"{"type":"assistant","timestamp":"2026-11-12T12:00:00Z","message":{"id":"msg1","model":"claude-opus-5-5","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":100,"cache_creation_input_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":20}}}}"#
        let final = first.replacingOccurrences(of: "\"output_tokens\":2", with: "\"output_tokens\":20")
        let result = try read([first, final, final], provider: .claude)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].tokens, 180)
        XCTAssertEqual(result[0].apiValue!, (10 * 4 + 100 * 0.2 + 20 * 20 + 30 * 5 + 20 * 8) / 1e6, accuracy: 1e-12)
    }
    func testUnknownModelHasNoFabricatedPrice() {
        let event = TokenUsageEvent(id: "x", provider: .codex, date: Date(), model: "codex-auto-review", input: 100, cached: 0, output: 10, cacheWrite: 0, cacheWriteHour: 0, fast: false)
        XCTAssertNil(event.apiValue)
        XCTAssertEqual(event.tokens, 110)
    }
    func testCalendarAlwaysHas53MondayAlignedWeeksIncludingEmptyDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
        let weeks = UsageCalendar.weeks(ending: date, calendar: calendar)
        XCTAssertEqual(weeks.count, 53)
        XCTAssertTrue(weeks.allSatisfy { $0.count == 7 && calendar.component(.weekday, from: $0[0]) == 2 })
        XCTAssertEqual(Set(weeks.flatMap { $0 }).count, 371)
        XCTAssertTrue(weeks.last!.contains(calendar.startOfDay(for: date)))
    }
    func testImportRetainsMetadataAfterLogsAreRemovedAndDeduplicatesFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = "{\"type\":\"assistant\",\"timestamp\":\"\(Date().ISO8601Format())\",\"message\":{\"id\":\"same\",\"model\":\"claude-opus-5-5\",\"usage\":{\"input_tokens\":10,\"output_tokens\":2}}}\n"
        try record.write(to: directory.appendingPathComponent("one.jsonl"), atomically: true, encoding: .utf8)
        try record.write(to: directory.appendingPathComponent("copy.jsonl"), atomically: true, encoding: .utf8)
        let importer = TokenLogImporter()
        let first = await importer.load(home: home)
        XCTAssertEqual(first.events.count, 1)
        try FileManager.default.removeItem(at: directory)
        let later = await importer.load(home: home)
        XCTAssertEqual(later.events.count, 1)
        XCTAssertEqual(later.events.first?.tokens, 12)
    }
}
