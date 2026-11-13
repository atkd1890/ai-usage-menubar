import Foundation

struct GeminiUsageClient: Sendable {
    // UsagePageQuery from Gemini's UsagePageSurface; not the Cloud Code API.
    static let querySignature = "2/dWbCvkVB0X16r9NPnxifeOAAqdCqMf0xeWvau9yPy7g="
    static let usageURL: URL = {
        var url = URLComponents(string: "https://gemini.google.com/_/BardChatUi/graphql/schemas/GEMINI_WEB_GRAPHQL/executeQuery")!
        let variables = #"{"g1Request":{"entrypoints":["GEMINI_USAGE_SETTINGS_UPGRADE_BANNER"]},"workspaceRequest":{"recommendationsForSurfaceRequests":[]}}"#
        url.queryItems = [URLQueryItem(name: "authuser", value: "0"), URLQueryItem(name: "query_signature", value: querySignature),
                          URLQueryItem(name: "variables", value: variables)]
        return url.url!
    }()
    let http: any HTTPClient

    init(http: any HTTPClient = GeminiReadOnlyHTTPClient()) { self.http = http }

    func fetchUsage(session: GeminiWebSession) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(method: .get, url: Self.usageURL, headers: [
            "Accept": "application/json",
            "Referer": "https://gemini.google.com/usage",
            "Cookie": session.cookieHeader
        ]))
    }
}

/// Never forward the supplied Google session to a redirect destination.
private final class GeminiNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor GeminiReadOnlyHTTPClient: HTTPClient {
    private let session: URLSession
    private let allowedHosts: Set<String>
    init(allowedHosts: Set<String> = ["gemini.google.com"], timeout: TimeInterval = 20) {
        self.allowedHosts = allowedHosts
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 1.5
        session = URLSession(configuration: config, delegate: GeminiNoRedirects(), delegateQueue: nil)
    }
    func send(_ input: HTTPRequest) async throws -> HTTPResponse {
        guard let host = input.url.host, allowedHosts.contains(host), input.url.scheme == "https" else {
            throw ProviderFailure(.invalidResponse, "Unexpected Gemini usage host.")
        }
        var request = URLRequest(url: input.url)
        request.httpMethod = input.method.rawValue
        request.httpBody = input.body
        for (key, value) in input.headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ProviderFailure(.transient, "Gemini could not be reached.")
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String { headers[key] = String(describing: value) }
        }
        return HTTPResponse(statusCode: response.statusCode, headers: headers, body: data)
    }
}
