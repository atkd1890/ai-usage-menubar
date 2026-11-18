import AppKit
import Foundation

/// User-selected, read-only file access. Stores an OS bookmark, never cookie data.
enum BrowserDatabaseAccess {
    private static let edgeKey = "manusEdgeCookieAccess.v1"
    private static let chromeKey = "browserChromeCookieAccess.v1"

    static var expectedURL: URL {
        expectedURL(for: .edge)
    }

    static func expectedURL(for source: WebSessionSource) -> URL {
        switch source {
        case .chrome:
            URL(fileURLWithPath: expandHome("~/Library/Application Support/Google/Chrome/Default/Cookies"))
        default:
            URL(fileURLWithPath: expandHome("~/Library/Application Support/Microsoft Edge/Default/Cookies"))
        }
    }

    private static func bookmarkKey(for source: WebSessionSource) -> String {
        source == .chrome ? chromeKey : edgeKey
    }

    @MainActor static func request(providerName: String = "Manus", source: WebSessionSource = .edge) -> Bool {
        let targetURL = expectedURL(for: source)
        let browserName = source == .chrome ? "Chrome Default" : "Edge Default"
        let panel = NSOpenPanel()
        panel.title = "Allow \(providerName) login access"
        panel.message = "Select \(browserName)'s Cookies file. AI Usage reads only the approved \(providerName) session cookies."
        panel.prompt = "Allow Read Access"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = targetURL.deletingLastPathComponent()
        panel.nameFieldStringValue = targetURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL == targetURL.standardizedFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey(for: source))
        return true
    }

    static func start(path: String) -> URL? {
        let standardized = URL(fileURLWithPath: expandHome(path)).standardizedFileURL
        let key: String
        let targetURL: URL
        if standardized == expectedURL(for: .edge).standardizedFileURL {
            key = edgeKey
            targetURL = expectedURL(for: .edge)
        } else if standardized == expectedURL(for: .chrome).standardizedFileURL {
            key = chromeKey
            targetURL = expectedURL(for: .chrome)
        } else {
            return nil
        }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
              url.standardizedFileURL == targetURL.standardizedFileURL,
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
}
