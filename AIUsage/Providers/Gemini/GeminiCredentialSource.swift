import Foundation

enum GeminiCredentialSource: String, CaseIterable, Identifiable, Sendable {
    case nativeApp
    case edge
    case chrome
    static let preferenceKey = "geminiCredentialSource.v1"
    var id: Self { self }
    var title: String {
        switch self { case .nativeApp: "Gemini app"; case .edge: "Edge Default"; case .chrome: "Chrome Default" }
    }
    var accessKey: String {
        switch self {
        case .nativeApp: GeminiNativeAuthStore.accessKey
        case .edge: "geminiEdgeCookiesAllowed.v1"
        case .chrome: "geminiChromeCookiesAllowed.v1"
        }
    }
    var keychainService: String {
        switch self { case .nativeApp: "Gemini Safe Storage"; case .edge: "Microsoft Edge Safe Storage"; case .chrome: "Chrome Safe Storage" }
    }
    var cookiePaths: [String] {
        let directory: String
        switch self { case .nativeApp: return []; case .edge: directory = "Microsoft Edge"; case .chrome: directory = "Google/Chrome" }
        return ["~/Library/Application Support/\(directory)/Default/Cookies",
                "~/Library/Application Support/\(directory)/Default/Network/Cookies"]
    }
    static var selected: Self {
        UserDefaults.standard.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .nativeApp
    }
}
