import XCTest
@testable import AIUsage

final class GeminiNativeTests: XCTestCase {
    // Synthetic independent vectors generated with Node AES-256-GCM and a small protobuf encoder.
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let keyStoreHex = "087b1226080110012220000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private let authHex = "2ebafeca2ebafeca17000000080110011801220c0a0b0c0d0e0f10111213141528c40165b45ca900b8fa12d76db91fcac88025925eba57de078ed88e77a2f8273cb08a4d7b79d9d7f0b224a27ed98b5d6f33b859d5c0e93c32371eeeef60596652e39815ffb679b0d768d9aa3a81a6fef16b1c664e75b965b1a0515c637bbbc10fd9a3f4fd5cf33ed4c900ed09cf3f3fcd2d4072240ec8948c01599fc3b4e85b7c2d991acc69980c523065b7c0839ff42253289208541c808cac1822e171e7ef9713af7120c0583c913e855ff30b2cdc3dcd24e023fcaa42bf20094c59da66a825ca8134c07e33"
    private let otherAuthHex = "2ebafeca2ebafeca17000000080110011801220c0a0b0c0d0e0f10111213141528c40165b45ca900b8fa12d76db91fcbc39120986c9f4ac70b93c4873ce5ff3f2bbd8f40054a98cbf0b627eb6bd9d35d6f6af151d5c8e235362607f4b22d556410ad8c14e3f137a2d772c3ad2f8ebca8c01f1279433da529a3a84c5c637bbbc10fd9a3f4fd5cf33ed4c900ed09cf3f3fcd2d4072240ec8948c01599fc3b4e85b7c2d991acc69980c523065b7c0839ff42253289208541c808cac1822e171e7ef9713af7120c0583c913e855ff30b2cdc3dcd24e023fcaa7b76b8d232170759588a2b8af3da720b"
    private let configHex = "22057573657231"
    private let otherConfigHex = "22057573657232"
    private let usageHex = "10021a16080212120a0b08a0e6c5da0610c0a9d33a150000003e1a16080112120a0b0888cba7da0610c0a9d33a150000803e"
    private let clientID = "fake-native.apps.googleusercontent.com"

    func testDecryptsNativeCredentialAndSelectsActiveAccount() throws {
        let files = try nativeFiles()
        let credential = try store(files: files).load()
        XCTAssertEqual(credential.refreshToken, "fake-native-refresh")
        XCTAssertEqual(credential.clientID, clientID)
        XCTAssertEqual(credential.accountLabel, "demo@example.invalid")
        XCTAssertTrue(files.reads.contains(GeminiNativeAuthStore.root + "/Data/user1/auth"))
        XCTAssertFalse(files.reads.contains(GeminiNativeAuthStore.root + "/Data/user2/auth"))
    }

    func testConsentPreventsNativeFileAndKeychainAccess() throws {
        let files = try nativeFiles()
        let auth = GeminiNativeAuthStore(allowNativeAccess: false,
            readData: { try files.read($0) }, readKeyStore: { XCTFail("Must not read Keychain"); return Data() })
        XCTAssertThrowsError(try auth.load()) { error in
            XCTAssertEqual((error as? ProviderFailure)?.kind, .authentication)
        }
        XCTAssertTrue(files.reads.isEmpty)
    }

    func testTamperedCiphertextWrongKeyAndEnvelopeFailClosed() throws {
        let original = try Self.data(authHex)
        var tampered = original; tampered[tampered.count - 1] ^= 1
        for blob in [Data(), Data([1, 2, 3]), tampered] {
            XCTAssertThrowsError(try GeminiNativeAuthStore.decryptCredential(blob, keyStore: Self.data(keyStoreHex)))
        }
        var wrongKey = try Self.data(keyStoreHex); wrongKey[wrongKey.count - 1] ^= 1
        XCTAssertThrowsError(try GeminiNativeAuthStore.decryptCredential(original, keyStore: wrongKey))
    }

    func testActiveAccountPathTraversalIsRejected() throws {
        let files = try nativeFiles()
        files.set(GeminiNativeAuthStore.root + "/account_config", Data([0x22, 0x03, 0x2e, 0x2e, 0x2f]))
        XCTAssertThrowsError(try store(files: files).load())
        XCTAssertFalse(files.reads.contains(where: { $0.contains("/Data/") }))
    }

    func testInstalledClientConfigurationMustBeUnambiguousAndMatchAudience() throws {
        let binary = fakeBinary()
        let result = try GeminiNativeAuthStore.clientConfiguration(in: binary, clientID: clientID)
        XCTAssertEqual(result.clientID, clientID)
        XCTAssertEqual(result.clientSecret, fakeClientSecret)
        XCTAssertThrowsError(try GeminiNativeAuthStore.clientConfiguration(in: binary, clientID: "other.apps.googleusercontent.com"))
        XCTAssertThrowsError(try GeminiNativeAuthStore.clientConfiguration(in: binary + binary, clientID: clientID))
        XCTAssertThrowsError(try GeminiNativeAuthStore.clientConfiguration(in: Data(clientID.utf8), clientID: clientID))
    }

    func testNativeQuotaMapsSessionWeeklyPercentagesAndTimestamp() throws {
        let result = try GeminiNativeUsageMapper.map(response: usage(), now: now, accountLabel: "demo@example.invalid")
        XCTAssertEqual(result.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(result.windows.map(\.usedPercent), [25, 12.5])
        XCTAssertEqual(result.credentialSource, "Gemini app")
        XCTAssertEqual(result.accountLabel, "demo@example.invalid")
        XCTAssertEqual(try XCTUnwrap(result.windows[0].resetsAt).timeIntervalSince1970, 1_800_005_000.123, accuracy: 0.00001)
        XCTAssertEqual(result.planName, "Google AI Pro") // Native TIER1 mapping verified from installed schema.
    }

    func testUnknownNativeTierIsNotLabeledAsPro() throws {
        var body = try Self.data(usageHex)
        body[1] = 99
        let value = try GeminiNativeUsageMapper.map(response: HTTPResponse(statusCode: 200, headers: [:], body: body), now: now, accountLabel: nil)
        XCTAssertNil(value.planName)
    }
    func testMalformedOrMissingQuotaNeverBecomesFullAllowance() {
        for body in [Data(), Data([0xff]), Data([0x18, 0x01])] {
            XCTAssertThrowsError(try GeminiNativeUsageMapper.map(response: HTTPResponse(statusCode: 200, headers: [:], body: body), now: now, accountLabel: nil))
        }
        for data in [Data([0x0a, 0xff]), Data([0x00]), Data(repeating: 0xff, count: 12)] {
            XCTAssertThrowsError(try GeminiProtobuf.fields(data))
        }
    }

    func testCachedAccessTokenIsMemoryOnlyAndReusedForSameAccount() async throws {
        let files = try nativeFiles()
        let http = MockHTTPClient([httpResponse(json: #"{"access_token":"fake-access","expires_in":3600}"#), try usage(), try usage()])
        let provider = GeminiNativeProvider(authStore: try store(files: files), client: GeminiNativeUsageClient(http: http), dateProvider: FixedDateProvider(value: now))
        _ = try await provider.fetch()
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.map(\.url.host), ["oauth2.googleapis.com", "robinfrontend-pa.googleapis.com", "robinfrontend-pa.googleapis.com"])
        XCTAssertEqual(files.reads.filter { $0 == GeminiNativeAuthStore.binaryPath }.count, 1)
        XCTAssertEqual(requests[1].headers["Authorization"], "Bearer fake-access")
        XCTAssertEqual(requests[1].headers["Content-Type"], "application/x-protobuf")
        XCTAssertEqual(requests[1].body, Data())
        XCTAssertNil(requests[1].headers["Cookie"])
        let body = String(decoding: try XCTUnwrap(requests[0].body), as: UTF8.self)
        XCTAssertTrue(body.contains("refresh_token=fake-native-refresh"))
        XCTAssertTrue(body.contains("client_secret="))
        XCTAssertTrue(body.contains("assistant"))
    }

    func testAccountSwitchInvalidatesCachedAccessToken() async throws {
        let files = try nativeFiles()
        let http = MockHTTPClient([httpResponse(json: #"{"access_token":"first-access","expires_in":3600}"#), try usage(), httpResponse(json: #"{"access_token":"other-access","expires_in":3600}"#), try usage()])
        let provider = GeminiNativeProvider(authStore: try store(files: files), client: GeminiNativeUsageClient(http: http), dateProvider: FixedDateProvider(value: now))
        _ = try await provider.fetch()
        files.set(GeminiNativeAuthStore.root + "/account_config", try Self.data(otherConfigHex))
        let other = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[3].headers["Authorization"], "Bearer other-access")
        XCTAssertEqual(other.accountLabel, "other@example.invalid")
    }

    func testUnauthorizedReadRefreshesOnlyOnce() async throws {
        let files = try nativeFiles()
        let http = MockHTTPClient([httpResponse(json: #"{"access_token":"first-access","expires_in":3600}"#), httpResponse(401), httpResponse(json: #"{"access_token":"renewed-access","expires_in":3600}"#), try usage()])
        let provider = GeminiNativeProvider(authStore: try store(files: files), client: GeminiNativeUsageClient(http: http), dateProvider: FixedDateProvider(value: now))
        _ = try await provider.fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.last?.headers["Authorization"], "Bearer renewed-access")
    }

    func testRevokedRefreshAndRateLimitHaveDifferentFailures() async throws {
        let credential = try store(files: nativeFiles()).load()
        for (response, kind) in [(httpResponse(400, json: #"{"error":"invalid_grant"}"#), ProviderFailureKind.authentication), (httpResponse(429, headers: ["Retry-After":"60"]), .rateLimited)] {
            let client = GeminiNativeUsageClient(http: MockHTTPClient([response]))
            do {
                _ = try await client.refresh(credential: credential, client: GeminiNativeOAuthClient(clientID: clientID, clientSecret: fakeClientSecret), now: now)
                XCTFail("Expected classified failure")
            } catch { XCTAssertEqual((error as? ProviderFailure)?.kind, kind) }
        }
    }

    @MainActor
    func testPermissionIsSeparateForEachSourceAndNativeIsDefault() {
        let suite = "GeminiNativePreferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.geminiSource, .nativeApp)
        XCTAssertFalse(preferences.geminiCredentialAccessAllowed)
        preferences.geminiSource = .chrome
        preferences.geminiCredentialAccessAllowed = true
        preferences.geminiSource = .edge
        XCTAssertFalse(preferences.geminiCredentialAccessAllowed)
        preferences.geminiSource = .nativeApp
        XCTAssertFalse(preferences.geminiCredentialAccessAllowed)
        preferences.geminiCredentialAccessAllowed = true
        let restored = AppPreferences(defaults: defaults)
        XCTAssertEqual(restored.geminiSource, .nativeApp)
        XCTAssertTrue(restored.geminiCredentialAccessAllowed)
    }

    func testConcurrentGoogleReadsShareOneRefreshAndSameToken() async throws {
        let files = try nativeFiles()
        let http = MockHTTPClient([httpResponse(json: #"{"access_token":"shared-token","expires_in":3600}"#)])
        let session = GoogleAISession(authStore: try store(files: files), client: GeminiNativeUsageClient(http: http),
                                      dateProvider: FixedDateProvider(value: now))
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await session.access().token } }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(tokens.count, 10)
        XCTAssertEqual(Set(tokens), ["shared-token"])
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
        let body = String(decoding: requests[0].body!, as: UTF8.self)
        XCTAssertTrue(body.contains("assistant"))
        XCTAssertFalse(body.contains("cloud-platform"))
    }

    func testOldRejectionDoesNotDiscardNewlyRefreshedSharedToken() async throws {
        let files = try nativeFiles()
        let http = MockHTTPClient([httpResponse(json: #"{"access_token":"old","expires_in":3600}"#),
                                   httpResponse(json: #"{"access_token":"new","expires_in":3600}"#)])
        let session = GoogleAISession(authStore: try store(files: files), client: GeminiNativeUsageClient(http: http),
                                      dateProvider: FixedDateProvider(value: now))
        _ = try await session.access()
        _ = try await session.access(rejecting: "old")
        let current = try await session.access(rejecting: "old")
        XCTAssertEqual(current.token, "new")
        let count = await http.capturedRequests().count
        XCTAssertEqual(count, 2)
    }

    @MainActor
    func testOverageCreditPoolMapsLiveZeroOffShapeWithoutWarnings() throws {
        let gxu = pbMsg(1, pbVarint(1, 1_800_100_000)) + pbFloat(2, 0.25)
        let overage = pbVarint(2, 0) + pbVarint(3, 0)
            + pbStr(4, "Use AI credits")
            + pbStr(5, "Continue using Gemini with AI credits when you reach your plan’s limits.")
            + pbStr(6, "https://support.google.com/googleone/answer/16287445")
        let body = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, overage))
            + pbMsg(4, pbStr(1, "Disclaimer"))
            + pbMsg(5, pbStr(1, "Advanced"))

        let snapshot = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: body),
            now: now,
            accountLabel: "demo@example.invalid"
        )
        XCTAssertTrue(snapshot.allDiagnosticWarnings.isEmpty)
        XCTAssertEqual(snapshot.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 0 · Off")
        ])
        XCTAssertTrue(ProviderDetailsLayout.canExpand(snapshot))
    }

    func testOverageCreditPoolMapsPositiveCreditsExpiryAndToggleStates() throws {
        let gxu = pbMsg(1, pbVarint(1, 1_800_100_000)) + pbFloat(2, 0.1)
        let expirySeconds: UInt64 = 1_800_500_000
        let expiryDate = Date(timeIntervalSince1970: Double(expirySeconds))
        let enabledOverage = pbMsg(1, pbVarint(1, expirySeconds))
            + pbVarint(2, 1250)
            + pbVarint(3, 1)
        let enabledBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, enabledOverage))

        let enabled = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: enabledBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertEqual(enabled.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 1,250"),
            ProviderUsageDetail(
                id: "gemini.overage.credits.expiry",
                title: "AI Credits expire",
                value: expiryDate.formatted(date: .abbreviated, time: .shortened),
                targetDate: expiryDate
            )
        ])

        let disabledPositiveBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(2, 250) + pbVarint(3, 0)))
        let disabledPositive = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: disabledPositiveBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertEqual(disabledPositive.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 250 · Off")
        ])
    }

    func testOverageCreditPoolHandlesMissingNegativeDuplicateAndDetailsOnly() throws {
        let gxu = pbMsg(1, pbVarint(1, 1_800_100_000)) + pbFloat(2, 0.1)

        // Missing credits_remaining with use_overage_ai_credits=false -> Off
        let missingAmountBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(3, 0)))
        let missingAmount = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: missingAmountBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertEqual(missingAmount.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "Off")
        ])

        // Negative int64 credits_remaining (-5) must not become huge unsigned count
        let negativeAmountBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(2, UInt64(bitPattern: -5)) + pbVarint(3, 0)))
        let negativeAmount = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: negativeAmountBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertEqual(negativeAmount.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "Off")
        ])

        // Details-only response (OVERAGE_CREDITS only, no GxuPool) is valid
        let detailsOnlyBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(2, 400) + pbVarint(3, 1)))
        let detailsOnly = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: detailsOnlyBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertTrue(detailsOnly.windows.isEmpty)
        XCTAssertEqual(detailsOnly.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 400")
        ])

        // Duplicate OVERAGE_CREDITS pools must not duplicate detail IDs
        let duplicateBody = pbVarint(2, 2)
            + pbMsg(3, pbVarint(1, 1) + pbMsg(2, gxu))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(2, 300) + pbVarint(3, 1)))
            + pbMsg(3, pbVarint(1, 3) + pbMsg(3, pbVarint(2, 999) + pbVarint(3, 1)))
        let duplicate = try GeminiNativeUsageMapper.map(
            response: HTTPResponse(statusCode: 200, headers: [:], body: duplicateBody),
            now: now,
            accountLabel: nil
        )
        XCTAssertEqual(duplicate.usageDetails, [
            ProviderUsageDetail(id: "gemini.overage.credits", title: "Additional Credits", value: "AI Credits 300")
        ])
    }

    private var fakeClientSecret: String { "GOCSPX-" + String(repeating: "a", count: 28) }
    private func fakeBinary() -> Data {
        Data(clientID.utf8) + Data([0]) + Data(fakeClientSecret.utf8.map { $0 ^ 0x5a })
    }
    private func nativeFiles() throws -> NativeMemoryFiles {
        NativeMemoryFiles([
            GeminiNativeAuthStore.root + "/account_config": try Self.data(configHex),
            GeminiNativeAuthStore.root + "/Data/user1/auth": try Self.data(authHex),
            GeminiNativeAuthStore.root + "/Data/user2/auth": try Self.data(otherAuthHex),
            GeminiNativeAuthStore.binaryPath: fakeBinary()
        ])
    }
    private func store(files: NativeMemoryFiles) throws -> GeminiNativeAuthStore {
        let keys = try Self.data(keyStoreHex)
        return GeminiNativeAuthStore(allowNativeAccess: true, readData: { try files.read($0) }, readKeyStore: { keys })
    }
    private func usage() throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: try Self.data(usageHex))
    }
    private static func data(_ text: String) throws -> Data { try GeminiProtobuf.hexData(text) }

    private func pbTag(_ number: Int, wireType: Int) -> Data {
        pbRawVarint(UInt64((number << 3) | wireType))
    }
    private func pbVarint(_ number: Int, _ value: UInt64) -> Data {
        pbTag(number, wireType: 0) + pbRawVarint(value)
    }
    private func pbFloat(_ number: Int, _ value: Float) -> Data {
        var le = value.bitPattern.littleEndian
        return pbTag(number, wireType: 5) + Data(bytes: &le, count: 4)
    }
    private func pbMsg(_ number: Int, _ payload: Data) -> Data {
        pbTag(number, wireType: 2) + pbRawVarint(UInt64(payload.count)) + payload
    }
    private func pbStr(_ number: Int, _ text: String) -> Data {
        pbMsg(number, Data(text.utf8))
    }
    private func pbRawVarint(_ value: UInt64) -> Data {
        var v = value
        var out = Data()
        while true {
            var byte = UInt8(v & 0x7f)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
            if v == 0 { break }
        }
        return out
    }
}

private final class NativeMemoryFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var data: [String: Data]
    private var paths: [String] = []
    var reads: [String] { lock.withLock { paths } }
    init(_ data: [String: Data]) { self.data = data }
    func read(_ path: String) throws -> Data {
        try lock.withLock {
            paths.append(path)
            guard let value = data[path] else { throw CocoaError(.fileReadNoSuchFile) }
            return value
        }
    }
    func set(_ path: String, _ value: Data) { lock.withLock { data[path] = value } }
}
