import XCTest
@testable import AIUsage

final class ClaudeBreakdownTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
    private func body(_ rows: [[String: Any]]) -> [String: Any] { [
        "seven_day": ["utilization": 34, "resets_at": "2026-11-18T02:59:59Z"],
        "seven_day_breakdown": ["as_of": "2026-11-11T16:35:31Z", "window_started_at": "2026-11-11T02:59:59Z", "rows": rows]
    ] }
    private var rows: [[String: Any]] { [
        ["key": "claude_code", "display_name": "Claude Code", "percent": 0],
        ["key": "chat", "display_name": "Chats", "percent": 0],
        ["key": "cowork", "display_name": "Cowork", "percent": 100],
        ["key": "other", "display_name": "Other", "percent": 0]
    ] }
    func testActualClaudeSchemaMapsSurfaceSharesWithoutCreatingQuotaWindows() throws {
        let response = HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body(rows)))
        let value = try ClaudeUsageMapper.map(response: response, credentials: ClaudeOAuth(), now: now)
        XCTAssertEqual(value.windows.map(\.kind), [.weekly])
        XCTAssertEqual(value.consumptionShares.map(\.id), ["claude_code", "chat", "cowork", "other"])
        XCTAssertEqual(value.consumptionShares.map(\.percent), [0, 0, 100, 0])
        XCTAssertEqual(value.consumptionShares.first?.title, "Code")
        XCTAssertFalse(value.availableMenuBarItems.contains { $0.metric == .chat })
    }
    func testPartialDuplicateAndInvalidBreakdownsAreNotInvented() {
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body([["key": "chat", "display_name": "Chats", "percent": 30]]), now: now))
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body(rows + [rows[0]]), now: now))
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body([["key": "chat", "display_name": "Chats", "percent": -1]]), now: now))
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown([:], now: now))
    }
    func testExpiredAndFutureDatedBreakdownsAreHidden() {
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body(rows), now: now.addingTimeInterval(14 * 86400)))
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body(rows), now: now.addingTimeInterval(-7 * 86400)))
    }
    func testPreviousPeriodBreakdownIsNotAttachedToNewWeeklyQuota() {
        var next = body(rows)
        next["seven_day"] = ["utilization": 5, "resets_at": "2026-11-25T02:59:59Z"]
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(next, now: now.addingTimeInterval(7 * 86400)))
    }

    func testZeroSharesRequireConfirmedZeroWeeklyUse() {
        let empty = [["key": "chat", "display_name": "Chats", "percent": 0]] as [[String: Any]]
        XCTAssertNil(ClaudeUsageMapper.consumptionBreakdown(body(empty), now: now))
        var zero = body(empty)
        zero["seven_day"] = ["utilization": 0, "resets_at": "2026-11-18T02:59:59Z"]
        XCTAssertEqual(ClaudeUsageMapper.consumptionBreakdown(zero, now: now)?.shares.first?.percent, 0)
    }
}
