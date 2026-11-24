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

    @MainActor
    func testFrequencyModelDailyLimitsRenderCleanTitlesAndConditionalReset() throws {
        let futureMs = Int64((now.addingTimeInterval(3_600).timeIntervalSince1970 * 1000).rounded())
        let nowMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let creditsWithFrequency = httpResponse(json: """
        {
          "httpCode": 200,
          "success": true,
          "data": {
            "creditsRemain": true,
            "scopes": [],
            "entitlements": [
              {
                "entitlementCode": "model_shared_usage",
                "balance": 150,
                "total": 200,
                "expireAt": 1794913223000,
                "frequency": [
                  {"frequencyEntitlementCode": "qwen3.8-max", "refreshAt": \(futureMs), "scope": "DAILY", "usedPercent": 25},
                  {"frequencyEntitlementCode": "qwen4.0-max-preview", "refreshAt": \(nowMs), "scope": "DAILY", "usedPercent": 0},
                  {"frequencyEntitlementCode": "qwen4-max", "refreshAt": \(futureMs), "scope": "DAILY", "usedPercent": 10}
                ]
              },
              {"entitlementCode": "daily_credits", "balance": 20, "total": 40, "expireAt": 1794913223000, "frequency": []},
              {"entitlementCode": "image_generation", "balance": 8, "total": 10, "expireAt": 1794913223000, "frequency": []},
              {"entitlementCode": "task_assistant", "balance": 3000, "total": 6000, "expireAt": 1795431623000, "frequency": []}
            ]
          }
        }
        """)

        let snapshot = try QwenProvider.map(
            agentUsage: agentUsageOK,
            credits: creditsWithFrequency,
            resetCards: resetCardsOK,
            memberLevel: httpResponse(json: #"{"success":true,"data":{"memberType":"free","memberName":"Free"}}"#),
            now: now
        )

        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(snapshot).map(\.kind), [.daily, .weekly])
        let freqWindows = snapshot.windows.filter { $0.kind.rawValue.hasPrefix("additional:qwen.freq.") }
        XCTAssertEqual(freqWindows.map(\.kind.title), ["Qwen 4", "Qwen 4 Preview"])
        XCTAssertEqual(freqWindows.map(\.usedPercent), [10, 0])
        XCTAssertNotNil(freqWindows[0].resetsAt)
        XCTAssertNil(freqWindows[1].resetsAt)
        let detailRows = ProviderDetailsLayout.rows(ProviderDetailsLayout.detailWindows(snapshot))
        XCTAssertEqual(
            detailRows.map { $0.map(\.kind.title) },
            [
                ["Video Credits", "Image Generation"],
                ["Qwen 4", "Qwen 4 Preview"]
            ]
        )
        XCTAssertEqual(QwenProvider.frequencyModelTitle("qwen-max"), "Qwen Max")
        XCTAssertEqual(QwenProvider.frequencyModelTitle("qwen3.5-plus"), "Qwen 3.5 Plus")
    }

    func testConcurrentFetchesShareSingleRefreshAndDoNotReplayRefreshToken() async throws {
        actor GatedHTTPClient: HTTPClient {
            private var requests: [HTTPRequest] = []
            private var refreshWaiter: CheckedContinuation<Void, Never>?
            private var releaseGate: CheckedContinuation<Void, Never>?
            private var refreshEntered = false
            private let refreshResponse: HTTPResponse
            private let agentUsageResponse: HTTPResponse
            private let creditsResponse: HTTPResponse
            private let resetCardsResponse: HTTPResponse
            private let memberLevelResponse: HTTPResponse

            init(
                refreshResponse: HTTPResponse,
                agentUsageResponse: HTTPResponse,
                creditsResponse: HTTPResponse,
                resetCardsResponse: HTTPResponse,
                memberLevelResponse: HTTPResponse
            ) {
                self.refreshResponse = refreshResponse
                self.agentUsageResponse = agentUsageResponse
                self.creditsResponse = creditsResponse
                self.resetCardsResponse = resetCardsResponse
                self.memberLevelResponse = memberLevelResponse
            }

            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                requests.append(request)
                switch request.url {
                case QwenProvider.refreshURL:
                    refreshEntered = true
                    refreshWaiter?.resume()
                    refreshWaiter = nil
                    await withCheckedContinuation { continuation in
                        releaseGate = continuation
                    }
                    return refreshResponse
                case QwenProvider.agentUsageURL:
                    return agentUsageResponse
                case QwenProvider.creditsURL:
                    return creditsResponse
                case QwenProvider.resetCardURL:
                    return resetCardsResponse
                case QwenProvider.memberLevelURL:
                    return memberLevelResponse
                default:
                    throw ProviderFailure(.transient, "Unexpected URL \(request.url)")
                }
            }

            func waitForRefreshEntry() async {
                if refreshEntered { return }
                await withCheckedContinuation { continuation in
                    refreshWaiter = continuation
                }
            }

            func openGate() {
                releaseGate?.resume()
                releaseGate = nil
            }

            func capturedRequests() -> [HTTPRequest] {
                requests
            }
        }

        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-concurrent.json")
        let cred = QwenCredential(access: nil, refresh: "r1", sourceLabel: "Edge Default")
        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: cred.fingerprintHex,
                accessToken: "expired-access",
                refreshToken: "r1",
                expiresAt: now.addingTimeInterval(-30),
                email: "u@example.com",
                isForked: true
            ),
            for: "Edge Default"
        )

        let http = GatedHTTPClient(
            refreshResponse: httpResponse(json: """
            {
              "success": true,
              "data": {
                "access_token": "fresh-access",
                "refresh_token": "r2",
                "email": "u@example.com",
                "expires_at": \(Int(now.timeIntervalSince1970) + 900)
              }
            }
            """),
            agentUsageResponse: agentUsageOK,
            creditsResponse: creditsOK,
            resetCardsResponse: resetCardsOK,
            memberLevelResponse: httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#)
        )

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: { cred },
            now: { fixedNow }
        )

        let task1 = Task { try await provider.fetch() }
        await http.waitForRefreshEntry()
        let task2 = Task { try await provider.fetch() }
        try await Task.sleep(for: .milliseconds(30))
        await http.openGate()

        let snap1 = try await task1.value
        let snap2 = try await task2.value
        XCTAssertEqual(snap1.planName, "Pro")
        XCTAssertEqual(snap2.planName, "Pro")

        let requests = await http.capturedRequests()
        let refreshRequests = requests.filter { $0.url == QwenProvider.refreshURL }
        XCTAssertEqual(refreshRequests.count, 1)
        XCTAssertEqual(refreshRequests.first?.headers["Cookie"], "refresh_token=r1")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r2")
    }

    func testCancelledFetchDuringRefreshStillPersistsRotatedToken() async throws {
        actor CancellableGateHTTPClient: HTTPClient {
            private var requests: [HTTPRequest] = []
            private var refreshEntered = false
            private var refreshFinished = false
            private var entryWaiter: CheckedContinuation<Void, Never>?
            private var releaseGate: CheckedContinuation<Void, Never>?
            private var finishWaiter: CheckedContinuation<Void, Never>?
            private var queued: [HTTPResponse]

            init(queued: [HTTPResponse]) {
                self.queued = queued
            }

            func send(_ request: HTTPRequest) async throws -> HTTPResponse {
                requests.append(request)
                if request.url == QwenProvider.refreshURL {
                    refreshEntered = true
                    entryWaiter?.resume()
                    entryWaiter = nil
                    await withCheckedContinuation { continuation in
                        releaseGate = continuation
                    }
                    guard !queued.isEmpty else {
                        refreshFinished = true
                        finishWaiter?.resume()
                        finishWaiter = nil
                        throw ProviderFailure(.transient, "No mock refresh response available.")
                    }
                    let response = queued.removeFirst()
                    refreshFinished = true
                    finishWaiter?.resume()
                    finishWaiter = nil
                    return response
                }
                guard !queued.isEmpty else {
                    throw ProviderFailure(.transient, "No mock response available.")
                }
                return queued.removeFirst()
            }

            func waitForRefreshEntry() async {
                if refreshEntered { return }
                await withCheckedContinuation { continuation in
                    entryWaiter = continuation
                }
            }

            func openGateAndWaitForFinish() async {
                releaseGate?.resume()
                releaseGate = nil
                if !refreshFinished {
                    await withCheckedContinuation { continuation in
                        finishWaiter = continuation
                    }
                }
            }

            func capturedRequests() -> [HTTPRequest] {
                requests
            }
        }

        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-cancel.json")
        let cred = QwenCredential(access: nil, refresh: "r1", sourceLabel: "Edge Default")
        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: cred.fingerprintHex,
                accessToken: "expired-access",
                refreshToken: "r1",
                expiresAt: now.addingTimeInterval(-10),
                email: "u@example.com",
                isForked: true
            ),
            for: "Edge Default"
        )

        let http = CancellableGateHTTPClient(queued: [
            httpResponse(json: """
            {
              "success": true,
              "data": {
                "access_token": "access-2",
                "refresh_token": "r2",
                "email": "u@example.com",
                "expires_at": \(Int(now.timeIntervalSince1970) + 900)
              }
            }
            """),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: { cred },
            now: { fixedNow }
        )

        let task1 = Task { try await provider.fetch() }
        await http.waitForRefreshEntry()
        task1.cancel()
        await http.openGateAndWaitForFinish()
        _ = try? await task1.value

        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r2")
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.accessToken, "access-2")

        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.filter { $0.url == QwenProvider.refreshURL }.count, 1)
        XCTAssertEqual(requests.last(where: { $0.url == QwenProvider.agentUsageURL })?.headers["Authorization"], "Bearer access-2")
    }

    func testTransientAndRateLimitRefreshErrorsPreservePersistedSession() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var now: Date
            init(_ now: Date) { self.now = now }
        }

        let clock = Clock(now)
        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-errors.json")
        let cred = QwenCredential(access: nil, refresh: "r1", sourceLabel: "Edge Default")
        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: cred.fingerprintHex,
                accessToken: "expired-access",
                refreshToken: "r1",
                expiresAt: now.addingTimeInterval(-10),
                email: "u@example.com",
                isForked: false
            ),
            for: "Edge Default"
        )

        let http = MockHTTPClient([
            httpResponse(json: #"{"success":false,"data":{"code":"RATE_LIMITED"}}"#),
            httpResponse(json: #"{"success":false,"data":{"code":"INTERNAL_ERROR"}}"#),
            httpResponse(json: """
            {
              "success": true,
              "data": {
                "access_token": "access-2",
                "refresh_token": "r2",
                "email": "u@example.com",
                "expires_at": \(Int(now.timeIntervalSince1970) + 400)
              }
            }
            """),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#),
            httpResponse(json: #"{"success":false,"data":{"code":"Unauthorized","details":"Token is revoked, please login again."}}"#)
        ])

        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: { cred },
            now: { clock.lock.withLock { clock.now } }
        )

        do {
            _ = try await provider.fetch()
            XCTFail("Expected rateLimited failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .rateLimited)
        }
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r1")

        do {
            _ = try await provider.fetch()
            XCTFail("Expected transient failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .transient)
        }
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r1")

        _ = try await provider.fetch()
        XCTAssertEqual(sessionStore.load(for: "Edge Default")?.refreshToken, "r2")

        clock.lock.withLock { clock.now = now.addingTimeInterval(500) }
        do {
            _ = try await provider.fetch()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        }
        XCTAssertNil(sessionStore.load(for: "Edge Default"))
    }

    func testProactiveRefreshTokenRenewalViaAuthorizeCodeAndCooldown() async throws {
        final class Clock: @unchecked Sendable {
            let lock = NSLock()
            var now: Date
            init(_ now: Date) { self.now = now }
        }

        let clock = Clock(now)
        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-proactive.json")
        let expiringRefresh = makeJWT(
            id: "user-1",
            type: "refresh_token",
            iat: now.addingTimeInterval(-29.5 * 86_400),
            exp: now.addingTimeInterval(12 * 3_600)
        )
        let freshRefresh = makeJWT(
            id: "user-1",
            type: "refresh_token",
            iat: now,
            exp: now.addingTimeInterval(30 * 86_400)
        )
        let cred = QwenCredential(access: nil, refresh: expiringRefresh, sourceLabel: "Qwen desktop")
        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: cred.fingerprintHex,
                accessToken: "valid-access",
                refreshToken: expiringRefresh,
                expiresAt: now.addingTimeInterval(600),
                email: "u@example.com",
                isForked: true,
                refreshTokenExpiresAt: now.addingTimeInterval(12 * 3_600)
            ),
            for: "Qwen desktop"
        )

        let http = MockHTTPClient([
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#),
            httpResponse(json: #"{"success":true,"data":{"code":"renew-code-1"}}"#),
            httpResponse(json: """
            {
              "success": true,
              "data": {
                "access_token": "renewed-access",
                "refresh_token": "\(freshRefresh)",
                "email": "u@example.com",
                "expires_at": \(Int(now.timeIntervalSince1970) + 900)
              }
            }
            """)
        ])

        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: { cred },
            now: { clock.lock.withLock { clock.now } }
        )

        _ = try await provider.fetch()
        let saved = sessionStore.load(for: "Qwen desktop")
        XCTAssertEqual(saved?.refreshToken, freshRefresh)
        XCTAssertEqual(saved?.accessToken, "renewed-access")
        XCTAssertEqual(saved?.isForked, true)

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[4].url, QwenProvider.authorizeCodeURL)
        XCTAssertEqual(requests[5].url.absoluteString, "https://auth.qwen.ai/api/v2/auths/refresh?code=renew-code-1")

        // Failed proactive renewal preserves existing session and enforces 1-hour cooldown.
        let files2 = MemoryFiles()
        let store2 = QwenSessionStore(files: files2, path: "/tmp/qwen-auth-cooldown.json")
        store2.save(
            QwenPersistedSession(
                seedFingerprint: cred.fingerprintHex,
                accessToken: "valid-access",
                refreshToken: expiringRefresh,
                expiresAt: now.addingTimeInterval(900),
                email: "u@example.com",
                isForked: true,
                refreshTokenExpiresAt: now.addingTimeInterval(12 * 3_600)
            ),
            for: "Qwen desktop"
        )
        let http2 = MockHTTPClient([
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#),
            httpResponse(500),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#)
        ])
        let provider2 = QwenProvider(
            http: http2,
            sessionStore: store2,
            loadCredentials: { cred },
            now: { clock.lock.withLock { clock.now } }
        )

        _ = try await provider2.fetch()
        XCTAssertEqual(store2.load(for: "Qwen desktop")?.refreshToken, expiringRefresh)

        clock.lock.withLock { clock.now = now.addingTimeInterval(600) }
        _ = try await provider2.fetch()
        let requests2 = await http2.capturedRequests()
        XCTAssertEqual(requests2.filter { $0.url == QwenProvider.authorizeCodeURL }.count, 1)
    }

    func testRevokedForkedSessionRecoversFromUntouchedDiskCookieAndReloadedLocalAccess() async throws {
        // Subcase A: forked session fails auth while untouched disk cookie has the same seedFingerprint.
        let filesA = MemoryFiles()
        let storeA = QwenSessionStore(files: filesA, path: "/tmp/qwen-auth-fork-recover.json")
        let diskCred = QwenCredential(access: nil, refresh: "untouched-disk-cookie", sourceLabel: "Edge Default")
        storeA.save(
            QwenPersistedSession(
                seedFingerprint: diskCred.fingerprintHex,
                accessToken: "expired-forked-access",
                refreshToken: "forked-r1",
                expiresAt: now.addingTimeInterval(-10),
                email: nil,
                isForked: true
            ),
            for: "Edge Default"
        )

        let httpA = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: #"{"success":true,"data":{"access_token":"recovered-access","refresh_token":"recovered-r2","expires_at":1794827823}}"#),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"free"}}"#)
        ])

        let fixedNow = now
        let providerA = QwenProvider(
            http: httpA,
            sessionStore: storeA,
            loadCredentials: { diskCred },
            now: { fixedNow }
        )

        let snapA = try await providerA.fetch()
        XCTAssertEqual(snapA.planName, "Free")
        XCTAssertEqual(storeA.load(for: "Edge Default")?.refreshToken, "recovered-r2")
        let reqsA = await httpA.capturedRequests()
        XCTAssertEqual(reqsA[0].headers["Cookie"], "refresh_token=forked-r1")
        XCTAssertEqual(reqsA[1].headers["Cookie"], "refresh_token=untouched-disk-cookie")

        // Subcase B: fresh LocalStorage JWT is only returned after sessionStore is cleared.
        let filesB = MemoryFiles()
        let storeB = QwenSessionStore(files: filesB, path: "/tmp/qwen-auth-reload-local.json")
        let freshLocalJWT = makeJWT(id: "user-b", type: "access_token", iat: now, exp: now.addingTimeInterval(900))
        let oldCred = QwenCredential(access: nil, refresh: "old-cookie", sourceLabel: "Edge Default")
        storeB.save(
            QwenPersistedSession(
                seedFingerprint: oldCred.fingerprintHex,
                accessToken: "stale-access",
                refreshToken: "revoked-r1",
                expiresAt: now.addingTimeInterval(-10),
                email: "reload@example.com",
                isForked: false
            ),
            for: "Edge Default"
        )

        let httpB = MockHTTPClient([
            httpResponse(401),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"plus"}}"#),
            httpResponse(json: #"{"success":true,"data":{"email":"reload@example.com"}}"#),
            httpResponse(json: #"{"success":true,"data":{"code":"fork-code-b"}}"#),
            httpResponse(json: #"{"success":true,"data":{"access_token":"forked-b","refresh_token":"forked-refresh-b","expires_at":1794828000}}"#)
        ])

        let providerB = QwenProvider(
            http: httpB,
            sessionStore: storeB,
            loadCredentials: {
                let localAccess = storeB.load(for: "Edge Default") == nil ? freshLocalJWT : nil
                return QwenCredential(access: localAccess, refresh: "untouched-browser-cookie", sourceLabel: "Edge Default")
            },
            now: { fixedNow }
        )

        let snapB = try await providerB.fetch()
        XCTAssertEqual(snapB.planName, "Plus")
        XCTAssertEqual(storeB.load(for: "Edge Default")?.refreshToken, "forked-refresh-b")
        let reqsB = await httpB.capturedRequests()
        XCTAssertFalse(reqsB.contains { $0.headers.values.contains { $0.contains("untouched-browser-cookie") } })
    }

    func testAccountSwitchInSourceJWTInvalidatesPersistedSession() async throws {
        let files = MemoryFiles()
        let sessionStore = QwenSessionStore(files: files, path: "/tmp/qwen-auth-switch.json")
        let userAAccess = makeJWT(id: "user-a", type: "access_token", iat: now, exp: now.addingTimeInterval(600))
        let userBRefresh = makeJWT(id: "user-b", type: "refresh_token", iat: now, exp: now.addingTimeInterval(86_400))
        let userBAccess = makeJWT(id: "user-b", type: "access_token", iat: now, exp: now.addingTimeInterval(900))
        let userBNextRefresh = makeJWT(id: "user-b", type: "refresh_token", iat: now, exp: now.addingTimeInterval(86_400))

        sessionStore.save(
            QwenPersistedSession(
                seedFingerprint: "seed-a",
                accessToken: userAAccess,
                refreshToken: "refresh-a",
                expiresAt: now.addingTimeInterval(600),
                email: "a@example.com",
                isForked: true
            ),
            for: "Qwen desktop"
        )

        let http = MockHTTPClient([
            httpResponse(json: """
            {
              "success": true,
              "data": {
                "access_token": "\(userBAccess)",
                "refresh_token": "\(userBNextRefresh)",
                "email": "b@example.com",
                "expires_at": \(Int(now.timeIntervalSince1970) + 900)
              }
            }
            """),
            agentUsageOK, creditsOK, resetCardsOK, httpResponse(json: #"{"success":true,"data":{"memberType":"pro"}}"#)
        ])

        let fixedNow = now
        let provider = QwenProvider(
            http: http,
            sessionStore: sessionStore,
            loadCredentials: {
                QwenCredential(access: nil, refresh: userBRefresh, sourceLabel: "Qwen desktop")
            },
            now: { fixedNow }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.identityEmail, "b@example.com")
        XCTAssertEqual(sessionStore.load(for: "Qwen desktop")?.accessToken, userBAccess)
        XCTAssertEqual(sessionStore.load(for: "Qwen desktop")?.refreshToken, userBNextRefresh)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].headers["Cookie"], "refresh_token=\(userBRefresh)")
    }

    func testExtractRefreshTokenCookieSkipsDeletedAndMaxAgeZero() {
        let withDeletedThenValid = HTTPResponse(
            statusCode: 200,
            headers: [
                "Set-Cookie": "refresh_token=deleted; Path=/; Max-Age=0, acw_tc=abc, refresh_token=valid-jwt-token; Path=/; HttpOnly"
            ],
            body: Data()
        )
        XCTAssertEqual(QwenProvider.extractRefreshTokenCookie(from: withDeletedThenValid), "valid-jwt-token")

        let deletedOnly = HTTPResponse(
            statusCode: 200,
            headers: ["Set-Cookie": "refresh_token=deleted; Max-Age=0"],
            body: Data()
        )
        XCTAssertNil(QwenProvider.extractRefreshTokenCookie(from: deletedOnly))

        let maxAgeZeroOnly = HTTPResponse(
            statusCode: 200,
            headers: ["Set-Cookie": "refresh_token=stale-token; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Max-Age=0"],
            body: Data()
        )
        XCTAssertNil(QwenProvider.extractRefreshTokenCookie(from: maxAgeZeroOnly))
    }

    private func makeJWT(id: String, type: String, iat: Date, exp: Date) -> String {
        func b64(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        let payload = b64(Data("{\"id\":\"\(id)\",\"type\":\"\(type)\",\"iat\":\(Int(iat.timeIntervalSince1970)),\"exp\":\(Int(exp.timeIntervalSince1970))}".utf8))
        return "\(header).\(payload).sig"
    }
}
