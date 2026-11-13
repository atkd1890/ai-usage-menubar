import Foundation

actor GeminiProvider: UsageProvider {
    nonisolated let id = ProviderID.gemini
    private let authStore: GeminiAuthStore
    private let client: GeminiUsageClient
    private let source: GeminiCredentialSource?
    private let native: GeminiNativeProvider
    private let dateProvider: any DateProviding
    private let identity: AccountIdentityClient?
    private let identityCache = AccountIdentityCache(provider: .gemini, source: "browser")

    init(authStore: GeminiAuthStore = GeminiAuthStore(),
         client: GeminiUsageClient = GeminiUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider(),
         source: GeminiCredentialSource? = nil,
         native: GeminiNativeProvider = GeminiNativeProvider(),
         identity: AccountIdentityClient? = nil) {
        self.source = source
        self.identity = identity
        self.native = native
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
    }
    func fetch() async throws -> ProviderSnapshot {
        let selected = source ?? GeminiCredentialSource.selected
        if selected == .nativeApp { return try await native.fetch() }
        let login = try authStore.loadSession(source: selected)
        let response: HTTPResponse
        do { response = try await client.fetchUsage(session: login) }
        catch let error as ProviderFailure { throw error }
        catch { throw ProviderFailure(.transient, "Gemini web usage could not be reached.") }
        let value = try GeminiUsageMapper.map(response: response, now: dateProvider.now(), sourceLabel: selected.title)
        if let identity {
            let email = await identityCache.read(credential: login.cookieHeader.components(separatedBy: "; ").first(where: { $0.hasPrefix("__Secure-1PSID=") }) ?? login.cookieHeader) { try await identity.googleDefault(login.cookieHeader) }
            return value.withCredential(source: selected.title, account: email, email: email)
        }
        return value
    }
}
