import XCTest
@testable import AIUsage

final class ProviderScopeTests: XCTestCase {
    private func response(_ object: [String: Any]) throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: object))
    }
    func testVerifiedCopilotScopedCreditsAreNotSummedOrCalledDollars() throws {
        let result = try CopilotUsageMapper.map(response: response([
            "copilot_plan": "individual", "access_type_sku": "free_limited_copilot", "token_based_billing": true,
            "quota_snapshots": [
                "chat": ["credits_used": 0, "has_quota": true, "percent_remaining": 100, "entitlement": 200],
                "completions": ["credits_used": 138, "has_quota": true, "percent_remaining": 93.1, "entitlement": 2000],
                "premium_interactions": ["credits_used": 0, "has_quota": false, "entitlement": 0]
            ]
        ]), now: Date())
        XCTAssertEqual(result.planName, "Free")
        XCTAssertEqual(result.windows.map(\.kind), [.chat, .completions])
        XCTAssertEqual(QuotaKind.chat.title, "Monthly")
        XCTAssertEqual(QuotaKind.completions.title, "Completions Monthly")
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertFalse(result.availableMenuBarItems.contains { $0.metric == .extraUsage })
        XCTAssertNil(result.billingUsage)
        XCTAssertTrue(result.hasPanelContent)
    }
    func testCreditBilledSeatDoesNotDisplayRawCreditCounts() throws {
        let result = try CopilotUsageMapper.map(response: response([
            "token_based_billing": true,
            "quota_snapshots": ["premium_interactions": ["credits_used": 42, "unlimited": true]]
        ]), now: Date())
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertFalse(result.hasPanelContent)
    }
    func testInvalidAndAbsentCreditsAreNotFabricated() {
        let details = CopilotUsageMapper.creditDetails([
            "token_based_billing": true,
            "quota_snapshots": [
                "chat": ["credits_used": -1],
                "completions": ["credits_used": Double.infinity],
                "premium_interactions": ["credits_used": 50, "has_quota": false]
            ]
        ])
        XCTAssertTrue(details.isEmpty)
        XCTAssertTrue(CopilotUsageMapper.creditDetails([:]).isEmpty)
    }
    func testApplicableResetsAreSeparateFromBankedCount() throws {
        let result = try CodexUsageMapper.map(response: response([
            "plan_type": "plus", "rate_limit_reset_credits": ["available_count": 1, "applicable_available_count": 0]
        ]), now: Date())
        XCTAssertEqual(result.resets?.availableCount, 1)
        XCTAssertTrue(result.usageDetails.isEmpty)
        XCTAssertEqual(result.resets?.usableCount, 0)
        XCTAssertEqual(result.usageScope, "Shared allowance · Codex & ChatGPT Work")
        XCTAssertEqual(result.displayName, "Codex")
    }
    func testProviderLabelsDescribeActualQuotaWithoutChangingPersistedIDs() {
        XCTAssertEqual(ProviderID.claude.displayName, "Claude")
        XCTAssertEqual(ProviderID.claude.rawValue, "claude")
        XCTAssertEqual(QuotaKind.claudePool.title, "3rd-party Session")
        XCTAssertEqual(QuotaKind.claudePool.rawValue, "claudePool")
        XCTAssertEqual(QuotaKind.claudePoolWeekly.title, "3rd-party Weekly")
        let gemini = ProviderSnapshot(provider: .gemini, planName: nil, windows: [], fetchedAt: Date())
        XCTAssertEqual(gemini.usageScope, "Gemini app quota · separate from Antigravity")
        for provider in ProviderID.enabledCases {
            let subtitle = ProviderSnapshot(provider: provider, planName: nil, windows: [], fetchedAt: Date()).dashboardSubtitle
            XCTAssertNotNil(subtitle, "\(provider.rawValue) must have a dashboardSubtitle")
            XCTAssertTrue(subtitle?.contains(" • ") == true, "\(provider.rawValue) subtitle must follow '<Scope> • <Details>'")
        }
    }

    @MainActor
    func testCopilotUnlimitedProBarsAndSubQuotaSeparationAndAdditionalUsageDefaults() throws {
        let pro = try CopilotUsageMapper.map(response: response([
            "copilot_plan": "individual",
            "quota_reset_date": "2026-12-01",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 300, "remaining": 240, "percent_remaining": 80, "has_quota": true, "overage_permitted": false],
                "chat": ["unlimited": true, "has_quota": true],
                "completions": ["unlimited": true, "has_quota": true]
            ]
        ]), now: Date())
        XCTAssertEqual(pro.windows.map(\.kind), [.credits, .chat, .completions])
        XCTAssertEqual(pro.windows.map(\.isUnlimited), [false, true, true])
        XCTAssertEqual(pro.availableMenuBarItems.map(\.metric), [.credits])
        XCTAssertEqual(pro.additionalUsageEnabled, false)
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(pro).map(\.kind), [.credits, .chat])
        XCTAssertEqual(ProviderDetailsLayout.detailWindows(pro).map(\.kind), [.completions])
        XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(pro))
        XCTAssertEqual(pro.usageDetails, [
            ProviderUsageDetail(id: "copilot.overage.status", title: "Overage billing", value: "Off")
        ])

        let proOverageEnabled = try CopilotUsageMapper.map(response: response([
            "copilot_plan": "individual",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 300, "remaining": 0, "percent_remaining": 0, "has_quota": true, "overage_permitted": true]
            ]
        ]), now: Date())
        XCTAssertEqual(proOverageEnabled.usageDetails, [
            ProviderUsageDetail(id: "copilot.overage.status", title: "Overage billing", value: "Enabled")
        ])

        let copilotFree = ProviderSnapshot(
            provider: .copilot,
            planName: "Free",
            windows: [
                QuotaWindow(kind: .chat, usedPercent: 10, resetsAt: nil),
                QuotaWindow(kind: .completions, usedPercent: 20, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(copilotFree).map(\.kind), [.chat])
        XCTAssertEqual(ProviderDetailsLayout.detailWindows(copilotFree).map(\.kind), [.completions])

        let adobe = ProviderSnapshot(
            provider: .adobe,
            planName: "Creative Cloud",
            windows: [
                QuotaWindow(kind: .monthly, usedPercent: 10, resetsAt: nil),
                QuotaWindow(kind: .firefly, usedPercent: 25, resetsAt: nil)
            ],
            fetchedAt: Date()
        )
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(adobe).map(\.kind), [.monthly])
        XCTAssertEqual(ProviderDetailsLayout.detailWindows(adobe).map(\.kind), [.firefly])

        let kimi = ProviderSnapshot(
            provider: .kimi,
            planName: "Free",
            windows: [
                QuotaWindow(kind: .monthly, usedPercent: 0, resetsAt: nil),
                QuotaWindow(kind: .additional(id: "kimi.code.7d", title: "Kimi Code · Weekly"), usedPercent: 0, resetsAt: nil, isInactive: true)
            ],
            fetchedAt: Date()
        )
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(kimi).map(\.kind), [.monthly])
        XCTAssertEqual(ProviderDetailsLayout.detailWindows(kimi).map(\.kind.rawValue), ["additional:kimi.code.7d"])

        let museFree = ProviderSnapshot(
            provider: .muse,
            planName: "Free",
            windows: [QuotaWindow(kind: .weekly, usedPercent: 10, resetsAt: nil)],
            fetchedAt: Date(),
            additionalUsageEnabled: false
        )
        XCTAssertTrue(ProviderDetailsLayout.showsAdditionalUsageRow(museFree))
        XCTAssertTrue(ProviderDetailsLayout.canExpand(museFree))

        for provider in [ProviderID.claude, .cursor, .muse] {
            let disabledSnap = ProviderSnapshot(
                provider: provider,
                planName: nil,
                windows: [QuotaWindow(kind: .weekly, usedPercent: 10, resetsAt: nil)],
                fetchedAt: Date(),
                additionalUsageEnabled: false
            )
            let unknownSnap = ProviderSnapshot(
                provider: provider,
                planName: nil,
                windows: [QuotaWindow(kind: .weekly, usedPercent: 10, resetsAt: nil)],
                fetchedAt: Date()
            )
            XCTAssertTrue(ProviderDetailsLayout.showsAdditionalUsageRow(disabledSnap), "\(provider.rawValue) disabled should still show Additional Usage")
            XCTAssertTrue(ProviderDetailsLayout.showsAdditionalUsageRow(unknownSnap), "\(provider.rawValue) transient nil should still show Additional Usage")
        }

        for provider in [ProviderID.antigravity, .gemini, .adobe, .kimi, .qwen, .copilot, .codex, .manus, .minimax, .qoder] {
            let snap = ProviderSnapshot(
                provider: provider,
                planName: nil,
                windows: [QuotaWindow(kind: .weekly, usedPercent: 10, resetsAt: nil)],
                fetchedAt: Date()
            )
            XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(snap), "\(provider.rawValue) must not show permanent N/A Additional Usage")
        }

        let manusSnapshot = ProviderSnapshot(
            provider: .manus,
            planName: nil,
            windows: [QuotaWindow(kind: .daily, usedPercent: 10, resetsAt: nil)],
            fetchedAt: Date(),
            usageDetails: [ProviderUsageDetail(id: "manus.credits", title: "Additional Credits", value: "N/A")]
        )
        XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(manusSnapshot))

        let qoderSnapshot = ProviderSnapshot(
            provider: .qoder,
            planName: "Pro",
            windows: [QuotaWindow(kind: .weekly, usedPercent: 20, resetsAt: nil)],
            fetchedAt: Date(),
            usageDetails: [ProviderUsageDetail(id: "qoder.addon.credits", title: "Add-on Credits", value: "N/A")]
        )
        XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(qoderSnapshot))
    }

    @MainActor
    func testCodexFlexCreditsAppearAsAdditionalCreditsRow() throws {
        let active = try CodexUsageMapper.map(response: response([
            "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]],
            "credits": ["has_credits": true, "balance": "820.9"]
        ]), now: Date())
        XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(active))
        XCTAssertEqual(ProviderDetailsLayout.displayedUsageDetails(active).first,
                       ProviderUsageDetail(id: "codex.flex.credits", title: "Additional Credits", value: "Flex 820"))
        XCTAssertTrue(ProviderDetailsLayout.canExpand(active))

        let disabled = try CodexUsageMapper.map(response: response([
            "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]],
            "credits": ["has_credits": false, "balance": "0"]
        ]), now: Date())
        XCTAssertEqual(disabled.additionalUsageEnabled, false)
        XCTAssertEqual(ProviderDetailsLayout.displayedUsageDetails(disabled).first?.value, "Off")
        XCTAssertTrue(ProviderDetailsLayout.canExpand(disabled))

        let unlimited = try CodexUsageMapper.map(response: response([
            "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]],
            "credits": ["has_credits": true, "unlimited": true]
        ]), now: Date())
        XCTAssertEqual(ProviderDetailsLayout.displayedUsageDetails(unlimited).first?.value, "Unlimited")

        let unknown = try CodexUsageMapper.map(response: response([
            "rate_limit": ["primary_window": ["used_percent": 20, "limit_window_seconds": 18000]]
        ]), now: Date())
        XCTAssertEqual(ProviderDetailsLayout.displayedUsageDetails(unknown).first?.value, "N/A")

        let balanceOnly = ProviderSnapshot(
            provider: .codex,
            planName: "Plus",
            windows: [],
            billingUsage: .flexCreditBalance(remainingCredits: 120, usdValue: 4.8),
            fetchedAt: Date()
        )
        XCTAssertTrue(balanceOnly.hasPanelContent)
        XCTAssertEqual(ProviderDetailsLayout.displayedUsageDetails(balanceOnly).first?.value, "Flex 120")
    }

    @MainActor
    func testUnifiedBoundedAdditionalUsageAndCreditBarSemantics() throws {
        XCTAssertEqual(AdditionalUsageSection.spendLabel(for: .muse), "Top-up")
        XCTAssertEqual(AdditionalUsageSection.spendLabel(for: .claude), "Monthly spend")
        XCTAssertEqual(AdditionalUsageSection.spendLabel(for: .cursor), "Monthly spend")

        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .muse).icon, "infinity")
        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .muse).text, "No reset")
        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .claude).icon, "clock")
        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .claude).text, "Resets monthly")
        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .cursor).icon, "clock")
        XCTAssertEqual(AdditionalUsageSection.resetFallback(for: .cursor).text, "Resets monthly")

        let musePaid = ProviderSnapshot(
            provider: .muse,
            planName: "Plus",
            windows: [QuotaWindow(kind: .weekly, usedPercent: 50, resetsAt: nil)],
            billingUsage: .boundedSpend(usedAmount: 7.5, limitAmount: 10, currencyCode: "USD"),
            fetchedAt: Date(),
            prepaidBalance: MonetaryBalance(amount: 2.5, currencyCode: "USD"),
            additionalUsageEnabled: true
        )
        XCTAssertFalse(AdditionalUsageSection.showsHeaderBalance(for: musePaid))

        let claudePaid = ProviderSnapshot(
            provider: .claude,
            planName: "Max",
            windows: [QuotaWindow(kind: .weekly, usedPercent: 20, resetsAt: nil)],
            billingUsage: .boundedSpend(usedAmount: 5, limitAmount: 50, currencyCode: "USD"),
            fetchedAt: Date(),
            prepaidBalance: MonetaryBalance(amount: 12, currencyCode: "USD"),
            additionalUsageEnabled: true
        )
        XCTAssertTrue(AdditionalUsageSection.showsHeaderBalance(for: claudePaid))

        let cursorPaid = try CursorUsageMapper.map(
            usageResponse: response([
                "enabled": true,
                "billingCycleEnd": 1_800_100_000_000,
                "planUsage": ["limit": 2000, "totalSpend": 500],
                "spendLimitUsage": ["individualLimit": 5000, "individualUsed": 1200]
            ]),
            planResponse: nil,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertEqual(cursorPaid.effectiveAdditionalUsageResetsAt, Date(timeIntervalSince1970: 1_800_100_000))

        let progress = BoundedCreditProgress(label: "Add-on", used: 25, limit: 100, resetsAt: nil, resetNote: "No reset")
        XCTAssertEqual(progress.valueText(for: .remaining), "75 / 100 left")
        XCTAssertEqual(progress.valueText(for: .used), "25 / 100 used")
        XCTAssertEqual(progress.fraction(for: .remaining) ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(progress.fraction(for: .used) ?? -1, 0.25, accuracy: 0.001)
    }
}
