import AppKit
import Observation
import OSLog
import SwiftUI

@MainActor
protocol ApplicationActivating: AnyObject {
    func activate()
    func setDockVisible(_ visible: Bool)
}

extension NSApplication: ApplicationActivating {
    func setDockVisible(_ visible: Bool) {
        setActivationPolicy(visible ? .regular : .accessory)
    }
}

struct PanelToggleGate {
    private(set) var suppressesNextToggle = false

    mutating func panelDidClose() {
        suppressesNextToggle = true
    }

    mutating func consumeSuppression() -> Bool {
        guard suppressesNextToggle else { return false }
        suppressesNextToggle = false
        return true
    }

    mutating func clearSuppression() {
        suppressesNextToggle = false
    }
}

@MainActor
enum MenuBarStatusImageRenderer {
    private static let iconSize: CGFloat = 15
    private static let iconTextSpacing: CGFloat = 3
    private static let labelValueSpacing: CGFloat = 1
    private static let separatorSpacing: CGFloat = 3
    private static let staleSpacing: CGFloat = 1
    private static let suffixSpacing: CGFloat = 1
    private static let microLabelRaise: CGFloat = 2
    private static let providerSpacing: CGFloat = 9

    private struct TextRun {
        let text: String
        let size: NSSize

        var width: CGFloat { ceil(size.width) }
    }

    private struct MetricRun {
        let label: TextRun?
        let value: TextRun
        let staleIndicator: TextRun?
        let severity: UsageSeverity
        let width: CGFloat
    }

    static func image(
        for groups: [MenuBarProviderReadings],
        font: NSFont
    ) -> NSImage {
        let microFont = NSFont.systemFont(
            ofSize: max(8, floor(font.pointSize * 0.62)),
            weight: .semibold
        )
        let separator = textRun("·", font: microFont)
        let entries = groups.map { group in
            let presentation = MenuBarProviderPresentation(group: group)
            let metrics = presentation.metrics.map { metric in
                let label = metric.label.map {
                    textRun($0, font: microFont)
                }
                let value = textRun(metric.valueText, font: font)
                let staleIndicator = metric.showsStaleIndicator
                    ? textRun("⚠︎", font: microFont)
                    : nil
                return MetricRun(
                    label: label,
                    value: value,
                    staleIndicator: staleIndicator,
                    severity: metric.severity,
                    width:
                        (label?.width ?? 0) +
                        (label == nil ? 0 : labelValueSpacing) +
                        value.width +
                        (staleIndicator == nil ? 0 : staleSpacing) +
                        (staleIndicator?.width ?? 0)
                )
            }
            let separatorsWidth =
                (separator.width + separatorSpacing * 2) *
                CGFloat(max(metrics.count - 1, 0))
            let suffix = presentation.sharedSuffix.map {
                textRun($0, font: microFont)
            }
            let valuesWidth =
                metrics.map(\.width).reduce(0, +) +
                separatorsWidth +
                (suffix == nil ? 0 : suffixSpacing) +
                (suffix?.width ?? 0)
            let width = iconSize + (
                metrics.isEmpty ? 0 : iconTextSpacing + ceil(valuesWidth)
            )
            return (
                provider: group.provider,
                isXSubscription: group.isXSubscription,
                metrics: metrics,
                suffix: suffix,
                width: width
            )
        }
        let microAttributes: [NSAttributedString.Key: Any] = [
            .font: microFont,
            .foregroundColor: NSColor.labelColor
        ]
        let width = entries.map(\.width).reduce(0, +) +
            providerSpacing * CGFloat(max(entries.count - 1, 0))
        let height = max(
            iconSize,
            ceil(font.ascender - font.descender + font.leading),
            ceil(
                microFont.ascender -
                    microFont.descender +
                    microFont.leading +
                    microLabelRaise
            )
        )

        let image = NSImage(
            size: NSSize(width: ceil(width), height: ceil(height)),
            flipped: false
        ) { destination in
            var x = destination.minX

            for (index, entry) in entries.enumerated() {
                let icon = tintedIcon(entry.isXSubscription ? xIcon() : icon(for: entry.provider))
                icon.draw(
                    in: NSRect(
                        x: x,
                        y: destination.midY - iconSize / 2,
                        width: iconSize,
                        height: iconSize
                    ),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
                x += iconSize

                if !entry.metrics.isEmpty {
                    x += iconTextSpacing
                }
                for (metricIndex, metric) in entry.metrics.enumerated() {
                    if metricIndex > 0 {
                        x += separatorSpacing
                        (separator.text as NSString).draw(
                            at: NSPoint(
                                x: x,
                                y: destination.midY -
                                    separator.size.height / 2
                            ),
                            withAttributes: microAttributes
                        )
                        x += separator.width + separatorSpacing
                    }

                    if let label = metric.label {
                        (label.text as NSString).draw(
                            at: NSPoint(
                                x: x,
                                y: destination.midY -
                                    label.size.height / 2 +
                                    microLabelRaise
                            ),
                            withAttributes: microAttributes
                        )
                        x += label.width + labelValueSpacing
                    }

                    (metric.value.text as NSString).draw(
                        at: NSPoint(
                            x: x,
                            y: destination.midY -
                                metric.value.size.height / 2
                        ),
                        withAttributes: [.font: font, .foregroundColor: metric.severity.nsColor]
                    )
                    x += metric.value.width

                    if metricIndex == entry.metrics.count - 1,
                       let suffix = entry.suffix {
                        x += suffixSpacing
                        (suffix.text as NSString).draw(
                            at: NSPoint(
                                x: x,
                                y: destination.midY -
                                    suffix.size.height / 2
                            ),
                            withAttributes: [.font: microFont, .foregroundColor: metric.severity.nsColor]
                        )
                        x += suffix.width
                    }

                    if let staleIndicator = metric.staleIndicator {
                        x += staleSpacing
                        (staleIndicator.text as NSString).draw(
                            at: NSPoint(
                                x: x,
                                y: destination.midY -
                                    staleIndicator.size.height / 2
                            ),
                            withAttributes: microAttributes
                        )
                        x += staleIndicator.width
                    }
                }

                if index < entries.count - 1 {
                    x += providerSpacing
                }
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private static func tintedIcon(_ source: NSImage) -> NSImage {
        NSImage(size: source.size, flipped: false) { rect in
            source.draw(in: rect)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceIn)
            return true
        }
    }

    private static func textRun(_ text: String, font: NSFont) -> TextRun {
        TextRun(
            text: text,
            size: (text as NSString).size(withAttributes: [
                .font: font
            ])
        )
    }

    private static func xIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { rect in
            ("𝕏" as NSString).draw(in: rect, withAttributes: [
                .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black
            ])
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func icon(for provider: ProviderID) -> NSImage {
        ProviderIcon.templateImage(for: provider, size: iconSize)
    }
}

enum AppSurfaceLayout {
    static let dashboardWidth: CGFloat = 392
    static let settingsWidth: CGFloat = 750
    static let settingsHeight: CGFloat = 640
}

@MainActor
final class UsagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
@Observable
final class UsagePanelPresentation {
    var isVisible = false
}

@MainActor
final class MenuBarController: NSObject, NSWindowDelegate {
    private let store: UsageStore
    private let preferences: AppPreferences
    private let launchAtLogin: LaunchAtLoginController
    private let updateController: UpdateController
    private let statusBar: NSStatusBar
    private let application: any ApplicationActivating

    private var statusItem: NSStatusItem?
    private(set) var usagePanel: UsagePanel?
    private var dashboardHost: DashboardPanelView?
    private let panelPresentation = UsagePanelPresentation()
    private var outsideClickMonitor: Any?
    private var localEventMonitor: Any?
    private var activationMonitor: NSObjectProtocol?
    private var presentationTask: Task<Void, Never>?
    private var panelAnchor: NSRect?
    private var panelScreen: NSScreen?
    private var previousForegroundPID: pid_t?
    private let panelLog = Logger(subsystem: "com.burakgon.aiusage", category: "panel")
    var currentStatusButton: NSStatusBarButton? { statusItem?.button }
    private var settingsMeasuredHeight: CGFloat = 0
    private(set) var settingsWindow: NSWindow?
    private(set) var analyticsWindow: NSWindow?
    private var isStarted = false
    private var appearanceObservation: NSKeyValueObservation?
    private var latestGroups: [MenuBarProviderReadings] = []
    private var hasRenderedStatusImage = false
    private var renderedAppearance: NSAppearance.Name?
    var currentStatusImage: NSImage? { statusItem?.button?.image }

    func refreshStatusAppearance() { updateStatusItem(with: latestGroups) }

    init(
        store: UsageStore,
        preferences: AppPreferences,
        launchAtLogin: LaunchAtLoginController,
        updateController: UpdateController,
        statusBar: NSStatusBar = .system,
        application: any ApplicationActivating = NSApplication.shared
    ) {
        self.store = store
        self.preferences = preferences
        self.launchAtLogin = launchAtLogin
        self.updateController = updateController
        self.statusBar = statusBar
        self.application = application
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        let item = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.refreshStatusAppearance()
                }
            }
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.font = .monospacedDigitSystemFont(
                ofSize: NSFont.systemFontSize,
                weight: .regular
            )
        }

        trackMenuBarState()
        store.start()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        hasRenderedStatusImage = false
        renderedAppearance = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        store.stop()
        hidePanel()
        usagePanel?.delegate = nil
        usagePanel?.close()
        usagePanel?.contentViewController = nil
        usagePanel = nil
        dashboardHost = nil
        settingsWindow?.close()
        settingsWindow?.contentViewController = nil
        settingsWindow = nil
        analyticsWindow?.close()
        analyticsWindow?.contentViewController = nil
        analyticsWindow = nil

        if let statusItem {
            statusBar.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    @objc
    func togglePanel(_ sender: Any?) {
        panelLog.notice("Status item toggle received; buttonWindow=\(self.currentStatusButton?.window != nil)")
        if presentationTask != nil || usagePanel?.isVisible == true {
            hidePanel()
            return
        }
        capturePanelAnchor(at: sender is NSStatusBarButton ? NSEvent.mouseLocation : nil)
        if sender is NSStatusBarButton {
            // The real menu-bar action can arrive while AppKit is still unwinding
            // its status-item tracking. Present on the next main-actor turn.
            presentationTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.isStarted else { return }
                self.presentationTask = nil
                self.showPanel()
            }
        } else {
            showPanel()
        }
    }

    private func capturePanelAnchor(at pointer: NSPoint?) {
        let source = statusButtonRect()
        let point = pointer ?? source.map { NSPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        panelScreen = screen
        if let source, source.contains(point) {
            panelAnchor = source
        } else {
            // Replicated status items can send actions without a local button window.
            // Never make presentation conditional on that private hosting window.
            let width = max(24, statusItem?.button?.bounds.width ?? 24)
            let top = screen?.frame.maxY ?? point.y
            panelAnchor = NSRect(x: point.x - width / 2, y: top - NSStatusBar.system.thickness,
                                 width: width, height: NSStatusBar.system.thickness)
        }
    }

    func showSettings() {
        guard isStarted else { return }
        preferences.markInitialSetupCompleted()
        hidePanel()
        application.setDockVisible(true)
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        fitSettingsWindow()
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        application.activate()
    }

    func reopenMainWindow() {
        if analyticsWindow?.isVisible == true || analyticsWindow?.isMiniaturized == true {
            showAnalytics()
        } else { showSettings() }
    }

    func showAnalytics() {
        guard isStarted else { return }
        hidePanel()
        application.setDockVisible(true)
        if analyticsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "AI Usage Dashboard"
            window.identifier = NSUserInterfaceItemIdentifier("aiusage.analytics")
            window.isReleasedWhenClosed = false
            window.delegate = self
            let hosting = NSHostingController(rootView: UsageDashboardView(store: store, preferences: preferences))
            hosting.sizingOptions = []
            (hosting.view as? NSHostingView<UsageDashboardView>)?.sizingOptions = []
            hosting.safeAreaRegions = []
            window.contentViewController = hosting
            window.contentMinSize = NSSize(width: 1080, height: 700)
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 1000)
            window.setContentSize(NSSize(width: max(1080, min(1280, screen.width - 60)), height: max(700, min(850, screen.height - 60))))
            window.center()
            analyticsWindow = window
        }
        analyticsWindow?.deminiaturize(nil)
        analyticsWindow?.makeKeyAndOrderFront(nil)
        application.activate()
    }

    private func fitSettingsWindow() {
        guard let window = settingsWindow, settingsMeasuredHeight > 0 else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let titleHeight = window.frame.height - (window.contentView?.bounds.height ?? 0)
        let height = min(settingsMeasuredHeight + 2, max(240, visible.height - titleHeight - 8))
        let size = NSSize(width: AppSurfaceLayout.settingsWidth, height: height)
        guard window.contentView?.bounds.size != size else { return }
        let top = min(window.frame.maxY, visible.maxY - 4)
        window.contentMinSize = .zero
        window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: max(visible.minY + 4, top - window.frame.height)))
        window.contentMinSize = size
        window.contentMaxSize = size
    }

    private func makeSettingsWindow() -> NSWindow {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let availableHeight = max(240, floor((screen?.visibleFrame.height ?? 900) - 48))
        let root = SettingsRootView(store: store, preferences: preferences,
            launchAtLogin: launchAtLogin, updateController: updateController, contentHeightChanged: { [weak self] height in
                guard let self, height > 0, self.settingsMeasuredHeight != ceil(height) else { return }
                self.settingsMeasuredHeight = ceil(height)
                DispatchQueue.main.async { [weak self] in self?.fitSettingsWindow() }
            })
        let host = NSHostingController(rootView: root)
        host.sizingOptions = []
        (host.view as? NSHostingView<SettingsRootView>)?.sizingOptions = []
        host.safeAreaRegions = []
        // Measure actual content after attachment, rather than asking a scroll view
        // for an unbounded fitting size while AppKit owns the window constraints.
        let initialHeight = min(availableHeight, AppSurfaceLayout.settingsHeight)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: AppSurfaceLayout.settingsWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.delegate = self
        window.title = "AI Usage Settings"
        window.animationBehavior = .none
        window.identifier = NSUserInterfaceItemIdentifier("aiusage.settings")
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        let fixedSize = NSSize(width: AppSurfaceLayout.settingsWidth, height: initialHeight)
        window.contentMinSize = fixedSize
        window.contentMaxSize = fixedSize
        window.setContentSize(fixedSize)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.backgroundColor = .windowBackgroundColor
        window.center()
        return window
    }

    private func showPanel() {
        guard isStarted, statusItem?.button != nil else { return }
        if usagePanel == nil {
            let panel = UsagePanel(contentRect: NSRect(x: 0, y: 0, width: AppSurfaceLayout.dashboardWidth, height: 240),
                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "AI Usage"
            panel.identifier = NSUserInterfaceItemIdentifier("aiusage.dashboard")
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.hidesOnDeactivate = false
            panel.level = .popUpMenu
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.delegate = self
            let host = DashboardPanelView(rootView: DashboardRootView(
                store: store, launchAtLogin: launchAtLogin, preferences: preferences,
                updateController: updateController, presentation: panelPresentation,
                openSettings: { [weak self] in self?.showSettings() },
                openAnalytics: { [weak self] in self?.showAnalytics() }))
            panel.contentView = host
            host.onContentSizeChange = { [weak self] in self?.resizeAndPositionPanel() }
            usagePanel = panel
            dashboardHost = host
        }
        if panelAnchor == nil { capturePanelAnchor(at: nil) }
        previousForegroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        panelPresentation.isVisible = true
        resizeAndPositionPanel()
        usagePanel?.makeKeyAndOrderFront(nil)
        dashboardHost?.layoutSubtreeIfNeeded()
        panelLog.notice("Panel presented: visible=\(self.usagePanel?.isVisible == true) width=\(self.usagePanel?.frame.width ?? 0) height=\(self.usagePanel?.frame.height ?? 0)")
        installPanelMonitors()
    }

    func hidePanel() {
        presentationTask?.cancel()
        presentationTask = nil
        if panelPresentation.isVisible { panelLog.notice("Panel dismissed") }
        panelPresentation.isVisible = false
        usagePanel?.orderOut(nil)
        removePanelMonitors()
    }

    private func statusButtonRect() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func resizeAndPositionPanel() {
        guard panelPresentation.isVisible, let panel = usagePanel, let host = dashboardHost,
              let anchor = panelAnchor else { return }
        let screen = panelScreen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let top = anchor.minY > visible.minY + 4
            ? min(visible.maxY, anchor.minY - 4)
            : visible.maxY
        let maxHeight = floor(top - visible.minY)
        let size = host.fittedSize(maximumHeight: maxHeight)
        let x = max(visible.minX, min(anchor.midX - size.width / 2, visible.maxX - size.width))
        let y = top - size.height
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        // AppKit disclosure constraints are the sole animation source. Keep
        // the panel's top edge fixed while following the native stack height.
        if panel.frame != frame { panel.setFrame(frame, display: false, animate: false) }
        host.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()
    }

    private func installPanelMonitors() {
        removePanelMonitors()
        let monitorStart = ProcessInfo.processInfo.systemUptime
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard event.timestamp >= monitorStart else { return }
            let point = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, !self.isStatusItemPoint(point) else { return }
                self.hidePanel()
            }
        }
        activationMonitor = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                let pid = app.processIdentifier
                Task { @MainActor [weak self] in
                    guard let self, pid != ProcessInfo.processInfo.processIdentifier,
                          pid != self.previousForegroundPID else { return }
                    self.hidePanel()
                }
            }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handlePanelEvent(event)
        }
    }

    func handlePanelEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            if event.keyCode == 53, event.window === usagePanel { hidePanel(); return nil }
        } else if event.window !== usagePanel {
            if let statusWindow = statusItem?.button?.window, event.window === statusWindow { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            if !isStatusItemPoint(point) { hidePanel() }
        }
        return event
    }

    private func isStatusItemPoint(_ point: NSPoint) -> Bool {
        panelAnchor?.contains(point) == true || statusButtonRect()?.contains(point) == true
    }

    private func removePanelMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let activationMonitor { NSWorkspace.shared.notificationCenter.removeObserver(activationMonitor) }
        outsideClickMonitor = nil
        localEventMonitor = nil
        activationMonitor = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === settingsWindow || window === analyticsWindow else { return }
        let other = window === settingsWindow ? analyticsWindow : settingsWindow
        application.setDockVisible(other?.isVisible == true || other?.isMiniaturized == true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // A replicated menu-bar click can transiently release key focus while opening.
        // Dismiss on actual outside clicks, Escape, or a foreground-app change instead.
    }

    private func trackMenuBarState() {
        guard isStarted else { return }

        store.setTrackedProviders(preferences.trackedProviderIDs)
        let state = withObservationTracking {
            (
                groups: store.menuBarProviderReadings(
                    for: preferences.menuBarProviderConfigurations,
                    displayMode: preferences.usageDisplayMode
                ),
                trackedProviders: preferences.trackedProviderIDs,
                refreshInterval: preferences.refreshInterval,
                panelStates: store.states,
                providerOrder: preferences.providerOrder
            )
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.trackMenuBarState()
            }
        }

        store.setTrackedProviders(state.trackedProviders)
        store.setRefreshInterval(state.refreshInterval)
        updateStatusItem(with: state.groups)
        if panelPresentation.isVisible { resizeAndPositionPanel() }
    }

    private func updateStatusItem(with groups: [MenuBarProviderReadings]) {
        guard let button = statusItem?.button else { return }
        let appearance = button.effectiveAppearance.bestMatch(from: [
            .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua
        ]) ?? .aqua
        // AppKit emits effectiveAppearance KVO during status-item replication, even
        // when the resolved appearance is unchanged. Never force a redraw from KVO:
        // setting button.image would schedule another replication/KVO cycle.
        guard !hasRenderedStatusImage || latestGroups != groups || renderedAppearance != appearance else { return }
        latestGroups = groups
        renderedAppearance = appearance
        hasRenderedStatusImage = true

        let collectionPresentation = MenuBarReadingsPresentation(
            groups: groups
        )
        button.toolTip = collectionPresentation.accessibilityLabel
        button.setAccessibilityLabel(collectionPresentation.accessibilityLabel)

        guard !groups.isEmpty else {
            button.attributedTitle = NSAttributedString()
            button.image = statusImage(for: nil)
            button.title = ""
            return
        }

        button.attributedTitle = NSAttributedString()
        button.image = nil
        button.title = ""
        button.image = MenuBarStatusImageRenderer.image(
            for: groups,
            font: button.font ?? NSFont.menuBarFont(ofSize: 0)
        )
    }

    private func statusImage(for provider: ProviderID?) -> NSImage {
        if let provider {
            return ProviderIcon.templateImage(for: provider, size: 15)
        }

        guard let source = NSImage(
            systemSymbolName: "gauge.with.dots.needle.50percent",
            accessibilityDescription: nil
        ), let image = source.copy() as? NSImage else {
            return NSImage(size: NSSize(width: 15, height: 15))
        }
        image.size = NSSize(width: 15, height: 15)
        image.isTemplate = true
        return image
    }
}

// AppKit owns disclosure and all vertical geometry. SwiftUI only draws each
// fixed-height summary/body, with no geometry animation or frame feedback.
@MainActor
private final class DashboardHostingView: NSHostingView<DashboardRootView> {
    var onSizeInvalidated: (() -> Void)?
    var measuredHeight: CGFloat?
    var naturalHeight: CGFloat { measuredHeight ?? ceil(fittingSize.height) }
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeInvalidated?()
    }
}

@MainActor
final class ProviderDisclosureBody: NSView {
    var onHeightChange: (() -> Void)?
    override var isFlipped: Bool { true }
    private var previousHeight: CGFloat = -1
    override func layout() {
        super.layout()
        if bounds.height != previousHeight {
            previousHeight = bounds.height
            onHeightChange?()
        }
    }
}

@MainActor
final class NativeProviderSection: NSView {
    let stack = NSStackView()
    let details = ProviderDisclosureBody()
    private let summaryController: NSHostingController<AnyView>
    private let detailsController: NSHostingController<AnyView>
    private let summaryHost: NSView
    private let detailsHost: NSView
    private var summaryHeight: NSLayoutConstraint!
    private var detailContentHeight: NSLayoutConstraint!
    private(set) var detailHeight: NSLayoutConstraint!
    private(set) var isExpanded = false
    private var naturalDetailHeight: CGFloat = 0
    private var naturalSummaryHeight: CGFloat = 0
    var onHeightChange: (() -> Void)?
    var makeContent: ((ProviderSectionPart, Bool, @escaping () -> Void) -> AnyView)?
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        summaryController = NSHostingController(rootView: AnyView(EmptyView()))
        detailsController = NSHostingController(rootView: AnyView(EmptyView()))
        summaryController.sizingOptions = []
        detailsController.sizingOptions = []
        summaryHost = summaryController.view
        detailsHost = detailsController.view
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for host in [summaryHost, detailsHost] {
            if let hostingView = host as? NSHostingView<AnyView> {
                hostingView.sizingOptions = []
                hostingView.isFlipped = true
            }
            host.translatesAutoresizingMaskIntoConstraints = false
        }
        details.wantsLayer = true
        details.layer?.masksToBounds = true
        details.translatesAutoresizingMaskIntoConstraints = false
        details.addSubview(detailsHost)
        stack.addArrangedSubview(summaryHost)
        stack.addArrangedSubview(details)
        summaryHeight = summaryHost.heightAnchor.constraint(equalToConstant: 0)
        detailContentHeight = detailsHost.heightAnchor.constraint(equalToConstant: 0)
        detailHeight = details.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            summaryHost.widthAnchor.constraint(equalTo: stack.widthAnchor), summaryHeight,
            details.widthAnchor.constraint(equalTo: stack.widthAnchor), detailHeight,
            detailsHost.leadingAnchor.constraint(equalTo: details.leadingAnchor),
            detailsHost.topAnchor.constraint(equalTo: details.topAnchor),
            detailsHost.widthAnchor.constraint(equalTo: details.widthAnchor), detailContentHeight
        ])
        details.onHeightChange = { [weak self] in self?.onHeightChange?() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        guard let makeContent else { return }
        let toggle: () -> Void = { [weak self] in self?.setExpanded(!(self?.isExpanded ?? false), animated: true) }
        summaryController.rootView = AnyView(makeContent(.summary, isExpanded, toggle)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.setSummaryHeight(height)
            }
            .transaction { $0.animation = nil })
        detailsController.rootView = AnyView(makeContent(.details, isExpanded, toggle)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.setDetailHeight(height)
            }
            .transaction { $0.animation = nil })
        let proposal = NSSize(width: AppSurfaceLayout.dashboardWidth - 20, height: .greatestFiniteMagnitude)
        setSummaryHeight(summaryController.sizeThatFits(in: proposal).height)
        setDetailHeight(detailsController.sizeThatFits(in: proposal).height)
    }

    private func setSummaryHeight(_ value: CGFloat) {
        let height = ceil(value)
        guard height != naturalSummaryHeight else { return }
        naturalSummaryHeight = height
        summaryHeight.constant = height
        onHeightChange?()
    }
    private func setDetailHeight(_ value: CGFloat) {
        let height = ceil(value)
        guard height != naturalDetailHeight else { return }
        naturalDetailHeight = height
        detailContentHeight.constant = height
        if isExpanded { detailHeight.constant = height }
        onHeightChange?()
    }
    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        // Neither hosting root is inserted or removed during disclosure.
        // Only the clipped body's height constraint changes (Apple stack sample).
        reload()
        superview?.layoutSubtreeIfNeeded()
        let height = expanded ? naturalDetailHeight : 0
        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                detailHeight.animator().constant = height
            }
        } else {
            detailHeight.constant = height
            onHeightChange?()
        }
    }
}

@MainActor
private final class ProviderStackDocument: NSView {
    override var isFlipped: Bool { true }
}

struct NativeProviderContent: View {
    @Bindable var store: UsageStore
    @Bindable var preferences: AppPreferences
    let provider: ProviderID
    let presentation: UsagePanelPresentation
    let part: ProviderSectionPart
    let expanded: Bool
    let toggle: () -> Void
    var body: some View {
        Group {
            if GoogleAIGroup.members.contains(provider) {
                GoogleAISectionView(states: GoogleAIGroup.ordered(preferences.providerOrder.filter(store.isProviderVisibleInDashboard))
                    .filter { GoogleAIGroup.members.contains($0) }.compactMap { store.states[$0] },
                    displayMode: preferences.usageDisplayMode, part: part, expandedOverride: part == .details ? true : expanded, onToggle: toggle)
            } else if let state = store.states[provider] {
                ProviderSectionView(state: state, displayMode: preferences.usageDisplayMode,
                                    expandedOverride: part == .details ? true : expanded, part: part, onToggle: toggle)
            }
        }
        .environment(\.usagePanelVisible, presentation.isVisible && (part != .details || expanded))
    }
}

@MainActor
final class DashboardPanelView: NSView {
    private let header: DashboardHostingView
    private let footer: DashboardHostingView
    private let root: DashboardRootView
    let providerStack = NSStackView()
    private let document = ProviderStackDocument()
    private(set) var sections: [ProviderID: NativeProviderSection] = [:]
    private var providerIDs: [ProviderID] = []
    let scrollView = NSScrollView()
    var onContentSizeChange: (() -> Void)?
    private var resizeQueued = false
    private var rowHeight: CGFloat = 0
    private var headerHeight: CGFloat = 0
    private var footerHeight: CGFloat = 0
    override var isFlipped: Bool { true }

    init(rootView: DashboardRootView) {
        root = rootView
        var content = rootView
        content.section = .header
        header = DashboardHostingView(rootView: content)
        content.section = .footer
        footer = DashboardHostingView(rootView: content)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        providerStack.orientation = .vertical
        providerStack.alignment = .leading
        providerStack.spacing = 8
        providerStack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 6, right: 10)
        providerStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(providerStack)
        NSLayoutConstraint.activate([
            providerStack.topAnchor.constraint(equalTo: document.topAnchor),
            providerStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            providerStack.widthAnchor.constraint(equalToConstant: AppSurfaceLayout.dashboardWidth)
        ])
        addSubview(header)
        addSubview(scrollView)
        addSubview(footer)
        for view in [header, footer] {
            view.setFrameSize(NSSize(width: AppSurfaceLayout.dashboardWidth, height: 1))
            view.sizingOptions = [.intrinsicContentSize]
            view.isFlipped = true
            view.rootView.onHeightChange = { [weak self, weak view] height in
                guard let self, let view else { return }
                let value = ceil(height)
                guard value > 0, view.measuredHeight != value else { return }
                view.measuredHeight = value
                self.scheduleResize()
            }
            view.onSizeInvalidated = { [weak self] in self?.scheduleResize() }
        }
        synchronizeProviders()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func synchronizeProviders() {
        let visible = GoogleAIGroup.ordered(root.preferences.providerOrder.filter(root.store.isProviderVisibleInDashboard))
        let firstGoogle = visible.first { GoogleAIGroup.members.contains($0) }
        let ids = visible.filter { !GoogleAIGroup.members.contains($0) || $0 == firstGoogle }
        guard ids != providerIDs else { return }
        providerIDs = ids
        for view in providerStack.arrangedSubviews {
            providerStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sections = sections.filter { ids.contains($0.key) }
        for (index, id) in ids.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.boxType = .separator
                providerStack.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalToConstant: AppSurfaceLayout.dashboardWidth - 20).isActive = true
            }
            let section = sections[id] ?? NativeProviderSection(frame: .zero)
            sections[id] = section
            section.makeContent = { [root] part, expanded, toggle in
                AnyView(NativeProviderContent(store: root.store, preferences: root.preferences,
                    provider: id, presentation: root.presentation, part: part, expanded: expanded, toggle: toggle))
            }
            section.onHeightChange = { [weak self] in self?.scheduleResize() }
            providerStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalToConstant: AppSurfaceLayout.dashboardWidth - 20).isActive = true
            section.reload()
        }
    }
    private func scheduleResize() {
        guard !resizeQueued else { return }
        resizeQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeQueued = false
            let heights = [self.header.naturalHeight, ceil(self.providerStack.fittingSize.height), self.footer.naturalHeight]
            guard heights != [self.headerHeight, self.rowHeight, self.footerHeight] else { return }
            self.onContentSizeChange?()
        }
    }
    func fittedSize(maximumHeight: CGFloat) -> NSSize {
        synchronizeProviders()
        header.layoutSubtreeIfNeeded()
        footer.layoutSubtreeIfNeeded()
        headerHeight = header.naturalHeight
        footerHeight = footer.naturalHeight
        providerStack.layoutSubtreeIfNeeded()
        rowHeight = ceil(providerStack.fittingSize.height)
        needsLayout = true
        return NSSize(width: AppSurfaceLayout.dashboardWidth,
                      height: min(maximumHeight, headerHeight + rowHeight + footerHeight))
    }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let viewport = max(0, bounds.height - headerHeight - footerHeight)
        let offset = scrollView.contentView.bounds.origin.y
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: rowHeight)
        scrollView.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: viewport)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, offset), max(0, rowHeight - viewport))))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        footer.frame = NSRect(x: 0, y: headerHeight + viewport, width: bounds.width, height: footerHeight)
    }
}

struct DashboardRootView: View {
    let store: UsageStore
    let launchAtLogin: LaunchAtLoginController
    @Bindable var preferences: AppPreferences
    @Bindable var updateController: UpdateController
    let presentation: UsagePanelPresentation
    let openSettings: @MainActor () -> Void
    var openAnalytics: @MainActor () -> Void = {}
    var section: DashboardSection = .rows
    var onHeightChange: ((CGFloat) -> Void)?

    var body: some View {
        DashboardView(
            store: store,
            launchAtLogin: launchAtLogin,
            usageDisplayMode: $preferences.usageDisplayMode,
            refreshInterval: $preferences.refreshInterval,
            availableUpdateVersion: updateController.availableVersion,
            isCheckingForUpdates: updateController.isChecking,
            checkForUpdates: updateController.checkForUpdates,
            openSettings: openSettings,
            openAnalytics: openAnalytics,
            providerOrder: preferences.providerOrder,
            section: section
        )
        .environment(\.usagePanelVisible, presentation.isVisible)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            onHeightChange?(height)
        }
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
        .transaction { $0.animation = nil }
    }
}

private struct SettingsRootView: View {
    let store: UsageStore
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @Bindable var updateController: UpdateController
    var contentHeightChanged: ((CGFloat) -> Void)?
    var body: some View {
        ScrollView {
            settingsContent
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsContent: some View {
        SettingsView(
            store: store,
            preferences: preferences,
            launchAtLogin: launchAtLogin,
            updateController: updateController,
            isInSettingsWindow: true
        )
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeightChanged?($0) }
    }
}
