import Foundation

struct CursorUsageClient: Sendable {
    static let usageURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
    )!
    static let planURL = URL(
        string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo"
    )!
    static let refreshURL = URL(
        string: "https://api2.cursor.sh/oauth/token"
    )!
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    let http: HTTPClient

    init(http: HTTPClient = CursorHTTPClient()) {
        self.http = http
    }

    func refresh(_ refreshToken: String) async throws -> HTTPResponse {
        let body = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken
        ])
        return try await http.send(HTTPRequest(
            method: .post,
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: body
        ))
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.usageURL, accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.planURL, accessToken: accessToken)
    }


    func fetchDashboard(accessToken: String, path: String, post: Bool = false) async throws -> HTTPResponse {
        let cookie = try Self.sessionCookie(accessToken: accessToken)
        let allowed = ["/api/dashboard/v2/usage-status?scope=user", "/api/dashboard/get-sand-usage-status"]
        guard allowed.contains(path) else { throw ProviderFailure(.invalidResponse, "Unexpected Cursor endpoint.") }
        return try await http.send(HTTPRequest(
            method: post ? .post : .get,
            url: URL(string: "https://cursor.com" + path)!,
            headers: ["Cookie": cookie,
                      "Accept": "application/json", "Content-Type": "application/json", "Origin": "https://cursor.com"],
            body: post ? Data("{}".utf8) : nil
        ))
    }

    static func sessionCookie(accessToken: String) throws -> String {
        guard let payload = accessToken.split(separator: ".").dropFirst().first,
              let data = ProviderParsing.base64URLData(String(payload)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String,
              let user = subject.split(separator: "|").last,
              user.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw ProviderFailure(.authentication, "Cursor account identity is unavailable.")
        }
        return "WorkosCursorSessionToken=\(user)%3A%3A\(accessToken)"
    }

    private func connectPost(
        _ url: URL,
        accessToken: String
    ) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: Data("{}".utf8)
        ))
    }
}

private final class CursorNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

actor CursorHTTPClient: HTTPClient {
    private let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        session = URLSession(configuration: config, delegate: CursorNoRedirects(), delegateQueue: nil)
    }
    func send(_ input: HTTPRequest) async throws -> HTTPResponse {
        guard input.url.scheme == "https", ["cursor.com", "api2.cursor.sh"].contains(input.url.host ?? "") else {
            throw ProviderFailure(.invalidResponse, "Unexpected Cursor host.")
        }
        var request = URLRequest(url: input.url)
        request.httpMethod = input.method.rawValue
        request.httpBody = input.body
        for (key, value) in input.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProviderFailure(.transient, "Cursor could not be reached.") }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String { headers[key] = String(describing: value) } }
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}
