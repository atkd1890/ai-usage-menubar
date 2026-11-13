import XCTest
@testable import AIUsage

final class AccountIdentityTests: XCTestCase {
    func testSuccessfulRefreshKeepsEmailWithoutAnotherProfileRequest() async {
        let suite = "IdentityRotation." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let cache = AccountIdentityCache(provider: .claude, source: "oauth", suiteName: suite)
        _ = await cache.read(credential: "old") { "person@example.com" }
        await cache.rebindAfterRefresh(from: "old", to: "rotated")
        let email = await cache.read(credential: "rotated") { XCTFail("Refresh must not refetch identity"); return nil }
        XCTAssertEqual(email, "person@example.com")
        await cache.rebindAfterRefresh(from: "unrelated", to: "other")
        let unrelated = await cache.read(credential: "other") { XCTFail("Do not silently poll identity"); return nil }
        XCTAssertNil(unrelated)
    }
    func testValidatesEmailAndNeverTreatsOrganizationNamesAsEmail() {
        XCTAssertEqual(AccountEmail.validated("person@example.com"), "person@example.com")
        for value in ["Team account", "not-an-email", "a@b\nInjected: header", "a@@example.com"] {
            XCTAssertNil(AccountEmail.validated(value))
        }
        let organization = ProviderSnapshot(provider: .claude, planName: "Max", windows: [], fetchedAt: Date(),
            accountLabel: "organization@example.com")
        XCTAssertNil(organization.identityEmail)
        XCTAssertEqual(organization.withCredential(source: "web", account: nil, email: "person@example.com").identityEmail,
                       "person@example.com")
    }
    func testIdentityIsFetchedOncePerSelectionAcrossRefreshesAndRelaunches() async {
        let suite = "AccountIdentityTests." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let counter = IdentityCounter()
        let cache = AccountIdentityCache(provider: .codex, source: "edge", suiteName: suite)
        let first = await cache.read(credential: "session-one") { await counter.email() }
        let again = await cache.read(credential: "session-one") { await counter.email() }
        let relaunched = AccountIdentityCache(provider: .codex, source: "edge", suiteName: suite)
        let persisted = await relaunched.read(credential: "session-one") { await counter.email() }
        XCTAssertEqual(first, "person@example.com")
        XCTAssertEqual(again, first)
        XCTAssertEqual(persisted, first)
        let count = await counter.count
        XCTAssertEqual(count, 1)
        // Credential changes cannot inherit a cached email or start background identity polling.
        let changed = await cache.read(credential: "session-two") { await counter.email() }
        XCTAssertNil(changed)
        let stillOne = await counter.count
        XCTAssertEqual(stillOne, 1)
        UserDefaults(suiteName: suite)?.set("new-selection", forKey: ProviderLoginMethod.selectionKey(for: .codex))
        let selected = await cache.read(credential: "session-two") { await counter.email() }
        XCTAssertEqual(selected, first)
        let twice = await counter.count
        XCTAssertEqual(twice, 2)
    }
    func testFailedIdentityReadIsNotRetriedByUsageRefresh() async {
        let suite = "AccountIdentityFailureTests." + UUID().uuidString
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let counter = IdentityCounter()
        let cache = AccountIdentityCache(provider: .claude, source: "desktop", suiteName: suite)
        _ = await cache.read(credential: "test") { _ = await counter.email(); return nil }
        let value = await cache.read(credential: "test") { await counter.email() }
        XCTAssertNil(value)
        let count = await counter.count
        XCTAssertEqual(count, 1)
    }
    func testClaudeAndCursorProfileParsers() {
        XCTAssertEqual(AccountEmail.claude(["email_address":"web@example.com"]), "web@example.com")
        XCTAssertEqual(AccountEmail.claude(["account":["email":"oauth@example.com"]]), "oauth@example.com")
        XCTAssertEqual(AccountEmail.cursor(["email":"cursor@example.com"]), "cursor@example.com")
        XCTAssertNil(AccountEmail.claude(["organization":["name":"org@example.com"]]))
    }
    func testCodexQuotaEmailIsAvailableWithoutAnIdentityRequest() throws {
        let snapshot = try CodexUsageMapper.map(response: httpResponse(json: #"{"email":"codex@example.com","plan_type":"plus","rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":1000}}}"#), now: Date())
        XCTAssertEqual(snapshot.identityEmail, "codex@example.com")
    }
    func testGoogleSharedEmailRequiresMatchingAccounts() {
        func state(_ provider: ProviderID, _ email: String) -> ProviderState {
            ProviderState(provider: provider, snapshot: ProviderSnapshot(provider: provider, planName: "Pro", windows: [],
                fetchedAt: Date(), accountEmail: email))
        }
        XCTAssertEqual(GoogleAIGroup.sharedEmail([state(.gemini,"one@example.com"),state(.antigravity,"one@example.com")]), "one@example.com")
        XCTAssertNil(GoogleAIGroup.sharedEmail([state(.gemini,"one@example.com"),state(.antigravity,"other@example.com")]))
        XCTAssertEqual(GoogleAIGroup.sharedEmail([state(.gemini,"browser@example.com")]), "browser@example.com")
    }
}
private actor IdentityCounter {
    private(set) var count = 0
    func email() -> String? { count += 1; return "person@example.com" }
}
