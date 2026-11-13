import XCTest
@testable import AIUsage

final class WebUsageProviderTests: XCTestCase {
    private func sessions(domain: String, names: [String: String], source: WebSessionSource = .edge) -> WebSessionStore {
        let rows = names.map { ["name": $0.key, "host": "." + domain, "value": $0.value, "encrypted": ""] }
        let json = String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!
        return WebSessionStore(sqlite: CookieSQLite(rows: json), keychain: MemoryKeychain(),
            files: MemoryFiles(["~/Library/Application Support/\(source.directory)/Cookies":""]))
    }
    func testRejectsUnexpectedDomainsNamesAndCrossProductDesktopStores() {
        let store = sessions(domain: "claude.ai", names: ["sessionKey":"test"])
        XCTAssertThrowsError(try store.cookies(source: .edge, domain: "evil.test", names: ["sessionKey"]))
        XCTAssertThrowsError(try store.cookies(source: .edge, domain: "claude.ai", names: ["history"]))
        XCTAssertThrowsError(try store.cookies(source: .claudeDesktop, domain: "chatgpt.com", names: ["__Secure-next-auth.session-token"]))
    }
    func testReadsChunkedSessionAndRejectsHeaderInjection() throws {
        let store = sessions(domain: "chatgpt.com", names: ["__Secure-next-auth.session-token.0":"first", "__Secure-next-auth.session-token.1":"second"])
        let cookie = try store.cookies(source: .edge, domain: "chatgpt.com", names: ["__Secure-next-auth.session-token.0","__Secure-next-auth.session-token.1"])
        XCTAssertEqual(cookie, "__Secure-next-auth.session-token.0=first; __Secure-next-auth.session-token.1=second")
        let invalid = sessions(domain: "cursor.com", names: ["WorkosCursorSessionToken":"bad; another=value"])
        XCTAssertThrowsError(try invalid.cookies(source: .edge, domain: "cursor.com", names: ["WorkosCursorSessionToken"]))
    }
    func testCodexSessionLoadsQuotaAndAccountAndScopesResetRead() async throws {
        let http = MockHTTPClient([
            httpResponse(json: #"{"accessToken":"browser-token","user":{"email":"test@example.com"}}"#),
            httpResponse(json: #"{"email":"test@example.com","account_id":"account-test","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":41,"limit_window_seconds":18000,"reset_after_seconds":3000}}}"#),
            httpResponse(404)])
        let provider = WebUsageProvider(id: .codex, source: .edge,
            sessions: sessions(domain: "chatgpt.com", names: ["__Secure-next-auth.session-token":"test-session"]), http: http)
        let value = try await provider.fetch()
        XCTAssertEqual(value.accountLabel, "test@example.com")
        XCTAssertEqual(value.credentialSource, "Edge Default")
        XCTAssertEqual(value.windows.first?.usedPercent, 41)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(requests[0].headers["Authorization"])
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer browser-token")
        XCTAssertEqual(requests[2].headers["ChatGPT-Account-ID"], "account-test")
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "chatgpt.com" })
    }
    func testRejectedWebSessionNeverFallsBackAndAccountMismatchFails() async {
        for responses in [
            [httpResponse(403)],
            [httpResponse(json: #"{"accessToken":"test","user":{"email":"one@example.com"}}"#),
             httpResponse(json: #"{"email":"other@example.com"}"#)]
        ] {
            let http = MockHTTPClient(responses)
            let provider = WebUsageProvider(id: .codex, source: .edge,
                sessions: sessions(domain: "chatgpt.com", names: ["__Secure-next-auth.session-token":"test"]), http: http)
            do { _ = try await provider.fetch(); XCTFail("Expected authentication failure") }
            catch { XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication) }
            let requests = await http.capturedRequests()
            XCTAssertEqual(requests.count, responses.count)
        }
    }
    func testSelectedBrowserDoesNotInvokeLocalProvider() async throws {
        let local = CountedSource(id: .codex)
        let edge = CountedSource(id: .codex)
        let chrome = CountedSource(id: .codex)
        let provider = CredentialSelectingProvider(local: local, method: { .edge }, edge: edge, chrome: chrome)
        _ = try await provider.fetch()
        let counts = await [local.count, edge.count, chrome.count]
        XCTAssertEqual(counts, [0,1,0])
    }
    func testClaudeWebSelectsChatOrganizationAndRetainsFableAndResets() async throws {
        let chatID = "11111111-1111-4111-8111-111111111111"
        let http = MockHTTPClient([
            httpResponse(json: #"[{"uuid":"22222222-2222-4222-8222-222222222222","capabilities":["api"]},{"uuid":"11111111-1111-4111-8111-111111111111","name":"Selected Chat account","capabilities":["chat","claude_max"],"analytics_subscription_plan":"claude_max 5x","rate_limit_tier":"default_claude_max_5x"}]"#),
            httpResponse(json: #"{"five_hour":{"utilization":24},"seven_day":{"utilization":51},"limits":[{"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Fable"}}}],"cedar_ember":{"eligible":true,"grants":[{"id":"test-grant","resets_left":3}]},"spend":{"enabled":false}}"#)])
        let provider = WebUsageProvider(id: .claude, source: .edge,
            sessions: sessions(domain: "claude.ai", names: ["sessionKey":"test"]), http: http)
        let value = try await provider.fetch()
        XCTAssertEqual(value.planName, "Max")
        XCTAssertEqual(value.windows.map(\.kind), [.session,.weekly,.fable])
        XCTAssertEqual(value.resets?.availableCount, 3)
        XCTAssertFalse(value.hasAdditionalUsageSection)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[1].url.path, "/api/organizations/\(chatID)/usage")
        XCTAssertTrue(requests.allSatisfy { $0.url.host == "claude.ai" && $0.headers["Authorization"] == nil })
    }
    func testAmbiguousClaudeOrganizationsFailRatherThanChoosingAnotherAccount() async {
        let http = MockHTTPClient([httpResponse(json: #"[{"uuid":"11111111-1111-4111-8111-111111111111","capabilities":["chat"]},{"uuid":"22222222-2222-4222-8222-222222222222","capabilities":["chat"]}]"#)])
        let provider = WebUsageProvider(id: .claude, source: .edge,
            sessions: sessions(domain: "claude.ai", names: ["sessionKey":"test"]), http: http)
        do { _ = try await provider.fetch(); XCTFail("Expected organization selection failure") }
        catch { XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication) }
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }
    @MainActor
    func testGoogleProvidersFetchIndependently() async {
        let gemini = CountedSource(id: .gemini)
        let antigravity = CountedSource(id: .antigravity)
        let store = UsageStore(providers: [gemini, antigravity],
            availabilityChecker: FixedProviderAvailabilityChecker(installed: [.gemini,.antigravity]))
        await store.refresh()
        let counts = await [gemini.count, antigravity.count]
        XCTAssertEqual(counts, [1,1])
        XCTAssertTrue(store.isProviderVisibleInDashboard(.gemini))
        XCTAssertTrue(store.isProviderVisibleInDashboard(.antigravity))
        XCTAssertNotNil(store.states[.antigravity]?.snapshot)
        XCTAssertFalse(store.states[.antigravity]?.isRefreshing == true)
        store.stop()
    }
    func testReadOnlySQLiteReaderNeverExecutesWrites() {
        XCTAssertThrowsError(try ReadOnlySessionSQLiteReader().execute(path: "/tmp/unused", sql: "DELETE FROM cookies"))
    }
}
private struct CookieSQLite: SQLiteValueReading {
    let rows: String
    func queryValue(path: String, sql: String) throws -> String? { sql.contains("FROM meta") ? "24" : rows }
    func execute(path: String, sql: String) throws { XCTFail("Cookie stores must never be modified") }
}
private actor CountedSource: UsageProvider {
    nonisolated let id: ProviderID
    private(set) var count = 0
    init(id: ProviderID) { self.id = id }
    func fetch() async throws -> ProviderSnapshot {
        count += 1
        return ProviderSnapshot(provider: id, planName: nil, windows: [], fetchedAt: Date())
    }
}
