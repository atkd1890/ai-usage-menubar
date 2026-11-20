import Foundation

struct ProviderDiagnosticWarning: Equatable, Sendable, Identifiable {
    enum Kind: String, Equatable, Sendable {
        case schemaAdded
        case schemaRemoved
        case apiDeprecated
        case partialCompatibility

        var badgeTitle: String {
            switch self {
            case .schemaAdded: "New API fields"
            case .schemaRemoved: "Missing API fields"
            case .apiDeprecated: "API / version notice"
            case .partialCompatibility: "Partial quota support"
            }
        }
    }

    let id: String
    let kind: Kind
    let summary: String
    let detail: String
    let patch: SchemaChangePatch?

    init(
        id: String,
        kind: Kind,
        summary: String,
        detail: String,
        patch: SchemaChangePatch? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.detail = detail
        self.patch = patch
    }
}

enum ResponseSchemaWatch {
    private static let noiseKeys: Set<String> = [
        "request_id", "requestId", "trace_id", "traceId",
        "server_time", "serverTime", "__typename",
        "base_resp", "statusInfo", "success", "code", "message", "msg"
    ]

    private static let vendorDeprecationHeaders: Set<String> = [
        "x-api-warn", "x-api-deprecation", "x-deprecated",
        "x-deprecation-warning", "x-min-client-version", "x-api-sunset"
    ]

    private static let bodyDeprecationKeys: [String] = [
        "deprecation_warning", "deprecationWarning",
        "api_deprecated", "upgrade_required", "sunset"
    ]

    private static let sensitiveKeyFragments: [String] = [
        "api_key", "apikey", "access_key", "secret", "private_key", "signing_key",
        "token", "password", "passwd", "cookie", "authorization", "credential",
        "email", "jwt", "bearer"
    ]

    static func httpHeaders(
        _ response: HTTPResponse,
        provider: ProviderID? = nil,
        endpoint: String,
        store: ConfirmedSchemaStore = .shared
    ) -> [ProviderDiagnosticWarning] {
        var warnings: [ProviderDiagnosticWarning] = []
        let sortedHeaders = response.headers.sorted { $0.key.lowercased() < $1.key.lowercased() }

        for (rawName, rawValue) in sortedHeaders {
            let name = rawName.lowercased()
            let clean = sanitize(rawValue)
            guard !clean.isEmpty else { continue }

            let id = "api.header.\(endpoint).\(name)"
            if name == "deprecation" {
                let lowered = clean.lowercased()
                guard lowered != "false", lowered != "0" else { continue }
                let detail = "\(rawName): \(clean)"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "Deprecated API header on \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            } else if name == "sunset" {
                let detail = "Sunset: \(clean)"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "API sunset notice on \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            } else if name == "warning" {
                let lowered = clean.lowercased()
                let isRelevant = lowered.contains("299")
                    || lowered.contains("deprecat")
                    || lowered.contains("sunset")
                    || lowered.contains("obsolete")
                    || lowered.contains("upgrade")
                    || lowered.contains("legacy")
                guard isRelevant else { continue }
                let detail = "Warning: \(clean)"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "API warning header on \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            } else if vendorDeprecationHeaders.contains(name) {
                let lowered = clean.lowercased()
                guard lowered != "false", lowered != "0" else { continue }
                let detail = "\(rawName): \(clean)"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "API notice on \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            }
        }
        return filterConfirmed(deduplicated(warnings), provider: provider, store: store)
    }

    static func jsonBodyDeprecation(
        _ object: [String: Any],
        provider: ProviderID? = nil,
        endpoint: String,
        store: ConfirmedSchemaStore = .shared
    ) -> [ProviderDiagnosticWarning] {
        var warnings: [ProviderDiagnosticWarning] = []
        for key in bodyDeprecationKeys {
            guard let raw = object[key], !(raw is NSNull) else { continue }
            let id = "api.body.\(endpoint).\(key)"
            if let flag = raw as? Bool {
                guard flag else { continue }
                let detail = "\(key): true"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "API deprecation flag in \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            } else if let text = raw as? String {
                let clean = sanitize(text)
                let lowered = clean.lowercased()
                guard !clean.isEmpty, lowered != "false", lowered != "0" else { continue }
                let detail = "\(key): \(clean)"
                warnings.append(ProviderDiagnosticWarning(
                    id: id,
                    kind: .apiDeprecated,
                    summary: "API notice in \(endpoint)",
                    detail: detail,
                    patch: .acknowledgeNotice(endpoint: endpoint, signature: "\(id)|\(detail)")
                ))
            }
        }
        return filterConfirmed(deduplicated(warnings), provider: provider, store: store)
    }

    static func confirmedJSONKeys(
        in object: [String: Any],
        provider: ProviderID,
        endpoint: String,
        requirePresent: Bool = true,
        store: ConfirmedSchemaStore = .shared
    ) -> [ProviderDiagnosticWarning] {
        let schema = store.effectiveSchema(for: provider, endpoint: endpoint)
        return jsonKeys(
            in: object,
            endpoint: endpoint,
            known: Set(schema.jsonKeys),
            knownPrefixes: schema.jsonKeyPrefixes,
            required: requirePresent ? Set(schema.requiredJSONKeys) : []
        )
    }

    static func jsonKeys(
        in object: [String: Any],
        endpoint: String,
        known: Set<String>,
        knownPrefixes: [String] = [],
        required: Set<String> = []
    ) -> [ProviderDiagnosticWarning] {
        var warnings: [ProviderDiagnosticWarning] = []
        let actualKeys = Set(object.keys)

        let added = actualKeys.filter { key in
            guard !known.contains(key), !noiseKeys.contains(key) else { return false }
            return !knownPrefixes.contains(where: { key.hasPrefix($0) })
        }.sorted()

        if !added.isEmpty {
            let previewLines = added.map { "\($0): \(formatJSONValue(object[$0], key: $0))" }.joined(separator: "\n")
            warnings.append(ProviderDiagnosticWarning(
                id: "schema.added.\(endpoint)",
                kind: .schemaAdded,
                summary: added.count == 1 ? "New field in \(endpoint)" : "New fields in \(endpoint)",
                detail: previewLines,
                patch: .addJSONKeys(endpoint: endpoint, keys: added)
            ))
        }

        let removed = required.subtracting(actualKeys).sorted()
        if !removed.isEmpty {
            let list = removed.joined(separator: ", ")
            warnings.append(ProviderDiagnosticWarning(
                id: "schema.removed.\(endpoint)",
                kind: .schemaRemoved,
                summary: removed.count == 1 ? "Missing field in \(endpoint)" : "Missing fields in \(endpoint)",
                detail: list,
                patch: .relaxRequiredJSONKeys(endpoint: endpoint, keys: removed)
            ))
        }

        return warnings
    }

    static func confirmedProtobufFields(
        _ fields: [GeminiProtobuf.Field],
        provider: ProviderID,
        endpoint: String,
        store: ConfirmedSchemaStore = .shared
    ) -> [ProviderDiagnosticWarning] {
        let schema = store.effectiveSchema(for: provider, endpoint: endpoint)
        return protobufFields(
            fields,
            endpoint: endpoint,
            known: Set(schema.protobufTags),
            required: Set(schema.requiredProtobufTags)
        )
    }

    static func protobufFields(
        _ fields: [GeminiProtobuf.Field],
        endpoint: String,
        known: Set<Int>,
        required: Set<Int> = []
    ) -> [ProviderDiagnosticWarning] {
        var warnings: [ProviderDiagnosticWarning] = []
        let present = Set(fields.map(\.number))

        let added = present.subtracting(known).sorted()
        if !added.isEmpty {
            let previewLines = added.map { "#\($0): \(formatProtobufValue(for: $0, in: fields))" }.joined(separator: "\n")
            warnings.append(ProviderDiagnosticWarning(
                id: "schema.added.pb.\(endpoint)",
                kind: .schemaAdded,
                summary: added.count == 1 ? "New protobuf field in \(endpoint)" : "New protobuf fields in \(endpoint)",
                detail: previewLines,
                patch: .addProtobufTags(endpoint: endpoint, tags: added)
            ))
        }

        let removed = required.subtracting(present).sorted()
        if !removed.isEmpty {
            let list = removed.map { "#\($0)" }.joined(separator: ", ")
            warnings.append(ProviderDiagnosticWarning(
                id: "schema.removed.pb.\(endpoint)",
                kind: .schemaRemoved,
                summary: removed.count == 1 ? "Missing protobuf field in \(endpoint)" : "Missing protobuf fields in \(endpoint)",
                detail: list,
                patch: .relaxRequiredProtobufTags(endpoint: endpoint, tags: removed)
            ))
        }

        return warnings
    }

    static func confirmedEnum(
        _ value: String,
        provider: ProviderID,
        endpoint: String,
        field: String,
        store: ConfirmedSchemaStore = .shared
    ) -> ProviderDiagnosticWarning? {
        let known = Set(store.effectiveSchema(for: provider, endpoint: endpoint).enums[field] ?? [])
        return unknownEnum(value, endpoint: endpoint, field: field, known: known)
    }

    static func unknownEnum(
        _ value: String,
        endpoint: String,
        field: String,
        known: Set<String>
    ) -> ProviderDiagnosticWarning? {
        let clean = sanitize(value)
        guard !clean.isEmpty, !known.contains(clean) else { return nil }
        return ProviderDiagnosticWarning(
            id: "schema.enum.\(endpoint).\(field).\(clean)",
            kind: .schemaAdded,
            summary: "Unknown \(field) in \(endpoint)",
            detail: "\(field): \(clean)",
            patch: .addEnumValue(endpoint: endpoint, field: field, value: clean)
        )
    }

    static func confirmedNotice(
        id: String,
        provider: ProviderID,
        endpoint: String,
        kind: ProviderDiagnosticWarning.Kind = .apiDeprecated,
        summary: String,
        detail: String,
        signature: String? = nil,
        store: ConfirmedSchemaStore = .shared
    ) -> ProviderDiagnosticWarning? {
        let cleanSummary = sanitize(summary)
        let noticeSignature = signature ?? "\(id)|\(cleanSummary)"
        let warning = ProviderDiagnosticWarning(
            id: id,
            kind: kind,
            summary: cleanSummary,
            detail: sanitize(detail, maxLength: 240),
            patch: .acknowledgeNotice(endpoint: endpoint, signature: noticeSignature)
        )
        return store.isConfirmed(warning, for: provider) ? nil : warning
    }

    static func apiNotice(id: String, summary: String, detail: String) -> ProviderDiagnosticWarning {
        let cleanSummary = sanitize(summary)
        return ProviderDiagnosticWarning(
            id: id,
            kind: .apiDeprecated,
            summary: cleanSummary,
            detail: sanitize(detail, maxLength: 240),
            patch: .acknowledgeNotice(endpoint: "api", signature: "\(id)|\(cleanSummary)")
        )
    }

    private static func filterConfirmed(
        _ warnings: [ProviderDiagnosticWarning],
        provider: ProviderID?,
        store: ConfirmedSchemaStore
    ) -> [ProviderDiagnosticWarning] {
        guard let provider else { return warnings }
        return warnings.filter { !store.isConfirmed($0, for: provider) }
    }

    static func deduplicated(_ warnings: [ProviderDiagnosticWarning]) -> [ProviderDiagnosticWarning] {
        var seen: Set<String> = []
        return warnings.filter { seen.insert($0.id).inserted }
    }

    static func formatJSONValue(_ raw: Any?, key: String, depth: Int = 0) -> String {
        if looksLikeSensitiveKey(key) {
            return "<redacted>"
        }
        guard let raw, !(raw is NSNull) else {
            return "null"
        }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            let d = number.doubleValue
            guard d.isFinite else { return "null" }
            if d.rounded() == d, d >= -9_000_000_000_000_000.0, d <= 9_000_000_000_000_000.0 {
                return "\(Int64(d))"
            }
            return String(format: "%g", d)
        }
        if let text = raw as? String {
            return formatStringValue(text)
        }
        if let array = raw as? [Any] {
            guard !array.isEmpty else { return "[]" }
            if depth == 0, array.count <= 3, array.allSatisfy(isJSONPrimitive) {
                let rendered = "[\(array.map { formatJSONValue($0, key: "", depth: 1) }.joined(separator: ", "))]"
                if rendered.count <= 60 {
                    return rendered
                }
            }
            return array.count == 1 ? "[1 item]" : "[\(array.count) items]"
        }
        if let dict = raw as? [String: Any] {
            let keys = dict.keys.sorted()
            guard !keys.isEmpty else { return "{}" }
            if depth == 0, keys.count <= 3, keys.allSatisfy({ isJSONPrimitive(dict[$0]) }) {
                let pairs = keys.map { "\($0): \(formatJSONValue(dict[$0], key: $0, depth: 1))" }
                let rendered = "{\(pairs.joined(separator: ", "))}"
                if rendered.count <= 70 {
                    return rendered
                }
            }
            let head = keys.prefix(3).joined(separator: ", ")
            return "{\(head)\(keys.count > 3 ? ", …" : "")}"
        }
        return "<value>"
    }

    static func formatProtobufValue(for tag: Int, in fields: [GeminiProtobuf.Field]) -> String {
        let matches = fields.filter { $0.number == tag }
        guard !matches.isEmpty else { return "present" }
        let rendered = matches.prefix(2).map(formatProtobufField).joined(separator: ", ")
        return matches.count > 2 ? "\(rendered) (+\(matches.count - 2) more)" : rendered
    }

    private static func formatProtobufField(_ field: GeminiProtobuf.Field) -> String {
        if let integer = field.integer {
            return "\(integer)"
        }
        if let floating = field.floating {
            return floating.isFinite ? String(format: "%g", floating) : "null"
        }
        if let bytes = field.bytes {
            if !bytes.isEmpty,
               bytes.count <= 60,
               let text = String(data: bytes, encoding: .utf8),
               text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\t" }) {
                return formatStringValue(text)
            }
            if let sub = try? GeminiProtobuf.fields(bytes), !sub.isEmpty {
                let tags = Array(Set(sub.map(\.number))).sorted().prefix(4).map { "#\($0)" }.joined(separator: ", ")
                return "msg (\(bytes.count) B, tags: \(tags))"
            }
            return "bytes (\(bytes.count) B)"
        }
        return "present"
    }

    private static func formatStringValue(_ raw: String) -> String {
        var clean = sanitize(raw, maxLength: Int.max)
        guard !clean.isEmpty else { return "\"\"" }
        let lowered = clean.lowercased()
        let hasWhitespace = clean.contains(where: \.isWhitespace)
        if !hasWhitespace,
           let at = clean.firstIndex(of: "@"),
           clean[clean.index(after: at)...].contains(".") {
            return "<redacted>"
        }
        if !hasWhitespace,
           clean.hasPrefix("eyJ"),
           clean.split(separator: ".").count >= 3 {
            return "<redacted>"
        }
        if lowered.hasPrefix("bearer ")
            || clean.hasPrefix("sk-")
            || clean.hasPrefix("gho_")
            || clean.hasPrefix("ghp_")
            || clean.hasPrefix("ya29.")
            || clean.hasPrefix("GOCSPX-") {
            return "<redacted>"
        }
        if !hasWhitespace,
           clean.count >= 40,
           !lowered.hasPrefix("http://"),
           !lowered.hasPrefix("https://"),
           !looksLikeISODate(clean) {
            return "<redacted>"
        }
        if (lowered.hasPrefix("http://") || lowered.hasPrefix("https://")),
           let q = clean.firstIndex(of: "?") {
            clean = String(clean[..<q]) + "?…"
        }
        let truncated = clean.count > 60 ? String(clean.prefix(60)) + "…" : clean
        return "\"\(truncated)\""
    }

    private static func isJSONPrimitive(_ raw: Any?) -> Bool {
        raw == nil || raw is NSNull || raw is NSNumber || raw is String
    }

    private static func looksLikeSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeyFragments.contains { lowered.contains($0) }
    }

    private static func looksLikeISODate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}T"#, options: .regularExpression) != nil
    }

    private static func sanitize(_ value: String, maxLength: Int = 120) -> String {
        let stripped = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(stripped.prefix(maxLength))
    }
}
