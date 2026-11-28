import XCTest
@testable import AIUsage

@MainActor
final class UsageStoreTests: XCTestCase {
    func testTransientFailureRetainsLastGoodAndMarksMetricStale() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [QuotaWindow(kind: .session, usedPercent: 72, resetsAt: nil)],
            fetchedAt: now
        )
        let claude = SequencedProvider(
            id: .claude,
            results: [
                .success(snapshot),
                .failure(ProviderFailure(.transient, "Offline"))
            ]
        )
        let store = UsageStore(
            providers: [claude],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )
        let item = MenuBarItemID(provider: .claude, metric: .session)

        await store.refresh()
        await store.refresh()

        XCTAssertEqual(store.states[.claude]?.snapshot, snapshot)
        XCTAssertTrue(store.states[.claude]?.isStale == true)
        XCTAssertEqual(
            store.menuBarReading(for: item),
            MenuBarReading(
                provider: .claude,
                metric: .session,
                value: .percentage(72),
                displayMode: .used,
                isStale: true
            )
        )
    }

    func testAuthenticationFailureClearsLastGoodAndHidesUnavailableMetric() async {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: nil,
            windows: [QuotaWindow(kind: .session, usedPercent: 18, resetsAt: nil)],
            fetchedAt: Date()
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [
                .success(snapshot),
                .failure(ProviderFailure(.authentication, "Logged out"))
            ]
        )
        let store = UsageStore(
            providers: [codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )
        let item = MenuBarItemID(provider: .codex, metric: .session)

        await store.refresh()
        await store.refresh()

        XCTAssertNil(store.states[.codex]?.snapshot)
        XCTAssertNil(store.menuBarReading(for: item))
        XCTAssertEqual(store.availableMenuBarItems(for: .codex), [])
    }

    func testMenuBarReadingsUseExactMetricsInUserOrder() async {
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))]
        )
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))]
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )
        let items = [
            MenuBarItemID(provider: .codex, metric: .weekly),
            MenuBarItemID(provider: .claude, metric: .session),
            MenuBarItemID(provider: .claude, metric: .weekly)
        ]

        await store.refresh()

        let readings = store.menuBarReadings(for: items)
        XCTAssertEqual(readings.map(\.provider), [.codex, .claude, .claude])
        XCTAssertEqual(readings.map(\.metric), [.weekly, .session, .weekly])
        XCTAssertEqual(
            readings.map(\.value),
            [.percentage(42), .percentage(20), .percentage(35)]
        )

        let groups = store.menuBarProviderReadings(
            for: [
                MenuBarProviderConfiguration(
                    provider: .codex,
                    metrics: [.weekly]
                ),
                MenuBarProviderConfiguration(
                    provider: .claude,
                    metrics: [.session, .weekly]
                )
            ]
        )
        XCTAssertEqual(groups.map(\.provider), [.codex, .claude])
        XCTAssertEqual(groups[0].readings.map(\.metric), [.weekly])
        XCTAssertEqual(
            groups[1].readings.map(\.metric),
            [.session, .weekly]
        )
    }

    func testProviderGroupFallsBackToDefaultMetricWhenSelectionIsMissing() async {
        // Some Claude accounts have no five-hour window: the API returns
        // `five_hour: null`, so a saved "session" selection yields nothing.
        let claude = SequencedProvider(
            id: .claude,
            results: [.success(ProviderSnapshot(
                provider: .claude,
                planName: "Max",
                windows: [
                    QuotaWindow(kind: .weekly, usedPercent: 1, resetsAt: nil),
                    QuotaWindow(kind: .fable, usedPercent: 0, resetsAt: nil)
                ],
                fetchedAt: Date()
            ))]
        )
        let store = UsageStore(
            providers: [claude],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()

        let groups = store.menuBarProviderReadings(
            for: [MenuBarProviderConfiguration(
                provider: .claude,
                metrics: [.session]
            )]
        )
        XCTAssertEqual(groups.map(\.provider), [.claude])
        XCTAssertEqual(groups[0].readings.map(\.metric), [.weekly])
        XCTAssertEqual(groups[0].readings.map(\.value), [.percentage(1)])
    }

    func testExplicitWeeklyMetricNeverFallsBackToSession() async {
        let codex = SequencedProvider(
            id: .codex,
            results: [.success(ProviderSnapshot(
                provider: .codex,
                planName: "Pro",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 17,
                        resetsAt: nil
                    )
                ],
                fetchedAt: Date()
            ))]
        )
        let store = UsageStore(
            providers: [codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )
        let weekly = MenuBarItemID(provider: .codex, metric: .weekly)

        await store.refresh()

        XCTAssertNil(store.menuBarReading(for: weekly))
        XCTAssertFalse(store.isMenuBarItemAvailable(weekly))
    }

    func testAvailableMetricsComeOnlyFromTheLiveSnapshot() async {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            planName: "Pro",
            windows: [
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: 37,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .sparkSession,
                    usedPercent: 14,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .sparkWeekly,
                    usedPercent: 48,
                    resetsAt: nil
                )
            ],
            billingUsage: .flexCreditBalance(
                remainingCredits: 120,
                usdValue: 4.8
            ),
            fetchedAt: Date()
        )
        let store = UsageStore(
            providers: [
                SequencedProvider(id: .codex, results: [.success(snapshot)])
            ],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.codex]
            )
        )

        await store.refresh()

        XCTAssertEqual(
            store.availableMenuBarItems(for: .codex),
            [
                MenuBarItemID(provider: .codex, metric: .weekly),
                MenuBarItemID(provider: .codex, metric: .spark),
                MenuBarItemID(provider: .codex, metric: .sparkWeekly)
            ]
        )
        XCTAssertFalse(store.isMenuBarItemAvailable(
            MenuBarItemID(provider: .codex, metric: .session)
        ))
        XCTAssertNil(store.menuBarReading(for: MenuBarItemID(provider: .codex, metric: .credits)))
    }

    func testMissingToolIsNeitherFetchedNorShown() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()
        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()

        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 0)
        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertFalse(store.isProviderVisibleInDashboard(.codex))
        XCTAssertEqual(
            store.menuBarReadings(for: [
                MenuBarItemID(provider: .claude, metric: .session),
                MenuBarItemID(provider: .codex, metric: .session)
            ]).map(\.provider),
            [.claude]
        )
        XCTAssertEqual(
            store.menuBarProviderReadings(
                for: [
                    MenuBarProviderConfiguration(
                        provider: .claude,
                        metrics: [.session]
                    ),
                    MenuBarProviderConfiguration(
                        provider: .codex,
                        metrics: [.session]
                    )
                ]
            ).map(\.provider),
            [.claude]
        )
    }

    func testWeeklyDefaultsRenderOnlyInstalledProviders() async {
        let installCombinations: [Set<ProviderID>] = [
            [],
            [.claude],
            [.codex],
            [.claude, .codex]
        ]

        for installedProviders in installCombinations {
            let claude = CountingProvider(
                id: .claude,
                result: .success(snapshot(
                    provider: .claude,
                    session: 20,
                    weekly: 35
                ))
            )
            let codex = CountingProvider(
                id: .codex,
                result: .success(snapshot(
                    provider: .codex,
                    session: 81,
                    weekly: 42
                ))
            )
            let store = UsageStore(
                providers: [claude, codex],
                availabilityChecker: FixedProviderAvailabilityChecker(
                    installed: installedProviders
                )
            )

            await store.refresh()

            let suiteName =
                "UsageStoreTests.installation.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            let preferences = AppPreferences(defaults: defaults)
            preferences.configureDefaultMenuBarProviders(
                availableItemsByProvider:
                    store.availableMenuBarItemsByProvider
            )

            XCTAssertEqual(
                preferences.selectedMenuBarMetrics(for: .claude),
                [.weekly]
            )
            XCTAssertEqual(
                preferences.selectedMenuBarMetrics(for: .codex),
                [.weekly]
            )
            XCTAssertEqual(
                store.menuBarProviderReadings(
                    for: preferences.menuBarProviderConfigurations
                ).map(\.provider),
                ProviderID.allCases.filter(installedProviders.contains)
            )
            for provider in ProviderID.allCases {
                XCTAssertEqual(
                    store.isProviderVisibleInDashboard(provider),
                    installedProviders.contains(provider)
                )
            }
            let claudeFetches = await claude.fetchCallCount()
            let codexFetches = await codex.fetchCallCount()
            XCTAssertEqual(
                claudeFetches,
                installedProviders.contains(.claude) ? 1 : 0
            )
            XCTAssertEqual(
                codexFetches,
                installedProviders.contains(.codex) ? 1 : 0
            )

            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    func testUntrackedProviderIsNeitherFetchedNorShown() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(),
            trackedProviderIDs: [.claude]
        )

        await store.refresh()
        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()

        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 0)
        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertFalse(store.isProviderVisibleInDashboard(.codex))
    }

    func testEnablingTrackingRefreshesOnlyTheNewProvider() async {
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(
                provider: .claude,
                session: 20,
                weekly: 35
            ))
        )
        let codex = CountingProvider(
            id: .codex,
            result: .success(snapshot(
                provider: .codex,
                session: 81,
                weekly: 42
            ))
        )
        let store = UsageStore(
            providers: [claude, codex],
            availabilityChecker: FixedProviderAvailabilityChecker(),
            trackedProviderIDs: [.claude]
        )
        store.start()
        await store.refresh()

        store.setTrackedProviders([.claude, .codex])
        await Task.yield()
        await store.refresh(providerIDs: [.codex])

        let claudeFetches = await claude.fetchCallCount()
        let codexFetches = await codex.fetchCallCount()
        XCTAssertEqual(claudeFetches, 1)
        XCTAssertEqual(codexFetches, 1)
        store.stop()
    }

    func testInstalledButLoggedOutProviderRemainsVisible() async {
        let store = UsageStore(
            providers: [
                SequencedProvider(
                    id: .claude,
                    results: [.failure(ProviderFailure(
                        .authentication,
                        "Not logged in. Run `claude` to authenticate."
                    ))]
                )
            ],
            availabilityChecker: FixedProviderAvailabilityChecker(
                installed: [.claude]
            )
        )

        await store.refresh()

        XCTAssertTrue(store.isProviderVisibleInDashboard(.claude))
        XCTAssertEqual(
            store.states[.claude]?.failure?.kind,
            .authentication
        )
        XCTAssertEqual(
            store.menuBarProviderReadings(
                for: [
                    MenuBarProviderConfiguration(
                        provider: .claude,
                        metrics: [.session]
                    )
                ]
            ),
            [
                MenuBarProviderReadings(
                    provider: .claude,
                    selectedMetrics: [.session],
                    readings: []
                )
            ]
        )
    }

    func testRefreshIntervalCanBeChangedWithoutRecreatingTheStore() {
        let store = UsageStore(
            providers: [],
            availabilityChecker: FixedProviderAvailabilityChecker()
        )

        XCTAssertEqual(store.refreshInterval, .fiveMinutes)

        store.setRefreshInterval(.thirtyMinutes)

        XCTAssertEqual(store.refreshInterval, .thirtyMinutes)
    }

    func testRemainingUsageIsBoundedToARealPercentage() {
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: 62),
            38
        )
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: 140),
            0
        )
        XCTAssertEqual(
            UsageDisplayMode.remaining.displayedPercent(from: -10),
            100
        )
    }

    func testRemainingUsageIsTheFirstAndDefaultDisplayOption() {
        XCTAssertEqual(UsageDisplayMode.defaultSelection, .remaining)
        XCTAssertEqual(UsageDisplayMode.allCases, [.remaining, .used])
    }

    func testCompletedProviderPublishesWhileAnotherWaitsForPermission() async throws {
        let newest = Date(timeIntervalSince1970: 1_800_000_000)
        let fastSnapshot = ProviderSnapshot(provider: .codex, planName: "Test", windows: [], fetchedAt: newest)
        let slowSnapshot = ProviderSnapshot(provider: .buddy, planName: "Test", windows: [], fetchedAt: newest.addingTimeInterval(-10))
        let waiting = PermissionWaitingProvider(snapshot: slowSnapshot)
        let store = UsageStore(providers: [SequencedProvider(id: .codex, results: [.success(fastSnapshot)]), waiting],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.codex, .buddy]))
        let refresh = Task { await store.refresh() }
        for _ in 0..<200 where store.states[.codex]?.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.states[.codex]?.snapshot, fastSnapshot)
        XCTAssertEqual(store.states[.codex]?.isRefreshing, false)
        XCTAssertEqual(store.states[.buddy]?.isRefreshing, true)
        XCTAssertNil(store.states[.buddy]?.snapshot)
        await waiting.release()
        await refresh.value
        XCTAssertEqual(store.states[.buddy]?.snapshot, slowSnapshot)
        XCTAssertEqual(store.lastSuccessfulRefreshAt, newest, "A later completion of older data must not move the timestamp backwards")
    }

    func testReconnectingDiscardsAResultFromThePreviousSource() async throws {
        let old = ProviderSnapshot(provider: .buddy, planName: "Old", windows: [], fetchedAt: Date())
        let current = ProviderSnapshot(provider: .buddy, planName: "New", windows: [], fetchedAt: Date())
        let waiting = PermissionWaitingProvider(snapshot: old, subsequent: current)
        let store = UsageStore(providers: [waiting], availabilityChecker: FixedProviderAvailabilityChecker(installed: [.buddy]))
        let previousRefresh = Task { await store.refresh() }
        for _ in 0..<200 {
            if await waiting.hasStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.reconnect(providerIDs: [.buddy])
        for _ in 0..<200 where store.states[.buddy]?.snapshot == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.states[.buddy]?.snapshot, current)
        await waiting.release()
        await previousRefresh.value
        XCTAssertEqual(store.states[.buddy]?.snapshot, current)
        store.stop()
    }

    @MainActor
    func testMenuBarReadingsMarkAtRiskSessionsAndClearPastReset() async {
        let now = Date()
        let start = now.addingTimeInterval(-2 * 3_600)
        let reset = now.addingTimeInterval(3 * 3_600)
        let provider = SequencedProvider(
            id: .claude,
            results: [.success(ProviderSnapshot(
                provider: .claude,
                planName: "Max",
                windows: [
                    QuotaWindow(
                        kind: .session,
                        usedPercent: 80,
                        resetsAt: reset,
                        startsAt: start
                    ),
                    QuotaWindow(
                        kind: .weekly,
                        usedPercent: 80,
                        resetsAt: now.addingTimeInterval(5 * 86_400),
                        startsAt: now.addingTimeInterval(-2 * 86_400)
                    )
                ],
                fetchedAt: now
            ))]
        )
        let store = UsageStore(
            providers: [provider],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.claude]),
            trackedProviderIDs: [.claude]
        )

        await store.refresh()

        let readings = store.menuBarReadings(
            for: [
                MenuBarItemID(provider: .claude, metric: .session),
                MenuBarItemID(provider: .claude, metric: .weekly)
            ]
        )
        XCTAssertEqual(readings.map(\.isAtRisk), [true, false])
    }

    func testRefreshProviderReloadsOnlyTargetProviderAndClearsStaleFailure() async {
        let firstBuddy = snapshot(provider: .buddy, session: 30, weekly: 50)
        let refreshedBuddy = snapshot(provider: .buddy, session: 45, weekly: 60)
        let buddy = SequencedProvider(
            id: .buddy,
            results: [
                .success(firstBuddy),
                .failure(ProviderFailure(.transient, "Buddy could not be reached.")),
                .success(refreshedBuddy)
            ]
        )
        let claude = CountingProvider(
            id: .claude,
            result: .success(snapshot(provider: .claude, session: 20, weekly: 35))
        )
        let store = UsageStore(
            providers: [buddy, claude],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.buddy, .claude]),
            trackedProviderIDs: [.buddy, .claude]
        )

        await store.refresh()
        await store.refresh()
        XCTAssertTrue(store.states[.buddy]?.isStale == true)
        let claudeCallsBeforeReload = await claude.fetchCallCount()
        XCTAssertEqual(claudeCallsBeforeReload, 2)

        await store.refresh(provider: .buddy)

        let claudeCallsAfterReload = await claude.fetchCallCount()
        XCTAssertEqual(claudeCallsAfterReload, 2)
        XCTAssertFalse(store.states[.buddy]?.isStale == true)
        XCTAssertNil(store.states[.buddy]?.failure)
        XCTAssertEqual(store.states[.buddy]?.snapshot, refreshedBuddy)
    }

    func testRefreshProviderRunsWhileOtherProviderBatchRefreshIsInFlight() async {
        let initialBuddy = snapshot(provider: .buddy, session: 15, weekly: 25)
        let reloadedBuddy = snapshot(provider: .buddy, session: 55, weekly: 65)
        let buddy = SequencedProvider(
            id: .buddy,
            results: [
                .success(initialBuddy),
                .failure(ProviderFailure(.transient, "Buddy could not be reached.")),
                .success(reloadedBuddy)
            ]
        )
        let claudeGate = BlockingProvider(
            id: .claude,
            snapshot: snapshot(provider: .claude, session: 10, weekly: 20)
        )
        let store = UsageStore(
            providers: [buddy, claudeGate],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.buddy, .claude]),
            trackedProviderIDs: [.buddy, .claude]
        )

        await store.refresh()
        XCTAssertEqual(store.states[.buddy]?.snapshot, initialBuddy)

        await claudeGate.setBlocking(true)
        let batchTask = Task { await store.refresh() }
        await claudeGate.waitUntilStarted()
        // Wait until buddy's batch fetch (2nd result: failure) has completed while claude is still blocking.
        while store.states[.buddy]?.failure == nil {
            await Task.yield()
        }

        XCTAssertTrue(store.states[.claude]?.isRefreshing == true)
        XCTAssertFalse(store.states[.buddy]?.isRefreshing == true)
        XCTAssertTrue(store.states[.buddy]?.isStale == true)

        await store.refresh(provider: .buddy)

        XCTAssertNil(store.states[.buddy]?.failure)
        XCTAssertEqual(store.states[.buddy]?.snapshot, reloadedBuddy)
        XCTAssertTrue(store.states[.claude]?.isRefreshing == true)

        // Attempting a single-provider reload for claude while claude is already refreshing must not double-fetch.
        await store.refresh(provider: .claude)
        let claudeStartedCount = await claudeGate.fetchCallCount()
        XCTAssertEqual(claudeStartedCount, 2)

        await claudeGate.release()
        await batchTask.value
        XCTAssertFalse(store.states[.claude]?.isRefreshing == true)
    }

    private func snapshot(
        provider: ProviderID,
        session: Double,
        weekly: Double
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            planName: nil,
            windows: [
                QuotaWindow(
                    kind: .session,
                    usedPercent: session,
                    resetsAt: nil
                ),
                QuotaWindow(
                    kind: .weekly,
                    usedPercent: weekly,
                    resetsAt: nil
                )
            ],
            fetchedAt: Date()
        )
    }
}

private actor PermissionWaitingProvider: UsageProvider {
    nonisolated let id = ProviderID.buddy
    let snapshot: ProviderSnapshot
    let subsequent: ProviderSnapshot?
    var hasStarted = false
    private var continuation: CheckedContinuation<ProviderSnapshot, Never>?
    private var released = false
    init(snapshot: ProviderSnapshot, subsequent: ProviderSnapshot? = nil) { self.snapshot = snapshot; self.subsequent = subsequent }
    func fetch() async throws -> ProviderSnapshot {
        if hasStarted, let subsequent { return subsequent }
        hasStarted = true
        if released { return snapshot }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private actor BlockingProvider: UsageProvider {
    nonisolated let id: ProviderID
    let snapshot: ProviderSnapshot
    private var blocking = false
    private var started = false
    private var callCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var fetchContinuation: CheckedContinuation<ProviderSnapshot, Never>?

    init(id: ProviderID, snapshot: ProviderSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }

    func setBlocking(_ value: Bool) {
        blocking = value
        started = false
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func fetchCallCount() -> Int {
        callCount
    }

    func fetch() async throws -> ProviderSnapshot {
        callCount += 1
        started = true
        startContinuation?.resume()
        startContinuation = nil
        guard blocking else { return snapshot }
        return await withCheckedContinuation { fetchContinuation = $0 }
    }

    func release() {
        blocking = false
        fetchContinuation?.resume(returning: snapshot)
        fetchContinuation = nil
    }
}
