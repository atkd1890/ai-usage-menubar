import Foundation

/// No fallback to another app's identity: both quota reads use the active Gemini account.
actor GoogleAIAntigravityProvider: UsageProvider {
    nonisolated let id = ProviderID.antigravity
    private let session: GoogleAISession
    private let client: AntigravityUsageClient
    private let dateProvider: any DateProviding

    init(session: GoogleAISession,
         client: AntigravityUsageClient = AntigravityUsageClient(http: GeminiReadOnlyHTTPClient(
            allowedHosts: ["cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com"])),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.session = session; self.client = client; self.dateProvider = dateProvider
    }

    func fetch() async throws -> ProviderSnapshot {
        var access = try await session.access()
        for attempt in 0...1 {
            var plan: String?
            var project: String?
            switch await client.loadCodeAssist(accessToken: access.token) {
            case .success(let data):
                plan = AntigravityUsageMapper.plan(data)
                project = AntigravityUsageMapper.project(data)
            case .tokenRefused:
                if attempt == 0 { access = try await session.access(rejecting: access.token); continue }
                throw GeminiNativeAuthStore.signInRequired
            case .denied, .unavailable: break
            }
            let outcome = await client.quotaSummary(accessToken: access.token, project: project, now: dateProvider.now())
            try await session.validate(access)
            try Task.checkCancellation()
            switch outcome {
            case .success(let bodies):
                guard let value = AntigravityUsageMapper.summary(bodies, planName: plan, now: dateProvider.now()),
                      !value.windows.isEmpty else {
                    throw ProviderFailure(.invalidResponse, "Antigravity quota response changed.")
                }
                return ProviderSnapshot(provider: .antigravity, planName: value.planName, windows: value.windows,
                    billingUsage: value.billingUsage, resets: value.resets, fetchedAt: value.fetchedAt,
                    credentialSource: "Gemini app · shared Google AI login", accountLabel: access.accountLabel,
                    usageScope: value.usageScope, usageDetails: value.usageDetails)
            case .tokenRefused:
                if attempt == 0 { access = try await session.access(rejecting: access.token); continue }
                throw GeminiNativeAuthStore.signInRequired
            case .denied:
                throw ProviderFailure(.authentication, "Antigravity quota access denied for the active Gemini account.")
            case .rateLimited(let retry):
                throw ProviderFailure(.rateLimited, "Antigravity quota is rate limited.", retryAt: retry)
            case .unavailable:
                throw ProviderFailure(.transient, "Antigravity quota could not be reached.")
            }
        }
        throw GeminiNativeAuthStore.signInRequired
    }
}
