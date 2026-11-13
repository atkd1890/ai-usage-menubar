import AppKit
import Foundation

/// User-selected, read-only file access. Stores an OS bookmark, never cookie data.
enum BrowserDatabaseAccess {
    private static let key = "manusEdgeCookieAccess.v1"
    static var expectedURL: URL {
        URL(fileURLWithPath: expandHome("~/Library/Application Support/Microsoft Edge/Default/Cookies"))
    }
    @MainActor static func request() -> Bool {
        let panel = NSOpenPanel()
        panel.title = "Allow Manus login access"
        panel.message = "Select Edge Default's Cookies file. AI Usage reads only the Manus session cookie."
        panel.prompt = "Allow Read Access"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expectedURL.deletingLastPathComponent()
        panel.nameFieldStringValue = expectedURL.lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url,
              url.standardizedFileURL == expectedURL.standardizedFileURL else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        UserDefaults.standard.set(data, forKey: key)
        return true
    }
    static func start(path: String) -> URL? {
        guard URL(fileURLWithPath: expandHome(path)).standardizedFileURL == expectedURL.standardizedFileURL,
              let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale), !stale,
              url.standardizedFileURL == expectedURL.standardizedFileURL,
              url.startAccessingSecurityScopedResource() else { return nil }
        return url
    }
}
