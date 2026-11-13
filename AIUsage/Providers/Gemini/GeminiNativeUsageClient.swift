import Foundation

struct GeminiNativeAccessToken: Sendable {
    let value: String
    let expiresIn: TimeInterval
}
struct GeminiNativeUsageClient: Sendable {
    static let refreshURL = URL(string: "https://oauth2.googleapis.com/token")!
    static let usageURL = URL(string: "https://robinfrontend-pa.googleapis.com/$rpc/assistant.mobile.robin.RobinService/GetUsageInfo")!
    let http: any HTTPClient
    init(http: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: ["oauth2.googleapis.com", "robinfrontend-pa.googleapis.com"])) {
        self.http = http
    }
    func refresh(credential: GeminiNativeCredential, client: GeminiNativeOAuthClient, now: Date, scope: String = "https://www.googleapis.com/auth/assistant") async throws -> GeminiNativeAccessToken {
        let response = try await http.send(HTTPRequest(method: .post, url: Self.refreshURL,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: ProviderParsing.formBody([
                ("grant_type", "refresh_token"), ("client_id", client.clientID),
                ("client_secret", client.clientSecret), ("refresh_token", credential.refreshToken),
                ("scope", scope)
            ])))
        if response.statusCode == 429 {
            throw ProviderFailure(.rateLimited, "Gemini sign-in refresh is rate limited.",
                retryAt: ProviderParsing.retryDate(from: response, now: now))
        }
        guard (200..<300).contains(response.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            if object?["error"] as? String == "invalid_grant" { throw GeminiNativeAuthStore.signInRequired }
            throw ProviderFailure(response.statusCode >= 500 ? .transient : .invalidResponse,
                "Gemini app sign-in could not be refreshed (\(response.statusCode)).")
        }
        guard let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let value = body["access_token"] as? String, !value.isEmpty else {
            throw ProviderFailure(.invalidResponse, "Gemini token response changed.")
        }
        let expires = ProviderParsing.double(body["expires_in"]) ?? 3600
        guard expires.isFinite, expires > 0 else { throw GeminiUsageMapper.changedResponse }
        return GeminiNativeAccessToken(value: value, expiresIn: expires)
    }
    func fetchUsage(token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(method: .post, url: Self.usageURL, headers: [
            "Authorization": "Bearer \(token)", "Content-Type": "application/x-protobuf",
            "Accept": "application/x-protobuf", "X-Goog-Api-Format-Version": "2"
        ], body: Data()))
    }
}
