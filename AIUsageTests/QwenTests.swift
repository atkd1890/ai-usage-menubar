import XCTest
@testable import AIUsage

final class QwenTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_826_823)

    private var agentUsageOK: HTTPResponse {
        httpResponse(json: """
        {
          "httpCode": 200,
          "success": true,
          "data": {
            "status": "PENDING",
            "remainingPercent": 72,
            "resetAt": 1795431623000,
            "memberType": "free"
          }
        }
        """)
    }

    private var creditsOK: HTTPResponse {
        httpResponse(json: """
        {
          "httpCode": 200,
          "success": true,
          "data": {
            "creditsRemain": true,
            "entitlements": [
              {"entitlementCode": "model_shared_usage", "balance": 150, "total": 200, "expireAt": 1794913223000},
              {"entitlementCode": "daily_credits", "balance": 20, "total": 40, "expireAt": 1794913223000},
              {"entitlementCode": "image_generation", "balance": 8, "total": 10, "expireAt": 1794913223000},
              {"entitlementCode": "task_assistant", "balance": 3000, "total": 6000, "expireAt": 1795431623000}
            ]
          }
        }
        """)
    }

    private var resetCardsOK: HTTPResponse {
        httpResponse(json: """
        {
          "httpCode": 200,
          "success": true,
          "data": {
            "coupons": [
              {"grantId": "c1", "resetPeriod": "7D", "gmtExpire": 1795000000000},
              {"grantId": "c2", "resetPeriod": "7D", "gmtExpire": 1794700000000}
            ]
          }
        }
        """)
    }

    func testMappingExtractsWeeklyAgentCreditsResetsAndPlanTiers() throws {
        let snapshot = try QwenProvider.map(
            agentUsage: agentUsageOK,
            credits: creditsOK,
            resetCards: resetCardsOK,
            memberLevel: httpResponse(json: #"{"success":true,"data":{"memberType":"plus","memberName":"Plus"}}"#),
            email: "user@example.com",
            sourceLabel: "Qwen desktop",
            historyID: "qwen-session:abc",
            now: now
        )

        XCTAssertEqual(snapshot.provider, .qwen)
        XCTAssertEqual(snapshot.planName, "Plus")
        XCTAssertEqual(snapshot.identityEmail, "user@example.com")
        XCTAssertEqual(snapshot.credentialSource, "Qwen desktop")
        XCTAssertEqual(snapshot.dashboardSubtitle, "Shared account limits • Chat, Agent & Qwen Code")
        XCTAssertEqual(snapshot.windows.map(\.kind), [
            .daily,
            .weekly,
            .additional(id: "qwen.daily_credits", title: "Video Credits"),
            .additional(id: "qwen.image_generation", title: "Image Generation")
        ])
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[0].remainingCount, 150)
        XCTAssertEqual(snapshot.windows[0].limitCount, 200)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_794_913_223))
        XCTAssertEqual(snapshot.windows[1].usedPercent, 28, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].remainingCount, 3000)
        XCTAssertEqual(snapshot.windows[1].limitCount, 6000)
        XCTAssertEqual(snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_795_431_623))

        let videoCredits = snapshot.windows[2]
        XCTAssertEqual(videoCredits.kind.title, "Video Credits")
        XCTAssertEqual(videoCredits.usedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(videoCredits.remainingCount, 20)
        XCTAssertEqual(videoCredits.limitCount, 40)

        let image = snapshot.windows[3]
        XCTAssertEqual(image.kind.title, "Image Generation")
        XCTAssertEqual(image.usedPercent, 20, accuracy: 0.001)
        XCTAssertEqual(image.remainingCount, 8)
        XCTAssertEqual(image.limitCount, 10)

        let rows = ProviderDetailsLayout.rows(snapshot.windows)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first?.map(\.kind), [.daily, .weekly])
        XCTAssertEqual(rows.last?.map(\.kind.title), ["Video Credits", "Image Generation"])
        XCTAssertEqual(
            ProviderDetailsLayout.windows(snapshot, expanded: false).map(\.kind),
            [.daily, .weekly]
        )

        XCTAssertEqual(snapshot.resets?.availableCount, 1)
        XCTAssertEqual(snapshot.resets?.expirations, [Date(timeIntervalSince1970: 1_795_000_000)])

        for (raw, expected) in [("free", "Free"), ("lite", "Lite"), ("go", "Lite"), ("plus", "Plus"), ("pro", "Pro")] {
            let tiered = try QwenProvider.map(
                agentUsage: agentUsageOK,
                memberLevel: httpResponse(json: #"{"success":true,"data":{"memberType":"\#(raw)"}}"#),
                now: now
            )
            XCTAssertEqual(tiered.planName, expected)
        }
    }

    func testRefreshOnExpiredOrBrowserSessionCachesInMemory() async throws {
        let refreshResponse = httpResponse(json: """
        {
          "success": true,
          "data": {
            "access_token": "fresh-access-token",
            "refresh_token": "stable-refresh-token",
            "email": "qwen-user@example.com",
            "expires_at": 1794827823
          }
        }
        """)
        let http = MockHTTPClient([
            refreshResponse,
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            loadCredentials: {
                QwenCredential(access: nil, refresh: "stable-refresh-token", sourceLabel: "Edge Default")
            },
            now: { fixedNow }
        )

        let first = try await provider.fetch()
        let second = try await provider.fetch()

        XCTAssertEqual(first.identityEmail, "qwen-user@example.com")
        XCTAssertEqual(second.identityEmail, "qwen-user@example.com")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 9)
        XCTAssertEqual(requests[0].url.absoluteString, QwenProvider.refreshURL.absoluteString)
        XCTAssertEqual(requests[0].headers["Cookie"], "refresh_token=stable-refresh-token")
        XCTAssertEqual(requests[0].headers["source"], "web")
        XCTAssertEqual(requests[0].headers["x-request-origin"], "https://chat.qwen.ai")

        for request in requests.dropFirst() {
            XCTAssertEqual(request.headers["Authorization"], "Bearer fresh-access-token")
            XCTAssertFalse(request.headers.values.contains(where: { $0.contains("stable-refresh-token") }))
        }
    }

    func testDesktopTokenRejectedAtEndpointRefreshesOnceAndRetries() async throws {
        let unauthorizedJSON = httpResponse(json: #"{"success":false,"data":{"code":"unauthorized","details":"Token has expired"}}"#)
        let refreshOK = httpResponse(json: #"{"success":true,"data":{"access_token":"renewed-token","email":"retry@example.com","expires_at":1794827823}}"#)
        let http = MockHTTPClient([
            unauthorizedJSON,
            refreshOK,
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#)
        ])

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            loadCredentials: {
                QwenCredential(access: "stale-access", refresh: "desktop-refresh", sourceLabel: "Qwen desktop")
            },
            now: { fixedNow }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.identityEmail, "retry@example.com")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer stale-access")
        XCTAssertEqual(requests[1].url, QwenProvider.refreshURL)
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer renewed-token")
    }

    func testMalformedNullAndRejectedResponsesAreRejected() {
        for invalid in ["null", "true", "-1", "101"] {
            XCTAssertThrowsError(try QwenProvider.map(
                agentUsage: httpResponse(json: #"{"success":true,"data":{"remainingPercent":\#(invalid)}}"#),
                now: now
            ))
        }
        for code in [401, 403, 429, 500] {
            XCTAssertThrowsError(try QwenProvider.map(agentUsage: httpResponse(code), now: now))
        }
    }

    func testTokenExtractionFromLocalStorageState() {
        let state = #"{"version":1,"stateId":"abc","token":"jwt.access.token"}"#
        XCTAssertEqual(QwenNativeSession.extractAccessToken(from: ["qwen_access_token_state": state]), "jwt.access.token")
        XCTAssertEqual(QwenNativeSession.extractAccessToken(from: ["token": #""direct.jwt.token""#]), "direct.jwt.token")
        XCTAssertNil(QwenNativeSession.extractAccessToken(from: ["qwen_access_token_state": #"{"token":"bad token"}"#]))
    }

    @MainActor
    func testQwenIsSeededOnceManualDisableRespectedAndLoginMethodsExposed() {
        let suite = "QwenPreferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isTracking(.qwen))
        preferences.setTracking(false, for: .qwen)
        XCTAssertFalse(AppPreferences(defaults: defaults).isTracking(.qwen))
        XCTAssertEqual(ProviderLoginMethod.supported(for: .qwen), [.desktop, .edge, .chrome])
    }

    func testRotatedRefreshTokenPersistsAcrossRelaunchesAndIgnoresStaleDiskCookie() async throws {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var now: Date
            var diskRefresh: String
            init(now: Date, diskRefresh: String) {
                self.now = now
                self.diskRefresh = diskRefresh
            }
        }

        let state = State(now: now, diskRefresh: "r1")
        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-test-1.json")

        let refreshR1ToR2 = httpResponse(json: """
        {
          "success": true,
          "data": {
            "access_token": "access-1",
            "refresh_token": "r2",
            "email": "u@example.com",
            "expires_at": \(Int(now.timeIntervalSince1970) + 400)
          }
        }
        """)
        let http1 = MockHTTPClient([
            refreshR1ToR2,
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let provider1 = QwenProvider(
            http: http1,
            sessionStore: sessionStore,
            loadCredentials: {
                let refresh = state.lock.withLock { state.diskRefresh }
                return QwenCredential(access: nil, refresh: refresh, sourceLabel: "Edge Default")
            },
            now: { state.lock.withLock { state.now } }
        )

        _ = try await provider1.fetch()
        let requests1 = await http1.capturedRequests()
        XCTAssertEqual(requests1[0].url, QwenProvider.refreshURL)
        XCTAssertEqual(requests1[0].headers["Cookie"], "refresh_token=r1")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r2")

        // Simulate app relaunch after access_token expired AND browser cookie rotated to r_browser on disk.
        state.lock.withLock {
            state.now = now.addingTimeInterval(400)
            state.diskRefresh = "r_browser"
        }

        let refreshR2ToR3 = httpResponse(json: """
        {
          "success": true,
          "data": {
            "access_token": "access-2",
            "refresh_token": "r3",
            "email": "u@example.com",
            "expires_at": \(Int(now.timeIntervalSince1970) + 800)
          }
        }
        """)
        let http2 = MockHTTPClient([
            refreshR2ToR3,
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let provider2 = QwenProvider(
            http: http2,
            sessionStore: sessionStore,
            loadCredentials: {
                let refresh = state.lock.withLock { state.diskRefresh }
                return QwenCredential(access: nil, refresh: refresh, sourceLabel: "Edge Default")
            },
            now: { state.lock.withLock { state.now } }
        )

        _ = try await provider2.fetch()
        let requests2 = await http2.capturedRequests()
        XCTAssertEqual(requests2[0].url, QwenProvider.refreshURL)
        XCTAssertEqual(requests2[0].headers["Cookie"], "refresh_token=r2")
        XCTAssertFalse(requests2.contains { $0.headers.values.contains { $0.contains("r_browser") || $0.contains("=r1") } })
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r3")
    }

    func testValidLocalStorageJWTForksIndependentSessionViaAuthorizeCode() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var now: Date
            init(_ now: Date) { self.now = now }
        }

        let clock = Clock(now)
        let header = Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let payload = Data("{\"exp\":\(Int(now.timeIntervalSince1970) + 900),\"type\":\"access_token\"}".utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let validJWT = "\(header).\(payload).sig"

        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-test-2.json")

        let http = MockHTTPClient([
            agentUsageOK,
            creditsOK,
            resetCardsOK,
            httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#),
            httpResponse(json: #"{"success":true,"data":{"email":"fork@example.com"}}"#),
            httpResponse(json: #"{"success":true,"data":{"code":"auth-code-123"}}"#),
            httpResponse(json: #"{"success":true,"data":{"access_token":"forked-access","refresh_token":"forked-refresh-r1","expires_at":1794827823}}"#),
            httpResponse(json: #"{"success":true,"data":{"access_token":"forked-access-2","refresh_token":"forked-refresh-r2","expires_at":1794829000}}"#),
            agentUsageOK,
            creditsOK,
            resetCardsOK,
            httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: {
                QwenCredential(access: validJWT, refresh: "untouched-browser-cookie", sourceLabel: "Edge Default")
            },
            now: { clock.lock.withLock { clock.now } }
        )

        let first = try await provider.fetch()
        XCTAssertEqual(first.identityEmail, "fork@example.com")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.isForked, true)
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "forked-refresh-r1")

        // Advance past forked-access expiry (1794827823 - now = 1000s) and fetch again.
        clock.lock.withLock { clock.now = now.addingTimeInterval(1500) }
        _ = try await provider.fetch()

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 12)
        XCTAssertFalse(requests.contains { $0.headers.values.contains { $0.contains("untouched-browser-cookie") } })
        XCTAssertEqual(requests[5].url, QwenProvider.authorizeCodeURL)
        XCTAssertEqual(requests[5].headers["Authorization"], "Bearer \(validJWT)")
        XCTAssertEqual(requests[6].url.absoluteString, "https://auth.qwen.ai/api/v2/auths/refresh?code=auth-code-123")
        XCTAssertNil(requests[6].headers["Cookie"])
        XCTAssertEqual(requests[7].url, QwenProvider.refreshURL)
        XCTAssertEqual(requests[7].headers["Cookie"], "refresh_token=forked-refresh-r1")
        XCTAssertEqual(requests[8].headers["Authorization"], "Bearer forked-access-2")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "forked-refresh-r2")
    }

    func testRevokedPersistedSessionFallsBackToUpdatedNativeCredential() async throws {
        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-test-3.json")
        let oldSeed = QwenCredential(access: nil, refresh: "old-cookie", sourceLabel: "Edge Default").fingerprintHex
        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: oldSeed,
                accessToken: "expired-access",
                refreshToken: "revoked-refresh-token",
                expiresAt: now.addingTimeInterval(-100),
                email: nil,
                isForked: true
            ),
            for: "Edge Default"
        )

        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: #"{"success":true,"data":{"access_token":"recovered-access","refresh_token":"recovered-refresh-2","email":"recovered@example.com","expires_at":1794827823}}"#),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#)
        ])

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: {
                QwenCredential(access: nil, refresh: "new-native-refresh-token", sourceLabel: "Edge Default")
            },
            now: { fixedNow }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.identityEmail, "recovered@example.com")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[0].headers["Cookie"], "refresh_token=revoked-refresh-token")
        XCTAssertEqual(requests[1].headers["Cookie"], "refresh_token=new-native-refresh-token")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "recovered-refresh-2")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.isForked, false)
    }

    func testMissingEntitlementsRenderInactiveGraySlotsAndStayOutOfMenuBar() throws {
        let snapshot = try QwenProvider.map(
            agentUsage: agentUsageOK,
            credits: nil,
            resetCards: nil,
            memberLevel: httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#),
            now: now
        )
        XCTAssertEqual(snapshot.windows.map(\.kind), [
            .daily,
            .weekly,
            .additional(id: "qwen.daily_credits", title: "Video Credits"),
            .additional(id: "qwen.image_generation", title: "Image Generation")
        ])
        XCTAssertTrue(snapshot.windows[0].isInactive)
        XCTAssertFalse(snapshot.windows[1].isInactive)
        XCTAssertTrue(snapshot.windows[2].isInactive)
        XCTAssertTrue(snapshot.windows[3].isInactive)
        XCTAssertEqual(snapshot.windows[0].inactiveDetail, "Not on plan")
        XCTAssertEqual(snapshot.availableMenuBarItems.map(\.metric), [.weekly])
    }
}
