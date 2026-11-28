import XCTest
@testable import AIUsage

final class MuseTests: XCTestCase {
    private var free: HTTPResponse { httpResponse(json: #"1:{"success":true,"subscription":{"tier":{"name":"Muse Free"},"usage":{"percentUsed":0,"resetsAt":1795183771},"topupTotal":0,"topupBalance":0}}"#) }
    func testFreeWeeklyAndPaidTopupAreSeparateAndUseMoneyUnits() throws {
        let value = try MuseProvider.map(free, historyID: "muse-session:" + String(repeating: "a", count: 64))
        XCTAssertEqual(value.planName, "Free")
        XCTAssertEqual(value.windows.first?.usedPercent, 0)
        XCTAssertEqual(value.windows.first?.kind, .weekly)
        XCTAssertNotNil(value.windows.first?.resetsAt)
        XCTAssertFalse(value.hasAdditionalUsageSection)
        XCTAssertNotNil(value.historyIdentity)
        XCTAssertNil(value.identityEmail)
        let paid = try MuseProvider.map(httpResponse(json: #"1:{"success":true,"subscription":{"usage":{"percentUsed":99},"topupTotal":10000000,"topupBalance":2500000}}"#), historyID: "test")
        XCTAssertEqual(paid.prepaidBalance?.amount, 2.5)
        XCTAssertEqual(paid.billingUsage, .boundedSpend(usedAmount: 7.5, limitAmount: 10, currencyCode: "USD"))
        XCTAssertTrue(paid.hasAdditionalUsageSection)
    }
    func testCachedActionDoesNotRediscoverAndSendsOnlyReadOnlyBody() async throws {
        let http = MockHTTPClient([free, free])
        let provider = MuseProvider(http: http, cookies: { "hatch_sess=synthetic; hatch_gw=gateway" }, action: nil,
            pageScripts: { _ in XCTFail("No discovery on working action"); return [] }, saveAction: { _ in })
        _ = try await provider.fetch(); _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.url.absoluteString == "https://muse.ai/" && $0.method == .post })
        XCTAssertEqual(requests.first?.body, Data(#"[{"includeAgreement":true}]"#.utf8))
        XCTAssertEqual(requests.first?.headers["Next-Action"], MuseProvider.verifiedAction)
    }
    func testStaleActionDiscoversOnlyNamedSubscriptionActionWithoutAssetCookies() async throws {
        let freshID = String(repeating: "b", count: 40)
        let chunk = "createServerReference(\"\(freshID)\",callServer,void 0,findSourceMapURL,\"fetchSubscriptionAction\")"
        let http = MockHTTPClient([httpResponse(404), httpResponse(json: chunk), free, free])
        let provider = MuseProvider(http: http, cookies: { "hatch_sess=synthetic" }, action: String(repeating: "a", count: 40),
            pageScripts: { _ in ["/_next/static/chunks/settings.js", "https://evil.test/token", "/api/chat"] }, saveAction: { _ in })
        _ = try await provider.fetch(); _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url.path, "/_next/static/chunks/settings.js")
        XCTAssertNil(requests[1].headers["Cookie"])
        XCTAssertEqual(requests[2].headers["Next-Action"], freshID)
        XCTAssertEqual(requests[3].headers["Next-Action"], freshID)
    }
    func testScriptScannerDiscardsInlineBootstrapAndExternalURLsAcrossChunkBoundaries() {
        var collector = MuseScriptSources()
        for text in [
            "<html><scr",
            "ipt>private chat <script src='/_next/static/chunks/private.js'>",
            "</script><script src=\"/_next/static/chunks/app.js\"",
            "></script><script src=\"/_next/static/immutable/chunks/1a4i9fvziyigq.js\"",
            "></script><script src='https://evil.test/_next/static/chunks/evil.js'></script>"
        ] {
            collector.consume(Data(text.utf8))
        }
        XCTAssertEqual(collector.paths, [
            "/_next/static/chunks/app.js",
            "/_next/static/immutable/chunks/1a4i9fvziyigq.js"
        ])
        XCTAssertTrue(MuseScriptSources.allowed("/_next/static/immutable/chunks/1a4i9fvziyigq.js"))
        XCTAssertFalse(MuseScriptSources.allowed("/_next/static/chunks/../api/chat"))
        XCTAssertFalse(MuseScriptSources.allowed("/_next/static/immutable/chunks/../api/chat"))
        XCTAssertEqual(
            MuseScriptSources.chunkPaths(in: #"["static/immutable/chunks/settings.js","static/chunks/other.js"]"#),
            ["/_next/static/immutable/chunks/settings.js", "/_next/static/chunks/other.js"]
        )
        XCTAssertNil(MuseProvider.actionID(in: "createServerReference(\"" + String(repeating: "a", count: 40) + "\",call,\"sendMessageAction\")"))
    }
    func testImmutableChunkLoaderRecoversFrom409RotatedActionWithoutAssetCookies() async throws {
        let freshID = String(repeating: "c", count: 40)
        let loaderChunk = #"[434304,e=>{e.v(t=>Promise.all(["static/immutable/chunks/settings.js"].map(t=>e.l(t))))}]"#
        let appChunk = #"t.A(434304).then(({Settings:s})=>s)"#
        let settingsChunk = "createServerReference(\"\(freshID)\",callServer,void 0,findSourceMapURL,\"fetchSubscriptionAction\")"
        let http = RoutedHTTPClient([
            "https://muse.ai/": [
                httpResponse(409, json: #"{"error":"Server Action unavailable."}"#, headers: ["x-nextjs-action-not-found": "1"]),
                free
            ],
            "https://muse.ai/_next/static/immutable/chunks/loader.js": [httpResponse(json: loaderChunk)],
            "https://muse.ai/_next/static/immutable/chunks/app.js": [httpResponse(json: appChunk)],
            "https://muse.ai/_next/static/immutable/chunks/settings.js": [httpResponse(json: settingsChunk)]
        ])
        let provider = MuseProvider(
            http: http,
            cookies: { "hatch_sess=synthetic; hatch_gw=gateway" },
            action: String(repeating: "a", count: 40),
            pageScripts: { _ in [
                "/_next/static/immutable/chunks/loader.js",
                "/_next/static/immutable/chunks/app.js"
            ] },
            saveAction: { _ in }
        )
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.planName, "Free")
        let requests = await http.capturedRequests()
        let chunkRequests = requests.filter { $0.url.path.hasPrefix("/_next/") }
        XCTAssertEqual(chunkRequests.count, 3)
        XCTAssertTrue(chunkRequests.allSatisfy { $0.headers["Cookie"] == nil })
        let postActions = requests.filter { $0.method == .post }.compactMap { $0.headers["Next-Action"] }
        XCTAssertEqual(postActions, [String(repeating: "a", count: 40), freshID])
    }
    func testMalformedNullAndRejectedResponsesDoNotBecomeFullAllowance() {
        for value in ["null", "true", "-1", "101"] {
            XCTAssertThrowsError(try MuseProvider.map(httpResponse(json: "1:{\"success\":true,\"subscription\":{\"usage\":{\"percentUsed\":\(value)}}}"), historyID: "test"))
        }
        for code in [401,403,429,500] { XCTAssertThrowsError(try MuseProvider.map(httpResponse(code), historyID: "test")) }
    }
    @MainActor func testMuseIsSeededOnceAndManualDisableRemainsRespected() {
        let suite = "MusePreferences." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertTrue(preferences.isTracking(.muse))
        preferences.setTracking(false, for: .muse)
        XCTAssertFalse(AppPreferences(defaults: defaults).isTracking(.muse))
        XCTAssertEqual(ProviderLoginMethod.supported(for: .muse), [.edge, .chrome])
    }
    func testMuseChromeMethodUsesChromeSessionAndCredentialSource() async throws {
        let rows = try String(data: JSONSerialization.data(withJSONObject: [
            ["name": "hatch_sess", "host": ".muse.ai", "value": "chrome-sess", "encrypted": ""],
            ["name": "hatch_gw", "host": ".muse.ai", "value": "chrome-gw", "encrypted": ""]
        ]), encoding: .utf8)!
        let store = WebSessionStore(
            sqlite: MuseCookieSQLite(rows: rows),
            keychain: MemoryKeychain(),
            files: MemoryFiles(["~/Library/Application Support/Google/Chrome/Default/Cookies": ""])
        )
        let http = MockHTTPClient([free])
        let provider = MuseProvider(http: http, method: { .chrome }, sessions: store, action: nil, pageScripts: { _ in [] }, saveAction: { _ in })
        let snapshot = try await provider.fetch()
        XCTAssertEqual(snapshot.credentialSource, "Chrome Default")
        XCTAssertNotNil(snapshot.historyIdentity)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.first?.headers["Cookie"], "hatch_gw=chrome-gw; hatch_sess=chrome-sess")
    }
}
private struct MuseCookieSQLite: SQLiteValueReading {
    let rows: String
    func queryValue(path: String, sql: String) throws -> String? { sql.contains("FROM meta") ? "24" : rows }
    func execute(path: String, sql: String) throws { XCTFail("Cookie stores must never be modified") }
}
