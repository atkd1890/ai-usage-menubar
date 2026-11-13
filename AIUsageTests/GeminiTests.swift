import XCTest
@testable import AIUsage

final class GeminiTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Independently generated with hashlib PBKDF2 + SHA256 and OpenSSL AES-CBC.
    private let encrypted = "76313026d8be4ade0e663e9084bdc1c8a78c5fd63c4bbf0ba2b48d0e12a2861834c02d198df5a9a3eab5e98c3abf84907532f00f1afaf40c4d49e414aff1b0231e0cb4"
    private let body = #"""
    )]}'
    [{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"TIER1","pools":[
      {"poolType":"GXU_FIVE_HOURLY","percentageUsed":0.37,"gxu":{"windowRefreshesAt":"2027-01-15T12:00:00Z"}},
      {"poolType":"GXU_WEEKLY","percentageUsed":0.125,"gxu":{"windowRefreshesAt":"2027-01-21T12:00:00Z"}}
    ]}}}},"errors":[{"message":"irrelevant upsell error"}]}]
    """#

    func testChromeCookieKnownVectorAndDomainBinding() throws {
        XCTAssertEqual(try GeminiAuthStore.decryptCookie(hex: encrypted, host: ".google.com", version: 24, password: "fake-browser-key"), "fake-google-session")
        XCTAssertThrowsError(try GeminiAuthStore.decryptCookie(hex: encrypted, host: ".example.com", version: 24, password: "fake-browser-key"))
        XCTAssertThrowsError(try GeminiAuthStore.decryptCookie(hex: encrypted, host: ".google.com", version: 24, password: "wrong-key"))
    }

    func testLegacyCookieAndBadCiphertext() throws {
        XCTAssertEqual(try GeminiAuthStore.decryptCookie(hex: "763130c4c1aabb38e5f50c55e161710201cc30", host: ".google.com", version: 23, password: "fake-browser-key"), "legacy-session")
        for hex in ["", "0", "zz", "76323000"] {
            XCTAssertThrowsError(try GeminiAuthStore.decryptCookie(hex: hex, host: ".google.com", version: 24, password: "fake-browser-key"))
        }
    }

    func testNoCredentialReadsWithoutExplicitConsent() {
        let db = GeminiTestSQLite(rows: "[]")
        let keys = MemoryKeychain()
        let store = auth(db: db, keychain: keys, allowed: false)
        XCTAssertThrowsError(try store.loadSession()) { error in
            XCTAssertTrue((error as? ProviderFailure)?.message.contains("Enable") == true)
        }
        XCTAssertTrue(db.queries.isEmpty)
        XCTAssertTrue(keys.genericReads.isEmpty)
    }

    func testReadsOnlyGoogleLoginCookiesAndNeverWrites() throws {
        let db = GeminiTestSQLite(rows: rows(encrypted: encrypted))
        let keys = MemoryKeychain(generic: [GeminiAuthStore.keychainService: "fake-browser-key"])
        let session = try auth(db: db, keychain: keys).loadSession()
        XCTAssertEqual(session.cookieHeader, "__Secure-1PSID=fake-google-session")
        XCTAssertEqual(keys.genericReads, [GeminiAuthStore.keychainService])
        XCTAssertEqual(db.queries.count, 2)
        XCTAssertTrue(db.queries[0].contains("host_key = '.google.com'"))
        XCTAssertTrue(db.queries[0].contains("name IN ('__Secure-1PSID', '__Secure-1PSIDTS')"))
        XCTAssertTrue(db.writes.isEmpty)
    }

    func testMissingAndDeniedKeychainAreStorageFailures() {
        for keychain in [MemoryKeychain(), MemoryKeychain(generic: [GeminiAuthStore.keychainService: "wrong-key"])] {
            XCTAssertThrowsError(try auth(db: GeminiTestSQLite(rows: rows(encrypted: encrypted)), keychain: keychain).loadSession()) { error in
                XCTAssertEqual((error as? ProviderFailure)?.kind, .storage)
            }
        }
    }

    func testMissingLoginAndHeaderInjection() {
        let noCookies = auth(db: GeminiTestSQLite(rows: "[]"))
        XCTAssertThrowsError(try noCookies.loadSession()) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
        let malicious = #"[{"name":"__Secure-1PSID","host":".google.com","value":"bad; other=secret","encrypted":""}]"#
        XCTAssertThrowsError(try auth(db: GeminiTestSQLite(rows: malicious)).loadSession())
    }

    func testMapsWebUsageFractionsPlanAndResetTimes() throws {
        let result = try GeminiUsageMapper.map(response: httpResponse(json: body), now: now)
        XCTAssertEqual(result.provider, .gemini)
        XCTAssertEqual(result.planName, "Google AI Pro")
        XCTAssertEqual(result.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(result.windows.map(\.usedPercent), [37, 12.5])
        XCTAssertNotNil(result.windows[0].resetsAt)
        XCTAssertEqual(result.fetchedAt, now)
    }

    func testUnknownWindowsAreAbsentAndReportedZeroIsZero() throws {
        let text = #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"subscriptionTier":"NEW_TIER","pools":[{"poolType":"GXU_FIVE_HOURLY","percentageUsed":null},{"poolType":"GXU_WEEKLY","percentageUsed":0,"gxu":{"windowRefreshesAt":"unknown"}}]}}}}}]"#
        let result = try GeminiUsageMapper.map(response: httpResponse(json: text), now: now)
        XCTAssertEqual(result.windows.map(\.kind), [.weekly])
        XCTAssertEqual(result.windows[0].usedPercent, 0)
        XCTAssertNil(result.windows[0].resetsAt)
        XCTAssertNil(result.planName)
    }

    func testMissingMetersAndDriftNeverBecomeFullQuota() {
        for text in ["{}", "[]", #"[{"data":{"viewer":{"rpcs":{"getUsageInfo":{"pools":[]}}}}}]"#,
                     #"[{"data":{},"errors":[{"message":"private-data-do-not-echo"}]}]"#] {
            XCTAssertThrowsError(try GeminiUsageMapper.map(response: httpResponse(json: text), now: now)) { error in
                XCTAssertEqual((error as? ProviderFailure)?.kind, .invalidResponse)
                XCTAssertFalse(error.localizedDescription.contains("private-data-do-not-echo"))
            }
        }
    }

    func testSignedOutForbiddenAndHTMLRequireWebLogin() {
        for response in [httpResponse(401), httpResponse(403), httpResponse(302), httpResponse(json: "<html>Sign in</html>"), httpResponse(json: #"[{"data":{"viewer":null}}]"#)] {
            XCTAssertThrowsError(try GeminiUsageMapper.map(response: response, now: now)) { error in
                XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
            }
        }
    }

    func testRateLimitAndServerFailureRetainTheirClassification() {
        for (response, kind) in [(httpResponse(429, headers: ["Retry-After":"60"]), ProviderFailureKind.rateLimited), (httpResponse(503, json: "<html>down</html>"), .transient)] {
            XCTAssertThrowsError(try GeminiUsageMapper.map(response: response, now: now)) { error in
                XCTAssertEqual((error as? ProviderFailure)?.kind, kind)
            }
        }
    }

    func testProviderSendsOnlyWebSessionToGeminiHost() async throws {
        let db = GeminiTestSQLite(rows: rows(encrypted: encrypted))
        let http = MockHTTPClient([httpResponse(json: body)])
        let provider = GeminiProvider(authStore: auth(db: db, keychain: MemoryKeychain(generic: [GeminiAuthStore.keychainService: "fake-browser-key"])), client: GeminiUsageClient(http: http), dateProvider: FixedDateProvider(value: now), source: .chrome)
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].method, .get)
        XCTAssertEqual(requests[0].url.host, "gemini.google.com")
        XCTAssertEqual(requests[0].headers["Cookie"], "__Secure-1PSID=fake-google-session")
        XCTAssertNil(requests[0].headers["Authorization"])
        let query = URLComponents(url: requests[0].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first(where: { $0.name == "query_signature" })?.value, GeminiUsageClient.querySignature)
        XCTAssertTrue(db.writes.isEmpty)
    }

    func testHTTPClientRefusesNonGeminiHostsWithoutNetwork() async {
        do {
            _ = try await GeminiReadOnlyHTTPClient().send(HTTPRequest(method: .get, url: URL(string: "https://example.com/usage")!))
            XCTFail("Expected host rejection")
        } catch { XCTAssertEqual((error as? ProviderFailure)?.kind, .invalidResponse) }
    }

    @MainActor
    func testNewProviderMigrationPreservesOptOutAndRequiresSeparateCookieConsent() throws {
        let suite = "GeminiTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONEncoder().encode([ProviderID.claude]), forKey: "trackedProviderIDs.v1")
        let first = AppPreferences(defaults: defaults)
        XCTAssertTrue(first.isTracking(.gemini))
        XCTAssertTrue(first.providerOrder.contains(.gemini))
        XCTAssertFalse(first.geminiChromeCookiesAllowed)
        first.setTracking(false, for: .gemini)
        first.geminiChromeCookiesAllowed = true
        let next = AppPreferences(defaults: defaults)
        XCTAssertFalse(next.isTracking(.gemini))
        XCTAssertTrue(next.geminiChromeCookiesAllowed)
    }

    private func rows(encrypted: String) -> String {
        #"[{"name":"__Secure-1PSID","host":".google.com","value":"","encrypted":""# + encrypted + #""}]"#
    }
    private func auth(db: GeminiTestSQLite, keychain: MemoryKeychain = MemoryKeychain(), allowed: Bool = true) -> GeminiAuthStore {
        GeminiAuthStore(sqlite: db, keychain: keychain, files: MemoryFiles([GeminiAuthStore.cookiePaths[0]: "exists"]), allowChromeCookies: allowed)
    }
}

private final class GeminiTestSQLite: SQLiteValueReading, @unchecked Sendable {
    let rows: String
    private let lock = NSLock()
    private var reads: [String] = []
    private var statements: [String] = []
    var queries: [String] { lock.withLock { reads } }
    var writes: [String] { lock.withLock { statements } }
    init(rows: String) { self.rows = rows }
    func queryValue(path: String, sql: String) throws -> String? {
        lock.withLock { reads.append(sql) }
        return sql.contains("FROM meta") ? "24" : rows
    }
    func execute(path: String, sql: String) throws { lock.withLock { statements.append(sql) } }
}
