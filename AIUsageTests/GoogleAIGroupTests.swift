import XCTest
@testable import AIUsage

final class GoogleAIGroupTests: XCTestCase {
    private func state(_ provider: ProviderID, account: String?, plan: String? = "Google AI Pro") -> ProviderState {
        ProviderState(provider: provider, snapshot: ProviderSnapshot(provider: provider, planName: plan,
            windows: [QuotaWindow(kind: .weekly, usedPercent: provider == .gemini ? 10 : 50, resetsAt: nil)],
            fetchedAt: Date(), accountLabel: account))
    }
    @MainActor func testGoogleProvidersKeepIndependentSettings() {
        let suite = "GoogleSplit." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.setTracking(false, for: .gemini)
        XCTAssertTrue(preferences.isTracking(.antigravity))
        preferences.setTracking(true, for: .gemini)
        preferences.setTracking(false, for: .antigravity)
        XCTAssertTrue(preferences.isTracking(.gemini))
        preferences.setLoginMethod(.chrome, for: .gemini)
        XCTAssertEqual(preferences.loginMethod(for: .antigravity), .desktop)
        XCTAssertEqual(ProviderLoginMethod.supported(for: .antigravity), [.desktop])
        XCTAssertNotEqual(ProviderLoginMethod.selectionKey(for: .gemini), ProviderLoginMethod.selectionKey(for: .antigravity))
    }
    func testDashboardSelectionDoesNotIncludeOtherGoogleProvider() {
        let now = Date()
        let hits = [ProviderID.gemini, .antigravity].map {
            UsageLimitHit(id: $0.rawValue, provider: $0, account: "test", date: now, metric: .weekly, reset: nil)
        }
        let projection = DashboardProjection.build(events: [], hits: hits, providers: [.gemini, .antigravity],
            selected: .antigravity, days: 30, now: now, names: [:], accounts: [.gemini: "test", .antigravity: "test"])
        XCTAssertEqual(projection.hitCount, 1)
        XCTAssertEqual(projection.limits.first?.provider, .antigravity)
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
