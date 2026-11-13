import XCTest
@testable import AIUsage

@MainActor final class DashboardProjectionTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
    private func event(_ id: String, provider: ProviderID, model: String, date: Date) -> TokenUsageEvent {
        TokenUsageEvent(id: id, provider: provider, date: date, model: model, input: 100, cached: 0, output: 10, cacheWrite: 0, cacheWriteHour: 0, fast: false)
    }
    func testProjectionKeepsSidebarTotalsWhileFilteringSelectedProvider() {
        let events = [event("a", provider: .codex, model: "gpt-6.1-sol", date: now), event("b", provider: .claude, model: "claude-opus-5-5", date: now)]
        let data = DashboardProjection.build(events: events, hits: [], providers: [.codex, .claude], selected: .codex, days: 30, now: now,
                                             names: [.codex: "Codex", .claude: "Claude"], accounts: [:])
        XCTAssertEqual(data.total.tokens, 110)
        XCTAssertEqual(data.sidebarProviders[.claude]?.tokens, 110)
        XCTAssertEqual(data.series, ["gpt-6.1-sol"])
        XCTAssertEqual(data.days.values.first?.amount.tokens, 110)
    }
    func testLimitRowsGroupByProviderMetricAndDayWithoutDuplicatingAccounts() {
        let hits = (0..<3).map { UsageLimitHit(id: "\($0)", provider: .codex, account: "one", date: now.addingTimeInterval(Double($0 * 60)), metric: .session, reset: nil) }
            + [UsageLimitHit(id: "other", provider: .codex, account: "two", date: now, metric: .session, reset: nil)]
        let data = DashboardProjection.build(events: [], hits: hits, providers: [.codex], selected: nil, days: 30, now: now,
                                             names: [.codex: "Codex"], accounts: [.codex: "one"])
        XCTAssertEqual(data.hitCount, 3)
        XCTAssertEqual(data.limits.count, 1)
        XCTAssertEqual(data.limits.first?.count, 3)
        XCTAssertEqual(data.hitsByDay.values.first, 3)
    }
    func testSwitchingBackReusesCachedViewAndDataChangeInvalidatesIt() async {
        let events = [event("a", provider: .codex, model: "gpt-6.1-sol", date: now)]
        let model = DashboardProjectionModel()
        for key in ["overview", "codex", "overview"] {
            await model.rebuild(key: key, generation: "revision1", events: events, hits: [], providers: [.codex], selected: key == "codex" ? .codex : nil,
                                days: 30, now: now, names: [.codex: "Codex"], accounts: [:])
        }
        XCTAssertEqual(model.buildCount, 2)
        await model.rebuild(key: "overview", generation: "revision2", events: events, hits: [], providers: [.codex], selected: nil,
                            days: 30, now: now, names: [.codex: "Codex"], accounts: [:])
        XCTAssertEqual(model.buildCount, 3)
    }
    func testCancelledViewStillCachesCompletedAggregation() async {
        let model = DashboardProjectionModel()
        let task = Task { await model.rebuild(key: "overview", events: [], hits: [], providers: [], selected: nil,
                                               days: 30, now: now, names: [:], accounts: [:]) }
        await Task.yield()
        task.cancel()
        await task.value
        let count = model.buildCount
        await model.rebuild(key: "overview", events: [], hits: [], providers: [], selected: nil,
                            days: 30, now: now, names: [:], accounts: [:])
        XCTAssertEqual(model.buildCount, count)
    }
    func testViewReopeningUsesImportCooldownButRefreshCanForceReload() async {
        let importer = CountingTokenImporter()
        let analytics = TokenAnalytics(importer: importer)
        await analytics.refresh()
        await analytics.refresh()
        var count = await importer.calls
        XCTAssertEqual(count, 1)
        await analytics.refresh(force: true)
        count = await importer.calls
        XCTAssertEqual(count, 2)
    }
    func testKnownPlanPricesAreExplicitEstimatesAndAmbiguousTiersStayUnknown() {
        XCTAssertEqual(DashboardPlanPrice.listed(provider: .codex, plan: "Plus")?.monthlyUSD, 20)
        XCTAssertEqual(DashboardPlanPrice.listed(provider: .claude, plan: "Max")?.monthlyUSD, 100)
        XCTAssertTrue(DashboardPlanPrice.listed(provider: .claude, plan: "Max")!.isListPrice)
        XCTAssertNil(DashboardPlanPrice.listed(provider: .codex, plan: "Pro"))
        XCTAssertNil(DashboardPlanPrice.listed(provider: .cursor, plan: "Plus"))
        XCTAssertNil(DashboardPlanPrice.listed(provider: .copilot, plan: "Individual"))
        XCTAssertEqual(DashboardProjection.planMultiple(value: 60, monthlyPrice: 20, days: 30)!, 3.04375, accuracy: 1e-8)
        XCTAssertNil(DashboardProjection.planMultiple(value: 60, monthlyPrice: 0, days: 30))
    }
    func testEveryDashboardNoteIsUnder100Characters() {
        for note in DashboardCopy.allNotes { XCTAssertLessThan(note.count, 100, note) }
    }
    func testHitsSurviveSameHourResetAndRepeatedFullSnapshotsDoNotInflateCount() {
        let history = UsageHistory()
        for (offset, percent) in [90.0, 100, 100, 30, 100, 100].enumerated() {
            history.record(ProviderSnapshot(provider: .codex, planName: "Plus",
                windows: [.init(kind: .session, usedPercent: percent, resetsAt: nil)], fetchedAt: now.addingTimeInterval(Double(offset * 60)),
                credentialSource: "Local OAuth", accountEmail: "one@example.com"))
        }
        XCTAssertEqual(history.limitHits.count, 2)
        XCTAssertEqual(history.points.count, 1)
    }
}

private actor CountingTokenImporter: TokenUsageImporting {
    var calls = 0
    func load(home: URL) async -> TokenImportResult { calls += 1; return TokenImportResult(events: [], skipped: 0) }
}
