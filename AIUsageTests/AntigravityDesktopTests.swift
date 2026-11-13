import XCTest
@testable import AIUsage

final class AntigravityDesktopTests: XCTestCase {
    func testExactOAuthRecordRejectsMalformedAmbiguousAndUnrelatedEntries() {
        let encoded = NativeAntigravitySQLite.record("synthetic-refresh")
        XCTAssertEqual(AntigravityDesktopCredentials.refreshToken(encoded), "synthetic-refresh")
        XCTAssertNil(AntigravityDesktopCredentials.refreshToken("not-base64"))
        let data = Data(base64Encoded: encoded)!
        XCTAssertNil(AntigravityDesktopCredentials.refreshToken((data + data).base64EncodedString()))
        XCTAssertNil(AntigravityDesktopCredentials.refreshToken(NativeAntigravitySQLite.record("x", key: "different-account")))
    }
    @MainActor func testNativeSessionWithoutEmailStillRecordsLimitsWithoutDisplayingFakeIdentity() {
        let credential = AntigravityDesktopCredentials.Credential(refresh: "synthetic", email: nil)
        let value = ProviderSnapshot(provider: .antigravity, planName: nil,
            windows: [QuotaWindow(kind: .argonWeekly, usedPercent: 100, resetsAt: nil)], fetchedAt: Date(),
            credentialSource: "Antigravity app", accountLabel: credential.historyID)
        XCTAssertNil(value.identityEmail)
        XCTAssertEqual(value.historyIdentity, credential.historyID)
        let history = UsageHistory()
        history.record(value)
        XCTAssertEqual(history.limitHits.count, 1)
        XCTAssertFalse(credential.historyID.contains("synthetic"))
    }
    func testNativeUnifiedIdentityUsesOnlyUserStatusEmailField() {
        let raw = NativeAntigravitySQLite.record("native@example.invalid", key: "userStatusSentinelKey", fieldNumber: 7)
        XCTAssertEqual(AntigravityDesktopCredentials.email(raw), "native@example.invalid")
        XCTAssertNil(AntigravityDesktopCredentials.email(NativeAntigravitySQLite.record("native@example.invalid")))
        XCTAssertNil(AntigravityDesktopCredentials.email(NativeAntigravitySQLite.record("invalid", key: "userStatusSentinelKey", fieldNumber: 7)))
        let bytes = Data(base64Encoded: raw)!
        XCTAssertNil(AntigravityDesktopCredentials.email((bytes + bytes).base64EncodedString()))
    }
    func testMissingNativeProfileNeverFallsBackToGeminiOrKeychain() {
        let store = AntigravityDesktopCredentials(sqlite: NativeAntigravitySQLite(), exists: { _ in false })
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual(($0 as? ProviderFailure)?.kind, .authentication) }
    }
    func testNativeRefreshIsAccountBoundMemoryCachedAndUsesOnlyAntigravityClient() async throws {
        let sqlite = NativeAntigravitySQLite()
        let credentials = AntigravityDesktopCredentials(sqlite: sqlite, exists: { $0.contains("Antigravity IDE/") })
        let base = "https://cloudcode-pa.googleapis.com"
        let summary = httpResponse(json: #"{"groups":[{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-weekly","window":"weekly","remainingFraction":0.01}]}]}"#)
        let http = RoutedHTTPClient([
            AntigravityUsageClient.googleOAuthURL.absoluteString: [
                httpResponse(json: #"{"access_token":"native-one","expires_in":3600}"#),
                httpResponse(json: #"{"access_token":"native-two","expires_in":3600}"#)],
            base + AntigravityUsageClient.planPath: [httpResponse(json: #"{"paidTier":{"id":"g1-pro-tier"}}"#)],
            base + AntigravityUsageClient.summaryPath: [summary]
        ])
        let provider = AntigravityDesktopProvider(credentials: credentials, client: AntigravityUsageClient(http: http))
        let first = try await provider.fetch()
        XCTAssertEqual(first.identityEmail, "ide@example.invalid")
        XCTAssertEqual(first.credentialSource, "Antigravity app")
        XCTAssertEqual(first.windows.first?.kind, .argonWeekly)
        XCTAssertEqual(first.windows.first?.usedPercent, 99)
        _ = try await provider.fetch()
        var requests = await http.capturedRequests()
        XCTAssertEqual(requests.filter { $0.url.host == "oauth2.googleapis.com" }.count, 1)
        sqlite.changeAccount()
        let switched = try await provider.fetch()
        XCTAssertEqual(switched.identityEmail, "second@example.invalid")
        requests = await http.capturedRequests()
        let refreshes = requests.filter { $0.url.host == "oauth2.googleapis.com" }
        XCTAssertEqual(refreshes.count, 2)
        for request in refreshes {
            let form = String(decoding: request.body!, as: UTF8.self)
            XCTAssertTrue(form.contains(AntigravityUsageClient.googleClientID))
            XCTAssertFalse(form.contains("assistant"))
        }
        XCTAssertTrue(requests.allSatisfy { ["oauth2.googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"].contains($0.url.host!) })
    }
}
private final class NativeAntigravitySQLite: SQLiteValueReading, @unchecked Sendable {
    private let lock = NSLock()
    private var second = false
    func changeAccount() { lock.withLock { second = true } }
    func queryValue(path: String, sql: String) throws -> String? {
        XCTAssertTrue(path.contains("Antigravity IDE/"))
        return lock.withLock {
            if sql == "SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.oauthToken'" {
                return Self.record(second ? "refresh-two" : "refresh-one")
            }
            if sql == "SELECT value FROM ItemTable WHERE key='antigravityAuthStatus'" {
                return second ? #"{"email":"second@example.invalid"}"# : #"{"email":"ide@example.invalid"}"#
            }
            if sql == "SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.userStatus'" { return nil }
            XCTFail("Unexpected data access"); return nil
        }
    }
    func execute(path: String, sql: String) throws { XCTFail("Native storage must never be modified") }
    static func record(_ refresh: String, key: String = "oauthTokenInfoSentinelKey", fieldNumber: UInt8 = 3) -> String {
        func field(_ number: UInt8, _ value: Data) -> Data {
            precondition(value.count < 128)
            return Data([number << 3 | 2, UInt8(value.count)]) + value
        }
        let oauth = field(fieldNumber, Data(refresh.utf8)).base64EncodedData()
        let entry = field(1, Data(key.utf8)) + field(2, field(1, oauth))
        return field(1, entry).base64EncodedString()
    }
}
