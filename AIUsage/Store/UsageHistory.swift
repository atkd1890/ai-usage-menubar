import Foundation
import Observation

struct UsageHistoryPoint: Codable, Identifiable, Sendable {
    let provider: ProviderID
    let account: String
    let date: Date
    let metric: QuotaKind
    var usedPercent: Double
    var reset: Date?
    var id: String { "\(provider.rawValue)|\(account)|\(metric.rawValue)|\(date.timeIntervalSince1970)" }
}

struct UsageLimitHit: Codable, Identifiable, Sendable {
    let id: String
    let provider: ProviderID
    let account: String
    let date: Date
    let metric: QuotaKind
    let reset: Date?
}

@MainActor @Observable
final class UsageHistory {
    private(set) var points: [UsageHistoryPoint] = []
    private(set) var limitHits: [UsageLimitHit] = []
    private(set) var revision = 0
    @ObservationIgnored private var previous: [String: QuotaWindow] = [:]
    private(set) var storageError: String?
    private let file: URL?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(file: URL? = nil) {
        self.file = file
        if let file, FileManager.default.fileExists(atPath: file.path) {
            do { points = try JSONDecoder().decode([UsageHistoryPoint].self, from: Data(contentsOf: file)) }
            catch { storageError = "Could not read saved quota history." }
        }
        if let file {
            let hitsFile = file.deletingLastPathComponent().appendingPathComponent("quota-limit-hits.json")
            if let data = try? Data(contentsOf: hitsFile) {
                do { limitHits = try JSONDecoder().decode([UsageLimitHit].self, from: data) }
                catch { storageError = "Could not read saved limit hits." }
            } else {
                // Migrate observations from the old hourly store once.
                for point in points.sorted(by: { $0.date < $1.date }) {
                    observe(provider: point.provider, account: point.account, date: point.date,
                            window: QuotaWindow(kind: point.metric, usedPercent: point.usedPercent, resetsAt: point.reset))
                }
            }
        }
        for point in points.sorted(by: { $0.date < $1.date }) {
            previous[key(point.provider, point.account, point.metric)] = QuotaWindow(kind: point.metric, usedPercent: point.usedPercent, resetsAt: point.reset)
        }
    }
    private func key(_ provider: ProviderID, _ account: String, _ metric: QuotaKind) -> String {
        "\(provider.rawValue)|\(account)|\(metric.rawValue)"
    }
    private func observe(provider: ProviderID, account: String, date: Date, window: QuotaWindow) {
        let id = key(provider, account, window.kind)
        let old = previous[id]
        let alreadyRecorded = limitHits.contains {
            $0.provider == provider && $0.account == account && $0.metric == window.kind && $0.reset == window.resetsAt
        }
        if window.usedPercent >= 100 && (old.map { $0.usedPercent < 100 || $0.resetsAt != window.resetsAt } ?? !alreadyRecorded) {
            limitHits.append(UsageLimitHit(id: UUID().uuidString, provider: provider, account: account,
                                          date: date, metric: window.kind, reset: window.resetsAt))
        }
        previous[id] = window
    }
    static func persistent() -> UsageHistory {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AI Usage", isDirectory: true)
        return UsageHistory(file: directory.appendingPathComponent("quota-history.json"))
    }
    func record(_ snapshot: ProviderSnapshot) {
        // One sample per metric/account/hour; retain the latest observation.
        // Different login sources/accounts never become one historical series.
        guard let email = snapshot.identityEmail else { return }
        let date = Date(timeIntervalSince1970: floor(snapshot.fetchedAt.timeIntervalSince1970 / 3600) * 3600)
        let account = "\(snapshot.credentialSource ?? "selected")|\(email)"
        for window in snapshot.windows where window.usedPercent.isFinite {
            observe(provider: snapshot.provider, account: account, date: snapshot.fetchedAt, window: window)
            let point = UsageHistoryPoint(provider: snapshot.provider, account: account, date: date,
                                          metric: window.kind, usedPercent: window.usedPercent, reset: window.resetsAt)
            if let index = points.lastIndex(where: { $0.id == point.id }) { points[index] = point }
            else { points.append(point) }
        }
        let cutoff = Calendar.current.date(byAdding: .month, value: -13, to: snapshot.fetchedAt)!
        points.removeAll { $0.date < cutoff }
        limitHits.removeAll { $0.date < cutoff }
        revision += 1
        guard let file else { return }
        saveTask?.cancel()
        let values = points
        let hits = limitHits
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try await Task.detached(priority: .utility) {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try JSONEncoder().encode(values).write(to: file, options: .atomic)
                    try JSONEncoder().encode(hits).write(to: file.deletingLastPathComponent().appendingPathComponent("quota-limit-hits.json"), options: .atomic)
                }.value
                storageError = nil
            } catch is CancellationError {} catch { storageError = "Could not save quota history." }
        }
    }
}
