import XCTest
@testable import AIUsage

final class QuotaDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testIdentifiersReadLegacyAndRoundTripDynamicTitles() throws {
        XCTAssertEqual(try JSONDecoder().decode(QuotaKind.self, from: Data(#""weekly""#.utf8)), .weekly)
        let kind = QuotaKind.additional(id: "test.carbon", title: "Carbon · Weekly")
        XCTAssertEqual(try JSONDecoder().decode(QuotaKind.self, from: JSONEncoder().encode(kind)).title, kind.title)
        XCTAssertEqual(kind, .additional(id: "test.carbon", title: "Renamed"))
        XCTAssertEqual(kind.menuBarMetric.quotaKind, kind)
        let metric = kind.menuBarMetric
        XCTAssertEqual(try JSONDecoder().decode(MenuBarMetricID.self, from: JSONEncoder().encode(metric)).title, kind.title)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(QuotaKind.weekly), as: UTF8.self), #""weekly""#)
    }
    func testClaudeNullQuotaAppearsWhenItHasDataAndNewScopedModelsAreRetained() throws {
        let credentials = ClaudeOAuth(accessToken: "synthetic", subscriptionType: "max")
        let empty = try ClaudeUsageMapper.map(response: httpResponse(json: #"{"seven_day_opus":null}"#), credentials: credentials, now: now)
        XCTAssertTrue(empty.windows.isEmpty)
        let value = try ClaudeUsageMapper.map(response: httpResponse(json: #"{"seven_day_opus":{"utilization":36},"limits":[{"kind":"weekly_scoped","scope":{"model":{"display_name":"Future Model"}},"percent":73}]}"#), credentials: credentials, now: now)
        XCTAssertEqual(value.windows.map(\.usedPercent), [36, 73])
        XCTAssertTrue(value.windows[0].kind.title.contains("Opus"))
        XCTAssertTrue(value.windows[1].kind.title.contains("Future Model"))
    }
    func testCodexRetainsNonSparkAndReviewWithoutInventingAvailabilityPercent() throws {
        let value = try CodexUsageMapper.map(response: httpResponse(json: #"{"additional_rate_limits":[{"metered_feature":"future","limit_name":"Future Model","rate_limit":{"primary_window":{"used_percent":81,"limit_window_seconds":18000}}}],"code_review_rate_limit":{"secondary_window":{"used_percent":100,"limit_window_seconds":604800}},"model_usage":{"future":{"available":false}}}"#), now: now)
        XCTAssertEqual(value.windows.map(\.usedPercent), [81, 100])
        XCTAssertTrue(value.windows[0].kind.title.contains("Future Model"))
        XCTAssertTrue(value.usageDetails.isEmpty)
    }
    func testAntigravityUnknownFamiliesAndZeroAreRetainedNullAndDisabledHidden() throws {
        let data = Data(#"{"groups":[{"displayName":"Gemini Carbon","buckets":[{"bucketId":"carbon-weekly","window":"weekly","remainingFraction":0},{"bucketId":"null","remainingFraction":null},{"bucketId":"disabled","disabled":true,"remainingFraction":0.5}]}]}"#.utf8)
        let value = try XCTUnwrap(AntigravityUsageMapper.summary([data], planName: nil, now: now))
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.windows[0].usedPercent, 100)
        XCTAssertTrue(value.windows[0].kind.title.contains("Carbon"))
        XCTAssertTrue(value.quotaCompatibilityNotes.isEmpty)
    }
    func testUnknownCopilotBucketUsesItsOwnDenominator() throws {
        let value = try CopilotUsageMapper.map(response: httpResponse(json: #"{"quota_snapshots":{"future_agent":{"entitlement":200,"remaining":50},"absent":null,"unlimited":{"unlimited":true}}}"#), now: now)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.windows[0].usedPercent, 75)
        XCTAssertTrue(value.quotaCompatibilityNotes.isEmpty)
    }
    func testMalformedNewQuotaProducesCompatibilityNotice() throws {
        let value = try CopilotUsageMapper.map(response: httpResponse(json: #"{"quota_snapshots":{"chat":{"entitlement":100,"remaining":100},"future":{"format":"changed"}}}"#), now: now)
        XCTAssertEqual(value.windows.count, 1)
        XCTAssertEqual(value.quotaCompatibilityNotes.count, 1)
    }
    func testGeminiNativeUnknownPoolUsesNoInventedCadence() throws {
        // field 3: pool type 9; GXU field 2: fixed32 percentage 0.25.
        let body = Data([0x1a, 0x09, 0x08, 0x09, 0x12, 0x05, 0x15, 0x00, 0x00, 0x80, 0x3e])
        let value = try GeminiNativeUsageMapper.map(response: HTTPResponse(statusCode: 200, headers: [:], body: body), now: now, accountLabel: nil)
        XCTAssertEqual(value.windows.first?.usedPercent, 25)
        XCTAssertEqual(value.windows.first?.kind.title, "Gemini · Quota 9")
    }
    func testManusMonthlyAndKimiRollingQuotaKeepSeparateDenominators() throws {
        let manus = try ConsumerQuotaProvider.manus(httpResponse(json: #"{"maxRefreshCredits":300,"refreshCredits":300,"proMonthlyCredits":10000,"periodicCredits":4000}"#))
        XCTAssertEqual(manus.windows.map(\.usedPercent), [0, 60])
        let kimi = try ConsumerQuotaProvider.kimi(subscription: httpResponse(json: "{}"),
            stats: httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0.2}}"#),
            code: httpResponse(json: #"{"usages":[{"scope":"FEATURE_CODING","detail":{"limit":"2000","remaining":"1000"},"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":200,"remaining":20}}]}]}"#))
        XCTAssertEqual(kimi.windows.map(\.usedPercent), [20, 50, 90])
        XCTAssertTrue(kimi.windows.last!.kind.title.contains("300"))
    }
    @MainActor func testDynamicLimitReachesHistoryAndDashboardWithoutTokenData() throws {
        let history = UsageHistory()
        let kind = QuotaKind.additional(id: "antigravity.carbon", title: "Carbon · Weekly")
        history.record(ProviderSnapshot(provider: .antigravity, planName: nil,
            windows: [QuotaWindow(kind: kind, usedPercent: 100, resetsAt: nil)], fetchedAt: now, accountEmail: "test@example.invalid"))
        XCTAssertEqual(history.limitHits.first?.metric, kind)
        let saved = try JSONDecoder().decode([UsageHistoryPoint].self, from: JSONEncoder().encode(history.points))
        XCTAssertEqual(saved.first?.metric.title, kind.title)
        let projection = DashboardProjection.build(events: [], hits: history.limitHits, providers: [.antigravity], selected: nil, days: 30, now: now, names: [:], accounts: [.antigravity: "selected|test@example.invalid"])
        XCTAssertEqual(projection.hitCount, 1)
        XCTAssertEqual(projection.total.tokens, 0)
        XCTAssertEqual(projection.total.value, 0)
    }
}
