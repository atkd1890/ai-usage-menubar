import XCTest
@testable import AIUsage

final class ConsumerQuotaTests: XCTestCase {
    func testKimiRefreshIsScopedRetriedOnceAndCachedOnlyForSameNativeSession() async throws {
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let stats = httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0}}"#)
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: #"{"access_token":"new-access","refresh_token":"Bearer new-refresh"}"#),
            subscription, stats, httpResponse(json: "{}"),
            subscription, stats, httpResponse(json: "{}"),
            httpResponse(401),
            httpResponse(json: #"{"access_token":"newer-access","refresh_token":"Bearer newer-refresh"}"#),
            subscription, stats, httpResponse(json: "{}")
        ])
        let provider = ConsumerQuotaProvider(id: .kimi, http: http,
            nativeKimi: { KimiNativeSession(access: "old-access", refresh: "old-refresh") }, allowRefresh: { true })
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 13)
        XCTAssertEqual(requests[1].url.absoluteString, "https://www.kimi.ai/api/auth/token/refresh")
        XCTAssertEqual(requests[1].method, .get)
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer old-refresh")
        XCTAssertNil(requests[1].headers["Cookie"])
        for request in requests[2..<8] {
            XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
            XCTAssertFalse(request.headers.values.contains(where: { $0.contains("new-refresh") || $0.contains("old-refresh") }))
        }
        XCTAssertEqual(requests[9].url.absoluteString, "https://www.kimi.ai/api/auth/token/refresh")
        XCTAssertEqual(requests[9].headers["Authorization"], "Bearer new-refresh")
        for request in requests.dropFirst(10) {
            XCTAssertEqual(request.headers["Authorization"], "Bearer newer-access")
        }
        XCTAssertEqual(KimiNativeSession.stripBearer("Bearer abc.def.ghi"), "abc.def.ghi")
        XCTAssertFalse(KimiNativeSession.valid(KimiNativeSession.stripBearer("invalid token")))
    }
    func testKimiRefreshRequiresConsentAndDoesNotLoop() async {
        for allowed in [false, true] {
            let http = MockHTTPClient([httpResponse(401), httpResponse(401)])
            let provider = ConsumerQuotaProvider(id: .kimi, http: http,
                nativeKimi: { KimiNativeSession(access: "old-access", refresh: "old-refresh") }, allowRefresh: { allowed })
            do { _ = try await provider.fetch(); XCTFail("Expected rejected login") } catch { }
            let requests = await http.capturedRequests()
            XCTAssertEqual(requests.count, allowed ? 2 : 1)
        }
    }
    func testKimiPersistsRotatedTokensAcrossProviderRestartsAndResetsOnNewLogin() async throws {
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let stats = httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0}}"#)
        let files = MemoryFiles()
        let store = KimiSessionStore(files: files)
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

        let http1 = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: #"{"access_token":"new-access","refresh_token":"Bearer new-refresh"}"#),
            subscription, stats, httpResponse(json: "{}")
        ])
        let provider1 = ConsumerQuotaProvider(
            id: .kimi,
            http: http1,
            nativeKimi: { KimiNativeSession(access: "old-access", refresh: "old-refresh") },
            allowRefresh: { true },
            kimiSessionStore: store,
            now: { fixedNow }
        )
        _ = try await provider1.fetch()
        let persisted1 = try XCTUnwrap(store.load(for: "Kimi desktop"))
        XCTAssertEqual(persisted1.accessToken, "new-access")
        XCTAssertEqual(persisted1.refreshToken, "new-refresh")
        XCTAssertEqual(persisted1.updatedAt, fixedNow)

        // Simulate app restart with a fresh provider reading the same stale native disk tokens.
        let http2 = MockHTTPClient([
            subscription, stats, httpResponse(json: "{}"),
            httpResponse(401),
            httpResponse(json: #"{"access_token":"newer-access","refresh_token":"Bearer newer-refresh"}"#),
            subscription, stats, httpResponse(json: "{}")
        ])
        let provider2 = ConsumerQuotaProvider(
            id: .kimi,
            http: http2,
            nativeKimi: { KimiNativeSession(access: "old-access", refresh: "old-refresh") },
            allowRefresh: { true },
            kimiSessionStore: store,
            now: { fixedNow }
        )
        _ = try await provider2.fetch()
        _ = try await provider2.fetch()
        let requests2 = await http2.capturedRequests()
        XCTAssertEqual(requests2[0].headers["Authorization"], "Bearer new-access")
        XCTAssertEqual(requests2[4].url.absoluteString, "https://www.kimi.ai/api/auth/token/refresh")
        XCTAssertEqual(requests2[4].headers["Authorization"], "Bearer new-refresh")
        XCTAssertEqual(requests2[5].headers["Authorization"], "Bearer newer-access")
        let persisted2 = try XCTUnwrap(store.load(for: "Kimi desktop"))
        XCTAssertEqual(persisted2.accessToken, "newer-access")
        XCTAssertEqual(persisted2.refreshToken, "newer-refresh")

        // New native login replaces/clears stale persisted entry.
        let http3 = MockHTTPClient([subscription, stats, httpResponse(json: "{}")])
        let provider3 = ConsumerQuotaProvider(
            id: .kimi,
            http: http3,
            nativeKimi: { KimiNativeSession(access: "fresh-access", refresh: "fresh-refresh") },
            allowRefresh: { true },
            kimiSessionStore: store,
            now: { fixedNow }
        )
        _ = try await provider3.fetch()
        let requests3 = await http3.capturedRequests()
        XCTAssertEqual(requests3[0].headers["Authorization"], "Bearer fresh-access")
        XCTAssertNil(store.load(for: "Kimi desktop"))
    }
    func testKimiProactivelyRefreshesExpiredJWTWithSessionHeadersAndClearsPersistedOn401() async throws {
        func makeJWT(exp: TimeInterval, sub: String, deviceID: String, ssid: String) throws -> String {
            func b64url(_ obj: [String: Any]) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: obj)
                return data.base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "=", with: "")
            }
            let h = try b64url(["alg": "HS256", "typ": "JWT"])
            let p = try b64url(["exp": Int(exp), "sub": sub, "device_id": deviceID, "ssid": ssid])
            return "\(h).\(p).sig"
        }

        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredAccess = try makeJWT(exp: fixedNow.timeIntervalSince1970 - 10, sub: "usr-1", deviceID: "dev-1", ssid: "ss-1")
        let freshRefresh = try makeJWT(exp: fixedNow.timeIntervalSince1970 + 86_400, sub: "usr-1", deviceID: "dev-1", ssid: "ss-1")
        let freshAccess = try makeJWT(exp: fixedNow.timeIntervalSince1970 + 900, sub: "usr-1", deviceID: "dev-2", ssid: "ss-2")
        let nextRefresh = try makeJWT(exp: fixedNow.timeIntervalSince1970 + 86_400, sub: "usr-1", deviceID: "dev-2", ssid: "ss-2")

        let files = MemoryFiles()
        let store = KimiSessionStore(files: files)
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let stats = httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0}}"#)
        let http = MockHTTPClient([
            httpResponse(json: #"{"access_token":"\#(freshAccess)","refresh_token":"Bearer \#(nextRefresh)"}"#),
            subscription, stats, httpResponse(json: "{}")
        ])
        let provider = ConsumerQuotaProvider(
            id: .kimi,
            http: http,
            nativeKimi: { KimiNativeSession(access: expiredAccess, refresh: freshRefresh) },
            allowRefresh: { true },
            kimiSessionStore: store,
            now: { fixedNow }
        )
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].url.absoluteString, "https://www.kimi.ai/api/auth/token/refresh")
        XCTAssertEqual(requests[0].headers["X-Traffic-Id"], "usr-1")
        XCTAssertEqual(requests[0].headers["x-msh-device-id"], "dev-1")
        XCTAssertEqual(requests[0].headers["x-msh-session-id"], "ss-1")
        XCTAssertEqual(requests[1].url.absoluteString, "https://www.kimi.ai/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscription")
        XCTAssertEqual(requests[1].headers["X-Traffic-Id"], "usr-1")
        XCTAssertEqual(requests[1].headers["x-msh-device-id"], "dev-2")
        XCTAssertEqual(requests[1].headers["x-msh-session-id"], "ss-2")
        XCTAssertNotNil(store.load(for: "Kimi desktop"))

        // If refresh returns 401 on another instance (at t+850s when freshAccess is expiring soon),
        // it retries fallback native refresh once, clears the matching persisted entry, and reports expiry.
        let httpFail = MockHTTPClient([httpResponse(401), httpResponse(401)])
        let providerFail = ConsumerQuotaProvider(
            id: .kimi,
            http: httpFail,
            nativeKimi: { KimiNativeSession(access: expiredAccess, refresh: freshRefresh) },
            allowRefresh: { true },
            kimiSessionStore: store,
            now: { fixedNow.addingTimeInterval(850) }
        )
        do {
            _ = try await providerFail.fetch()
            XCTFail("Expected authentication failure")
        } catch let failure as ProviderFailure {
            XCTAssertEqual(failure.kind, .authentication)
            XCTAssertEqual(failure.message, "Kimi session expired. Sign in to Kimi desktop again.")
        }
        let failRequests = await httpFail.capturedRequests()
        XCTAssertEqual(failRequests.count, 2)
        XCTAssertEqual(failRequests[0].headers["Authorization"], "Bearer \(nextRefresh)")
        XCTAssertEqual(failRequests[1].headers["Authorization"], "Bearer \(freshRefresh)")
        XCTAssertNil(store.load(for: "Kimi desktop"))
    }
    func testManusDailyDoesNotCombineFreeCreditsOrInventPlan() throws {
        let value = try ConsumerQuotaProvider.manus(httpResponse(json: #"{"totalCredits":1300,"freeCredits":1000,"refreshCredits":150,"maxRefreshCredits":300,"nextRefreshTime":"2026-11-14T00:00:00Z"}"#))
        XCTAssertEqual(value.windows.count, 2)
        XCTAssertEqual(value.windows.first?.kind, .daily)
        XCTAssertEqual(value.windows.first?.usedPercent, 50)
        XCTAssertEqual(value.windows.first?.remainingCount, 150)
        XCTAssertEqual(value.windows.first?.limitCount, 300)
        XCTAssertNotNil(value.windows.first?.resetsAt)
        XCTAssertEqual(value.windows[1].kind, .additional(id: "manus.monthly", title: "Monthly"))
        XCTAssertTrue(value.windows[1].isInactive)
        XCTAssertEqual(value.windows[1].inactiveDetail, "No Pro plan")
        XCTAssertEqual(value.availableMenuBarItems.map(\.metric), [.daily])
        XCTAssertNil(value.planName)
        XCTAssertNil(value.billingUsage)
        XCTAssertEqual(value.usageDetails, [
            ProviderUsageDetail(
                id: "manus.credits",
                title: "Additional Credits",
                value: "Free \(1000.formatted(.number)) · Total \(1300.formatted(.number))"
            )
        ])
        XCTAssertThrowsError(try ConsumerQuotaProvider.manus(httpResponse(json: #"{"totalCredits":1300,"freeCredits":1000}"#)))
        XCTAssertThrowsError(try ConsumerQuotaProvider.manus(httpResponse(401)))
    }
    func testManusSupportsDesktopAndChromeSessionSources() async throws {
        let manusResponse = httpResponse(json: #"{"totalCredits":1300,"freeCredits":1000,"refreshCredits":300,"maxRefreshCredits":300,"nextRefreshTime":"2026-11-16T15:00:00Z"}"#)
        let desktopRows = try String(data: JSONSerialization.data(withJSONObject: [
            ["name": "session_id", "host": "api.manus.im", "value": "desktop-sess", "encrypted": ""]
        ]), encoding: .utf8)!
        let desktopStore = WebSessionStore(
            sqlite: ConsumerCookieSQLite(rows: desktopRows),
            keychain: MemoryKeychain(),
            files: MemoryFiles(["~/Library/Application Support/Manus/Cookies": ""])
        )
        let desktopHTTP = MockHTTPClient([manusResponse])
        let desktopProvider = ConsumerQuotaProvider(id: .manus, http: desktopHTTP, sessions: desktopStore, method: { .desktop })
        let desktopSnapshot = try await desktopProvider.fetch()
        XCTAssertEqual(desktopSnapshot.credentialSource, "Manus desktop")
        XCTAssertNotNil(desktopSnapshot.historyIdentity)
        let desktopRequests = await desktopHTTP.capturedRequests()
        XCTAssertEqual(desktopRequests.first?.headers["Authorization"], "Bearer desktop-sess")

        let chromeRows = try String(data: JSONSerialization.data(withJSONObject: [
            ["name": "session_id", "host": ".manus.im", "value": "chrome-sess", "encrypted": ""]
        ]), encoding: .utf8)!
        let chromeStore = WebSessionStore(
            sqlite: ConsumerCookieSQLite(rows: chromeRows),
            keychain: MemoryKeychain(),
            files: MemoryFiles(["~/Library/Application Support/Google/Chrome/Default/Cookies": ""])
        )
        let chromeHTTP = MockHTTPClient([manusResponse])
        let chromeProvider = ConsumerQuotaProvider(id: .manus, http: chromeHTTP, sessions: chromeStore, method: { .chrome })
        let chromeSnapshot = try await chromeProvider.fetch()
        XCTAssertEqual(chromeSnapshot.credentialSource, "Chrome Default")
        XCTAssertNotNil(chromeSnapshot.historyIdentity)
        let chromeRequests = await chromeHTTP.capturedRequests()
        XCTAssertEqual(chromeRequests.first?.headers["Authorization"], "Bearer chrome-sess")
    }
    func testKimiBrowserMethodsLoadFromLevelDBAndCookieFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func physical(_ value: Data) -> Data {
            var checked = Data([1]); checked.append(value)
            let crc = ScopedLocalStorageReader.crc(checked)
            var result = Data((0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
            result.append(contentsOf: [UInt8(value.count & 255), UInt8(value.count >> 8), 1]); result.append(value)
            return result
        }
        func batch(sequence: UInt64, token: String) -> Data {
            var value = Data((0..<8).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
            value.append(contentsOf: [1, 0, 0, 0, 1])
            var key = Data("_https://www.kimi.ai\0".utf8); key.append(1); key.append(Data("access_token".utf8))
            value.append(UInt8(key.count)); value.append(key)
            let raw = Data([1]) + Data(token.utf8); value.append(UInt8(raw.count)); value.append(raw)
            return physical(value)
        }
        try Data("MANIFEST-000001\n".utf8).write(to: dir.appendingPathComponent("CURRENT"))
        try physical(Data([2, 1])).write(to: dir.appendingPathComponent("MANIFEST-000001"))
        try batch(sequence: 1, token: "edge-jwt").write(to: dir.appendingPathComponent("000001.log"))

        let edgeSession = try KimiNativeSession.load(
            method: .edge,
            includeRefresh: false,
            localStorageDirectories: [.edge: dir.path]
        )
        XCTAssertEqual(edgeSession.access, "edge-jwt")
        XCTAssertEqual(edgeSession.sourceLabel, "Edge Default")

        let cookieRows = try String(data: JSONSerialization.data(withJSONObject: [
            ["name": "kimi-auth", "host": ".kimi.ai", "value": "chrome-cookie-jwt", "encrypted": ""]
        ]), encoding: .utf8)!
        let chromeStore = WebSessionStore(
            sqlite: ConsumerCookieSQLite(rows: cookieRows),
            keychain: MemoryKeychain(),
            files: MemoryFiles(["~/Library/Application Support/Google/Chrome/Default/Cookies": ""])
        )
        let chromeSession = try KimiNativeSession.load(
            method: .chrome,
            includeRefresh: false,
            sessions: chromeStore,
            localStorageDirectories: [.chrome: dir.appendingPathComponent("missing").path]
        )
        XCTAssertEqual(chromeSession.access, "chrome-cookie-jwt")
        XCTAssertEqual(chromeSession.sourceLabel, "Chrome Default")
    }
    func testKimiUsesMembershipRatioIncludingZeroNotCodeQuotaOrWeekly() throws {
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let value = try ConsumerQuotaProvider.kimi(subscription: subscription,
            stats: httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0,"expireTime":"2026-12-01T00:00:00Z"}}"#))
        XCTAssertEqual(value.planName, "Free")
        XCTAssertEqual(value.windows.count, 2)
        XCTAssertEqual(value.windows.first?.kind, .monthly)
        XCTAssertEqual(value.windows.first?.kind.title, "Monthly")
        XCTAssertEqual(value.windows.first?.usedPercent, 0)
        XCTAssertEqual(value.windows[1].kind, .additional(id: "kimi.code.7d", title: "Kimi Code · Weekly"))
        XCTAssertTrue(value.windows[1].isInactive)
        XCTAssertEqual(value.windows[1].inactiveDetail, "No Kimi Code plan")
        XCTAssertEqual(value.availableMenuBarItems.map(\.metric), [.monthly])
        let coding = try ConsumerQuotaProvider.kimi(subscription: subscription,
            stats: httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_CODING","amountUsedRatio":0}}"#))
        XCTAssertEqual(coding.windows.first?.kind.rawValue, "additional:kimi.membership.FEATURE_CODING")
        let fallbackAndWeekly = try ConsumerQuotaProvider.kimi(
            subscription: httpResponse(json: #"{"subscription":{"goods":{"title":"Pro"}},"balances":[{"feature":"FEATURE_OMNI","amountUsedRatio":0.25,"expireTime":"2026-12-01T00:00:00Z"}]}"#),
            stats: httpResponse(json: #"{"ratelimitCode7d":{"amountUsedRatio":0.4,"expireTime":"2026-11-23T00:00:00Z"}}"#)
        )
        XCTAssertEqual(fallbackAndWeekly.windows.map(\.kind.rawValue), ["monthly", "additional:kimi.code.7d"])
        XCTAssertEqual(fallbackAndWeekly.windows.map(\.usedPercent), [25, 40])
        XCTAssertTrue(fallbackAndWeekly.windows.allSatisfy { !$0.isInactive })
        for invalid in ["true", "-1", "1.1", "null"] {
            XCTAssertThrowsError(try ConsumerQuotaProvider.kimi(subscription: subscription,
                stats: httpResponse(json: "{\"subscriptionBalance\":{\"feature\":\"FEATURE_OMNI\",\"amountUsedRatio\":\(invalid)}}")))
        }
    }
    func testScopedReaderCRCAndSnappyBounds() throws {
        // Raw Snappy: length 5, literal 'hello'.
        XCTAssertEqual(try ScopedLocalStorageReader.snappy(Data([5,16] + Array("hello".utf8))), Data("hello".utf8))
        XCTAssertThrowsError(try ScopedLocalStorageReader.snappy(Data([5,1,0])))
        XCTAssertThrowsError(try ScopedLocalStorageReader.snappy(Data([5,16,1])))
        XCTAssertThrowsError(try ScopedLocalStorageReader.table(Data()) { _,_ in })
        var bytes = Data([1,2,3,0]); bytes.append(contentsOf: [0,0,0,0])
        XCTAssertThrowsError(try ScopedLocalStorageReader.block(bytes, offset: 0, size: 3))
    }
    func testScopedReaderHonorsManifestAndTombstones() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func physical(_ value: Data) -> Data {
            var checked = Data([1]); checked.append(value)
            let crc = ScopedLocalStorageReader.crc(checked)
            var result = Data((0..<4).map { UInt8(truncatingIfNeeded: crc >> ($0 * 8)) })
            result.append(contentsOf: [UInt8(value.count & 255), UInt8(value.count >> 8), 1]); result.append(value)
            return result
        }
        func batch(sequence: UInt64, token: String?) -> Data {
            var value = Data((0..<8).map { UInt8(truncatingIfNeeded: sequence >> ($0 * 8)) })
            value.append(contentsOf: [1,0,0,0,token == nil ? 0 : 1])
            var key = Data("_https://www.kimi.ai\0".utf8); key.append(1); key.append(Data("access_token".utf8))
            value.append(UInt8(key.count)); value.append(key)
            if let token { let raw = Data([1]) + Data(token.utf8); value.append(UInt8(raw.count)); value.append(raw) }
            return physical(value)
        }
        try Data("MANIFEST-000001\n".utf8).write(to: dir.appendingPathComponent("CURRENT"))
        try physical(Data([2,3])).write(to: dir.appendingPathComponent("MANIFEST-000001")) // live log #3
        try batch(sequence: 100, token: "obsolete").write(to: dir.appendingPathComponent("000002.log"))
        try batch(sequence: 101, token: "current").write(to: dir.appendingPathComponent("000003.log"))
        let reader = ScopedLocalStorageReader()
        XCTAssertEqual(try reader.read(directory: dir, origin: "https://www.kimi.ai", names: ["access_token"]), ["access_token":"current"])
        XCTAssertTrue(try reader.read(directory: dir, origin: "https://other.test", names: ["access_token"]).isEmpty)
        var log = try Data(contentsOf: dir.appendingPathComponent("000003.log")); log.append(batch(sequence: 102, token: nil))
        try log.write(to: dir.appendingPathComponent("000003.log"))
        XCTAssertTrue(try reader.read(directory: dir, origin: "https://www.kimi.ai", names: ["access_token"]).isEmpty)
    }
}
private struct ConsumerCookieSQLite: SQLiteValueReading {
    let rows: String
    func queryValue(path: String, sql: String) throws -> String? { sql.contains("FROM meta") ? "24" : rows }
    func execute(path: String, sql: String) throws { XCTFail("Cookie stores must never be modified") }
}
