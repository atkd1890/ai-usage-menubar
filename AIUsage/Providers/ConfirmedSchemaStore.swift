import Foundation
import Observation

/// Structured schema delta attached to a diagnostic warning so manual approval
/// (`Update`) updates only the reviewed API difference instead of muting future drift.
enum SchemaChangePatch: Codable, Equatable, Hashable, Sendable {
    case addJSONKeys(endpoint: String, keys: [String])
    case relaxRequiredJSONKeys(endpoint: String, keys: [String])
    case addProtobufTags(endpoint: String, tags: [Int])
    case relaxRequiredProtobufTags(endpoint: String, tags: [Int])
    case addEnumValue(endpoint: String, field: String, value: String)
    case acknowledgeNotice(endpoint: String, signature: String)
}

/// User-accepted additions/relaxations layered over `ConfirmedSchemaCatalog`.
struct EndpointSchemaOverride: Codable, Equatable, Sendable {
    var addedJSONKeys: [String]
    var relaxedRequiredJSONKeys: [String]
    var addedProtobufTags: [Int]
    var relaxedRequiredProtobufTags: [Int]
    var addedEnums: [String: [String]]
    var acknowledgedNotices: [String]

    init(
        addedJSONKeys: [String] = [],
        relaxedRequiredJSONKeys: [String] = [],
        addedProtobufTags: [Int] = [],
        relaxedRequiredProtobufTags: [Int] = [],
        addedEnums: [String: [String]] = [:],
        acknowledgedNotices: [String] = []
    ) {
        self.addedJSONKeys = addedJSONKeys
        self.relaxedRequiredJSONKeys = relaxedRequiredJSONKeys
        self.addedProtobufTags = addedProtobufTags
        self.relaxedRequiredProtobufTags = relaxedRequiredProtobufTags
        self.addedEnums = addedEnums
        self.acknowledgedNotices = acknowledgedNotices
    }

    var isEmpty: Bool {
        addedJSONKeys.isEmpty &&
            relaxedRequiredJSONKeys.isEmpty &&
            addedProtobufTags.isEmpty &&
            relaxedRequiredProtobufTags.isEmpty &&
            addedEnums.values.allSatisfy(\.isEmpty) &&
            acknowledgedNotices.isEmpty
    }
}

/// Persisted manual `confirmed` overrides for a single provider.
struct ProviderSchemaOverride: Codable, Equatable, Sendable {
    var endpoints: [String: EndpointSchemaOverride]
    var updatedAt: Date

    init(endpoints: [String: EndpointSchemaOverride] = [:], updatedAt: Date = Date()) {
        self.endpoints = endpoints
        self.updatedAt = updatedAt
    }
}

private struct PersistedConfirmedSchemasDocument: Codable {
    var schemaVersion: Int
    var providers: [String: ProviderSchemaOverride]
}

/// Observable change token so SwiftUI views drop acknowledged warnings immediately
/// when the user clicks `Update` in the popover.
@MainActor
@Observable
final class ConfirmedSchemaObserver {
    static let shared = ConfirmedSchemaObserver()

    private(set) var revision = 0

    func notifyChanged() {
        revision += 1
    }
}

/// Thread-safe store combining bundled `ConfirmedSchemaCatalog` baselines with
/// persisted manual user confirmations (`confirmed-schemas.json`).
final class ConfirmedSchemaStore: @unchecked Sendable {
    static let defaultPath = "~/Library/Application Support/AI Usage/confirmed-schemas.json"
    static let fallbackNoticeEndpoint = "notices"

    static let shared: ConfirmedSchemaStore = {
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let url = isRunningTests ? nil : URL(fileURLWithPath: expandHome(defaultPath))
        return ConfirmedSchemaStore(fileURL: url) {
            Task { @MainActor in
                ConfirmedSchemaObserver.shared.notifyChanged()
            }
        }
    }()

    private let lock = NSLock()
    private let fileURL: URL?
    private let observer: (@Sendable () -> Void)?
    private var overrides: [String: ProviderSchemaOverride]

    init(fileURL: URL?, observer: (@Sendable () -> Void)? = nil) {
        self.fileURL = fileURL
        self.observer = observer
        self.overrides = Self.load(from: fileURL)
    }

    func effectiveSchema(for provider: ProviderID, endpoint: String) -> EndpointConfirmedSchema {
        let baseline = ConfirmedSchemaCatalog.baseline(for: provider).endpoints[endpoint] ?? EndpointConfirmedSchema()
        let override = lock.withLock {
            overrides[provider.rawValue]?.endpoints[endpoint]
        }
        guard let override else { return baseline }

        let relaxedJSON = Set(override.relaxedRequiredJSONKeys)
        let relaxedProtobuf = Set(override.relaxedRequiredProtobufTags)

        var mergedEnums = baseline.enums
        for (field, extraValues) in override.addedEnums {
            mergedEnums[field] = Self.mergeUnique(mergedEnums[field] ?? [], with: extraValues)
        }

        return EndpointConfirmedSchema(
            jsonKeys: Self.mergeUnique(baseline.jsonKeys, with: override.addedJSONKeys),
            jsonKeyPrefixes: baseline.jsonKeyPrefixes,
            requiredJSONKeys: baseline.requiredJSONKeys.filter { !relaxedJSON.contains($0) },
            protobufTags: Self.mergeUnique(baseline.protobufTags, with: override.addedProtobufTags),
            requiredProtobufTags: baseline.requiredProtobufTags.filter { !relaxedProtobuf.contains($0) },
            enums: mergedEnums,
            acknowledgedNotices: Self.mergeUnique(baseline.acknowledgedNotices, with: override.acknowledgedNotices)
        )
    }

    func isConfirmed(_ warning: ProviderDiagnosticWarning, for provider: ProviderID) -> Bool {
        guard let patch = warning.patch else {
            let schema = effectiveSchema(for: provider, endpoint: Self.fallbackNoticeEndpoint)
            return schema.acknowledgedNotices.contains(warning.id)
        }
        switch patch {
        case let .addJSONKeys(endpoint, keys):
            guard !keys.isEmpty else { return false }
            let schema = effectiveSchema(for: provider, endpoint: endpoint)
            let known = Set(schema.jsonKeys)
            return keys.allSatisfy { key in
                known.contains(key) || schema.jsonKeyPrefixes.contains { key.hasPrefix($0) }
            }
        case let .relaxRequiredJSONKeys(endpoint, keys):
            guard !keys.isEmpty else { return false }
            let required = Set(effectiveSchema(for: provider, endpoint: endpoint).requiredJSONKeys)
            return keys.allSatisfy { !required.contains($0) }
        case let .addProtobufTags(endpoint, tags):
            guard !tags.isEmpty else { return false }
            let known = Set(effectiveSchema(for: provider, endpoint: endpoint).protobufTags)
            return tags.allSatisfy(known.contains)
        case let .relaxRequiredProtobufTags(endpoint, tags):
            guard !tags.isEmpty else { return false }
            let required = Set(effectiveSchema(for: provider, endpoint: endpoint).requiredProtobufTags)
            return tags.allSatisfy { !required.contains($0) }
        case let .addEnumValue(endpoint, field, value):
            let values = effectiveSchema(for: provider, endpoint: endpoint).enums[field] ?? []
            return values.contains(value)
        case let .acknowledgeNotice(endpoint, signature):
            let notices = effectiveSchema(for: provider, endpoint: endpoint).acknowledgedNotices
            return notices.contains(signature)
        }
    }

    func activeWarnings(for snapshot: ProviderSnapshot) -> [ProviderDiagnosticWarning] {
        snapshot.allDiagnosticWarnings.filter { !isConfirmed($0, for: snapshot.provider) }
    }

    func hasActiveWarnings(for snapshot: ProviderSnapshot) -> Bool {
        !activeWarnings(for: snapshot).isEmpty
    }

    func confirm(warnings: [ProviderDiagnosticWarning], for provider: ProviderID) {
        guard !warnings.isEmpty else { return }
        lock.withLock {
            var providerOverride = overrides[provider.rawValue] ?? ProviderSchemaOverride()
            for warning in warnings {
                let patch = warning.patch ?? .acknowledgeNotice(
                    endpoint: Self.fallbackNoticeEndpoint,
                    signature: warning.id
                )
                let endpoint = Self.endpoint(for: patch)
                var endpointOverride = providerOverride.endpoints[endpoint] ?? EndpointSchemaOverride()
                Self.apply(patch, to: &endpointOverride)
                providerOverride.endpoints[endpoint] = endpointOverride
            }
            providerOverride.updatedAt = Date()
            overrides[provider.rawValue] = providerOverride
            persistLocked()
        }
        observer?()
    }

    func resetOverrides(for provider: ProviderID? = nil) {
        lock.withLock {
            if let provider {
                overrides.removeValue(forKey: provider.rawValue)
            } else {
                overrides.removeAll()
            }
            persistLocked()
        }
        observer?()
    }

    func userOverride(for provider: ProviderID) -> ProviderSchemaOverride? {
        lock.withLock {
            overrides[provider.rawValue]
        }
    }

    private static func endpoint(for patch: SchemaChangePatch) -> String {
        switch patch {
        case let .addJSONKeys(endpoint, _),
             let .relaxRequiredJSONKeys(endpoint, _),
             let .addProtobufTags(endpoint, _),
             let .relaxRequiredProtobufTags(endpoint, _),
             let .addEnumValue(endpoint, _, _),
             let .acknowledgeNotice(endpoint, _):
            endpoint
        }
    }

    private static func apply(_ patch: SchemaChangePatch, to target: inout EndpointSchemaOverride) {
        switch patch {
        case let .addJSONKeys(_, keys):
            target.addedJSONKeys = mergeUnique(target.addedJSONKeys, with: keys)
        case let .relaxRequiredJSONKeys(_, keys):
            target.relaxedRequiredJSONKeys = mergeUnique(target.relaxedRequiredJSONKeys, with: keys)
        case let .addProtobufTags(_, tags):
            target.addedProtobufTags = mergeUnique(target.addedProtobufTags, with: tags)
        case let .relaxRequiredProtobufTags(_, tags):
            target.relaxedRequiredProtobufTags = mergeUnique(target.relaxedRequiredProtobufTags, with: tags)
        case let .addEnumValue(_, field, value):
            target.addedEnums[field] = mergeUnique(target.addedEnums[field] ?? [], with: [value])
        case let .acknowledgeNotice(_, signature):
            target.acknowledgedNotices = mergeUnique(target.acknowledgedNotices, with: [signature])
        }
    }

    private static func mergeUnique<T: Hashable & Comparable>(_ existing: [T], with additions: [T]) -> [T] {
        var seen = Set(existing)
        var result = existing
        for item in additions where seen.insert(item).inserted {
            result.append(item)
        }
        return result.sorted()
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let cleaned = overrides.filter { _, value in
                value.endpoints.values.contains { !$0.isEmpty }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let document = PersistedConfirmedSchemasDocument(schemaVersion: 1, providers: cleaned)
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure should not crash the UI or polling loop.
        }
    }

    private static func load(from fileURL: URL?) -> [String: ProviderSchemaOverride] {
        guard let fileURL,
              FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return [:]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(PersistedConfirmedSchemasDocument.self, from: data) {
            return document.providers
        }
        return [:]
    }
}
