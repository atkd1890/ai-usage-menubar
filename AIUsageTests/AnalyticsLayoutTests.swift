import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

@MainActor final class AnalyticsLayoutTests: XCTestCase {
    func testTokensAndValueDashboardLayout() async throws {
        let suite = "AnalyticsLayout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let events = (0..<30).flatMap { index -> [TokenUsageEvent] in
            let date = Calendar.current.date(byAdding: .day, value: -index, to: Date())!
            return [TokenUsageEvent(id: "a\(index)", provider: .codex, date: date, model: "gpt-6.1-sol", input: index % 3 == 0 ? 5_000_000 : 500_000, cached: 400_000, output: 20000, cacheWrite: 0, cacheWriteHour: 0, fast: false),
                    TokenUsageEvent(id: "b\(index)", provider: .claude, date: date, model: "claude-opus-5-5", input: index % 4 == 0 ? 2_000_000 : 200_000, cached: 20000, output: 10000, cacheWrite: 5000, cacheWriteHour: 0, fast: false)]
        }
        let store = UsageStore(providers: [], analytics: TokenAnalytics(enabled: false, events: events), availabilityChecker: FixedProviderAvailabilityChecker(installed: []))
        let preferences = AppPreferences(defaults: defaults)
        for unit in AnalyticsUnit.allCases {
            let projection = DashboardProjectionModel()
            let host = NSHostingController(rootView: UsageDashboardView(store: store, preferences: preferences, initialUnit: unit, projection: projection))
            host.sizingOptions = []
            host.safeAreaRegions = []
            let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 1280, height: 850), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1280, height: 850))
            window.orderFront(nil)
            defer { window.close() }
            host.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertGreaterThanOrEqual(host.view.bounds.width, 1080)
            let builds = projection.buildCount
            let resizeStart = Date()
            for step in 0..<16 {
                window.setContentSize(NSSize(width: 1080 + step * 12, height: 740 + step * 4))
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(8))
            }
            XCTAssertEqual(projection.buildCount, builds, "Live resize must reuse aggregates")
            XCTAssertEqual(store.analytics.revision, 0, "View changes must not import logs")
            let attachment = XCTAttachment(string: "16 resize passes: \(Date().timeIntervalSince(resizeStart))s; aggregate builds unchanged: \(builds)")
            attachment.lifetime = .keepAlways
            add(attachment)
            window.setContentSize(NSSize(width: 1280, height: 850))
            host.view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aiusage-dashboard-\(unit.rawValue.lowercased())-fixture.png"))
        }
    }
}
