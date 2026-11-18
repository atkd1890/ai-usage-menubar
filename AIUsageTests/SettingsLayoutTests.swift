import AppKit
import SwiftUI
import XCTest
@testable import AIUsage

@MainActor final class SettingsLayoutTests: XCTestCase {
    func testSettingsWithAlertsUsesNaturalHeight() async throws {
        let suite = "SettingsLayout." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UsageStore(providers: [], availabilityChecker: FixedProviderAvailabilityChecker(installed: []))
        let host = NSHostingController(rootView: SettingsView(store: store, preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(), updateController: UpdateController(startingUpdater: false), isInSettingsWindow: true)
            .fixedSize(horizontal: false, vertical: true))
        let size = host.sizeThatFits(in: NSSize(width: 750, height: CGFloat.greatestFiniteMagnitude))
        XCTAssertEqual(size.width, 750, accuracy: 1)
        XCTAssertGreaterThan(size.height, 400)
        XCTAssertLessThan(size.height, 1300)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: size.width, height: size.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = host
        window.setContentSize(size)
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        host.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/aiusage-settings-alerts-fixture.png"))
    }
}
