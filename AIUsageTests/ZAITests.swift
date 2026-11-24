import CryptoKit
import XCTest
@testable import AIUsage

final class ZAITests: XCTestCase {
    private let auth = ZAICredential(token: "fake-token", zcodeToken: nil, email: "test@example.invalid", source: "ZCode desktop")
    private func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
    }
    func testFreeAccountKeepsValidSnapshotWithoutNumericQuota() throws {
        let snapshot = try ZAIProvider.map(subscription: response(#"{"code":200,"success":true,"data":[]}"#), quota: response(#"{"code":500,"success":false}"#), start: nil, auth: auth)
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertTrue(snapshot.windows[0].isInactive)
        XCTAssertEqual(snapshot.windows[0].inactiveDetail, "No plan")
        XCTAssertEqual(snapshot.identityEmail, "test@example.invalid")
        XCTAssertNotNil(snapshot.historyIdentity)
        XCTAssertTrue(snapshot.usageDetails.isEmpty)
    }
    func testMaskedCustomerEmailAndOrganizationMetadataDoNotReplaceIdentityOrWarn() throws {
        let account = response(#"{"code":200,"data":{"email":"te****st@example.invalid","organizations":[{"organizationId":"fake-org","organizationName":"Personal","isDefault":1,"role":"owner","projects":[]}]}}"#)
        let subscription = response(#"{"code":200,"data":[]}"#)
        let snapshot = try ZAIProvider.map(subscription: subscription, quota: nil, start: nil, auth: auth, account: account)
        XCTAssertEqual(snapshot.identityEmail, "test@example.invalid")
        XCTAssertFalse(snapshot.usageDetails.contains { $0.id.contains("organizations") })
        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
        let masked = ZAICredential(token: "fake", zcodeToken: nil, email: "te****st@example.invalid", source: "Edge Default")
        let maskedSnapshot = try ZAIProvider.map(subscription: subscription, quota: nil, start: nil, auth: masked, account: account)
        XCTAssertNil(maskedSnapshot.identityEmail)
        XCTAssertNil(ZAIAuthStore.email(#"{"email":"te****st@example.invalid"}"#))
    }
    func testMapsAllQuotaWindowsZeroAndModelDetails() throws {
        let snapshot = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[{"productId":"coding-pro","productName":"Pro Coding","status":"VALID","inCurrentPeriod":true}]}"#), quota: response(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":100,"currentValue":100,"percentage":100},{"type":"TOKENS_LIMIT","unit":6,"number":1,"usage":600,"currentValue":0,"percentage":0},{"type":"NEW_POOL","remaining":0,"usageDetails":[{"modelCode":"model-a","usage":0}]}]}}"#), start: nil, auth: auth)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].remainingCount, 0)
        XCTAssertEqual(snapshot.windows[1].remainingCount, 600)
        XCTAssertTrue(snapshot.usageDetails.contains { $0.value == "0 left" })
        XCTAssertTrue(snapshot.usageDetails.contains { $0.value == "0 used" })
    }
    func testOptionalFailureDoesNotClaimNoPlanForPaidAccount() throws {
        let snapshot = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[{"productId":"coding","productName":"Pro","status":"VALID","inCurrentPeriod":true}]}"#), quota: nil, start: nil, auth: auth)
        XCTAssertEqual(snapshot.windows[0].inactiveDetail, "Unavailable")
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertTrue(snapshot.usageDetails.contains { $0.id == "compatibility.zai.quota" })
    }
    func testAuthenticationIsNotNoPlanAndErrorsAreRedacted() throws {
        XCTAssertThrowsError(try ZAIProvider.envelope(response(#"{"code":401,"msg":"fake-secret@example.invalid"}"#))) { error in
            let failure = error as? ProviderFailure
            XCTAssertEqual(failure?.kind, .authentication)
            XCTAssertFalse(failure?.message.contains("fake-secret") ?? true)
        }
        XCTAssertThrowsError(try ZAIProvider.map(subscription: response(#"{"code":200,"data":null}"#), quota: nil, start: nil, auth: auth))
    }
    func testNativeEnvelopeAuthenticatesKeyAndRejectsTampering() throws {
        let key = Data(repeating: 7, count: 32)
        let nonce = try AES.GCM.Nonce(data: Data(repeating: 3, count: 12))
        let box = try AES.GCM.seal(Data("fake-access-token".utf8), using: SymmetricKey(data: key), nonce: nonce)
        func b64(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let id = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined().prefix(24)
        let text = "enc:v2:os:\(id):\(b64(Data(nonce))).\(b64(box.tag)).\(b64(box.ciphertext))"
        XCTAssertEqual(try ZAIAuthStore.decrypt(text, key: key), "fake-access-token")
        XCTAssertThrowsError(try ZAIAuthStore.decrypt(text, key: Data(repeating: 8, count: 32)))
        XCTAssertThrowsError(try ZAIAuthStore.decrypt(text.replacingOccurrences(of: "enc:v2:os", with: "enc:v2:file"), key: key))
    }
    func testSourceRoutingAndIdentityDoNotFallback() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = ZAIAuthStore(home: temporary.path, key: { _ in XCTFail("No Keychain read without native source"); return nil })
        XCTAssertThrowsError(try store.load(.cli))
        XCTAssertThrowsError(try store.load(.desktop))
        let other = ZAICredential(token: auth.token, zcodeToken: nil, email: nil, source: "Edge Default")
        let native = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[]}"#), quota: nil, start: nil, auth: ZAICredential(token: auth.token, zcodeToken: nil, email: nil, source: auth.source))
        let browser = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[]}"#), quota: nil, start: nil, auth: other)
        XCTAssertNotEqual(native.historyIdentity, browser.historyIdentity)
    }
    func testDailyStartModelQuotasRemainSeparateAndStableAcrossBucketRenewal() throws {
        func balance(bucket: String) -> HTTPResponse {
            response("""
            {"code":0,"data":{"plans":[{"plan_id":"start","name":"ZCode Start Plan","status":"active","entitlements":[{"entitlement_id":"model-a","period":"daily","grant_units":3000000,"unit_type":"token"},{"entitlement_id":"model-b","period":"daily","grant_units":5000000,"unit_type":"token"}]}],"balances":[{"plan_id":"start","bucket_id":"\(bucket)","entitlement_id":"model-a","show_name":"Model A","remaining_units":3000000,"total_units":3000000,"available_units":3000000,"unit_type":"token","period_end":1800000000},{"plan_id":"start","bucket_id":"second-\(bucket)","entitlement_id":"model-b","show_name":"Model B","remaining_units":0,"total_units":5000000,"available_units":0,"unit_type":"token","period_end":1800000000}]}}
            """)
        }
        let credential = ZAICredential(token: "fake-api", zcodeToken: "fake-native", email: nil, source: "ZCode desktop")
        let subscription = response(#"{"code":200,"data":[]}"#)
        let first = try ZAIProvider.map(subscription: subscription, quota: nil, start: balance(bucket: "old"), auth: credential)
        let next = try ZAIProvider.map(subscription: subscription, quota: nil, start: balance(bucket: "new"), auth: credential)
        XCTAssertEqual(first.windows.count, 2)
        XCTAssertEqual(first.windows[0].remainingCount, 3000000)
        XCTAssertEqual(first.windows[0].countText(for: .remaining), "3M / 3M")
        XCTAssertEqual(first.windows[1].remainingCount, 0)
        XCTAssertEqual(first.windows[1].countText(for: .remaining), "0 / 5M")
        XCTAssertEqual(first.windows[1].countText(for: .used), "5M / 5M")
        XCTAssertEqual(first.windows[1].usedPercent, 100)
        XCTAssertEqual(first.windows[0].resetsAt?.timeIntervalSince1970, 1800000001)
        XCTAssertEqual(first.windows.map(\.kind), next.windows.map(\.kind))
        XCTAssertEqual(first.planName, "ZCode Start Plan")
        XCTAssertFalse(first.windows.contains { $0.isInactive })
        XCTAssertEqual(first.availableMenuBarItems.count, 2)
        XCTAssertTrue(first.allDiagnosticWarnings.isEmpty)
    }
    func testApiBalanceUsesSingleConciseRowAndEmailStabilizesAccountLabel() throws {
        let account = response(#"{"code":200,"data":{"email":"person@example.invalid","balance":12.5,"availableBalance":10}}"#)
        let first = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[]}"#), quota: nil, start: nil,
            auth: ZAICredential(token: "token-one", zcodeToken: nil, email: nil, source: "ZCode desktop"), account: account)
        let second = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[]}"#), quota: nil, start: nil,
            auth: ZAICredential(token: "token-two", zcodeToken: nil, email: nil, source: "ZCode desktop"), account: account)
        XCTAssertEqual(first.accountLabel, second.accountLabel)
        XCTAssertEqual(first.usageDetails.count, 2)
        XCTAssertEqual(first.usageDetails[0].title, "API balance")
        XCTAssertEqual(first.usageDetails[0].value, "12.5 (unit unconfirmed)")
        XCTAssertEqual(first.usageDetails[1].title, "API available balance")
        XCTAssertEqual(first.usageDetails[1].value, "10 (unit unconfirmed)")
    }
    func testQuotaEndpointPropagatesAuthAndRateLimitErrors() async {
        for (status, expectedKind) in [(401, ProviderFailureKind.authentication), (429, .rateLimited)] {
            let http = MockHTTPClient([
                response(#"{"code":200,"data":[]}"#),
                response(#"{"code":200,"data":{}}"#),
                response(#"{"code":\#(status)}"#, status: status)
            ])
            let provider = ZAIProvider(http: http, method: { .edge }, credential: { _ in
                ZAICredential(token: "fake-browser", zcodeToken: nil, email: nil, source: "Edge Default")
            })
            do {
                _ = try await provider.fetch()
                XCTFail("Expected \(expectedKind)")
            } catch {
                XCTAssertEqual((error as? ProviderFailure)?.kind, expectedKind)
            }
        }
    }
    func testNativeHeadersNeverReachApiHostAndBrowserDoesNotReadNativePool() async throws {
        let http = MockHTTPClient([
            response(#"{"code":200,"data":[]}"#), response(#"{"code":200,"data":{}}"#),
            response(#"{"code":500,"success":false}"#), response(#"{"code":0,"data":{"plans":[],"balances":[]}}"#)
        ])
        let provider = ZAIProvider(http: http, method: { .desktop }, credential: { method in
            XCTAssertEqual(method, .desktop)
            return ZAICredential(token: "fake-api", zcodeToken: "fake-native", email: nil, source: "ZCode desktop", startHeaders: ["X-Device-Mid": "fake-device", "X-ZCode-App-Version": "3.18.2"])
        })
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.filter { $0.url.host == "api.z.ai" }.allSatisfy { $0.headers["X-Device-Mid"] == nil && $0.headers["Authorization"] == "Bearer fake-api" })
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer fake-native")
        XCTAssertEqual(requests.last?.headers["X-Device-Mid"], "fake-device")
        let browserHTTP = MockHTTPClient([response(#"{"code":200,"data":[]}"#), response(#"{"code":200,"data":{}}"#), response(#"{"code":500,"success":false}"#)])
        let browser = ZAIProvider(http: browserHTTP, method: { .edge }, credential: { method in
            XCTAssertEqual(method, .edge)
            return ZAICredential(token: "fake-browser", zcodeToken: nil, email: nil, source: "Edge Default")
        })
        _ = try await browser.fetch()
        let browserRequests = await browserHTTP.capturedRequests()
        XCTAssertTrue(browserRequests.allSatisfy { $0.url.host == "api.z.ai" })
    }

    func testCompactCountFormattingThresholds() {
        XCTAssertEqual(QuotaWindow.formatCount(0), "0")
        XCTAssertEqual(QuotaWindow.formatCount(4_000), "4,000")
        XCTAssertEqual(QuotaWindow.formatCount(99_999), "99,999")
        XCTAssertEqual(QuotaWindow.formatCount(100_000), "100K")
        XCTAssertEqual(QuotaWindow.formatCount(125_500), "125.5K")
        XCTAssertEqual(QuotaWindow.formatCount(125_450), "125.45K")
        XCTAssertEqual(QuotaWindow.formatCount(999_999), "1M")
        XCTAssertEqual(QuotaWindow.formatCount(1_000_000), "1M")
        XCTAssertEqual(QuotaWindow.formatCount(1_250_000), "1.25M")
        XCTAssertEqual(QuotaWindow.formatCount(2_500_000), "2.5M")
        XCTAssertEqual(QuotaWindow.formatCount(3_000_000), "3M")
        XCTAssertEqual(QuotaWindow.formatCount(5_000_000), "5M")
        XCTAssertEqual(QuotaWindow.formatCount(999_999_000), "1B")
        XCTAssertEqual(QuotaWindow.formatCount(1_500_000_000), "1.5B")
        let window = QuotaWindow(
            kind: .additional(id: "fake.tokens", title: "Tokens"),
            usedPercent: 50,
            resetsAt: nil,
            remainingCount: 1_250_000,
            limitCount: 2_500_000
        )
        XCTAssertEqual(window.countText(for: .remaining), "1.25M / 2.5M")
        XCTAssertEqual(window.countText(for: .used), "1.25M / 2.5M")
    }

    func testExpiryRenewAndEffectiveDetailsSetTargetDateForCountdown() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let renew = Int(now.addingTimeInterval(2 * 86_400 + 6 * 3_600).timeIntervalSince1970)
        let startEnd = Int(now.addingTimeInterval(3 * 86_400).timeIntervalSince1970)
        let effective = Int(now.addingTimeInterval(2 * 3_600 + 30 * 60).timeIntervalSince1970)
        let bucketExpiry = Int(now.addingTimeInterval(5 * 86_400 + 1 * 3_600).timeIntervalSince1970)
        let subscription = response(#"{"code":200,"data":[{"productId":"coding","productName":"Coding Pro","status":"VALID","inCurrentPeriod":true,"autoRenew":true,"nextRenewTime":\#(renew)}]}"#)
        let start = response(#"{"code":0,"data":{"plans":[{"plan_id":"start","name":"ZCode Start Plan","status":"active","ends_at":\#(startEnd),"entitlements":[{"entitlement_id":"model-a","show_name":"Future Pool","effective_at":\#(effective),"period":"once"}]}],"balances":[{"plan_id":"start","bucket_id":"b1","entitlement_id":"model-a","show_name":"One-off","remaining_units":100,"total_units":100,"unit_type":"token","expires_at":\#(bucketExpiry)}]}}"#)
        let credential = ZAICredential(token: "fake-token", zcodeToken: "fake-native", email: "test@example.invalid", source: "ZCode desktop")
        let snapshot = try ZAIProvider.map(subscription: subscription, quota: nil, start: start, auth: credential, now: now)

        let codingRenew = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "Coding Pro renews" })
        let startExpiry = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "ZCode Start Plan expires" })
        let futureAvail = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "Future Pool available" })
        let oneOffExpiry = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "One-off expires" })

        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(codingRenew.targetDate), from: now, fallback: codingRenew.value), "in 2d 6h")
        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(startExpiry.targetDate), from: now, fallback: startExpiry.value), "in 3d")
        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(futureAvail.targetDate), from: now, fallback: futureAvail.value), "in 2h 30m")
        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(oneOffExpiry.targetDate), from: now, fallback: oneOffExpiry.value), "in 5d 1h")
    }

    func testCodingPlanMapsResetCardsAndMcpUsageFallbackWithoutDuplicatingTimeLimit() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let exp1 = Int(now.addingTimeInterval(3_600).timeIntervalSince1970)
        let exp2 = Int(now.addingTimeInterval(86_400).timeIntervalSince1970)
        let expired = Int(now.addingTimeInterval(-60).timeIntervalSince1970)
        let mcpRefresh = Int(now.addingTimeInterval(7_200).timeIntervalSince1970)
        let subscription = response(#"{"code":200,"data":[{"productId":"coding-pro","productName":"Pro Coding","status":"VALID","inCurrentPeriod":true}]}"#)
        let quotaNoTime = response(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":100,"currentValue":25,"percentage":25}]}}"#)
        let resetStatus = response(#"{"code":0,"data":{"available_five_hour_resets":[{"expire_at":\#(exp1)},{"expire_at":\#(expired)}],"available_week_resets":[{"expire_at":\#(exp2)}],"latest_five_hour_reset_history":null,"latest_week_reset_history":null,"has_unread_history":false}}"#)
        let mcpUsage = response(#"{"code":0,"data":{"server_time":1800000000,"next_refresh_at":\#(mcpRefresh),"level":"pro","total_usage":{"used":12,"limit":100,"remaining":88}}}"#)

        let emptyStart = response(#"{"code":0,"data":{"plans":[],"balances":[]}}"#)

        let mapped = try ZAIProvider.map(
            subscription: subscription,
            quota: quotaNoTime,
            start: emptyStart,
            auth: ZAICredential(token: "fake-api", zcodeToken: "fake-native", email: nil, source: "ZCode desktop"),
            resetStatus: resetStatus,
            mcpUsage: mcpUsage,
            now: now
        )
        XCTAssertTrue(mapped.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(mapped.resets?.availableCount, 2)
        XCTAssertEqual(mapped.resets?.expirations.map(\.timeIntervalSince1970), [Double(exp1), Double(exp2)])
        let toolsWindow = try XCTUnwrap(mapped.windows.first { $0.kind == .additional(id: "zai.tools", title: "Tools") })
        XCTAssertEqual(toolsWindow.remainingCount, 88)
        XCTAssertEqual(toolsWindow.limitCount, 100)
        XCTAssertEqual(toolsWindow.usedPercent, 12, accuracy: 0.01)
        XCTAssertEqual(toolsWindow.resetsAt?.timeIntervalSince1970, Double(mcpRefresh))

        let quotaWithTime = response(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":100,"currentValue":25,"percentage":25},{"type":"TIME_LIMIT","usage":200,"currentValue":10,"percentage":5}]}}"#)
        let deduped = try ZAIProvider.map(
            subscription: subscription,
            quota: quotaWithTime,
            start: emptyStart,
            auth: ZAICredential(token: "fake-api", zcodeToken: "fake-native", email: nil, source: "ZCode desktop"),
            resetStatus: resetStatus,
            mcpUsage: mcpUsage,
            now: now
        )
        XCTAssertEqual(deduped.windows.filter { $0.kind == .additional(id: "zai.tools", title: "Tools") }.count, 1)
        XCTAssertEqual(deduped.windows.first { $0.kind == .additional(id: "zai.tools", title: "Tools") }?.limitCount, 200)
    }

    func testCodingPlanFetchSendsReadOnlyResetAndMcpRequestsOnlyWhenActiveCodingPlanExists() async throws {
        let http = MockHTTPClient([
            response(#"{"code":200,"data":[{"productId":"coding-pro","productName":"Pro Coding","status":"VALID","inCurrentPeriod":true}]}"#),
            response(#"{"code":200,"data":{}}"#),
            response(#"{"code":200,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"usage":100,"currentValue":20,"percentage":20}]}}"#),
            response(#"{"code":0,"data":{"plans":[],"balances":[]}}"#),
            response(#"{"code":0,"data":{"available_five_hour_resets":[],"available_week_resets":[]}}"#),
            response(#"{"code":403,"msg":"coding plan is required"}"#, status: 403)
        ])
        let provider = ZAIProvider(http: http, method: { .desktop }, credential: { _ in
            ZAICredential(token: "fake-api", zcodeToken: "fake-native", email: nil, source: "ZCode desktop", startHeaders: ["X-Device-Mid": "fake-device", "X-ZCode-App-Version": "3.18.2"])
        })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Pro Coding")
        XCTAssertNil(snapshot.resets)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[4].url.path, "/api/v1/coding-plan/reset/status")
        XCTAssertEqual(requests[4].method, .get)
        XCTAssertEqual(requests[4].headers["X-Bigmodel-Authorization"], "Bearer fake-api")
        XCTAssertEqual(requests[5].url.path, "/api/v1/mcp/usage")
        XCTAssertEqual(requests[5].method, .get)
    }

}
