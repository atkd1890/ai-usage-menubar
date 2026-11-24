import Foundation

enum GeminiCredentialSource: String, CaseIterable, Identifiable, Sendable {
    case nativeApp
    case edge
    case chrome
    /// Explicit combined modes: Gemini quotas from the desktop app, Flow/Flow Music credits from the named browser.
    case nativeAppEdge
    case nativeAppChrome
    static let preferenceKey = "geminiCredentialSource.v1"
    var id: Self { self }
    var title: String {
        switch self {
        case .nativeApp: "Gemini app"
        case .edge: "Edge Default"
        case .chrome: "Chrome Default"
        case .nativeAppEdge: "Gemini app + Edge Default"
        case .nativeAppChrome: "Gemini app + Chrome Default"
        }
    }
    /// Whether Gemini quotas come from the desktop app.
    var usesNativeApp: Bool { [.nativeApp, .nativeAppEdge, .nativeAppChrome].contains(self) }
    /// The browser whose Google/Flow Music cookies are read, if any.
    var browser: GeminiCredentialSource? {
        switch self {
        case .nativeApp: nil
        case .edge, .nativeAppEdge: .edge
        case .chrome, .nativeAppChrome: .chrome
        }
    }
    var accessKey: String {
        switch self {
        case .nativeApp: GeminiNativeAuthStore.accessKey
        case .edge: "geminiEdgeCookiesAllowed.v1"
        case .chrome: "geminiChromeCookiesAllowed.v1"
        case .nativeAppEdge, .nativeAppChrome: browser!.accessKey
        }
    }
    var keychainService: String {
        switch self {
        case .nativeApp: "Gemini Safe Storage"
        case .edge, .nativeAppEdge: "Microsoft Edge Safe Storage"
        case .chrome, .nativeAppChrome: "Chrome Safe Storage"
        }
    }
    var cookiePaths: [String] {
        let directory: String
        switch browser {
        case nil: return []
        case .edge: directory = "Microsoft Edge"
        default: directory = "Google/Chrome"
        }
        return ["~/Library/Application Support/\(directory)/Default/Cookies",
                "~/Library/Application Support/\(directory)/Default/Network/Cookies"]
    }
    /// New installs combine the desktop app (Gemini quotas) with Edge (Flow/Flow Music credits);
    /// existing users who enabled the desktop app before combined modes keep `.nativeApp`.
    static let defaultSource: Self = .nativeAppEdge
    static func resolved(in defaults: UserDefaults = .standard) -> Self {
        if let raw = defaults.string(forKey: preferenceKey), let stored = Self(rawValue: raw) {
            return stored
        }
        if defaults.bool(forKey: GeminiNativeAuthStore.accessKey) {
            return .nativeApp
        }
        return defaultSource
    }
    static var selected: Self { resolved() }
}
