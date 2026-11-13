import AppKit
import SwiftUI

enum DashboardSection { case header, rows, footer }

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Environment(\.usagePanelVisible) private var isPanelVisible
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Binding var usageDisplayMode: UsageDisplayMode
    @Binding var refreshInterval: RefreshIntervalOption
    let availableUpdateVersion: String?
    let isCheckingForUpdates: Bool
    var checkForUpdates: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var openAnalytics: @MainActor () -> Void = {}
    var providerOrder: [ProviderID] = ProviderID.allCases

    var section: DashboardSection? = nil

    var body: some View {
        Group {
            switch section {
            case .header: content.header.padding([.horizontal, .top], 10).padding(.bottom, 8)
            case .rows: content.providerRowsContent.padding(.horizontal, 10).padding(.bottom, 6)
            case .footer: footer
            case nil: completeDashboard
            }
        }
        .frame(width: 392)
    }

    private var content: DashboardContentView {
        DashboardContentView(store: store, usageDisplayMode: $usageDisplayMode, providerOrder: providerOrder)
    }

    private var completeDashboard: some View {
        DashboardContentView(
            store: store,
            usageDisplayMode: $usageDisplayMode,
            providerOrder: providerOrder
        )
        .safeAreaBar(edge: .bottom, spacing: 0) {
            footer
        }
        .frame(width: 392)
        .onAppear {
            store.setRefreshInterval(refreshInterval)
            store.start()
            launchAtLogin.synchronize()
        }
        .onChange(of: refreshInterval) { _, interval in
            store.setRefreshInterval(interval)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: freshnessSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(freshnessTint)

                Group {
                    if let updated = store.lastSuccessfulRefreshAt {
                        HStack(spacing: 3) {
                            Text("Updated")
                            if isPanelVisible { Text(updated, style: .relative) }
                        }
                    } else if store.lastAttemptAt != nil {
                        Text("Not updated")
                    } else {
                        Text("Waiting to refresh")
                    }
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer()

            if let version = availableUpdateVersion {
                Button(action: checkForUpdates) {
                    Label("Update", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(UsagePalette.accent)
                .controlSize(.small)
                .disabled(isCheckingForUpdates)
                .help("Update AI Usage to \(version)")
            }

            HStack(spacing: 0) {
                Button {
                    store.refreshNow()
                } label: {
                    RefreshButtonLabel(isRefreshing: isRefreshing && isPanelVisible)
                }
                .help(isRefreshing ? "Refreshing usage" : "Refresh now")
                .disabled(isRefreshing)

                Button(action: openAnalytics) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: RefreshButtonLabel.symbolSize, weight: .medium))
                        .frame(width: RefreshButtonLabel.size, height: RefreshButtonLabel.size)
                }
                .help("Dashboard")
                .accessibilityLabel("Open Dashboard")

                Button(action: openSettings) {
                    SettingsButtonLabel()
                }
                .help("Settings")
                .accessibilityLabel("Settings")
                .accessibilityHint("Opens the Settings window")
            }
            .buttonStyle(.plain)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 7)
    }

    private var freshnessSymbol: String {
        store.lastSuccessfulRefreshAt == nil ? "clock" : "checkmark.circle.fill"
    }

    private var freshnessTint: Color {
        store.lastSuccessfulRefreshAt == nil ? .secondary : UsagePalette.success
    }

    private var isRefreshing: Bool {
        store.states.values.contains(where: \.isRefreshing)
    }
}

struct SettingsButtonLabel: View {
    var body: some View {
        Image(systemName: "gearshape")
            .font(.system(size: RefreshButtonLabel.symbolSize, weight: .medium))
            .frame(width: RefreshButtonLabel.size, height: RefreshButtonLabel.size)
            .contentShape(Circle())
    }
}

struct RefreshButtonLabel: View {
    static let size: CGFloat = 28
    static let symbolSize: CGFloat = 14

    let isRefreshing: Bool

    var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .font(.system(size: Self.symbolSize, weight: .medium))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Circle())
        .accessibilityLabel(isRefreshing ? "Refreshing usage" : "Refresh now")
    }
}

struct DashboardContentView: View {
    @Bindable var store: UsageStore
    @Binding var usageDisplayMode: UsageDisplayMode
    var providerOrder: [ProviderID] = ProviderID.allCases

    var body: some View {
        VStack(spacing: 8) {
            header
            providerRows
        }
        .padding([.horizontal, .top], 10)
        .padding(.bottom, 6)
    }

    private var providerRows: some View {
        ScrollView { providerRowsContent }
            .scrollBounceBehavior(.basedOnSize)
    }

    var providerRowsContent: some View {
        VStack(spacing: 8) {
            ForEach(topLevelProviders) { provider in
                if provider != topLevelProviders.first {
                    Rectangle()
                        .fill(.primary.opacity(0.22))
                        .frame(height: 1)
                        .padding(.vertical, 4)
                        .accessibilityHidden(true)
                }
                if GoogleAIGroup.members.contains(provider) {
                        GoogleAISectionView(states: googleProviders.compactMap { store.states[$0] },
                                            displayMode: usageDisplayMode)
                } else if let state = store.states[provider] {
                    ProviderSectionView(
                        state: state,
                        displayMode: usageDisplayMode
                    )
                }
            }
        }
    }

    // Google AI is one top-level provider group; its child divider remains inset.
    private var topLevelProviders: [ProviderID] {
        visibleProviders.filter {
            !GoogleAIGroup.members.contains($0) || $0 == googleProviders.first
        }
    }

    private var visibleProviders: [ProviderID] {
        GoogleAIGroup.ordered(providerOrder.filter(store.isProviderVisibleInDashboard))
    }

    private var googleProviders: [ProviderID] {
        visibleProviders.filter { GoogleAIGroup.members.contains($0) }
    }

    var header: some View {
        HStack {
            Text("AI Usage")
                .font(.headline.weight(.semibold))
            Spacer()
            Picker("Numbers", selection: $usageDisplayMode) {
                ForEach(UsageDisplayMode.allCases) { mode in
                    Text(mode.title)
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 112)
            .accessibilityLabel("Usage numbers")
            .accessibilityHint("Choose whether percentages show usage left or used")
        }
        .padding(.horizontal, 4)
        .frame(height: 28)
    }
}
