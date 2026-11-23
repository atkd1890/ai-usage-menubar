import Foundation

enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case cursor
    case antigravity
    case copilot
    case gemini
    case manus
    case kimi
    case muse
    case qwen
    case adobe
    case minimax
    case qoder
    case dola
    case zai
    case buddy

    // Keep enum cases for decoding saved preferences; only these providers run/show.
    static let enabledCases: [Self] = [
        .claude, .codex, .cursor, .antigravity, .copilot,
        .gemini, .manus, .kimi, .muse, .qwen, .adobe,
        .minimax, .qoder, .dola, .zai, .buddy
    ]

    var isEnabledInBuild: Bool { Self.enabledCases.contains(self) }
    var id: Self { self }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .antigravity: "Antigravity"
        case .copilot: "GitHub"
        case .manus: "Manus"
        case .kimi: "Kimi"
        case .muse: "Muse"
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        case .adobe: "Adobe"
        case .minimax: "MiniMax"
        case .qoder: "Qoder"
        case .dola: "Dola"
        case .zai: "Z.ai"
        case .buddy: "Buddy"
        }
    }

    var iconAssetName: String {
        switch self {
        case .claude: "ProviderClaude"
        case .codex: "ProviderCodex"
        case .cursor: "ProviderCursor"
        case .antigravity: "ProviderAntigravity"
        case .copilot: "ProviderCopilot"
        case .manus: "ProviderManus"
        case .kimi: "ProviderKimi"
        case .muse: "ProviderMuse"
        case .gemini: "ProviderGemini"
        case .qwen: "ProviderQwen"
        case .adobe: "ProviderAdobe"
        case .minimax: "ProviderMiniMax"
        case .qoder: "ProviderQoder"
        case .dola: "ProviderDola"
        case .zai: "ProviderZAI"
        case .buddy: "ProviderBuddy"
        }
    }

    var region: ProviderRegion {
        switch self {
        case .claude, .codex, .cursor, .antigravity, .copilot, .gemini, .muse, .adobe:
            .us
        case .manus, .kimi, .qwen, .minimax, .qoder, .dola, .zai, .buddy:
            .cn
        }
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
        case .gemini, .manus, .kimi, .muse, .qwen, .adobe, .minimax, .qoder, .dola, .zai, .buddy: []
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
                "/Applications/Antigravity IDE.app",
                "~/Applications/Antigravity IDE.app",
                "~/Library/Application Support/Antigravity IDE"
            ]
        case .copilot:
            [
                "~/.config/github-copilot/apps.json",
                "~/.config/github-copilot/hosts.json"
            ]
        case .gemini:
            [GeminiNativeAuthStore.root + "/account_config"] +
                GeminiCredentialSource.edge.cookiePaths + GeminiCredentialSource.chrome.cookiePaths
        case .manus:
            [
                "/Applications/Manus Studio.app",
                "~/Applications/Manus Studio.app",
                "~/Library/Application Support/Manus/Cookies",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .muse:
            [
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .kimi:
            [
                "/Applications/Kimi.app",
                "~/Applications/Kimi.app",
                "~/Library/Application Support/kimi-desktop/Local Storage/leveldb",
                "~/Library/Application Support/Microsoft Edge/Default/Local Storage/leveldb",
                "~/Library/Application Support/Google/Chrome/Default/Local Storage/leveldb",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .qwen:
            [
                "/Applications/Qwen.app",
                "~/Applications/Qwen.app",
                "~/Library/Application Support/Qwen",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .adobe:
            [
                "/Applications/Adobe Photoshop 2027/Adobe Photoshop 2027.app",
                "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app",
                "/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app",
                "/Applications/Adobe Photoshop 2024/Adobe Photoshop 2024.app",
                "/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app",
                "~/Library/Application Support/Adobe",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .minimax:
            [
                "/Applications/MiniMax Code.app",
                "~/Applications/MiniMax Code.app",
                "/Applications/MiniMax Design.app",
                "~/Applications/MiniMax Design.app",
                "~/.minimax/auth/prod/en/mcode-public/auth.json",
                "~/Library/Application Support/@hilo/MiniMax Hub Global/hub-config-global.json",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        case .buddy:
            [
                "/Applications/CodeBuddy.app",
                "~/Applications/CodeBuddy.app",
                "~/Library/Application Support/CodeBuddy/User/globalStorage/state.vscdb"
            ]
        case .zai:
            ["/Applications/ZCode.app", "~/Applications/ZCode.app", "~/.zcode/v2/credentials.json"]
        case .dola:
            ["/Applications/Cici.app", "~/Applications/Cici.app",
             "~/Library/Application Support/Cici/Default/Cookies",
             "~/Library/Application Support/Microsoft Edge/Default/Cookies",
             "~/Library/Application Support/Google/Chrome/Default/Cookies"]
        case .qoder:
            [
                "/Applications/Qoder.app",
                "~/Applications/Qoder.app",
                "/Applications/Qoder IDE.app",
                "~/Applications/Qoder IDE.app",
                "~/Library/Application Support/com.qoder.app.stable/auth.v1.dat",
                "~/Library/Application Support/Qoder/User/globalStorage/state.vscdb",
                "~/Library/Application Support/Microsoft Edge/Default/Cookies",
                "~/Library/Application Support/Google/Chrome/Default/Cookies"
            ]
        }
    }

    var defaultMenuBarMetric: MenuBarMetricID {
        switch self {
        case .manus: .daily
        case .kimi, .adobe: .monthly
        case .buddy: .monthly
        case .zai: .session
        case .dola: .additional(id: "dola.usage", title: "Usage")
        case .cursor: .totalUsage
        case .copilot: .credits
        case .claude, .codex, .antigravity, .gemini, .muse, .qwen, .minimax, .qoder: .weekly
        }
    }
}

enum QuotaKind: RawRepresentable, Codable, Hashable, Sendable {
    case session
    case weekly
    case daily
    case monthly
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
    case firefly
    case additional(id: String, title: String)

    typealias RawValue = String
    var rawValue: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case .daily: "daily"
        case .monthly: "monthly"
        case .sonnet: "sonnet"
        case .fable: "fable"
        case .sparkSession: "sparkSession"
        case .sparkWeekly: "sparkWeekly"
        case .totalUsage: "totalUsage"
        case .autoUsage: "autoUsage"
        case .apiUsage: "apiUsage"
        case .credits: "credits"
        case .chat: "chat"
        case .completions: "completions"
        case .claudePool: "claudePool"
        case .claudePoolWeekly: "claudePoolWeekly"
        case .argonWeekly: "argonWeekly"
        case .firefly: "firefly"
        case .additional(let id, _): "additional:" + id
        }
    }
    init?(rawValue: String) {
        switch rawValue {
        case "session": self = .session
        case "weekly": self = .weekly
        case "daily": self = .daily
        case "monthly": self = .monthly
        case "sonnet": self = .sonnet
        case "fable": self = .fable
        case "sparkSession": self = .sparkSession
        case "sparkWeekly": self = .sparkWeekly
        case "totalUsage": self = .totalUsage
        case "autoUsage": self = .autoUsage
        case "apiUsage": self = .apiUsage
        case "credits": self = .credits
        case "chat": self = .chat
        case "completions": self = .completions
        case "claudePool": self = .claudePool
        case "claudePoolWeekly": self = .claudePoolWeekly
        case "argonWeekly": self = .argonWeekly
        case "firefly": self = .firefly
        default:
            guard rawValue.hasPrefix("additional:"), rawValue.count > 11 else { return nil }
            let id = String(rawValue.dropFirst(11))
            self = .additional(id: id, title: id)
        }
    }
    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self), let value = Self(rawValue: raw) {
            self = value; return
        }
        let value = try AdditionalQuotaIdentifier(from: decoder)
        guard value.id.hasPrefix("additional:"), value.id.count > 11 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid additional quota identifier"))
        }
        self = .additional(id: String(value.id.dropFirst(11)), title: value.title)
    }
    func encode(to encoder: Encoder) throws {
        if case .additional = self { try AdditionalQuotaIdentifier(id: rawValue, title: title).encode(to: encoder) }
        else { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }


    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .daily: "Daily"
        case .monthly: "Monthly"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .sparkSession: "Spark"
        case .sparkWeekly: "Spark Weekly"
        case .totalUsage: "Total Usage"
        case .autoUsage: "Auto Usage"
        case .apiUsage: "API Usage"
        case .credits: "Credits"
        case .chat: "Monthly"
        case .completions: "Completions"
        case .claudePool: "3rd-party"
        case .claudePoolWeekly: "3rd-party Weekly"
        case .argonWeekly: "Argon"
        case .firefly: "Firefly"
        case .additional(_, let title): title
        }
    }

    var menuBarMetric: MenuBarMetricID {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .daily: .daily
        case .monthly: .monthly
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
        case .firefly: .firefly
        case .additional(let id, let title): .additional(id: id, title: title)
        }
    }
}

enum MenuBarMetricID: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case session
    case weekly
    case daily
    case monthly
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
    case extraUsage
    case credits
    case resets
    case firefly
    case additional(id: String, title: String)

    typealias RawValue = String
    var rawValue: String {
        switch self {
        case .session: "session"
        case .weekly: "weekly"
        case .daily: "daily"
        case .monthly: "monthly"
        case .sonnet: "sonnet"
        case .fable: "fable"
        case .spark: "spark"
        case .sparkWeekly: "sparkWeekly"
        case .totalUsage: "totalUsage"
        case .autoUsage: "autoUsage"
        case .apiUsage: "apiUsage"
        case .chat: "chat"
        case .completions: "completions"
        case .claudePool: "claudePool"
        case .claudePoolWeekly: "claudePoolWeekly"
        case .argonWeekly: "argonWeekly"
        case .extraUsage: "extraUsage"
        case .credits: "credits"
        case .resets: "resets"
        case .firefly: "firefly"
        case .additional(let id, _): "additional:" + id
        }
    }
    init?(rawValue: String) {
        switch rawValue {
        case "session": self = .session
        case "weekly": self = .weekly
        case "daily": self = .daily
        case "monthly": self = .monthly
        case "sonnet": self = .sonnet
        case "fable": self = .fable
        case "spark": self = .spark
        case "sparkWeekly": self = .sparkWeekly
        case "totalUsage": self = .totalUsage
        case "autoUsage": self = .autoUsage
        case "apiUsage": self = .apiUsage
        case "chat": self = .chat
        case "completions": self = .completions
        case "claudePool": self = .claudePool
        case "claudePoolWeekly": self = .claudePoolWeekly
        case "argonWeekly": self = .argonWeekly
        case "extraUsage": self = .extraUsage
        case "credits": self = .credits
        case "resets": self = .resets
        case "firefly": self = .firefly
        default:
            guard rawValue.hasPrefix("additional:"), rawValue.count > 11 else { return nil }
            let id = String(rawValue.dropFirst(11))
            self = .additional(id: id, title: id)
        }
    }
    init(from decoder: Decoder) throws {
        if let raw = try? decoder.singleValueContainer().decode(String.self), let value = Self(rawValue: raw) {
            self = value; return
        }
        let value = try AdditionalQuotaIdentifier(from: decoder)
        guard value.id.hasPrefix("additional:"), value.id.count > 11 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid additional quota identifier"))
        }
        self = .additional(id: String(value.id.dropFirst(11)), title: value.title)
    }
    func encode(to encoder: Encoder) throws {
        if case .additional = self { try AdditionalQuotaIdentifier(id: rawValue, title: title).encode(to: encoder) }
        else { var container = encoder.singleValueContainer(); try container.encode(rawValue) }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rawValue == rhs.rawValue }
    func hash(into hasher: inout Hasher) { hasher.combine(rawValue) }

    static let allCases: [Self] = [.session, .weekly, .daily, .monthly, .sonnet, .fable, .spark, .sparkWeekly, .totalUsage, .autoUsage, .apiUsage, .chat, .completions, .claudePool, .claudePoolWeekly, .argonWeekly, .extraUsage, .credits, .resets, .firefly]


    var id: Self { self }

    var title: String {
        switch self {
        case .session: "Session"
        case .weekly: "Weekly"
        case .daily: "Daily"
        case .monthly: "Monthly"
        case .sonnet: "Sonnet"
        case .fable: "Fable"
        case .spark: "Spark"
        case .sparkWeekly: "Spark Weekly"
        case .totalUsage: "Total Usage"
        case .autoUsage: "Auto Usage"
        case .apiUsage: "API Usage"
        case .chat: "Monthly"
        case .completions: "Completions"
        case .claudePool: "3rd-party"
        case .claudePoolWeekly: "3rd-party Weekly"
        case .argonWeekly: "Argon"
        case .additional(_, let title): title
        case .extraUsage: "Extra Usage"
        case .credits: "Credits"
        case .resets: "Resets"
        case .firefly: "Firefly"
        }
    }

    var systemImage: String {
        switch self {
        case .session: "clock"
        case .weekly: "calendar"
        case .daily: "sun.max"
        case .monthly: "calendar"
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
        case .extraUsage: "dollarsign.circle"
        case .credits: "creditcard"
        case .resets: "arrow.counterclockwise"
        case .firefly: "sparkles"
        case .additional: "gauge.with.dots.needle.50percent"
        }
    }

    var compactLabel: String {
        switch self {
        case .session: "S"
        case .weekly: "W"
        case .daily: "D"
        case .monthly: "M"
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
        case .extraUsage: "E"
        case .credits: "C"
        case .resets: "R"
        case .firefly: "FF"
        case .additional(_, let title): String(title.prefix(6))
        }
    }

    var quotaKind: QuotaKind? {
        switch self {
        case .session: .session
        case .weekly: .weekly
        case .daily: .daily
        case .monthly: .monthly
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
        case .credits: .credits
        case .firefly: .firefly
        case .extraUsage, .resets: nil
        case .additional(let id, let title): .additional(id: id, title: title)
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

struct QuotaSeriesReading: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    let resetsAt: Date?
}

struct QuotaWindow: Identifiable, Equatable, Sendable {
    let kind: QuotaKind
    let usedPercent: Double
    let resetsAt: Date?
    let remainingCount: Double?
    let limitCount: Double?
    let series: [QuotaSeriesReading]
    let isInactive: Bool
    let inactiveDetail: String?
    let isUnlimited: Bool
    let trailingDetail: String?

    init(
        kind: QuotaKind,
        usedPercent: Double,
        resetsAt: Date?,
        remainingCount: Double? = nil,
        limitCount: Double? = nil,
        series: [QuotaSeriesReading] = [],
        isInactive: Bool = false,
        inactiveDetail: String? = nil,
        isUnlimited: Bool = false,
        trailingDetail: String? = nil
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.series = series
        self.isInactive = isInactive
        self.inactiveDetail = inactiveDetail
        self.isUnlimited = isUnlimited
        self.trailingDetail = trailingDetail
        if let remaining = remainingCount, let limit = limitCount,
           remaining.isFinite, limit.isFinite, limit > 0, remaining >= 0 {
            self.remainingCount = min(remaining, limit)
            self.limitCount = limit
        } else {
            self.remainingCount = nil
            self.limitCount = nil
        }
    }

    var id: QuotaKind { kind }
    var isBoundedActive: Bool { !isInactive && !isUnlimited }
    var renderedFraction: Double { min(max(usedPercent / 100, 0), 1) }

    func countText(for displayMode: UsageDisplayMode) -> String? {
        guard let remainingCount, let limitCount, limitCount > 0 else { return nil }
        let shown = displayMode == .used ? max(limitCount - remainingCount, 0) : remainingCount
        return "\(Self.formatCount(shown)) / \(Self.formatCount(limitCount))"
    }

    static func formatCount(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 {
            return formatCompact(value / 1_000_000_000, suffix: "B")
        }
        if magnitude >= 1_000_000 {
            let millions = (value / 1_000_000 * 100).rounded() / 100
            if abs(millions) >= 1_000 {
                return formatCompact(value / 1_000_000_000, suffix: "B")
            }
            return formatCompact(value / 1_000_000, suffix: "M")
        }
        if magnitude > 99_999 {
            let thousands = (value / 1_000 * 100).rounded() / 100
            if abs(thousands) >= 1_000 {
                return formatCompact(value / 1_000_000, suffix: "M")
            }
            return formatCompact(value / 1_000, suffix: "K")
        }
        let rounded = (value * 100).rounded() / 100
        let normalized = rounded == 0 ? 0 : rounded
        if normalized.rounded() == normalized, abs(normalized) < Double(Int.max) {
            return Int(normalized).formatted(.number)
        }
        return normalized.formatted(.number.precision(.fractionLength(0...2)))
    }

    private static func formatCompact(_ scaled: Double, suffix: String) -> String {
        let rounded = (scaled * 100).rounded() / 100
        let normalized = rounded == 0 ? 0 : rounded
        if normalized.rounded() == normalized, abs(normalized) < Double(Int.max) {
            return "\(Int(normalized).formatted(.number))\(suffix)"
        }
        return "\(normalized.formatted(.number.precision(.fractionLength(0...2))))\(suffix)"
    }
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

struct BoundedCreditProgress: Equatable, Sendable {
    let label: String
    let used: Double
    let limit: Double
    let resetsAt: Date?
    let resetNote: String?

    init(
        label: String,
        used: Double,
        limit: Double,
        resetsAt: Date? = nil,
        resetNote: String? = "No reset"
    ) {
        self.label = label
        let clampedLimit = limit.isFinite && limit > 0 ? limit : 0
        self.limit = clampedLimit
        self.used = used.isFinite ? min(max(used, 0), clampedLimit) : 0
        self.resetsAt = resetsAt
        self.resetNote = resetNote
    }

    func fraction(for displayMode: UsageDisplayMode) -> Double? {
        guard limit > 0 else { return nil }
        let consumed = min(max(used / limit, 0), 1)
        return displayMode == .used ? consumed : 1 - consumed
    }

    func valueText(for displayMode: UsageDisplayMode) -> String {
        let shown = displayMode == .used ? used : max(limit - used, 0)
        let suffix = displayMode == .used ? "used" : "left"
        return "\(QuotaWindow.formatCount(shown)) / \(QuotaWindow.formatCount(limit)) \(suffix)"
    }
}

struct ProviderUsageDetail: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let value: String
    let boundedProgress: BoundedCreditProgress?
    let targetDate: Date?

    init(
        id: String,
        title: String,
        value: String,
        boundedProgress: BoundedCreditProgress? = nil,
        targetDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.boundedProgress = boundedProgress
        self.targetDate = targetDate
    }
}

struct ProviderQuotaSection: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let windows: [QuotaWindow]
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
        if xSubscription != nil { return "Shared account limits • Cursor & Grok" }
        switch provider {
        case .claude: return "Shared account limits • Chat, Code & Cowork"
        case .codex: return "Shared account limits • Codex & ChatGPT Work"
        case .cursor: return "Product usage limits • Editor, Auto & API"
        case .antigravity: return "Antigravity app limits • Gemini, Argon & 3rd-party"
        case .copilot: return "Monthly Copilot quota • Chat & Completions"
        case .gemini: return "Shared account limits • Gemini App & Web"
        case .manus: return "Product usage limits • Agent Tasks & Credits"
        case .kimi: return "Shared account limits • Chat & Kimi Code"
        case .muse: return "Product usage limits • Personal Agent & Top-up"
        case .qwen: return "Shared account limits • Chat, Agent & Qwen Code"
        case .adobe: return "Generative credits • Firefly, Photoshop & Creative Cloud"
        case .minimax: return "Unified account • Agent, Design & Hailuo Video"
        case .qoder: return "Shared account limits • Qoder & Qoder IDE"
        case .dola: return "Shared account limits • Chat & Work"
        case .zai: return "Product usage limits • Coding Plan & ZCode"
        case .buddy: return "Shared account limits • WorkBuddy & CodeBuddy"
        }
    }

    let credentialSource: String?
    let accountLabel: String?
    let accountEmail: String?
    let usageScope: String?
    let usageDetails: [ProviderUsageDetail]
    let prepaidBalance: MonetaryBalance?
    let additionalUsageEnabled: Bool?
    let additionalUsageResetsAt: Date?
    let usageBreakdown: ConsumptionBreakdown?
    let quotaSections: [ProviderQuotaSection]
    let diagnosticWarnings: [ProviderDiagnosticWarning]

    var identityEmail: String? {
        accountEmail ?? ([ProviderID.gemini, .antigravity].contains(provider) ? AccountEmail.validated(accountLabel) : nil)
    }

    /// A credential-scoped native identity can retain history without inventing an email.
    var historyIdentity: String? {
        if let email = identityEmail { return email }
        guard let label = accountLabel else { return nil }
        let prefix: String
        if provider == .antigravity && credentialSource == "Antigravity app" { prefix = "native-session:" }
        else if provider == .muse { prefix = "muse-session:" }
        else if provider == .manus { prefix = "manus-session:" }
        else if provider == .kimi { prefix = "kimi-session:" }
        else if provider == .qwen { prefix = "qwen-session:" }
        else if provider == .minimax { prefix = "minimax-session:" }
        else if provider == .qoder { prefix = "qoder-session:" }
        else if provider == .dola { prefix = "dola-session:" }
        else if provider == .zai { prefix = "zai-session:" }
        else if provider == .buddy { prefix = "buddy-session:" }
        else { return nil }
        guard label.hasPrefix(prefix), label.dropFirst(prefix.count).count == 64,
              label.dropFirst(prefix.count).allSatisfy({ $0.isHexDigit }) else { return nil }
        return label
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
    var effectiveAdditionalUsageResetsAt: Date? {
        additionalUsageResetsAt ?? xSubscription?.additionalUsageResetsAt
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
    var hasFlexCreditBalance: Bool {
        if case .flexCreditBalance = billingUsage { return true }
        return false
    }
    var allDiagnosticWarnings: [ProviderDiagnosticWarning] {
        let compatibility = quotaCompatibilityNotes.map { note in
            ProviderDiagnosticWarning(
                id: note.id,
                kind: .partialCompatibility,
                summary: note.value,
                detail: "The provider returned a quota entry whose format is not yet supported.",
                patch: .acknowledgeNotice(endpoint: "compatibility", signature: "\(note.id)|\(note.value)")
            )
        }
        return ResponseSchemaWatch.deduplicated(diagnosticWarnings + compatibility)
    }
    var hasDiagnosticWarnings: Bool { !allDiagnosticWarnings.isEmpty }

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
        additionalUsageResetsAt: Date? = nil,
        usageBreakdown: ConsumptionBreakdown? = nil,
        quotaSections: [ProviderQuotaSection] = [],
        diagnosticWarnings: [ProviderDiagnosticWarning] = []
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
        self.additionalUsageResetsAt = additionalUsageResetsAt
        self.usageBreakdown = usageBreakdown
        self.quotaSections = quotaSections
        self.diagnosticWarnings = diagnosticWarnings
    }

    /// Whether the panel has anything to show beyond the provider header.
    var hasPanelContent: Bool {
        !windows.isEmpty ||
            !quotaSections.isEmpty ||
            !consumptionShares.isEmpty ||
            !usageDetails.isEmpty ||
            hasAdditionalUsageSection ||
            hasFlexCreditBalance ||
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
        if provider == .kimi, metric == .totalUsage {
            return windows.first { $0.kind == .monthly || $0.kind == .totalUsage }
        }
        return windows.first { $0.kind == quotaKind }
    }

    var availableMenuBarItems: [MenuBarItemID] {
        var items = windows.filter(\.isBoundedActive).map {
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
        if let window = window(for: metric), window.isBoundedActive {
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
            windows.first { $0.kind == .session && $0.isBoundedActive }
        case .weekly:
            windows.first { $0.kind == .weekly && $0.isBoundedActive }
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

enum ProviderRegion: String, CaseIterable, Identifiable, Sendable {
    case us
    case cn

    static let defaultSelection: Self = .us

    var id: Self { self }

    var flag: String {
        switch self {
        case .us: "🇺🇸"
        case .cn: "🇨🇳"
        }
    }

    var title: String {
        switch self {
        case .us: "US"
        case .cn: "CN"
        }
    }

    var badgeTitle: String {
        "\(flag) \(title)"
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
private struct AdditionalQuotaIdentifier: Codable {
    let id: String
    let title: String
}
