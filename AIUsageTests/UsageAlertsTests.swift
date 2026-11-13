import XCTest
@testable import AIUsage

@MainActor final class UsageAlertsTests: XCTestCase {
    func testPaceWarnsOnlyWhenExhaustionPrecedesResetWithinLeadTime() {
        let now = Date(), reset = Date().addingTimeInterval(3600)
        let samples = [AlertReading(date: now.addingTimeInterval(-600), used: 60, reset: reset),
                       AlertReading(date: now.addingTimeInterval(-300), used: 75, reset: reset),
                       AlertReading(date: now, used: 90, reset: reset)]
        XCTAssertNotNil(AlertRules.exhaustion(readings: samples, leadMinutes: 15))
        XCTAssertNil(AlertRules.exhaustion(readings: samples, leadMinutes: 1))
        XCTAssertNil(AlertRules.exhaustion(readings: Array(samples.suffix(2)), leadMinutes: 15))
        let slow = [AlertReading(date: now.addingTimeInterval(-600), used: 89, reset: reset),
                    AlertReading(date: now.addingTimeInterval(-300), used: 89.5, reset: reset),
                    AlertReading(date: now, used: 90, reset: reset)]
        XCTAssertNil(AlertRules.exhaustion(readings: slow, leadMinutes: 60))
    }
    func testHighFixedPercentageAloneDoesNotTriggerPaceAlert() {
        let now = Date(), reset = Date().addingTimeInterval(10000)
        let flat = (0..<3).map { AlertReading(date: now.addingTimeInterval(Double($0 - 2) * 300), used: 99, reset: reset) }
        XCTAssertNil(AlertRules.exhaustion(readings: flat, leadMinutes: 60))
    }
    func testPaidUsageRequiresActualSpendChangeAndObservedLimit() {
        func snapshot(_ used: Double, _ spent: Double) -> ProviderSnapshot {
            ProviderSnapshot(provider: .codex, planName: "Plus", windows: [.init(kind: .session, usedPercent: used, resetsAt: nil)],
                             billingUsage: .boundedSpend(usedAmount: spent, limitAmount: 50, currencyCode: "USD"), fetchedAt: Date())
        }
        XCTAssertTrue(AlertRules.paidStarted(old: snapshot(100, 0), new: snapshot(100, 1)))
        XCTAssertFalse(AlertRules.paidStarted(old: snapshot(50, 0), new: snapshot(60, 1)))
        XCTAssertFalse(AlertRules.paidStarted(old: snapshot(100, 1), new: snapshot(100, 2)))
    }
    func testAlertPreferencesPersistAndDefaultOff() {
        let suite = "AlertsTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AlertPreferences(defaults: defaults)
        XCTAssertFalse(settings.enabled)
        settings.runningOut = true; settings.leadMinutes = 30
        let restored = AlertPreferences(defaults: defaults)
        XCTAssertTrue(restored.runningOut)
        XCTAssertEqual(restored.leadMinutes, 30)
    }
}
