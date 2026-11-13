import Foundation
import Observation

struct TokenUsageEvent: Codable, Identifiable, Sendable {
    let id: String
    let provider: ProviderID
    let date: Date
    let model: String
    let input: Int
    let cached: Int
    let output: Int
    let cacheWrite: Int
    let cacheWriteHour: Int
    let fast: Bool
    var tokens: Int { input + output + (provider == .claude ? cached + cacheWrite : 0) }
    // Standard first-party USD prices verified 2026-11-13. Unknown model IDs
    // deliberately remain unpriced. Cached/reasoning subsets are not added twice.
    // https://openai.com/index/introducing-gpt-6-1-sol/
    // https://platform.claude.com/docs/en/about-claude/pricing
    var apiValue: Double? {
        let rates: (Double, Double, Double, Double, Double)
        switch model {
        case "gpt-6.1-sol": rates = (2, 0.1, 10, 0, 0)
        case "gpt-6-astra": rates = (10, 1, 50, 0, 0)
        case "gpt-6-luna": rates = (0.1, 0.01, 0.5, 0, 0)
        case "claude-opus-5-5": rates = (4, 0.2, 20, 5, 8)
        case "claude-sonnet-5-5": rates = (2, 0.1, 10, 2.5, 4)
        default: return nil
        }
        let uncached = provider == .codex ? max(0, input - cached) : input
        let value = Double(uncached) * rates.0 + Double(cached) * rates.1 + Double(output) * rates.2
            + Double(max(0, cacheWrite - cacheWriteHour)) * rates.3 + Double(cacheWriteHour) * rates.4
        return value / 1_000_000 * (fast ? 2 : 1)
    }
}

struct TokenImportResult: Sendable {
    var events: [TokenUsageEvent]
    var skipped: Int
}

protocol TokenUsageImporting: Sendable {
    func load(home: URL) async -> TokenImportResult
}

actor TokenLogImporter: TokenUsageImporting {
    private struct CachedFile: Codable { let size: Int; let modified: Date; let events: [TokenUsageEvent]; let skipped: Int }
    private var cache: [String: CachedFile] = [:]

    func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> TokenImportResult {
        let storage = home.appendingPathComponent("Library/Application Support/AI Usage/token-history.json")
        let cacheFile = storage.deletingLastPathComponent().appendingPathComponent("token-file-cache.json")
        if cache.isEmpty, let data = try? Data(contentsOf: cacheFile),
           let saved = try? JSONDecoder().decode([String: CachedFile].self, from: data) { cache = saved }
        var result: [String: TokenUsageEvent] = [:]
        if let data = try? Data(contentsOf: storage), let saved = try? JSONDecoder().decode([TokenUsageEvent].self, from: data) {
            for event in saved { result[event.id] = event }
        }
        var seenFiles = Set<String>()
        var skipped = 0
        let sources: [(ProviderID, String)] = [(.codex, ".codex/sessions"), (.codex, ".codex/archived_sessions"), (.claude, ".claude/projects")]
        for (provider, path) in sources {
            let directory = home.appendingPathComponent(path)
            guard let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.pathExtension == "jsonl" {
                guard !Task.isCancelled else { return TokenImportResult(events: [], skipped: skipped) }
                seenFiles.insert(file.path)
                guard let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { skipped += 1; continue }
                let size = attributes.fileSize ?? 0, modified = attributes.contentModificationDate ?? .distantPast
                let entry: CachedFile
                if let previous = cache[file.path], previous.size == size, previous.modified == modified { entry = previous }
                else {
                    let read = Self.read(file, provider: provider)
                    entry = CachedFile(size: size, modified: modified, events: read.events, skipped: read.skipped)
                    cache[file.path] = entry
                }
                skipped += entry.skipped
                for event in entry.events {
                    // Claude streaming entries share a message ID. Keep the
                    // fullest usage snapshot, including copies across log files.
                    if event.tokens >= (result[event.id]?.tokens ?? -1) { result[event.id] = event }
                }
            }
        }
        cache = cache.filter { seenFiles.contains($0.key) }
        let cutoff = Calendar.current.date(byAdding: .month, value: -13, to: Date())!
        let retained = result.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        do {
            try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(retained).write(to: storage, options: .atomic)
            try JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        } catch { skipped += 1 }
        return TokenImportResult(events: retained, skipped: skipped)
    }

    static func read(_ url: URL, provider: ProviderID) -> TokenImportResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return TokenImportResult(events: [], skipped: 1) }
        defer { try? handle.close() }
        var buffer = Data(), dropping = false, skipped = 0
        var model = "unknown", prior: [String: Int] = [:], events: [String: TokenUsageEvent] = [:]
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func consume(_ line: Data) {
            // Filter before JSON decoding: ignore user/tool/chat-only records.
            guard let text = String(data: line, encoding: .utf8),
                  (provider == .codex ? text.contains("\"token_count\"") || text.contains("\"turn_context\"") : text.contains("\"assistant\"") && text.contains("\"usage\"")) else { return }
            guard let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { skipped += 1; return }
            if provider == .codex, item["type"] as? String == "turn_context" {
                model = (item["payload"] as? [String: Any])?["model"] as? String ?? "unknown"; return
            }
            guard let timestamp = item["timestamp"] as? String,
                  let date = fractional.date(from: timestamp) ?? plain.date(from: timestamp) else { return }
            if provider == .codex {
                guard item["type"] as? String == "event_msg", let payload = item["payload"] as? [String: Any], payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Int] else { return }
                func delta(_ key: String) -> Int { max(0, (total[key] ?? 0) - (prior[key] ?? 0)) }
                if (total["total_tokens"] ?? 0) < (prior["total_tokens"] ?? 0) { prior = [:] }
                let event = TokenUsageEvent(id: "codex|\(timestamp)|\(model)|\(total["total_tokens"] ?? 0)", provider: provider, date: date, model: model,
                    input: delta("input_tokens"), cached: delta("cached_input_tokens"), output: delta("output_tokens"), cacheWrite: 0, cacheWriteHour: 0, fast: false)
                prior = total
                if event.tokens > 0 { events[event.id] = event }
            } else {
                guard item["type"] as? String == "assistant", let message = item["message"] as? [String: Any],
                      let id = message["id"] as? String, let usage = message["usage"] as? [String: Any],
                      let name = message["model"] as? String, name != "<synthetic>" else { return }
                let creation = usage["cache_creation"] as? [String: Int]
                let event = TokenUsageEvent(id: "claude|\(id)", provider: provider, date: date, model: name,
                    input: usage["input_tokens"] as? Int ?? 0, cached: usage["cache_read_input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0, cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheWriteHour: creation?["ephemeral_1h_input_tokens"] ?? 0, fast: usage["speed"] as? String == "fast")
                if event.tokens >= (events[event.id]?.tokens ?? -1) { events[event.id] = event }
            }
        }
        do {
            while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    if !dropping { consume(buffer.subdata(in: buffer.startIndex..<newline)) }
                    buffer.removeSubrange(buffer.startIndex...newline); dropping = false
                }
                if buffer.count > 16 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false); dropping = true; skipped += 1 }
            }
            // An unfinished last JSONL record is retried when the file changes.
        } catch { skipped += 1 }
        return TokenImportResult(events: Array(events.values), skipped: skipped)
    }
}

@MainActor @Observable final class TokenAnalytics {
    private(set) var events: [TokenUsageEvent] = []
    private(set) var lastLoadedAt: Date?
    private(set) var revision = 0
    private(set) var isLoading = false
    private(set) var skipped = 0
    private let importer: any TokenUsageImporting
    private let enabled: Bool
    init(enabled: Bool = true, events: [TokenUsageEvent] = [], importer: any TokenUsageImporting = TokenLogImporter()) {
        self.enabled = enabled; self.events = events; self.importer = importer
    }
    func refresh(force: Bool = false) async {
        guard enabled, !isLoading else { return }
        if !force, let lastLoadedAt, Date().timeIntervalSince(lastLoadedAt) < 300 { return }
        isLoading = true
        let result = await importer.load(home: FileManager.default.homeDirectoryForCurrentUser)
        guard !Task.isCancelled else { isLoading = false; return }
        events = result.events; skipped = result.skipped; lastLoadedAt = Date(); revision += 1; isLoading = false
    }
}

struct UsageCalendar {
    static func weeks(ending date: Date, calendar: Calendar = .current) -> [[Date]] {
        var calendar = calendar; calendar.firstWeekday = 2
        let end = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        return (0..<53).map { week in
            let start = calendar.date(byAdding: .weekOfYear, value: week - 52, to: end)!
            return (0..<7).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        }
    }
}
