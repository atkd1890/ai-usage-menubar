import Foundation

/// Keeps only script src attributes. Inline bootstrap/chat payloads are discarded.
struct MuseScriptSources {
    static let maxScriptCount = 256
    private var buffer = ""
    private var insideScript = false
    private(set) var paths: [String] = []
    mutating func consume(_ data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while true {
            let marker = insideScript ? "</script" : "<script"
            guard let start = buffer.range(of: marker, options: .caseInsensitive) else {
                buffer = String(buffer.suffix(8)); return
            }
            buffer = String(buffer[start.lowerBound...])
            guard let end = buffer.firstIndex(of: ">") else {
                if buffer.utf8.count > 8192 { buffer = "" }
                return
            }
            let tag = String(buffer[...end])
            buffer = String(buffer[buffer.index(after: end)...])
            if !insideScript, let src = MuseProvider.capture(#"(?i)\ssrc\s*=\s*["']([^"']+)["']"#, tag),
               let url = URL(string: src, relativeTo: URL(string: MuseProvider.origin)), url.host == "muse.ai",
               Self.allowedPath(url.path), !paths.contains(url.path) { paths.append(url.path) }
            insideScript.toggle()
        }
    }
    static func allowed(_ path: String) -> Bool { allowedPath(path) }
    private static func allowedPath(_ path: String) -> Bool {
        path.range(of: #"^/_next/static/(?:immutable/)?chunks/[A-Za-z0-9_~.-]+\.js$"#, options: .regularExpression) != nil
    }
    static func chunkPaths(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"static/(?:immutable/)?chunks/[A-Za-z0-9_~.-]+\.js"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            let path = "/_next/" + text[range]
            return allowed(path) && seen.insert(path).inserted ? path : nil
        }
    }
}
private final class MuseNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum MusePageScripts {
    static func load(cookie: String) async throws -> [String] {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil
        config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config, delegate: MuseNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: MuseProvider.origin + "/")!)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue(MuseProvider.userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw MuseProvider.changed }
        var collector = MuseScriptSources(), chunk = Data(), count = 0
        for try await byte in bytes {
            count += 1
            guard count <= 8_000_000 else { throw MuseProvider.changed }
            chunk.append(byte)
            if chunk.count >= 4096 {
                collector.consume(chunk); chunk.removeAll(keepingCapacity: true)
                if collector.paths.count >= MuseScriptSources.maxScriptCount { break }
            }
        }
        collector.consume(chunk)
        return collector.paths
    }
}
