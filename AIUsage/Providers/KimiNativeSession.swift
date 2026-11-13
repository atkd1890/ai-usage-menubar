import Foundation

struct KimiNativeSession: Sendable {
    let access: String
    let refresh: String?
    static func valid(_ value: String) -> Bool {
        !value.isEmpty && !value.contains(where: { $0.isWhitespace || $0 == ";" || $0 == "\"" || $0 == "\\" })
    }
    static func load(includeRefresh: Bool = UserDefaults.standard.bool(forKey: "kimiNativeRefreshAllowed.v1")) throws -> Self {
        do {
            let directory = URL(fileURLWithPath: expandHome("~/Library/Application Support/kimi-desktop/Local Storage/leveldb"))
            let values = try ScopedLocalStorageReader().read(directory: directory, origin: "https://www.kimi.ai",
                names: includeRefresh ? ["access_token", "accessToken", "refresh_token", "refreshToken"] : ["access_token", "accessToken"])
            func token(_ names: [String]) throws -> String? {
                let found = Set(names.compactMap { name -> String? in
                    guard let raw = values[name] else { return nil }
                    if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                       let value = json as? String { return value }
                    return raw
                })
                guard found.count <= 1 else { throw ProviderFailure(.authentication, "Kimi desktop has conflicting login records. Sign in again.") }
                return found.first.flatMap { valid($0) ? $0 : nil }
            }
            guard let access = try token(["access_token", "accessToken"]) else {
                throw ProviderFailure(.authentication, "Sign in to Kimi desktop (www.kimi.ai), then refresh.")
            }
            return Self(access: access, refresh: try token(["refresh_token", "refreshToken"]))
        } catch let failure as ProviderFailure { throw failure }
        catch { throw ProviderFailure(.storage, "Kimi desktop login storage is unavailable or unsupported.") }
    }
}
