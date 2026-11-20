import Foundation
import XCTest
@testable import AIUsage

final class QoderProviderTests: XCTestCase {
    @MainActor
    func testMapsQoderLiveUsageAndPlanSnapshot() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_795_109_000)
        let usageJSON = """
        {
          "displayMode": "qoder",
          "qoderUsage": {
            "userId": "01a17204-b130-7909-bbc7-d66b18771c3a",
            "userType": "personal_professional_trial",
            "usageType": "credits",
            "totalUsagePercentage": 0,
            "isQuotaExceeded": false,
            "expiresAt": 1795750354290,
            "refreshAt": 1795750354290,
            "userQuota": {
              "total": 300,
              "used": 60,
              "remaining": 240,
              "percentage": 20,
              "unit": "credits"
            },
            "addOnQuota": {
              "total": 100,
              "used": 25,
              "remaining": 75,
              "percentage": 25,
              "unit": "credits"
            }
          }
        }
        """
        let planJSON = """
        {
          "user_type": "personal_professional_trial",
          "plan_tier_name": "Pro Trial",
          "is_personal_version": true
        }
        """
        let http = MockHTTPClient([
            httpResponse(200, json: usageJSON),
            httpResponse(200, json: planJSON)
        ])
        let seed = QoderDesktopSeed(
            accessToken: "qoder-access-1",
            refreshToken: "qoder-refresh-1",
            expiresAt: fixedNow.addingTimeInterval(3_600),
            refreshTokenExpiresAt: fixedNow.addingTimeInterval(86_400 * 30),
            email: "dev@example.com",
            userID: "01a17204-b130-7909-bbc7-d66b18771c3a",
            sourceLabel: "Qoder desktop"
        )
        let provider = QoderProvider(
            http: http,
            authLoader: { _ in .desktop(seed) },
            method: { .desktop },
            now: { fixedNow }
        )

        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.provider, .qoder)
        XCTAssertEqual(snapshot.planName, "Pro Trial")
        XCTAssertEqual(snapshot.accountEmail, "dev@example.com")
        XCTAssertEqual(snapshot.credentialSource, "Qoder desktop")
        XCTAssertEqual(snapshot.dashboardSubtitle, "Shared account limits • Qoder & Qoder IDE")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].kind, .weekly)
        XCTAssertEqual(snapshot.windows[0].usedPercent, 20, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[0].remainingCount, 240)
        XCTAssertEqual(snapshot.windows[0].limitCount, 300)
        XCTAssertEqual(snapshot.windows[0].resetsAt?.timeIntervalSince1970 ?? 0, 1_795_750_354.29, accuracy: 0.1)
        XCTAssertEqual(snapshot.usageDetails.count, 1)
        XCTAssertEqual(snapshot.usageDetails[0].id, "qoder.addon.credits")
        XCTAssertEqual(snapshot.usageDetails[0].title, "Add-on Credits")
        XCTAssertEqual(snapshot.usageDetails[0].value, "75 / 100 left")
        XCTAssertEqual(
            snapshot.usageDetails[0].boundedProgress,
            BoundedCreditProgress(label: "Add-on", used: 25, limit: 100, resetsAt: nil, resetNote: "No reset")
        )
        XCTAssertTrue(ProviderDetailsLayout.canExpand(snapshot))

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url.absoluteString, "https://openapi.qoder.sh/sash/api/v2/me/usage")
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer qoder-access-1")
        XCTAssertEqual(requests[0].headers["Cosy-ClientType"], "10")
        XCTAssertEqual(requests[0].headers["User-Agent"], "Qoder")
        XCTAssertEqual(requests[1].url.absoluteString, "https://openapi.qoder.sh/api/v2/user/plan")
    }

    func testMapsEnterpriseDisplayModeAndOrgResourcePackage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let enterpriseJSON = """
        {
          "displayMode": "enterprise",
          "enterpriseUsage": {
            "openMode": "externalBrowser",
            "detailUrl": "https://qoder.com/enterprise/usage"
          }
        }
        """
        let enterpriseSnap = try QoderProvider.map(
            usage: httpResponse(200, json: enterpriseJSON),
            plan: nil,
            email: "org@example.com",
            credentialSource: "Qoder desktop",
            historyID: "qoder-session:abc",
            now: now
        )
        XCTAssertEqual(enterpriseSnap.planName, "Enterprise")
        XCTAssertTrue(enterpriseSnap.windows.isEmpty)
        XCTAssertEqual(enterpriseSnap.usageDetails.first?.title, "Usage")
        XCTAssertEqual(enterpriseSnap.usageDetails.first?.value, "Managed by organization")
        XCTAssertTrue(enterpriseSnap.hasPanelContent)

        let orgJSON = """
        {
          "displayMode": "qoder",
          "qoderUsage": {
            "userType": "pro",
            "userQuota": {"total": 500, "used": 100, "remaining": 400, "percentage": 20},
            "orgResourcePackage": {"total": 2000, "used": 500, "remaining": 1500}
          }
        }
        """
        let orgSnap = try QoderProvider.map(
            usage: httpResponse(200, json: orgJSON),
            plan: nil,
            email: nil,
            credentialSource: "Qoder desktop",
            historyID: "qoder-session:abc",
            now: now
        )
        XCTAssertEqual(orgSnap.planName, "Pro")
        XCTAssertEqual(orgSnap.usageDetails.first?.id, "qoder.org.credits")
        XCTAssertEqual(orgSnap.usageDetails.first?.title, "Org Credits")
        XCTAssertEqual(orgSnap.usageDetails.first?.value, "500 / 2,000")
        XCTAssertEqual(
            orgSnap.usageDetails.first?.boundedProgress,
            BoundedCreditProgress(label: "Org pool", used: 500, limit: 2000, resetsAt: nil, resetNote: "No reset")
        )
    }

    func testProactiveTokenRefreshPersistsRotatedTokens() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let files = MemoryFiles()
        let store = QoderSessionStore(files: files)

        let refreshJSON = """
        {
          "device_token": "rotated-access-2",
          "refresh_token": "rotated-refresh-2",
          "expires_in": 7200,
          "refresh_token_expires_in": 86400
        }
        """
        let usageJSON = """
        {
          "displayMode": "qoder",
          "qoderUsage": {
            "userType": "personal_pro",
            "userQuota": {"total": 300, "used": 30, "remaining": 270, "percentage": 10}
          }
        }
        """
        let http1 = MockHTTPClient([
            httpResponse(200, json: refreshJSON),
            httpResponse(200, json: usageJSON),
            httpResponse(404)
        ])
        let expiringSeed = QoderDesktopSeed(
            accessToken: "old-access-1",
            refreshToken: "old-refresh-1",
            expiresAt: fixedNow.addingTimeInterval(30),
            refreshTokenExpiresAt: fixedNow.addingTimeInterval(86_400),
            email: "user@example.com",
            userID: "user-1",
            sourceLabel: "Qoder desktop"
        )
        let provider1 = QoderProvider(
            http: http1,
            authLoader: { _ in .desktop(expiringSeed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow }
        )

        let snap1 = try await provider1.fetch()
        XCTAssertEqual(snap1.planName, "Pro")
        let persisted = try XCTUnwrap(store.load(for: "Qoder desktop"))
        XCTAssertEqual(persisted.accessToken, "rotated-access-2")
        XCTAssertEqual(persisted.refreshToken, "rotated-refresh-2")

        let requests1 = await http1.capturedRequests()
        XCTAssertEqual(requests1[0].url.absoluteString, "https://openapi.qoder.sh/api/v1/deviceToken/refresh")
        XCTAssertEqual(requests1[0].method, .post)
        let refreshBody = try XCTUnwrap(requests1[0].body)
        let parsedRefreshBody = try ProviderParsing.object(from: refreshBody)
        XCTAssertEqual(parsedRefreshBody["refresh_token"] as? String, "old-refresh-1")
        XCTAssertEqual(requests1[1].headers["Authorization"], "Bearer rotated-access-2")

        // Next provider instance reads stale disk seed but reuses persisted rotated token.
        let http2 = MockHTTPClient([
            httpResponse(200, json: usageJSON),
            httpResponse(404)
        ])
        let provider2 = QoderProvider(
            http: http2,
            authLoader: { _ in .desktop(expiringSeed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow.addingTimeInterval(60) }
        )
        _ = try await provider2.fetch()
        let requests2 = await http2.capturedRequests()
        XCTAssertEqual(requests2.count, 2)
        XCTAssertEqual(requests2[0].headers["Authorization"], "Bearer rotated-access-2")
    }

    func testRetriesOn401AndClearsPersistedSessionWhenRefreshRejected() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let files = MemoryFiles()
        let store = QoderSessionStore(files: files)
        let seed = QoderDesktopSeed(
            accessToken: "seed-access",
            refreshToken: "seed-refresh",
            expiresAt: fixedNow.addingTimeInterval(3_600),
            refreshTokenExpiresAt: fixedNow.addingTimeInterval(86_400),
            email: "user@example.com",
            userID: "user-1",
            sourceLabel: "Qoder desktop"
        )
        let usageJSON = """
        {
          "displayMode": "qoder",
          "qoderUsage": {
            "userType": "personal_professional_trial",
            "userQuota": {"total": 300, "used": 0, "remaining": 300, "percentage": 0}
          }
        }
        """

        let httpRetry = MockHTTPClient([
            httpResponse(401),
            httpResponse(200, json: #"{"device_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#),
            httpResponse(200, json: usageJSON),
            httpResponse(404)
        ])
        let provider = QoderProvider(
            http: httpRetry,
            authLoader: { _ in .desktop(seed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow }
        )
        _ = try await provider.fetch()
        XCTAssertEqual(store.load(for: "Qoder desktop")?.accessToken, "fresh-access")

        // Rejected refresh removes persisted cache.
        let httpFail = MockHTTPClient([
            httpResponse(401),
            httpResponse(401),
            httpResponse(401)
        ])
        let providerFail = QoderProvider(
            http: httpFail,
            authLoader: { _ in .desktop(seed) },
            method: { .desktop },
            sessionStore: store,
            now: { fixedNow }
        )
        do {
            _ = try await providerFail.fetch()
            XCTFail("Expected authentication error")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
        }
        XCTAssertNil(store.load(for: "Qoder desktop"))
    }

    func testBrowserCookieUsesWebUsageEndpointAndFallsBackToUserType() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let usageJSON = """
        {
          "displayMode": "qoder",
          "qoderUsage": {
            "userId": "u-browser-1",
            "userType": "personal_professional_trial",
            "userQuota": {"total": 300, "used": 15, "remaining": 285, "percentage": 5}
          }
        }
        """
        let http = MockHTTPClient([httpResponse(200, json: usageJSON)])
        let provider = QoderProvider(
            http: http,
            authLoader: { _ in .browser(cookieHeader: "qoder_session_cookie=web-cookie-val", sourceLabel: "Edge Default") },
            method: { .edge },
            now: { fixedNow }
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.credentialSource, "Edge Default")
        XCTAssertEqual(snapshot.planName, "Pro Trial")
        XCTAssertEqual(snapshot.windows.first?.usedPercent ?? -1, 5, accuracy: 0.01)
        XCTAssertEqual(snapshot.usageDetails.map(\.id), ["qoder.addon.credits"])
        XCTAssertEqual(snapshot.usageDetails.map(\.title), ["Add-on Credits"])
        XCTAssertEqual(snapshot.usageDetails.map(\.value), ["N/A"])

        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url.absoluteString, "https://qoder.com/sash/api/v2/me/usage")
        XCTAssertEqual(requests[0].headers["Cookie"], "qoder_session_cookie=web-cookie-val")
    }

    func testDecryptsDesktopAuthDatAndIDEStateDatabase() throws {
        let password = "test-safe-storage-password"
        let desktopPayload = """
        {
          "schemaVersion": 1,
          "token": "qoder-app-tok",
          "refreshToken": "qoder-app-ref",
          "expiresAt": "2026-12-13T03:32:58Z",
          "refreshTokenExpiresAt": "2027-11-08T03:32:58Z",
          "user": {
            "id": "u-app",
            "email": "app@example.com"
          }
        }
        """
        let desktopEncrypted = try ChromiumSafeStorageCodec.encrypt(Data(desktopPayload.utf8), password: password)
        let files = MemoryFiles([
            "/mock/auth.v1.dat": "placeholder"
        ])
        let keychain = MemoryKeychain(generic: [
            QoderAuthLoader.desktopKeychainService: password,
            QoderAuthLoader.ideKeychainService: password
        ])

        let desktopLoader = QoderAuthLoader(
            files: files,
            keychain: keychain,
            desktopAuthPath: "/mock/auth.v1.dat",
            ideDatabasePath: "/mock/missing-state.vscdb",
            dataReader: { _ in desktopEncrypted }
        )
        let loadedDesktop = try desktopLoader.load(method: .desktop)
        guard case let .desktop(desktopSeed) = loadedDesktop else {
            return XCTFail("Expected desktop seed")
        }
        XCTAssertEqual(desktopSeed.accessToken, "qoder-app-tok")
        XCTAssertEqual(desktopSeed.refreshToken, "qoder-app-ref")
        XCTAssertEqual(desktopSeed.email, "app@example.com")
        XCTAssertEqual(desktopSeed.sourceLabel, "Qoder desktop")

        let idePayload = """
        {
          "id": "u-ide",
          "token": "qoder-ide-tok",
          "refreshToken": "qoder-ide-ref",
          "expireTime": "1797132753000",
          "email": "ide@example.com"
        }
        """
        let ideEncrypted = try ChromiumSafeStorageCodec.encrypt(Data(idePayload.utf8), password: password)
        let bufferJSON = try JSONSerialization.data(withJSONObject: ["type": "Buffer", "data": ideEncrypted.map(Int.init)])
        let ideFiles = MemoryFiles(["/mock/state.vscdb": "placeholder"])
        let ideLoader = QoderAuthLoader(
            files: ideFiles,
            keychain: keychain,
            sqlite: StubQoderSQLite(value: String(decoding: bufferJSON, as: UTF8.self)),
            desktopAuthPath: "/mock/missing-auth.v1.dat",
            ideDatabasePath: "/mock/state.vscdb"
        )
        let loadedIDE = try ideLoader.load(method: .desktop)
        guard case let .desktop(ideSeed) = loadedIDE else {
            return XCTFail("Expected IDE seed")
        }
        XCTAssertEqual(ideSeed.accessToken, "qoder-ide-tok")
        XCTAssertEqual(ideSeed.refreshToken, "qoder-ide-ref")
        XCTAssertEqual(ideSeed.email, "ide@example.com")
        XCTAssertEqual(ideSeed.sourceLabel, "Qoder IDE")
    }
}

private struct StubQoderSQLite: SQLiteValueReading {
    let value: String?

    func queryValue(path: String, sql: String) throws -> String? {
        value
    }

    func execute(path: String, sql: String) throws {}
}
