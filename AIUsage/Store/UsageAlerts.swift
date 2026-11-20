import Foundation
import Observation
import UserNotifications

@MainActor @Observable final class AlertPreferences {
    var runningOut: Bool { didSet { defaults.set(runningOut, forKey: "alerts.runningOut") } }
    var paidUsage: Bool { didSet { defaults.set(paidUsage, forKey: "alerts.paidUsage") } }
    var limitBack: Bool { didSet { defaults.set(limitBack, forKey: "alerts.limitBack") } }
    var leadMinutes: Int { didSet { defaults.set(leadMinutes, forKey: "alerts.leadMinutes") } }
    var enabled: Bool { runningOut || paidUsage || limitBack }
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults) {
        self.defaults = defaults
        runningOut = defaults.bool(forKey: "alerts.runningOut")
        paidUsage = defaults.bool(forKey: "alerts.paidUsage")
        limitBack = defaults.bool(forKey: "alerts.limitBack")
        leadMinutes = defaults.object(forKey: "alerts.leadMinutes") as? Int ?? 15
    }
}

nonisolated struct AlertReading {
    let date: Date
    let used: Double
    let reset: Date?
}
nonisolated enum AlertRules {
    static func exhaustion(readings: [AlertReading], leadMinutes: Int) -> Date? {
        guard readings.count >= 3, let first = readings.first, let last = readings.last,
              let reset = last.reset, reset > last.date, last.used < 100,
              readings.allSatisfy({ $0.reset == reset }), last.date.timeIntervalSince(first.date) >= 120 else { return nil }
        let rate = (last.used - first.used) / last.date.timeIntervalSince(first.date)
        guard rate > 0 else { return nil }
        let projected = last.date.addingTimeInterval(max(0, 100 - last.used) / rate)
        return projected < reset && projected.timeIntervalSince(last.date) <= Double(leadMinutes * 60) ? projected : nil
    }
    static func spent(_ snapshot: ProviderSnapshot) -> Double? {
        switch snapshot.displayedBillingUsage {
        case .boundedSpend(let used, _, _), .unboundedSpend(let used, _): used
        default: nil
        }
    }
    static func paidStarted(old: ProviderSnapshot, new: ProviderSnapshot) -> Bool {
        guard (old.windows + new.windows).contains(where: { $0.isBoundedActive && $0.usedPercent >= 100 }) else { return false }
        if let before = spent(old) ?? (old.additionalUsageEnabled == false ? 0 : nil), let after = spent(new), before <= 0, after > 0 { return true }
        if let before = old.displayedBalance, let after = new.displayedBalance,
           before.currencyCode == after.currencyCode, before.amount > after.amount { return true }
        return false
    }
}

@MainActor final class UsageAlertController {
    let settings: AlertPreferences
    private var samples: [String: [AlertReading]] = [:]
    private var previous: [String: ProviderSnapshot] = [:]
    private var sent: Set<String> = []
    init(settings: AlertPreferences) { self.settings = settings }
    func requestPermission() {
        Task {
            let center = UNUserNotificationCenter.current()
            let state = await center.notificationSettings()
            if state.authorizationStatus == .notDetermined { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
        }
    }
    func receive(_ snapshot: ProviderSnapshot) {
        guard let email = snapshot.historyIdentity else { return }
        let account = "\(snapshot.provider.rawValue)|\(snapshot.credentialSource ?? "selected")|\(email)"
        defer { previous[account] = snapshot }
        let old = previous[account]
        for window in snapshot.windows where window.isBoundedActive {
            let key = account + "|" + window.kind.rawValue
            let reading = AlertReading(date: snapshot.fetchedAt, used: window.usedPercent, reset: window.resetsAt)
            var history = samples[key] ?? []
            if let last = history.last, last.reset != reading.reset || reading.used < last.used { history = [] }
            history.removeAll { reading.date.timeIntervalSince($0.date) > 1800 }
            if history.last.map({ reading.date > $0.date }) ?? true { history.append(reading) }
            samples[key] = history
            let cycle = key + "|\(window.resetsAt?.timeIntervalSince1970 ?? Calendar.current.startOfDay(for: snapshot.fetchedAt).timeIntervalSince1970)"
            if settings.runningOut, let projected = AlertRules.exhaustion(readings: history, leadMinutes: settings.leadMinutes) {
                send(id: cycle + "|pace", title: "\(snapshot.displayName) may run out soon",
                     body: "\(window.kind.title) may run out around \(projected.formatted(date: .omitted, time: .shortened)), before its reset.")
            }
            if settings.limitBack, let before = old?.windows.first(where: { $0.isBoundedActive && $0.kind == window.kind }), before.usedPercent >= 100, window.usedPercent < 100 {
                send(id: cycle + "|back", title: "\(snapshot.displayName) is available again", body: "\(window.kind.title) is no longer capped.")
            }
        }
        if settings.paidUsage, let old, AlertRules.paidStarted(old: old, new: snapshot) {
            let cycle = snapshot.windows.compactMap(\.resetsAt).min()?.timeIntervalSince1970 ?? Calendar.current.startOfDay(for: snapshot.fetchedAt).timeIntervalSince1970
            send(id: account + "|paid|\(cycle)", title: "\(snapshot.displayName) is using extra balance", body: "A limit was reached and paid usage has started.")
        }
    }
    private func send(id: String, title: String, body: String) {
        guard !sent.contains(id) else { return }
        sent.insert(id)
        Task {
            let center = UNUserNotificationCenter.current()
            let state = await center.notificationSettings()
            guard state.authorizationStatus == .authorized || state.authorizationStatus == .provisional else { sent.remove(id); return }
            let content = UNMutableNotificationContent()
            content.title = title; content.body = body; content.sound = .default
            content.interruptionLevel = .active // System Focus rules apply; never time-sensitive/critical.
            do { try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) }
            catch { sent.remove(id) }
        }
    }
}
