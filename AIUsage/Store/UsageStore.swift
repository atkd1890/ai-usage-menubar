import Foundation
import Observation

struct MenuBarReading: Equatable, Sendable {
    let provider: ProviderID
    let metric: MenuBarMetricID
    let value: MenuBarReadingValue
    let displayMode: UsageDisplayMode
    let isStale: Bool
    /// The session runs out before its reset at its current pace.
    let isAtRisk: Bool
    let isXSubscription: Bool

    init(
        provider: ProviderID,
        metric: MenuBarMetricID,
        value: MenuBarReadingValue,
        displayMode: UsageDisplayMode,
        isStale: Bool,
        isAtRisk: Bool = false,
        isXSubscription: Bool = false
    ) {
        self.provider = provider
        self.metric = metric
        self.value = value
        self.displayMode = displayMode
        self.isXSubscription = isXSubscription
        self.isStale = isStale
        self.isAtRisk = isAtRisk
    }
}

struct MenuBarProviderReadings: Equatable, Identifiable, Sendable {
    let provider: ProviderID
    let selectedMetrics: [MenuBarMetricID]
    let readings: [MenuBarReading]
    var isXSubscription = false

    var id: ProviderID { provider }
    var showsMetricLabels: Bool { readings.count > 1 }
}

@MainActor
@Observable
final class UsageStore {
    var alertController: UsageAlertController?
    let analytics: TokenAnalytics
    let history: UsageHistory
    private(set) var states: [ProviderID: ProviderState]
    private(set) var installedProviderIDs: Set<ProviderID>?
    private(set) var trackedProviderIDs: Set<ProviderID>
    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var refreshInterval: RefreshIntervalOption

    private let providers: [any UsageProvider]
    private let availabilityChecker: any ProviderAvailabilityChecking
    private var cadenceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var providerRefreshTasks: [ProviderID: Task<Void, Never>] = [:]
    private var refreshGeneration = 0
    private var providerRefreshGenerations: [ProviderID: Int] = [:]
    private var batchRefreshID = 0

    init(
        providers: [any UsageProvider]? = nil,
        history: UsageHistory? = nil,
        analytics: TokenAnalytics? = nil,
        availabilityChecker: any ProviderAvailabilityChecking =
            SystemProviderAvailabilityChecker(),
        refreshInterval: RefreshIntervalOption = .fiveMinutes,
        trackedProviderIDs: Set<ProviderID> = Set(ProviderID.allCases)
    ) {
        self.analytics = analytics ?? TokenAnalytics(enabled: false)
        self.history = history ?? UsageHistory()
        self.providers = providers ?? Self.defaultProviders()
        self.availabilityChecker = availabilityChecker
        self.refreshInterval = refreshInterval
        self.trackedProviderIDs = trackedProviderIDs
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderState(provider: $0))
        })
    }

    private static func defaultProviders() -> [any UsageProvider] {
        let google = GoogleAISession()
        return [CredentialSelectingProvider(local: ClaudeProvider(identity: AccountIdentityClient())), CredentialSelectingProvider(local: CodexProvider()),
                CredentialSelectingProvider(local: CursorProvider(identity: AccountIdentityClient())),
                ConsumerQuotaProvider(id: .manus), ConsumerQuotaProvider(id: .kimi), MuseProvider(), QwenProvider(), AdobeProvider(),
                MiniMaxProvider(), QoderProvider(), DolaProvider(), ZAIProvider(), BuddyProvider(),
                AntigravityDesktopProvider(), CopilotProvider(method: { .selected(for: .copilot) }, identity: AccountIdentityClient()),
                GeminiProvider(native: GeminiNativeProvider(session: google), identity: AccountIdentityClient(), mediaCredits: GoogleFlowCredits())]
    }

    func start() {
        guard cadenceTask == nil else { return }
        LoginShellEnvironment.shared.prewarm()
        cadenceTask = makeCadenceTask(refreshImmediately: true)
    }

    func stop() {
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
        for provider in ProviderID.allCases {
            states[provider]?.isRefreshing = false
        }
    }

    func setTrackedProviders(_ providers: Set<ProviderID>) {
        guard trackedProviderIDs != providers else { return }

        let newlyEnabled = providers.subtracting(trackedProviderIDs)
        trackedProviderIDs = providers
        for provider in ProviderID.allCases where !providers.contains(provider) {
            providerRefreshTasks.removeValue(forKey: provider)?.cancel()
            providerRefreshGenerations[provider, default: 0] += 1
            states[provider]?.isRefreshing = false
        }

        guard cadenceTask != nil else { return }
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
        cadenceTask = makeCadenceTask(
            refreshImmediately: !newlyEnabled.isEmpty,
            initialProviderIDs: newlyEnabled.isEmpty ? nil : newlyEnabled
        )
    }

    func setRefreshInterval(_ interval: RefreshIntervalOption) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval

        guard cadenceTask != nil else { return }
        cadenceTask?.cancel()
        cadenceTask = makeCadenceTask(refreshImmediately: false)
    }

    /// A new source must not inherit a Connected badge or quota from the old source.
    func reconnect(providerIDs: Set<ProviderID>) {
        for id in providerIDs {
            states[id]?.snapshot = nil
            states[id]?.failure = nil
            states[id]?.isRefreshing = trackedProviderIDs.contains(id)
        }
        refreshNow()
    }

    func refreshNow() {
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
        cadenceTask = makeCadenceTask(refreshImmediately: true)
    }

    func refreshProvider(_ providerID: ProviderID) {
        Task { [weak self] in
            await self?.refresh(provider: providerID)
        }
    }

    func refresh(provider providerID: ProviderID) async {
        if let existing = providerRefreshTasks[providerID] {
            await existing.value
            return
        }

        guard providerID.isEnabledInBuild,
              trackedProviderIDs.contains(providerID),
              states[providerID]?.isToolInstalled != false,
              states[providerID]?.isRefreshing != true,
              let provider = providers.first(where: { $0.id == providerID }) else {
            return
        }

        let globalGeneration = refreshGeneration
        let providerGeneration = providerRefreshGenerations[providerID, default: 0] + 1
        providerRefreshGenerations[providerID] = providerGeneration
        states[providerID]?.isRefreshing = true

        let task = Task { [weak self] in
            let result = await Self.fetchResult(for: provider)
            guard let self else { return }
            guard !Task.isCancelled,
                  self.refreshGeneration == globalGeneration,
                  self.providerRefreshGenerations[providerID] == providerGeneration else {
                if self.refreshGeneration == globalGeneration,
                   self.providerRefreshGenerations[providerID] == providerGeneration {
                    self.states[providerID]?.isRefreshing = false
                }
                return
            }
            self.applyFetchResults([result])
        }
        providerRefreshTasks[providerID] = task
        await task.value
        if refreshGeneration == globalGeneration,
           providerRefreshGenerations[providerID] == providerGeneration {
            providerRefreshTasks.removeValue(forKey: providerID)
        }
    }

    func refresh(providerIDs requestedProviderIDs: Set<ProviderID>? = nil) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        batchRefreshID += 1
        let currentBatchID = batchRefreshID
        let generation = refreshGeneration
        let providers = self.providers
        let trackedProviderIDs = self.trackedProviderIDs
        let availabilityChecker = self.availabilityChecker
        let task = Task { [weak self] in
            let installedProviders =
                await availabilityChecker.installedProviders()
            guard !Task.isCancelled else { return }

            self?.applyInstalledProviders(installedProviders)

            let requested = requestedProviderIDs ?? trackedProviderIDs
            let effectiveProviders = providers.filter { provider in
                provider.id.isEnabledInBuild &&
                    trackedProviderIDs.contains(provider.id) &&
                    requested.contains(provider.id) &&
                    (installedProviders?.contains(provider.id) ?? true)
            }

            var expectedProviderGenerations: [ProviderID: Int] = [:]
            for provider in effectiveProviders {
                self?.providerRefreshTasks.removeValue(forKey: provider.id)?.cancel()
                let nextGeneration = (self?.providerRefreshGenerations[provider.id] ?? 0) + 1
                self?.providerRefreshGenerations[provider.id] = nextGeneration
                expectedProviderGenerations[provider.id] = nextGeneration
                self?.states[provider.id]?.isRefreshing = true
            }

            await withTaskGroup(
                of: FetchResult.self
            ) { group in
                for provider in effectiveProviders {
                    group.addTask {
                        await Self.fetchResult(for: provider)
                    }
                }

                for await result in group {
                    guard !Task.isCancelled,
                          self?.refreshGeneration == generation,
                          self?.providerRefreshGenerations[result.provider] == expectedProviderGenerations[result.provider] else {
                        continue
                    }
                    self?.applyFetchResults([result])
                }
            }
        }
        refreshTask = task
        await task.value
        if currentBatchID == batchRefreshID {
            refreshTask = nil
        }
    }

    private static func fetchResult(for provider: any UsageProvider) async -> FetchResult {
        do {
            return FetchResult(
                provider: provider.id,
                result: .success(try await provider.fetch())
            )
        } catch let failure as ProviderFailure {
            return FetchResult(
                provider: provider.id,
                result: .failure(failure)
            )
        } catch {
            return FetchResult(
                provider: provider.id,
                result: .failure(ProviderFailure(
                    .transient,
                    "\(provider.id.displayName) could not be refreshed."
                ))
            )
        }
    }

    func isProviderVisibleInDashboard(_ provider: ProviderID) -> Bool {
        provider.isEnabledInBuild && trackedProviderIDs.contains(provider) &&
            states[provider]?.isToolInstalled != false
    }

    func availableMenuBarItems(
        for provider: ProviderID
    ) -> [MenuBarItemID] {
        guard provider.isEnabledInBuild, trackedProviderIDs.contains(provider),
              states[provider]?.isToolInstalled != false else {
            return []
        }
        return states[provider]?.snapshot?.availableMenuBarItems ?? []
    }

    var availableMenuBarItemsByProvider:
        [ProviderID: [MenuBarItemID]] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, availableMenuBarItems(for: $0))
        })
    }

    func isMenuBarItemAvailable(_ item: MenuBarItemID) -> Bool {
        availableMenuBarItems(for: item.provider).contains(item)
    }

    func menuBarReadings(
        for items: [MenuBarItemID],
        displayMode: UsageDisplayMode = .used
    ) -> [MenuBarReading] {
        let now = Date()
        return items.compactMap { item in
            guard item.provider.isEnabledInBuild, trackedProviderIDs.contains(item.provider),
                  let state = states[item.provider],
                  state.isToolInstalled != false,
                  let value = state.snapshot?.menuBarValue(
                    for: item.metric,
                    displayMode: displayMode
                  ) else {
                return nil
            }

            return MenuBarReading(
                provider: item.provider,
                metric: item.metric,
                value: value,
                displayMode: displayMode,
                isStale: state.isStale,
                isAtRisk: state.snapshot?.isAtRisk(item.metric, now: now) ?? false,
                isXSubscription: state.snapshot?.xSubscription != nil
            )
        }
    }

    func menuBarProviderReadings(
        for configurations: [MenuBarProviderConfiguration],
        displayMode: UsageDisplayMode = .used
    ) -> [MenuBarProviderReadings] {
        configurations.compactMap { configuration in
            guard configuration.provider.isEnabledInBuild, trackedProviderIDs.contains(configuration.provider),
                  let state = states[configuration.provider],
                  state.isToolInstalled != false else {
                return nil
            }

            let items = configuration.metrics.map {
                MenuBarItemID(
                    provider: configuration.provider,
                    metric: $0
                )
            }
            var readings = menuBarReadings(
                for: items,
                displayMode: displayMode
            )
            // Selected metrics can vanish from the live snapshot (for
            // example, Claude accounts without a five-hour window return
            // `five_hour: null`). Show the provider's default metric rather
            // than nothing, without touching the saved selection.
            if readings.isEmpty,
               let fallback = AppPreferences.defaultMenuBarItem(
                   for: configuration.provider,
                   in: availableMenuBarItems(for: configuration.provider)
               ) {
                readings = menuBarReadings(
                    for: [fallback],
                    displayMode: displayMode
                )
            }
            return MenuBarProviderReadings(
                provider: configuration.provider,
                selectedMetrics: configuration.metrics,
                readings: readings,
                isXSubscription: states[configuration.provider]?.snapshot?.xSubscription != nil
            )
        }
    }

    func menuBarReading(
        for item: MenuBarItemID,
        displayMode: UsageDisplayMode = .used
    ) -> MenuBarReading? {
        menuBarReadings(for: [item], displayMode: displayMode).first
    }

    private func applyInstalledProviders(_ installedProviders: Set<ProviderID>?) {
        installedProviderIDs = installedProviders
        guard let installedProviders else { return }

        for provider in ProviderID.allCases {
            states[provider]?.isToolInstalled =
                installedProviders.contains(provider)
            if !installedProviders.contains(provider) {
                states[provider]?.isRefreshing = false
            }
        }
    }

    private func applyFetchResults(_ fetchResults: [FetchResult]) {
        lastAttemptAt = Date()
        var successfulDates: [Date] = []

        for fetchResult in fetchResults {
            guard trackedProviderIDs.contains(fetchResult.provider) else {
                continue
            }

            var state =
                states[fetchResult.provider] ??
                ProviderState(provider: fetchResult.provider)
            state.isRefreshing = false
            switch fetchResult.result {
            case .success(let snapshot):
                state.snapshot = snapshot
                history.record(snapshot)
                alertController?.receive(snapshot)
                state.failure = nil
                successfulDates.append(snapshot.fetchedAt)
            case .failure(let failure):
                if !failure.preservesLastGood {
                    state.snapshot = nil
                }
                state.failure = failure
            }
            states[fetchResult.provider] = state
        }

        if let latest = successfulDates.max() {
            lastSuccessfulRefreshAt = max(lastSuccessfulRefreshAt ?? latest, latest)
        }
    }

    private func cancelRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
        for (_, task) in providerRefreshTasks {
            task.cancel()
        }
        providerRefreshTasks.removeAll()
    }

    private func makeCadenceTask(
        refreshImmediately: Bool,
        initialProviderIDs: Set<ProviderID>? = nil
    ) -> Task<Void, Never> {
        let duration = refreshInterval.duration
        return Task { [weak self, duration] in
            if refreshImmediately {
                await self?.refresh(providerIDs: initialProviderIDs)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

private struct FetchResult: Sendable {
    let provider: ProviderID
    let result: Result<ProviderSnapshot, ProviderFailure>
}
