import Foundation

/// Verified API schema contract for a single provider endpoint or sub-object.
/// Lists both displayed fields and intentionally-ignored (`confirmed`) fields
/// so live responses can be diffed accurately against the last reviewed API shape.
struct EndpointConfirmedSchema: Codable, Equatable, Sendable {
    var jsonKeys: [String]
    var jsonKeyPrefixes: [String]
    var requiredJSONKeys: [String]
    var protobufTags: [Int]
    var requiredProtobufTags: [Int]
    var enums: [String: [String]]
    var acknowledgedNotices: [String]

    init(
        jsonKeys: [String] = [],
        jsonKeyPrefixes: [String] = [],
        requiredJSONKeys: [String] = [],
        protobufTags: [Int] = [],
        requiredProtobufTags: [Int] = [],
        enums: [String: [String]] = [:],
        acknowledgedNotices: [String] = []
    ) {
        self.jsonKeys = jsonKeys
        self.jsonKeyPrefixes = jsonKeyPrefixes
        self.requiredJSONKeys = requiredJSONKeys
        self.protobufTags = protobufTags
        self.requiredProtobufTags = requiredProtobufTags
        self.enums = enums
        self.acknowledgedNotices = acknowledgedNotices
    }
}

/// Bundled baseline `confirmed` schema configuration for one provider.
struct ProviderConfirmedSchema: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var endpoints: [String: EndpointConfirmedSchema]

    init(
        schemaVersion: Int = 1,
        endpoints: [String: EndpointConfirmedSchema] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.endpoints = endpoints
    }
}

/// Bundled per-provider `confirmed` schema catalog updated alongside code fixes.
enum ConfirmedSchemaCatalog {
    static func baseline(for provider: ProviderID) -> ProviderConfirmedSchema {
        switch provider {
        case .claude: claude
        case .codex: codex
        case .cursor: cursor
        case .copilot: copilot
        case .muse: muse
        case .adobe: adobe
        case .manus: manus
        case .kimi: kimi
        case .qwen: qwen
        case .minimax: minimax
        case .qoder: qoder
        case .dola: dola
        case .zai: zai
        case .buddy: buddy
        case .gemini: gemini
        case .antigravity: antigravity
        }
    }

    private static let buddy = ProviderConfirmedSchema(endpoints: [
        "Buddy summary": EndpointConfirmedSchema(jsonKeys: ["CreditGroups", "IsPaidUser", "IsProtectedPriceUser", "Packages", "ProTrialStatus", "SubscriptionPackageCode", "SubscriptionPackageName", "TotalCredits"], requiredJSONKeys: ["Packages"]),
        "Buddy summary package": EndpointConfirmedSchema(jsonKeys: ["CapacityUnit", "CycleFrozenCapacity", "CycleRemainCapacity", "CycleTotalCapacity", "CycleUsedCapacity", "PackageCode", "TotalCount"]),
        "Buddy credit group": EndpointConfirmedSchema(jsonKeys: ["CapacityUnit", "CycleFrozenCapacity", "CycleRemainCapacity", "CycleTotalCapacity", "CycleUsedCapacity", "Kind", "Name", "TotalCount"], enums: ["Kind": ["plan_base", "plan_bonus", "addon", "benefit"]]),
        "Buddy package": EndpointConfirmedSchema(jsonKeys: ["AccountAttributes", "AccountId", "AppId", "AutoRenewFlag", "AutoRenewTimeSpan", "AutoRenewTimeUnit", "CapacityRemain", "CapacityRemainPrecise", "CapacitySize", "CapacitySizePrecise", "CapacityType", "CapacityUnit", "CapacityUsed", "CapacityUsedPrecise", "CreateTime", "CycleCapacityRemain", "CycleCapacityRemainPrecise", "CycleCapacitySize", "CycleCapacitySizePrecise", "CycleCapacityUsedPrecise", "CycleEndTime", "CycleStartTime", "DealName", "DeductionEndTime", "DeductionProperties", "DeductionStartTime", "ExpiredTime", "FeeType", "OriginUnit", "PackageCode", "PackageName", "PackageType", "PkgSourceType", "ProductCode", "ProductName", "Region", "RegionId", "RemainCycles", "ResourceCycleId", "ResourceId", "ResourceType", "Status", "SubProductCode", "SubProductName", "SupportAutoRenew", "SupportManualRenew", "Threshold", "TotalCycles", "Uin", "Zone", "ZoneId"])
    ])

    private static let zai = ProviderConfirmedSchema(endpoints: [
        "Z.ai envelope": EndpointConfirmedSchema(jsonKeys: ["code", "msg", "success", "data"]),
        "Z.ai subscription": EndpointConfirmedSchema(jsonKeys: ["productId", "productName", "status", "inCurrentPeriod", "billingCycle", "nextRenewTime", "autoRenew", "valid"], enums: ["status": ["VALID"]]),
        "Z.ai quota": EndpointConfirmedSchema(jsonKeys: ["level", "limits"]),
        "Z.ai limit": EndpointConfirmedSchema(jsonKeys: ["type", "unit", "number", "usage", "currentValue", "remaining", "percentage", "nextResetTime", "usageDetails"], enums: ["type": ["TOKENS_LIMIT", "CREDIT_LIMIT", "TIME_LIMIT"]]),
        "Z.ai usage detail": EndpointConfirmedSchema(jsonKeys: ["modelCode", "displayName", "usage"]),
        "Z.ai account": EndpointConfirmedSchema(jsonKeys: ["acState", "acSubmitType", "acType", "allLabelValue", "availableBalance", "avatar", "balance", "betaTester", "channel", "countryCode", "createTime", "customerName", "customerNumber", "email", "enableStatus", "enableTwoFa", "giveAmount", "id", "isNewUser", "isUniversity", "lastRequestTime", "nickName", "openId", "organizations", "phoneNumber", "phoneOpenId", "rechargeAmount", "remittanceAccount", "securityEncryptFlag", "source", "unionId", "userType", "watermarkCode", "wechatNickName", "whetherChanges"]),
        "ZCode plan": EndpointConfirmedSchema(jsonKeys: ["plan_id", "user_plan_id", "name", "description", "priority", "status", "starts_at", "ends_at", "entitlements"], enums: ["status": ["active"]]),
        "ZCode entitlement": EndpointConfirmedSchema(jsonKeys: ["entitlement_id", "grant_units", "show_name", "capabilities", "effective_at", "meter", "period", "priority", "unit_type"], enums: ["period": ["daily", "weekly", "monthly", "once"]]),
        "ZCode balance": EndpointConfirmedSchema(jsonKeys: ["plans", "balances", "server_time"]),
        "ZCode bucket": EndpointConfirmedSchema(jsonKeys: ["bucket_id", "user_plan_id", "plan_id", "entitlement_id", "show_name", "capabilities", "total_units", "used_units", "remaining_units", "available_units", "entitlement_priority", "plan_priority", "priority", "unit_type", "meter", "expires_at", "period_start", "period_end"]),
        "ZCode reset status": EndpointConfirmedSchema(jsonKeys: ["available_five_hour_resets", "available_week_resets", "latest_five_hour_reset_history", "latest_week_reset_history", "has_unread_history"]),
        "ZCode reset item": EndpointConfirmedSchema(jsonKeys: ["expire_at"]),
        "ZCode mcp usage": EndpointConfirmedSchema(jsonKeys: ["server_time", "next_refresh_at", "level", "total_usage"]),
        "ZCode mcp total_usage": EndpointConfirmedSchema(jsonKeys: ["used", "limit", "remaining"])
    ])

    private static let dola = ProviderConfirmedSchema(endpoints: [
        "Dola overview": EndpointConfirmedSchema(jsonKeys: [
            "current_subscription", "enterprise_package_entitlement_groups", "enterprise_subscription",
            "enterprise_window_limit_section", "entitlements", "incentive_quota_entitlements",
            "is_membership_gift", "member_info", "package_entitlement_groups", "quota_package_entitlement_groups",
            "service_current_time", "show_benefit_package_entry", "switch_data", "upgrade_guide", "window_limit_section"
        ]),
        "Dola member": EndpointConfirmedSchema(jsonKeys: ["has_business_subscription", "has_team_subscription",
            "hasActiveSubscription", "hasEnterpriseSubscription", "usr_type"]),
        "Dola window section": EndpointConfirmedSchema(jsonKeys: ["entitlement_count", "usage_exhausted", "window_limit_groups"]),
        "Dola subscription": EndpointConfirmedSchema(jsonKeys: ["agreement_price", "agreement_status", "agreement_type",
            "display", "effective_time", "end_time", "has_switched", "is_gift", "next_deduct_time", "period_type",
            "sku_key", "source_type", "start_time", "status", "subscription_id", "subscription_type", "timezone"]),
        "Dola subscription display": EndpointConfirmedSchema(jsonKeys: ["product_name"]),
        "Dola status": EndpointConfirmedSchema(jsonKeys: ["has_subscribed", "is_subscribing"]),
        "Dola usage": EndpointConfirmedSchema(jsonKeys: ["service_current_time", "total_used_percent", "window_limit_groups"]),
        "Dola ogf": EndpointConfirmedSchema(jsonKeys: ["quota_left", "total_quota"])
    ])

    // MARK: - 1. Claude (OAuth & claude.ai Web)
    private static let claude = ProviderConfirmedSchema(endpoints: [
        // Displayed: five_hour, seven_day, seven_day_sonnet, seven_day_*, extra_usage, spend, limits, cedar_ember, seven_day_breakdown.
        // Confirmed-ignored: experiment flags (amber_*, brass_thimble, cinder_cove, copper_kite, granite_teacup, harbor_lantern,
        //   iguana_necktie, juniper_tide, maple_sundial, nimbus_quill, starry_waterfall, tangelo, wattle_ember),
        //   weekly_scoped_shares (allowance metadata), member_dashboard_available, indicator, pace, promo_credits, omelette_promotional.
        "Claude": EndpointConfirmedSchema(
            jsonKeys: [
                "five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus",
                "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette",
                "seven_day_breakdown", "extra_usage", "spend", "limits",
                "cedar_ember", "weekly_scoped_shares", "member_dashboard_available",
                "indicator", "pace", "promo_credits", "omelette_promotional",
                "amber_cistern", "amber_cistern_offer", "amber_gauge", "amber_ladder",
                "brass_thimble", "cinder_cove", "copper_kite", "granite_teacup",
                "harbor_lantern", "iguana_necktie", "juniper_tide", "maple_sundial",
                "nimbus_quill", "starry_waterfall", "tangelo", "wattle_ember"
            ],
            jsonKeyPrefixes: ["seven_day_"]
        ),
        // Displayed: utilization, resets_at. Confirmed-ignored: limit_dollars, remaining_dollars, used_dollars, locked_reason.
        "Claude window": EndpointConfirmedSchema(
            jsonKeys: [
                "utilization", "resets_at", "limit_dollars",
                "remaining_dollars", "used_dollars", "locked_reason"
            ]
        ),
        // Displayed: is_enabled, monthly_limit, used_credits, currency, decimal_places, spend_limit_reached.
        // Confirmed-ignored: utilization, credits_ever_enabled, credits_can_pay, daily, weekly, disabled_reason, user_disabled.
        "Claude extra_usage": EndpointConfirmedSchema(
            jsonKeys: [
                "is_enabled", "monthly_limit", "used_credits", "utilization",
                "currency", "decimal_places", "credits_ever_enabled", "credits_can_pay",
                "daily", "weekly", "disabled_reason", "spend_limit_reached", "user_disabled"
            ]
        ),
        // Displayed: enabled, used, limit, balance, auto_reload.
        // Confirmed-ignored: can_purchase_credits, can_toggle, cap, disabled_reason, disclaimer, percent, severity.
        "Claude spend": EndpointConfirmedSchema(
            jsonKeys: [
                "enabled", "used", "limit", "balance", "auto_reload",
                "can_purchase_credits", "can_toggle", "cap", "disabled_reason",
                "disclaimer", "percent", "severity"
            ]
        ),
        // Displayed: eligible, ineligible_reason, grants.
        // Confirmed-ignored: at_limit, cooldown_until, event_props, exhausted, next_grant_id, paused_held, weekly_resets_at.
        "Claude cedar_ember": EndpointConfirmedSchema(
            jsonKeys: [
                "eligible", "ineligible_reason", "grants", "at_limit",
                "cooldown_until", "event_props", "exhausted", "next_grant_id",
                "paused_held", "weekly_resets_at"
            ]
        ),
        // Displayed: id, resets_left, ends_at, usable_now.
        // Confirmed-ignored: resets_total, starts_at, use_requires_limit, unavailable_reason, label, type, arm, blocking, clears, gives_back_weekly, paused, percent_used.
        "Claude cedar_ember grant": EndpointConfirmedSchema(
            jsonKeys: [
                "id", "resets_left", "resets_total", "ends_at", "starts_at",
                "usable_now", "use_requires_limit", "unavailable_reason",
                "label", "type", "arm", "blocking", "clears",
                "gives_back_weekly", "paused", "percent_used"
            ]
        ),
        // Displayed: is_active, kind, percent, resets_at, scope. Confirmed-ignored: group, severity.
        "Claude limit": EndpointConfirmedSchema(
            jsonKeys: ["group", "is_active", "kind", "percent", "resets_at", "scope", "severity"]
        ),
        // Displayed: as_of, window_started_at, rows.
        "Claude breakdown": EndpointConfirmedSchema(
            jsonKeys: ["as_of", "window_started_at", "rows"]
        ),
        // Displayed: key, display_name, percent. Confirmed-ignored: percent_of_limit.
        "Claude breakdown row": EndpointConfirmedSchema(
            jsonKeys: ["key", "display_name", "percent", "percent_of_limit"]
        )
    ])

    // MARK: - 2. Codex (ChatGPT backend wham API)
    private static let codex = ProviderConfirmedSchema(endpoints: [
        // Displayed: plan_type, rate_limit, additional_rate_limits, code_review_rate_limit, credits, rate_limit_reset_credits, email.
        // Confirmed-ignored: rate_limit_reached_type, spend_control, account_id, user_id, promo, model_usage.
        "Codex": EndpointConfirmedSchema(
            jsonKeys: [
                "plan_type", "rate_limit", "additional_rate_limits",
                "code_review_rate_limit", "credits", "rate_limit_reset_credits",
                "rate_limit_reached_type", "spend_control", "email",
                "account_id", "user_id", "promo", "model_usage"
            ],
            enums: [
                "plan_type": [
                    "free", "plus", "pro", "prolite", "promax", "team",
                    "business", "enterprise", "edu", "go", "self_serve_business_prolite"
                ]
            ]
        ),
        // Displayed: primary_window, secondary_window. Confirmed-ignored: allowed, limit_reached.
        "Codex rate_limit": EndpointConfirmedSchema(
            jsonKeys: ["allowed", "limit_reached", "primary_window", "secondary_window"]
        ),
        // Displayed: limit_window_seconds, reset_after_seconds, reset_at, used_percent.
        "Codex window": EndpointConfirmedSchema(
            jsonKeys: ["limit_window_seconds", "reset_after_seconds", "reset_at", "used_percent"]
        ),
        // Displayed: has_credits, unlimited, balance.
        // Confirmed-ignored: overage_limit_reached, approx_local_messages, approx_cloud_messages.
        "Codex credits": EndpointConfirmedSchema(
            jsonKeys: [
                "has_credits", "unlimited", "balance", "overage_limit_reached",
                "approx_local_messages", "approx_cloud_messages"
            ]
        ),
        // Displayed: available_count, applicable_available_count.
        "Codex rate_limit_reset_credits": EndpointConfirmedSchema(
            jsonKeys: ["available_count", "applicable_available_count"]
        ),
        // Displayed: reached (when true). Confirmed-ignored: individual_limit.
        "Codex spend_control": EndpointConfirmedSchema(
            jsonKeys: ["individual_limit", "reached"]
        ),
        // Displayed: available_count, credits.
        // Confirmed-ignored: history_enabled, immediate_reset_purchase_eligible, total_earned_count.
        "Codex reset_credits": EndpointConfirmedSchema(
            jsonKeys: [
                "available_count", "credits", "history_enabled",
                "immediate_reset_purchase_eligible", "total_earned_count"
            ]
        ),
        // Displayed: status, expires_at.
        // Confirmed-ignored: id, granted_at, title, description, is_supported_by_plan, profile_image_url, profile_user_id, redeem_started_at, redeemed_at, reset_type.
        "Codex reset_credit": EndpointConfirmedSchema(
            jsonKeys: [
                "id", "status", "expires_at", "granted_at", "title", "description",
                "is_supported_by_plan", "profile_image_url", "profile_user_id",
                "redeem_started_at", "redeemed_at", "reset_type"
            ]
        )
    ])

    // MARK: - 3. Cursor & X Subscription
    private static let cursor = ProviderConfirmedSchema(endpoints: [
        // Displayed: enabled, billingCycleEnd, planUsage, spendLimitUsage.
        // Confirmed-ignored: billingCycleStart, membershipType, limitType, isUnlimited, autoBucketModels,
        //   displayMessage, displayThreshold, autoModelSelectedDisplayMessage, namedModelSelectedDisplayMessage, individualUsage, teamUsage.
        "Cursor": EndpointConfirmedSchema(
            jsonKeys: [
                "enabled", "billingCycleStart", "billingCycleEnd", "membershipType",
                "limitType", "isUnlimited", "autoBucketModels", "displayMessage",
                "displayThreshold", "autoModelSelectedDisplayMessage",
                "namedModelSelectedDisplayMessage", "individualUsage", "teamUsage",
                "planUsage", "spendLimitUsage"
            ]
        ),
        // Displayed: totalPercentUsed, autoPercentUsed, apiPercentUsed, limit, remaining, totalSpend.
        // Confirmed-ignored: remainingBonus, bonusTooltip, includedSpend, bonusSpend.
        "Cursor planUsage": EndpointConfirmedSchema(
            jsonKeys: [
                "totalPercentUsed", "autoPercentUsed", "apiPercentUsed",
                "limit", "remaining", "totalSpend", "remainingBonus",
                "bonusTooltip", "includedSpend", "bonusSpend"
            ]
        ),
        // Displayed: individualLimit, individualRemaining, individualUsed, totalSpend, limitType, pooledLimit.
        // Confirmed-ignored: pooledUsed, pooledRemaining.
        "Cursor spendLimitUsage": EndpointConfirmedSchema(
            jsonKeys: [
                "individualLimit", "individualRemaining", "individualUsed",
                "totalSpend", "limitType", "pooledLimit", "pooledUsed", "pooledRemaining"
            ]
        ),
        // Displayed: isMerged, planInfo. Confirmed-ignored: nextUpgrade.
        "Cursor planInfo": EndpointConfirmedSchema(
            jsonKeys: ["isMerged", "planInfo", "nextUpgrade"]
        ),
        // Displayed: availability, weeklyIncludedUsage, weeklyIncludedUsageByProduct, monthlyUsage.
        // Confirmed-ignored: weeklyIncludedStatus, resetCounter, billingCycleStart, billingCycleEnd, onDemandUsage.
        "X Subscription": EndpointConfirmedSchema(
            jsonKeys: [
                "availability", "weeklyIncludedUsage", "weeklyIncludedStatus",
                "weeklyIncludedUsageByProduct", "monthlyUsage", "resetCounter",
                "billingCycleStart", "billingCycleEnd", "onDemandUsage"
            ]
        ),
        // Displayed: usedCents, budgetCents, periodStart, resetsAt. Confirmed-ignored: resetCounter.
        "X Subscription weeklyIncludedUsage": EndpointConfirmedSchema(
            jsonKeys: ["usedCents", "budgetCents", "resetCounter", "periodStart", "resetsAt"]
        ),
        // Displayed: usedCents, limitCents, additionalUsageOff, periodStart, resetsAt. Confirmed-ignored: creditsUsedCents.
        "X Subscription monthlyUsage": EndpointConfirmedSchema(
            jsonKeys: ["usedCents", "limitCents", "creditsUsedCents", "additionalUsageOff", "periodStart", "resetsAt"]
        ),
        // Displayed: isUnified, usagePercent, nextResetTimestampUtc, prepaidAvailableCents, cursorPlanName, grokPlanLabel.
        // Confirmed-ignored: currentPeriodStart, billingBrand, additionalUsageLimit, hasAvailableUsage, hasNonZeroIncludedLimit,
        //   onDemandSettings, unifiedBillingUrl, unifiedUpsellButtons, upgradeOption, upgradeRecommendation, upgradeRecommendations, wouldRefuseSend.
        "X Subscription sand": EndpointConfirmedSchema(
            jsonKeys: [
                "isUnified", "usagePercent", "nextResetTimestampUtc", "prepaidAvailableCents",
                "currentPeriodStart", "cursorPlanName", "grokPlanLabel", "billingBrand",
                "additionalUsageLimit", "hasAvailableUsage", "hasNonZeroIncludedLimit",
                "onDemandSettings", "unifiedBillingUrl", "unifiedUpsellButtons",
                "upgradeOption", "upgradeRecommendation", "upgradeRecommendations", "wouldRefuseSend"
            ]
        )
    ])

    // MARK: - 4. GitHub Copilot
    private static let copilot = ProviderConfirmedSchema(endpoints: [
        // Displayed: access_type_sku, copilot_plan, quota_reset_date, quota_reset_date_utc, quota_snapshots, token_based_billing,
        //   limited_user_quotas, monthly_quotas, limited_user_reset_date.
        // Confirmed-ignored: UI feature flags, telemetry IDs, endpoints map, enterprise/org lists.
        "GitHub Copilot": EndpointConfirmedSchema(
            jsonKeys: [
                "access_type_sku", "analytics_tracking_id", "assigned_date",
                "can_signup_for_limited", "can_upgrade_plan", "chat_enabled",
                "cli_enabled", "cli_remote_control_enabled",
                "cloud_session_storage_enabled", "cloud_sessions_enabled",
                "copilot_app_enabled", "copilot_app_office_plugins_enabled",
                "copilot_plan", "copilotignore_enabled",
                "editor_preview_features_enabled", "endpoints",
                "enterprise_list", "enterprise_usage_telemetry", "id",
                "is_mcp_enabled", "is_staff", "login", "organization_list",
                "organization_login_list", "quota_reset_date",
                "quota_reset_date_utc", "quota_snapshots",
                "restricted_telemetry", "te", "token_based_billing",
                "limited_user_quotas", "monthly_quotas", "limited_user_reset_date"
            ],
            enums: [
                "copilot_plan": [
                    "free", "individual", "individual_pro", "pro",
                    "pro_plus", "business", "enterprise"
                ],
                "access_type_sku": [
                    "free_limited_copilot", "copilot_for_individuals",
                    "copilot_for_business", "copilot_enterprise", "copilot_pro_plus"
                ]
            ]
        ),
        // Displayed: entitlement, overage_count, overage_permitted, percent_remaining, quota_remaining, remaining, unlimited, has_quota, quota_reset_at.
        // Confirmed-ignored: quota_id, credits_used, token_based_billing, timestamp_utc.
        "Copilot bucket": EndpointConfirmedSchema(
            jsonKeys: [
                "entitlement", "overage_count", "overage_permitted",
                "percent_remaining", "quota_id", "quota_remaining",
                "remaining", "unlimited", "has_quota", "credits_used",
                "token_based_billing", "quota_reset_at", "timestamp_utc"
            ]
        )
    ])

    // MARK: - 5. Muse
    private static let muse = ProviderConfirmedSchema(endpoints: [
        // Displayed: tier, usage, topupTotal, topupBalance.
        // Confirmed-ignored: topupEligible, topupRowLabel, topupRowValueLabel, subscriptionType, statusSubtitle, billingSubtitle,
        //   agreement, complimentaryOffer, complimentaryRedeemPage, entryPointCtaLabel, isEligibleToPurchase,
        //   managementActions, usageRowFooter, usageRowLabel, usageRowValueLabel, status, currentPeriodStart/End, cancelAtPeriodEnd, plan, id, userId, createdAt, updatedAt.
        "Muse subscription": EndpointConfirmedSchema(
            jsonKeys: [
                "tier", "usage", "topupTotal", "topupBalance", "topupEligible",
                "topupRowLabel", "topupRowValueLabel", "subscriptionType",
                "statusSubtitle", "billingSubtitle", "agreement", "complimentaryOffer",
                "complimentaryRedeemPage", "entryPointCtaLabel", "isEligibleToPurchase",
                "managementActions", "usageRowFooter", "usageRowLabel", "usageRowValueLabel",
                "status", "currentPeriodStart", "currentPeriodEnd", "cancelAtPeriodEnd",
                "plan", "id", "userId", "createdAt", "updatedAt"
            ],
            requiredJSONKeys: ["usage"],
            enums: [
                "subscriptionType": ["FREE", "PLUS", "PRO", "MAX", "ULTRA", "TEAM", "ENTERPRISE"]
            ]
        ),
        // Displayed: percentUsed, resetsAt. Confirmed-ignored: quotaStatus, state.
        "Muse usage": EndpointConfirmedSchema(
            jsonKeys: ["percentUsed", "quotaStatus", "resetsAt", "state"],
            requiredJSONKeys: ["percentUsed"],
            enums: [
                "state": ["METERED", "UNLIMITED", "EXHAUSTED"]
            ]
        ),
        // Displayed: name. Confirmed-ignored: isPaid, rank, tierCode, tierId.
        "Muse tier": EndpointConfirmedSchema(
            jsonKeys: ["isPaid", "name", "rank", "tierCode", "tierId"]
        )
    ])

    // MARK: - 6. Adobe
    private static let adobe = ProviderConfirmedSchema(endpoints: [
        // Displayed: total, credits.
        "Adobe": EndpointConfirmedSchema(
            jsonKeys: ["total", "credits"]
        ),
        // Displayed: availableUntil, planCap, quota.
        "Adobe total": EndpointConfirmedSchema(
            jsonKeys: ["availableUntil", "planCap", "quota"],
            enums: ["planCap": ["HARD", "SOFT"]]
        ),
        // Displayed: firefly_plan_credit.
        "Adobe credits": EndpointConfirmedSchema(
            jsonKeys: ["firefly_plan_credit"],
            jsonKeyPrefixes: ["firefly"]
        ),
        // Displayed: quota, availableUntil.
        "Adobe credit item": EndpointConfirmedSchema(
            jsonKeys: ["quota", "availableUntil"]
        ),
        // Displayed: available, total, used.
        "Adobe quota": EndpointConfirmedSchema(
            jsonKeys: ["available", "total", "used"]
        )
    ])

    // MARK: - 7. Manus
    private static let manus = ProviderConfirmedSchema(endpoints: [
        // Displayed: totalCredits, freeCredits, bonusCredits, refreshCredits, maxRefreshCredits, nextRefreshTime, refreshInterval, periodicCredits, proMonthlyCredits, addOnCredits.
        // Confirmed-ignored: paidCredits, usedCredits, plan, tier, userFlag.
        "Manus": EndpointConfirmedSchema(
            jsonKeys: [
                "totalCredits", "freeCredits", "refreshCredits", "maxRefreshCredits",
                "nextRefreshTime", "refreshInterval", "periodicCredits", "proMonthlyCredits",
                "addOnCredits", "bonusCredits", "paidCredits", "usedCredits",
                "plan", "tier", "userFlag"
            ],
            enums: [
                "refreshInterval": ["daily", "weekly", "monthly"]
            ]
        )
    ])

    // MARK: - 8. Kimi
    private static let kimi = ProviderConfirmedSchema(endpoints: [
        // Displayed: subscription (goods.title), balances.
        // Confirmed-ignored: cancelRetentionGroup, capabilities, purchaseSubscription.
        "Kimi GetSubscription": EndpointConfirmedSchema(
            jsonKeys: [
                "balances", "cancelRetentionGroup", "capabilities",
                "purchaseSubscription", "subscription"
            ]
        ),
        // Displayed: balances, subscriptionBalance, ratelimitCode7d.
        "Kimi GetSubscriptionStats": EndpointConfirmedSchema(
            jsonKeys: ["balances", "subscriptionBalance", "ratelimitCode7d"]
        ),
        // Displayed: amountUsedRatio, expireTime, resetTime, feature.
        // Confirmed-ignored: domain, id, type, unit.
        "Kimi balance": EndpointConfirmedSchema(
            jsonKeys: [
                "amountUsedRatio", "domain", "expireTime", "resetTime",
                "feature", "id", "type", "unit"
            ]
        ),
        // Displayed: usages (paid Kimi Code). Confirmed-ignored: totalQuota (free account default 100/100 stub).
        "Kimi GetUsages": EndpointConfirmedSchema(
            jsonKeys: ["usages", "totalQuota"]
        )
    ])

    // MARK: - 9. Qwen
    private static let qwen = ProviderConfirmedSchema(endpoints: [
        // Displayed: remainingPercent, resetAt, memberType. Confirmed-ignored: lowCredits, status.
        "Qwen agent/usage": EndpointConfirmedSchema(
            jsonKeys: ["lowCredits", "memberType", "remainingPercent", "resetAt", "status"],
            requiredJSONKeys: ["remainingPercent"]
        ),
        // Displayed: entitlements. Confirmed-ignored: creditsRemain, scopes, total, balance.
        "Qwen credits": EndpointConfirmedSchema(
            jsonKeys: ["creditsRemain", "entitlements", "scopes", "total", "balance"]
        ),
        // Displayed: balance, entitlementCode, expireAt, frequency, total.
        "Qwen entitlement": EndpointConfirmedSchema(
            jsonKeys: ["balance", "entitlementCode", "expireAt", "frequency", "total"]
        ),
        // Displayed: frequencyEntitlementCode, refreshAt, usedPercent. Confirmed-ignored: scope.
        "Qwen frequency": EndpointConfirmedSchema(
            jsonKeys: ["frequencyEntitlementCode", "refreshAt", "scope", "usedPercent"]
        ),
        // Displayed: coupons.
        "Qwen resets": EndpointConfirmedSchema(
            jsonKeys: ["coupons"]
        ),
        // Displayed: memberName, memberType.
        // Confirmed-ignored: expireTime, payChannel, productId, productUnit, subscribeStatus, userId.
        "Qwen member": EndpointConfirmedSchema(
            jsonKeys: [
                "expireTime", "memberName", "memberType", "payChannel",
                "productId", "productUnit", "subscribeStatus", "userId"
            ],
            enums: [
                "memberType": ["free", "lite", "go", "plus", "pro"]
            ]
        )
    ])

    // MARK: - 10. MiniMax
    private static let minimax = ProviderConfirmedSchema(endpoints: [
        // Displayed: model_remains.
        "MiniMax remains": EndpointConfirmedSchema(
            jsonKeys: ["model_remains", "base_resp"]
        ),
        // Displayed: model_name, current_interval_*_percent/count/status, current_weekly_*_percent/status, end_time, weekly_end_time, remains_time, weekly_remains_time.
        // Confirmed-ignored: start_time, weekly_start_time.
        "MiniMax model_remains": EndpointConfirmedSchema(
            jsonKeys: [
                "model_name", "current_interval_total_percent",
                "current_interval_used_percent", "current_interval_remaining_percent",
                "current_interval_status",
                "current_weekly_total_percent", "current_weekly_used_percent",
                "current_weekly_remaining_percent", "current_weekly_status",
                "current_interval_total_count", "current_interval_used_count",
                "current_interval_usage_count",
                "remains_time", "weekly_remains_time",
                "start_time", "end_time",
                "weekly_start_time", "weekly_end_time"
            ]
        ),
        // Displayed: remaining_credits, total_credits, balance_breakdown.
        // Confirmed-ignored: api_key, used_credits, enable_credit_first_for_high_cost, token_plan_credit_fallback_enabled.
        "MiniMax tokenPlanCredit": EndpointConfirmedSchema(
            jsonKeys: [
                "api_key", "balance_breakdown", "base_resp",
                "enable_credit_first_for_high_cost", "remaining_credits",
                "token_plan_credit_fallback_enabled", "total_credits", "used_credits"
            ]
        ),
        // Displayed: token_plan_tier, plan_name, op_credit_summary, opcredit_balance, total_remains_credit, daily_login_gift_credit_remaining, op_group_id, email, user_email.
        // Confirmed-ignored: can_upgrade, expires_at, has_token_plan, is_migrated_to_op,
        //   is_pro_builder, next_plan_name, pending_credit, plan_type, purchase_source, subscription_type, upgrade_action, will_renewal.
        "MiniMax membership": EndpointConfirmedSchema(
            jsonKeys: [
                "base_resp", "can_upgrade", "daily_login_gift_credit_remaining",
                "expires_at", "has_token_plan", "is_migrated_to_op",
                "is_pro_builder", "next_plan_name", "op_credit_summary",
                "op_group_id", "opcredit_balance", "pending_credit", "plan_name",
                "plan_type", "purchase_source", "subscription_type",
                "token_plan_tier", "total_remains_credit", "upgrade_action",
                "will_renewal", "email", "user_email"
            ]
        ),
        // Displayed: wallets, total_credit. Confirmed-ignored: can_migrate, migrate_end_time.
        "MiniMax wallet": EndpointConfirmedSchema(
            jsonKeys: ["can_migrate", "migrate_end_time", "wallets", "total_credit"]
        ),
        // Displayed: source, total_credit, plan_name.
        // Confirmed-ignored: cycle_type, debit_credit, end_time, next_credit_refresh_time, next_renewal_time, privilege_type, renewal_state, sub_credits, subscription_state_known, url.
        "MiniMax wallet item": EndpointConfirmedSchema(
            jsonKeys: [
                "cycle_type", "debit_credit", "end_time",
                "next_credit_refresh_time", "next_renewal_time", "plan_name",
                "privilege_type", "renewal_state", "source", "sub_credits",
                "subscription_state_known", "total_credit", "url"
            ]
        ),
        // Displayed: account. Confirmed-ignored: uid, user_name.
        "MiniMax profile": EndpointConfirmedSchema(
            jsonKeys: ["account", "uid", "user_name"]
        ),
        // Displayed: total_credit. Confirmed-ignored: base_resp, debit_credit, sub_credits.
        "MiniMax hailuo credit": EndpointConfirmedSchema(
            jsonKeys: ["base_resp", "debit_credit", "sub_credits", "total_credit"]
        ),
        // Displayed: memberName. Confirmed-ignored: Hailuo UI/model catalog metadata.
        "MiniMax hailuo equity": EndpointConfirmedSchema(
            jsonKeys: [
                "canManagePlan", "creditExpireText", "debitCredit", "expireText",
                "expireTime", "imageQueueLength", "isNewUser", "isPaidSubscription",
                "memberHoverText", "memberName", "memberText", "modelControl",
                "msg", "newUserVersion", "privilegeType", "questionText",
                "queueLength", "supportModes", "totalCredits", "totalCreditsStr",
                "trialExpireTime", "trialText", "videoCost"
            ]
        )
    ])

    // MARK: - 11. Qoder
    private static let qoder = ProviderConfirmedSchema(endpoints: [
        // Displayed: displayMode, qoderUsage. Confirmed-ignored: enterpriseUsage (in enterprise mode).
        "Qoder": EndpointConfirmedSchema(
            jsonKeys: ["displayMode", "qoderUsage", "enterpriseUsage"],
            enums: ["displayMode": ["qoder", "enterprise"]]
        ),
        // Displayed: userId, userType, expiresAt, refreshAt, userQuota, addOnQuota, orgResourcePackage, dedicatedResourcePackages.
        // Confirmed-ignored: usageType, totalUsagePercentage, isQuotaExceeded, isPlanQuotaProrated, isHighestTier, upgradeUrl.
        "Qoder usage": EndpointConfirmedSchema(
            jsonKeys: [
                "userId", "userType", "usageType", "totalUsagePercentage",
                "isQuotaExceeded", "isPlanQuotaProrated", "isHighestTier", "expiresAt", "refreshAt",
                "upgradeUrl", "userQuota", "addOnQuota", "orgResourcePackage", "dedicatedResourcePackages"
            ],
            requiredJSONKeys: ["userQuota"],
            enums: [
                "usageType": ["credits"],
                "userType": [
                    "personal_free", "personal_standard", "personal_pro", "personal_ultra",
                    "personal_professional_trial", "free", "standard", "pro", "ultra", "enterprise"
                ]
            ]
        ),
        // Displayed: remaining, total, used, percentage, cap. Confirmed-ignored: detailUrl, unit, available.
        "Qoder quota": EndpointConfirmedSchema(
            jsonKeys: ["available", "cap", "detailUrl", "percentage", "remaining", "total", "unit", "used"]
        ),
        // Displayed: id, name, total, used, remaining, percentage, expiresAt/expires_at.
        "Qoder dedicated package": EndpointConfirmedSchema(
            jsonKeys: [
                "id", "name", "description", "total", "used", "remaining",
                "percentage", "unit", "expiresAt", "expires_at",
                "available", "status", "displayLabels", "display_labels"
            ]
        ),
        // Displayed: plan_tier_name / planName.
        // Confirmed-ignored: end_date, feature_allowed, is_highest_tier, is_paid_plan, is_personal_version, start_date, user_type.
        "Qoder plan": EndpointConfirmedSchema(
            jsonKeys: [
                "end_date", "feature_allowed", "is_highest_tier", "is_paid_plan",
                "is_personal_version", "plan_tier_name", "planTierName",
                "plan_name", "planName", "start_date", "user_type"
            ]
        )
    ])

    // MARK: - 12. Gemini (Web GraphQL & Native Protobuf)
    private static let gemini = ProviderConfirmedSchema(endpoints: [
        // Displayed: subscriptionTier, pools, useOverageAiCredits. Confirmed-ignored: advancedSettings.
        "Gemini Web getUsageInfo": EndpointConfirmedSchema(
            jsonKeys: ["subscriptionTier", "pools", "advancedSettings", "useOverageAiCredits"],
            requiredJSONKeys: ["pools"],
            enums: ["subscriptionTier": ["FREE", "TIER0", "TIER1"]]
        ),
        // Displayed: poolType, percentageUsed, gxu, credits, overageCredits, creditsRemaining.
        "Gemini Web pool": EndpointConfirmedSchema(
            jsonKeys: [
                "poolType", "percentageUsed", "gxu", "credits",
                "overageCredits", "creditsRemaining"
            ],
            requiredJSONKeys: ["poolType"],
            enums: ["poolType": ["GXU_FIVE_HOURLY", "GXU_WEEKLY", "OVERAGE_CREDITS"]]
        ),
        // Displayed: windowRefreshesAt, remaining, limit, total. Confirmed-ignored: title.
        "Gemini Web gxu": EndpointConfirmedSchema(
            jsonKeys: ["windowRefreshesAt", "remaining", "limit", "total", "title"],
            requiredJSONKeys: ["windowRefreshesAt"]
        ),
        // Displayed: creditsRemaining, remaining, useOverageAiCredits, expiresAt. Confirmed-ignored: title, description, learnMoreUrl.
        "Gemini Web credits": EndpointConfirmedSchema(
            jsonKeys: [
                "creditsRemaining", "remaining", "useOverageAiCredits",
                "expiresAt", "title", "description", "learnMoreUrl"
            ]
        ),
        // Native GetUsageInfo protobuf top-level tags:
        // Displayed: #2 (user_tier), #3 (pools). Confirmed-ignored: #1 (id/header), #4 (disclaimer), #5 (advanced_settings).
        "Gemini Native": EndpointConfirmedSchema(
            protobufTags: [1, 2, 3, 4, 5],
            requiredProtobufTags: [2, 3],
            enums: ["user_tier": ["0", "1", "2"]]
        ),
        // Native Pool protobuf tags (#1 type, #2 gxu, #3 credits):
        "Gemini Native pool": EndpointConfirmedSchema(
            protobufTags: [1, 2, 3],
            requiredProtobufTags: [1],
            enums: ["pool_type": ["1", "2", "3"]]
        ),
        // Native GxuPool protobuf tags (#1 reset_time, #2 percentage_used, #5 remaining, #6 limit):
        // Confirmed-ignored: #3 (title), #4 (subtitle/tip).
        "Gemini Native GxuPool": EndpointConfirmedSchema(
            protobufTags: [1, 2, 3, 4, 5, 6],
            requiredProtobufTags: [1, 2]
        ),
        // Native OverageCreditPool protobuf tags (#1 expires_at, #2 credits_remaining, #3 use_overage_ai_credits):
        // Confirmed-ignored: #4 (title), #5 (description), #6 (learn_more_url).
        "Gemini Native OverageCreditPool": EndpointConfirmedSchema(
            protobufTags: [1, 2, 3, 4, 5, 6]
        ),
        // Flow Music `/__api/billing/credits` response:
        "Gemini Flow Music": EndpointConfirmedSchema(
            jsonKeys: ["data", "add_token_transactions"],
            requiredJSONKeys: ["data"]
        ),
        "Gemini Flow Music data": EndpointConfirmedSchema(
            jsonKeys: ["credits_remaining", "tokens_remaining"],
            requiredJSONKeys: ["credits_remaining"]
        )
    ])

    // MARK: - 13. Antigravity
    private static let antigravity = ProviderConfirmedSchema(endpoints: [
        // Displayed: currentTier, paidTier, cloudaicompanionProject.
        // Confirmed-ignored: allowedTiers, gcpManaged, upgradeSubscriptionUri, ineligibleTiers, userInfo.
        "Antigravity loadCodeAssist": EndpointConfirmedSchema(
            jsonKeys: [
                "currentTier", "allowedTiers", "cloudaicompanionProject",
                "gcpManaged", "upgradeSubscriptionUri", "paidTier",
                "ineligibleTiers", "userInfo"
            ],
            requiredJSONKeys: ["currentTier"]
        ),
        // Displayed: id, name, availableCredits.
        // Confirmed-ignored: description, upgradeSubscriptionUri/Text/Type, privacyNotice, isDefault, usesGcpTos, userDefinedCloudaicompanionProject.
        "Antigravity paidTier": EndpointConfirmedSchema(
            jsonKeys: [
                "id", "name", "description", "upgradeSubscriptionUri",
                "upgradeSubscriptionText", "upgradeSubscriptionType",
                "availableCredits", "privacyNotice", "isDefault",
                "usesGcpTos", "userDefinedCloudaicompanionProject"
            ],
            enums: [
                "paidTier.id": [
                    "g1-pro-tier", "g1-ultra-tier", "g1-ultra-lite-tier",
                    "standard-tier", "free-tier"
                ]
            ]
        ),
        // Displayed: creditType, creditAmount. Confirmed-ignored: minimumCreditAmountForUsage.
        "Antigravity availableCredits": EndpointConfirmedSchema(
            jsonKeys: ["creditType", "creditAmount", "minimumCreditAmountForUsage"],
            enums: ["creditType": ["GOOGLE_ONE_AI"]]
        ),
        // Displayed: groups, response. Confirmed-ignored: description.
        "Antigravity quotaSummary": EndpointConfirmedSchema(
            jsonKeys: ["groups", "description", "response"],
            requiredJSONKeys: ["groups"]
        ),
        // Displayed: buckets, displayName. Confirmed-ignored: description.
        "Antigravity group": EndpointConfirmedSchema(
            jsonKeys: ["buckets", "displayName", "description"],
            requiredJSONKeys: ["buckets"]
        ),
        // Displayed: bucketId, displayName, window, resetTime, remainingFraction, disabled. Confirmed-ignored: description.
        "Antigravity bucket": EndpointConfirmedSchema(
            jsonKeys: [
                "bucketId", "displayName", "window",
                "resetTime", "description", "remainingFraction", "disabled"
            ],
            requiredJSONKeys: ["bucketId"]
        )
    ])
}
