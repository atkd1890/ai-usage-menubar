import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController
    var isInSettingsWindow = false
    var showDashboard: @MainActor () -> Void = {}

    @State private var rowFrames: [ProviderID: CGRect] = [:]
    @State private var draggingProvider: ProviderID?

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: 16) {
                if !isInSettingsWindow { header }
                providersSection
                Divider()
                alertsSection
                Divider()
                generalSection
                footer
            }
        }
        .padding(20)
        .frame(width: AppSurfaceLayout.settingsWidth, alignment: .top)
        .onAppear {
            store.setTrackedProviders(preferences.trackedProviderIDs)
            store.setRefreshInterval(preferences.refreshInterval)
            launchAtLogin.synchronize()
        }
        .onChange(of: preferences.geminiNativeAccessAllowed) { _, _ in
            store.refreshNow()
        }
        .onChange(of: preferences.geminiSource) { _, _ in
            store.refreshNow()
        }
        .onChange(of: preferences.refreshInterval) { _, interval in
            store.setRefreshInterval(interval)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: showDashboard) {
                Label("Usage", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Back to usage")
            .accessibilityHint("Shows the usage dashboard")

            Text("Settings")
                .font(.title3.weight(.semibold))

            Spacer()
        }
    }

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(
                title: "Providers",
                systemImage: "switch.2",
                detail: "Choose what to track and what appears in the menu bar."
            )

            ForEach(ProviderRegion.allCases) { region in
                VStack(alignment: .leading, spacing: 5) {
                    Text(region.badgeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                    providerRowsContent(descriptors(for: region), in: region)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func regionOrder(for region: ProviderRegion) -> [ProviderID] {
        preferences.providerOrder.filter { $0.isEnabledInBuild && $0.region == region }
    }

    private func descriptors(for region: ProviderRegion) -> [ProviderDescriptor] {
        regionOrder(for: region).map(\.descriptor)
    }

    private func providerRowsContent(
        _ descriptors: [ProviderDescriptor],
        in region: ProviderRegion
    ) -> some View {
        let space = Self.rowsSpace(for: region)
        return VStack(spacing: 0) {
            ProviderSettingsHeader()

            Divider()

            ForEach(descriptors) { descriptor in
                let availableItems = store.availableMenuBarItems(
                    for: descriptor.id
                )
                ProviderSettingsRow(
                    descriptor: descriptor,
                    state: store.states[descriptor.id],
                    isTracking: preferences.isTracking(descriptor.id),
                    isVisible:
                        store.states[descriptor.id]?.isToolInstalled != false &&
                        preferences.isProviderShownInMenuBar(descriptor.id),
                    selectedMetrics: Set(
                        preferences.selectedMenuBarMetrics(
                            for: descriptor.id
                        )
                    ),
                    availableItems: availableItems,
                    setTracking: { enabled in
                        preferences.setTracking(
                            enabled,
                            for: descriptor.id
                        )
                        store.setTrackedProviders(
                            preferences.trackedProviderIDs
                        )
                    },
                    setVisible: { enabled in
                        preferences.setMenuBarVisibility(
                            enabled,
                            for: descriptor.id,
                            availableItems: availableItems
                        )
                    },
                    setMetric: { item, enabled in
                        preferences.setMenuBarMetric(
                            enabled,
                            item: item,
                            availableItems: availableItems
                        )
                    },
                    isDragging: draggingProvider == descriptor.id,
                    reportFrame: { rowFrames[descriptor.id] = $0 },
                    dragChanged: { handleDrag(of: descriptor.id, at: $0, in: region) },
                    dragEnded: { draggingProvider = nil },
                    move: { offset in
                        moveProvider(descriptor.id, by: offset, in: region)
                    },
                    rowsSpace: space,
                    loginPreferences: preferences, loginChanged: { store.reconnect(providerIDs: [descriptor.id]) }
                )

                if descriptor.id != descriptors.last?.id {
                    Divider()
                }
            }
        }
        .coordinateSpace(.named(space))
    }

    private static func rowsSpace(for region: ProviderRegion) -> String {
        "providerRows.\(region.rawValue)"
    }

    private func moveProvider(_ provider: ProviderID, by offset: Int, in region: ProviderRegion) {
        let order = regionOrder(for: region)
        guard let index = order.firstIndex(of: provider) else { return }
        let targetIndex = index + offset
        guard order.indices.contains(targetIndex) else { return }
        preferences.moveProvider(provider, to: order[targetIndex])
    }

    /// Live reorder: the dragged provider takes the place of the row the
    /// pointer has moved past.
    private func handleDrag(of provider: ProviderID, at point: CGPoint, in region: ProviderRegion) {
        draggingProvider = provider
        guard let target = ProviderRowDrag.target(
            of: provider,
            at: point.y,
            order: regionOrder(for: region),
            frames: rowFrames
        ) else { return }
        preferences.moveProvider(provider, to: target)
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "Alerts", systemImage: "bell", detail: "System notifications · follows macOS Focus.")
            AlertSettingsView(settings: preferences.alerts, enable: { store.alertController?.requestPermission() })
                .padding(.leading, 12)
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(title: "General", systemImage: "gearshape", detail: "Refresh and startup preferences.")

            Grid(
                alignment: .leading,
                horizontalSpacing: 18,
                verticalSpacing: 11
            ) {
                GridRow {
                    Text("Refresh")
                        .foregroundStyle(.secondary)

                    Picker("Refresh", selection: $preferences.refreshInterval) {
                        ForEach(RefreshIntervalOption.allCases) { option in
                            Text(option.title)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .leading)
                }

                GridRow(alignment: .top) {
                    Text("Startup")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { launchAtLogin.isEnabled },
                                set: { launchAtLogin.setEnabled($0) }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        if launchAtLogin.requiresApproval {
                            Text("Approval needed in System Settings")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else if let error = launchAtLogin.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .padding(.leading, 12)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Spacer()

            Button("Quit AI Usage") {
                NSApplication.shared.terminate(nil)
            }
        }
        .controlSize(.small)
        .padding(.top, 2)
    }

    private func sectionHeader(
        title: String,
        systemImage: String,
        detail: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct ProviderSettingsHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("Provider")
                .frame(width: 130, alignment: .leading)
            Text("Login method")
                .frame(width: 192, alignment: .leading)
            Text("Track")
                .frame(width: 44)
            Label("Menu Bar", systemImage: "menubar.rectangle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }
}

private struct ProviderSettingsRow: View {
    let descriptor: ProviderDescriptor
    let state: ProviderState?
    let isTracking: Bool
    let isVisible: Bool
    let selectedMetrics: Set<MenuBarMetricID>
    let availableItems: [MenuBarItemID]
    let setTracking: (Bool) -> Void
    let setVisible: (Bool) -> Void
    let setMetric: (MenuBarItemID, Bool) -> Void
    let isDragging: Bool
    let reportFrame: (CGRect) -> Void
    let dragChanged: (CGPoint) -> Void
    let dragEnded: () -> Void
    let move: (Int) -> Void
    let rowsSpace: String

    var displayNameOverride: String? = nil
    var selectedMetricItems: Set<MenuBarItemID>? = nil

    var loginPreferences: AppPreferences? = nil
    var loginChanged: () -> Void = {}
    var connectionStates: [ProviderState]? = nil
    @State private var loginRevision = 0

    private var displayName: String { displayNameOverride ?? state?.snapshot?.displayName ?? descriptor.displayName }
    private func isSelected(_ item: MenuBarItemID) -> Bool {
        selectedMetricItems?.contains(item) ?? selectedMetrics.contains(item.metric)
    }
    private func metricTitle(_ item: MenuBarItemID) -> String {
        selectedMetricItems == nil ? item.metric.title : item.provider.displayName + " · " + item.metric.title
    }

    private var connectionStatus: some View {
        let _ = ConfirmedSchemaObserver.shared.revision
        let states = connectionStates ?? [state].compactMap { $0 }
        let activeWarnings: (ProviderState) -> [ProviderDiagnosticWarning] = { state in
            guard let snapshot = state.snapshot else { return [] }
            return ConfirmedSchemaStore.shared.activeWarnings(for: snapshot)
        }
        let status = states.first(where: { $0.isRefreshing })
            ?? states.first(where: { $0.failure != nil || $0.snapshot == nil })
            ?? states.first(where: { !activeWarnings($0).isEmpty })
            ?? states.first
        let notes = status.map { activeWarnings($0).map(\.summary).joined(separator: "\n") } ?? ""
        return ProviderStatusView(state: status)
            .help(status?.failure?.message ?? (notes.isEmpty ? "Usage loaded successfully using the selected login method." : notes))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 8) {
                if state?.snapshot?.xSubscription != nil {
                    Text("𝕏").font(.title2).frame(width: 22, height: 22)
                } else {
                    ProviderIcon(provider: descriptor.id, size: 22)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.body.weight(.medium))

                    if isTracking {
                        connectionStatus
                    } else {
                        Label("Off", systemImage: "pause.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 130, alignment: .leading)

            if let preferences = loginPreferences {
                VStack(alignment: .leading, spacing: 4) {
                    let methods = ProviderLoginMethod.supported(for: descriptor.id)
                    let currentMethod: ProviderLoginMethod = {
                        _ = loginRevision
                        return preferences.loginMethod(for: descriptor.id)
                    }()
                    FixedWidthPopUpButton(
                        items: methods.map { .init(value: $0, title: $0.title(for: descriptor.id)) },
                        selection: currentMethod,
                        width: 184,
                        accessibilityLabel: "Login method for \(displayName)",
                        helpText: "Uses the selected credential source immediately and reports the quota fetch result beneath the provider name."
                    ) { method in
                        preferences.setLoginMethod(method, for: descriptor.id)
                        loginRevision += 1
                        loginChanged()
                    }
                    .frame(width: 184, alignment: .leading)
                    if [ProviderID.manus, .muse, .qwen, .kimi, .adobe, .minimax, .qoder].contains(descriptor.id),
                       state?.failure?.kind == .storage {
                        let method = preferences.loginMethod(for: descriptor.id)
                        if method == .edge {
                            Button("Allow Edge access…") {
                                if BrowserDatabaseAccess.request(providerName: displayName, source: .edge) { loginChanged() }
                            }
                            .controlSize(.small)
                            .help("Choose only Edge Default's Cookies file using the macOS permission dialog.")
                        } else if method == .chrome {
                            Button("Allow Chrome access…") {
                                if BrowserDatabaseAccess.request(providerName: displayName, source: .chrome) { loginChanged() }
                            }
                            .controlSize(.small)
                            .help("Choose only Chrome Default's Cookies file using the macOS permission dialog.")
                        }
                    }
                    if let account = state?.snapshot?.identityEmail {
                        Text(account).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(account)
                    }

                }
                .font(.caption)
                .frame(width: 192, alignment: .leading)
            }

            Toggle(
                "Track \(displayName)",
                isOn: Binding(
                    get: { isTracking },
                    set: { enabled in setTracking(enabled) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .frame(width: 44)
            .accessibilityLabel("Track \(displayName)")

            HStack(spacing: 8) {
                Toggle(
                    "Show \(displayName) in Menu Bar",
                    isOn: Binding(
                        get: { isVisible },
                        set: { enabled in setVisible(enabled) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(width: 44)
                .disabled(!isTracking || (!isVisible && !canEnableMenuBar))
                .help(
                    isVisible
                        ? "Hide \(displayName) from the menu bar"
                        : "Show \(displayName) in the menu bar"
                )

                Divider()
                    .frame(height: 20)

                menuBarMetrics
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            dragHandle
        }
        .padding(.vertical, 9)
        .background(
            isDragging ? Color.accentColor.opacity(0.12) : .clear,
            in: .rect(cornerRadius: 8)
        )
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(rowsSpace))
        } action: {
            reportFrame($0)
        }
        .accessibilityElement(children: .contain)
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(
                    minimumDistance: 2,
                    coordinateSpace: .named(rowsSpace)
                )
                .onChanged { dragChanged($0.location) }
                .onEnded { _ in dragEnded() }
            )
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
            .help("Drag to reorder \(displayName)")
            .accessibilityLabel("Reorder \(displayName)")
            .accessibilityAction(named: "Move Up") { move(-1) }
            .accessibilityAction(named: "Move Down") { move(1) }
    }

    @ViewBuilder
    private var menuBarMetrics: some View {
        if availableItems.isEmpty {
            Text(emptyMetricsMessage)
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            WrappingHStack(spacing: 8, lineSpacing: 4) {
                ForEach(availableItems) { item in
                    Toggle(
                        metricTitle(item),
                        isOn: Binding(
                            get: {
                                isSelected(item)
                            },
                            set: { enabled in
                                setMetric(item, enabled)
                            }
                        )
                    )
                    .font(.caption)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(!isTracking || !isVisible)
                    .help(
                        enabledMetricHelp(
                            item.metric,
                            isSelected:
                                isSelected(item)
                        )
                    )
                }
            }
        }
    }

    private var canEnableMenuBar: Bool {
        state?.isToolInstalled != false &&
            (!(selectedMetricItems?.isEmpty ?? selectedMetrics.isEmpty) || !availableItems.isEmpty)
    }

    private var emptyMetricsMessage: String {
        if state?.isToolInstalled == false {
            return "Not installed"
        }
        if state?.isRefreshing == true {
            return "Loading available metrics…"
        }
        if let failure = state?.failure { return failure.message }
        return "No usage metrics returned"
    }

    private func enabledMetricHelp(
        _ metric: MenuBarMetricID,
        isSelected: Bool
    ) -> String {
        isSelected
            ? "Hide \(metric.title) for \(displayName)"
            : "Show \(metric.title) for \(displayName)"
    }
}

/// Where a dragged provider row belongs.
enum ProviderRowDrag {
    /// The provider whose place the dragged row takes, or `nil` to stay.
    ///
    /// A row is passed only once the pointer crosses its middle. Rows differ
    /// in height, so swapping as soon as the pointer entered one would leave
    /// the pointer over the row it had just swapped with, and the two would
    /// trade places on every move. Direction comes from the order rather than
    /// the frames, which still describe the old layout until it is redrawn.
    static func target(
        of provider: ProviderID,
        at y: CGFloat,
        order: [ProviderID],
        frames: [ProviderID: CGRect]
    ) -> ProviderID? {
        guard let index = order.firstIndex(of: provider) else { return nil }
        let passedBelow = order[(index + 1)...].last { below in
            frames[below].map { y > $0.midY } ?? false
        }
        let passedAbove = order[..<index].first { above in
            frames[above].map { y < $0.midY } ?? false
        }
        return passedBelow ?? passedAbove
    }
}

/// Lays out its views in a row and continues on the next line when the
/// row is full, so a provider with many metrics never truncates one.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let lines = lines(for: subviews, maxWidth: proposal.width ?? .infinity)
        let height = lines.map(\.height).reduce(0, +) +
            lineSpacing * CGFloat(max(lines.count - 1, 0))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(for: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(for subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !current.indices.isEmpty,
               current.width + spacing + size.width > maxWidth {
                lines.append(current)
                current = Line()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            lines.append(current)
        }
        return lines
    }
}

private struct ProviderStatusView: View {
    let state: ProviderState?

    var body: some View {
        let _ = ConfirmedSchemaObserver.shared.revision
        let presentation = ProviderStatusPresentation(state: state)

        Label(presentation.text, systemImage: presentation.systemImage)
            .font(.caption)
            .foregroundStyle(presentation.color)
            .labelStyle(.titleAndIcon)
            .accessibilityLabel(presentation.text)
    }
}

private struct ProviderStatusPresentation {
    let text: String
    let systemImage: String
    let color: Color

    init(state: ProviderState?) {
        guard let state else {
            text = "Checking…"
            systemImage = "clock"
            color = .secondary
            return
        }

        if state.isRefreshing {
            text = "Connecting…"
            systemImage = "arrow.triangle.2.circlepath"
            color = .secondary
            return
        }

        if state.isToolInstalled == false {
            text = "Not installed"
            systemImage = "minus.circle"
            color = .secondary
            return
        }

        if let failure = state.failure {
            switch failure.kind {
            case .authentication:
                text = "Not logged in"
                systemImage = "person.crop.circle.badge.exclamationmark"
                color = .orange
            case .rateLimited:
                text = "Rate limited"
                systemImage = "hourglass"
                color = .orange
            case .transient, .invalidResponse, .storage:
                text = state.snapshot == nil
                    ? "Temporarily unavailable"
                    : "Showing last update"
                systemImage = "exclamationmark.triangle"
                color = .orange
            }
            return
        }

        if let snapshot = state.snapshot,
           case let activeWarnings = ConfirmedSchemaStore.shared.activeWarnings(for: snapshot),
           !activeWarnings.isEmpty {
            let onlyCompatibility = activeWarnings.allSatisfy { $0.kind == .partialCompatibility }
            text = onlyCompatibility ? "Connected · Partial data" : "Connected · API changed"
            systemImage = "exclamationmark.triangle"
            color = .yellow
        } else if state.snapshot != nil {
            text = "Connected"
            systemImage = "checkmark.circle.fill"
            color = .green
        } else {
            text = state.isRefreshing ? "Checking…" : "Waiting for usage"
            systemImage = "clock"
            color = .secondary
        }
    }
}

private struct AlertSettingsView: View {
    @Bindable var settings: AlertPreferences
    let enable: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("An agent will run out before it resets", subtitle: "Based on your pace, not fixed 80% / 90% marks", binding: $settings.runningOut)
            row("Extra balance starts being used", subtitle: "A limit was hit and paid usage kicked in", binding: $settings.paidUsage)
            row("A capped limit is back", subtitle: "A previously capped limit is available again", binding: $settings.limitBack)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Heads-up lead time")
                    Text("How early to warn before your quota is predicted to run out")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Heads-up lead time", selection: $settings.leadMinutes) {
                    ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }.labelsHidden().frame(width: 140)
            }
        }
        .toggleStyle(.switch).controlSize(.small)
        .onChange(of: settings.enabled) { _, enabled in if enabled { enable() } }
    }
    private func row(_ title: String, subtitle: String?, binding: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle(title, isOn: binding).labelsHidden()
        }
    }
}

private struct FixedWidthPopUpButton<Option: Hashable>: NSViewRepresentable {
    struct Item: Equatable {
        let value: Option
        let title: String
    }

    let items: [Item]
    let selection: Option
    let width: CGFloat
    let accessibilityLabel: String
    let helpText: String
    let onSelect: (Option) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.lineBreakMode = .byTruncatingTail
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        configure(button, context: context)
        return button
    }

    func updateNSView(_ nsView: NSPopUpButton, context: Context) {
        configure(nsView, context: context)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: nsView.fittingSize.height)
    }

    private func configure(_ button: NSPopUpButton, context: Context) {
        context.coordinator.items = items
        context.coordinator.onSelect = onSelect
        let titles = items.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let selectedIndex = items.firstIndex(where: { $0.value == selection }),
           button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.toolTip = helpText
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: [Item]
        var onSelect: (Option) -> Void

        init(items: [Item], onSelect: @escaping (Option) -> Void) {
            self.items = items
            self.onSelect = onSelect
        }

        @objc func selectionChanged(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard items.indices.contains(index) else { return }
            onSelect(items[index].value)
        }
    }
}
