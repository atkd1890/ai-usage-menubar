import SwiftUI

private struct UsagePanelVisibleKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var usagePanelVisible: Bool {
        get { self[UsagePanelVisibleKey.self] }
        set { self[UsagePanelVisibleKey.self] = newValue }
    }
}

/// Cached dashboard views have no periodic wakeups while the panel is hidden.
struct UsageMinuteSchedule: TimelineSchedule {
    let isActive: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard isActive else { return AnySequence([startDate]) }
        return AnySequence(PeriodicTimelineSchedule(from: startDate, by: 60).entries(from: startDate, mode: mode))
    }
}
