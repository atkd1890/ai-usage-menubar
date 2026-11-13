import Foundation

@MainActor
final class AppServices {
    let preferences: AppPreferences
    let store: UsageStore
    let launchAtLogin: LaunchAtLoginController
    let updateController: UpdateController

    init(startingUpdater: Bool = true, defaults: UserDefaults = .standard) {
        let preferences = AppPreferences(defaults: defaults)
        self.preferences = preferences
        store = UsageStore(
            history: UsageHistory.persistent(),
            analytics: TokenAnalytics(),
            refreshInterval: preferences.refreshInterval,
            trackedProviderIDs: preferences.trackedProviderIDs
        )
        store.alertController = UsageAlertController(settings: preferences.alerts)
        launchAtLogin = LaunchAtLoginController()
        updateController = UpdateController(startingUpdater: startingUpdater)
    }
}
