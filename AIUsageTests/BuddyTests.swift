import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

final class BuddyTests: XCTestCase {
    private func response(_ json: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(statusCode: status, headers: [:], body: Data(json.utf8))
    }
    private let base = "TCACA_code_035_ArVxJcGDsm"
    private let gift = "TCACA_code_006_DbXS0lrypC"
    private func summary(baseLeft: Double = 100, giftLeft: Double = 250) -> HTTPResponse {
        let data: [String: Any] = ["code": 0, "data": ["SubscriptionPackageName": "Free", "IsPaidUser": false,
            "Packages": [["PackageCode": base, "CycleTotalCapacity": 100, "CycleRemainCapacity": baseLeft, "CycleUsedCapacity": 100-baseLeft],
                         ["PackageCode": gift, "CycleTotalCapacity": 250, "CycleRemainCapacity": giftLeft, "CycleUsedCapacity": 250-giftLeft]]]]
        return HTTPResponse(statusCode: 200, headers: [:], body: try! JSONSerialization.data(withJSONObject: data))
    }
    func testSharedPoolIsNotSummedWithGiftOrPackageBreakdown() throws {
        let snapshot = try BuddyProvider.map(summary: summary(), packages: ["free": [
            ["PackageCode": base, "ResourceId": "fake-base", "CapacityType": 4, "CycleStartTime": "2026-11-01 00:00:00", "CycleEndTime": "2026-11-30 23:59:59", "DeductionEndTime": 2_000_000_000_000],
            ["PackageCode": gift, "ResourceId": "fake-gift", "DeductionEndTime": 1_800_000_000_000]
        ]], source: "CodeBuddy desktop", accountID: "fake-id")
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].kind, .monthly)
        XCTAssertEqual(snapshot.windows[0].remainingCount, 100)
        XCTAssertEqual(snapshot.windows[0].limitCount, 100)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.usageDetails.filter { $0.id.hasSuffix(".credits") }.count, 1)
        XCTAssertEqual(snapshot.usageDetails.first { $0.id.hasSuffix(".credits") }?.boundedProgress?.limit, 250)
        let giftExpiry = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "Gift credits expires" })
        let target = try XCTUnwrap(giftExpiry.targetDate)
        XCTAssertEqual(target.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(
            ProviderUsageDetail.countdownText(for: target, from: target.addingTimeInterval(-(2 * 86_400 + 3 * 3_600)), fallback: giftExpiry.value),
            "in 2d 3h"
        )
        XCTAssertEqual(
            ProviderUsageDetail.countdownText(for: target, from: target.addingTimeInterval(60), fallback: giftExpiry.value),
            giftExpiry.value
        )
        XCTAssertFalse(snapshot.windows.contains { $0.limitCount == 350 })
    }
    func testExhaustedFreeAndGiftQuotasRemainVisible() throws {
        let snapshot = try BuddyProvider.map(summary: summary(baseLeft: 0, giftLeft: 0), packages: [:], source: "Edge Default", accountID: "fake-id")
        XCTAssertEqual(snapshot.windows[0].usedPercent, 100)
        XCTAssertEqual(snapshot.windows[0].remainingCount, 0)
        XCTAssertEqual(snapshot.usageDetails.first?.boundedProgress?.used, 250)
    }
    func testMissingCapacityIsNotZeroAndDoesNotInventProgress() throws {
        let snapshot = try BuddyProvider.map(summary: response(#"{"code":0,"data":{"SubscriptionPackageName":"Free","Packages":[{"PackageCode":"new-pool","CycleRemainCapacity":0}]}}"#), packages: [:], source: "Chrome Default", accountID: "fake-id")
        XCTAssertTrue(snapshot.windows[0].isInactive)
        XCTAssertNil(snapshot.usageDetails[0].boundedProgress)
        XCTAssertEqual(snapshot.usageDetails[0].value, "0 credits left")
    }
    func testOptionalPackageFailurePreservesSummaryAndSourcesAreIsolated() throws {
        let first = try BuddyProvider.map(summary: summary(), packages: [:], partial: ["free"], source: "CodeBuddy desktop", accountID: "fake-id")
        let second = try BuddyProvider.map(summary: summary(), packages: [:], source: "Edge Default", accountID: "fake-id")
        XCTAssertNotEqual(first.historyIdentity, second.historyIdentity)
        XCTAssertEqual(first.windows[0].remainingCount, 100)
        XCTAssertTrue(first.usageDetails.contains { $0.id == "compatibility.buddy.free" })
    }
    func testRejectedAuthDoesNotBecomeFreePlanOrExposePayload() throws {
        XCTAssertThrowsError(try BuddyProvider.body(response(#"{"secret":"not-for-errors"}"#, status: 401))) { error in
            let failure = error as? ProviderFailure
            XCTAssertEqual(failure?.kind, .authentication)
            XCTAssertFalse(failure?.message.contains("not-for-errors") ?? true)
        }
        XCTAssertThrowsError(try BuddyProvider.body(response(#"{"code":0,"data":null}"#)))
    }
    func testTimestampKeepsShanghaiTimezoneAndMillis() throws {
        let date = try XCTUnwrap(BuddyProvider.date("2026-11-30 23:59:59"))
        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-11-30T15:59:59Z"))
        XCTAssertEqual(BuddyProvider.date(1_800_000_000_000)?.timeIntervalSince1970, 1_800_000_000)
    }
    func testDetailLayoutUsesSharedDisclosure() throws {
        let snapshot = try BuddyProvider.map(summary: summary(), packages: [:], source: "CodeBuddy desktop", accountID: "fake-id")
        XCTAssertTrue(ProviderDetailsLayout.canExpand(snapshot))
        XCTAssertEqual(ProviderDetailsLayout.summaryWindows(snapshot).count, 1)
        XCTAssertEqual(snapshot.dashboardSubtitle, "Shared account limits • WorkBuddy & CodeBuddy")
    }
}

private struct BuddyFixtureSQLite: SQLiteValueReading {
    let envelope: String
    func queryValue(path: String, sql: String) throws -> String? {
        XCTAssertEqual(path, "~/Library/Application Support/CodeBuddy/User/globalStorage/state.vscdb")
        XCTAssertTrue(sql.contains(BuddyAuthStore.tokenKey))
        return envelope
    }
    func execute(path: String, sql: String) throws { XCTFail("Source DB must stay read-only") }
}
private struct BuddyFixtureKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { XCTAssertEqual(service, "CodeBuddy Safe Storage"); return "fake-safe-storage" }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { XCTFail("No unrelated Keychain account"); return nil }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("No credential writes") }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws { XCTFail("No credential writes") }
}
private struct BuddyCookieSQLite: SQLiteValueReading {
    let rows: String
    func queryValue(path: String, sql: String) throws -> String? { sql.contains("FROM meta") ? "24" : rows }
    func execute(path: String, sql: String) throws { XCTFail("Cookie DB must remain read-only") }
}

extension BuddyTests {
    @MainActor func testCardsRenderWithSharedLayoutAndMonochromeIcons() throws {
        let buddy = try BuddyProvider.map(summary: summary(), packages: [:], source: "CodeBuddy desktop", accountID: "fake-personal")
        let zai = try ZAIProvider.map(subscription: response(#"{"code":200,"data":[]}"#), quota: nil, start: nil,
            auth: ZAICredential(token: "fake-api", zcodeToken: nil, email: "test@example.invalid", source: "Edge Default"))
        let neighbor = ProviderSnapshot(provider: .qwen, planName: "Free", windows: [QuotaWindow(kind: .daily, usedPercent: 0, resetsAt: nil, remainingCount: 100, limitCount: 100)], fetchedAt: Date())
        let root = VStack(spacing: 14) {
            ProviderSectionView(state: ProviderState(provider: .qwen, snapshot: neighbor))
            ProviderSectionView(state: ProviderState(provider: .buddy, snapshot: buddy))
            ProviderSectionView(state: ProviderState(provider: .zai, snapshot: zai))
        }.padding(12).frame(width: 440).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        XCTAssertLessThan(host.fittingSize.height, 520)
        host.setFrameSize(host.fittingSize); host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertTrue(ProviderIcon.templateImage(for: .buddy, size: 18).isTemplate)
        XCTAssertTrue(ProviderIcon.templateImage(for: .zai, size: 18).isTemplate)
    }
    func testFinalCycleBasePackageShowsExpiryWhenNoNextResetAndSubdomainCookiesWork() throws {
        let snapshot = try BuddyProvider.map(summary: summary(), packages: ["free": [
            ["PackageCode": base, "ResourceId": "fake-base", "CapacityType": 4,
             "CycleStartTime": "2026-11-01 00:00:00", "CycleEndTime": "2026-11-30 23:59:59",
             "DeductionEndTime": "2026-11-30 23:59:59"]
        ]], source: "CodeBuddy desktop", accountID: "fake-id")
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertTrue(snapshot.usageDetails.contains { $0.title == "Credits expires" })
        XCTAssertFalse(ProviderID.buddy.descriptor.installationIndicators.contains { $0.contains("WorkBuddy AI.app") })

        let store = WebSessionStore(
            sqlite: BuddyCookieSQLite(rows: #"[{"name":"session","host":".codebuddy.ai","value":"fake-sess","encrypted":""}]"#),
            keychain: BuddyFixtureKeychain(),
            files: MemoryFiles(["~/Library/Application Support/Microsoft Edge/Default/Cookies": ""])
        )
        XCTAssertEqual(try store.cookies(source: .edge, domain: "www.codebuddy.ai", names: ["session"]), "session=fake-sess")
    }
    func testDesktopUsesCurrentNestedAuthAndRejectsOtherRegions() throws {
        func store(domain: String) throws -> BuddyAuthStore {
            let session: [String: Any] = ["accessToken": "stale-legacy", "token": "another-stale-token",
                "auth": ["accessToken": "fake-current-token", "domain": domain],
                "account": ["uid": "fake-personal", "type": "personal"]]
            let encrypted = try ChromiumSafeStorageCodec.encrypt(JSONSerialization.data(withJSONObject: session), password: "fake-safe-storage")
            let envelope = try JSONSerialization.data(withJSONObject: ["type": "Buffer", "data": Array(encrypted)])
            return BuddyAuthStore(sqlite: BuddyFixtureSQLite(envelope: String(decoding: envelope, as: UTF8.self)), keychain: BuddyFixtureKeychain())
        }
        let credential = try store(domain: "www.codebuddy.ai").load(.desktop)
        XCTAssertEqual(credential.headers["Authorization"], "Bearer fake-current-token")
        XCTAssertEqual(credential.accountID, "fake-personal")
        XCTAssertEqual(credential.source, "CodeBuddy desktop")
        XCTAssertThrowsError(try store(domain: "copilot.tencent.com").load(.desktop))
        XCTAssertThrowsError(try store(domain: "www.codebuddy.ai").load(.cli))
    }
    func testFetchUsesSelectedCredentialAndExactReadOnlyRoutes() async throws {
        let http = MockHTTPClient([
            response(#"{"code":0,"data":{"accounts":[{"uid":"fake-personal","type":"personal"}]}}"#),
            summary(),
            response(#"{"code":0,"data":{"Accounts":[],"TotalCount":0}}"#),
            response(#"{"code":0,"data":{"Accounts":[],"TotalCount":0}}"#)
        ])
        let provider = BuddyProvider(http: http, method: { .desktop }, credential: { method in
            XCTAssertEqual(method, .desktop)
            return BuddyCredential(headers: ["Authorization": "Bearer fake-current"], host: "www.codebuddy.ai", source: "CodeBuddy desktop", fingerprint: "fake-scope", accountID: "fake-personal")
        })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.windows[0].remainingCount, 100)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "www.codebuddy.ai" && $0.headers["Authorization"] == "Bearer fake-current" })
        XCTAssertEqual(Set(requests.map { $0.url.path }), ["/console/accounts", "/billing/meter/get-user-resource-summary", "/billing/meter/get-user-resource-free-packages", "/billing/meter/get-user-resource-paid-packages"])
    }

    func testSortsAdditionalCreditPoolsAndPackagesBySoonestExpiryFIFO() throws {
        let addon = "TCACA_code_009_0XmEQc2xOf"
        let laterExpiry = 1_900_000_000_000
        let soonerExpiry = 1_800_000_000_000
        let summaryData: [String: Any] = [
            "code": 0,
            "data": [
                "SubscriptionPackageName": "Pro",
                "IsPaidUser": true,
                "Packages": [
                    ["PackageCode": base, "CycleTotalCapacity": 1000, "CycleRemainCapacity": 800],
                    ["PackageCode": addon, "CycleTotalCapacity": 500, "CycleRemainCapacity": 500],
                    ["PackageCode": gift, "CycleTotalCapacity": 200, "CycleRemainCapacity": 150]
                ]
            ]
        ]
        let summaryResp = HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: summaryData))
        let snapshot = try BuddyProvider.map(summary: summaryResp, packages: [
            "paid": [
                ["PackageCode": base, "ResourceId": "res-base", "CapacityType": 4, "CycleStartTime": "2026-11-01 00:00:00", "CycleEndTime": "2026-11-30 23:59:59", "DeductionEndTime": 2_000_000_000_000],
                ["PackageCode": addon, "ResourceId": "res-addon-later", "DeductionEndTime": laterExpiry, "CapacityRemainPrecise": 300],
                ["PackageCode": addon, "ResourceId": "res-addon-sooner", "DeductionEndTime": soonerExpiry + 100_000_000, "CapacityRemainPrecise": 200]
            ],
            "free": [
                ["PackageCode": gift, "ResourceId": "res-gift", "DeductionEndTime": soonerExpiry]
            ]
        ], source: "CodeBuddy desktop", accountID: "fake-id")

        let creditTitles = snapshot.usageDetails.filter { $0.id.hasSuffix(".credits") }.map(\.title)
        XCTAssertEqual(creditTitles, ["Gift credits", "Add-on"])

        let addonExpiries = snapshot.usageDetails.filter { $0.title == "Add-on expires" }.compactMap(\.targetDate)
        XCTAssertEqual(addonExpiries.count, 2)
        XCTAssertLessThan(addonExpiries[0], addonExpiries[1])
    }
}
