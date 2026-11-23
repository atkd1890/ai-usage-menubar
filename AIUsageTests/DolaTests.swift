import CryptoKit
import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

final class DolaTests: XCTestCase {
    private let history = "dola-session:" + String(repeating: "a", count: 64)
    private var overview: HTTPResponse {
        httpResponse(json: #"{"code":0,"data":{"member_info":{"hasActiveSubscription":false,"has_business_subscription":false,"has_team_subscription":false,"hasEnterpriseSubscription":false,"usr_type":1},"current_subscription":{"display":{"product_name":"Dola Membership"},"end_time":0,"next_deduct_time":0},"entitlements":[],"window_limit_section":{},"enterprise_window_limit_section":{"entitlement_count":0,"usage_exhausted":false,"window_limit_groups":[]}}}"#)
    }
    private var supplemental: [String: HTTPResponse] {
        ["status": httpResponse(json: #"{"code":0,"data":{"has_subscribed":false,"is_subscribing":false}}"#),
         "usage": httpResponse(json: #"{"code":0,"data":{"total_used_percent":0,"window_limit_groups":[]}}"#),
         "ogf": httpResponse(json: #"{"code":0,"data":{"quota_left":0,"total_quota":0}}"#)]
    }
    func testNoPlanUsesSharedQuotaPlaceholderWithoutRawDefaultMetadata() throws {
        let snapshot = try DolaProvider.map(overview: overview, supplemental: supplemental, historyID: history)
        XCTAssertEqual(snapshot.planName, "Free")
        XCTAssertEqual(snapshot.historyIdentity, history)
        XCTAssertNil(snapshot.identityEmail)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertTrue(snapshot.windows[0].isInactive)
        XCTAssertEqual(snapshot.windows[0].kind.title, "Usage")
        XCTAssertEqual(snapshot.windows[0].inactiveDetail, "No plan")
        XCTAssertTrue(snapshot.usageDetails.isEmpty)
        XCTAssertFalse(ProviderDetailsLayout.canExpand(snapshot))
        XCTAssertNil(snapshot.usageDetails.first { $0.id == "dola.ogf" })
        XCTAssertFalse(snapshot.windows.contains { $0.isBoundedActive })
        XCTAssertFalse(snapshot.usageDetails.contains { $0.id == "dola.end_time" })
        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
    }
    func testPositiveFreeQuotaUsesRealCapacityEvenWithoutSubscription() throws {
        var responses = supplemental
        responses["ogf"] = httpResponse(json: #"{"code":0,"data":{"quota_left":3,"total_quota":10}}"#)
        let snapshot = try DolaProvider.map(overview: overview, supplemental: responses, historyID: history)
        let quota = try XCTUnwrap(snapshot.windows.first { $0.kind.rawValue == "additional:dola.ogf" })
        XCTAssertEqual(quota.usedPercent, 70)
        XCTAssertEqual(quota.countText(for: .remaining), "3 / 10")
        XCTAssertEqual(quota.countText(for: .used), "7 / 10")
        XCTAssertNil(quota.resetsAt)
        XCTAssertTrue(quota.isBoundedActive)
    }
    @MainActor func testProfileEmailIsReadOnceAndDoesNotUseAnotherSource() async throws {
        let name = "DolaIdentity." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let cycle = [overview, supplemental["status"]!, supplemental["usage"]!, supplemental["ogf"]!]
        let profile = httpResponse(json: #"{"message":"success","data":{"email":"person@example.invalid"}}"#)
        let http = MockHTTPClient(cycle + [profile] + cycle)
        let cache = AccountIdentityCache(provider: .dola, source: "selected", suiteName: name)
        let provider = DolaProvider(http: http, method: { .edge }, identity: cache, cookies: { source in
            XCTAssertEqual(source, .edge)
            return "sessionid=fake-account"
        })
        let first = try await provider.fetch(), second = try await provider.fetch()
        XCTAssertEqual(first.identityEmail, "person@example.invalid")
        XCTAssertEqual(second.identityEmail, first.identityEmail)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.filter { $0.url.path.contains("/passport/account/info/v2") }.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "www.dola.com" })
        XCTAssertNil(DolaProvider.profileEmail(httpResponse(json: #"{"message":"success","data":{"email":""}}"#)))
    }
    func testPartialSupplementaryFailureRetainsAccountAndOtherCounters() throws {
        var responses = supplemental
        responses["usage"] = httpResponse(500)
        let snapshot = try DolaProvider.map(overview: overview, supplemental: responses, historyID: history)
        XCTAssertTrue(snapshot.hasDiagnosticWarnings)
        XCTAssertTrue(snapshot.windows.first?.isInactive == true)
        XCTAssertTrue(snapshot.hasPanelContent)
    }
    func testDetailsOnlyPaidAccountKeepsPlanAndWarnsForUnknownEntitlements() throws {
        let paid = httpResponse(json: #"{"code":0,"data":{"member_info":{"hasActiveSubscription":true},"current_subscription":{"display":{"product_name":"Dola Plus"}},"entitlements":[{"future_shape":true}]}}"#)
        let snapshot = try DolaProvider.map(overview: paid, supplemental: supplemental, historyID: history)
        XCTAssertEqual(snapshot.planName, "Dola Plus")
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 0)
        XCTAssertTrue(snapshot.hasPanelContent)
        XCTAssertTrue(snapshot.hasDiagnosticWarnings)
    }
    func testExpiredLoginRateLimitAndMalformedResponseFailWithCorrectKinds() {
        for (response, kind) in [(httpResponse(json: #"{"code":710012001,"data":null}"#), ProviderFailureKind.authentication),
                                 (httpResponse(429), .rateLimited),
                                 (httpResponse(json: #"{"code":0,"data":null}"#), .invalidResponse)] {
            XCTAssertThrowsError(try DolaProvider.body(response)) { error in
                XCTAssertEqual((error as? ProviderFailure)?.kind, kind)
            }
        }
    }
    func testDesktopEncryptedCookieUsesEmbeddedBrowserKeyNotOuterAppKey() throws {
        let password = "fake-browser-safe-storage"
        let host = ".dola.com"
        let plain = Data(SHA256.hash(data: Data(host.utf8))) + Data("fake-desktop-session".utf8)
        let encrypted = try ChromiumSafeStorageCodec.encrypt(plain, password: password)
        let rows = try String(data: JSONSerialization.data(withJSONObject: [[
            "host": host, "name": "sessionid", "value": "",
            "encrypted": encrypted.map { String(format: "%02x", $0) }.joined()
        ]]), encoding: .utf8)!
        let keys = MemoryKeychain(generic: ["Cici Browser Safe Storage": password, "Cici Safe Storage": "wrong-outer-app-key"])
        let store = WebSessionStore(sqlite: DolaCookieFixtureSQLite(rows: rows), keychain: keys,
            files: MemoryFiles(["~/Library/Application Support/Cici/Default/Cookies": ""]))
        XCTAssertEqual(try store.cookies(source: .dolaDesktop, domain: "dola.com", names: DolaProvider.cookieNames), "sessionid=fake-desktop-session")
        XCTAssertEqual(keys.genericReads, ["Cici Browser Safe Storage"])
    }
    func testSourcesAreExplicitAndUnsupportedMethodsDoNotFallback() throws {
        XCTAssertEqual(try DolaProvider.source(for: .desktop).0, .dolaDesktop)
        XCTAssertEqual(try DolaProvider.source(for: .edge).0, .edge)
        XCTAssertEqual(try DolaProvider.source(for: .chrome).0, .chrome)
        XCTAssertThrowsError(try DolaProvider.source(for: .cli))
        XCTAssertEqual(WebSessionSource.dolaDesktop.directory, "Cici/Default")
        XCTAssertEqual(WebSessionSource.dolaDesktop.keychainService, "Cici Browser Safe Storage")
        XCTAssertEqual(ProviderLoginMethod.supported(for: .dola), [.desktop, .edge, .chrome])
        XCTAssertFalse(DolaProvider.cookieNames.contains("LARK_SUITE_ACCESS_TOKEN"))
        XCTAssertThrowsError(try WebSessionStore().cookies(source: .edge, domain: "dola.com", names: ["LARK_SUITE_ACCESS_TOKEN"]))
        XCTAssertThrowsError(try WebSessionStore().cookies(source: .dolaDesktop, domain: "muse.ai", names: ["hatch_sess"]))
    }
    func testFetcherUsesOnlySelectedSourceAndReadOnlyAllowlistedRoutes() async throws {
        let http = MockHTTPClient([overview, supplemental["status"]!, supplemental["usage"]!, supplemental["ogf"]!])
        let provider = DolaProvider(http: http, method: { .chrome }, cookies: { source in
            XCTAssertEqual(source, .chrome)
            return "sessionid=fake-dola-session; passport_csrf_token=fake-csrf"
        })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.credentialSource, "Chrome Default")
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(Set(requests.map(\.url.path)), Set(DolaProvider.paths.values.map { URL(string: "https://www.dola.com" + $0)!.path }))
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "www.dola.com" && $0.url.scheme == "https" && $0.method == .post })
        XCTAssertTrue(requests.allSatisfy { $0.body == Data(#"{"product_line":"membership"}"#.utf8) })
        XCTAssertTrue(requests.allSatisfy { !($0.headers["Cookie"] ?? "").contains("LARK") })
    }
    func testCookieStorageFailureNamesDolaAndPreservesOSPermissionGuidance() async {
        let http = MockHTTPClient([])
        let provider = DolaProvider(http: http, method: { .desktop }, cookies: { source in
            XCTAssertEqual(source, .dolaDesktop)
            throw ProviderFailure(.storage, "Synthetic foreign provider decrypt failure")
        })
        do { _ = try await provider.fetch(); XCTFail("Expected storage failure") }
        catch {
            let failure = error as? ProviderFailure
            XCTAssertEqual(failure?.kind, .storage)
            XCTAssertTrue(failure?.message.contains("Dola desktop") == true)
            XCTAssertFalse(failure?.message.contains("Gemini") == true)
        }
        let permissionProvider = DolaProvider(http: http, method: { .edge }, cookies: { _ in
            throw ProviderFailure(.storage, "macOS denied access to the selected app or browser data. Allow AI Usage access in Privacy & Security, then refresh.")
        })
        do { _ = try await permissionProvider.fetch(); XCTFail("Expected permission denial") }
        catch {
            let failure = error as? ProviderFailure
            XCTAssertEqual(failure?.kind, .storage)
            XCTAssertTrue(failure?.message.contains("Privacy & Security") == true)
        }
        let requests = await http.capturedRequests()
        XCTAssertTrue(requests.isEmpty)
    }
    @MainActor func testDefaultMetricIsUsageAndEmailStabilizesAccountLabelAcrossCookieRotation() async throws {
        XCTAssertEqual(ProviderID.dola.defaultMenuBarMetric, .additional(id: "dola.usage", title: "Usage"))
        let cycle = [overview, supplemental["status"]!, supplemental["usage"]!, supplemental["ogf"]!]
        let profile = httpResponse(json: #"{"message":"success","data":{"email":"person@example.invalid"}}"#)
        let firstSuite = "DolaStableIdentity1." + UUID().uuidString
        let secondSuite = "DolaStableIdentity2." + UUID().uuidString
        let firstDefaults = UserDefaults(suiteName: firstSuite)!
        let secondDefaults = UserDefaults(suiteName: secondSuite)!
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }
        let firstProvider = DolaProvider(http: MockHTTPClient(cycle + [profile]), method: { .edge },
            identity: AccountIdentityCache(provider: .dola, source: "selected", suiteName: firstSuite),
            cookies: { _ in "sessionid=cookie-one" })
        let secondProvider = DolaProvider(http: MockHTTPClient(cycle + [profile]), method: { .edge },
            identity: AccountIdentityCache(provider: .dola, source: "selected", suiteName: secondSuite),
            cookies: { _ in "sessionid=cookie-two" })
        let first = try await firstProvider.fetch()
        let second = try await secondProvider.fetch()
        XCTAssertEqual(first.accountLabel, second.accountLabel)
        XCTAssertEqual(first.historyIdentity, "person@example.invalid")
        XCTAssertEqual(second.historyIdentity, "person@example.invalid")
    }
    func testRejectedSelectedLoginDoesNotFetchSupplementalOrFallback() async {
        let http = MockHTTPClient([httpResponse(json: #"{"code":710012001,"data":null}"#)])
        let provider = DolaProvider(http: http, method: { .desktop }, cookies: { source in
            XCTAssertEqual(source, .dolaDesktop)
            return "sessionid=fake-desktop"
        })
        do { _ = try await provider.fetch(); XCTFail("Expected authentication error") }
        catch { XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication) }
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }
    @MainActor func testNoPlanCardRendersCompactlyBesideExistingProvider() throws {
        let snapshot = try DolaProvider.map(overview: overview, supplemental: supplemental, historyID: history)
        let other = ProviderSnapshot(provider: .minimax, planName: "Free", windows: [
            QuotaWindow(kind: .session, usedPercent: 0, resetsAt: nil, isInactive: true, inactiveDetail: "No Token Plan"),
            QuotaWindow(kind: .weekly, usedPercent: 0, resetsAt: nil, isInactive: true, inactiveDetail: "No Token Plan")
        ], fetchedAt: Date())
        let root = VStack(spacing: 14) {
            ProviderSectionView(state: ProviderState(provider: .minimax, snapshot: other))
            ProviderSectionView(state: ProviderState(provider: .dola, snapshot: snapshot))
        }.padding(12).frame(width: 440).fixedSize(horizontal: false, vertical: true).environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        XCTAssertLessThan(size.height, 330, "Two unavailable cards must not turn into a raw metadata list")
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
    @MainActor func testSeedingRespectsOptOutAfterFirstLaunch() {
        let name = "DolaTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppPreferences(defaults: defaults)
        XCTAssertTrue(first.isTracking(.dola))
        first.setTracking(false, for: .dola)
        XCTAssertFalse(AppPreferences(defaults: defaults).isTracking(.dola))
    }
    func testSubscriptionDatesUseTargetDateForCountdownAndTooltipFallback() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let end = now.addingTimeInterval(3 * 86_400 + 5 * 3_600)
        let billing = now.addingTimeInterval(4 * 3_600 + 15 * 60)
        let paid = httpResponse(json: """
        {"code":0,"data":{"member_info":{"hasActiveSubscription":true},"current_subscription":{"display":{"product_name":"Dola Plus"},"end_time":\(Int(end.timeIntervalSince1970)),"next_deduct_time":\(Int(billing.timeIntervalSince1970))}}}
        """)
        let snapshot = try DolaProvider.map(overview: paid, supplemental: supplemental, historyID: history, now: now)
        let ends = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "Subscription ends" })
        let next = try XCTUnwrap(snapshot.usageDetails.first { $0.title == "Next billing" })
        XCTAssertEqual(try XCTUnwrap(ends.targetDate).timeIntervalSince1970, end.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(next.targetDate).timeIntervalSince1970, billing.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(ends.targetDate), from: now, fallback: ends.value), "in 3d 5h")
        XCTAssertEqual(ProviderUsageDetail.countdownText(for: try XCTUnwrap(next.targetDate), from: now, fallback: next.value), "in 4h 15m")
    }
}

private struct DolaCookieFixtureSQLite: SQLiteValueReading {
    let rows: String
    func queryValue(path: String, sql: String) throws -> String? { sql.contains("FROM meta") ? "24" : rows }
    func execute(path: String, sql: String) throws { XCTFail("Cookie DB must remain read-only") }
}
