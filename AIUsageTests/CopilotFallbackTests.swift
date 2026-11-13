import XCTest
@testable import AIUsage

final class CopilotFallbackTests: XCTestCase {
    private let success = httpResponse(json: """
        {"copilot_plan":"individual_pro","quota_snapshots":{
          "premium_interactions":{"entitlement":300,"remaining":225}}}
        """)

    func testRejectedEditorTokenFallsBackToKeychain() async throws {
        let http = MockHTTPClient([httpResponse(401), success])
        let keys = MemoryKeychain(generic: [CopilotAuthStore.ghKeychainService: "go-keyring-base64:Z2gtdG9rZW4="])
        let snapshot = try await provider(http: http, keychain: keys).fetch()
        XCTAssertEqual(snapshot.windows.first?.usedPercent, 25)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["token editor-token", "token gh-token"])
    }

    func testValidEditorAvoidsFallbackKeychainRead() async throws {
        let http = MockHTTPClient([success])
        let keys = MemoryKeychain()
        _ = try await provider(http: http, keychain: keys).fetch()
        XCTAssertTrue(keys.genericReads.isEmpty)
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTriesOtherEditorConfigBeforeCLI() async throws {
        let files = MemoryFiles([
            CopilotAuthStore.editorAppsPath: "{\"github.com\":{\"oauth_token\":\"old-token\"}}",
            CopilotAuthStore.editorHostsPath: "{\"github.com\":{\"oauth_token\":\"valid-token\"}}"
        ])
        let keys = MemoryKeychain()
        let http = MockHTTPClient([httpResponse(401), success])
        _ = try await CopilotProvider(authStore: CopilotAuthStore(files: files, keychain: keys), client: CopilotUsageClient(http: http)).fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["token old-token", "token valid-token"])
        XCTAssertTrue(keys.genericReads.isEmpty)
    }

    func testAllEditorEntriesAreDeterministicAndIgnoreOtherHosts() {
        XCTAssertEqual(CopilotAuthStore.oauthTokens(fromEditorJSON: """
            {"github.com:b":{"oauth_token":"second"},
             "example.com":{"oauth_token":"unrelated"},
             "github.com:a":{"oauth_token":" first "},
             "github.com:c":{"oauth_token":" "}}
            """), ["first", "second"])
    }

    func testDuplicateTokensAreNotRequestedAgain() async throws {
        let files = MemoryFiles([
            CopilotAuthStore.editorAppsPath: "{\"github.com\":{\"oauth_token\":\"same-token\"}}",
            CopilotAuthStore.editorHostsPath: "{\"github.com\":{\"oauth_token\":\"same-token\"}}",
            CopilotAuthStore.ghHostsPath: "github.com:\n    oauth_token: same-token"
        ])
        let keys = MemoryKeychain(generic: [CopilotAuthStore.ghKeychainService: "valid-token"])
        let http = MockHTTPClient([httpResponse(401), success])
        _ = try await CopilotProvider(authStore: CopilotAuthStore(files: files, keychain: keys), client: CopilotUsageClient(http: http)).fetch()
        let requests = await http.capturedRequests()
        XCTAssertEqual(requests.map { $0.headers["Authorization"] }, ["token same-token", "token valid-token"])
    }

    func testRateLimitsAndServerErrorsDoNotTryFallback() async {
        for response in [httpResponse(429), httpResponse(403, headers: ["x-ratelimit-remaining":"0"]), httpResponse(503)] {
            let keys = MemoryKeychain(generic: [CopilotAuthStore.ghKeychainService: "gh-token"])
            let http = MockHTTPClient([response])
            do {
                _ = try await provider(http: http, keychain: keys).fetch()
                XCTFail("Expected a failure")
            } catch {
                XCTAssertEqual((error as? ProviderFailure)?.kind, response.statusCode == 503 ? .transient : .rateLimited)
            }
            XCTAssertTrue(keys.genericReads.isEmpty)
            let requests = await http.capturedRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testNetworkFailureDoesNotTryFallback() async {
        let keys = MemoryKeychain()
        let http = MockHTTPClient([])
        do {
            _ = try await provider(http: http, keychain: keys).fetch()
            XCTFail("Expected failure")
        } catch { XCTAssertEqual((error as? ProviderFailure)?.kind, .transient) }
        XCTAssertTrue(keys.genericReads.isEmpty)
    }

    func testForbiddenCredentialCanFallBackButReportsPermissionsIfAllFail() async throws {
        let keys = MemoryKeychain(generic: [CopilotAuthStore.ghKeychainService: "gh-token"])
        _ = try await provider(http: MockHTTPClient([httpResponse(403), success]), keychain: keys).fetch()
        do {
            _ = try await provider(http: MockHTTPClient([httpResponse(403), httpResponse(401)]), keychain: keys).fetch()
            XCTFail("Expected failure")
        } catch {
            XCTAssertTrue((error as? ProviderFailure)?.message.contains("access denied") == true)
        }
    }

    func testAllRejectedAndNoCredentialsHaveDifferentMessages() async {
        do {
            _ = try await provider(http: MockHTTPClient([httpResponse(401)]), keychain: MemoryKeychain()).fetch()
            XCTFail("Expected failure")
        } catch { XCTAssertTrue((error as? ProviderFailure)?.message.contains("were rejected") == true) }
        do {
            _ = try await CopilotProvider(authStore: CopilotAuthStore(files: MemoryFiles(), keychain: MemoryKeychain()), client: CopilotUsageClient(http: MockHTTPClient([]))).fetch()
            XCTFail("Expected failure")
        } catch { XCTAssertTrue((error as? ProviderFailure)?.message.contains("Not logged in") == true) }
    }

    private func provider(http: MockHTTPClient, keychain: MemoryKeychain) -> CopilotProvider {
        CopilotProvider(authStore: CopilotAuthStore(files: MemoryFiles([
            CopilotAuthStore.editorAppsPath: "{\"github.com\":{\"oauth_token\":\"editor-token\"}}"
        ]), keychain: keychain), client: CopilotUsageClient(http: http))
    }
}
