import CryptoKit
import Foundation

actor MuseProvider: UsageProvider {
    nonisolated let id = ProviderID.muse
    static let origin = "https://muse.ai"
    static let actionKey = "muse.subscriptionAction.v1"
    // Verified read-only subscription action; deployments can replace this ID.
    static let verifiedAction = "406cd44441421b58cea8309747129141947de9f499"
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    private let http: any HTTPClient
    private let loadCookies: @Sendable () throws -> (cookie: String, sourceLabel: String)
    private let pageScripts: @Sendable (String) async throws -> [String]
    private let saveAction: @Sendable (String) -> Void
    private var action: String
    init(http: any HTTPClient = GeminiReadOnlyHTTPClient(allowedHosts: ["muse.ai"]),
         cookies: (@Sendable () throws -> String)? = nil,
         method: (@Sendable () -> ProviderLoginMethod)? = nil,
         sessions: WebSessionStore = WebSessionStore(),
         action: String? = UserDefaults.standard.string(forKey: MuseProvider.actionKey),
         pageScripts: @escaping @Sendable (String) async throws -> [String] = { try await MusePageScripts.load(cookie: $0) },
         saveAction: @escaping @Sendable (String) -> Void = { UserDefaults.standard.set($0, forKey: MuseProvider.actionKey) }) {
        self.http = http
        if let cookies {
            self.loadCookies = { (try cookies(), "Edge Default") }
        } else {
            let resolveMethod = method ?? { ProviderLoginMethod.selected(for: .muse) }
            self.loadCookies = {
                let selected = resolveMethod()
                let source: WebSessionSource = selected == .chrome ? .chrome : .edge
                let label = selected == .chrome ? "Chrome Default" : "Edge Default"
                let header = try sessions.cookies(source: source, domain: "muse.ai", names: ["hatch_sess", "hatch_gw"])
                return (header, label)
            }
        }
        self.pageScripts = pageScripts; self.saveAction = saveAction
        self.action = action.flatMap { Self.validAction($0) ? $0 : nil } ?? Self.verifiedAction
    }
    func fetch() async throws -> ProviderSnapshot {
        let (cookie, sourceLabel) = try loadCookies()
        guard let sessionCookie = cookie.components(separatedBy: "; ").first(where: { $0.hasPrefix("hatch_sess=") && $0.count > "hatch_sess=".count }) else {
            throw ProviderFailure(.authentication, "Sign in to Muse in \(sourceLabel).")
        }
        var extraWarnings: [ProviderDiagnosticWarning] = []
        var response = try await subscription(cookie: cookie, action: action)
        if [404, 409].contains(response.statusCode) || response.header("x-nextjs-action-not-found") == "1" {
            action = try await discover(cookie: cookie)
            response = try await subscription(cookie: cookie, action: action)
        }
        if action != Self.verifiedAction,
           let notice = ResponseSchemaWatch.confirmedNotice(
               id: "api.version.muse.action",
               provider: .muse,
               endpoint: "Muse",
               summary: "Muse Next-Action hash rotated",
               detail: "Using rediscovered Next-Action \(action) instead of hardcoded verifiedAction.",
               signature: "api.version.muse.action|\(action)"
           ) {
            extraWarnings.append(notice)
        }
        let fingerprint = Data(SHA256.hash(data: Data(sessionCookie.utf8))).map { String(format: "%02x", $0) }.joined()
        let value = try Self.map(
            response,
            historyID: "muse-session:" + fingerprint,
            credentialSource: sourceLabel,
            extraWarnings: extraWarnings
        )
        saveAction(action)
        return value
    }
    private func subscription(cookie: String, action: String) async throws -> HTTPResponse {
        guard Self.validAction(action) else { throw Self.changed }
        return try await http.send(HTTPRequest(method: .post, url: URL(string: Self.origin + "/")!, headers: [
            "Cookie": cookie, "Accept": "text/x-component", "Content-Type": "text/plain;charset=UTF-8",
            "Next-Action": action, "Origin": Self.origin, "Sec-Fetch-Site": "same-origin",
            "Sec-Fetch-Mode": "cors", "Sec-Fetch-Dest": "empty", "User-Agent": Self.userAgent
        ], body: Data(#"[{"includeAgreement":true}]"#.utf8)))
    }
    private func discover(cookie: String) async throws -> String {
        let paths = Array(try await pageScripts(cookie).filter(MuseScriptSources.allowed).prefix(MuseScriptSources.maxScriptCount))
        var text = ""
        for offset in stride(from: 0, to: paths.count, by: 8) {
            for chunk in await fetchChunks(Array(paths[offset..<min(offset + 8, paths.count)])) {
                text += chunk
                guard text.utf8.count <= 12_000_000 else { throw Self.changed }
                if let id = Self.actionID(in: chunk) { return id }
            }
            guard let module = Self.capture(#"\.A\((\d+)\)\.then\(\(\{[^}]*Settings"#, text),
                  let loader = Self.capture("[,{\\[]" + module + #",\w+=>\{\w+\.v\(\w+=>Promise\.all\(\[([^\]]*)"#, text) else { continue }
            let settings = Array(MuseScriptSources.chunkPaths(in: loader).prefix(32))
            for batch in stride(from: 0, to: settings.count, by: 8) {
                for chunk in await fetchChunks(Array(settings[batch..<min(batch + 8, settings.count)])) {
                    if let id = Self.actionID(in: chunk) { return id }
                }
            }
            break
        }
        throw Self.changed
    }
    private func fetchChunks(_ paths: [String]) async -> [String] {
        let http = self.http
        return await withTaskGroup(of: String.self) { group in
            for path in paths where MuseScriptSources.allowed(path) {
                group.addTask {
                    guard let response = try? await http.send(HTTPRequest(method: .get, url: URL(string: Self.origin + path)!,
                        headers: ["Accept": "*/*", "User-Agent": Self.userAgent], body: nil)),
                          response.statusCode == 200, response.body.count <= 4_000_000 else { return "" }
                    // Public JavaScript only; cookies never go to chunks.
                    return String(decoding: response.body, as: UTF8.self)
                }
            }
            var result: [String] = []
            for await text in group { result.append(text) }
            return result
        }
    }
    static func actionID(in text: String) -> String? {
        capture(#""([0-9a-f]{40,64})",[^"\n]{0,200}"fetchSubscriptionAction""#, text)
    }
    static func validAction(_ id: String) -> Bool { id.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil }
    static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    static var changed: ProviderFailure { ProviderFailure(.invalidResponse, "Muse subscription API changed. Refresh to retry compatibility discovery.") }
    static func map(
        _ response: HTTPResponse,
        historyID: String,
        credentialSource: String = "Edge Default",
        now: Date = Date(),
        extraWarnings: [ProviderDiagnosticWarning] = []
    ) throws -> ProviderSnapshot {
        if [401, 403].contains(response.statusCode) || (300..<400).contains(response.statusCode) {
            throw ProviderFailure(.authentication, "Muse session expired. Sign in to Muse in \(credentialSource).")
        }
        if response.statusCode == 429 { throw ProviderFailure(.rateLimited, "Muse usage is rate limited.") }
        guard response.statusCode == 200, response.body.count <= 1_000_000 else { throw changed }
        var matches: [[String: Any]] = []
        for line in String(decoding: response.body, as: UTF8.self).split(separator: "\n") {
            guard let raw = capture(#"^[0-9a-f]+:(\{.*\})\s*$"#, String(line)),
                  let row = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  row["success"] as? Bool == true, let sub = row["subscription"] as? [String: Any] else { continue }
            matches.append(sub)
        }
        guard matches.count == 1, let sub = matches.first, let usage = sub["usage"] as? [String: Any],
              let used = QuotaDiscovery.number(usage["percentUsed"]), (0...100).contains(used) else { throw changed }
        var warnings = extraWarnings
        warnings += ResponseSchemaWatch.httpHeaders(response, provider: .muse, endpoint: "Muse")
        warnings += ResponseSchemaWatch.jsonBodyDeprecation(sub, provider: .muse, endpoint: "Muse")
        warnings += ResponseSchemaWatch.confirmedJSONKeys(
            in: sub,
            provider: .muse,
            endpoint: "Muse subscription"
        )
        warnings += ResponseSchemaWatch.confirmedJSONKeys(
            in: usage,
            provider: .muse,
            endpoint: "Muse usage"
        )
        if let tierObj = sub["tier"] as? [String: Any] {
            warnings += ResponseSchemaWatch.confirmedJSONKeys(
                in: tierObj,
                provider: .muse,
                endpoint: "Muse tier"
            )
        }
        if let subscriptionType = ProviderParsing.string(sub["subscriptionType"]),
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               subscriptionType,
               provider: .muse,
               endpoint: "Muse subscription",
               field: "subscriptionType"
           ) {
            warnings.append(enumWarning)
        }
        if let usageState = ProviderParsing.string(usage["state"]),
           let enumWarning = ResponseSchemaWatch.confirmedEnum(
               usageState,
               provider: .muse,
               endpoint: "Muse usage",
               field: "state"
           ) {
            warnings.append(enumWarning)
        }
        let rawTier = (sub["tier"] as? [String: Any])?["name"] as? String
        let cleanedTier = rawTier?
            .replacingOccurrences(of: "muse", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        let tier = (cleanedTier?.isEmpty == false) ? cleanedTier : rawTier
        var billing: BillingUsage?
        var balance: MonetaryBalance?
        if let total = QuotaDiscovery.number(sub["topupTotal"]), total > 0,
           let remaining = QuotaDiscovery.number(sub["topupBalance"]), (0...total).contains(remaining) {
            billing = .boundedSpend(usedAmount: (total - remaining) / 1_000_000, limitAmount: total / 1_000_000, currencyCode: "USD")
            balance = MonetaryBalance(amount: remaining / 1_000_000, currencyCode: "USD")
        }
        return ProviderSnapshot(provider: .muse, planName: tier, windows: [QuotaWindow(kind: .weekly, usedPercent: used,
            resetsAt: ProviderParsing.date(usage["resetsAt"]))], billingUsage: billing, fetchedAt: now,
            credentialSource: credentialSource, accountLabel: historyID, usageScope: "Product usage • Muse",
            prepaidBalance: balance, additionalUsageEnabled: billing != nil,
            diagnosticWarnings: ResponseSchemaWatch.deduplicated(warnings))
    }
}
