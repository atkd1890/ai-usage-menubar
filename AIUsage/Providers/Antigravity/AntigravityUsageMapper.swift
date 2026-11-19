import Foundation

enum AntigravityUsageMapper {
    private static let sharedPoolKinds: [String: QuotaKind] = [
        "gemini-5h": .session,
        "gemini-weekly": .weekly,
        "3p-5h": .claudePool,
        "3p-weekly": .claudePoolWeekly
    ]
    private static let argonGroupName = "Gemini 4 Argon"
    private static let argonBucketIDs: Set<String> = [
        "gemini-argon-wtu-weekly",
        "gemini-argon-weekly"
    ]
    private static let order: [QuotaKind] = [
        .session, .weekly, .claudePool, .claudePoolWeekly, .argonWeekly
    ]
    private static let paidTierPlans = [
        "g1-pro-tier": "Google AI Pro",
        "g1-ultra-tier": "Google AI Ultra",
        "g1-ultra-lite-tier": "Google AI Ultra Lite"
    ]

    /// Maps host-tagged `RetrieveUserQuotaSummary` responses. When both
    /// `Antigravity` (`daily`) and `Antigravity IDE` (`prod`) respond with
    /// quota windows, Row 1 (`session` / `weekly`) combines both into dual-series
    /// readings while `quotaSections` exposes each app's full breakdown.
    static func summary(
        _ hostSummaries: [AntigravityHostSummary],
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        var parsedByHost: [AntigravityHost: (windows: [QuotaWindow], notices: [ProviderUsageDetail])] = [:]
        for item in hostSummaries where parsedByHost[item.host] == nil {
            if let parsed = parseSingleBody(item.data) {
                parsedByHost[item.host] = parsed
            }
        }
        let orderedHosts: [AntigravityHost] = [.app, .ide]
        let presentHosts = orderedHosts.filter { parsedByHost[$0] != nil }
        guard !presentHosts.isEmpty else { return nil }

        if presentHosts.count == 1, let onlyHost = presentHosts.first, let parsed = parsedByHost[onlyHost] {
            return ProviderSnapshot(
                provider: .antigravity,
                planName: planName,
                windows: parsed.windows,
                fetchedAt: now,
                usageScope: "Antigravity quota · separate from Gemini app",
                usageDetails: parsed.notices
            )
        }

        let sections = orderedHosts.compactMap { host -> ProviderQuotaSection? in
            guard let parsed = parsedByHost[host], !parsed.windows.isEmpty else { return nil }
            return ProviderQuotaSection(id: host.seriesID, title: host.displayName, windows: parsed.windows)
        }
        let quotaSections = sections.count >= 2 ? sections : []

        var mergedWindows: [QuotaWindow] = []
        for kind in [QuotaKind.session, .weekly] {
            let matches = orderedHosts.compactMap { host -> (host: AntigravityHost, window: QuotaWindow)? in
                guard let window = parsedByHost[host]?.windows.first(where: { $0.kind == kind }) else { return nil }
                return (host, window)
            }
            guard !matches.isEmpty else { continue }
            let series: [QuotaSeriesReading] = matches.count >= 2
                ? matches.map {
                    QuotaSeriesReading(
                        id: $0.host.seriesID,
                        title: $0.host.displayName,
                        usedPercent: $0.window.usedPercent,
                        resetsAt: $0.window.resetsAt
                    )
                }
                : []
            let usedPercent = matches.map(\.window.usedPercent).max() ?? 0
            let consumedResets = matches.filter { $0.window.usedPercent > 0 }.compactMap(\.window.resetsAt)
            let resetsAt = consumedResets.min() ?? matches.compactMap(\.window.resetsAt).min()
            mergedWindows.append(QuotaWindow(kind: kind, usedPercent: usedPercent, resetsAt: resetsAt, series: series))
        }

        for kind in [QuotaKind.claudePool, .claudePoolWeekly, .argonWeekly] {
            let matches = orderedHosts.compactMap { host in
                parsedByHost[host]?.windows.first(where: { $0.kind == kind })
            }
            if let best = matches.dropFirst().reduce(matches.first, { current, candidate in
                guard let current else { return candidate }
                return candidate.usedPercent > current.usedPercent ? candidate : current
            }) {
                mergedWindows.append(best)
            }
        }

        for host in orderedHosts {
            for window in parsedByHost[host]?.windows ?? [] where !order.contains(window.kind) {
                if !mergedWindows.contains(where: { $0.kind == window.kind }) {
                    mergedWindows.append(window)
                }
            }
        }

        var notices: [ProviderUsageDetail] = []
        var seenNoticeIDs: Set<String> = []
        for host in orderedHosts {
            for detail in parsedByHost[host]?.notices ?? [] where seenNoticeIDs.insert(detail.id).inserted {
                notices.append(detail)
            }
        }

        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: mergedWindows,
            fetchedAt: now,
            usageScope: "Antigravity quota · separate from Gemini app",
            usageDetails: notices,
            quotaSections: quotaSections
        )
    }

    /// Maps one or more `RetrieveUserQuotaSummary` bodies, merged by bucket id
    /// with the first usable bucket winning. A host can omit a whole pool, so
    /// no single body is trusted to be complete. Returns `nil` only when no
    /// body is a quota summary at all. Buckets without a usable
    /// `remainingFraction` are dropped rather than reported as 0% or 100%.
    static func summary(
        _ bodies: [Data],
        planName: String?,
        now: Date
    ) -> ProviderSnapshot? {
        let groupLists = bodies.compactMap(groups)
        guard !groupLists.isEmpty else { return nil }
        let parsed = parseGroupLists(groupLists)

        return ProviderSnapshot(
            provider: .antigravity,
            planName: planName,
            windows: parsed.windows,
            fetchedAt: now,
            usageScope: "Antigravity quota · separate from Gemini app",
            usageDetails: parsed.notices
        )
    }

    private static func parseSingleBody(_ data: Data) -> (windows: [QuotaWindow], notices: [ProviderUsageDetail])? {
        guard let groups = groups(data) else { return nil }
        return parseGroupLists([groups])
    }

    private static func parseGroupLists(
        _ groupLists: [[[String: Any]]]
    ) -> (windows: [QuotaWindow], notices: [ProviderUsageDetail]) {
        var windows: [QuotaWindow] = []
        for group in groupLists.joined()
        where ProviderParsing.string(group["displayName"]) != argonGroupName {
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(bucket["bucketId"]),
                      let kind = sharedPoolKinds[identifier], bucket["disabled"] as? Bool != true,
                      !windows.contains(where: { $0.kind == kind }),
                      let window = window(kind: kind, bucket: bucket)
                else {
                    continue
                }
                windows.append(window)
            }
        }
        // Argon is judged per body: combining two hosts' Argon groups would
        // read as an ambiguous bucket.
        if let argon = groupLists.lazy.compactMap(argonWindow).first {
            windows.append(argon)
        }

        var notices: [ProviderUsageDetail] = []
        var seen = Set<String>()
        for group in groupLists.joined() {
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let id = ProviderParsing.string(bucket["bucketId"]), sharedPoolKinds[id] == nil,
                      !argonBucketIDs.contains(id), ProviderParsing.string(group["displayName"]) != argonGroupName,
                      bucket["disabled"] as? Bool != true, !seen.contains(id) else { continue }
                guard let remaining = bucket["remainingFraction"], !(remaining is NSNull) else { continue }
                let groupName = ProviderParsing.string(group["displayName"]) ?? QuotaDiscovery.name(id)
                let cadence = ProviderParsing.string(bucket["window"]).map(QuotaDiscovery.name) ?? "Quota"
                if let window = QuotaDiscovery.window(id: "antigravity." + id, title: groupName + " · " + cadence,
                    used: QuotaDiscovery.fraction(bucket["remainingFraction"]), reset: ProviderParsing.date(bucket["resetTime"])) {
                    windows.append(window)
                    seen.insert(id)
                } else { notices.append(QuotaDiscovery.notice(id)) }
            }
        }

        let sortedWindows = windows.sorted {
            (order.firstIndex(of: $0.kind) ?? order.count) <
                (order.firstIndex(of: $1.kind) ?? order.count)
        }
        return (sortedWindows, notices)
    }

    /// A shared-pool-only answer can omit Argon. Stop host fallback only once
    /// every shared pool plus an actual Argon reading is available.
    static func isCompleteSummary(_ data: Data) -> Bool {
        guard let groups = groups(data) else { return false }
        let usable = Set(groups
            .filter {
                ProviderParsing.string($0["displayName"]) != argonGroupName
            }
            .flatMap { ProviderParsing.array($0["buckets"]) }
            .compactMap { bucket -> String? in
                guard ProviderParsing.double(bucket["remainingFraction"]) != nil
                else {
                    return nil
                }
                return ProviderParsing.string(bucket["bucketId"])
            })
        return sharedPoolKinds.keys.allSatisfy(usable.contains) && argonWindow(groups) != nil
    }

    static func containsSummary(_ data: Data) -> Bool {
        groups(data) != nil
    }

    static func plan(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        let paidTier = ProviderParsing.object(root["paidTier"])
        if let identifier = ProviderParsing.string(paidTier?["id"]),
           let plan = paidTierPlans[identifier] {
            return plan
        }
        if let name = trimmed(paidTier?["name"]) {
            return formattedPlan(name)
        }
        let currentTier = ProviderParsing.object(root["currentTier"])
        if ProviderParsing.string(currentTier?["id"]) == "free-tier" {
            return "Free"
        }
        // The free tier is simply named "Antigravity", which would only
        // repeat the provider name in the panel.
        guard let name = trimmed(currentTier?["name"]),
              name.caseInsensitiveCompare("Antigravity") != .orderedSame
        else {
            return nil
        }
        return formattedPlan(name)
    }

    static func project(_ data: Data?) -> String? {
        guard let data,
              let root = try? ProviderParsing.object(from: data)
        else {
            return nil
        }
        return trimmed(root["cloudaicompanionProject"])
    }

    private static func groups(_ data: Data) -> [[String: Any]]? {
        guard let root = try? ProviderParsing.object(from: data) else {
            return nil
        }
        let container = ProviderParsing.object(root["response"]) ?? root
        return container["groups"] as? [[String: Any]]
    }

    /// The Argon weekly quota, only when exactly one enabled weekly bucket
    /// identifies it: the `Gemini 4 Argon` group's weekly bucket, or a bucket
    /// with a known Argon id.
    private static func argonWindow(_ groups: [[String: Any]]) -> QuotaWindow? {
        var candidates: [String: [String: Any]] = [:]
        for group in groups {
            let isArgonGroup =
                ProviderParsing.string(group["displayName"]) == argonGroupName
            for bucket in ProviderParsing.array(group["buckets"]) {
                guard let identifier = ProviderParsing.string(bucket["bucketId"]),
                      sharedPoolKinds[identifier] == nil
                else {
                    continue
                }
                let isWeekly = ProviderParsing.string(bucket["window"]) == "weekly"
                if argonBucketIDs.contains(identifier) ||
                    (isArgonGroup && isWeekly) {
                    candidates[identifier] = bucket
                }
            }
        }
        guard candidates.count == 1,
              let bucket = candidates.values.first
        else {
            return nil
        }
        if let disabled = bucket["disabled"], !(disabled is NSNull) {
            guard let number = disabled as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID(),
                  !number.boolValue else {
                return nil
            }
        }
        return window(kind: .argonWeekly, bucket: bucket)
    }

    private static func window(
        kind: QuotaKind,
        bucket: [String: Any]
    ) -> QuotaWindow? {
        guard let remaining = ProviderParsing.double(bucket["remainingFraction"])
        else {
            return nil
        }
        let clamped = min(max(remaining, 0), 1)
        return QuotaWindow(
            kind: kind,
            usedPercent: ((1 - clamped) * 10_000).rounded() / 100,
            resetsAt: ProviderParsing.date(bucket["resetTime"])
        )
    }

    private static func formattedPlan(_ name: String) -> String {
        for tier in ["Ultra Lite", "Ultra", "Pro"]
        where name.localizedCaseInsensitiveContains(tier) {
            return "Google AI \(tier)"
        }
        return name
            .split(whereSeparator: \.isWhitespace)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func trimmed(_ value: Any?) -> String? {
        guard let value = ProviderParsing.string(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
