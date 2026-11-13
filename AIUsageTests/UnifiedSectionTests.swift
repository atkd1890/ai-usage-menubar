import AppKit
import XCTest
@testable import AIUsage

final class UnifiedSectionTests: XCTestCase {
    func testMonetaryBalanceIsInsideAdditionalUsageAndCreditsAreHidden() {
        let snapshot = ProviderSnapshot(provider: .codex, planName: "Plus", windows: [],
            billingUsage: .flexCreditBalance(remainingCredits: 120, usdValue: 4.8), fetchedAt: Date())
        XCTAssertNil(snapshot.displayedBillingUsage)
        XCTAssertNil(snapshot.displayedBalance)
        XCTAssertFalse(snapshot.hasAdditionalUsageSection)
        XCTAssertFalse(snapshot.availableMenuBarItems.contains { $0.metric == .credits })
        XCTAssertNil(snapshot.menuBarValue(for: .credits, displayMode: .used))
        let money = ProviderSnapshot(provider: .claude, planName: "Max", windows: [],
            billingUsage: .boundedSpend(usedAmount: 2, limitAmount: 50, currencyCode: "USD"), fetchedAt: Date(),
            prepaidBalance: MonetaryBalance(amount: 5, currencyCode: "USD"))
        XCTAssertTrue(money.hasAdditionalUsageSection)
        XCTAssertEqual(money.displayedBalance?.amount, 5)
    }
    func testClaudeTypedMoneyDoesNotGuessCurrencyOrUnits() {
        XCTAssertEqual(ClaudeUsageMapper.money(["amount_minor": 504, "exponent": 2, "currency": "USD"]),
                       MonetaryBalance(amount: 5.04, currencyCode: "USD"))
        XCTAssertNil(ClaudeUsageMapper.money(["amount_minor": 504, "currency": "USD"]))
        XCTAssertNil(ClaudeUsageMapper.money(["amount_minor": -1, "exponent": 2, "currency": "USD"]))
    }

    func testDisabledExtraUsageIsNotReportedAsZeroSpending() {
        let snapshot = ProviderSnapshot(provider: .claude, planName: nil, windows: [], fetchedAt: Date(), additionalUsageEnabled: false)
        XCTAssertFalse(snapshot.hasAdditionalUsageSection)
        XCTAssertNil(snapshot.displayedBillingUsage)
        XCTAssertNil(snapshot.displayedBalance)
    }
    func testUsableResetsAreInlineAndNeverExceedBankedCount() {
        let now = Date()
        let resets = UsageResets(availableCount: 1, usableCount: 0)
        let presentation = ResetsPresentation(resets: resets, now: now)
        XCTAssertEqual(presentation.valueText, "1 available · 0 usable now")
        XCTAssertEqual(UsageResets(availableCount: 1, usableCount: 20).usableCount, 1)
        let expired = UsageResets(availableCount: 2, expirations: [now.addingTimeInterval(-1)], usableCount: 2).active(at: now)
        XCTAssertEqual(expired.availableCount, 1)
        XCTAssertEqual(expired.usableCount, 1)
    }
    func testMenuWarningColorsUseConsumedPercentInBothModes() {
        for (used, expected) in [(59.0, UsageSeverity.normal), (60, .warning), (84, .warning), (85, .critical), (100, .critical)] {
            for mode in [UsageDisplayMode.used, .remaining] {
                let reading = MenuBarReading(provider: .codex, metric: .weekly,
                    value: .percentage(mode.displayedPercent(from: used)), displayMode: mode, isStale: false)
                let presentation = MenuBarProviderPresentation(group: MenuBarProviderReadings(provider: .codex,
                    selectedMetrics: [.weekly], readings: [reading]))
                XCTAssertEqual(presentation.metrics.first?.severity, expected)
            }
        }
    }
    @MainActor
    func testRenderedMenuBarRetainsMultipleWarningColors() throws {
        let readings = [70.0, 90.0].enumerated().map { index, used in
            MenuBarReading(provider: .codex, metric: index == 0 ? .session : .weekly,
                           value: .percentage(used), displayMode: .used, isStale: false)
        }
        let image = MenuBarStatusImageRenderer.image(for: [MenuBarProviderReadings(provider: .codex,
            selectedMetrics: [.session, .weekly], readings: readings)], font: NSFont.systemFont(ofSize: 14))
        XCTAssertFalse(image.isTemplate)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let orangeReference = try XCTUnwrap(NSColor.systemOrange.usingColorSpace(.deviceRGB))
        let redReference = try XCTUnwrap(NSColor.systemRed.usingColorSpace(.deviceRGB))
        func matches(_ color: NSColor, _ expected: NSColor) -> Bool {
            abs(color.redComponent - expected.redComponent) < 0.1 &&
            abs(color.greenComponent - expected.greenComponent) < 0.1 &&
            abs(color.blueComponent - expected.blueComponent) < 0.1
        }
        var orange = false, red = false
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5 else { continue }
                if matches(c, orangeReference) { orange = true }
                if matches(c, redReference) { red = true }
            }
        }
        XCTAssertTrue(orange)
        XCTAssertTrue(red)
    }
}
