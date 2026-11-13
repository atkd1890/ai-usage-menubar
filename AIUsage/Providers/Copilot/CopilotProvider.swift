import Foundation

actor CopilotProvider: UsageProvider {
    nonisolated let id = ProviderID.copilot

    private let authStore: CopilotAuthStore
    private let client: CopilotUsageClient
    private let dateProvider: DateProviding
    private let identity: AccountIdentityClient?
    private let identityCache = AccountIdentityCache(provider: .copilot, source: "oauth")
    private let method: @Sendable () -> ProviderLoginMethod

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        client: CopilotUsageClient = CopilotUsageClient(),
        dateProvider: DateProviding = SystemDateProvider(),
        method: @escaping @Sendable () -> ProviderLoginMethod = { .editorFallback },
        identity: AccountIdentityClient? = nil
    ) {
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
        self.method = method
        self.identity = identity
    }

    func fetch() async throws -> ProviderSnapshot {
        var seen: Set<String> = []
        var sawForbidden = false
        // Editor tokens can remain on disk after revocation. Do not let one
        // stale credential hide a valid GitHub CLI login. Keep fallback lazy.
        let method = method()
        for phase in 0..<2 where (method != .cli || phase == 1) && (method != .editor || phase == 0) {
            let candidates = phase == 0
                ? authStore.loadEditorTokens()
                : authStore.loadFallbackTokens()
            for candidate in candidates where seen.insert(candidate.value).inserted {
                let response: HTTPResponse
                do {
                    response = try await client.fetchUsage(token: candidate.value)
                } catch let failure as ProviderFailure {
                    throw failure
                } catch {
                    throw ProviderFailure(.transient, "GitHub Copilot could not be reached.")
                }

                if Self.isRateLimited(response) {
                    throw ProviderFailure(
                        .rateLimited,
                        "GitHub Copilot is rate limited. Try again later.",
                        retryAt: Self.retryDate(response, now: dateProvider.now())
                    )
                }
                if response.statusCode == 401 || response.statusCode == 403 {
                    sawForbidden = sawForbidden || response.statusCode == 403
                    continue
                }
                let snapshot = try CopilotUsageMapper.map(response: response, now: dateProvider.now())
                if let identity {
                    let email = await identityCache.read(credential: candidate.value) { try await identity.github(candidate.value) }
                    return snapshot.withCredential(source: phase == 0 ? "Editor login" : "GitHub CLI", account: email, email: email)
                }
                return snapshot
            }
        }
        guard !seen.isEmpty else {
            throw ProviderFailure(
                .authentication,
                "Not logged in. Sign in to GitHub Copilot or run `gh auth login`."
            )
        }
        throw ProviderFailure(.authentication, sawForbidden
            ? "GitHub Copilot access denied. Check token permissions, subscription, or organization policy."
            : "Saved GitHub credentials were rejected. Sign in to Copilot or run `gh auth login` again.")
    }

    /// GitHub reports its rate limits as `429`, or as `403` with an
    /// exhausted `x-ratelimit-remaining` or a `Retry-After`. Neither means
    /// the token was rejected.
    static func isRateLimited(_ response: HTTPResponse) -> Bool {
        response.statusCode == 429 ||
            (response.statusCode == 403 &&
                (response.header("x-ratelimit-remaining") == "0" ||
                    response.header("Retry-After") != nil))
    }

    private static func retryDate(_ response: HTTPResponse, now: Date) -> Date {
        if response.header("Retry-After") == nil,
           let reset = ProviderParsing.double(response.header("x-ratelimit-reset")) {
            let delay = min(
                max(reset - now.timeIntervalSince1970, 0),
                ProviderParsing.maximumRetryDelay
            )
            return now.addingTimeInterval(delay)
        }
        return ProviderParsing.retryDate(from: response, now: now)
    }
}
