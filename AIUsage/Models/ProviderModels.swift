import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case devin
    case grok
    case kiro
    case zai
    case gemini
    case manus
    case kimi

    // Keep enum cases for decoding saved preferences; only these providers run/show.
    static let enabledCases: [Self] = [
        .claude, .codex, .cursor, .antigravity, .copilot,
        // .devin,
        // .grok, // Grok Build (CLI): temporarily hidden.
        // .kiro,
        // .zai,
        .gemini, .manus, .kimi
    ]

    var isEnabledInBuild: Bool { Self.enabledCases.contains(self) }
    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub Copilot"
        case .devin: "Devin"
        case .grok: "Grok Build (CLI)"
        case .kiro: "Kiro"
        case .zai: "Z.ai"
        case .manus: "Manus"
        case .kimi: "Kimi"
        case .gemini: "Gemini"
        }
    }

    var iconAssetName: String {
        switch self {
        case .claude: "ProviderClaude"
        case .codex: "ProviderCodex"
        case .cursor: "ProviderCursor"
        case .antigravity: "ProviderAntigravity"
        case .copilot: "ProviderCopilot"
        case .devin: "ProviderDevin"
        case .grok: "ProviderGrok"
        case .kiro: "ProviderKiro"
        case .zai: "ProviderZAI"
        case .manus: "ProviderManus"
        case .kimi: "ProviderKimi"
        case .gemini: "ProviderGemini"
        }
    }

    /// Z.ai has no app or CLI of its own to detect. It counts as installed
    /// while another coding tool on this Mac holds a GLM Coding Plan key.
    var isDetectedByCredential: Bool {
        self == .zai
    }

    var descriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: self,
            displayName: displayName,
            iconAssetName: iconAssetName,
            executableNames: executableNames,
            installationIndicators: installationIndicators,
            defaultMenuBarMetric: defaultMenuBarMetric
        )
    }

    private var executableNames: [String] {
        switch self {
        case .claude: ["claude"]
        case .codex: ["codex"]
        case .cursor: ["cursor"]
        case .antigravity: ["antigravity", "agy"]
        case .copilot: ["copilot", "github-copilot"]
        case .devin: ["devin"]
        case .grok: ["grok"]
        case .kiro: ["kiro", "kiro-cli"]
        case .zai, .gemini, .manus, .kimi: []
        }
    }

    private var installationIndicators: [String] {
        switch self {
        case .claude:
            ["~/.claude", "~/.config/claude"]
        case .codex:
            ["~/.codex", "~/.config/codex"]
        case .cursor:
            [
                "/Applications/Cursor.app",
                "~/Applications/Cursor.app",
                "~/Library/Application Support/Cursor"
            ]
        case .antigravity:
            [
                "/Applications/Antigravity.app",
                "~/Applications/Antigravity.app",
                "~/Library/Application Support/Antigravity",
                GeminiNativeAuthStore.root + "/account_config"
            ]
        case .copilot:
            [
                "~/.config/github-copilot/apps.json",
                "~/.config/github-copilot/hosts.json"
            ]
        case .devin:
            [
                "~/.local/share/devin",
                "/Applications/Devin.app",
                "~/Applications/Devin.app",
                "~/Library/Application Support/Devin"
            ]
        case .grok:
            ["~/.grok"]
        case .kiro:
            [
                "~/.aws/sso/cache/kiro-auth-token.json",
                "~/.kiro",
                "/Applications/Kiro.app",
                "~/Applications/Kiro.app",
                "~/Library/Application Support/Kiro",
                "~/.local/bin/kiro-cli"
            ]
        case .gemini:
            [GeminiNativeAuthStore.root + "/account_config"] +
                GeminiCredentialSource.edge.cookiePaths + GeminiCredentialSource.chrome.cookiePaths
        case .manus:
            ["~/Library/Application Support/Microsoft Edge/Default/Cookies"]
        case .kimi:
            ["~/Library/Application Support/kimi-desktop/Local Storage/leveldb"]
        case .zai:
            []
        }
    }

    var defaultMenuBarMetric: MenuBarMetricID {
        switch self {
        case .manus: .daily
        case .kimi: .totalUsage
        case .cursor: .totalUsage
        case .copilot, .kiro: .credits
        case .claude, .codex, .antigravity, .devin, .grok, .zai, .gemini: .weekly
        }
    }
}

enum QuotaKind: String, Codable, Hashable, Sendable {
    case session
    case weekly
    case daily
    case sonnet
    case fable
    case sparkSession
    case sparkWeekly
    case totalUsage
    case autoUsage
    case apiUsage
    case credits
    case chat
    case completions
    case claudePool
    case claudePoolWeekly
    case argonWeekly
    case webSearches
    case freeTrial

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .daily: "Daily"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .sparkSession: "Spark"
        case .sparkWeekly: "Spark Weekly"
        case .totalUsage: "Total Usage"
        case .autoUsage: "Auto Usage"
        case .apiUsage: "API Usage"
        case .credits: "Credits"
        case .chat: "Chat"
        case .completions: "Completions"
        case .claudePool: "3rd-party"
        case .claudePoolWeekly: "3rd-party Weekly"
        case .argonWeekly: "Argon Weekly"
        case .webSearches: "Web Searches"
        case .freeTrial: "Free Trial"
        }
    }

    var menuBarMetric: MenuBarMetricID {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .daily: .daily
        case .sonnet: .sonnet
        case .fable: .fable
        case .sparkSession: .spark
        case .sparkWeekly: .sparkWeekly
        case .totalUsage: .totalUsage
        case .autoUsage: .autoUsage
        case .apiUsage: .apiUsage
        case .credits: .credits
        case .chat: .chat
        case .completions: .completions
        case .claudePool: .claudePool
        case .claudePoolWeekly: .claudePoolWeekly
        case .argonWeekly: .argonWeekly
        case .webSearches: .webSearches
        case .freeTrial: .freeTrial
        }
    }
}

enum MenuBarMetricID: String, CaseIterable, Codable, Identifiable, Sendable {
    case session
    case weekly
    case daily
    case sonnet
    case fable
    case spark
    case sparkWeekly
    case totalUsage
    case autoUsage
    case apiUsage
    case chat
    case completions
    case claudePool
    case claudePoolWeekly
    case argonWeekly
    case webSearches
    case freeTrial
    case extraUsage
    case credits
    case resets

    var id: Self { self }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .daily: "Daily"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .spark: "Spark"
        case .sparkWeekly: "Spark Weekly"
        case .totalUsage: "Total Usage"
        case .autoUsage: "Auto Usage"
        case .apiUsage: "API Usage"
        case .chat: "Chat"
        case .completions: "Completions"
        case .claudePool: "3rd-party"
        case .claudePoolWeekly: "3rd-party Weekly"
        case .argonWeekly: "Argon Weekly"
        case .webSearches: "Web Searches"
        case .freeTrial: "Free Trial"
        case .extraUsage: "Extra Usage"
        case .credits: "Credits"
        case .resets: "Resets"
        }
    }

    var systemImage: String {
        switch self {
        case .session: "clock"
        case .weekly: "calendar"
        case .daily: "sun.max"
        case .sonnet: "waveform"
        case .fable: "book.closed"
        case .spark: "sparkles"
        case .sparkWeekly: "calendar.badge.clock"
        case .totalUsage: "gauge.with.dots.needle.50percent"
        case .autoUsage: "wand.and.sparkles"
        case .apiUsage: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .completions: "text.badge.checkmark"
        case .claudePool: "brain"
        case .claudePoolWeekly: "calendar.badge.clock"
        case .argonWeekly: "atom"
        case .webSearches: "magnifyingglass"
        case .freeTrial: "gift"
        case .extraUsage: "dollarsign.circle"
        case .credits: "creditcard"
        case .resets: "arrow.counterclockwise"
        }
    }

    var compactLabel: String {
        switch self {
        case .session: "S"
        case .weekly: "W"
        case .daily: "D"
        case .sonnet: "So"
        case .fable: "F"
        case .spark: "Sp"
        case .sparkWeekly: "SpW"
        case .totalUsage: "T"
        case .autoUsage: "A"
        case .apiUsage: "API"
        case .chat: "Ch"
        case .completions: "Co"
        case .claudePool: "3P"
        case .claudePoolWeekly: "3PW"
        case .argonWeekly: "ArW"
        case .webSearches: "WS"
        case .freeTrial: "FT"
        case .extraUsage: "E"
        case .credits: "C"
        case .resets: "R"
        }
    }

    var quotaKind: QuotaKind? {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .daily: .daily
        case .sonnet: .sonnet
        case .fable: .fable
        case .spark: .sparkSession
        case .sparkWeekly: .sparkWeekly
        case .totalUsage: .totalUsage
        case .autoUsage: .autoUsage
        case .apiUsage: .apiUsage
        case .chat: .chat
        case .completions: .completions
        case .claudePool: .claudePool
        case .claudePoolWeekly: .claudePoolWeekly
        case .argonWeekly: .argonWeekly
        case .webSearches: .webSearches
        case .freeTrial: .freeTrial
        case .credits: .credits
        case .extraUsage, .resets: nil
        }
    }
}

struct MenuBarItemID: Codable, Hashable, Identifiable, Sendable {
    let provider: ProviderID
    let metric: MenuBarMetricID

    var id: String { "\(provider.rawValue).\(metric.rawValue)" }
    var title: String { "\(provider.displayName) · \(metric.title)" }
}

struct MenuBarProviderConfiguration:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    let provider: ProviderID
    let metrics: [MenuBarMetricID]

    var id: ProviderID { provider }
}

struct ProviderDescriptor: Identifiable, Sendable {
    let id: ProviderID
    let displayName: String
    let iconAssetName: String
    let executableNames: [String]
    let installationIndicators: [String]
    let defaultMenuBarMetric: MenuBarMetricID
}

enum ProviderCatalog {
    static let all = ProviderID.enabledCases.map(\.descriptor)

    static func descriptor(for provider: ProviderID) -> ProviderDescriptor {
        provider.descriptor
    }
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let kind: QuotaKind
    let usedPercent: Double
    let resetsAt: Date?

    var id: QuotaKind { kind }
    var renderedFraction: Double { min(max(usedPercent / 100, 0), 1) }
}

enum BillingUsage: Equatable, Sendable {
    case boundedSpend(
        usedAmount: Double,
        limitAmount: Double,
        currencyCode: String
    )
    case unboundedSpend(
        usedAmount: Double,
        currencyCode: String
    )
    case flexCreditBalance(
        remainingCredits: Int,
        usdValue: Double
    )

    var menuBarMetric: MenuBarMetricID {
        switch self {
        case .boundedSpend, .unboundedSpend: .extraUsage
        case .flexCreditBalance: .credits
        }
    }

    func menuBarValue(
        displayMode: UsageDisplayMode
    ) -> MenuBarReadingValue {
        switch self {
        case let .boundedSpend(usedAmount, limitAmount, currencyCode):
            let amount = displayMode == .used
                ? usedAmount
                : max(limitAmount - usedAmount, 0)
            return .money(amount: amount, currencyCode: currencyCode)
        case let .unboundedSpend(usedAmount, currencyCode):
            return .money(amount: usedAmount, currencyCode: currencyCode)
        case let .flexCreditBalance(remainingCredits, usdValue):
            return .credits(
                remaining: remainingCredits,
                usdValue: usdValue
            )
        }
    }
}

enum MenuBarReadingValue: Equatable, Sendable {
    case percentage(Double)
    case money(amount: Double, currencyCode: String)
    case credits(remaining: Int, usdValue: Double)
    case resets(available: Int)
}

/// Banked usage-limit resets a provider has granted the account, such as
/// Claude's reset grants or Codex's rate-limit reset credits. Read-only:
/// AI Usage never redeems them.
struct UsageResets: Equatable, Sendable {
    let availableCount: Int
    /// Known expiration of each available reset, soonest first. Holds fewer
    /// entries than `availableCount` when the provider omits some details.
    let expirations: [Date]
    let usableCount: Int?

    init(availableCount: Int, expirations: [Date] = [], usableCount: Int? = nil) {
        self.availableCount = max(availableCount, 0)
        self.usableCount = usableCount.map { min(max($0, 0), max(availableCount, 0)) }
        self.expirations = Array(expirations.sorted().prefix(self.availableCount))
    }

    var nextExpiration: Date? { expirations.first }

    var hasUnknownExpirations: Bool { expirations.count < availableCount }

    /// The resets still usable at `now`, without the ones that have expired
    /// since the provider was last read.
    func active(at now: Date) -> UsageResets {
        let expired = expirations.filter { $0 <= now }.count
        return UsageResets(
            availableCount: availableCount - expired,
            expirations: expirations.filter { $0 > now },
            usableCount: usableCount
        )
    }
}

struct UnifiedProductUsage: Equatable, Sendable, Identifiable {
    let product: String
    let usedCents: Double
    var id: String { product }
    var title: String {
        switch product {
        case "cursor": "Cursor"
        case "grok-chat": "Grok Chat"
        default: product
        }
    }
}

struct XSubscriptionUsage: Equatable, Sendable {
    let products: [UnifiedProductUsage]
    let prepaidDollars: Double?
    let additionalUsageResetsAt: Date?
    let additionalUsageEnabled: Bool?
    let additionalUsageUnavailable: Bool
}

struct ConsumptionShare: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let percent: Double
}

struct ConsumptionBreakdown: Equatable, Sendable {
    let shares: [ConsumptionShare]
    let asOf: Date?
}

struct MonetaryBalance: Equatable, Sendable {
    let amount: Double
    let currencyCode: String
}

struct ProviderUsageDetail: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let value: String
}

struct ProviderSnapshot: Equatable, Sendable {
    let provider: ProviderID
    let planName: String?
    let windows: [QuotaWindow]
    let billingUsage: BillingUsage?
    let resets: UsageResets?
    let fetchedAt: Date
    let xSubscription: XSubscriptionUsage?
    var displayName: String { xSubscription == nil ? provider.displayName : "X Subscription" }
    var dashboardSubtitle: String? {
        if xSubscription != nil { return "Shared weekly pool • Cursor & Grok" }
        switch provider {
        case .claude: return "Shared account limits • Chat, Code & Cowork"
        case .codex: return "Shared allowance • Codex & ChatGPT Work"
        case .copilot: return "Account usage • GitHub Copilot"
        case .cursor: return "Product usage • Cursor"
        case .gemini, .antigravity: return nil // Google AI group owns the subtitle.
        default: return usageScope
        }
    }

    let credentialSource: String?
    let accountLabel: String?
    let accountEmail: String?
    let usageScope: String?
    let usageDetails: [ProviderUsageDetail]
    let prepaidBalance: MonetaryBalance?
    let additionalUsageEnabled: Bool?
    let usageBreakdown: ConsumptionBreakdown?

    var identityEmail: String? {
        accountEmail ?? (GoogleAIGroup.members.contains(provider) ? AccountEmail.validated(accountLabel) : nil)
    }

    var consumptionShares: [ConsumptionShare] {
        if let usageBreakdown { return usageBreakdown.shares }
        guard let products = xSubscription?.products else { return [] }
        let total = products.reduce(0) { $0 + $1.usedCents }
        return products.map { ConsumptionShare(id: $0.product, title: $0.title,
            percent: total > 0 ? $0.usedCents / total * 100 : 0) }
    }

    /// Raw credit counts and their estimated dollar conversions are not cash balances.
    var displayedBillingUsage: BillingUsage? {
        if case .flexCreditBalance = billingUsage { return nil }
        return billingUsage
    }
    var displayedBalance: MonetaryBalance? {
        prepaidBalance ?? xSubscription?.prepaidDollars.map { MonetaryBalance(amount: $0, currencyCode: "USD") }
    }
    var hasAdditionalUsageSection: Bool {
        guard (additionalUsageEnabled ?? xSubscription?.additionalUsageEnabled) != false else { return false }
        if let balance = displayedBalance, balance.amount.isFinite, balance.amount > 0 { return true }
        switch displayedBillingUsage {
        case let .boundedSpend(used, limit, _): return used > 0 || limit > 0
        case let .unboundedSpend(used, _): return used > 0
        default: return false
        }
    }

    init(
        provider: ProviderID,
        planName: String?,
        windows: [QuotaWindow],
        billingUsage: BillingUsage? = nil,
        resets: UsageResets? = nil,
        fetchedAt: Date,
        xSubscription: XSubscriptionUsage? = nil,
        credentialSource: String? = nil,
        accountLabel: String? = nil,
        accountEmail: String? = nil,
        usageScope: String? = nil,
        usageDetails: [ProviderUsageDetail] = [],
        prepaidBalance: MonetaryBalance? = nil,
        additionalUsageEnabled: Bool? = nil,
        usageBreakdown: ConsumptionBreakdown? = nil
    ) {
        self.provider = provider
        self.planName = planName
        self.windows = windows
        self.billingUsage = billingUsage
        self.resets = resets
        self.fetchedAt = fetchedAt
        self.xSubscription = xSubscription
        self.credentialSource = credentialSource
        self.accountLabel = accountLabel
        self.accountEmail = AccountEmail.validated(accountEmail)
        self.usageScope = usageScope ?? (provider == .gemini ? "Gemini app quota · separate from Antigravity" : nil)
        self.usageDetails = usageDetails
        self.prepaidBalance = prepaidBalance
        self.additionalUsageEnabled = additionalUsageEnabled
        self.usageBreakdown = usageBreakdown
    }

    /// Whether the panel has anything to show beyond the provider header.
    var hasPanelContent: Bool {
        !windows.isEmpty ||
            !consumptionShares.isEmpty ||
            !usageDetails.isEmpty ||
            hasAdditionalUsageSection ||
            (resets?.availableCount ?? 0) > 0
    }

    var sessionWindow: QuotaWindow? {
        windows.first { $0.kind == .session }
    }

    func window(for metric: MenuBarMetricID) -> QuotaWindow? {
        guard let quotaKind = metric.quotaKind else { return nil }
        if xSubscription != nil, [.totalUsage, .autoUsage, .apiUsage].contains(metric) {
            return windows.first { $0.kind == .weekly }
        }
        return windows.first { $0.kind == quotaKind }
    }

    var availableMenuBarItems: [MenuBarItemID] {
        var items = windows.map {
            MenuBarItemID(provider: provider, metric: $0.kind.menuBarMetric)
        }
        if xSubscription != nil {
            items += [.totalUsage, .autoUsage, .apiUsage].map { MenuBarItemID(provider: provider, metric: $0) }
        }
        if let billingUsage = displayedBillingUsage {
            items.append(MenuBarItemID(
                provider: provider,
                metric: billingUsage.menuBarMetric
            ))
        }
        if resets != nil {
            items.append(MenuBarItemID(provider: provider, metric: .resets))
        }
        var seen: Set<MenuBarItemID> = []
        return items.filter { seen.insert($0).inserted }
    }

    func menuBarValue(
        for metric: MenuBarMetricID,
        displayMode: UsageDisplayMode
    ) -> MenuBarReadingValue? {
        if let window = window(for: metric) {
            return .percentage(
                displayMode.displayedPercent(from: window.usedPercent)
            )
        }
        if metric == .resets, let resets {
            return .resets(available: resets.availableCount)
        }
        guard displayedBillingUsage?.menuBarMetric == metric else { return nil }
        return displayedBillingUsage?.menuBarValue(displayMode: displayMode)
    }

    func primaryWindow(for selection: MenuBarWindow) -> QuotaWindow? {
        switch selection {
        case .session:
            windows.first { $0.kind == .session }
        case .weekly:
            windows.first { $0.kind == .weekly }
        }
    }

    func primaryWindowWithFallback(
        for selection: MenuBarWindow
    ) -> QuotaWindow? {
        if let selected = primaryWindow(for: selection) {
            return selected
        }
        let fallback: MenuBarWindow =
            selection == .session ? .weekly : .session
        return primaryWindow(for: fallback)
    }
}

enum ProviderFailureKind: String, Sendable {
    case authentication
    case transient
    case rateLimited
    case invalidResponse
    case storage
}

struct ProviderFailure: LocalizedError, Equatable, Sendable {
    let kind: ProviderFailureKind
    let message: String
    let retryAt: Date?

    init(_ kind: ProviderFailureKind, _ message: String, retryAt: Date? = nil) {
        self.kind = kind
        self.message = message
        self.retryAt = retryAt
    }

    var errorDescription: String? { message }

    var preservesLastGood: Bool {
        switch kind {
        case .transient, .rateLimited, .invalidResponse:
            true
        case .authentication, .storage:
            false
        }
    }
}

struct ProviderState: Equatable, Sendable {
    let provider: ProviderID
    var snapshot: ProviderSnapshot?
    var failure: ProviderFailure?
    var isRefreshing = false
    var isToolInstalled: Bool?

    var isStale: Bool { snapshot != nil && failure != nil }

    var isVisibleInDashboard: Bool {
        isToolInstalled != false
    }
}

enum MenuBarSelection: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case all
    case claude
    case codex

    var id: Self { self }

    var title: String {
        switch self {
        case .automatic: "Auto — Highest usage"
        case .all: "All providers"
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var provider: ProviderID? {
        switch self {
        case .automatic, .all: nil
        case .claude: .claude
        case .codex: .codex
        }
    }
}

enum MenuBarWindow: String, CaseIterable, Identifiable, Sendable {
    case session
    case weekly

    var id: Self { self }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

enum UsageDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case remaining
    case used

    static let defaultSelection: Self = .remaining

    var id: Self { self }

    var title: String {
        switch self {
        case .used: "Used"
        case .remaining: "Left"
        }
    }

    var valueSuffix: String {
        switch self {
        case .used: "used"
        case .remaining: "left"
        }
    }

    func displayedPercent(from usedPercent: Double) -> Double {
        switch self {
        case .used:
            usedPercent
        case .remaining:
            100 - min(max(usedPercent, 0), 100)
        }
    }

    func renderedFraction(from usedPercent: Double) -> Double {
        min(max(displayedPercent(from: usedPercent) / 100, 0), 1)
    }
}

enum RefreshIntervalOption: String, CaseIterable, Identifiable, Sendable {
    case oneMinute
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    var id: Self { self }

    var title: String {
        switch self {
        case .oneMinute: "Every minute"
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .oneHour: "Every hour"
        }
    }

    var duration: Duration {
        switch self {
        case .oneMinute: .seconds(60)
        case .fiveMinutes: .seconds(300)
        case .fifteenMinutes: .seconds(900)
        case .thirtyMinutes: .seconds(1_800)
        case .oneHour: .seconds(3_600)
        }
    }
}

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> ProviderSnapshot
}

protocol DateProviding: Sendable {
    func now() -> Date
}

struct SystemDateProvider: DateProviding {
    func now() -> Date { Date() }
}


/// Presentation grouping only: provider IDs, authentication and quota remain independent.
enum GoogleAIGroup {
    static let members: Set<ProviderID> = [.gemini, .antigravity]

    /// Anchor the group at its first member; preserve each child's stored relative order.
    static func ordered(_ providers: [ProviderID]) -> [ProviderID] {
        let children = providers.filter { members.contains($0) }
        var inserted = false
        return providers.flatMap { provider -> [ProviderID] in
            guard members.contains(provider) else { return [provider] }
            guard !inserted else { return [] }
            inserted = true
            return children
        }
    }

    static func sharedEmail(_ states: [ProviderState]) -> String? {
        guard !states.isEmpty, states.allSatisfy({ $0.snapshot?.identityEmail != nil }) else { return nil }
        let emails = states.compactMap { $0.snapshot?.identityEmail }
        return Set(emails.map { $0.lowercased() }).count == 1 ? emails.first : nil
    }

    static func sharedPlan(_ states: [ProviderState]) -> String? {
        if states.count == 1 { return states.first?.snapshot?.planName }
        // Equal subscription names do not prove both adapters use the same Google account.
        guard !states.isEmpty,
              states.allSatisfy({ $0.snapshot?.accountLabel?.isEmpty == false }),
              Set(states.compactMap { $0.snapshot?.accountLabel?.lowercased() }).count == 1,
              Set(states.compactMap { $0.snapshot?.planName }.filter { !$0.isEmpty }).count == 1 else { return nil }
        return states.compactMap { $0.snapshot?.planName }.first { !$0.isEmpty }
    }
}
