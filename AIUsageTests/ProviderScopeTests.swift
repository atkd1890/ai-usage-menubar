import XCTest
@testable import AIUsage

final class ProviderScopeTests: XCTestCase {
    private func response(_ object: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
    func testVerifiedCopilotScopedCreditsAreNotSummedOrCalledDollars() throws {
        let result = try CopilotUsageMapper.map(response: response([
            "copilot_plan": "individual", "token_based_billing": true,
            "quota_snapshots": [
                "chat": ["credits_used": 0, "has_quota": true, "percent_remaining": 100, "entitlement": 200],
                "completions": ["credits_used": 138, "has_quota": true, "percent_remaining": 93.1, "entitlement": 2000],
                "premium_interactions": ["credits_used": 0, "has_quota": false, "entitlement": 0]
            ]
        ]), now: Date())
        XCTAssertEqual(result.windows.map(\.kind), [.chat, .completions])
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertFalse(result.availableMenuBarItems.contains { $0.metric == .extraUsage })
        XCTAssertNil(result.billingUsage)
        XCTAssertTrue(result.hasPanelContent)
    }
    func testCreditBilledSeatDoesNotDisplayRawCreditCounts() throws {
        let result = try CopilotUsageMapper.map(response: response([
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["credits_used": 42, "unlimited": true]]
        ]), now: Date())
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertFalse(result.hasPanelContent)
    }
    func testInvalidAndAbsentCreditsAreNotFabricated() {
        let details = CopilotUsageMapper.creditDetails([
            "token_based_billing": true,
            "quota_snapshots": [
                "chat": ["credits_used": -1],
                "completions": ["credits_used": Double.infinity],
                "premium_interactions": ["credits_used": 50, "has_quota": false]
            ]
        ])
        XCTAssertTrue(details.isEmpty)
        XCTAssertTrue(CopilotUsageMapper.creditDetails([:]).isEmpty)
    }
    func testApplicableResetsAreSeparateFromBankedCount() throws {
        let result = try CodexUsageMapper.map(response: response([
            "plan_type": "plus", "rate_limit_reset_credits": ["available_count": 1, "applicable_available_count": 0]
        ]), now: Date())
        XCTAssertEqual(result.resets?.availableCount, 1)
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertEqual(result.resets?.usableCount, 0)
        XCTAssertEqual(result.usageScope, "Shared allowance · Codex & ChatGPT Work")
        XCTAssertEqual(result.displayName, "Codex")
    }
    func testProviderLabelsDescribeActualQuotaWithoutChangingPersistedIDs() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.claude.rawValue, "claude")
        XCTAssertEqual(QuotaKind.claudePool.title, "3rd-party")
        XCTAssertEqual(QuotaKind.claudePool.rawValue, "claudePool")
        XCTAssertEqual(QuotaKind.claudePoolWeekly.title, "3rd-party Weekly")
        let gemini = ProviderSnapshot(provider: .gemini, planName: nil, windows: [], fetchedAt: Date())
        XCTAssertEqual(gemini.usageScope, "Gemini app quota · separate from Antigravity")
    }
}
