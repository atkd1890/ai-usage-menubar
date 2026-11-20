import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct UsageDashboardView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    @State private var selection = "overview"
    @State private var days = 30
    @State private var unit: AnalyticsUnit
    @State private var projection: DashboardProjectionModel
    @State private var exportError: String?
    @State private var priceProvider: ProviderID?
    @State private var planPrice = 0.0
    @State private var priceRevision = 0
    private let periods = [7, 30, 90, 365]
    init(store: UsageStore, preferences: AppPreferences, initialUnit: AnalyticsUnit = .tokens,
         projection: DashboardProjectionModel? = nil) {
        self.store = store; self.preferences = preferences
        _unit = State(initialValue: initialUnit)
        _projection = State(initialValue: projection ?? DashboardProjectionModel())
    }
    private var data: DashboardProjection { projection.data }
    private var today: Date { Calendar.current.startOfDay(for: Date()) }
    private var start: Date { Calendar.current.date(byAdding: .day, value: -(days - 1), to: today)! }
    private var end: Date { Calendar.current.date(byAdding: .day, value: 1, to: today)! }
    private var providers: [ProviderID] {
        preferences.providerOrder.filter { store.trackedProviderIDs.contains($0) && ProviderID.enabledCases.contains($0) }
    }
    private var sidebarProviders: [ProviderID] { providers }
    private var selected: ProviderID? { ProviderID(rawValue: selection) }
    private var selectedProviders: [ProviderID] {
        guard let selected else { return providers }
        return [selected]
    }
    private var planProviders: [ProviderID] { sidebarProviders.filter { selectedProviders.contains($0) } }
    private func name(_ provider: ProviderID) -> String {
        store.states[provider]?.snapshot?.displayName ?? provider.displayName
    }
    private func leafName(_ provider: ProviderID) -> String { provider == .gemini ? "Gemini" : provider == .antigravity ? "Antigravity" : name(provider) }
    private var title: String { selected.map(name) ?? "Overview" }
    private var names: [ProviderID: String] { Dictionary(uniqueKeysWithValues: providers.map { ($0, name($0)) }) }
    private var accounts: [ProviderID: String] {
        Dictionary(uniqueKeysWithValues: providers.compactMap { provider in
            guard let snapshot = store.states[provider]?.snapshot, let email = snapshot.historyIdentity else { return nil }
            return (provider, "\(snapshot.credentialSource ?? "selected")|\(email)")
        })
    }
    private var generation: String {
        "\(store.analytics.revision)|\(store.history.revision)|\(today.timeIntervalSince1970)|" + providers.map {
            "\($0.rawValue):\(name($0)):\(accounts[$0] ?? "")"
        }.joined(separator: ";")
    }
    private var query: String { "\(generation)|\(selection)|\(days)" }
    private var chartColors: [Color] {
        data.series.enumerated().map { index, series in
            color(data.seriesProviders[series] ?? .codex).opacity(selected == nil ? 1 : max(0.4, 1 - Double(index) * 0.15))
        }
    }
    private func formatted(_ value: Double) -> String { AnalyticsDisplay.number(value, unit: unit) }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        headline
                        DashboardUsageChart(data: data, unit: unit, start: start, end: end, days: days, colors: chartColors)
                        if data.events.isEmpty && !store.analytics.isLoading {
                            Text("No local token records in this period.").font(.caption).foregroundStyle(.secondary)
                        }
                        DashboardHeatmap(data: data, unit: unit, today: today, weeks: UsageCalendar.weeks(ending: today))
                        footer
                    }.padding(26)
                }
                .defaultScrollAnchor(.top).scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                Divider()
                ScrollView { rightSidebar.padding(24) }
                    .defaultScrollAnchor(.top).scrollBounceBehavior(.basedOnSize)
                    .frame(width: 380).frame(maxHeight: .infinity).clipped()
            }.frame(maxHeight: .infinity).clipped()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 1080, minHeight: 700)
        .task { await store.analytics.refresh() }
        .task(id: query) {
            await projection.rebuild(key: query, generation: generation, events: store.analytics.events,
                hits: store.history.limitHits, providers: providers, selected: selected, days: days,
                now: Date(), names: names, accounts: accounts)
        }
        .sheet(item: $priceProvider) { provider in
            Form {
                Text("\(name(provider)) monthly plan price").font(.headline)
                TextField("USD per month", value: $planPrice, format: .number)
                Text(DashboardCopy.priceEditor).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel") { priceProvider = nil }
                    if DashboardPlanPrice.listed(provider: provider, plan: planName(provider)) != nil {
                        Button("Use list price") {
                            UserDefaults.standard.removeObject(forKey: priceKey(provider)); priceRevision += 1; priceProvider = nil
                        }
                    }
                    Spacer()
                    Button("Save") {
                        UserDefaults.standard.set(planPrice, forKey: priceKey(provider))
                        priceRevision += 1; priceProvider = nil
                    }.disabled(!planPrice.isFinite || planPrice < 0).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 440)
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Text(title).font(.headline).frame(width: 190, alignment: .leading)
            Spacer()
            Picker("Period", selection: $days) {
                ForEach(periods, id: \.self) { Text($0 == 365 ? "12 Months" : "\($0) Days").tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 350)
            Button(action: export) { Image(systemName: "square.and.arrow.up") }.help("Export token usage")
            Button { Task { await store.analytics.refresh(force: true) }; store.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }.disabled(store.analytics.isLoading).help("Refresh local usage and limits")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 20).frame(height: 52)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("dashboard.header")
    }
    private var sidebar: some View {
        ScrollView {
            VStack(spacing: 4) {
                sidebarButton("Overview", key: "overview", provider: nil, amount: nil)
                ForEach(sidebarProviders) { provider in
                    sidebarButton(name(provider), key: provider.rawValue, provider: provider, amount: providerAmount(provider, sidebar: true))
                }
                Spacer(minLength: 0)
            }.padding(8)
        }.frame(maxHeight: .infinity).clipped()
        .background(Color(nsColor: .controlBackgroundColor))
    }
    private func sidebarButton(_ title: String, key: String, provider: ProviderID?, amount: AnalyticsAmount?) -> some View {
        Button { selection = key } label: {
            HStack(spacing: 9) {
                if let provider { ProviderIcon(provider: provider, size: 16) }
                else { Image(systemName: "square.grid.2x2.fill").frame(width: 16) }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let amount, amount.tokens > 0 {
                    Circle().fill(color(provider ?? .codex)).frame(width: 5, height: 5)
                    Text(AnalyticsDisplay.compact(amount.tokens)).font(.caption).foregroundStyle(selection == key ? .white.opacity(0.8) : .secondary)
                }
            }
            .foregroundStyle(selection == key ? Color.white : .primary)
            .padding(.horizontal, 10).frame(height: 34)
            .background(selection == key ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var headline: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("USAGE · \(start.formatted(.dateTime.month(.abbreviated).day())) – \(today.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "chart.bar.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("Unit", selection: $unit) { ForEach(AnalyticsUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 125).accessibilityIdentifier("dashboard.units")
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(data.total.records == 0 || (unit == .value && data.total.pricedRecords == 0) ? "—" : formatted(data.total.number(unit)))
                    .font(.system(size: 56, weight: .semibold)).monospacedDigit()
                Text(unit == .tokens ? "tokens" : "at API prices").font(.title3).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text(unit == .tokens ? data.total.value.formatted(.currency(code: "USD")) + " at API prices" : AnalyticsDisplay.compact(data.total.tokens) + " tokens")
                Divider().frame(height: 15)
                Text("\(formatted(data.total.number(unit) / Double(days))) a day")
                if data.previous.number(unit) > 0 {
                    Divider().frame(height: 15)
                    Text(String(format: "%.1f× previous period", data.total.number(unit) / data.previous.number(unit)))
                }
            }.font(.caption).foregroundStyle(.secondary)
            if store.analytics.isLoading { ProgressView("Reading local usage metadata…").controlSize(.small) }
            if data.total.unpriced > 0 {
                Text("Partial API value: \(data.total.unpriced) unpriced records excluded.").font(.caption2).foregroundStyle(.orange)
            }
        }
    }
    private var rightSidebar: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                sidebarTitle("Plans", symbol: "creditcard.fill", tint: .green)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(data.total.value.formatted(.currency(code: "USD").precision(.fractionLength(0...2)))).font(.system(size: 28, weight: .semibold))
                    Text("at API prices").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(planProviders) { provider in planRow(provider) }
                Text("US list prices unless edited; multiples compare API value with period plan cost.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                sidebarTitle("Limits", symbol: "exclamationmark.circle.fill", tint: .red)
                let _ = ConfirmedSchemaObserver.shared.revision
                if providers.contains(where: {
                    guard let snapshot = store.states[$0]?.snapshot else { return false }
                    return ConfirmedSchemaStore.shared.hasActiveWarnings(for: snapshot)
                }) {
                    Text("Some provider APIs changed or returned unsupported fields. Check the provider warning badge.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("\(data.hitCount) observed hits").font(.system(size: 27, weight: .semibold))
                ForEach(data.limits) { row in
                    HStack(alignment: .firstTextBaseline) {
                        ProviderIcon(provider: row.provider, size: 13).foregroundStyle(color(row.provider))
                        Text("\(leafName(row.provider)) · \(row.metric.title)").lineLimit(2)
                        Spacer(minLength: 6)
                        Text(row.date.formatted(.dateTime.month(.abbreviated).day())).frame(width: 55, alignment: .trailing)
                        Text("\(row.count) \(row.count == 1 ? "time" : "times")").frame(width: 55, alignment: .trailing)

                    }.font(.caption)
                }
                Text(DashboardCopy.limits).font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                sidebarTitle("Models", symbol: "star.fill", tint: .purple)
                let models = data.models.sorted { $0.value.number(unit) > $1.value.number(unit) }
                if models.isEmpty { Text("No model usage in this period.").font(.caption).foregroundStyle(.secondary) }
                ForEach(models, id: \.key) { model, amount in
                    let fraction = data.total.number(unit) > 0 ? amount.number(unit) / data.total.number(unit) : 0
                    HStack(spacing: 7) {
                        ProviderIcon(provider: model.hasPrefix("claude") ? .claude : .codex, size: 13)
                            .foregroundStyle(model.hasPrefix("claude") ? Color.orange : Color.cyan)
                        Text(AnalyticsDisplay.model(model)).font(.caption).lineLimit(1).help(model)
                        Spacer(minLength: 4)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.secondary.opacity(0.18))
                                Capsule().fill(model.hasPrefix("claude") ? Color.orange : Color.cyan).frame(width: geometry.size.width * fraction)
                            }
                        }.frame(width: 65, height: 4)
                        Text(fraction, format: .percent.precision(.fractionLength(0...1))).font(.caption).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                        Text(unit == .value && amount.pricedRecords == 0 ? "—" : formatted(amount.number(unit)))
                            .font(.caption).monospacedDigit().frame(width: 58, alignment: .trailing)
                    }
                }
                Text("Share by \(unit == .tokens ? "tokens" : "priced API value").").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func providerAmount(_ provider: ProviderID, sidebar: Bool = false) -> AnalyticsAmount {
        let amounts = sidebar ? data.sidebarProviders : data.providers
        return amounts[provider] ?? AnalyticsAmount()
    }
    private func planName(_ provider: ProviderID) -> String? {
        store.states[provider]?.snapshot?.planName
    }
    private func priceKey(_ provider: ProviderID) -> String {
        "analytics.planPrice.\(provider.rawValue)"
    }
    private func price(_ provider: ProviderID) -> DashboardPlanPrice? {
        _ = priceRevision
        if let number = UserDefaults.standard.object(forKey: priceKey(provider)) as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 {
            return DashboardPlanPrice(monthlyUSD: number.doubleValue, isListPrice: false, source: nil)
        }
        return DashboardPlanPrice.listed(provider: provider, plan: planName(provider))
    }
    private func planRow(_ provider: ProviderID) -> some View {
        let amount = providerAmount(provider), price = price(provider)
        return Group {
            if amount.records > 0 || planName(provider) != nil {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        ProviderIcon(provider: provider, size: 14)
                        Text(name(provider)).font(.caption.weight(.medium))
                        if let plan = planName(provider) {
                            let formattedPlan = [ProviderID.gemini, .antigravity].contains(provider)
                                ? plan.replacingOccurrences(of: "Google AI ", with: "")
                                : (provider == .muse ? plan.replacingOccurrences(of: "muse", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces) : plan)
                            Text(formattedPlan.isEmpty ? plan : formattedPlan).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 3)
                        Text(amount.pricedRecords > 0 ? amount.value.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) : "—").font(.caption)
                    }
                    HStack(spacing: 6) {
                        if let price {
                            Text("\(price.isListPrice ? "Listed " : "")\(price.monthlyUSD.formatted(.currency(code: "USD")))/mo")
                                .font(.caption2).foregroundStyle(.secondary)
                            if amount.pricedRecords > 0, let multiple = DashboardProjection.planMultiple(value: amount.value, monthlyPrice: price.monthlyUSD, days: days) {
                                Text("\(amount.unpriced > 0 ? "≥" : price.isListPrice ? "≈" : "")\(String(format: "%.1f×", multiple))")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.green)
                                    .help(amount.unpriced > 0 ? "Lower bound: unpriced models are excluded." : "API value divided by plan cost for this period.")
                            }
                        }
                        Spacer(minLength: 4)
                        Button(price == nil ? "Set price" : "Edit") { planPrice = price?.monthlyUSD ?? 0; priceProvider = provider }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }
        }
    }
    private func sidebarTitle(_ title: String, symbol: String, tint: Color) -> some View {
        HStack { Image(systemName: symbol).foregroundStyle(tint); Text(title).font(.headline); Spacer() }
    }
    private func color(_ provider: ProviderID) -> Color { provider == .claude ? .orange : provider == .codex ? .cyan : .purple }
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Local logs · 13 months · cached. API estimates exclude tools/unpriced models; Refresh updates data.")
            if store.analytics.skipped > 0 { Text("Skipped \(store.analytics.skipped) unreadable or oversized records.").foregroundStyle(.orange) }
        }.font(.caption2).foregroundStyle(.secondary)
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.commaSeparatedText]; panel.nameFieldStringValue = "ai-usage-tokens.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows = data.events.map { "\($0.date.ISO8601Format()),\($0.provider.rawValue),\($0.model),\($0.input),\($0.cached),\($0.cacheWrite),\($0.output),\($0.tokens),\($0.apiValue.map(String.init(describing:)) ?? "")" }
        do { try ("timestamp,provider,model,input_tokens,cached_tokens,cache_write_tokens,output_tokens,total_tokens,api_equivalent_usd\n" + rows.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}
