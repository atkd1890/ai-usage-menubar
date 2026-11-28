import AppKit
import SwiftUI

enum DashboardSection { case header, rows, footer }

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Environment(\.usagePanelVisible) private var isPanelVisible
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Binding var usageDisplayMode: UsageDisplayMode
    @Binding var selectedRegion: ProviderRegion
    @Binding var refreshInterval: RefreshIntervalOption
    let availableUpdateVersion: String?
    let isCheckingForUpdates: Bool
    var checkForUpdates: @MainActor () -> Void = {}
    var openSettings: @MainActor () -> Void = {}
    var openAnalytics: @MainActor () -> Void = {}
    var providerOrder: [ProviderID] = ProviderID.allCases

    var section: DashboardSection? = nil

    init(
        store: UsageStore,
        launchAtLogin: LaunchAtLoginController,
        usageDisplayMode: Binding<UsageDisplayMode>,
        selectedRegion: Binding<ProviderRegion> = .constant(.us),
        refreshInterval: Binding<RefreshIntervalOption>,
        availableUpdateVersion: String?,
        isCheckingForUpdates: Bool,
        checkForUpdates: @escaping @MainActor () -> Void = {},
        openSettings: @escaping @MainActor () -> Void = {},
        openAnalytics: @escaping @MainActor () -> Void = {},
        providerOrder: [ProviderID] = ProviderID.allCases,
        section: DashboardSection? = nil
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self._usageDisplayMode = usageDisplayMode
        self._selectedRegion = selectedRegion
        self._refreshInterval = refreshInterval
        self.availableUpdateVersion = availableUpdateVersion
        self.isCheckingForUpdates = isCheckingForUpdates
        self.checkForUpdates = checkForUpdates
        self.openSettings = openSettings
        self.openAnalytics = openAnalytics
        self.providerOrder = providerOrder
        self.section = section
    }

    var body: some View {
        Group {
            switch section {
            case .header: content.header.padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            case .rows: content.providerRowsContent.padding(.horizontal, 10).padding(.bottom, 5)
            case .footer: footer
            case nil: completeDashboard
            }
        }
        .frame(width: AppSurfaceLayout.dashboardWidth)
    }

    private var content: DashboardContentView {
        DashboardContentView(
            store: store,
            usageDisplayMode: $usageDisplayMode,
            selectedRegion: $selectedRegion,
            providerOrder: providerOrder
        )
    }

    private var completeDashboard: some View {
        DashboardContentView(
            store: store,
            usageDisplayMode: $usageDisplayMode,
            selectedRegion: $selectedRegion,
            providerOrder: providerOrder
        )
        .safeAreaBar(edge: .bottom, spacing: 0) {
            footer
        }
        .frame(width: AppSurfaceLayout.dashboardWidth)
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
                Text("Upstream \(version)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(UsagePalette.accent)
                    .lineLimit(1)
                    .help("Upstream AI Usage \(version) is available. Local fork builds do not auto-update.")
                    .accessibilityLabel("Upstream version \(version) available")
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
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10)
        .padding(.top, 3)
        .padding(.bottom, 6)
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
    @Binding var selectedRegion: ProviderRegion
    var providerOrder: [ProviderID] = ProviderID.allCases

    init(
        store: UsageStore,
        usageDisplayMode: Binding<UsageDisplayMode>,
        selectedRegion: Binding<ProviderRegion> = .constant(.us),
        providerOrder: [ProviderID] = ProviderID.allCases
    ) {
        self.store = store
        self._usageDisplayMode = usageDisplayMode
        self._selectedRegion = selectedRegion
        self.providerOrder = providerOrder
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            providerRows
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 5)
    }

    private var providerRows: some View {
        ScrollView { providerRowsContent }
            .scrollBounceBehavior(.basedOnSize)
    }

    var providerRowsContent: some View {
        VStack(spacing: 6) {
            ForEach(topLevelProviders) { provider in
                if provider != topLevelProviders.first {
                    Rectangle()
                        .fill(.primary.opacity(0.22))
                        .frame(height: 1)
                        .padding(.vertical, 2.5)
                        .accessibilityHidden(true)
                }
                if let state = store.states[provider] {
                    ProviderSectionView(
                        state: state,
                        displayMode: usageDisplayMode,
                        onReload: { store.refreshProvider(provider) }
                    )
                }
            }
        }
    }

    private var topLevelProviders: [ProviderID] {
        providerOrder.filter {
            $0.region == selectedRegion && store.isProviderVisibleInDashboard($0)
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Text("AI Usage")
                .font(.headline.weight(.semibold))
            Spacer()
            Picker("Region", selection: $selectedRegion) {
                ForEach(ProviderRegion.allCases) { region in
                    Text(region.badgeTitle)
                        .tag(region)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 116)
            .accessibilityLabel("Provider region")
            .accessibilityHint("Choose whether to show US or CN providers")
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
        .frame(height: 26)
    }
}
