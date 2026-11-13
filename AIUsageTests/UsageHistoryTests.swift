import XCTest
@testable import AIUsage

@MainActor final class UsageHistoryTests: XCTestCase {
    private func snapshot(_ date: Date, percent: Double, email: String?) -> ProviderSnapshot {
        ProviderSnapshot(provider: .codex, planName: "Plus", windows: [.init(kind: .weekly, usedPercent: percent, resetsAt: nil)],
                         fetchedAt: date, credentialSource: "Local OAuth", accountEmail: email)
    }
    func testHourlySamplesReplaceOnlyMatchingAccountAndMetric() {
        let history = UsageHistory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        history.record(snapshot(date, percent: 20, email: "one@example.com"))
        history.record(snapshot(date.addingTimeInterval(60), percent: 25, email: "one@example.com"))
        XCTAssertEqual(history.points.count, 1)
        XCTAssertEqual(history.points.first?.usedPercent, 25)
        history.record(snapshot(date, percent: 40, email: "two@example.com"))
        XCTAssertEqual(history.points.count, 2)
        history.record(snapshot(date, percent: 60, email: nil))
        XCTAssertEqual(history.points.count, 2, "Unverified accounts must not share a history series")
    }
    func testOldSamplesArePruned() {
        let history = UsageHistory()
        let date = Date()
        history.record(snapshot(Calendar.current.date(byAdding: .month, value: -14, to: date)!, percent: 10, email: "one@example.com"))
        history.record(snapshot(date, percent: 20, email: "one@example.com"))
        XCTAssertEqual(history.points.count, 1)
    }
    func testDashboardWindowCoexistsWithSettings() {
        let suite = "DashboardWindow." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MenuBarController(store: UsageStore(providers: [], availabilityChecker: FixedProviderAvailabilityChecker(installed: [])),
            preferences: AppPreferences(defaults: defaults), launchAtLogin: LaunchAtLoginController(),
            updateController: UpdateController(startingUpdater: false))
        controller.start()
        defer { controller.stop() }
        controller.showAnalytics()
        let dashboard = controller.analyticsWindow
        XCTAssertTrue(dashboard?.isVisible == true)
        XCTAssertTrue(dashboard?.styleMask.contains(.resizable) == true)
        controller.showSettings()
        controller.settingsWindow?.close()
        XCTAssertTrue(dashboard?.isVisible == true)
        controller.showAnalytics()
        XCTAssertTrue(controller.analyticsWindow === dashboard)
    }
}
