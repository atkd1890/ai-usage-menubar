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
                let summarySeries = state.snapshot.flatMap {
                    Array(ProviderDetailsLayout.windows($0, expanded: true).prefix(2))
                        .first(where: { $0.series.count >= 2 })?.series
                } ?? []
                if !summarySeries.isEmpty {
                    HStack(spacing: 4) {
                        Text("Separate app limits •")
                        ForEach(Array(summarySeries.enumerated()), id: \.element.id) { index, item in
                            if index > 0 {
                                Text("&")
                            }
                            HStack(spacing: 3.5) {
                                Circle()
                                    .fill(QuotaSeriesColor.color(item.id))
                                    .frame(width: 5, height: 5)
                                Text(item.title)
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 3.5)
                    .help("Antigravity and Antigravity IDE have separate quota pools. Each summary bar overlays both apps with the longer bar underneath so both remain visible.")
                } else {
                    Text(scope)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 13)
                        .padding(.bottom, 3.5)
                }
            }
            if let snapshot = state.snapshot, snapshot.hasPanelContent {
                let effectiveDetails = ProviderDetailsLayout.displayedUsageDetails(snapshot)
                let showsInlineDetails = snapshot.windows.isEmpty && snapshot.quotaSections.isEmpty && !effectiveDetails.isEmpty
                let summary = ProviderDetailsLayout.summaryWindows(snapshot)
                let detailGridWindows = ProviderDetailsLayout.detailWindows(snapshot)
                if part != .details && !summary.isEmpty {
                    QuotaGrid(windows: summary, displayMode: displayMode)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 4.5)
                }
                if showsInlineDetails && part != .details {
                    VStack(alignment: .leading, spacing: 6) {
                        usageDetailsRows(effectiveDetails)
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
                }
                if part == .details || (part == .all && showsDetails) {
                    if !detailGridWindows.isEmpty {
                        QuotaGrid(windows: detailGridWindows, displayMode: displayMode)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4.5)
                    }
                    ForEach(snapshot.quotaSections) { section in
                        Divider()
                            .padding(.horizontal, 13)
                            .padding(.top, 1.5)
                            .padding(.bottom, 5.5)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(QuotaSeriesColor.color(section.id))
                                .frame(width: 5, height: 5)
                            Text(section.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 13)
                        .padding(.bottom, 2)
                        QuotaGrid(windows: section.windows, displayMode: displayMode)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4.5)
                    }
                    if !snapshot.consumptionShares.isEmpty {
                        if !snapshot.windows.isEmpty || !snapshot.quotaSections.isEmpty {
                            Divider()
                                .padding(.horizontal, 13)
                                .padding(.top, 1.5)
                                .padding(.bottom, 7.5)
                        }
                        ConsumedUsageBreakdown(shares: snapshot.consumptionShares)
                    }
                    let showsAdditional = ProviderDetailsLayout.showsAdditionalUsageRow(snapshot)
                    let hasResets = (snapshot.resets?.availableCount ?? 0) > 0
                    let hasDetails = !showsInlineDetails && !effectiveDetails.isEmpty
                    if showsAdditional || hasDetails || hasResets {
                        if !snapshot.windows.isEmpty || !snapshot.quotaSections.isEmpty || !snapshot.consumptionShares.isEmpty {
                            Divider()
                                .padding(.horizontal, 13)
                                .padding(.top, 1.5)
                                .padding(.bottom, 7.5)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            if hasResets, let resets = snapshot.resets {
                                ResetsRow(resets: resets)
                            }
                            if showsAdditional {
                                AdditionalUsageSection(snapshot: snapshot, displayMode: displayMode)
                            }
                            if hasDetails {
                                usageDetailsRows(effectiveDetails)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.bottom, 8)
                    }
                }
            } else if part != .details, state.isRefreshing {
                ProviderStatusRow(
                    message: "Checking local login…",
                    showsProgress: true
                )
            } else if part != .details, let failure = state.failure {
                FailureRow(failure: failure)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 12)
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
                    .padding(.horizontal, 13)
                    .padding(.bottom, 9)
            }
        }
    }

    @ViewBuilder
    private func usageDetailsRows(_ details: [ProviderUsageDetail]) -> some View {
        ForEach(details) { detail in
            if detail.id.hasSuffix(".credits") {
                AdditionalCreditsRow(detail: detail, displayMode: displayMode)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(detail.title).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text(detail.value).monospacedDigit().multilineTextAlignment(.trailing)
                }
                .font(.caption)
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

            let _ = ConfirmedSchemaObserver.shared.revision
            let activeWarnings = state.snapshot.map { ConfirmedSchemaStore.shared.activeWarnings(for: $0) } ?? []
            if !embedded, !activeWarnings.isEmpty {
                DiagnosticWarningBadge(
                    providerName: state.snapshot?.displayName ?? state.provider.displayName,
                    warnings: activeWarnings,
                    onUpdate: {
                        ConfirmedSchemaStore.shared.confirm(warnings: activeWarnings, for: state.provider)
                        ConfirmedSchemaObserver.shared.notifyChanged()
                    }
                )
            }

            Spacer(minLength: 8)

            if !embedded, let email = state.snapshot?.identityEmail {
                AccountEmailLabel(email: email)
            }
            if !embedded, let plan = state.snapshot?.planName {
                let formattedPlan = [ProviderID.gemini, .antigravity].contains(state.provider)
                    ? plan.replacingOccurrences(of: "Google AI ", with: "")
                    : (state.provider == .muse ? plan.replacingOccurrences(of: "muse", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces) : plan)
                Text(formattedPlan.isEmpty ? plan : formattedPlan)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2.5)
                    .background(.primary.opacity(0.06), in: Capsule())
                    .accessibilityLabel("Plan \(plan)")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .padding(.bottom, 4)
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
        .frame(maxWidth: .infinity, minHeight: 22)
        .padding(.horizontal, 13)
        .padding(.bottom, 6.5)
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
                    .fontWeight(.medium)
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
            .frame(maxWidth: .infinity)
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
        ProviderDetailsLayout.rows(windows)
    }
}

private struct BoundedAdditionalBarBlock: View {
    let label: String
    let valueText: String
    let fraction: Double?
    let resetsAt: Date?
    let resetFallbackText: String?
    let resetFallbackIcon: String

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(valueText).monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.leading, 21)

        if let fraction {
            let clamped = min(max(fraction, 0), 1)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.1))
                    Capsule().fill(Color(nsColor: .systemOrange)).frame(width: geometry.size.width * clamped)
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
            .padding(.leading, 21)
        }

        if let resetsAt {
            TimelineView(UsageMinuteSchedule(isActive: isPanelVisible)) { context in
                HStack(spacing: 5) {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Text(CompactCountdown.text(until: resetsAt, from: context.date).map { "Reset " + $0 } ?? "Resetting")
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 21)
            }
        } else if let resetFallbackText {
            HStack(spacing: 5) {
                Image(systemName: resetFallbackIcon).foregroundStyle(.tertiary)
                Text(resetFallbackText)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.leading, 21)
        }
    }
}

private struct AdditionalCreditsRow: View {
    let detail: ProviderUsageDetail
    let displayMode: UsageDisplayMode

    private var segments: [(label: String, number: String)] {
        let raw = detail.value.components(separatedBy: " · ")
        let parsed: [(label: String, number: String)] = raw.compactMap { segment in
            guard let space = segment.range(of: " ", options: .backwards) else { return nil }
            let label = String(segment[..<space.lowerBound])
            let number = String(segment[space.upperBound...])
            guard label.first?.isLetter == true, !label.contains("/"), number.first?.isNumber == true else { return nil }
            return (label: label, number: number)
        }
        return parsed.count == raw.count ? parsed : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "plus.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)

                Text(detail.title)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if detail.boundedProgress == nil {
                    if segments.isEmpty {
                        let isMuted = detail.value == "N/A" || detail.value == "Off"
                        Text(detail.value)
                            .monospacedDigit()
                            .fontWeight(isMuted ? .regular : .medium)
                            .foregroundStyle(isMuted ? .secondary : .primary)
                    } else {
                        HStack(spacing: 4) {
                            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                                if index > 0 {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                }
                                HStack(spacing: 4) {
                                    Text(segment.label)
                                        .foregroundStyle(.secondary)
                                    Text(segment.number)
                                        .monospacedDigit()
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }
                }
            }
            .lineLimit(1)

            if let bounded = detail.boundedProgress {
                BoundedAdditionalBarBlock(
                    label: bounded.label,
                    valueText: bounded.valueText(for: displayMode),
                    fraction: bounded.fraction(for: displayMode),
                    resetsAt: bounded.resetsAt,
                    resetFallbackText: bounded.resetNote,
                    resetFallbackIcon: bounded.resetsAt == nil && bounded.resetNote == "No reset" ? "infinity" : "clock"
                )
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct QuotaTile: View {
    let window: QuotaWindow
    let displayMode: UsageDisplayMode

    @Environment(\.usagePanelVisible) private var isPanelVisible

    var body: some View {
        TimelineView(UsageMinuteSchedule(isActive: isPanelVisible)) { context in
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(window.kind.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    if window.isUnlimited {
                        Text("Unlimited")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(nsColor: .systemIndigo))
                            .lineLimit(1)
                    } else if window.isInactive {
                        Text("—")
                            .font(.title3.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    } else if window.series.count >= 2 {
                        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
                            ForEach(Array(window.series.enumerated()), id: \.element.id) { index, reading in
                                if index > 0 {
                                    Text("/")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.tertiary)
                                }
                                Text(formattedPercent(for: reading.usedPercent))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(QuotaSeriesColor.color(reading.id))
                            }
                            Text(displayMode.valueSuffix)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(percentText)
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(valueTint)
                            Text(displayMode.valueSuffix)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                    }
                }

                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.primary.opacity(0.1))
                        if window.isUnlimited {
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [Color(nsColor: .systemIndigo), Color(nsColor: .systemPurple)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                        } else if window.isInactive {
                            Capsule()
                                .fill(Color(nsColor: .tertiaryLabelColor).opacity(0.45))
                        } else if window.series.count >= 2 {
                            let barLayout = DualQuotaBarLayout.layout(
                                series: window.series,
                                displayMode: displayMode
                            )
                            if barLayout.splitEqual {
                                VStack(spacing: 0) {
                                    ForEach(barLayout.layers, id: \.id) { layer in
                                        Rectangle()
                                            .fill(QuotaSeriesColor.color(layer.id))
                                    }
                                }
                                .frame(width: geometry.size.width * barLayout.layers[0].fraction)
                                .clipShape(Capsule())
                            } else {
                                ForEach(barLayout.layers, id: \.id) { layer in
                                    if layer.fraction > 0 {
                                        Capsule()
                                            .fill(QuotaSeriesColor.color(layer.id))
                                            .frame(width: geometry.size.width * layer.fraction)
                                    }
                                }
                            }
                        } else {
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
                }
                .frame(height: 4)
                .accessibilityHidden(true)

                let countText = window.countText(for: displayMode) ?? window.trailingDetail
                let subtext = window.isInactive ? window.inactiveDetail : nil
                if window.resetsAt != nil || countText != nil || subtext != nil {
                    HStack(spacing: 5) {
                        if let reset = window.resetsAt {
                            Image(systemName: "clock")
                                .foregroundStyle(.tertiary)
                            Text(resetText(reset, relativeTo: context.date))
                                .foregroundStyle(.secondary)
                        } else if let subtext {
                            Text(subtext)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if let countText {
                            Text(countText)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 53, alignment: .topLeading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(window.kind.title)
            .accessibilityValue(accessibilityValue(relativeTo: context.date))
        }
    }

    private var percentText: String {
        formattedPercent(for: window.usedPercent)
    }

    private func formattedPercent(for usedPercent: Double) -> String {
        let value = displayMode.displayedPercent(from: usedPercent)
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
        if window.isUnlimited {
            return "Unlimited"
        }
        if window.isInactive {
            return window.inactiveDetail ?? "Unavailable"
        }
        let usage: String
        if window.series.count >= 2 {
            usage = window.series.map { reading in
                "\(reading.title) \(formattedPercent(for: reading.usedPercent)) \(displayMode.valueSuffix)"
            }.joined(separator: ", ")
        } else {
            usage = "\(percentText) \(displayMode.valueSuffix)"
        }
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
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.bottom, 8)
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

enum QuotaSeriesColor {
    static func color(_ id: String) -> Color {
        switch id {
        case "antigravity-app": Color(nsColor: .systemBlue)
        case "antigravity-ide": Color(nsColor: .systemPurple)
        default: Color(nsColor: .systemTeal)
        }
    }
}

struct DualQuotaBarLayer: Equatable {
    let id: String
    let fraction: Double
}

enum DualQuotaBarLayout {
    /// Returns layers ordered back-to-front (longest first so it sits underneath and
    /// never covers the shorter bar), plus whether equal non-zero bars should split
    /// vertically so both colors remain visible.
    static func layout(
        series: [QuotaSeriesReading],
        displayMode: UsageDisplayMode
    ) -> (layers: [DualQuotaBarLayer], splitEqual: Bool) {
        let raw = series.map {
            DualQuotaBarLayer(
                id: $0.id,
                fraction: displayMode.renderedFraction(from: $0.usedPercent)
            )
        }
        if raw.count == 2,
           raw[0].fraction > 0,
           abs(raw[0].fraction - raw[1].fraction) < 0.005 {
            return (raw, true)
        }
        let ordered = raw.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.fraction != rhs.element.fraction {
                    return lhs.element.fraction > rhs.element.fraction
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        return (ordered, false)
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
        VStack(alignment: .leading, spacing: 6.5) {
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
            WrappingHStack(spacing: 12, lineSpacing: 5) {
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
        .padding(.horizontal, 13)
        .padding(.bottom, 8)
        .help("Product shares add up to the weekly usage already consumed, not your entire weekly allowance. Shares stay the same in Left and Used modes.")
    }
}

struct AdditionalUsageSection: View {
    let snapshot: ProviderSnapshot
    let displayMode: UsageDisplayMode

    private var billing: BillingUsage? { snapshot.displayedBillingUsage }
    private var enabled: Bool? { snapshot.additionalUsageEnabled ?? snapshot.xSubscription?.additionalUsageEnabled }
    private var reset: Date? { snapshot.effectiveAdditionalUsageResetsAt }
    private var fraction: Double? {
        guard case let .boundedSpend(used, limit, _) = billing,
              used.isFinite, limit.isFinite, limit > 0 else { return nil }
        let consumed = min(max(used / limit, 0), 1)
        return displayMode == .used ? consumed : 1 - consumed
    }

    static func spendLabel(for provider: ProviderID) -> String {
        provider == .muse ? "Top-up" : "Monthly spend"
    }

    static func resetFallback(for provider: ProviderID) -> (icon: String, text: String) {
        provider == .muse ? ("infinity", "No reset") : ("clock", "Resets monthly")
    }

    static func showsHeaderBalance(for snapshot: ProviderSnapshot) -> Bool {
        guard snapshot.displayedBalance != nil else { return false }
        return !(snapshot.provider == .muse && snapshot.displayedBillingUsage != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "creditcard")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 14)

                Text("Additional Usage")
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if Self.showsHeaderBalance(for: snapshot), let balance = snapshot.displayedBalance {
                    HStack(spacing: 4) {
                        Text("Balance").foregroundStyle(.secondary)
                        Text(balance.amount, format: .currency(code: balance.currencyCode))
                            .monospacedDigit().fontWeight(.medium)
                    }
                }
                if enabled == false {
                    Text("Off").foregroundStyle(.secondary)
                } else if billing == nil && snapshot.displayedBalance == nil {
                    Text("N/A").foregroundStyle(.secondary)
                }
            }
            if let billing, enabled != false {
                let presentation = BillingUsagePresentation(usage: billing, displayMode: displayMode)
                let fallback = Self.resetFallback(for: snapshot.provider)
                BoundedAdditionalBarBlock(
                    label: Self.spendLabel(for: snapshot.provider),
                    valueText: presentation.valueText,
                    fraction: fraction,
                    resetsAt: reset,
                    resetFallbackText: fallback.text,
                    resetFallbackIcon: fallback.icon
                )
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
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
    static func rows(_ windows: [QuotaWindow]) -> [[QuotaWindow]] {
        var result: [[QuotaWindow]] = []
        var pair: [QuotaWindow] = []
        for window in windows {
            if window.kind == .argonWeekly || window.kind.title.count > 20 {
                if !pair.isEmpty { result.append(pair); pair = [] }
                result.append([window])
            } else {
                pair.append(window)
                if pair.count == 2 { result.append(pair); pair = [] }
            }
        }
        if !pair.isEmpty { result.append(pair) }
        return result
    }
    private static func orderedWindows(_ snapshot: ProviderSnapshot) -> [QuotaWindow] {
        snapshot.provider == .claude
            ? snapshot.windows.filter { [.session, .weekly].contains($0.kind) }
                + snapshot.windows.filter { $0.kind == .fable }
                + snapshot.windows.filter { ![.session, .weekly, .fable].contains($0.kind) }
            : snapshot.windows
    }

    static func isDetailOnlyWindow(_ window: QuotaWindow, for provider: ProviderID) -> Bool {
        switch provider {
        case .claude, .codex, .antigravity, .minimax:
            ![QuotaKind.session, .weekly].contains(window.kind)
        case .qwen:
            ![QuotaKind.daily, .weekly].contains(window.kind)
        case .adobe:
            window.kind == .firefly
        case .copilot:
            window.kind == .completions
        case .kimi:
            window.kind.rawValue.hasPrefix("additional:kimi.code.")
        default:
            false
        }
    }

    static func summaryWindows(_ snapshot: ProviderSnapshot) -> [QuotaWindow] {
        let ordered = orderedWindows(snapshot)
        let primary = ordered.filter { !isDetailOnlyWindow($0, for: snapshot.provider) }
        return Array((primary.isEmpty ? ordered : primary).prefix(2))
    }

    static func detailWindows(_ snapshot: ProviderSnapshot) -> [QuotaWindow] {
        guard snapshot.quotaSections.isEmpty else { return [] }
        let summaryKinds = Set(summaryWindows(snapshot).map(\.kind))
        return orderedWindows(snapshot).filter { !summaryKinds.contains($0.kind) }
    }

    static func windows(_ snapshot: ProviderSnapshot, expanded: Bool) -> [QuotaWindow] {
        expanded ? (summaryWindows(snapshot) + detailWindows(snapshot)) : summaryWindows(snapshot)
    }

    static func showsAdditionalUsageRow(_ snapshot: ProviderSnapshot) -> Bool {
        if snapshot.hasAdditionalUsageSection { return true }
        guard !snapshot.windows.isEmpty || !snapshot.quotaSections.isEmpty else { return false }
        return [.claude, .cursor, .muse].contains(snapshot.provider)
    }

    static func displayedUsageDetails(_ snapshot: ProviderSnapshot) -> [ProviderUsageDetail] {
        guard snapshot.provider == .codex,
              !snapshot.usageDetails.contains(where: { $0.id == "codex.flex.credits" }) else {
            return snapshot.usageDetails
        }
        let flexDetail: ProviderUsageDetail?
        if case let .flexCreditBalance(remaining, _) = snapshot.billingUsage {
            flexDetail = ProviderUsageDetail(
                id: "codex.flex.credits",
                title: "Additional Credits",
                value: "Flex \(remaining.formatted(.number))"
            )
        } else if !snapshot.windows.isEmpty {
            flexDetail = ProviderUsageDetail(
                id: "codex.flex.credits",
                title: "Additional Credits",
                value: snapshot.additionalUsageEnabled == false ? "Off" : "N/A"
            )
        } else {
            flexDetail = nil
        }
        return flexDetail.map { [$0] + snapshot.usageDetails } ?? snapshot.usageDetails
    }

    static func canExpand(_ snapshot: ProviderSnapshot) -> Bool {
        let details = displayedUsageDetails(snapshot)
        let hasInlineOnlyDetails = snapshot.windows.isEmpty && snapshot.quotaSections.isEmpty && !details.isEmpty
        return !detailWindows(snapshot).isEmpty || !snapshot.quotaSections.isEmpty || !snapshot.consumptionShares.isEmpty || showsAdditionalUsageRow(snapshot) ||
            (snapshot.resets?.availableCount ?? 0) > 0 || (!hasInlineOnlyDetails && !details.isEmpty)
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

private struct DiagnosticWarningBadge: View {
    let providerName: String
    let warnings: [ProviderDiagnosticWarning]
    let onUpdate: () -> Void

    @State private var showingPopover = false

    private var tooltipSummary: String {
        warnings.map { warning in
            guard !warning.detail.isEmpty else { return warning.summary }
            let preview = warning.detail.replacingOccurrences(of: "\n", with: ", ")
            return "\(warning.summary) — \(preview)"
        }.joined(separator: "\n") + "\nClick for details or to update confirmed config."
    }

    private var needsScroll: Bool {
        warnings.count > 3 || warnings.reduce(0) { $0 + $1.detail.split(separator: "\n").count + 2 } > 10
    }

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tooltipSummary)
        .accessibilityLabel("\(providerName) API warning")
        .accessibilityValue(warnings.map(\.summary).joined(separator: "; "))
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(providerName) API Notice", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(nsColor: .systemYellow))

                if needsScroll {
                    ScrollView {
                        warningsList
                    }
                    .frame(maxHeight: 260)
                } else {
                    warningsList
                }

                Divider()

                HStack(spacing: 8) {
                    Text("Accept current API structure?")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("Update") {
                        onUpdate()
                        showingPopover = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Save these API changes into \(providerName)'s confirmed config until the next change.")
                }
            }
            .padding(12)
            .frame(width: 340, alignment: .leading)
        }
    }

    private var warningsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(warnings) { warning in
                VStack(alignment: .leading, spacing: 2) {
                    Text(warning.kind.badgeTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(warning.summary)
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if !warning.detail.isEmpty {
                        Text(warning.detail)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                if warning.id != warnings.last?.id {
                    Divider()
                }
            }
        }
    }
}
