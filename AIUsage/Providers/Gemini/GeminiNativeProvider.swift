import Foundation

actor GeminiNativeProvider: UsageProvider {
    nonisolated let id = ProviderID.gemini
    private let session: GoogleAISession
    private let client: GeminiNativeUsageClient
    private let dateProvider: any DateProviding

    init(authStore: GeminiNativeAuthStore = GeminiNativeAuthStore(),
         client: GeminiNativeUsageClient = GeminiNativeUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider(),
         session: GoogleAISession? = nil) {
        self.session = session ?? GoogleAISession(authStore: authStore, client: client, dateProvider: dateProvider)
        self.client = client; self.dateProvider = dateProvider
    }
    func fetch() async throws -> ProviderSnapshot {
        do {
            var access = try await session.access()
            var response = try await client.fetchUsage(token: access.token)
            if response.statusCode == 401 {
                access = try await session.access(rejecting: access.token)
                response = try await client.fetchUsage(token: access.token)
            }
            try await session.validate(access)
            try Task.checkCancellation()
            return try GeminiNativeUsageMapper.map(response: response, now: dateProvider.now(), accountLabel: access.accountLabel)
        } catch let failure as ProviderFailure { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProviderFailure(.transient, "Gemini native usage could not be reached.") }
    }
}
