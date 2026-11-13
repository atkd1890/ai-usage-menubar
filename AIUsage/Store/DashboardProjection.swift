import Foundation
import Observation

enum AnalyticsUnit: String, CaseIterable, Sendable { case tokens = "Tokens", value = "Value" }

nonisolated struct AnalyticsAmount: Sendable, Equatable {
    var tokens: Double = 0
    var value: Double = 0
    var records = 0
    var pricedRecords = 0
    var unpriced: Int { records - pricedRecords }
    func number(_ unit: AnalyticsUnit) -> Double { unit == .tokens ? tokens : value }
    mutating func add(_ event: TokenUsageEvent) {
        tokens += Double(event.tokens); records += 1
        if let price = event.apiValue { value += price; pricedRecords += 1 }
    }
}
nonisolated struct AnalyticsBar: Identifiable, Sendable {
    let date: Date
    let series: String
    let provider: ProviderID
    var amount = AnalyticsAmount()
    var id: String { "\(date.timeIntervalSince1970)|\(series)" }
}
nonisolated struct AnalyticsDay: Sendable {
    var amount = AnalyticsAmount()
    var series: [String: AnalyticsAmount] = [:]
}
nonisolated struct AnalyticsLimitRow: Identifiable, Sendable {
    let provider: ProviderID
    let metric: QuotaKind
    let date: Date
    var count: Int
    var id: String { "\(provider)|\(metric)|\(date.timeIntervalSince1970)" }
}
nonisolated struct DashboardProjection: Sendable {
    var total = AnalyticsAmount()
    var previous = AnalyticsAmount()
    var providers: [ProviderID: AnalyticsAmount] = [:]
    var sidebarProviders: [ProviderID: AnalyticsAmount] = [:]
    var models: [String: AnalyticsAmount] = [:]
    var bars: [AnalyticsBar] = []
    var days: [Date: AnalyticsDay] = [:]
    var periodDays: [Date: AnalyticsDay] = [:]
    var limits: [AnalyticsLimitRow] = []
    var hitsByDay: [Date: Int] = [:]
    var events: [TokenUsageEvent] = []
    var series: [String] = []
    var seriesProviders: [String: ProviderID] = [:]
    var maximumTokens: Double = 1
    var maximumValue: Double = 1
    var hitCount: Int { limits.reduce(0) { $0 + $1.count } }

    static func build(events: [TokenUsageEvent], hits: [UsageLimitHit], providers allowed: [ProviderID],
                      selected: ProviderID?, days count: Int, now: Date, names: [ProviderID: String],
                      accounts: [ProviderID: String], calendar: Calendar = .current) -> DashboardProjection {
        let today = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: today)!
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today)!
        let previousStart = calendar.date(byAdding: .day, value: -count, to: start)!
        let allowed = Set(allowed)
        let selection: Set<ProviderID>
        if let selected {
            selection = GoogleAIGroup.members.contains(selected) ? Set(GoogleAIGroup.members).intersection(allowed) : [selected]
        } else { selection = allowed }
        var result = DashboardProjection(), bars: [String: AnalyticsBar] = [:]
        for event in events where allowed.contains(event.provider) {
            if event.date >= start && event.date < end { result.sidebarProviders[event.provider, default: AnalyticsAmount()].add(event) }
            guard selection.contains(event.provider) else { continue }
            let date = calendar.startOfDay(for: event.date)
            let series = selected == nil ? names[event.provider] ?? event.provider.displayName : event.model
            result.days[date, default: AnalyticsDay()].amount.add(event)
            result.days[date, default: AnalyticsDay()].series[series, default: AnalyticsAmount()].add(event)
            if event.date >= start && event.date < end {
                result.events.append(event)
                result.total.add(event)
                result.providers[event.provider, default: AnalyticsAmount()].add(event)
                result.models[event.model, default: AnalyticsAmount()].add(event)
                let key = "\(date.timeIntervalSince1970)|\(series)"
                if bars[key] == nil { bars[key] = AnalyticsBar(date: date, series: series, provider: event.provider) }
                bars[key]!.amount.add(event)
                result.seriesProviders[series] = event.provider
            } else if event.date >= previousStart && event.date < start { result.previous.add(event) }
        }
        result.periodDays = result.days.filter { $0.key >= start && $0.key < end }
        result.maximumTokens = max(1, result.days.values.map { $0.amount.tokens }.max() ?? 1)
        result.maximumValue = max(1, result.days.values.map { $0.amount.value }.max() ?? 1)
        result.bars = bars.values.sorted { $0.date == $1.date ? $0.series < $1.series : $0.date < $1.date }
        result.series = Array(result.seriesProviders.keys).sorted()
        var limits: [String: AnalyticsLimitRow] = [:]
        for hit in hits where selection.contains(hit.provider) && hit.date >= start && hit.date < end && hit.account == accounts[hit.provider] {
            let date = calendar.startOfDay(for: hit.date)
            let key = "\(hit.provider)|\(hit.metric)|\(date.timeIntervalSince1970)"
            if limits[key] == nil { limits[key] = AnalyticsLimitRow(provider: hit.provider, metric: hit.metric, date: date, count: 0) }
            limits[key]!.count += 1
            result.hitsByDay[date, default: 0] += 1
        }
        result.limits = limits.values.sorted { $0.date > $1.date }
        return result
    }
    static func planMultiple(value: Double, monthlyPrice: Double, days: Int) -> Double? {
        guard monthlyPrice.isFinite, monthlyPrice > 0, value.isFinite, days > 0 else { return nil }
        return value / (monthlyPrice * Double(days) / 30.4375)
    }
}

@MainActor @Observable final class DashboardProjectionModel {
    private(set) var data = DashboardProjection()
    private(set) var buildCount = 0
    @ObservationIgnored private var appliedKey: String?
    @ObservationIgnored private var generation: String?
    @ObservationIgnored private var cache: [String: DashboardProjection] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var inFlight: [String: Task<DashboardProjection, Never>] = [:]
    func rebuild(key: String, generation: String = "", events: [TokenUsageEvent], hits: [UsageLimitHit], providers: [ProviderID], selected: ProviderID?,
                 days: Int, now: Date, names: [ProviderID: String], accounts: [ProviderID: String]) async {
        if self.generation != generation {
            self.generation = generation; cache.removeAll(); order.removeAll(); appliedKey = nil
        }
        guard key != appliedKey else { return }
        if let cached = cache[key] {
            data = cached; appliedKey = key
            order.removeAll { $0 == key }; order.append(key)
            return
        }
        let workKey = generation + "|" + key
        let task: Task<DashboardProjection, Never>
        if let pending = inFlight[workKey] { task = pending }
        else {
            buildCount += 1
            task = Task.detached(priority: .userInitiated) {
                DashboardProjection.build(events: events, hits: hits, providers: providers, selected: selected, days: days,
                                          now: now, names: names, accounts: accounts)
            }
            inFlight[workKey] = task
        }
        let result = await task.value
        inFlight[workKey] = nil
        guard self.generation == generation else { return }
        // Keep completed work even if the user already switched to another tab.
        cache[key] = result
        order.removeAll { $0 == key }; order.append(key)
        if order.count > 12 { cache.removeValue(forKey: order.removeFirst()) }
        guard !Task.isCancelled else { return }
        data = result; appliedKey = key
    }
}
