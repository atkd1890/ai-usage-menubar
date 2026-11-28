import Foundation

actor GeminiProvider: UsageProvider {
    nonisolated let id = ProviderID.gemini
    private let authStore: GeminiAuthStore
    private let client: GeminiUsageClient
    private let source: GeminiCredentialSource?
    private let native: GeminiNativeProvider
    private let dateProvider: any DateProviding
    private let identity: AccountIdentityClient?
    private let mediaCredits: GoogleFlowCredits?
    private let identityCache = AccountIdentityCache(provider: .gemini, source: "browser")

    init(authStore: GeminiAuthStore = GeminiAuthStore(),
         client: GeminiUsageClient = GeminiUsageClient(),
         dateProvider: any DateProviding = SystemDateProvider(),
         source: GeminiCredentialSource? = nil,
         native: GeminiNativeProvider = GeminiNativeProvider(),
         identity: AccountIdentityClient? = nil,
         mediaCredits: GoogleFlowCredits? = nil) {
        self.source = source
        self.identity = identity
        self.native = native
        self.authStore = authStore
        self.client = client
        self.dateProvider = dateProvider
        self.mediaCredits = mediaCredits
    }

    func fetch() async throws -> ProviderSnapshot {
        let selected = source ?? GeminiCredentialSource.selected
        if selected.usesNativeApp {
            let snapshot = try await native.fetch()
            guard let mediaCredits else { return snapshot }
            // Keep `credentialSource` as "Gemini app" so combined modes preserve existing UsageHistory series.
            return snapshot.mergingMediaCredits(await mediaCredits.fetch(source: selected, googleSession: nil))
        }
        let login = try authStore.loadSession(source: selected)
        let response: HTTPResponse
        do { response = try await client.fetchUsage(session: login) }
        catch let error as ProviderFailure { throw error }
        catch { throw ProviderFailure(.transient, "Gemini web usage could not be reached.") }
        var value = try GeminiUsageMapper.map(response: response, now: dateProvider.now(), sourceLabel: selected.title)
        if let mediaCredits {
            value = value.mergingMediaCredits(await mediaCredits.fetch(source: selected, googleSession: login))
        }
        if let identity {
            let email = await identityCache.read(credential: login.cookieHeader.components(separatedBy: "; ").first(where: { $0.hasPrefix("__Secure-1PSID=") }) ?? login.cookieHeader) { try await identity.googleDefault(login.cookieHeader) }
            return value.withCredential(source: selected.title, account: email, email: email)
        }
        return value
    }
}

extension ProviderSnapshot {
    func mergingMediaCredits(_ media: GoogleFlowCreditsResult) -> Self {
        guard !media.isEmpty else { return self }
        var updatedWindows = windows
        if let notebookSession = media.notebookLMSession,
           !updatedWindows.contains(where: { $0.kind.rawValue == "additional:gemini.notebooklm.session" }) {
            updatedWindows.append(GoogleFlowCredits.percentWindow(
                id: "gemini.notebooklm.session",
                title: "NotebookLM Session",
                reading: notebookSession
            ))
        }
        if let notebookWeekly = media.notebookLMWeekly,
           !updatedWindows.contains(where: { $0.kind.rawValue == "additional:gemini.notebooklm.weekly" }) {
            updatedWindows.append(GoogleFlowCredits.percentWindow(
                id: "gemini.notebooklm.weekly",
                title: "NotebookLM Weekly",
                reading: notebookWeekly
            ))
        }
        if let flow = media.flow, !updatedWindows.contains(where: { $0.kind.rawValue == "additional:gemini.flow" }) {
            updatedWindows.append(GoogleFlowCredits.window(
                id: "gemini.flow",
                title: "Flow Video Monthly",
                reading: flow,
                allotment: GoogleFlowCredits.flowAllotment(forPlan: planName)
            ))
        }
        if let music = media.music, !updatedWindows.contains(where: { $0.kind.rawValue == "additional:gemini.flowmusic" }) {
            updatedWindows.append(GoogleFlowCredits.window(
                id: "gemini.flowmusic",
                title: "Flow Music Monthly",
                reading: music,
                allotment: GoogleFlowCredits.flowMusicAllotment(forPlan: planName)
            ))
        }
        if let stitch = media.stitch, !updatedWindows.contains(where: { $0.kind.rawValue == "additional:gemini.stitch" }) {
            updatedWindows.append(GoogleFlowCredits.stitchWindow(
                id: "gemini.stitch",
                title: "Stitch Daily",
                reading: stitch
            ))
        }
        let mergedWarnings = ResponseSchemaWatch.deduplicated(diagnosticWarnings + media.diagnosticWarnings)
        return Self(provider: provider, planName: planName, windows: updatedWindows, billingUsage: billingUsage,
                    resets: resets, fetchedAt: fetchedAt, xSubscription: xSubscription,
                    credentialSource: credentialSource, accountLabel: accountLabel,
                    accountEmail: accountEmail, usageScope: usageScope,
                    usageDetails: usageDetails,
                    prepaidBalance: prepaidBalance,
                    additionalUsageEnabled: additionalUsageEnabled,
                    additionalUsageResetsAt: additionalUsageResetsAt,
                    usageBreakdown: usageBreakdown,
                    quotaSections: quotaSections,
                    diagnosticWarnings: mergedWarnings)
    }
}
