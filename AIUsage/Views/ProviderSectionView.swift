import AppKit
import SwiftUI

enum ProviderSectionPart { case all, summary, details }

struct ProviderSectionView: View {
    let state: ProviderState
    let displayMode: UsageDisplayMode
    let embedded: Bool
    let expandedOverride: Bool?
    let part: ProviderSectionPart
    let onToggle: (() -> Void)?
    @State private var isExpanded = false
    private var showsDetails: Bool { expandedOverride ?? isExpanded }

    init(
        state: ProviderState,
        displayMode: UsageDisplayMode = .used,
        embedded: Bool = false,
        expandedOverride: Bool? = nil,
        part: ProviderSectionPart = .all,
        onToggle: (() -> Void)? = nil
    ) {
        self.state = state
        self.displayMode = displayMode
        self.embedded = embedded
        self.expandedOverride = expandedOverride
        self.part = part
        self.onToggle = onToggle
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if part != .details { providerHeader }
            if part != .details, !embedded, let scope = state.snapshot?.dashboardSubtitle {
                Text(scope)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 5)
            }
            if let snapshot = state.snapshot, snapshot.hasPanelContent {
                let ordered = ProviderDetailsLayout.windows(snapshot, expanded: true)
                let windows = part == .summary ? Array(ordered.prefix(2)) : part == .details ? Array(ordered.dropFirst(2)) : ProviderDetailsLayout.windows(snapshot, expanded: showsDetails)
                if !windows.isEmpty {
                    QuotaGrid(windows: windows, displayMode: displayMode)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                if part == .details || (part == .all && showsDetails) {
                    if !snapshot.consumptionShares.isEmpty {
                        ConsumedUsageBreakdown(shares: snapshot.consumptionShares)
                    }
                    if (!snapshot.windows.isEmpty || !snapshot.consumptionShares.isEmpty) &&
                        (snapshot.hasAdditionalUsageSection || (snapshot.resets?.availableCount ?? 0) > 0 || !snapshot.usageDetails.isEmpty) {
                        Divider()
                            .padding(.horizontal, 20)
                            .padding(.top, 2)
                            .padding(.bottom, 10)
                    }
                    if snapshot.hasAdditionalUsageSection {
                        AdditionalUsageSection(snapshot: snapshot, displayMode: displayMode)
                    }
                    ForEach(snapshot.usageDetails) { detail in
                        HStack(alignment: .firstTextBaseline) {
                            Text(detail.title).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(detail.value).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        .font(.caption)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }
                    if let resets = snapshot.resets, resets.availableCount > 0 {
                        ResetsRow(resets: resets)
                    }
                }
            } else if part != .details, state.isRefreshing {
                ProviderStatusRow(
                    message: "Checking local login…",
                    showsProgress: true
                )
            } else if part != .details, let failure = state.failure {
                FailureRow(failure: failure)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else if part != .details {
                ProviderStatusRow(
                    message: "No quota data yet.",
                    systemImage: "chart.bar.xaxis"
                )
            }

            if part != .details, state.isStale, let failure = state.failure {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(UsagePalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(failure.message)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
        }
    }

    private var providerHeader: some View {
        HStack(spacing: 9) {
            if state.snapshot?.xSubscription != nil {
                Text("𝕏").font(.title3).frame(width: 18, height: 18)
            } else {
                ProviderIcon(provider: state.provider, size: 18)
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
            }

            ProviderDisclosureTitle(
                title: state.snapshot?.displayName ?? state.provider.displayName,
                isExpanded: Binding(get: { showsDetails }, set: { value in
                    if let onToggle { onToggle() } else { isExpanded = value }
                }),
                canExpand: !embedded && state.snapshot.map(ProviderDetailsLayout.canExpand) == true
            )
            .layoutPriority(1)

            Spacer(minLength: 8)

            if !embedded, let email = state.snapshot?.identityEmail {
                AccountEmailLabel(email: email)
            }
            if !embedded, let plan = state.snapshot?.planName {
                Text(plan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.primary.opacity(0.06), in: Capsule())
                    .accessibilityLabel("Plan \(plan)")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

struct BillingUsagePresentation: Equatable {
    let title: String
    let valueText: String
    let accessibilityValue: String

    init(
        usage: BillingUsage,
        displayMode: UsageDisplayMode,
        locale: Locale = .current
    ) {
        switch usage {
        case let .boundedSpend(usedAmount, limitAmount, currencyCode):
            let displayedAmount: Double
            let suffix: String
            switch displayMode {
            case .used:
                displayedAmount = usedAmount
                suffix = "spent"
            case .remaining:
                displayedAmount = max(limitAmount - usedAmount, 0)
                suffix = "left"
            }
            let displayed = Self.currency(
                displayedAmount,
                code: currencyCode,
                locale: locale
            )
            let limit = Self.currency(
                limitAmount,
                code: currencyCode,
                locale: locale
            )
            title = "Extra usage"
            valueText = "\(displayed) / \(limit) \(suffix)"
            accessibilityValue = "\(displayed) \(suffix), \(limit) monthly limit"

        case let .unboundedSpend(usedAmount, currencyCode):
            let used = Self.currency(
                usedAmount,
                code: currencyCode,
                locale: locale
            )
            title = "Extra usage"
            valueText = "\(used) spent"
            accessibilityValue = "\(used) spent, no monthly limit"

        case let .flexCreditBalance(remainingCredits, usdValue):
            let value = Self.currency(
                usdValue,
                code: "USD",
                locale: locale
            )
            let credits = Self.integer(remainingCredits, locale: locale)
            title = "Credits"
            valueText = "\(value) · \(credits) credits left"
            accessibilityValue =
                "\(credits) Codex credits remaining, worth \(value)"
        }
    }

    private static func currency(
        _ amount: Double,
        code: String,
        locale: Locale
    ) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: amount)) ?? "\(amount)"
    }

    private static func integer(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct BillingUsageRow: View {
    let usage: BillingUsage
    let displayMode: UsageDisplayMode
    var titleOverride: String? = nil

    var body: some View {
        let presentation = BillingUsagePresentation(
            usage: usage,
            displayMode: displayMode
        )

        HStack(spacing: 7) {
            Image(systemName: "creditcard")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)

            Text(titleOverride ?? presentation.title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Text(presentation.valueText)
                .monospacedDigit()
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 24)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.title)
        .accessibilityValue(presentation.accessibilityValue)
    }
}

enum CompactCountdown {
    /// `1d 4h`, `4h 12m`, or `12m`; `nil` once the moment has passed.
    static func text(until date: Date, from now: Date) -> String? {
        let remaining = Int(date.timeIntervalSince(now))
        guard remaining > 0 else { return nil }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = max(1, (remaining % 3_600) / 60)
        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}

struct ResetsPresentation: Equatable {
    static let expiringSoonInterval: TimeInterval = 24 * 60 * 60

    let valueText: String
    let expiryText: String?
    let isExpiringSoon: Bool
    let helpText: String
    let accessibilityValue: String

    init(
        resets: UsageResets,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let active = resets.active(at: now)
        if let usable = active.usableCount, usable != active.availableCount {
            valueText = "\(active.availableCount) available · \(usable) usable now"
        } else {
            valueText = "\(active.availableCount) available"
        }

        if let next = active.nextExpiration,
           let countdown = CompactCountdown.text(until: next, from: now) {
            expiryText = "next expires in \(countdown)"
            isExpiringSoon = next.timeIntervalSince(now) <= Self.expiringSoonInterval
        } else {
            expiryText = nil
            isExpiringSoon = false
        }

        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        var details = active.expirations.map { "Expires \($0.formatted(style))" }
        let unknown = active.availableCount - active.expirations.count
        if unknown > 0 {
            details.append(
                unknown == 1
                    ? "1 reset without a known expiration"
                    : "\(unknown) resets without a known expiration"
            )
        }
        helpText = (["Banked usage-limit resets. Redeem them in the provider's app."]
            + details).joined(separator: "\n")
        accessibilityValue = ([valueText] + details).joined(separator: ", ")
    }
}

private struct ResetsRow: View {
    let resets: UsageResets

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        TimelineView(UsageMinuteSchedule(isActive: isPanelVisible)) { context in
            let presentation = ResetsPresentation(
                resets: resets,
                now: context.date
            )

            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)

                Text("Resets")
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text(presentation.valueText)
                        .fontWeight(.medium)
                    if let expiry = presentation.expiryText {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(expiry)
                            .foregroundStyle(
                                presentation.isExpiringSoon
                                    ? AnyShapeStyle(UsagePalette.warning)
                                    : AnyShapeStyle(.secondary)
                            )
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            .contentShape(Rectangle())
            .help(presentation.helpText)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Usage limit resets")
            .accessibilityValue(presentation.accessibilityValue)
        }
    }
}

private struct QuotaGrid: View {
    let windows: [QuotaWindow]
    let displayMode: UsageDisplayMode

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 0) {
                    ForEach(row) { window in
                        QuotaTile(window: window, displayMode: displayMode)
                    }
                }
            }
        }
    }

    private var rows: [[QuotaWindow]] {
        stride(from: 0, to: windows.count, by: 2).map { index in
            Array(windows[index..<min(index + 2, windows.count)])
        }
    }
}

private struct QuotaTile: View {
    let window: QuotaWindow
    let displayMode: UsageDisplayMode

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        TimelineView(UsageMinuteSchedule(isActive: isPanelVisible)) { context in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(window.kind.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(percentText)
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(valueTint)
                        Text(displayMode.valueSuffix)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(0.1))
                        Capsule()
                            .fill(progressTint)
                            .frame(
                                width: geometry.size.width *
                                    displayMode.renderedFraction(
                                        from: window.usedPercent
                                    )
                            )
                    }
                }
                .frame(height: 4)
                .accessibilityHidden(true)

                if let reset = window.resetsAt {
                    HStack(spacing: 5) {
                        Image(systemName: "clock")
                            .foregroundStyle(.tertiary)
                        Text(resetText(reset, relativeTo: context.date))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.kind.title)
            .accessibilityValue(accessibilityValue(relativeTo: context.date))
        }
    }

    private var percentText: String {
        let value = displayMode.displayedPercent(from: window.usedPercent)
        if value.rounded() == value {
            return "\(Int(value))%"
        }
        return "\(value.formatted(.number.precision(.fractionLength(1))))%"
    }

    private var valueTint: Color { UsageSeverity(usedPercent: window.usedPercent).color }

    private var progressTint: Color {
        switch window.usedPercent {
        case 85...: UsagePalette.critical
        case 60..<85: UsagePalette.warning
        default: UsagePalette.normalUsage
        }
    }

    private func resetText(_ date: Date, relativeTo now: Date) -> String {
        guard let countdown = CompactCountdown.text(until: date, from: now) else {
            return "Resetting"
        }
        return "Reset \(countdown)"
    }

    private func accessibilityValue(relativeTo now: Date) -> String {
        let usage = "\(percentText) \(displayMode.valueSuffix)"
        guard let reset = window.resetsAt else {
            return usage
        }
        return "\(usage), \(resetText(reset, relativeTo: now))"
    }
}

private struct ProviderStatusRow: View {
    let message: String
    var systemImage: String?
    var showsProgress = false

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress && isPanelVisible {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)
            }

            Text(message)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }
}

private struct FailureRow: View {
    let failure: ProviderFailure

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(failureTint)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(failure.message)
                    .foregroundStyle(failureTint)
                    .fixedSize(horizontal: false, vertical: true)

                if let retryAt = failure.retryAt {
                    HStack(spacing: 3) {
                        Text("Retry")
                        Text(retryAt, style: .relative)
                    }
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureTint: Color {
        failure.kind == .authentication
            ? Color(nsColor: .secondaryLabelColor)
            : UsagePalette.warning
    }

    private var symbol: String {
        switch failure.kind {
        case .authentication:
            "person.crop.circle.badge.exclamationmark"
        case .rateLimited:
            "hourglass"
        case .transient, .invalidResponse, .storage:
            "exclamationmark.triangle"
        }
    }
}

private enum ConsumptionShareColor {
    static func color(_ product: String) -> Color {
        switch product {
        case "cursor", "claude_code": Color(nsColor: .systemBlue)
        case "grok-chat", "chat": Color(nsColor: .systemPurple)
        case "grok-tasks", "cowork": Color(nsColor: .systemTeal)
        case "other": Color(nsColor: .systemGray)
        default: Color(nsColor: .systemOrange)
        }
    }
}

private struct ConsumedUsageBreakdown: View {
    let shares: [ConsumptionShare]
    private var visibleShares: [ConsumptionShare] { shares.filter { $0.percent > 0 } }
    private var total: Double { shares.reduce(0) { $0 + $1.percent } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share of usage consumed")
                .foregroundStyle(.primary)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    HStack(spacing: 0) {
                        ForEach(visibleShares) { product in
                            ConsumptionShareColor.color(product.id)
                                .frame(width: total > 0 ? geometry.size.width * product.percent / total : 0)
                        }
                    }
                    .clipShape(Capsule())
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            WrappingHStack(spacing: 12, lineSpacing: 6) {
                ForEach(visibleShares) { product in
                    HStack(spacing: 4) {
                        Circle().fill(ConsumptionShareColor.color(product.id)).frame(width: 5, height: 5)
                        Text(product.title).foregroundStyle(.secondary)
                        Text(total > 0 ? product.percent.formatted(.number.precision(.fractionLength(1))) + "%" : "0%")
                            .monospacedDigit().foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if total == 0 {
                Text("No weekly usage recorded yet").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .help("Product shares add up to the weekly usage already consumed, not your entire weekly allowance. Shares stay the same in Left and Used modes.")
    }
}

struct AdditionalUsageSection: View {
    let snapshot: ProviderSnapshot
    let displayMode: UsageDisplayMode

    private var billing: BillingUsage? { snapshot.displayedBillingUsage }
    private var enabled: Bool? { snapshot.additionalUsageEnabled ?? snapshot.xSubscription?.additionalUsageEnabled }
    private var reset: Date? { snapshot.xSubscription?.additionalUsageResetsAt }
    private var fraction: Double? {
        guard case let .boundedSpend(used, limit, _) = billing,
              used.isFinite, limit.isFinite, limit > 0 else { return nil }
        let consumed = min(max(used / limit, 0), 1)
        return displayMode == .used ? consumed : 1 - consumed
    }

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Additional Usage").fontWeight(.medium)
                Spacer(minLength: 8)
                if let balance = snapshot.displayedBalance {
                    HStack(spacing: 4) {
                        Text("Balance").foregroundStyle(.secondary)
                        Text(balance.amount, format: .currency(code: balance.currencyCode))
                            .monospacedDigit().fontWeight(.medium)
                    }
                }
                if enabled == false {
                    Text("Off").foregroundStyle(.secondary)
                } else if billing == nil && snapshot.displayedBalance == nil {
                    Text("Unavailable").foregroundStyle(.secondary)
                }
            }
            if let billing, enabled != false {
                let presentation = BillingUsagePresentation(usage: billing, displayMode: displayMode)
                HStack {
                    Text("Monthly spend").foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(presentation.valueText).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
                }
                if let fraction {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.1))
                            Capsule().fill(Color(nsColor: .systemOrange)).frame(width: geometry.size.width * fraction)
                        }
                    }
                    .frame(height: 4).accessibilityHidden(true)
                }
            }
            if reset != nil && enabled != false {
                TimelineView(UsageMinuteSchedule(isActive: isPanelVisible)) { context in
                    HStack {
                        if let reset {
                            Image(systemName: "clock").foregroundStyle(.tertiary)
                            Text(CompactCountdown.text(until: reset, from: context.date).map { "Reset " + $0 } ?? "Resetting")
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

struct GoogleAISectionView: View {
    let states: [ProviderState]
    let displayMode: UsageDisplayMode
    @State private var isExpanded = false
    var part: ProviderSectionPart = .all
    var expandedOverride: Bool? = nil
    var onToggle: (() -> Void)? = nil
    private var showsDetails: Bool { expandedOverride ?? isExpanded }
    private var visibleStates: [ProviderState] { part == .summary ? Array(states.prefix(1)) : part == .details || showsDetails ? states : Array(states.prefix(1)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if part != .details {
            HStack(spacing: 9) {
                Text("G").font(.headline.weight(.semibold)).frame(width: 18, height: 18)
                ProviderDisclosureTitle(title: "Google AI", isExpanded: Binding(get: { showsDetails }, set: { value in
                    if let onToggle { onToggle() } else { isExpanded = value }
                }),
                    canExpand: states.count > 1 || states.first?.snapshot.map(ProviderDetailsLayout.canExpand) == true)
                    .layoutPriority(1)
                Spacer()
                if let email = GoogleAIGroup.sharedEmail(states) {
                    AccountEmailLabel(email: email)
                }
                if let plan = GoogleAIGroup.sharedPlan(states) {
                    Text(plan.hasPrefix("Google AI ") ? String(plan.dropFirst("Google AI ".count)) : plan)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.06), in: Capsule())
                        .accessibilityLabel("Plan \(plan)")
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 5)
            Text(states.count == 1 && states.first?.provider == .gemini ? "Product usage • Gemini" : "Separate usage limits • Gemini & Antigravity")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.bottom, 8)
            }
            ForEach(Array(visibleStates.enumerated()), id: \.element.provider) { index, state in
                if index > 0 {
                    Divider()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 6)
                }
                ProviderSectionView(state: state, displayMode: displayMode, embedded: true, expandedOverride: showsDetails,
                                    part: part == .details && index == 0 ? .details : part == .summary ? .summary : .all)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AccountEmailLabel: View {
    let email: String
    var body: some View {
        Text(email)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(email)
            .accessibilityLabel("Account \(email)")
    }
}

/// One quota-grid row is visible until the user explicitly expands the provider.
enum ProviderDetailsLayout {
    static func windows(_ snapshot: ProviderSnapshot, expanded: Bool) -> [QuotaWindow] {
        let ordered = snapshot.provider == .claude
            ? snapshot.windows.filter { [.session, .weekly].contains($0.kind) }
                + snapshot.windows.filter { $0.kind == .fable }
                + snapshot.windows.filter { ![.session, .weekly, .fable].contains($0.kind) }
            : snapshot.windows
        return expanded ? ordered : Array(ordered.prefix(2))
    }
    static func canExpand(_ snapshot: ProviderSnapshot) -> Bool {
        snapshot.windows.count > 2 || !snapshot.consumptionShares.isEmpty || snapshot.hasAdditionalUsageSection ||
            (snapshot.resets?.availableCount ?? 0) > 0 || !snapshot.usageDetails.isEmpty
    }
}

private struct ProviderDisclosureTitle: View {
    let title: String
    @Binding var isExpanded: Bool
    let canExpand: Bool
    var body: some View {
        if canExpand {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 5) {
                    Text(title).font(.headline.weight(.semibold))
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse \(title) details" : "Expand \(title) details")
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        } else {
            Text(title).font(.headline.weight(.semibold))
        }
    }
}
