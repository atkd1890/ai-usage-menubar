import XCTest
import SwiftUI
@testable import AIUsage

@MainActor
final class MenuBarControllerTests: XCTestCase {
    func testNativeDisclosureKeepsSummaryAnchoredThroughoutAnimation() async throws {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 392, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 392, height: 600))
        let section = NativeProviderSection(frame: .zero)
        section.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(section)
        NSLayoutConstraint.activate([
            section.topAnchor.constraint(equalTo: root.topAnchor, constant: 80),
            section.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            section.widthAnchor.constraint(equalToConstant: 372)
        ])
        section.makeContent = { part, _, _ in
            AnyView(Color.clear.frame(height: part == .summary ? 70 : 160))
        }
        section.reload()
        window.contentView = root
        window.orderFront(nil)
        defer { window.close() }
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        root.layoutSubtreeIfNeeded()
        let top = section.frame.maxY
        XCTAssertEqual(section.frame.height, 70, accuracy: 1)
        section.setExpanded(true, animated: true)
        var previous: CGFloat = 0
        var sampledHeights: Set<Int> = []
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(16))
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(section.frame.maxY, top, accuracy: 0.5)
            let height = section.details.frame.height
            XCTAssertGreaterThanOrEqual(height + 0.5, previous)
            XCTAssertLessThanOrEqual(height, 160.5)
            previous = height
            sampledHeights.insert(Int(height.rounded()))
        }
        XCTAssertGreaterThan(sampledHeights.count, 3, "Disclosure must interpolate, not jump directly to its final height")
        XCTAssertEqual(section.frame.height, 230, accuracy: 1)
        section.setExpanded(false, animated: true)
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(16))
            root.layoutSubtreeIfNeeded()
            XCTAssertEqual(section.frame.maxY, top, accuracy: 0.5)
            let height = section.details.frame.height
            XCTAssertLessThanOrEqual(height, previous + 0.5)
            previous = height
        }
        XCTAssertEqual(section.frame.height, 70, accuracy: 1)
    }

    func testNativePanelFollowsDisclosureAndScrollsOnlyAtScreenLimit() async throws {
        let suite = "NativeDisclosurePanel." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presentation = UsagePanelPresentation()
        presentation.isVisible = true
        let store = UsageStore(providers: [], availabilityChecker: FixedProviderAvailabilityChecker(installed: []), trackedProviderIDs: [])
        let content = DashboardPanelView(rootView: DashboardRootView(store: store,
            launchAtLogin: LaunchAtLoginController(service: MenuBarControllerLoginService()),
            preferences: AppPreferences(defaults: defaults), updateController: UpdateController(startingUpdater: false),
            presentation: presentation, openSettings: {}))
        let visible = NSScreen.main!.visibleFrame
        let panel = NSWindow(contentRect: NSRect(x: -10000, y: visible.maxY - 103, width: 392, height: 103),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.orderFront(nil)
        defer { panel.close() }
        content.onContentSizeChange = { [weak panel, weak content] in
            guard let panel, let content else { return }
            let size = content.fittedSize(maximumHeight: visible.height)
            let frame = NSRect(x: -10000, y: visible.maxY - size.height, width: size.width, height: size.height)
            if panel.frame != frame { panel.setFrame(frame, display: false) }
            content.layoutSubtreeIfNeeded()
        }
        let section = NativeProviderSection(frame: .zero)
        section.makeContent = { part, _, _ in AnyView(Color.clear.frame(height: part == .summary ? 70 : 2000)) }
        content.providerStack.addArrangedSubview(section)
        section.widthAnchor.constraint(equalToConstant: 372).isActive = true
        section.onHeightChange = { [weak content] in
            DispatchQueue.main.async { content?.onContentSizeChange?() }
        }
        section.reload()
        content.onContentSizeChange?()
        try await Task.sleep(for: .milliseconds(100))
        let collapsed = panel.frame.height
        let top = panel.frame.maxY
        let summaryTop = section.convert(.zero, to: nil).y + panel.frame.minY
        XCTAssertEqual(content.scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)
        section.setExpanded(true, animated: true)
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(16))
            XCTAssertEqual(panel.frame.maxY, top, accuracy: 0.5)
            XCTAssertEqual(section.convert(.zero, to: nil).y + panel.frame.minY, summaryTop, accuracy: 1)
        }
        XCTAssertGreaterThan(panel.frame.height, collapsed, "section=\(section.frame) fit=\(section.fittingSize) body=\(section.details.frame) constraint=\(section.detailHeight.constant) stack=\(content.providerStack.frame) stackfit=\(content.providerStack.fittingSize) arranged=\(content.providerStack.arrangedSubviews.count) detached=\(content.providerStack.detachedViews.count)")
        XCTAssertLessThanOrEqual(panel.frame.height, (panel.screen ?? NSScreen.main)!.visibleFrame.height)
        XCTAssertGreaterThan(content.scrollView.documentView!.frame.height, content.scrollView.contentSize.height)
        section.setExpanded(false, animated: true)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(panel.frame.height, collapsed, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 0.5)
        XCTAssertEqual(content.scrollView.contentView.bounds.origin.y, 0, accuracy: 0.5)
        XCTAssertLessThanOrEqual(content.scrollView.documentView!.frame.height, content.scrollView.contentSize.height + 1)
    }

    func testCloseSuppressesOnlyTheMatchingToggleEvent() {
        var gate = PanelToggleGate()

        gate.panelDidClose()

        XCTAssertTrue(gate.consumeSuppression())
        XCTAssertFalse(gate.consumeSuppression())
    }

    func testOutsideCloseSuppressionCanExpireBeforeAnotherToggle() {
        var gate = PanelToggleGate()

        gate.panelDidClose()
        gate.clearSuppression()

        XCTAssertFalse(gate.consumeSuppression())
    }

    func testSettingsWindowUsesItsOwnWiderLayout() {
        XCTAssertEqual(AppSurfaceLayout.dashboardWidth, 392)
        XCTAssertEqual(AppSurfaceLayout.settingsWidth, 750)
        XCTAssertGreaterThan(
            AppSurfaceLayout.settingsWidth,
            AppSurfaceLayout.dashboardWidth
        )
        XCTAssertLessThan(AppSurfaceLayout.settingsWidth, 800)
    }

    func testOpeningPanelActivatesApplicationBeforePresentation() {
        let suiteName = "MenuBarControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let application = RecordingApplicationActivator()
        let controller = MenuBarController(
            store: UsageStore(
                providers: [],
                availabilityChecker: FixedProviderAvailabilityChecker(
                    installed: []
                )
            ),
            preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(
                service: MenuBarControllerLoginService()
            ),
            updateController: UpdateController(startingUpdater: false),
            application: application
        )

        controller.start()
        controller.showSettings()

        XCTAssertEqual(application.activationCount, 1)
        XCTAssertEqual(application.dockVisibility.last, true)
        let window = controller.settingsWindow
        XCTAssertNotNil(window)
        XCTAssertTrue(window?.styleMask.contains(.titled) == true)
        XCTAssertTrue(window?.styleMask.contains(.closable) == true)
        XCTAssertTrue(window?.isVisible == true)
        XCTAssertFalse(window is NSPanel)
        XCTAssertFalse(window?.styleMask.contains(.resizable) == true)
        XCTAssertEqual(window?.contentMinSize, window?.contentMaxSize)
        XCTAssertEqual(window?.contentMinSize.width, AppSurfaceLayout.settingsWidth)
        XCTAssertTrue(window?.standardWindowButton(.zoomButton)?.isHidden == true)
        window?.close()
        XCTAssertEqual(application.dockVisibility.last, false)
        controller.showSettings()
        XCTAssertEqual(application.dockVisibility.last, true)
        XCTAssertTrue(controller.settingsWindow === window)
        XCTAssertTrue(window?.isVisible == true)

        controller.stop()
        XCTAssertNil(controller.settingsWindow)
        defaults.removePersistentDomain(forName: suiteName)
    }
    func testArrowlessPanelReusesContentWithoutOpenCloseAnimation() {
        let suite = "PanelReuseTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MenuBarController(
            store: UsageStore(providers: [], availabilityChecker: FixedProviderAvailabilityChecker(installed: [])),
            preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(service: MenuBarControllerLoginService()),
            updateController: UpdateController(startingUpdater: false), application: RecordingApplicationActivator())
        controller.start()
        controller.togglePanel(nil)
        let panel = controller.usagePanel
        let content = panel?.contentView
        XCTAssertNotNil(panel)
        XCTAssertFalse(panel?.styleMask.contains(.titled) == true)
        XCTAssertEqual(panel?.animationBehavior, NSWindow.AnimationBehavior.none)
        XCTAssertTrue(panel?.isVisible == true)
        XCTAssertGreaterThan(panel?.frame.height ?? 0, 0, "views: \(panel?.contentView?.subviews.map { "\(type(of: $0)) frame=\($0.frame) intrinsic=\($0.intrinsicContentSize) fit=\($0.fittingSize)" } ?? [])")
        let nativeContent = panel?.contentView as? DashboardPanelView
        XCTAssertNotNil(nativeContent)
        if let nativeContent {
            XCTAssertTrue(nativeContent.scrollView.documentView?.isFlipped == true)
            XCTAssertTrue(nativeContent.providerStack.orientation == .vertical)
            let natural = nativeContent.fittedSize(maximumHeight: 10000)
            let bounded = nativeContent.fittedSize(maximumHeight: 60)
            XCTAssertEqual(bounded.height, min(60, natural.height))
            XCTAssertEqual(nativeContent.fittedSize(maximumHeight: 10000), natural)
        }
        let firstHeight = panel?.frame.height
        controller.hidePanel()
        XCTAssertFalse(panel?.isVisible == true)
        controller.togglePanel(nil)
        XCTAssertEqual(controller.usagePanel?.frame.height, firstHeight)
        XCTAssertTrue(controller.usagePanel === panel)
        XCTAssertTrue(controller.usagePanel?.contentView === content)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53)!
        XCTAssertNil(controller.handlePanelEvent(escape))
        XCTAssertFalse(panel?.isVisible == true)
        controller.togglePanel(nil)
        // Window number 0 can resolve to the key panel; use a genuinely different window.
        let outsideWindow = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 100, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        outsideWindow.isReleasedWhenClosed = false
        defer { outsideWindow.close() }
        let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 0,
            windowNumber: outsideWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        XCTAssertNotNil(controller.handlePanelEvent(outside))
        XCTAssertFalse(panel?.isVisible == true)
        controller.togglePanel(nil)
        controller.showSettings()
        XCTAssertFalse(panel?.isVisible == true)
        XCTAssertTrue(controller.settingsWindow?.isVisible == true)
        controller.stop()
        XCTAssertNil(controller.usagePanel)
    }

    func testHiddenPanelScheduleDoesNotKeepTicking() {
        let date = Date(timeIntervalSince1970: 1800000000)
        let hidden = Array(UsageMinuteSchedule(isActive: false).entries(from: date, mode: .normal).prefix(3))
        XCTAssertEqual(hidden, [date])
        let active = Array(UsageMinuteSchedule(isActive: true).entries(from: date, mode: .normal).prefix(3))
        XCTAssertEqual(active.count, 3)
        XCTAssertEqual(active[1].timeIntervalSince(active[0]), 60, accuracy: 0.01)
    }

    func testRepeatedAppearanceNotificationsDoNotReplaceUnchangedStatusImage() async throws {
        let suite = "StatusAppearanceRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = ProviderSnapshot(provider: .claude, planName: "Max", windows: [
            QuotaWindow(kind: .weekly, usedPercent: 70, resetsAt: nil)], fetchedAt: Date())
        let provider = CountingProvider(id: .claude, result: .success(snapshot))
        let store = UsageStore(providers: [provider], availabilityChecker: FixedProviderAvailabilityChecker(installed: [.claude]))
        await store.refresh()
        let preferences = AppPreferences(defaults: defaults)
        preferences.setMenuBarVisibility(true, for: .claude, availableItems: snapshot.availableMenuBarItems)
        let controller = MenuBarController(store: store, preferences: preferences,
            launchAtLogin: LaunchAtLoginController(service: MenuBarControllerLoginService()),
            updateController: UpdateController(startingUpdater: false), application: RecordingApplicationActivator())
        controller.start()
        defer { controller.stop() }
        try await Task.sleep(for: .milliseconds(200))
        let first = try XCTUnwrap(controller.currentStatusImage)
        for _ in 0..<1000 { controller.refreshStatusAppearance() }
        XCTAssertTrue(controller.currentStatusImage === first)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.currentStatusImage === first,
            "Native effectiveAppearance callbacks must not trigger an image-redraw feedback loop")
    }

    func testNativeStatusItemActionOpensVisibleContentAndSurvivesTransientFocusLoss() async throws {
        let suite = "StatusItemPresentationRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = MenuBarController(
            store: UsageStore(providers: [], availabilityChecker: FixedProviderAvailabilityChecker(installed: [])),
            preferences: AppPreferences(defaults: defaults),
            launchAtLogin: LaunchAtLoginController(service: MenuBarControllerLoginService()),
            updateController: UpdateController(startingUpdater: false), application: RecordingApplicationActivator())
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.currentStatusButton)
        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))
        try await Task.sleep(for: .milliseconds(200))
        let panel = try XCTUnwrap(controller.usagePanel)
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertGreaterThan(panel.frame.width, 300)
        XCTAssertGreaterThan(panel.frame.height, 50)
        let view = try XCTUnwrap(panel.contentView)
        XCTAssertGreaterThan(view.bounds.width, 300)
        XCTAssertGreaterThan(view.bounds.height, 50)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel))
        XCTAssertTrue(panel.isVisible, "Transient focus loss during status-item tracking must not dismiss the panel")
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))
        XCTAssertFalse(panel.isVisible)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(controller.usagePanel === panel)
    }

}

@MainActor
private final class RecordingApplicationActivator:
    ApplicationActivating
{
    private(set) var activationCount = 0
    private(set) var dockVisibility: [Bool] = []
    func setDockVisible(_ visible: Bool) { dockVisibility.append(visible) }

    func activate() {
        activationCount += 1
    }
}

@MainActor
private struct MenuBarControllerLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { .notRegistered }

    func register() throws {}
    func unregister() throws {}
}
