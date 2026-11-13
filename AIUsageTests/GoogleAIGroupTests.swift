import XCTest
@testable import AIUsage

final class GoogleAIGroupTests: XCTestCase {
    func testGroupingAnchorsAtFirstGoogleProductWithoutDuplicatingChildren() {
        let input: [ProviderID] = [.claude, .antigravity, .cursor, .copilot, .gemini, .codex]
        XCTAssertEqual(GoogleAIGroup.ordered(input), [.claude, .antigravity, .gemini, .cursor, .copilot, .codex])
        XCTAssertEqual(Set(GoogleAIGroup.ordered(input)), Set(input))
        XCTAssertEqual(GoogleAIGroup.ordered([.gemini, .cursor]), [.gemini, .cursor])
        XCTAssertEqual(GoogleAIGroup.ordered([.cursor, .antigravity]), [.cursor, .antigravity])
        XCTAssertEqual(GoogleAIGroup.ordered([]), [])
    }
    private func state(_ provider: ProviderID, account: String?, plan: String? = "Google AI Pro") -> ProviderState {
        ProviderState(provider: provider, snapshot: ProviderSnapshot(provider: provider, planName: plan,
            windows: [QuotaWindow(kind: .weekly, usedPercent: provider == .gemini ? 10 : 50, resetsAt: nil)],
            fetchedAt: Date(), accountLabel: account))
    }
    func testEqualPlanNamesWithoutAccountEvidenceDoNotBecomeSharedPlan() {
        XCTAssertNil(GoogleAIGroup.sharedPlan([state(.gemini, account: "one@example.test"), state(.antigravity, account: nil)]))
        XCTAssertNil(GoogleAIGroup.sharedPlan([state(.gemini, account: "one@example.test"), state(.antigravity, account: "two@example.test")]))
        XCTAssertEqual(GoogleAIGroup.sharedPlan([state(.gemini, account: "one@example.test")]), "Google AI Pro")
    }
    func testOnlyMatchingAccountAndPlanCanUseSharedBadge() {
        XCTAssertEqual(GoogleAIGroup.sharedPlan([state(.gemini, account: "One@example.test"), state(.antigravity, account: "one@example.test")]), "Google AI Pro")
        XCTAssertNil(GoogleAIGroup.sharedPlan([state(.gemini, account: "one@example.test"), state(.antigravity, account: "one@example.test", plan: "Google AI Ultra")]))
    }
    @MainActor
    func testMasterSettingsSwitchesAndProductSpecificCheckboxes() {
        let suite = "GoogleGroupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let gemini = MenuBarItemID(provider: .gemini, metric: .weekly)
        let ag = MenuBarItemID(provider: .antigravity, metric: .weekly)
        preferences.setGoogleAITracking(true)
        preferences.setGoogleAIMenuBarVisibility(true, availableItems: [gemini, ag])
        XCTAssertTrue(preferences.isProviderShownInMenuBar(.gemini))
        XCTAssertTrue(preferences.isProviderShownInMenuBar(.antigravity))
        preferences.setMenuBarMetric(false, item: gemini, availableItems: [gemini])
        XCTAssertTrue(preferences.isMenuBarMetricSelected(ag))
        XCTAssertFalse(preferences.isMenuBarMetricSelected(gemini))
        preferences.setGoogleAITracking(false)
        XCTAssertFalse(preferences.isTracking(.gemini))
        XCTAssertFalse(preferences.isTracking(.antigravity))
        XCTAssertFalse(preferences.isProviderShownInMenuBar(.antigravity))
        XCTAssertTrue(preferences.isMenuBarMetricSelected(ag))
    }

    @MainActor
    func testOneProductFailureKeepsOtherQuotaAndMetricIdentity() async {
        let good = state(.gemini, account: "one@example.test").snapshot!
        let store = UsageStore(providers: [
            SequencedProvider(id: .gemini, results: [.success(good)]),
            SequencedProvider(id: .antigravity, results: [.failure(ProviderFailure(.authentication, "Sign in again"))])
        ], availabilityChecker: FixedProviderAvailabilityChecker(installed: [.gemini, .antigravity]))
        store.setTrackedProviders([.gemini, .antigravity])
        await store.refresh()
        XCTAssertEqual(store.states[.gemini]?.snapshot, good)
        XCTAssertNotNil(store.states[.antigravity]?.failure)
        XCTAssertEqual(store.availableMenuBarItems(for: .gemini).first?.provider, .gemini)
        XCTAssertTrue(store.availableMenuBarItems(for: .antigravity).isEmpty)
    }
}
