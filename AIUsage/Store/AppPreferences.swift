import Foundation
import Observation

@MainActor
@Observable
final class AppPreferences {
    private(set) var trackedProviderIDs: Set<ProviderID> {
        didSet {
            Self.store(trackedProviderIDs, in: defaults)
        }
    }

    private(set) var visibleMenuBarProviderIDs: Set<ProviderID> {
        didSet {
            defaults.set(
                Self.encode(Array(visibleMenuBarProviderIDs).sorted {
                    $0.rawValue < $1.rawValue
                }),
                forKey: Key.visibleMenuBarProviderIDs
            )
        }
    }

    private(set) var menuBarMetricSelections:
        [ProviderID: [MenuBarMetricID]] {
        didSet {
            defaults.set(
                Self.encode(menuBarMetricSelections),
                forKey: Key.menuBarMetricSelections
            )
        }
    }

    /// User-chosen display order of providers. Always contains every
    /// `ProviderID` exactly once.
    private(set) var providerOrder: [ProviderID] {
        didSet {
            defaults.set(
                Self.encode(providerOrder),
                forKey: Key.providerOrder
            )
        }
    }

    private(set) var hasConfiguredMenuBar: Bool {
        didSet {
            defaults.set(
                hasConfiguredMenuBar,
                forKey: Key.hasConfiguredMenuBar
            )
        }
    }

    private(set) var hasCompletedInitialSetup: Bool {
        didSet {
            defaults.set(
                hasCompletedInitialSetup,
                forKey: Key.hasCompletedInitialSetup
            )
        }
    }

    var geminiSource: GeminiCredentialSource {
        didSet { defaults.set(geminiSource.rawValue, forKey: GeminiCredentialSource.preferenceKey) }
    }
    var geminiNativeAccessAllowed: Bool {
        didSet { defaults.set(geminiNativeAccessAllowed, forKey: GeminiNativeAuthStore.accessKey) }
    }
    var geminiEdgeCookiesAllowed: Bool {
        didSet { defaults.set(geminiEdgeCookiesAllowed, forKey: GeminiCredentialSource.edge.accessKey) }
    }
    var geminiCredentialAccessAllowed: Bool {
        get {
            switch geminiSource {
            case .nativeApp: geminiNativeAccessAllowed
            case .edge: geminiEdgeCookiesAllowed
            case .chrome: geminiChromeCookiesAllowed
            case .nativeAppEdge: geminiNativeAccessAllowed && geminiEdgeCookiesAllowed
            case .nativeAppChrome: geminiNativeAccessAllowed && geminiChromeCookiesAllowed
            }
        }
        set {
            switch geminiSource {
            case .nativeApp: geminiNativeAccessAllowed = newValue
            case .edge: geminiEdgeCookiesAllowed = newValue
            case .chrome: geminiChromeCookiesAllowed = newValue
            case .nativeAppEdge: geminiNativeAccessAllowed = newValue; geminiEdgeCookiesAllowed = newValue
            case .nativeAppChrome: geminiNativeAccessAllowed = newValue; geminiChromeCookiesAllowed = newValue
            }
        }
    }

    var geminiChromeCookiesAllowed: Bool {
        didSet { defaults.set(geminiChromeCookiesAllowed, forKey: GeminiAuthStore.cookieAccessKey) }
    }

    let alerts: AlertPreferences

    var selectedRegion: ProviderRegion {
        didSet {
            defaults.set(selectedRegion.rawValue, forKey: Key.selectedRegion)
        }
    }

    var usageDisplayMode: UsageDisplayMode {
        didSet {
            defaults.set(usageDisplayMode.rawValue, forKey: Key.usageDisplayMode)
        }
    }

    var refreshInterval: RefreshIntervalOption {
        didSet {
            defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        }
    }

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let pendingMenuBarItems: [MenuBarItemID]?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alerts = AlertPreferences(defaults: defaults)
        geminiSource = GeminiCredentialSource.resolved(in: defaults)
        geminiNativeAccessAllowed = defaults.bool(forKey: GeminiNativeAuthStore.accessKey)
        geminiEdgeCookiesAllowed = defaults.bool(forKey: GeminiCredentialSource.edge.accessKey)
        geminiChromeCookiesAllowed = defaults.bool(forKey: GeminiAuthStore.cookieAccessKey)

        providerOrder = Self.normalizedOrder(
            Self.decodeProviderList(
                forKey: Key.providerOrder,
                in: defaults
            ) ?? []
        )

        let restoredProviders = Self.decodeProviderList(
            forKey: Key.trackedProviderIDs,
            in: defaults
        )
        var initialTrackedProviders = Set(
            restoredProviders ?? ProviderID.allCases
        )
        if let restoredProviders {
            let restored = Set(restoredProviders)
            // Before 0.3.1 seeded providers stayed only in memory, so a
            // relaunch dropped them. Seed them again once if they were lost.
            let canRestore =
                defaults.object(forKey: Key.seededProvidersRestored) == nil
            if defaults.object(forKey: Key.openUsageProvidersAdded) == nil ||
                (canRestore && restored.isDisjoint(with: Self.openUsageProviders)) {
                initialTrackedProviders.formUnion(Self.openUsageProviders)
            }
            if defaults.object(forKey: Key.geminiProviderAdded) == nil {
                initialTrackedProviders.insert(.gemini)
            }
        }
        if defaults.object(forKey: "consumerProvidersAdded.v1") == nil {
            initialTrackedProviders.formUnion([.manus, .kimi])
            defaults.set(true, forKey: "consumerProvidersAdded.v1")
        }
        if defaults.object(forKey: "museProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.muse)
            defaults.set(true, forKey: "museProviderAdded.v1")
        }
        if defaults.object(forKey: "qwenProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.qwen)
            defaults.set(true, forKey: "qwenProviderAdded.v1")
        }
        if defaults.object(forKey: "adobeProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.adobe)
            defaults.set(true, forKey: "adobeProviderAdded.v1")
        }
        if defaults.object(forKey: "minimaxProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.minimax)
            defaults.set(true, forKey: "minimaxProviderAdded.v1")
        }
        if defaults.object(forKey: "qoderProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.qoder)
            defaults.set(true, forKey: "qoderProviderAdded.v1")
        }
        if defaults.object(forKey: "buddyProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.buddy)
            defaults.set(true, forKey: "buddyProviderAdded.v1")
        }
        if defaults.object(forKey: "zaiProviderAdded.v2") == nil {
            initialTrackedProviders.insert(.zai)
            defaults.set(true, forKey: "zaiProviderAdded.v2")
        }
        if defaults.object(forKey: "dolaProviderAdded.v1") == nil {
            initialTrackedProviders.insert(.dola)
            defaults.set(true, forKey: "dolaProviderAdded.v1")
        }
        trackedProviderIDs = initialTrackedProviders
        // Property observers do not run in an initializer.
        if restoredProviders.map(Set.init) != initialTrackedProviders {
            Self.store(initialTrackedProviders, in: defaults)
        }
        defaults.set(true, forKey: Key.openUsageProvidersAdded)
        defaults.set(true, forKey: Key.seededProvidersRestored)
        defaults.set(true, forKey: Key.geminiProviderAdded)

        let storedVisibleProviders = Self.decodeProviderList(
            forKey: Key.visibleMenuBarProviderIDs,
            in: defaults
        )
        let storedMetricSelections = Self.decode(
            [ProviderID: [MenuBarMetricID]].self,
            forKey: Key.menuBarMetricSelections,
            in: defaults
        )
        let storedConfigurationFlag =
            defaults.object(forKey: Key.hasConfiguredMenuBar) as? Bool

        let currentItems = Self.decode(
            [MenuBarItemID].self,
            forKey: Key.currentMenuBarItems,
            in: defaults
        )
        let currentConfigurationFlag =
            defaults.object(forKey: Key.currentConfiguredMenuBarItems) as? Bool
        let previousItems = Self.decode(
            [MenuBarItemID].self,
            forKey: Key.previousMenuBarItems,
            in: defaults
        )
        let previousConfigurationFlag =
            defaults.object(forKey: Key.previousConfiguredMenuBarItems) as? Bool
        let hasLegacyInstallation = Self.hasLegacyInstallation(in: defaults)

        if storedConfigurationFlag == true ||
            storedVisibleProviders != nil ||
            storedMetricSelections != nil {
            visibleMenuBarProviderIDs = Set(
                storedVisibleProviders ?? []
            ).intersection(ProviderID.allCases)
            menuBarMetricSelections = Self.sanitizedSelections(
                storedMetricSelections ?? [:]
            )
            hasConfiguredMenuBar = true
            pendingMenuBarItems = nil
        } else if currentConfigurationFlag == true || currentItems != nil {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = Self.unique(currentItems ?? [])
        } else if previousConfigurationFlag == true || previousItems != nil {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = Self.unique(previousItems ?? [])
        } else if hasLegacyInstallation {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = nil
        } else {
            visibleMenuBarProviderIDs = []
            menuBarMetricSelections = [:]
            hasConfiguredMenuBar = false
            pendingMenuBarItems = nil
        }

        if let storedCompletion =
            defaults.object(forKey: Key.hasCompletedInitialSetup) as? Bool {
            hasCompletedInitialSetup = storedCompletion
        } else {
            hasCompletedInitialSetup = hasLegacyInstallation
        }

        selectedRegion = Self.value(
            ProviderRegion.self,
            forKey: Key.selectedRegion,
            in: defaults
        ) ?? .defaultSelection
        usageDisplayMode = Self.value(
            UsageDisplayMode.self,
            forKey: Key.usageDisplayMode,
            in: defaults
        ) ?? .defaultSelection
        refreshInterval = Self.value(
            RefreshIntervalOption.self,
            forKey: Key.refreshInterval,
            in: defaults
        ) ?? .fiveMinutes

        if hasLegacyInstallation &&
            defaults.object(forKey: Key.hasCompletedInitialSetup) == nil {
            defaults.set(true, forKey: Key.hasCompletedInitialSetup)
        }

        if defaults.object(forKey: Key.qoderCreditsMetricMigrated) == nil {
            if let qoderMetrics = menuBarMetricSelections[.qoder],
               qoderMetrics.contains(.weekly) {
                var migrated: [MenuBarMetricID] = []
                for metric in qoderMetrics {
                    let mapped: MenuBarMetricID = metric == .weekly ? .credits : metric
                    if !migrated.contains(mapped) {
                        migrated.append(mapped)
                    }
                }
                menuBarMetricSelections[.qoder] = migrated
                defaults.set(
                    Self.encode(menuBarMetricSelections),
                    forKey: Key.menuBarMetricSelections
                )
            }
            defaults.set(true, forKey: Key.qoderCreditsMetricMigrated)
        }
    }

    var menuBarProviderConfigurations: [MenuBarProviderConfiguration] {
        providerOrder.compactMap { provider in
            guard visibleMenuBarProviderIDs.contains(provider) else {
                return nil
            }
            return MenuBarProviderConfiguration(
                provider: provider,
                metrics: selectedMenuBarMetrics(for: provider)
            )
        }
    }

    /// Moves `provider` to the position currently held by `target`.
    func moveProvider(_ provider: ProviderID, to target: ProviderID) {
        guard provider != target,
              let source = providerOrder.firstIndex(of: provider),
              let destination = providerOrder.firstIndex(of: target)
        else { return }
        var order = providerOrder
        order.remove(at: source)
        order.insert(provider, at: destination)
        providerOrder = order
    }

    /// Moves `provider` up (negative) or down (positive) by `offset` places,
    /// stopping at either end of the list.
    func moveProvider(_ provider: ProviderID, by offset: Int) {
        guard let index = providerOrder.firstIndex(of: provider) else { return }
        let destination = min(max(index + offset, 0), providerOrder.count - 1)
        moveProvider(provider, to: providerOrder[destination])
    }

    /// Drops duplicates, then appends providers the stored order does not
    /// know about (for example ones added by an app update) in their default
    /// order.
    static func normalizedOrder(_ stored: [ProviderID]) -> [ProviderID] {
        var seen: Set<ProviderID> = []
        let kept = stored.filter { seen.insert($0).inserted }
        return kept + ProviderID.allCases.filter { !seen.contains($0) }
    }

    func isTracking(_ provider: ProviderID) -> Bool {
        trackedProviderIDs.contains(provider)
    }

    func setTracking(_ enabled: Bool, for provider: ProviderID) {
        if enabled {
            trackedProviderIDs.insert(provider)
        } else {
            trackedProviderIDs.remove(provider)
            visibleMenuBarProviderIDs.remove(provider)
        }
    }

    func isProviderShownInMenuBar(_ provider: ProviderID) -> Bool {
        visibleMenuBarProviderIDs.contains(provider)
    }

    func selectedMenuBarMetrics(
        for provider: ProviderID
    ) -> [MenuBarMetricID] {
        menuBarMetricSelections[provider] ?? []
    }

    func isMenuBarMetricSelected(_ item: MenuBarItemID) -> Bool {
        selectedMenuBarMetrics(for: item.provider).contains(item.metric)
    }

    func setMenuBarVisibility(
        _ enabled: Bool,
        for provider: ProviderID,
        availableItems: [MenuBarItemID]
    ) {
        if enabled {
            guard trackedProviderIDs.contains(provider) else { return }

            if selectedMenuBarMetrics(for: provider).isEmpty {
                guard let defaultMetric = Self.defaultMenuBarItem(
                    for: provider,
                    in: availableItems
                )?.metric else {
                    return
                }
                menuBarMetricSelections[provider] = [defaultMetric]
            }
            visibleMenuBarProviderIDs.insert(provider)
        } else {
            visibleMenuBarProviderIDs.remove(provider)
        }
        hasConfiguredMenuBar = true
    }

    func setMenuBarMetric(
        _ enabled: Bool,
        item: MenuBarItemID,
        availableItems: [MenuBarItemID]
    ) {
        var metrics = selectedMenuBarMetrics(for: item.provider)
        if enabled {
            if !metrics.contains(item.metric) {
                metrics.append(item.metric)
            }
            if trackedProviderIDs.contains(item.provider) {
                visibleMenuBarProviderIDs.insert(item.provider)
            }
        } else {
            metrics.removeAll { $0 == item.metric }
        }

        metrics = Self.orderedMetrics(
            metrics,
            provider: item.provider,
            availableItems: availableItems
        )
        if metrics.isEmpty {
            menuBarMetricSelections.removeValue(forKey: item.provider)
            visibleMenuBarProviderIDs.remove(item.provider)
        } else {
            menuBarMetricSelections[item.provider] = metrics
        }
        hasConfiguredMenuBar = true
    }

    func configureDefaultMenuBarProviders(
        availableItemsByProvider: [ProviderID: [MenuBarItemID]]
    ) {
        guard !hasConfiguredMenuBar else { return }

        let selectedItems: [MenuBarItemID]
        if let pendingMenuBarItems {
            selectedItems = Self.resolve(
                pendingMenuBarItems,
                against: availableItemsByProvider
            )
        } else {
            selectedItems = Self.initialWeeklyMenuBarItems
        }
        applyMenuBarItems(selectedItems)
        hasConfiguredMenuBar = true
    }

    func markInitialSetupCompleted() {
        guard !hasCompletedInitialSetup else { return }
        hasCompletedInitialSetup = true
    }

    private func applyMenuBarItems(_ items: [MenuBarItemID]) {
        var selections: [ProviderID: [MenuBarMetricID]] = [:]
        for provider in ProviderID.allCases {
            let metrics = Self.uniqueMetrics(
                items
                    .filter { $0.provider == provider }
                    .map(\.metric)
            )
            if !metrics.isEmpty {
                selections[provider] = metrics
            }
        }
        menuBarMetricSelections = selections
        visibleMenuBarProviderIDs = Set(selections.keys)
    }

    private static var initialWeeklyMenuBarItems: [MenuBarItemID] {
        [ProviderID.claude, .codex].map {
            MenuBarItemID(
                provider: $0,
                metric: $0.defaultMenuBarMetric
            )
        }
    }

    private static let openUsageProviders: Set<ProviderID> = [
        .cursor,
        .antigravity,
        .copilot
    ]

    private static func hasLegacyInstallation(
        in defaults: UserDefaults
    ) -> Bool {
        [
            Key.menuBarSelection,
            Key.menuBarWindow,
            Key.usageDisplayMode,
            Key.refreshInterval,
            "launchAtLoginDefaultActivationApplied"
        ].contains { defaults.object(forKey: $0) != nil }
    }

    private static func unique(_ items: [MenuBarItemID]) -> [MenuBarItemID] {
        var seen: Set<MenuBarItemID> = []
        return items.filter { seen.insert($0).inserted }
    }

    private static func uniqueMetrics(
        _ metrics: [MenuBarMetricID]
    ) -> [MenuBarMetricID] {
        var seen: Set<MenuBarMetricID> = []
        return metrics.filter { seen.insert($0).inserted }
    }

    private static func sanitizedSelections(
        _ selections: [ProviderID: [MenuBarMetricID]]
    ) -> [ProviderID: [MenuBarMetricID]] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.compactMap {
            provider in
            let metrics = uniqueMetrics(selections[provider] ?? [])
            return metrics.isEmpty ? nil : (provider, metrics)
        })
    }

    private static func orderedMetrics(
        _ selectedMetrics: [MenuBarMetricID],
        provider: ProviderID,
        availableItems: [MenuBarItemID]
    ) -> [MenuBarMetricID] {
        let uniqueSelected = uniqueMetrics(selectedMetrics)
        let availableOrder = uniqueMetrics(
            availableItems
                .filter { $0.provider == provider }
                .map(\.metric)
        )
        let available = availableOrder.filter(uniqueSelected.contains)
        let temporarilyUnavailable = uniqueSelected.filter {
            !availableOrder.contains($0)
        }
        return available + temporarilyUnavailable
    }

    static func defaultMenuBarItem(
        for provider: ProviderID,
        in availableItems: [MenuBarItemID]
    ) -> MenuBarItemID? {
        let providerItems = availableItems.filter {
            $0.provider == provider
        }
        return providerItems.first {
            $0.metric == provider.defaultMenuBarMetric
        } ?? providerItems.first
    }

    private static func resolve(
        _ desiredItems: [MenuBarItemID],
        against availableItemsByProvider: [ProviderID: [MenuBarItemID]]
    ) -> [MenuBarItemID] {
        var resolved: [MenuBarItemID] = []
        for provider in ProviderID.allCases {
            let desiredForProvider = desiredItems.filter {
                $0.provider == provider
            }
            guard !desiredForProvider.isEmpty else { continue }

            let available = availableItemsByProvider[provider] ?? []
            if available.isEmpty {
                resolved.append(contentsOf: desiredForProvider)
                continue
            }
            let desiredSet = Set(desiredForProvider)
            let exactMatches = available.filter(desiredSet.contains)
            if exactMatches.isEmpty {
                if let fallback = defaultMenuBarItem(
                    for: provider,
                    in: available
                ) {
                    resolved.append(fallback)
                }
            } else {
                resolved.append(contentsOf: exactMatches)
            }
        }
        return unique(resolved)
    }

    private static func store(
        _ providers: Set<ProviderID>,
        in defaults: UserDefaults
    ) {
        defaults.set(
            encode(providers.sorted { $0.rawValue < $1.rawValue }),
            forKey: Key.trackedProviderIDs
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? JSONEncoder().encode(value)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func decodeProviderList(
        forKey key: String,
        in defaults: UserDefaults
    ) -> [ProviderID]? {
        guard let data = defaults.data(forKey: key),
              let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return rawValues.compactMap(ProviderID.init(rawValue:))
    }

    private static func value<Value: RawRepresentable>(
        _ type: Value.Type,
        forKey key: String,
        in defaults: UserDefaults
    ) -> Value? where Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return Value(rawValue: rawValue)
    }

    private enum Key {
        static let trackedProviderIDs = "trackedProviderIDs.v1"
        static let visibleMenuBarProviderIDs =
            "menuBarVisibleProviders.v3"
        static let menuBarMetricSelections =
            "menuBarMetricSelections.v3"
        static let providerOrder = "providerOrder.v1"
        static let hasConfiguredMenuBar =
            "menuBarConfigured.v3"
        static let currentMenuBarItems = "menuBarItems.v2"
        static let currentConfiguredMenuBarItems =
            "menuBarItemsConfigured.v2"
        static let previousMenuBarItems = "menuBarItems.v1"
        static let previousConfiguredMenuBarItems =
            "menuBarItemsConfigured.v1"
        static let hasCompletedInitialSetup = "initialSettingsCompleted.v1"
        static let openUsageProvidersAdded =
            "openUsageProvidersAdded.v1"
        static let geminiProviderAdded = "geminiProviderAdded.v1"
        static let seededProvidersRestored = "seededProvidersRestored.v1"
        static let menuBarSelection = "menuBarSelection"
        static let menuBarWindow = "menuBarWindow"
        static let selectedRegion = "selectedProviderRegion.v1"
        static let usageDisplayMode = "usageDisplayMode"
        static let refreshInterval = "refreshInterval"
        static let qoderCreditsMetricMigrated = "qoderCreditsMetricMigrated.v1"
    }
}

// Expose only credential paths actually implemented by each adapter.
enum ProviderLoginMethod: String, CaseIterable, Identifiable, Sendable {
    case desktop, cli, edge, chrome, editorFallback, editor, desktopEdge, desktopChrome
    var id: Self { self }
    var title: String {
        switch self {
        case .desktop: "Desktop app"
        case .cli: "Terminal CLI"
        case .edge: "Browser (Edge)"
        case .chrome: "Browser (Chrome)"
        case .editorFallback: "Editor + CLI fallback"
        case .editor: "Editor login"
        case .desktopEdge: "Desktop app + Edge"
        case .desktopChrome: "Desktop app + Chrome"
        }
    }
    static func supported(for provider: ProviderID) -> [Self] {
        switch provider {
        case .gemini: [.desktopEdge, .desktopChrome, .desktop, .edge, .chrome]
        case .antigravity: [.desktop]
        case .manus: [.desktop, .edge, .chrome]
        case .muse: [.edge, .chrome]
        case .adobe: [.edge, .chrome]
        case .kimi: [.desktop, .edge, .chrome]
        case .qwen: [.desktop, .edge, .chrome]
        case .minimax: [.desktop, .edge, .chrome]
        case .qoder: [.desktop, .edge, .chrome]
        case .dola, .zai, .buddy: [.desktop, .edge, .chrome]
        case .cursor: [.desktop, .edge, .chrome]
        case .codex: [.cli, .edge, .chrome]
        case .claude: [.cli, .desktop, .edge, .chrome]
        case .copilot: [.editorFallback, .editor, .cli]
        }
    }
}

extension AppPreferences {
    func loginMethod(for provider: ProviderID) -> ProviderLoginMethod {
        if provider == .gemini {
            return geminiSource.loginMethod
        }
        if let stored = defaults.string(forKey: ProviderLoginMethod.key(for: provider)),
           let value = ProviderLoginMethod(rawValue: stored),
           ProviderLoginMethod.supported(for: provider).contains(value) { return value }

        return ProviderLoginMethod.supported(for: provider)[0]
    }

    func setLoginMethod(_ method: ProviderLoginMethod, for provider: ProviderID) {
        guard ProviderLoginMethod.supported(for: provider).contains(method) else { return }
        defaults.set(UUID().uuidString, forKey: ProviderLoginMethod.selectionKey(for: provider))
        if provider == .gemini {
            switch method {
            case .edge: geminiSource = .edge; geminiEdgeCookiesAllowed = true
            case .chrome: geminiSource = .chrome; geminiChromeCookiesAllowed = true
            case .desktopEdge:
                geminiSource = .nativeAppEdge; geminiNativeAccessAllowed = true; geminiEdgeCookiesAllowed = true
            case .desktopChrome:
                geminiSource = .nativeAppChrome; geminiNativeAccessAllowed = true; geminiChromeCookiesAllowed = true
            case .desktop: geminiSource = .nativeApp; geminiNativeAccessAllowed = true
            default: break
            }
        } else {
            defaults.set(method.rawValue, forKey: ProviderLoginMethod.key(for: provider))
        }
    }
}

extension ProviderLoginMethod {
    static func selectionKey(for provider: ProviderID) -> String {
        "loginMethodSelection.v1.\(provider.rawValue)"
    }
    static func key(for provider: ProviderID) -> String { "\(provider.rawValue)LoginMethod.v1" }
    static func selected(for provider: ProviderID) -> Self {
        if provider == .gemini {
            return GeminiCredentialSource.selected.loginMethod
        }
        let supported = supported(for: provider)
        guard let raw = UserDefaults.standard.string(forKey: key(for: provider)),
              let value = Self(rawValue: raw), supported.contains(value) else { return supported[0] }
        return value
    }
    func title(for provider: ProviderID) -> String {
        if provider == .copilot {
            switch self {
            case .editorFallback: return "Local OAuth / GitHub CLI"
            case .editor: return "Local OAuth"
            case .cli: return "GitHub CLI OAuth"
            default: break
            }
        }
        if self == .cli, provider == .codex { return "Desktop app / Local OAuth" }
        if self == .cli, provider == .claude { return "Local OAuth" }
        return title
    }
}

extension GeminiCredentialSource {
    var loginMethod: ProviderLoginMethod {
        switch self {
        case .nativeApp: .desktop
        case .edge: .edge
        case .chrome: .chrome
        case .nativeAppEdge: .desktopEdge
        case .nativeAppChrome: .desktopChrome
        }
    }
}
