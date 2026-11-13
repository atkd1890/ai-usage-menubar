import XCTest
@testable import AIUsage

final class ConsumerQuotaTests: XCTestCase {
    func testKimiRefreshIsScopedRetriedOnceAndCachedOnlyForSameNativeSession() async throws {
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let stats = httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0}}"#)
        let http = MockHTTPClient([httpResponse(401), httpResponse(json: #"{"access_token":"new-access","refresh_token":"new-refresh"}"#), subscription, stats, subscription, stats])
        let provider = ConsumerQuotaProvider(id: .kimi, http: http,
            nativeKimi: { KimiNativeSession(access: "old-access", refresh: "old-refresh") }, allowRefresh: { true })
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[1].url.absoluteString, "https://www.kimi.ai/api/auth/token/refresh")
        XCTAssertEqual(requests[1].method, .get)
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer old-refresh")
        XCTAssertNil(requests[1].headers["Cookie"])
        for request in requests.dropFirst(2) {
            XCTAssertEqual(request.headers["Authorization"], "Bearer new-access")
            XCTAssertFalse(request.headers.values.contains(where: { $0.contains("new-refresh") || $0.contains("old-refresh") }))
        }
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
    func testManusDailyDoesNotCombineFreeCreditsOrInventPlan() throws {
        let value = try ConsumerQuotaProvider.manus(httpResponse(json: #"{"totalCredits":1300,"freeCredits":1000,"refreshCredits":150,"maxRefreshCredits":300,"nextRefreshTime":"2026-11-14T00:00:00Z"}"#))
        XCTAssertEqual(value.windows.first?.kind, .daily)
        XCTAssertEqual(value.windows.first?.usedPercent, 50)
        XCTAssertNotNil(value.windows.first?.resetsAt)
        XCTAssertNil(value.planName)
        XCTAssertNil(value.billingUsage)
        XCTAssertThrowsError(try ConsumerQuotaProvider.manus(httpResponse(json: #"{"totalCredits":1300,"freeCredits":1000}"#)))
        XCTAssertThrowsError(try ConsumerQuotaProvider.manus(httpResponse(401)))
    }
    func testKimiUsesMembershipRatioIncludingZeroNotCodeQuotaOrWeekly() throws {
        let subscription = httpResponse(json: #"{"subscription":{"goods":{"title":"Free"}}}"#)
        let value = try ConsumerQuotaProvider.kimi(subscription: subscription,
            stats: httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_OMNI","amountUsedRatio":0,"expireTime":"2026-12-01T00:00:00Z"}}"#))
        XCTAssertEqual(value.planName, "Free")
        XCTAssertEqual(value.windows.first?.kind, .totalUsage)
        XCTAssertEqual(value.windows.first?.usedPercent, 0)
        XCTAssertThrowsError(try ConsumerQuotaProvider.kimi(subscription: subscription,
            stats: httpResponse(json: #"{"subscriptionBalance":{"feature":"FEATURE_CODING","amountUsedRatio":0}}"#)))
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
