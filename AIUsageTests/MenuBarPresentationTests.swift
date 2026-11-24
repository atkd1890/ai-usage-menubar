import AppKit
import XCTest
@testable import AIUsage

final class MenuBarPresentationTests: XCTestCase {
    func testPercentageStaysCompactAndMeaningRemainsAccessible() {
        let presentation = MenuBarPresentation(reading: MenuBarReading(
            provider: .codex,
            metric: .weekly,
            value: .percentage(62.4),
            displayMode: .remaining,
            isStale: true
        ))

        XCTAssertEqual(presentation.valueText, "62%")
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Codex Weekly 62 percent left, stale"
        )
        XCTAssertTrue(presentation.showsStaleIndicator)
    }

    func testCreditsStayCompactAndExplainTheBalanceAccessibly() {
        let presentation = MenuBarPresentation(reading: MenuBarReading(
            provider: .codex,
            metric: .credits,
            value: .credits(remaining: 120, usdValue: 4.8),
            displayMode: .remaining,
            isStale: false
        ))

        XCTAssertNotNil(presentation.valueText)
        XCTAssertTrue(
            presentation.accessibilityLabel.contains("120 credits left")
        )
        XCTAssertTrue(
            presentation.accessibilityLabel.contains("worth")
        )
    }

    func testNoAvailableReadingsUsesOnlyTheAppIdentity() {
        let presentation = MenuBarReadingsPresentation(readings: [])

        XCTAssertEqual(presentation.items, [])
        XCTAssertEqual(presentation.accessibilityLabel, "AI usage")
    }

    func testMultipleReadingsKeepProviderValuesAndAccessibilityOrder() {
        let presentation = MenuBarReadingsPresentation(readings: [
            MenuBarReading(
                provider: .claude,
                metric: .session,
                value: .percentage(62),
                displayMode: .used,
                isStale: false
            ),
            MenuBarReading(
                provider: .codex,
                metric: .sparkWeekly,
                value: .percentage(28),
                displayMode: .used,
                isStale: true
            )
        ])

        XCTAssertEqual(presentation.items.map(\.valueText), ["62%", "28%"])
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Claude Session 62 percent used, Codex Spark Weekly 28 percent used, stale"
        )
    }

    func testSingleSelectedMetricShowsOnlyItsValue() {
        let group = MenuBarProviderReadings(
            provider: .claude,
            selectedMetrics: [.weekly],
            readings: [
                MenuBarReading(
                    provider: .claude,
                    metric: .weekly,
                    value: .percentage(42),
                    displayMode: .remaining,
                    isStale: false
                )
            ]
        )

        let presentation = MenuBarProviderPresentation(group: group)

        XCTAssertEqual(
            presentation.metrics,
            [
                MenuBarMetricPresentation(
                    label: nil,
                    valueText: "42%",
                    showsStaleIndicator: false
                )
            ]
        )
        XCTAssertNil(presentation.sharedSuffix)
    }

    func testSingleReadingDropsMicroLabelEvenWhenMoreMetricsAreSelected() {
        // A selected metric the provider no longer returns (e.g. a missing
        // five-hour window) must not force a label onto the lone reading.
        let group = MenuBarProviderReadings(
            provider: .claude,
            selectedMetrics: [.session, .weekly],
            readings: [
                MenuBarReading(
                    provider: .claude,
                    metric: .weekly,
                    value: .percentage(97),
                    displayMode: .remaining,
                    isStale: false
                )
            ]
        )

        let presentation = MenuBarProviderPresentation(group: group)

        XCTAssertEqual(
            presentation.metrics,
            [
                MenuBarMetricPresentation(
                    label: nil,
                    valueText: "97%",
                    showsStaleIndicator: false
                )
            ]
        )
        XCTAssertNil(presentation.sharedSuffix)
    }

    func testMultipleSelectedMetricsUseMicroLabelsAndSharedPercent() {
        let group = MenuBarProviderReadings(
            provider: .claude,
            selectedMetrics: [.session, .weekly],
            readings: [
                MenuBarReading(
                    provider: .claude,
                    metric: .session,
                    value: .percentage(78),
                    displayMode: .remaining,
                    isStale: false
                ),
                MenuBarReading(
                    provider: .claude,
                    metric: .weekly,
                    value: .percentage(42),
                    displayMode: .remaining,
                    isStale: false
                )
            ]
        )

        let presentation = MenuBarProviderPresentation(group: group)

        XCTAssertEqual(
            presentation.metrics,
            [
                MenuBarMetricPresentation(
                    label: "S",
                    valueText: "78",
                    showsStaleIndicator: false
                ),
                MenuBarMetricPresentation(
                    label: "W",
                    valueText: "42",
                    showsStaleIndicator: false
                )
            ]
        )
        XCTAssertEqual(presentation.sharedSuffix, "%")
    }

    func testMixedMetricTypesKeepTheirOwnUnits() {
        let group = MenuBarProviderReadings(
            provider: .codex,
            selectedMetrics: [.weekly, .credits],
            readings: [
                MenuBarReading(
                    provider: .codex,
                    metric: .weekly,
                    value: .percentage(42),
                    displayMode: .remaining,
                    isStale: false
                ),
                MenuBarReading(
                    provider: .codex,
                    metric: .credits,
                    value: .credits(remaining: 120, usdValue: 4.8),
                    displayMode: .remaining,
                    isStale: false
                )
            ]
        )

        let presentation = MenuBarProviderPresentation(group: group)

        XCTAssertEqual(presentation.metrics[0].label, "W")
        XCTAssertEqual(presentation.metrics[0].valueText, "42%")
        XCTAssertEqual(presentation.metrics[1].label, "C")
        XCTAssertFalse(presentation.metrics[1].valueText.isEmpty)
        XCTAssertNil(presentation.sharedSuffix)
    }

    func testProviderWithoutReadingsRemainsAccessibleWithoutPlaceholderText() {
        let groups = [
            MenuBarProviderReadings(
                provider: .claude,
                selectedMetrics: [.session],
                readings: []
            )
        ]
        let presentation = MenuBarReadingsPresentation(groups: groups)

        XCTAssertEqual(presentation.items, [])
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Claude, no usage data"
        )
        XCTAssertEqual(
            MenuBarProviderPresentation(group: groups[0]).metrics,
            []
        )
    }

    @MainActor
    func testGroupedStatusImageUsesTemplateRendering() {
        let groups = [
            MenuBarProviderReadings(
                provider: .claude,
                selectedMetrics: [.sonnet],
                readings: [
                    MenuBarReading(
                        provider: .claude,
                        metric: .sonnet,
                        value: .percentage(62),
                        displayMode: .used,
                        isStale: false
                    )
                ]
            ),
            MenuBarProviderReadings(
                provider: .codex,
                selectedMetrics: [.spark],
                readings: [
                    MenuBarReading(
                        provider: .codex,
                        metric: .spark,
                        value: .percentage(28),
                        displayMode: .used,
                        isStale: false
                    )
                ]
            )
        ]

        let image = MenuBarStatusImageRenderer.image(
            for: groups,
            font: NSFont.menuBarFont(ofSize: 0)
        )

        XCTAssertFalse(image.isTemplate)
        XCTAssertGreaterThan(image.size.width, 55)
        XCTAssertLessThan(image.size.width, 130)
    }

    @MainActor
    func testMicroLabelsUseLessWidthThanFullSizePrefixes() {
        let group = MenuBarProviderReadings(
            provider: .claude,
            selectedMetrics: [.session, .weekly],
            readings: [
                MenuBarReading(
                    provider: .claude,
                    metric: .session,
                    value: .percentage(78),
                    displayMode: .remaining,
                    isStale: false
                ),
                MenuBarReading(
                    provider: .claude,
                    metric: .weekly,
                    value: .percentage(42),
                    displayMode: .remaining,
                    isStale: false
                )
            ]
        )
        let font = NSFont.menuBarFont(ofSize: 0)
        let image = MenuBarStatusImageRenderer.image(
            for: [group],
            font: font
        )
        let legacyValuesWidth = ["S 78%", "W 42%"]
            .map {
                ($0 as NSString).size(withAttributes: [.font: font]).width
            }
            .reduce(0, +) + 6
        let legacyWidth = 15 + 3 + ceil(legacyValuesWidth)

        XCTAssertLessThan(image.size.width, legacyWidth - 15)
    }

    @MainActor
    func testRiskIndicatorSetsAccessibilityLabelAndStaleTakesPrecedenceInImage() {
        let font = NSFont.menuBarFont(ofSize: 0)
        let base = MenuBarReading(
            provider: .claude,
            metric: .session,
            value: .percentage(80),
            displayMode: .used,
            isStale: false,
            isAtRisk: false
        )
        let atRisk = MenuBarReading(
            provider: .claude,
            metric: .session,
            value: .percentage(80),
            displayMode: .used,
            isStale: false,
            isAtRisk: true
        )
        let staleAndAtRisk = MenuBarReading(
            provider: .claude,
            metric: .session,
            value: .percentage(80),
            displayMode: .used,
            isStale: true,
            isAtRisk: true
        )

        XCTAssertFalse(MenuBarPresentation(reading: base).showsRiskIndicator)
        let riskPresentation = MenuBarPresentation(reading: atRisk)
        XCTAssertTrue(riskPresentation.showsRiskIndicator)
        XCTAssertTrue(riskPresentation.accessibilityLabel.contains("runs out before reset at this pace"))

        let baseImage = MenuBarStatusImageRenderer.image(
            for: [MenuBarProviderReadings(provider: .claude, selectedMetrics: [.session], readings: [base])],
            font: font
        )
        let riskImage = MenuBarStatusImageRenderer.image(
            for: [MenuBarProviderReadings(provider: .claude, selectedMetrics: [.session], readings: [atRisk])],
            font: font
        )
        XCTAssertGreaterThan(riskImage.size.width, baseImage.size.width)

        let staleOnly = MenuBarReading(
            provider: .claude,
            metric: .session,
            value: .percentage(80),
            displayMode: .used,
            isStale: true,
            isAtRisk: false
        )
        let staleOnlyImage = MenuBarStatusImageRenderer.image(
            for: [MenuBarProviderReadings(provider: .claude, selectedMetrics: [.session], readings: [staleOnly])],
            font: font
        )
        let staleRiskImage = MenuBarStatusImageRenderer.image(
            for: [MenuBarProviderReadings(provider: .claude, selectedMetrics: [.session], readings: [staleAndAtRisk])],
            font: font
        )
        XCTAssertEqual(staleRiskImage.size.width, staleOnlyImage.size.width)
    }
}
