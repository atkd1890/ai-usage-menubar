import XCTest
@testable import AIUsage

final class XSubscriptionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")!
    private func response(_ object: [String: Any], status: Int = 200) throws -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
    private var legacy: ProviderSnapshot {
        ProviderSnapshot(provider: .cursor, planName: "Plus", windows: [
            QuotaWindow(kind: .totalUsage, usedPercent: 33.94230769,
                        resetsAt: now.addingTimeInterval(86400))],
            billingUsage: .boundedSpend(usedAmount: 0, limitAmount: 50, currencyCode: "USD"), fetchedAt: now)
    }
    private var dashboard: [String: Any] { [
        "availability": "available",
        "weeklyIncludedUsage": ["usedCents": 353, "budgetCents": 1040, "resetCounter": 3,
            "periodStart": "2026-11-07T18:44:53.254Z", "resetsAt": "2026-11-14T18:44:53.254Z"],
        "weeklyIncludedUsageByProduct": [["product": "grok-tasks", "cents": 324], ["product": "grok-chat", "cents": 29]],
        "monthlyUsage": ["usedCents": 258, "limitCents": 5000, "creditsUsedCents": 700,
            "additionalUsageOff": false, "periodStart": "2026-11-01T00:00:00Z", "resetsAt": "2026-12-01T00:00:00Z"]
    ] }
    func testVerifiedUnifiedResponseSeparatesSharedPoolSpendAndBalance() throws {
        let result = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: response(dashboard),
            shared: response(["isUnified": true, "prepaidAvailableCents": "504"]), isMerged: true, now: now)
        XCTAssertEqual(result.displayName, "X Subscription")
        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.windows[0].kind, .weekly)
        XCTAssertEqual(result.windows[0].usedPercent, 353.0 / 1040 * 100, accuracy: 0.0001)
        XCTAssertEqual(result.billingUsage, .boundedSpend(usedAmount: 2.58, limitAmount: 50, currencyCode: "USD"))
        XCTAssertEqual(result.xSubscription?.prepaidDollars, 5.04)
        XCTAssertEqual(result.xSubscription?.products.map(\.product), ["grok-tasks", "grok-chat"])
        XCTAssertNil(result.resets) // resetCounter is not available reset inventory.
        XCTAssertEqual(result.window(for: .totalUsage), result.windows.first)
        XCTAssertEqual(result.window(for: .autoUsage), result.windows.first)
    }
    func testUnavailableBillingNeverFallsBackToFalseLegacyZero() throws {
        let result = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: response([:], status: 503),
            shared: nil, isMerged: true, now: now)
        XCTAssertNil(result.billingUsage)
        XCTAssertEqual(result.xSubscription?.additionalUsageUnavailable, true)
        XCTAssertEqual(result.windows[0].kind, .weekly)
    }
    func testLegacyRemainsCursor() throws {
        let result = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: response(dashboard),
            shared: response(["isUnified": false]), isMerged: false, now: now)
        XCTAssertEqual(result, legacy)
    }
    func testExpiredMonthlyPeriodAndIncompleteBreakdownAreNotDisplayed() throws {
        var data = dashboard
        data["weeklyIncludedUsageByProduct"] = [["product": "grok-chat", "cents": 29]]
        data["monthlyUsage"] = ["usedCents": 0, "limitCents": 5000,
            "periodStart": "2026-10-01T00:00:00Z", "resetsAt": "2026-11-01T00:00:00Z"]
        let result = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: response(data), shared: nil,
                                                      isMerged: true, now: now)
        XCTAssertNil(result.billingUsage)
        XCTAssertEqual(result.xSubscription?.products, [])
        XCTAssertNil(result.xSubscription?.prepaidDollars)
    }
    func testSandCanIdentifyUnifiedAndSupplyWeeklyFallback() throws {
        let result = try CursorUnifiedUsageMapper.map(legacy: legacy, dashboard: nil,
            shared: response(["isUnified": true, "usagePercent": 42, "nextResetTimestampUtc": "2026-11-14T18:44:53Z"]),
            isMerged: false, now: now)
        XCTAssertEqual(result.windows[0].usedPercent, 42)
        XCTAssertNotNil(result.xSubscription)
    }
    func testDashboardRequestUsesNativeIdentityOnlyAtAllowedEndpoint() async throws {
        let clientHTTP = MockHTTPClient([try response([:])])
        let client = CursorUsageClient(http: clientHTTP)
        let payload = Data(#"{"sub":"auth0|synthetic_user"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "header." + payload + ".signature"
        _ = try await client.fetchDashboard(accessToken: token, path: "/api/dashboard/v2/usage-status?scope=user")
        let requests = await clientHTTP.capturedRequests()
        XCTAssertEqual(requests.first?.url.host, "cursor.com")
        XCTAssertEqual(requests.first?.headers["Cookie"], "WorkosCursorSessionToken=synthetic_user%3A%3A" + token)
        do {
            _ = try await client.fetchDashboard(accessToken: token, path: "/unapproved")
            XCTFail("Unexpected endpoint accepted")
        } catch {}
        let count = await clientHTTP.capturedRequests().count
        XCTAssertEqual(count, 1)
    }
}
