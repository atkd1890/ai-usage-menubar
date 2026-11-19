import Foundation

struct KimiJWTClaims: Equatable, Sendable {
    let expiresAt: Date?
    let userID: String?
    let deviceID: String?
    let sessionID: String?
}

struct KimiPersistedSession: Codable, Equatable, Sendable {
    var seedFingerprint: String
    var accessToken: String
    var refreshToken: String?
    var updatedAt: Date
}

struct KimiSessionStore: Sendable {
    static let defaultPath = "~/Library/Application Support/AI Usage/kimi-auth.json"

    let files: any TextFileAccessing
    let path: String

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        path: String = Self.defaultPath
    ) {
        self.files = files
        self.path = path
    }

    func load(for sourceLabel: String) -> KimiPersistedSession? {
        loadAll()[sourceLabel]
    }

    func save(_ session: KimiPersistedSession, for sourceLabel: String) {
        var all = loadAll()
        all[sourceLabel] = session
        writeAll(all)
    }

    func remove(for sourceLabel: String) {
        var all = loadAll()
        guard all.removeValue(forKey: sourceLabel) != nil else { return }
        writeAll(all)
    }

    private func loadAll() -> [String: KimiPersistedSession] {
        guard files.exists(path),
              let text = try? files.readText(path),
              let data = text.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: KimiPersistedSession].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func writeAll(_ sessions: [String: KimiPersistedSession]) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? files.writeText(path, String(decoding: data, as: UTF8.self))
    }
}

struct KimiNativeSession: Sendable {
    let access: String
    let refresh: String?
    let sourceLabel: String

    init(access: String, refresh: String?, sourceLabel: String = "Kimi desktop") {
        self.access = access
        self.refresh = refresh
        self.sourceLabel = sourceLabel
    }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "\"" || $0 == "\\" })
    }

    static func stripBearer(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            return String(trimmed.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    static func jwtClaims(_ token: String) -> KimiJWTClaims? {
        let normalized = stripBearer(token)
        let parts = normalized.split(separator: ".")
        guard parts.count == 3,
              let data = ProviderParsing.base64URLData(String(parts[1])),
              let object = try? ProviderParsing.object(from: data) else {
            return nil
        }
        let expiresAt = QuotaDiscovery.number(object["exp"]).map { Date(timeIntervalSince1970: $0) }
        return KimiJWTClaims(
            expiresAt: expiresAt,
            userID: ProviderParsing.string(object["sub"]),
            deviceID: ProviderParsing.string(object["device_id"]),
            sessionID: ProviderParsing.string(object["ssid"])
        )
    }

    static func sessionHeaders(for token: String) -> [String: String] {
        guard let claims = jwtClaims(token) else { return [:] }
        var headers: [String: String] = [:]
        if let userID = claims.userID, valid(userID) {
            headers["X-Traffic-Id"] = userID
        }
        if let deviceID = claims.deviceID, valid(deviceID) {
            headers["x-msh-device-id"] = deviceID
        }
        if let sessionID = claims.sessionID, valid(sessionID) {
            headers["x-msh-session-id"] = sessionID
        }
        return headers
    }

    static func load(
        method: ProviderLoginMethod = ProviderLoginMethod.selected(for: .kimi),
        includeRefresh: Bool = UserDefaults.standard.bool(forKey: "kimiNativeRefreshAllowed.v1"),
        sessions: WebSessionStore = WebSessionStore(),
        localStorageDirectories: [ProviderLoginMethod: String]? = nil
    ) throws -> Self {
        let source: WebSessionSource?
        let label: String
        let directoryPath: String
        switch method {
        case .edge:
            source = .edge
            label = "Edge Default"
            directoryPath = localStorageDirectories?[.edge] ?? "~/Library/Application Support/Microsoft Edge/Default/Local Storage/leveldb"
        case .chrome:
            source = .chrome
            label = "Chrome Default"
            directoryPath = localStorageDirectories?[.chrome] ?? "~/Library/Application Support/Google/Chrome/Default/Local Storage/leveldb"
        default:
            source = nil
            label = "Kimi desktop"
            directoryPath = localStorageDirectories?[.desktop] ?? "~/Library/Application Support/kimi-desktop/Local Storage/leveldb"
        }

        func parseTokenValues(_ values: [String: String]) throws -> (access: String?, refresh: String?) {
            func token(_ names: [String]) throws -> String? {
                let found = Set(names.compactMap { name -> String? in
                    guard let raw = values[name] else { return nil }
                    if let data = raw.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                       let value = json as? String {
                        return stripBearer(value)
                    }
                    return stripBearer(raw)
                })
                guard found.count <= 1 else {
                    throw ProviderFailure(.authentication, "\(label) has conflicting login records. Sign in again.")
                }
                return found.first.flatMap { valid($0) ? $0 : nil }
            }
            return (
                try token(["access_token", "accessToken"]),
                includeRefresh ? try token(["refresh_token", "refreshToken"]) : nil
            )
        }

        let keys: Set<String> = includeRefresh
            ? ["access_token", "accessToken", "refresh_token", "refreshToken"]
            : ["access_token", "accessToken"]

        if let source {
            var levelDBPermissionDenied = false
            do {
                let directory = URL(fileURLWithPath: expandHome(directoryPath))
                let values = try ScopedLocalStorageReader().read(directory: directory, origin: "https://www.kimi.ai", names: keys)
                let parsed = try parseTokenValues(values)
                if let access = parsed.access {
                    return Self(access: access, refresh: parsed.refresh, sourceLabel: label)
                }
            } catch let failure as ProviderFailure {
                throw failure
            } catch {
                let nsError = error as NSError
                if (nsError.domain == NSPOSIXErrorDomain && [Int(POSIXError.Code.EPERM.rawValue), Int(POSIXError.Code.EACCES.rawValue)].contains(nsError.code)) ||
                    (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError) {
                    levelDBPermissionDenied = true
                }
            }

            do {
                let cookieHeader = try sessions.cookies(source: source, domain: "kimi.ai", names: ["kimi-auth"])
                if let prefixRange = cookieHeader.range(of: "kimi-auth=") {
                    let value = String(cookieHeader[prefixRange.upperBound...]).split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
                    if valid(value) {
                        return Self(access: value, refresh: nil, sourceLabel: label)
                    }
                }
            } catch let failure as ProviderFailure {
                if levelDBPermissionDenied || failure.kind == .storage {
                    throw ProviderFailure(.storage, "macOS denied access to \(label) data. Allow AI Usage in Privacy & Security, or use Kimi desktop.")
                }
            } catch {
                if levelDBPermissionDenied {
                    throw ProviderFailure(.storage, "macOS denied access to \(label) data. Allow AI Usage in Privacy & Security, or use Kimi desktop.")
                }
            }

            if levelDBPermissionDenied {
                throw ProviderFailure(.storage, "macOS denied access to \(label) data. Allow AI Usage in Privacy & Security, or use Kimi desktop.")
            }
            throw ProviderFailure(.authentication, "Sign in to Kimi in \(label) (www.kimi.ai), then refresh.")
        }

        do {
            let directory = URL(fileURLWithPath: expandHome(directoryPath))
            let values = try ScopedLocalStorageReader().read(directory: directory, origin: "https://www.kimi.ai", names: keys)
            let parsed = try parseTokenValues(values)
            guard let access = parsed.access else {
                throw ProviderFailure(.authentication, "Sign in to Kimi desktop, then refresh.")
            }
            return Self(access: access, refresh: parsed.refresh, sourceLabel: label)
        } catch let failure as ProviderFailure {
            throw failure
        } catch {
            throw ProviderFailure(.storage, "Kimi desktop login storage is unavailable or unsupported.")
        }
    }
}
