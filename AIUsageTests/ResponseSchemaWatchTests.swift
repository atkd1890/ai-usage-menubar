import Foundation
import XCTest
@testable import AIUsage

final class ResponseSchemaWatchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testHTTPDeprecationAndSunsetHeadersEmitAPIDeprecatedWarnings() {
        let resp = HTTPResponse(
            statusCode: 200,
            headers: [
                "Deprecation": "true",
                "Sunset": "Wed, 01 Apr 2027 00:00:00 GMT",
                "Warning": #"299 - "v1 endpoint deprecated""#,
                "X-API-Warn": "Upgrade client soon"
            ],
            body: Data()
        )
        let warnings = ResponseSchemaWatch.httpHeaders(resp, endpoint: "TestEndpoint")
        XCTAssertEqual(warnings.count, 4)
        XCTAssertTrue(warnings.allSatisfy { $0.kind == .apiDeprecated })

        let nonDeprecationWarning = HTTPResponse(
            statusCode: 200,
            headers: [
                "Deprecation": "false",
                "Warning": "199 - Miscellaneous info"
            ],
            body: Data()
        )
        XCTAssertTrue(ResponseSchemaWatch.httpHeaders(nonDeprecationWarning, endpoint: "TestEndpoint").isEmpty)
    }

    func testJSONKeysDetectsAddedAndRemovedAndIgnoresNoiseAndPrefixes() {
        let object: [String: Any] = [
            "request_id": "abc-123",
            "traceId": "trace-1",
            "seven_day_sonnet": ["utilization": 10],
            "brand_new_field": 42
        ]
        let warnings = ResponseSchemaWatch.jsonKeys(
            in: object,
            endpoint: "Claude",
            known: ["five_hour"],
            knownPrefixes: ["seven_day_"],
            required: ["five_hour", "required_missing"]
        )
        XCTAssertEqual(warnings.map(\.kind), [.schemaAdded, .schemaRemoved])
        XCTAssertEqual(warnings[0].summary, "New field in Claude")
        XCTAssertEqual(warnings[0].detail, "brand_new_field: 42")
        XCTAssertFalse(warnings[0].summary.contains("brand_new_field"))
        XCTAssertEqual(warnings[1].summary, "Missing fields in Claude")
        XCTAssertEqual(warnings[1].detail, "five_hour, required_missing")
    }

    func testProtobufFieldsDetectsAddedAndRemovedTags() {
        let fields = [
            GeminiProtobuf.Field(number: 2, integer: 2),
            GeminiProtobuf.Field(number: 7, integer: 1)
        ]
        let warnings = ResponseSchemaWatch.protobufFields(
            fields,
            endpoint: "Gemini Native",
            known: [1, 2, 3],
            required: [2, 3]
        )
        XCTAssertEqual(warnings.map(\.kind), [.schemaAdded, .schemaRemoved])
        XCTAssertEqual(warnings[0].summary, "New protobuf field in Gemini Native")
        XCTAssertEqual(warnings[0].detail, "#7: 1")
        XCTAssertEqual(warnings[1].summary, "Missing protobuf field in Gemini Native")
        XCTAssertEqual(warnings[1].detail, "#3")
    }

    func testGeminiNativeParsesGxuRemainingLimitAndDetectsOverageAndUnknownTags() throws {
        // Live-shaped clean payload with tier=2, pool 1 (2400/2400), pool 2 (44410/48384), fields #4 & #5
        let ts = pbMsg(1, pbVarint(1, 1_800_100_000) + pbVarint(2, 500_000_000))
        let gxu1 = ts + pbFloat(2, 0.0) + pbStr(3, "Current usage") + pbMsg(4, pbStr(1, "Tip")) + pbVarint(5, 2400) + pbVarint(6, 2400)
        let gxu2 = ts + pbFloat(2, 0.08212207) + pbStr(3, "Weekly limit") + pbVarint(5, 44410) + pbVarint(6, 48384)
        let cleanBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu1))
            + pbMsg(3, pbVarint(1, 2) + pbMsg(2, gxu2))
            + pbMsg(4, pbStr(1, "Disclaimer"))
            + pbMsg(5, pbStr(1, "Advanced"))

        let clean = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: cleanBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertTrue(clean.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(clean.windows.count, 2)
        XCTAssertEqual(clean.windows[0].remainingCount, 2400)
        XCTAssertEqual(clean.windows[0].limitCount, 2400)
        XCTAssertEqual(clean.windows[1].remainingCount, 44410)
        XCTAssertEqual(clean.windows[1].limitCount, 48384)

        // Unknown top-level tag #7 + OVERAGE_CREDITS pool (type=3)
        let driftedBody = cleanBody
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(1, 150)))
            + pbVarint(7, 99)
        let drifted = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: driftedBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertTrue(drifted.quotaCompatibilityNotes.isEmpty)
        XCTAssertTrue(drifted.allDiagnosticWarnings.contains { $0.id == "schema.added.gemini.overage_credits" })
        XCTAssertTrue(drifted.allDiagnosticWarnings.contains {
            $0.kind == .schemaAdded && $0.detail.contains("#7: 99")
        })
    }

    func testGeminiWebMapsUseOverageAiCreditsAndDetectsSchemaDrift() throws {
        let cleanJSON = #"""
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{
          "subscriptionTier":"TIER1",
          "pools":[
            {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.0,"gxu":{"windowRefreshesAt":"2026-11-20T12:03:43Z"}},
            {"poolType":"GXU_WEEKLY","percentageUsed":0.0821,"gxu":{"windowRefreshesAt":"2026-11-23T01:03:43Z"}}
          ],
          "advancedSettings":null,
          "useOverageAiCredits":false
        }}},"if_workspace_upsell_enabled":{"rpcs":{"fetchRecommendations":null}}},"errors":[{"message":"upsell"}]}]
        """#
        let clean = try GeminiUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: Data(cleanJSON.utf8)),
            now: now
        )
        XCTAssertEqual(clean.planName, "Google AI Pro")
        XCTAssertTrue(clean.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(clean.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "Off")
        ])

        let overageAndDriftJSON = #"""
        [{"data":{"viewer":{"rpcs":{"getUsageInfo":{
          "subscriptionTier":"TIER_FUTURE",
          "brandNewTopKey":123,
          "pools":[
            {"poolType":"GXU_WEEKLY","percentageUsed":0.1,"gxu":{"windowRefreshesAt":"2026-11-23T01:03:43Z","remaining":900,"limit":1000}},
            {"poolType":"OVERAGE_CREDITS","credits":{"creditsRemaining":250}}
          ],
          "useOverageAiCredits":true
        }}}}}]
        """#
        let drifted = try GeminiUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: Data(overageAndDriftJSON.utf8)),
            now: now
        )
        XCTAssertEqual(drifted.windows.first?.remainingCount, 900)
        XCTAssertEqual(drifted.windows.first?.limitCount, 1000)
        XCTAssertEqual(drifted.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 250")
        ])
        XCTAssertTrue(drifted.allDiagnosticWarnings.contains { $0.detail.contains("brandNewTopKey: 123") })
        XCTAssertTrue(drifted.allDiagnosticWarnings.contains { $0.detail.contains("TIER_FUTURE") })
    }

    func testAntigravityClientUACreditsParsingAndSchemaDrift() throws {
        XCTAssertTrue(AntigravityUsageClient.clientUserAgent(version: "2.33.0").hasPrefix("antigravity/2.33.0 "))
        XCTAssertTrue(AntigravityUsageClient.clientUserAgent(version: nil).hasPrefix("antigravity/2.26.0 "))

        let cleanLoadCodeAssist = Data(#"""
        {
          "currentTier":{"id":"free-tier","name":"Antigravity"},
          "allowedTiers":[{"id":"free-tier"}],
          "cloudaicompanionProject":"p-123",
          "gcpManaged":false,
          "upgradeSubscriptionUri":"https://codeassist.google.com/upgrade",
          "paidTier":{
            "id":"g1-pro-tier",
            "name":"Google AI Pro",
            "description":"Google AI Pro",
            "upgradeSubscriptionUri":"https://antigravity.google/g1-upgrade",
            "upgradeSubscriptionText":"Upgrade",
            "availableCredits":[{"creditType":"GOOGLE_ONE_AI","minimumCreditAmountForUsage":"50"}]
          }
        }
        """#.utf8)
        XCTAssertEqual(
            AntigravityUsageMapper.aiCreditsDetail(cleanLoadCodeAssist),
            ProviderUsageDetail(id: "antigravity.ai.credits", title: "Additional Credits", value: "AI Credits 0")
        )
        XCTAssertTrue(AntigravityUsageMapper.codeAssistWarnings(cleanLoadCodeAssist).isEmpty)

        let withCredits = Data(#"""
        {"currentTier":{"id":"free-tier"},"paidTier":{"id":"g1-pro-tier","availableCredits":[{"creditType":"GOOGLE_ONE_AI","creditAmount":"1000"}]}}
        """#.utf8)
        XCTAssertEqual(
            AntigravityUsageMapper.aiCreditsDetail(withCredits),
            ProviderUsageDetail(
                id: "antigravity.ai.credits",
                title: "Additional Credits",
                value: "AI Credits \(1000.formatted(.number))"
            )
        )

        let cleanSummaryData = Data(#"""
        {
          "groups":[
            {"displayName":"Gemini Models","description":"Models","buckets":[
              {"bucketId":"gemini-5h","displayName":"Five Hour","window":"5h","resetTime":"2026-11-20T12:00:00Z","remainingFraction":1}
            ]}
          ],
          "description":"Shared limits"
        }
        """#.utf8)
        let cleanSnapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [AntigravityHostSummary(host: .app, data: cleanSummaryData)],
            planName: "Google AI Pro",
            now: now,
            extraDetails: [try XCTUnwrap(AntigravityUsageMapper.aiCreditsDetail(cleanLoadCodeAssist))],
            extraWarnings: AntigravityUsageMapper.codeAssistWarnings(cleanLoadCodeAssist)
        ))
        XCTAssertTrue(cleanSnapshot.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(cleanSnapshot.usageDetails.first?.value, "AI Credits 0")

        let driftedCodeAssist = Data(#"""
        {"currentTier":{"id":"free-tier"},"paidTier":{"id":"g1-new-tier","availableCredits":[{"creditType":"GOOGLE_ONE_AI"}]}}
        """#.utf8)
        let driftedSummary = Data(#"""
        {"groups":[{"displayName":"Gemini","buckets":[{"bucketId":"gemini-5h","remainingFraction":1,"newBucketKey":true}]}]}
        """#.utf8)
        let driftedSnapshot = try XCTUnwrap(AntigravityUsageMapper.summary(
            [AntigravityHostSummary(host: .app, data: driftedSummary, headers: ["Sunset": "2027-01-01"])],
            planName: nil,
            now: now,
            extraWarnings: AntigravityUsageMapper.codeAssistWarnings(driftedCodeAssist)
        ))
        XCTAssertTrue(driftedSnapshot.allDiagnosticWarnings.contains { $0.detail.contains("g1-new-tier") })
        XCTAssertTrue(driftedSnapshot.allDiagnosticWarnings.contains { $0.detail.contains("newBucketKey: true") })
        XCTAssertTrue(driftedSnapshot.allDiagnosticWarnings.contains { $0.kind == .apiDeprecated })
    }

    func testMuseRotatedActionHashEmitsAPIDeprecatedWarning() async throws {
        let rotatedID = String(repeating: "b", count: 40)
        let chunk = "createServerReference(\"\(rotatedID)\",callServer,void 0,findSourceMapURL,\"fetchSubscriptionAction\")"
        let subBody = Data(#"1:{"success":true,"subscription":{"tier":{"name":"Muse Free"},"usage":{"percentUsed":10,"resetsAt":1795183771}}}"#.utf8)
        let http = MockHTTPClient([
            httpResponse(404),
            httpResponse(json: chunk),
            HTTPResponse(statusCode: 200, headers: [:], body: subBody)
        ])
        let provider = MuseProvider(
            http: http,
            cookies: { "hatch_sess=synthetic; hatch_gw=gateway" },
            action: MuseProvider.verifiedAction,
            pageScripts: { _ in ["/_next/static/chunks/settings.js"] },
            saveAction: { _ in }
        )
        let snapshot = try await provider.fetch()
        XCTAssertTrue(snapshot.allDiagnosticWarnings.contains {
            $0.id == "api.version.muse.action" && $0.kind == .apiDeprecated
        })
    }

    func testSnapshotMergesDiagnosticWarningsAndPartialCompatibilityNotes() {
        let warning = ProviderDiagnosticWarning(
            id: "schema.added.test",
            kind: .schemaAdded,
            summary: "New field detected",
            detail: "Detail"
        )
        let snapshot = ProviderSnapshot(
            provider: .claude,
            planName: "Pro",
            windows: [],
            fetchedAt: now,
            usageDetails: [QuotaDiscovery.notice("future_bucket")],
            diagnosticWarnings: [warning]
        )
        XCTAssertTrue(snapshot.hasDiagnosticWarnings)
        XCTAssertEqual(snapshot.allDiagnosticWarnings.map(\.kind), [.schemaAdded, .partialCompatibility])
    }

    func testConfirmedSchemaCatalogCoversEveryProviderID() {
        for provider in ProviderID.allCases {
            let baseline = ConfirmedSchemaCatalog.baseline(for: provider)
            XCTAssertFalse(baseline.endpoints.isEmpty, "\(provider.rawValue) must define confirmed endpoints")
        }
    }

    func testManualUpdateWorkflowPersistsClearsAndDetectsSubsequentChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ConfirmedSchema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("confirmed-schemas.json")

        let store = ConfirmedSchemaStore(fileURL: fileURL)

        let driftedPayload: [String: Any] = [
            "availability": "available",
            "weeklyIncludedUsage": ["usedCents": 100, "budgetCents": 1000, "resetsAt": "2026-11-21T00:00:00Z"],
            "brandNewXKey": "experimental"
        ]
        let addedWarnings = ResponseSchemaWatch.confirmedJSONKeys(
            in: driftedPayload,
            provider: .cursor,
            endpoint: "X Subscription",
            store: store
        )
        let headerWarnings = ResponseSchemaWatch.httpHeaders(
            HTTPResponse(statusCode: 200, headers: ["Sunset": "Sat, 01 May 2027 00:00:00 GMT"], body: Data()),
            provider: .cursor,
            endpoint: "X Subscription",
            store: store
        )
        let enumWarning = ResponseSchemaWatch.confirmedEnum(
            "ULTRA_PRO",
            provider: .qwen,
            endpoint: "Qwen member",
            field: "memberType",
            store: store
        )
        let missingRequiredWarnings = ResponseSchemaWatch.confirmedJSONKeys(
            in: ["topupTotal": 0],
            provider: .muse,
            endpoint: "Muse subscription",
            store: store
        )
        let pbWarnings = ResponseSchemaWatch.confirmedProtobufFields(
            [GeminiProtobuf.Field(number: 2, integer: 2), GeminiProtobuf.Field(number: 3, bytes: Data()), GeminiProtobuf.Field(number: 99, integer: 1)],
            provider: .gemini,
            endpoint: "Gemini Native",
            store: store
        )

        XCTAssertEqual(addedWarnings.first?.patch, .addJSONKeys(endpoint: "X Subscription", keys: ["brandNewXKey"]))
        XCTAssertNotNil(headerWarnings.first?.patch)
        XCTAssertEqual(enumWarning?.patch, .addEnumValue(endpoint: "Qwen member", field: "memberType", value: "ULTRA_PRO"))
        XCTAssertEqual(missingRequiredWarnings.first?.patch, .relaxRequiredJSONKeys(endpoint: "Muse subscription", keys: ["usage"]))
        XCTAssertEqual(pbWarnings.first?.patch, .addProtobufTags(endpoint: "Gemini Native", tags: [99]))

        let cursorSnap = ProviderSnapshot(
            provider: .cursor,
            planName: "Plus",
            windows: [],
            fetchedAt: now,
            diagnosticWarnings: addedWarnings + headerWarnings
        )
        XCTAssertEqual(store.activeWarnings(for: cursorSnap).count, 2)

        store.confirm(warnings: cursorSnap.allDiagnosticWarnings, for: .cursor)
        store.confirm(warnings: [try XCTUnwrap(enumWarning)], for: .qwen)
        store.confirm(warnings: missingRequiredWarnings, for: .muse)
        store.confirm(warnings: pbWarnings, for: .gemini)

        XCTAssertTrue(store.activeWarnings(for: cursorSnap).isEmpty)
        XCTAssertFalse(store.hasActiveWarnings(for: cursorSnap))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Reloading from disk must retain confirmed overrides while detecting new drift.
        let reloaded = ConfirmedSchemaStore(fileURL: fileURL)
        XCTAssertTrue(
            ResponseSchemaWatch.confirmedJSONKeys(
                in: driftedPayload,
                provider: .cursor,
                endpoint: "X Subscription",
                store: reloaded
            ).isEmpty
        )
        XCTAssertTrue(
            ResponseSchemaWatch.httpHeaders(
                HTTPResponse(statusCode: 200, headers: ["Sunset": "Sat, 01 May 2027 00:00:00 GMT"], body: Data()),
                provider: .cursor,
                endpoint: "X Subscription",
                store: reloaded
            ).isEmpty
        )
        XCTAssertNil(
            ResponseSchemaWatch.confirmedEnum(
                "ULTRA_PRO",
                provider: .qwen,
                endpoint: "Qwen member",
                field: "memberType",
                store: reloaded
            )
        )
        XCTAssertTrue(
            ResponseSchemaWatch.confirmedJSONKeys(
                in: ["topupTotal": 0],
                provider: .muse,
                endpoint: "Muse subscription",
                store: reloaded
            ).isEmpty
        )
        XCTAssertTrue(
            ResponseSchemaWatch.confirmedProtobufFields(
                [GeminiProtobuf.Field(number: 2, integer: 2), GeminiProtobuf.Field(number: 3, bytes: Data()), GeminiProtobuf.Field(number: 99, integer: 1)],
                provider: .gemini,
                endpoint: "Gemini Native",
                store: reloaded
            ).isEmpty
        )

        var secondWave = driftedPayload
        secondWave["secondNewField"] = true
        let secondKeyWarnings = ResponseSchemaWatch.confirmedJSONKeys(
            in: secondWave,
            provider: .cursor,
            endpoint: "X Subscription",
            store: reloaded
        )
        XCTAssertEqual(secondKeyWarnings.first?.patch, .addJSONKeys(endpoint: "X Subscription", keys: ["secondNewField"]))

        let differentSunset = ResponseSchemaWatch.httpHeaders(
            HTTPResponse(statusCode: 200, headers: ["Sunset": "Wed, 01 Dec 2027 00:00:00 GMT"], body: Data()),
            provider: .cursor,
            endpoint: "X Subscription",
            store: reloaded
        )
        XCTAssertEqual(differentSunset.count, 1)
    }

    func testAllRemainingProvidersLiveShapedPayloadsHaveZeroWarnings() throws {
        // 1. Claude (with all live experiment/cedar_ember/breakdown/scoped-share keys)
        let claude = try ClaudeUsageMapper.map(
            response: httpResponse(json: """
            {
              "five_hour": {"utilization": 0, "resets_at": null, "limit_dollars": null, "remaining_dollars": null, "used_dollars": null, "locked_reason": null},
              "seven_day": {"utilization": 3, "resets_at": "2027-01-17T03:00:00Z"},
              "seven_day_breakdown": {
                "as_of": "2027-01-15T07:59:00Z",
                "window_started_at": "2027-01-10T03:00:00Z",
                "rows": [
                  {"key": "claude_code", "display_name": "Claude Code", "percent": 40, "percent_of_limit": 1},
                  {"key": "cowork", "display_name": "Cowork", "percent": 60, "percent_of_limit": 2}
                ]
              },
              "limits": [{"group": "weekly", "is_active": true, "kind": "weekly_all", "percent": 3, "resets_at": "2027-01-17T03:00:00Z", "scope": null, "severity": "normal"}],
              "extra_usage": {"is_enabled": false, "credits_ever_enabled": true, "daily": null, "weekly": null, "spend_limit_reached": false, "user_disabled": true},
              "spend": {"enabled": false, "percent": 0, "severity": "normal", "used": {"amount_minor": 0, "currency": "USD", "exponent": 2}},
              "cedar_ember": {
                "eligible": true,
                "at_limit": false,
                "paused_held": false,
                "grants": [{"id": "g1", "resets_left": 1, "resets_total": 1, "ends_at": "2027-03-09T07:59:00Z", "usable_now": true, "type": "full"}]
              },
              "amber_cistern": null,
              "wattle_ember": null,
              "weekly_scoped_shares": [{"allowance_percent_of_weekly": 50, "limit_index": 2}]
            }
            """),
            credentials: ClaudeOAuth(subscriptionType: "max", rateLimitTier: "default_claude_max_5x"),
            now: now
        )
        XCTAssertTrue(claude.allDiagnosticWarnings.isEmpty, "Claude warnings: \(claude.allDiagnosticWarnings)")

        // 2. Codex (with spend_control, rate_limit_reached_type, overage_limit_reached, reset-credits)
        let resetList = CodexResetCreditList.parse(Data("""
        {
          "available_count": 1,
          "history_enabled": true,
          "immediate_reset_purchase_eligible": false,
          "total_earned_count": 0,
          "credits": [
            {"id": "c1", "status": "available", "expires_at": "2026-12-01T20:00:00Z", "title": "Full reset", "reset_type": "codex_rate_limits"}
          ]
        }
        """.utf8))
        let codex = try CodexUsageMapper.map(
            response: httpResponse(json: """
            {
              "plan_type": "plus",
              "rate_limit_reached_type": null,
              "spend_control": {"individual_limit": null, "reached": false},
              "model_usage": {"gpt-6": {"available": true}},
              "rate_limit": {"allowed": true, "limit_reached": false, "primary_window": {"used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000, "reset_at": 1800018000}},
              "credits": {"has_credits": false, "unlimited": false, "overage_limit_reached": false, "balance": "0"},
              "rate_limit_reset_credits": {"available_count": 1, "applicable_available_count": 0}
            }
            """),
            resetCreditList: resetList,
            now: now
        )
        XCTAssertTrue(codex.allDiagnosticWarnings.isEmpty, "Codex warnings: \(codex.allDiagnosticWarnings)")

        // 3. Cursor & X Subscription
        let cursorLegacy = try CursorUsageMapper.map(
            usageResponse: httpResponse(json: """
            {
              "enabled": true,
              "autoBucketModels": ["default"],
              "displayMessage": "Limit",
              "displayThreshold": 200,
              "planUsage": {"autoPercentUsed": 50, "totalPercentUsed": 50, "bonusTooltip": "tip", "remainingBonus": false},
              "spendLimitUsage": {"individualLimit": 5000, "individualRemaining": 5000, "limitType": "user"}
            }
            """),
            planResponse: httpResponse(json: #"{"isMerged":true,"planInfo":{"planName":"Plus"},"nextUpgrade":{"tier":"premium"}}"#),
            now: now
        )
        XCTAssertTrue(cursorLegacy.allDiagnosticWarnings.isEmpty, "Cursor warnings: \(cursorLegacy.allDiagnosticWarnings)")

        let xSub = try CursorUnifiedUsageMapper.map(
            legacy: cursorLegacy,
            dashboard: httpResponse(json: """
            {
              "availability": "available",
              "weeklyIncludedStatus": {"status": "metered"},
              "weeklyIncludedUsage": {"usedCents": 100, "budgetCents": 1000, "resetCounter": 1, "periodStart": "2027-01-10T00:00:00Z", "resetsAt": "2027-01-20T00:00:00Z"},
              "weeklyIncludedUsageByProduct": [{"product": "grok-chat", "cents": 100}],
              "monthlyUsage": {"usedCents": 0, "limitCents": 5000, "creditsUsedCents": 0, "additionalUsageOff": false, "periodStart": "2027-01-01T00:00:00Z", "resetsAt": "2027-02-01T00:00:00Z"}
            }
            """),
            shared: httpResponse(json: """
            {
              "isUnified": true,
              "billingBrand": "SAND_BILLING_BRAND_GROK",
              "cursorPlanName": "Plus",
              "grokPlanLabel": "Grok Bot Plan",
              "prepaidAvailableCents": "2388",
              "wouldRefuseSend": false
            }
            """),
            isMerged: true,
            now: now
        )
        XCTAssertTrue(xSub.allDiagnosticWarnings.isEmpty, "X Sub warnings: \(xSub.allDiagnosticWarnings)")

        // 4. GitHub Copilot
        let copilot = try CopilotUsageMapper.map(
            response: httpResponse(json: """
            {
              "copilot_plan": "individual",
              "access_type_sku": "free_limited_copilot",
              "quota_reset_date": "2026-12-01",
              "endpoints": {"api": "https://api.individual.githubcopilot.com"},
              "quota_snapshots": {
                "chat": {"entitlement": 200, "remaining": 200, "percent_remaining": 100, "has_quota": true, "unlimited": false, "credits_used": 0, "timestamp_utc": "2026-11-20T00:00:00Z"}
              }
            }
            """),
            now: now
        )
        XCTAssertTrue(copilot.allDiagnosticWarnings.isEmpty, "Copilot warnings: \(copilot.allDiagnosticWarnings)")

        // 5. Muse
        let muse = try MuseProvider.map(
            httpResponse(json: """
            1:{"success":true,"subscription":{"subscriptionType":"FREE","statusSubtitle":"Weekly","topupEligible":false,"topupTotal":0,"topupBalance":0,"tier":{"isPaid":false,"name":"Muse Free","rank":0,"tierCode":"HATCH_FREE","tierId":"hatch_free"},"usage":{"percentUsed":1,"quotaStatus":"SUFFICIENT","resetsAt":1795367427,"state":"METERED"}}}
            """),
            historyID: "muse-test",
            now: now
        )
        XCTAssertTrue(muse.allDiagnosticWarnings.isEmpty, "Muse warnings: \(muse.allDiagnosticWarnings)")

        // 6. Adobe
        let adobe = try AdobeProvider.map(
            data: Data(#"{"credits":{"firefly_plan_credit":{"quota":{"available":4000,"total":4000,"used":0}}},"total":{"availableUntil":"2026-12-04T05:12:58.886Z","planCap":"HARD","quota":{"available":4000,"total":4000,"used":0}}}"#.utf8),
            accessToken: "a.e30.b",
            credentialSource: "Edge Default",
            now: now
        )
        XCTAssertTrue(adobe.allDiagnosticWarnings.isEmpty, "Adobe warnings: \(adobe.allDiagnosticWarnings)")

        // 7. Manus
        let manus = try ConsumerQuotaProvider.manus(
            httpResponse(json: #"{"freeCredits":1000,"maxRefreshCredits":300,"nextRefreshTime":"2026-11-20T15:00:00Z","refreshCredits":300,"refreshInterval":"daily","totalCredits":1300,"userFlag":{"drc16":false}}"#)
        )
        XCTAssertTrue(manus.allDiagnosticWarnings.isEmpty, "Manus warnings: \(manus.allDiagnosticWarnings)")

        // 8. Kimi
        let kimi = try ConsumerQuotaProvider.kimi(
            subscription: httpResponse(json: #"{"balances":[{"amountUsedRatio":0,"domain":"DOMAIN_NEXUS","expireTime":"2026-12-13T00:00:00Z","feature":"FEATURE_OMNI"}],"cancelRetentionGroup":"CONTROL","capabilities":[],"subscription":{"goods":{"title":"Free"}}}"#),
            stats: httpResponse(json: #"{"subscriptionBalance":{"amountUsedRatio":0,"feature":"FEATURE_OMNI","unit":"UNIT_CREDIT"}}"#),
            code: httpResponse(json: #"{"totalQuota":{"limit":"100","remaining":"100"}}"#)
        )
        XCTAssertTrue(kimi.allDiagnosticWarnings.isEmpty, "Kimi warnings: \(kimi.allDiagnosticWarnings)")

        // 9. Qoder
        let qoder = try QoderProvider.map(
            usage: httpResponse(json: """
            {
              "displayMode": "qoder",
              "qoderUsage": {
                "userId": "u1",
                "userType": "personal_professional_trial",
                "usageType": "credits",
                "isPlanQuotaProrated": false,
                "isQuotaExceeded": false,
                "upgradeUrl": "https://qoder.com/pricing",
                "refreshAt": 1795750354290,
                "userQuota": {"total": 300, "used": 0, "remaining": 300, "percentage": 0, "unit": "credits"},
                "addOnQuota": {"total": 100, "used": 0, "remaining": 100, "percentage": 0, "unit": "credits", "detailUrl": "https://qoder.com"}
              }
            }
            """),
            plan: httpResponse(json: #"{"plan_tier_name":"Pro Trial","user_type":"personal_professional_trial","is_highest_tier":false,"feature_allowed":{"quest":true}}"#),
            historyID: "qoder-test",
            now: now
        )
        XCTAssertTrue(qoder.allDiagnosticWarnings.isEmpty, "Qoder warnings: \(qoder.allDiagnosticWarnings)")
    }

    func testAddedFieldValueFormattingHandlesTypesAndRedactsSecrets() throws {
        let jsonData = Data(#"""
        {
          "credits_can_pay": false,
          "enabled_flag": true,
          "count_int": 42,
          "ratio_float": 12.5,
          "nullable_field": null,
          "short_text": "hello",
          "small_array": [1, "two"],
          "large_array": [1, 2, 3, 4],
          "small_object": {"a": 1, "b": false},
          "large_object": {"k1": 1, "k2": 2, "k3": 3, "k4": 4},
          "api_key": "plaintext-key-value",
          "access_token": "tok_value",
          "user_email": "someone@example.com",
          "contact_hint": "person@domain.org",
          "jwt_like": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signaturepart",
          "callback_url": "https://example.com/path?token=secret123"
        }
        """#.utf8)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let warnings = ResponseSchemaWatch.jsonKeys(in: parsed, endpoint: "Test endpoint", known: [])
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warning.summary, "New fields in Test endpoint")
        XCTAssertFalse(warning.summary.contains("credits_can_pay"))

        let lines = warning.detail.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("credits_can_pay: false"))
        XCTAssertTrue(lines.contains("enabled_flag: true"))
        XCTAssertTrue(lines.contains("count_int: 42"))
        XCTAssertTrue(lines.contains("ratio_float: 12.5"))
        XCTAssertTrue(lines.contains("nullable_field: null"))
        XCTAssertTrue(lines.contains("short_text: \"hello\""))
        XCTAssertTrue(lines.contains("small_array: [1, \"two\"]"))
        XCTAssertTrue(lines.contains("large_array: [4 items]"))
        XCTAssertTrue(lines.contains("small_object: {a: 1, b: false}"))
        XCTAssertTrue(lines.contains("large_object: {k1, k2, k3, …}"))
        XCTAssertTrue(lines.contains("api_key: <redacted>"))
        XCTAssertTrue(lines.contains("access_token: <redacted>"))
        XCTAssertTrue(lines.contains("user_email: <redacted>"))
        XCTAssertTrue(lines.contains("contact_hint: <redacted>"))
        XCTAssertTrue(lines.contains("jwt_like: <redacted>"))
        XCTAssertTrue(lines.contains("callback_url: \"https://example.com/path?…\""))

        let pbFields: [GeminiProtobuf.Field] = [
            GeminiProtobuf.Field(number: 7, integer: 42),
            GeminiProtobuf.Field(number: 8, floating: 3.5),
            GeminiProtobuf.Field(number: 9, bytes: Data("ok".utf8)),
            GeminiProtobuf.Field(number: 10, bytes: pbVarint(1, 5) + pbVarint(2, 9))
        ]
        let pbWarnings = ResponseSchemaWatch.protobufFields(pbFields, endpoint: "Test PB", known: [])
        let pbDetail = try XCTUnwrap(pbWarnings.first?.detail)
        XCTAssertTrue(pbDetail.contains("#7: 42"))
        XCTAssertTrue(pbDetail.contains("#8: 3.5"))
        XCTAssertTrue(pbDetail.contains("#9: \"ok\""))
        XCTAssertTrue(pbDetail.contains("#10: msg (4 B, tags: #1, #2)"))
    }

    // MARK: - Protobuf test helpers

    private func pbTag(_ number: Int, wireType: Int) -> Data {
        pbRawVarint(UInt64((number << 3) | wireType))
    }

    private func pbVarint(_ number: Int, _ value: UInt64) -> Data {
        pbTag(number, wireType: 0) + pbRawVarint(value)
    }

    private func pbFloat(_ number: Int, _ value: Float) -> Data {
        var le = value.bitPattern.littleEndian
        return pbTag(number, wireType: 5) + Data(bytes: &le, count: 4)
    }

    private func pbMsg(_ number: Int, _ payload: Data) -> Data {
        pbTag(number, wireType: 2) + pbRawVarint(UInt64(payload.count)) + payload
    }

    private func pbStr(_ number: Int, _ text: String) -> Data {
        pbMsg(number, Data(text.utf8))
    }

    private func pbRawVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while true {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
            if v == 0 { break }
        }
        return out
    }
}
