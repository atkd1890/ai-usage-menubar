import Foundation

struct GoogleAIAccess: Sendable {
    let token: String
    let accountLabel: String?
    let fingerprint: Data
    let expiresAt: Date
}

/// Memory-only, account-bound session for the Gemini native quota adapter.
actor GoogleAISession {
    private let authStore: GeminiNativeAuthStore
    private let client: GeminiNativeUsageClient
    private let dateProvider: any DateProviding
    private var cached: GoogleAIAccess?
    private var pending: (id: UUID, fingerprint: Data, task: Task<GoogleAIAccess, Error>)?

    init(authStore: GeminiNativeAuthStore = GeminiNativeAuthStore(),
         client: GeminiNativeUsageClient = GeminiNativeUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider()) {
        self.authStore = authStore; self.client = client; self.dateProvider = dateProvider
    }

    func access(rejecting rejected: String? = nil) async throws -> GoogleAIAccess {
        try Task.checkCancellation()
        let credential: GeminiNativeCredential
        do { credential = try authStore.load() }
        catch { cached = nil; pending?.task.cancel(); pending = nil; throw error }
        if let cached, cached.fingerprint != credential.fingerprint { self.cached = nil }
        if let pending, pending.fingerprint != credential.fingerprint { pending.task.cancel(); self.pending = nil }
        if let cached, cached.token != rejected, cached.expiresAt.timeIntervalSince(dateProvider.now()) > 60 { return cached }
        if let rejected, cached?.token == rejected { cached = nil }
        let flight: (id: UUID, fingerprint: Data, task: Task<GoogleAIAccess, Error>)
        if let pending { flight = pending }
        else {
            let client = self.client
            let config = try authStore.loadClient(for: credential.clientID)
            let now = dateProvider.now()
            flight = (UUID(), credential.fingerprint, Task {
                let token = try await client.refresh(credential: credential, client: config, now: now,
                    scope: "https://www.googleapis.com/auth/assistant")
                return GoogleAIAccess(token: token.value, accountLabel: credential.accountLabel,
                    fingerprint: credential.fingerprint, expiresAt: now.addingTimeInterval(token.expiresIn))
            })
            pending = flight
        }
        do {
            let result = try await flight.task.value
            try validate(result)
            if pending?.id == flight.id { cached = result; pending = nil }
            try Task.checkCancellation()
            return result
        } catch {
            if pending?.id == flight.id { pending = nil }
            throw error
        }
    }

    func validate(_ access: GoogleAIAccess) throws {
        let current: GeminiNativeCredential
        do { current = try authStore.load() }
        catch { cached = nil; pending?.task.cancel(); pending = nil; throw error }
        guard current.fingerprint == access.fingerprint else {
            throw ProviderFailure(.transient, "Google account changed. Refresh usage again.")
        }
    }
}
