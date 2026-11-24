import CryptoKit
import Foundation
import XCTest
@testable import AIUsage

final class MiniMaxProviderTests: XCTestCase {
    func testMapsTokenPlanAgentDesignAndHailuoUnifiedSnapshot() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_109_900)
        let remainsJSON = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_used_percent": "25%",
              "current_interval_total_percent": "100%",
              "end_time": 1795120000000,
              "current_weekly_used_percent": "40%",
              "current_weekly_total_percent": "100%",
              "weekly_end_time": 1795700000000
            },
            {
              "model_name": "MiniMax-Hailuo-Video",
              "current_interval_used_count": 3,
              "current_interval_total_count": 20,
              "end_time": 1795120000000
            }
          ],
          "base_resp": {"status_code": 0, "status_msg": "success"}
        }
        """
        let tokenPlanCreditJSON = """
        {
          "remaining_credits": 1500,
          "base_resp": {"status_code": 0, "status_msg": "success"}
        }
        """
        let membershipJSON = """
        {
          "data": {
            "token_plan_tier": "Pro",
            "op_group_id": "group-123"
          },
          "base_resp": {"status_code": 0, "status_msg": "success"}
        }
        """
        let walletJSON = """
        {
          "wallets": [
            {"source": 1, "plan_name": "Design Plus", "total_credit": "420"},
            {"source": 0, "plan_name": "", "total_credit": "80"}
          ]
        }
        """
        let profileJSON = #"{"account":"creator@example.com","uid":"577508542260006921"}"#
        let hailuoCreditJSON = #"{"data":{"total_credit":350},"statusInfo":{"code":0}}"#
        let hailuoEquityJSON = #"{"data":{"memberName":"Standard"},"statusInfo":{"code":0}}"#

        let http = MockHTTPClient([
            httpResponse(200, json: membershipJSON),
            httpResponse(200, json: remainsJSON),
            httpResponse(200, json: tokenPlanCreditJSON),
            httpResponse(200, json: walletJSON),
            httpResponse(200, json: profileJSON),
            httpResponse(200, json: hailuoCreditJSON),
            httpResponse(200, json: hailuoEquityJSON)
        ])

        let desktopSeed = MiniMaxDesktopSeed(
            codeOAuth: MiniMaxCodeOAuthSeed(
                accessToken: "oauth-live-access",
                refreshToken: "oauth-refresh",
                clientID: "mcode-public",
                scopes: ["agent.default"],
                audience: "agent-backend",
                expiresAtMs: fixedNow.addingTimeInterval(3_600).timeIntervalSince1970 * 1000
            ),
            design: MiniMaxDesignSeed(
                jwtToken: "design-jwt-token",
                groupID: nil,
                userID: "577508542260006921"
            ),
            sourceLabel: "MiniMax desktop"
        )
        let provider = MiniMaxProvider(
            http: http,
            authLoader: { _ in .desktop(desktopSeed) },
            method: { .desktop },
            now: { fixedNow }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .minimax)
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.accountEmail, "creator@example.com")
        XCTAssertEqual(snapshot.dashboardSubtitle, "Unified account • Agent, Design & Hailuo Video")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 40, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].kind, .additional(id: "minimax.video", title: "Video"))
        XCTAssertEqual(snapshot.windows[2].usedPercent, 15, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].remainingCount, 17)
        XCTAssertEqual(snapshot.windows[2].limitCount, 20)

        XCTAssertEqual(snapshot.usageDetails.map(\.id), ["minimax.credits", "minimax.agent.credits"])
        XCTAssertEqual(snapshot.usageDetails.map(\.title), ["Additional Credits", "Token Plan Credits"])
        XCTAssertEqual(snapshot.usageDetails[0].value, "Design 420 · Hailuo 350")
        XCTAssertEqual(snapshot.usageDetails[1].value, "1,500 credits")

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests[0].url.host, "agent.minimax.io")
        XCTAssertEqual(requests[1].headers["X-Group-Id"], "group-123")
        XCTAssertEqual(requests[5].url.host, "hailuoai.video")
        XCTAssertEqual(requests[5].headers["token"], "design-jwt-token")
    }

    @MainActor
    func testFreeAccountShowsInactiveTokenPlanBarsAndExpandableDesignHailuoCredits() throws {
        let now = Date(timeIntervalSince1970: 1_795_109_900)
        let snapshot = try MiniMaxProvider.map(
            remains: httpResponse(200, json: #"{"base_resp":{"status_code":0,"status_msg":"success"}}"#),
            tokenPlanCredit: httpResponse(200, json: #"{"remaining_credits":0,"base_resp":{"status_code":0}}"#),
            membership: nil,
            wallet: httpResponse(200, json: #"{"wallets":[{"source":1,"plan_name":"","total_credit":"0"}]}"#),
            profile: httpResponse(200, json: #"{"account":"free@example.com"}"#),
            hailuoCredit: httpResponse(200, json: #"{"data":{"total_credit":0},"statusInfo":{"code":0}}"#),
            hailuoEquity: httpResponse(200, json: #"{"data":{"memberName":"Free"},"statusInfo":{"code":0}}"#),
            credentialSource: "MiniMax desktop",
            historyID: "minimax-session:abc",
            now: now
        )
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.accountEmail, "free@example.com")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows.map(\.kind), [.session, .weekly])
        XCTAssertTrue(snapshot.windows.allSatisfy(\.isInactive))
        XCTAssertEqual(snapshot.windows[0].inactiveDetail, "No Token Plan")
        XCTAssertEqual(snapshot.windows[1].inactiveDetail, "No Token Plan")
        XCTAssertNil(snapshot.windows[1].trailingDetail)
        XCTAssertTrue(snapshot.availableMenuBarItems.isEmpty)
        XCTAssertEqual(snapshot.usageDetails.map(\.id), ["minimax.credits"])
        XCTAssertEqual(snapshot.usageDetails.map(\.title), ["Additional Credits"])
        XCTAssertEqual(snapshot.usageDetails.map(\.value), ["Design 0 · Hailuo 0"])
        XCTAssertTrue(snapshot.hasPanelContent)
        XCTAssertTrue(ProviderDetailsLayout.canExpand(snapshot))
        XCTAssertFalse(ProviderDetailsLayout.showsAdditionalUsageRow(snapshot))

        let history = UsageHistory()
        history.record(snapshot)
        XCTAssertTrue(history.points.isEmpty)

        let withAgentCredits = try MiniMaxProvider.map(
            remains: httpResponse(200, json: #"{"base_resp":{"status_code":0,"status_msg":"success"}}"#),
            tokenPlanCredit: httpResponse(200, json: #"{"remaining_credits":0,"base_resp":{"status_code":0}}"#),
            membership: httpResponse(200, json: #"{"op_credit_summary":{"total_remaining_amount":"378.76"},"base_resp":{"status_code":0}}"#),
            wallet: httpResponse(200, json: #"{"wallets":[{"source":1,"plan_name":"","total_credit":"340"}]}"#),
            profile: httpResponse(200, json: #"{"account":"free@example.com"}"#),
            hailuoCredit: httpResponse(200, json: #"{"data":{"total_credit":50},"statusInfo":{"code":0}}"#),
            hailuoEquity: nil,
            credentialSource: "MiniMax desktop",
            historyID: "minimax-session:abc",
            now: now
        )
        XCTAssertEqual(withAgentCredits.windows[0].inactiveDetail, "No Token Plan")
        XCTAssertEqual(withAgentCredits.windows[1].inactiveDetail, "No Token Plan")
        XCTAssertNil(withAgentCredits.windows[1].trailingDetail)
        XCTAssertEqual(withAgentCredits.usageDetails.map(\.id), ["minimax.credits"])
        XCTAssertEqual(withAgentCredits.usageDetails.map(\.value), ["Agent 378.76 · Design 340 · Hailuo 50"])
    }

    func testDecryptsDesignV2EncWith16ByteIV() throws {
        let keyBytes = Data((0..<32).map { UInt8($0) })
        let key = SymmetricKey(data: keyBytes)
        let iv = Data((10..<26).map { UInt8($0) }) // 16-byte IV as used by MiniMax Design
        let nonce = try AES.GCM.Nonce(data: iv)
        let plaintext = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig"
        let sealed = try AES.GCM.seal(Data(plaintext.utf8), using: key, nonce: nonce)
        let encoded = "v2enc:\(iv.base64EncodedString()):\(sealed.tag.base64EncodedString()):\(sealed.ciphertext.base64EncodedString())"

        let decrypted = try MiniMaxDesignCodec.decryptV2Enc(encoded, keyData: keyBytes)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testSigningGeneratesDeterministicHeadersAndParams() {
        let fixedDate = Date(timeIntervalSince1970: 1_795_109_900)
        let request = MiniMaxSigning.signedRequest(
            method: .post,
            baseURL: "https://agent.minimax.io",
            path: "/matrix/api/v1/commerce/get_membership_info",
            bizID: "3",
            body: "{}",
            tokenHeader: nil,
            bearerToken: "oauth-tok",
            now: fixedDate
        )
        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.headers["x-timestamp"], "1795109900")
        XCTAssertEqual(request.headers["Authorization"], "Bearer oauth-tok")
        XCTAssertEqual(
            request.headers["x-signature"],
            MiniMaxSigning.md5Hex("1795109900I*7Cf%WZ#S&%1RlZJ&C2{}")
        )
        let components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["biz_id"], "3")
        XCTAssertEqual(query["unix"], "1795109900000")
        XCTAssertNotNil(request.headers["yy"])
        XCTAssertEqual(MiniMaxSigning.encodeURIComponent("/a?b=1&c=2"), "%2Fa%3Fb%3D1%26c%3D2")
    }

    func testOAuthRefreshPersistsRotationAndFallsBackToDesignJWTOnFailure() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let files = MemoryFiles()
        let store = MiniMaxSessionStore(files: files)

        let expiredOAuth = MiniMaxCodeOAuthSeed(
            accessToken: "expired-access",
            refreshToken: "old-refresh",
            clientID: "mcode-public",
            scopes: ["agent.default"],
            audience: "agent-backend",
            expiresAtMs: fixedNow.addingTimeInterval(-60).timeIntervalSince1970 * 1000
        )
        let desktopSeed = MiniMaxDesktopSeed(
            codeOAuth: expiredOAuth,
            design: MiniMaxDesignSeed(jwtToken: "design-jwt", groupID: "grp-1", userID: "uid-1"),
            sourceLabel: "MiniMax desktop"
        )

        // 1. Successful OAuth refresh persists rotated token.
        let httpRefreshOK = MockHTTPClient([
            httpResponse(200, json: #"{"access_token":"new-oauth-access","refresh_token":"new-oauth-refresh","expires_in":3600}"#),
            httpResponse(200, json: #"{"data":{"token_plan_tier":"Build"},"base_resp":{"status_code":0}}"#),
            httpResponse(200, json: #"{"model_remains":[{"model_name":"general","current_interval_used_percent":"10%","current_interval_total_percent":"100%"}],"base_resp":{"status_code":0}}"#),
            httpResponse(200, json: #"{"remaining_credits":200,"base_resp":{"status_code":0}}"#),
            httpResponse(200, json: #"{"wallets":[{"source":1,"total_credit":"50"}]}"#),
            httpResponse(200, json: #"{"account":"user@example.com"}"#),
            httpResponse(200, json: #"{"data":{"total_credit":25},"statusInfo":{"code":0}}"#),
            httpResponse(200, json: #"{"data":{"memberName":"Pro"},"statusInfo":{"code":0}}"#)
        ])
        let providerOK = MiniMaxProvider(
            http: httpRefreshOK,
            authLoader: { _ in .desktop(desktopSeed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow }
        )
        let snap = try await providerOK.fetch()
        XCTAssertEqual(snap.planName, "Build")
        XCTAssertEqual(store.load(for: "MiniMax desktop")?.accessToken, "new-oauth-access")
        XCTAssertEqual(store.load(for: "MiniMax desktop")?.refreshToken, "new-oauth-refresh")
        let reqsOK = await httpRefreshOK.capturedRequests()
        XCTAssertEqual(reqsOK[0].url.absoluteString, "https://account.minimax.io/oauth2/token")
        XCTAssertEqual(String(decoding: reqsOK[0].body ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"), true)

        // 2. Next provider instance advances past expiry -> refresh rejects both persisted and seed refresh tokens -> clears cache & falls back to Design JWT.
        let httpFallback = MockHTTPClient([
            httpResponse(400, json: #"{"error":"invalid_grant"}"#),
            httpResponse(400, json: #"{"error":"invalid_grant"}"#),
            httpResponse(200, json: #"{"wallets":[{"source":1,"total_credit":"75"}]}"#),
            httpResponse(200, json: #"{"account":"user@example.com"}"#),
            httpResponse(200, json: #"{"data":{"total_credit":10},"statusInfo":{"code":0}}"#),
            httpResponse(200, json: #"{"data":{"memberName":"Free"},"statusInfo":{"code":0}}"#),
            httpResponse(200, json: #"{"base_resp":{"status_code":0}}"#),
            httpResponse(200, json: #"{"remaining_credits":0,"base_resp":{"status_code":0}}"#)
        ])
        let providerFallback = MiniMaxProvider(
            http: httpFallback,
            authLoader: { _ in .desktop(desktopSeed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow.addingTimeInterval(3_600) }
        )
        let fallbackSnap = try await providerFallback.fetch()
        XCTAssertEqual(fallbackSnap.planName, "Free")
        XCTAssertEqual(fallbackSnap.usageDetails.map(\.value), ["Design 75 · Hailuo 10"])
        XCTAssertNil(store.load(for: "MiniMax desktop"))
    }

    func testBrowserCookieFetchesDesignHailuoAndPlatformEndpoints() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let http = MockHTTPClient([
            httpResponse(200, json: #"{"wallets":[{"source":1,"total_credit":"120"}]}"#),
            httpResponse(200, json: #"{"account":"edge@example.com"}"#),
            httpResponse(200, json: #"{"data":{"total_credit":40},"statusInfo":{"code":0}}"#),
            httpResponse(200, json: #"{"data":{"memberName":"Free"},"statusInfo":{"code":0}}"#),
            httpResponse(200, json: #"{"base_resp":{"status_code":0}}"#),
            httpResponse(200, json: #"{"remaining_credits":0,"base_resp":{"status_code":0}}"#)
        ])
        let provider = MiniMaxProvider(
            http: http,
            authLoader: { _ in .browser(jwtToken: "edge-jwt-token", sourceLabel: "Edge Default") },
            method: { .edge },
            now: { fixedNow }
        )
        let snap = try await provider.fetch()
        XCTAssertEqual(snap.credentialSource, "Edge Default")
        XCTAssertEqual(snap.accountEmail, "edge@example.com")
        XCTAssertEqual(snap.planName, "Free")
        XCTAssertEqual(snap.usageDetails.map(\.value), ["Design 120 · Hailuo 40"])
    }

    func testActiveTokenPlanWithTotalCreditsRendersBoundedTokenPlanProgress() throws {
        let now = Date(timeIntervalSince1970: 1_795_109_900)
        let snapshot = try MiniMaxProvider.map(
            remains: httpResponse(200, json: """
            {
              "model_remains": [{
                "model_name": "general",
                "current_interval_used_percent": 10,
                "current_interval_total_percent": 100,
                "current_weekly_used_percent": 20,
                "current_weekly_total_percent": 100
              }],
              "base_resp": {"status_code": 0}
            }
            """),
            tokenPlanCredit: httpResponse(200, json: """
            {
              "remaining_credits": 1500,
              "total_credits": 2000,
              "used_credits": 500,
              "base_resp": {"status_code": 0}
            }
            """),
            membership: httpResponse(200, json: #"{"token_plan_tier":"Pro","base_resp":{"status_code":0}}"#),
            now: now
        )

        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
        let tokenPlanDetail = try XCTUnwrap(snapshot.usageDetails.first(where: { $0.id == "minimax.agent.credits" }))
        XCTAssertEqual(tokenPlanDetail.title, "Token Plan Credits")
        XCTAssertEqual(tokenPlanDetail.value, "1,500 / 2,000 left")
        XCTAssertEqual(
            tokenPlanDetail.boundedProgress,
            BoundedCreditProgress(label: "Token Plan", used: 500, limit: 2000, resetsAt: nil, resetNote: "No reset")
        )
    }

    func testMapsAllMultimodalPoolsUnlimitedWeeklyZeroBalancesAndGiftCredits() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let remainsJSON = """
        {
          "model_remains": [
            {
              "model_name": "general",
              "current_interval_remaining_percent": 75,
              "remains_time": 3600000,
              "current_weekly_status": 3,
              "weekly_remains_time": 86400000
            },
            {
              "model_name": "MiniMax-Hailuo-Video",
              "current_interval_used_count": 2,
              "current_interval_total_count": 10,
              "end_time": 1800007200000
            },
            {
              "model_name": "MiniMax-Speech",
              "current_interval_usage_count": 15,
              "current_interval_total_count": 20,
              "remains_time": 1800000
            },
            {
              "model_name": "MiniMax-Image",
              "current_interval_used_percent": 40,
              "current_interval_total_percent": 100
            },
            {
              "model_name": "MiniMax-Music",
              "current_interval_status": 3
            }
          ],
          "base_resp": {"status_code": 0}
        }
        """
        let snapshot = try MiniMaxProvider.map(
            remains: httpResponse(200, json: remainsJSON),
            tokenPlanCredit: httpResponse(200, json: #"{"remaining_credits":0,"base_resp":{"status_code":0}}"#),
            membership: httpResponse(200, json: #"{"token_plan_tier":"Max","daily_login_gift_credit_remaining":50,"base_resp":{"status_code":0}}"#),
            now: now
        )
        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(snapshot.windows.count, 6)
        XCTAssertEqual(snapshot.windows[0].kind, .session)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 25, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[0].resetsAt, now.addingTimeInterval(3_600))

        XCTAssertEqual(snapshot.windows[1].kind, .weekly)
        XCTAssertTrue(snapshot.windows[1].isUnlimited)
        XCTAssertEqual(snapshot.windows[1].resetsAt, now.addingTimeInterval(86_400))

        XCTAssertEqual(snapshot.windows[2].kind, .additional(id: "minimax.video", title: "Video"))
        XCTAssertEqual(snapshot.windows[2].remainingCount, 8)
        XCTAssertEqual(snapshot.windows[2].limitCount, 10)

        XCTAssertEqual(snapshot.windows[3].kind, .additional(id: "minimax.model.minimax-speech", title: "Speech"))
        XCTAssertEqual(snapshot.windows[3].remainingCount, 15)
        XCTAssertEqual(snapshot.windows[3].limitCount, 20)
        XCTAssertEqual(snapshot.windows[3].usedPercent, 25, accuracy: 0.01)

        XCTAssertEqual(snapshot.windows[4].kind, .additional(id: "minimax.model.minimax-image", title: "Image"))
        XCTAssertEqual(snapshot.windows[4].usedPercent, 40, accuracy: 0.01)

        XCTAssertEqual(snapshot.windows[5].kind, .additional(id: "minimax.model.minimax-music", title: "Music"))
        XCTAssertTrue(snapshot.windows[5].isUnlimited)

        let additional = try XCTUnwrap(snapshot.usageDetails.first { $0.id == "minimax.credits" })
        XCTAssertEqual(additional.value, "Gift 50")
        let tokenPlanZero = try XCTUnwrap(snapshot.usageDetails.first { $0.id == "minimax.agent.credits" })
        XCTAssertEqual(tokenPlanZero.value, "0 credits")
    }
}
