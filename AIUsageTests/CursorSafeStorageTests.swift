import XCTest
@testable import AIUsage

final class CursorSafeStorageTests: XCTestCase {
    private let password = "test-safe-storage-password"
    // Independently generated with Python hashlib PBKDF2 and OpenSSL AES-CBC.
    private let fixture = "cursor-safe-storage:v1:djEw0n4nhuLODwp9js1TG9vuFpdABm1vC+YjVYg+JbGubIM="

    func testChromiumKnownVector() throws {
        XCTAssertEqual(try CursorTokenCodec.decode(fixture, password: password), "fake-access-token")
        XCTAssertEqual(try CursorTokenCodec.encode("fake-access-token", password: password), fixture)
    }

    func testInvalidEnvelopeAndWrongKeyFail() {
        for value in ["cursor-safe-storage:v2:abc", "cursor-safe-storage:v1:!", "cursor-safe-storage:v1:djEx", "cursor-safe-storage:v1:djEw"] {
            XCTAssertThrowsError(try CursorTokenCodec.decode(value, password: password))
        }
        XCTAssertThrowsError(try CursorTokenCodec.decode(fixture, password: "wrong-password"))
    }

    func testLoadsBothEncryptedTokens() throws {
        let db = CursorTestSQLite(access: fixture, refresh: fixture)
        let store = CursorAuthStore(sqlite: db, keychain: keychain())
        let state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.accessToken, "fake-access-token")
        XCTAssertEqual(state.refreshToken, "fake-access-token")
        XCTAssertEqual(state.source, .sqliteEncrypted)
        XCTAssertTrue(db.writes.isEmpty)
    }

    func testLegacyPlaintextDoesNotReadSafeStorageKey() throws {
        let db = CursorTestSQLite(access: "legacy-token", refresh: "legacy-refresh")
        let keys = MemoryKeychain()
        let store = CursorAuthStore(sqlite: db, keychain: keys)
        XCTAssertEqual(try store.load()?.source, .sqlite)
        XCTAssertFalse(keys.genericReads.contains(CursorTokenCodec.keychainService))
        try store.saveAccessToken("new-token", source: .sqlite)
        XCTAssertTrue(db.writes.last?.contains("'new-token'") == true)
    }

    func testLegacyKeychainFallbackStillWorks() throws {
        let keys = MemoryKeychain(generic: [CursorAuthStore.accessTokenService: "keychain-token"])
        let store = CursorAuthStore(sqlite: CursorTestSQLite(), keychain: keys)
        XCTAssertEqual(try store.load()?.accessToken, "keychain-token")
        XCTAssertEqual(try store.load()?.source, .keychain)
    }

    func testMissingKeyIsStorageFailureInsteadOfExpiredSession() {
        let store = CursorAuthStore(sqlite: CursorTestSQLite(access: fixture), keychain: MemoryKeychain())
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .storage)
            XCTAssertTrue((error as? ProviderFailure)?.message.contains("key is missing") == true)
        }
    }

    func testDeniedKeychainIsStorageFailure() {
        let store = CursorAuthStore(sqlite: CursorTestSQLite(access: fixture), keychain: DeniedCursorKeychain())
        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .storage)
            XCTAssertTrue((error as? ProviderFailure)?.message.contains("Allow access") == true)
        }
    }

    func testRefreshSavesEncryptedTokenAndUsesPlaintextOnlyForHTTP() async throws {
        let token = "header.eyJleHAiOjQxMDI0NDQ4MDB9.signature"
        let encrypted = try CursorTokenCodec.encode(token, password: password)
        let db = CursorTestSQLite(access: encrypted, refresh: fixture)
        let http = MockHTTPClient([
            httpResponse(401),
            httpResponse(json: "{\"access_token\":\"refreshed-token\"}"),
            httpResponse(json: "{\"enabled\":true,\"planUsage\":{\"totalPercentUsed\":25}}"),
            httpResponse(json: "{\"planInfo\":{\"planName\":\"Pro\"}}")
        ])
        let provider = CursorProvider(authStore: CursorAuthStore(sqlite: db, keychain: keychain()), client: CursorUsageClient(http: http))
        let result = try await provider.fetch()
        XCTAssertEqual(result.windows.first?.usedPercent, 25)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer " + token)
        let body = try XCTUnwrap(requests[1].body)
        let refresh = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(refresh["refresh_token"], "fake-access-token")
        XCTAssertEqual(requests[2].headers["Authorization"], "Bearer refreshed-token")
        let expected = try CursorTokenCodec.encode("refreshed-token", password: password)
        XCTAssertEqual(db.writes.count, 1)
        XCTAssertTrue(db.writes[0].contains(expected))
        XCTAssertFalse(db.writes[0].contains("refreshed-token"))
    }

    private func keychain() -> MemoryKeychain {
        MemoryKeychain(generic: [CursorTokenCodec.keychainService: password])
    }
}

private final class CursorTestSQLite: SQLiteValueReading, @unchecked Sendable {
    let access: String?
    let refresh: String?
    private let lock = NSLock()
    private var statements: [String] = []
    var writes: [String] { lock.withLock { statements } }

    init(access: String? = nil, refresh: String? = nil) {
        self.access = access
        self.refresh = refresh
    }
    func queryValue(path: String, sql: String) throws -> String? {
        if sql.contains(CursorAuthStore.accessTokenKey) { return access }
        if sql.contains(CursorAuthStore.refreshTokenKey) { return refresh }
        return nil
    }
    func execute(path: String, sql: String) throws {
        lock.withLock { statements.append(sql) }
    }
}

private struct DeniedCursorKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { throw KeychainError.readFailed }
    func writeGenericPassword(service: String, value: String) throws { throw KeychainError.writeFailed }
    func readGenericPasswordForCurrentUser(service: String) throws -> String? { throw KeychainError.readFailed }
    func writeGenericPasswordForCurrentUser(service: String, value: String) throws { throw KeychainError.writeFailed }
}
