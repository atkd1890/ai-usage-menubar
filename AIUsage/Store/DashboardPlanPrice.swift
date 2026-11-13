import Foundation

nonisolated struct DashboardPlanPrice {
    let monthlyUSD: Double
    let isListPrice: Bool
    let source: URL?
    // US monthly list prices verified 2026-11-13. These are not account invoices.
    static func listed(provider: ProviderID, plan: String?) -> DashboardPlanPrice? {
        guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return nil }
        let amount: Double
        let source: String
        switch provider {
        case .codex:
            guard plan == "plus" else { return nil } // Pro has multiple paid usage tiers.
            amount = 20; source = "https://help.openai.com/en/articles/6950777-what-is-chatgpt-plus"
        case .claude:
            switch plan {
            case "pro": amount = 20
            case "max", "max 5x": amount = 100
            case "ultra", "max 20x": amount = 200
            default: return nil
            }
            source = "https://claude.com/pricing"
        case .gemini, .antigravity:
            guard plan == "google ai pro" || plan == "pro" else { return nil }
            amount = 19.99; source = "https://one.google.com/about/google-ai-plans/?gl=US"
        case .copilot:
            switch plan {
            case "pro", "copilot pro": amount = 10
            case "pro+", "copilot pro+": amount = 39
            case "max", "copilot max": amount = 100
            default: return nil // "Individual" alone does not distinguish Pro/Pro+.
            }
            source = "https://docs.github.com/en/copilot/get-started/plans"
        default: return nil // X Plus must never inherit legacy Cursor pricing.
        }
        return DashboardPlanPrice(monthlyUSD: amount, isListPrice: true, source: URL(string: source))
    }
}

nonisolated enum DashboardCopy {
    static let localScope = "Local Codex & Claude logs · 13 months · may include multiple accounts."
    static let exclusions = "API estimates exclude tool charges and unpriced models."
    static let otherDevices = "Web chats and other devices are not included."
    static let limits = "Observed on this Mac; earlier hits may be missing."
    static let prices = "US monthly list prices unless overridden; taxes and discounts may differ."
    static let comparison = "Multiples compare API value with plan cost for the selected period."
    static let cache = "Local logs are cached. Refresh scans for new activity."
    static let priceEditor = "For API-value comparison only. Billing is unchanged."
    static let allNotes = [localScope, exclusions, otherDevices, limits, prices, comparison, cache, priceEditor]
}
