import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

@MainActor
final class VisualSnapshotTests: XCTestCase {
    private let panelWidth: CGFloat = 440

    func testProviderIconsAreTemplateImagesAtMenuBarSize() {
        for provider in ProviderID.allCases {
            let image = ProviderIcon.templateImage(for: provider, size: 15)

            XCTAssertEqual(image.size.width, 15)
            XCTAssertEqual(image.size.height, 15)
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testLargeQuotaCountsWrapFooterWithoutChangingExactValues() throws {
        let footer = QuotaFooter(reset: "Reset 13h 4m", note: nil, count: "3,000,000 / 3,000,000")
        let narrow = measuredSize(of: footer, width: 188)
        let wide = measuredSize(of: footer, width: 400)
        XCTAssertEqual(narrow.width, 188, accuracy: 0.5)
        XCTAssertGreaterThan(narrow.height, wide.height + 5)
        XCTAssertLessThan(narrow.height, 45)
        let short = measuredSize(of: QuotaFooter(reset: "Reset 13h 4m", note: nil, count: "100 / 100"), width: 188)
        XCTAssertEqual(short.height, wide.height, accuracy: 1)
        let compact3M = measuredSize(of: QuotaFooter(reset: "Reset 13h 4m", note: nil, count: "3M / 3M"), width: 188)
        let compact5M = measuredSize(of: QuotaFooter(reset: "Reset 13h 4m", note: nil, count: "5M / 5M"), width: 188)
        XCTAssertEqual(compact3M.height, wide.height, accuracy: 1)
        XCTAssertEqual(compact5M.height, wide.height, accuracy: 1)
        let snapshot = ProviderSnapshot(provider: .zai, planName: "Start Plan", windows: [
            QuotaWindow(kind: .additional(id: "fake.model.a", title: "Model A tokens"), usedPercent: 0, resetsAt: Date().addingTimeInterval(3600), remainingCount: 3000000, limitCount: 3000000),
            QuotaWindow(kind: .additional(id: "fake.model.b", title: "Model B tokens"), usedPercent: 0, resetsAt: Date().addingTimeInterval(3600), remainingCount: 5000000, limitCount: 5000000)
        ], fetchedAt: Date())
        let root = ProviderSectionView(state: ProviderState(provider: .zai, snapshot: snapshot), displayMode: .remaining)
            .padding(12).frame(width: 440).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.bounds.height, 60)
    }

    func testUsagePaletteAdaptsToLightAndDarkAppearances() {
        var light = EnvironmentValues()
        light.colorScheme = .light
        var dark = EnvironmentValues()
        dark.colorScheme = .dark

        let colors: [(String, Color)] = [
            ("accent", UsagePalette.accent),
            ("normalUsage", UsagePalette.normalUsage),
            ("success", UsagePalette.success),
            ("warning", UsagePalette.warning),
            ("critical", UsagePalette.critical)
        ]

        for (name, color) in colors {
            let lightValue = color.resolve(in: light)
            let darkValue = color.resolve(in: dark)

            XCTAssertNotEqual(
                lightValue,
                darkValue,
                "\(name) must use the system's appearance-aware variant"
            )
            XCTAssertEqual(lightValue.opacity, 1, accuracy: 0.001)
            XCTAssertEqual(darkValue.opacity, 1, accuracy: 0.001)
        }
    }

    func testRefreshFeedbackStaysInsideTheFooterButton() {
        let idleSize = measuredSize(
            of: RefreshButtonLabel(isRefreshing: false),
            width: 100
        )
        let refreshingSize = measuredSize(
            of: RefreshButtonLabel(isRefreshing: true),
            width: 100
        )
        let settingsSize = measuredSize(
            of: SettingsButtonLabel(),
            width: 100
        )

        XCTAssertEqual(idleSize, refreshingSize)
        XCTAssertEqual(idleSize, settingsSize)
        XCTAssertEqual(idleSize.width, RefreshButtonLabel.size, accuracy: 0.5)
        XCTAssertEqual(idleSize.height, RefreshButtonLabel.size, accuracy: 0.5)
    }

    func testMenuBarLabelKeepsUsageMeaningOutOfVisibleText() {
        for displayMode in UsageDisplayMode.allCases {
            let size = measuredSize(
                of: MenuBarProviderLabelView(
                    group: MenuBarProviderReadings(
                        provider: .codex,
                        selectedMetrics: [.weekly],
                        readings: [
                            MenuBarReading(
                                provider: .codex,
                                metric: .weekly,
                                value: .percentage(62),
                                displayMode: displayMode,
                                isStale: false
                            )
                        ]
                    )
                ),
                width: 200
            )

            XCTAssertLessThan(size.width, 75)
        }
    }

    func testDashboardFitsBoundedPanelInLightAndDark() async {
        let store = await makePopulatedStore()
        let configurations: [(ColorScheme, Bool)] = [
            (.light, false),
            (.dark, false),
            (.light, true)
        ]

        for (colorScheme, reducesTransparency) in configurations {
            let view = DashboardView(
                store: store,
                launchAtLogin: LaunchAtLoginController(service: SnapshotLoginService()),
                usageDisplayMode: .constant(.used),
                refreshInterval: .constant(.fiveMinutes),
                availableUpdateVersion: nil,
                isCheckingForUpdates: false
            )
            .frame(maxHeight: 700)
            .environment(\.colorScheme, colorScheme)
            .environment(\._accessibilityReduceTransparency, reducesTransparency)

            let size = measuredSize(of: view, width: panelWidth)
            XCTAssertEqual(size.width, panelWidth, accuracy: 0.5)
            XCTAssertLessThanOrEqual(size.height, 700.5)
            XCTAssertGreaterThan(size.height, 250)
        }
    }

    func testDashboardRespectsHeightBoundWithRemainingUsageAndUpdateAction() async {
        let store = await makePopulatedStore()
        let view = DashboardView(
            store: store,
            launchAtLogin: LaunchAtLoginController(service: SnapshotLoginService()),
            usageDisplayMode: .constant(.remaining),
            refreshInterval: .constant(.fifteenMinutes),
            availableUpdateVersion: "0.2.0",
            isCheckingForUpdates: false
        )
        .frame(maxHeight: 700)
        .environment(\.colorScheme, .dark)

        let size = measuredSize(of: view, width: panelWidth)

        XCTAssertEqual(size.width, panelWidth, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.height, 700.5)
        XCTAssertGreaterThan(size.height, 250)
    }

    func testFooterShowsUpstreamNoticeTextWithoutInteractiveUpdateButton() async {
        let store = await makePopulatedStore()
        var triggeredUpdate = false
        let footer = DashboardView(
            store: store,
            launchAtLogin: LaunchAtLoginController(service: SnapshotLoginService()),
            usageDisplayMode: .constant(.used),
            refreshInterval: .constant(.fiveMinutes),
            availableUpdateVersion: "0.5.0",
            isCheckingForUpdates: false,
            checkForUpdates: { triggeredUpdate = true },
            section: .footer
        )
        let controller = NSHostingController(rootView: footer)
        let size = controller.sizeThatFits(in: CGSize(width: panelWidth, height: .greatestFiniteMagnitude))
        XCTAssertEqual(size.width, panelWidth, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 20)

        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()

        func allButtons(in view: NSView) -> [NSButton] {
            var buttons: [NSButton] = []
            if let button = view as? NSButton { buttons.append(button) }
            for subview in view.subviews { buttons += allButtons(in: subview) }
            return buttons
        }

        let buttons = allButtons(in: controller.view)
        XCTAssertFalse(buttons.contains { $0.title.localizedCaseInsensitiveContains("Update") })
        XCTAssertFalse(buttons.contains { ($0.toolTip ?? "").localizedCaseInsensitiveContains("Update AI Usage") })
        XCTAssertFalse(triggeredUpdate)
    }

    func testSettingsShowsIndependentProvidersInLightAndDark() async {
        let store = await makeFullyPopulatedStore()
        let suiteName = "VisualSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let preferences = AppPreferences(defaults: defaults)
        preferences.configureDefaultMenuBarProviders(
            availableItemsByProvider: store.availableMenuBarItemsByProvider
        )

        for colorScheme in [ColorScheme.light, .dark] {
            let view = SettingsView(
                store: store,
                preferences: preferences,
                launchAtLogin: LaunchAtLoginController(
                    service: SnapshotLoginService()
                ),
                updateController: UpdateController(startingUpdater: false)
            )
            .environment(\.colorScheme, colorScheme)

            let width = AppSurfaceLayout.settingsWidth
            let size = measuredSize(of: view, width: width)
            XCTAssertEqual(size.width, width, accuracy: 0.5)
            // Enabled products grouped into US and CN zones replace the original nine-row panel.
            // The native settings window constrains and scrolls taller content.
            XCTAssertLessThan(size.height, 700 + CGFloat(ProviderID.enabledCases.count) * 80)
            XCTAssertGreaterThan(size.height, 300)
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    func testSettingsMetricChoicesWrapInsteadOfTruncating() {
        let choices = WrappingHStack(spacing: 8, lineSpacing: 4) {
            ForEach(0..<6, id: \.self) { _ in
                Color.clear.frame(width: 60, height: 16)
            }
        }

        let size = measuredSize(of: choices, width: 200)

        XCTAssertEqual(size.height, 36, accuracy: 0.5)
        XCTAssertLessThanOrEqual(size.width, 200)
    }

    func testProviderSurfaceKeepsOddQuotaCountCompact() {
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .session, usedPercent: 28, resetsAt: Date().addingTimeInterval(3_600)),
                QuotaWindow(kind: .weekly, usedPercent: 52, resetsAt: Date().addingTimeInterval(86_400)),
                QuotaWindow(kind: .sonnet, usedPercent: 76, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let state = ProviderState(provider: .claude, snapshot: snapshot)
        let size = measuredSize(of: ProviderSectionView(state: state), width: panelWidth - 20)
        let expanded = measuredSize(of: ProviderSectionView(state: state, expandedOverride: true), width: panelWidth - 20)

        XCTAssertEqual(size.width, panelWidth - 20, accuracy: 0.5)
        XCTAssertGreaterThan(size.height, 70)
        XCTAssertLessThan(size.height, expanded.height)
        XCTAssertLessThan(expanded.height, 240)
        XCTAssertEqual(ProviderDetailsLayout.windows(snapshot, expanded: false).map(\.kind), [.session, .weekly])
        XCTAssertEqual(ProviderDetailsLayout.windows(snapshot, expanded: true).map(\.kind), [.session, .weekly, .sonnet])
    }

    func testBillingUsagePresentationKeepsProviderSemanticsDistinct() {
        let locale = Locale(identifier: "en_US")
        let bounded = BillingUsage.boundedSpend(
            usedAmount: 5,
            limitAmount: 10,
            currencyCode: "USD"
        )
        let used = BillingUsagePresentation(
            usage: bounded,
            displayMode: .used,
            locale: locale
        )
        let remaining = BillingUsagePresentation(
            usage: bounded,
            displayMode: .remaining,
            locale: locale
        )
        let uncapped = BillingUsagePresentation(
            usage: .unboundedSpend(
                usedAmount: 1234.56,
                currencyCode: "USD"
            ),
            displayMode: .remaining,
            locale: locale
        )
        let credits = BillingUsagePresentation(
            usage: .flexCreditBalance(
                remainingCredits: 820,
                usdValue: 32.8
            ),
            displayMode: .used,
            locale: locale
        )

        XCTAssertEqual(used.title, "Extra usage")
        XCTAssertEqual(used.valueText, "$5.00 / $10.00 spent")
        XCTAssertEqual(remaining.valueText, "$5.00 / $10.00 left")
        XCTAssertEqual(uncapped.valueText, "$1,234.56 spent")
        XCTAssertEqual(credits.title, "Credits")
        XCTAssertEqual(credits.valueText, "$32.80 · 820 credits left")
        XCTAssertTrue(credits.accessibilityValue.contains("remaining"))
    }

    func testProviderLoadingAndTransientFailureStatesStayInsideOneCompactSurface() {
        var loadingState = ProviderState(provider: .claude)
        loadingState.isRefreshing = true
        let loadingSize = measuredSize(
            of: ProviderSectionView(state: loadingState),
            width: panelWidth - 20
        )

        let failureState = ProviderState(
            provider: .codex,
            failure: ProviderFailure(.transient, "Codex could not be reached.")
        )
        let failureSize = measuredSize(
            of: ProviderSectionView(state: failureState),
            width: panelWidth - 20
        )

        XCTAssertLessThan(loadingSize.height, 110)
        XCTAssertLessThan(failureSize.height, 120)
        XCTAssertGreaterThan(loadingSize.height, 55)
        XCTAssertGreaterThan(failureSize.height, 55)
    }

    func testToolAvailabilityControlsVisibilityIndependentlyOfLogin() {
        let missingTool = ProviderState(
            provider: .claude,
            failure: ProviderFailure(.authentication, "Not logged in."),
            isToolInstalled: false
        )
        let loggedOut = ProviderState(
            provider: .codex,
            failure: ProviderFailure(.authentication, "Not logged in."),
            isToolInstalled: true
        )

        XCTAssertFalse(missingTool.isVisibleInDashboard)
        XCTAssertTrue(loggedOut.isVisibleInDashboard)
    }

    func testStaleProviderWarningMovesIntoHeaderBadgeWithoutExpandingCardHeight() {
        let snapshot = ProviderSnapshot(
            provider: .buddy,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .monthly, usedPercent: 40, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let freshState = ProviderState(provider: .buddy, snapshot: snapshot)
        let staleState = ProviderState(
            provider: .buddy,
            snapshot: snapshot,
            failure: ProviderFailure(.transient, "Buddy could not be reached.")
        )

        let freshSize = measuredSize(of: ProviderSectionView(state: freshState), width: panelWidth - 20)
        let staleSize = measuredSize(of: ProviderSectionView(state: staleState), width: panelWidth - 20)
        XCTAssertEqual(staleSize.height, freshSize.height, accuracy: 0.5)

        let presentation = ProviderWarningPresentation.make(
            state: staleState,
            activeWarnings: [],
            canReload: true
        )
        XCTAssertEqual(presentation?.entries.count, 1)
        XCTAssertEqual(presentation?.dividerCount, 0)
        XCTAssertEqual(presentation?.popoverTitle, "Buddy Warning")
        XCTAssertEqual(presentation?.accessibilityLabel, "Buddy warning")
        XCTAssertEqual(presentation?.accessibilityValue, "Buddy could not be reached.")
        XCTAssertTrue(presentation?.hasStaleFailure == true)
        XCTAssertFalse(presentation?.hasDiagnosticWarnings == true)
        XCTAssertTrue(presentation?.tooltipSummary.contains("Showing last update — Buddy could not be reached.") == true)
        XCTAssertTrue(presentation?.tooltipSummary.contains("Click for details or to reload.") == true)
    }

    func testNoDataFailureRemainsInlinePlaceholderInsteadOfHeaderBadge() {
        let noSnapshotState = ProviderState(
            provider: .buddy,
            failure: ProviderFailure(.transient, "Buddy could not be reached.")
        )
        let emptySnapshotState = ProviderState(
            provider: .buddy,
            snapshot: ProviderSnapshot(provider: .buddy, planName: nil, windows: [], fetchedAt: Date()),
            failure: ProviderFailure(.transient, "Buddy could not be reached.")
        )

        XCTAssertNil(ProviderWarningPresentation.make(state: noSnapshotState, activeWarnings: [], canReload: true))
        XCTAssertNil(ProviderWarningPresentation.make(state: emptySnapshotState, activeWarnings: [], canReload: true))

        let size = measuredSize(of: ProviderSectionView(state: noSnapshotState), width: panelWidth - 20)
        XCTAssertGreaterThan(size.height, 55)
        XCTAssertLessThan(size.height, 120)
    }

    func testMultipleWarningsOrderStaleFailureAndDiagnosticsWithDividers() {
        let retryAt = Date().addingTimeInterval(300)
        let snapshot = ProviderSnapshot(
            provider: .buddy,
            planName: "Pro",
            windows: [
                QuotaWindow(kind: .monthly, usedPercent: 40, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        let staleState = ProviderState(
            provider: .buddy,
            snapshot: snapshot,
            failure: ProviderFailure(.rateLimited, "Buddy usage is rate limited.", retryAt: retryAt)
        )
        let diagnostics = [
            ProviderDiagnosticWarning(
                id: "schema.added.test",
                kind: .schemaAdded,
                summary: "New field in Buddy",
                detail: "bonus_pool: 100"
            ),
            ProviderDiagnosticWarning(
                id: "api.deprecated.test",
                kind: .apiDeprecated,
                summary: "API deprecation notice",
                detail: "Sunset: 2027-01-01"
            )
        ]

        let combined = ProviderWarningPresentation.make(
            state: staleState,
            activeWarnings: diagnostics,
            canReload: true
        )
        XCTAssertEqual(combined?.entries.count, 3)
        XCTAssertEqual(combined?.dividerCount, 2)
        XCTAssertEqual(combined?.popoverTitle, "Buddy Warnings")
        XCTAssertEqual(combined?.accessibilityLabel, "Buddy warnings")
        XCTAssertEqual(combined?.entries.first?.isStaleFailure, true)
        XCTAssertEqual(combined?.entries.first?.retryAt, retryAt)
        XCTAssertEqual(
            combined?.entries.map(\.summary),
            ["Buddy usage is rate limited.", "New field in Buddy", "API deprecation notice"]
        )
        XCTAssertTrue(combined?.tooltipSummary.contains("Click for details, to reload, or to update confirmed config.") == true)

        let diagnosticOnly = ProviderWarningPresentation.make(
            state: ProviderState(provider: .buddy, snapshot: snapshot),
            activeWarnings: diagnostics,
            canReload: true
        )
        XCTAssertEqual(diagnosticOnly?.entries.count, 2)
        XCTAssertEqual(diagnosticOnly?.dividerCount, 1)
        XCTAssertEqual(diagnosticOnly?.popoverTitle, "Buddy API Notice")
        XCTAssertEqual(diagnosticOnly?.accessibilityLabel, "Buddy API warning")
    }

    private func makePopulatedStore() async -> UsageStore {
        let now = Date()
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(ProviderSnapshot(
                provider: .claude,
                planName: "Ultra",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 62,
                        resetsAt: now.addingTimeInterval(2_400)
                    ),
                    QuotaWindow(
                        kind: .weekly,
                        usedPercent: 37,
                        resetsAt: now.addingTimeInterval(172_800)
                    ),
                    QuotaWindow(
                        kind: .sonnet,
                        usedPercent: 86,
                        resetsAt: now.addingTimeInterval(259_200)
                    ),
                    QuotaWindow(
                        kind: .fable,
                        usedPercent: 14,
                        resetsAt: now.addingTimeInterval(345_600)
                    )
                ],
                billingUsage: .boundedSpend(
                    usedAmount: 5,
                    limitAmount: 10,
                    currencyCode: "USD"
                ),
                fetchedAt: now
            ))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(ProviderSnapshot(
                provider: .codex,
                planName: "Pro 100",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 28,
                        resetsAt: now.addingTimeInterval(7_200)
                    ),
                    QuotaWindow(
                        kind: .weekly,
                        usedPercent: 74,
                        resetsAt: now.addingTimeInterval(345_600)
                    ),
                    QuotaWindow(
                        kind: .sparkSession,
                        usedPercent: 11,
                        resetsAt: now.addingTimeInterval(10_800)
                    ),
                    QuotaWindow(
                        kind: .sparkWeekly,
                        usedPercent: 52,
                        resetsAt: now.addingTimeInterval(432_000)
                    )
                ],
                billingUsage: .flexCreditBalance(
                    remainingCredits: 820,
                    usdValue: 32.8
                ),
                fetchedAt: now
            ))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude, .codex]
            )
        )
        await store.refresh()
        return store
    }

    private func makeFullyPopulatedStore() async -> UsageStore {
        let now = Date()
        let snapshots: [ProviderID: ProviderSnapshot] = [
            .claude: ProviderSnapshot(
                provider: .claude,
                planName: "Ultra",
                windows: [
                    QuotaWindow(kind: .session, usedPercent: 62, resetsAt: nil),
                    QuotaWindow(kind: .weekly, usedPercent: 37, resetsAt: nil),
                    QuotaWindow(kind: .sonnet, usedPercent: 86, resetsAt: nil),
                    QuotaWindow(kind: .fable, usedPercent: 14, resetsAt: nil)
                ],
                billingUsage: .boundedSpend(
                    usedAmount: 5,
                    limitAmount: 10,
                    currencyCode: "USD"
                ),
                fetchedAt: now
            ),
            .codex: ProviderSnapshot(
                provider: .codex,
                planName: "Pro 100",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 74, resetsAt: nil),
                    QuotaWindow(
                        kind: .sparkSession,
                        usedPercent: 11,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .sparkWeekly,
                        usedPercent: 52,
                        resetsAt: nil
                    )
                ],
                billingUsage: .flexCreditBalance(
                    remainingCredits: 820,
                    usdValue: 32.8
                ),
                fetchedAt: now
            ),
            .cursor: ProviderSnapshot(
                provider: .cursor,
                planName: "Pro",
                windows: [
                    QuotaWindow(
                        kind: .totalUsage,
                        usedPercent: 25,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .autoUsage,
                        usedPercent: 40,
                        resetsAt: nil
                    ),
                    QuotaWindow(
                        kind: .apiUsage,
                        usedPercent: 12,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            ),
            .antigravity: ProviderSnapshot(
                provider: .antigravity,
                planName: "Pro",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 34, resetsAt: nil),
                    QuotaWindow(
                        kind: .claudePool,
                        usedPercent: 48,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            ),
            .copilot: ProviderSnapshot(
                provider: .copilot,
                planName: "Individual Pro",
                windows: [
                    QuotaWindow(kind: .credits, usedPercent: 25, resetsAt: nil),
                    QuotaWindow(kind: .chat, usedPercent: 20, resetsAt: nil),
                    QuotaWindow(
                        kind: .completions,
                        usedPercent: 8,
                        resetsAt: nil
                    )
                ],
                fetchedAt: now
            )
        ]
        let providers = ProviderID.allCases.compactMap { provider in
            snapshots[provider].map {
                SequencedProvider(id: provider, results: [.success($0)])
            }
        }
        let store = UsageStore(
            providers: providers,
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: Set(ProviderID.allCases)
            )
        )
        await store.refresh()
        return store
    }

    private func measuredSize<Content: View>(
        of view: Content,
        width: CGFloat
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        return controller.sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude)
        )
    }
}

@MainActor
private struct SnapshotLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }
    func register() throws {}
    func unregister() throws {}
}
