import AppKit
import SwiftUI
import Combine

@MainActor
final class RenduAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model: MonitorModel = {
        #if AUTORENDER_UI_HARNESS
        return MonitorModel()
        #else
        let canonical = LoginItemController.isCanonical(bundleURL: Bundle.main.bundleURL,
            homeURL: FileManager.default.homeDirectoryForCurrentUser, bundleIdentifier: Bundle.main.bundleIdentifier)
        return MonitorModel(macOnly: MacOnlyStartupPolicy.shouldApply(
            requested: CommandLine.arguments.contains("--mac-only"), canonical: canonical))
        #endif
    }()
    private lazy var softwareUpdates = SoftwareUpdateCoordinator(safety: { [weak model = model] in
        guard let model else { return (false, "État des rendus indisponible.") }
        let assessment = model.softwareUpdateSafetyAssessment(at: Date())
        return (assessment.safety == .safe, assessment.reason)
    })
    private lazy var loginItems = LoginItemController(service: LoginItemServiceFactory.make(),
        mayRegister: mayManageLoginItem)
    private var mayManageLoginItem: Bool {
        #if AUTORENDER_UI_HARNESS
        return false
        #else
        return LoginItemController.isCanonical(bundleURL: Bundle.main.bundleURL,
            homeURL: FileManager.default.homeDirectoryForCurrentUser, bundleIdentifier: Bundle.main.bundleIdentifier)
        #endif
    }
    private let startupUptime = ProcessInfo.processInfo.systemUptime
    private lazy var startupDiagnostic = StartupDiagnostic(
        requested: CommandLine.arguments.contains("--diagnostic-startup"),
        canonical: mayManageLoginItem, startedAt: startupUptime)
    private lazy var windowFrameDiagnostic = WindowFrameDiagnostic(
        requested: CommandLine.arguments.contains("--diagnostic-windows"),
        canonical: mayManageLoginItem, startedAt: startupUptime)
    private var lastMenuPresentation: MenuBarPresentation?
    private var statusUpdateQueued = false
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var overviewWindow: NSWindow?
    private var compactWindow: NSWindow?
    private var modelUpdates: AnyCancellable?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private var quitRequest = SoftwareUpdateQuitRequest()
    private struct WindowGeometrySpec {
        let key: String
        let initial: NSSize
        let minimum: NSSize
    }
    private var geometrySpecs: [ObjectIdentifier: WindowGeometrySpec] = [:]
    private var applyingGeometry = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        emitMacOnlyDiagnostic()
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = RenduLogo.app
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 520, height: 600)
        popover.contentViewController = RenderHostingController(rootView: summary(detached: false))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = RenduLogo.menu
        item.button?.imagePosition = .imageLeft
        item.button?.cell?.lineBreakMode = .byTruncatingMiddle
        item.button?.toolTip = "AUTORENDER — rendus Mac et Shadow"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        modelUpdates = model.objectWillChange.sink { [weak self] _ in
            guard let self, !self.statusUpdateQueued else { return }
            self.statusUpdateQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.statusUpdateQueued = false
                self.updateStatus()
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationBecameActive(_:)),
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        installApplicationMenu()
        updateStatus()
        model.start()
        #if !AUTORENDER_UI_HARNESS
        if CommandLine.arguments.contains("--enable-login-item") {
            loginItems.enable()
            let diagnostic = ["operation": "enable-login-item", "state": String(describing: loginItems.state),
                              "error": loginItems.error == nil ? "none" : "operation-failed"]
            if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { StartupDiagnostic.writeJSONLine(text) }
            emitStartupDiagnostic(observation: model.menuBarObservation(at: Date()))
        }
        #endif
    }

    private func emitMacOnlyDiagnostic() {
        #if !AUTORENDER_UI_HARNESS
        guard CommandLine.arguments.contains("--mac-only") else { return }
        var persisted: Bool?
        if mayManageLoginItem,
           case .loaded(let saved) = RenderConfigurationLoad.read(RenduStorage.root.appendingPathComponent("config.json")) {
            persisted = saved.shadowMonitoringEnabled
        }
        if let line = MacOnlyStartupPolicy.diagnostic(canonical: mayManageLoginItem,
            runtimeShadowEnabled: model.shadowMonitoringEnabled, persistedShadowEnabled: persisted) {
            StartupDiagnostic.writeJSONLine(line)
        }
        #endif
    }

    private func summary(detached: Bool) -> MenuSummaryView {
        MenuSummaryView(model: model, detached: detached, loginItems: loginItems,
                        openOverview: { [weak self] in self?.popover.performClose(nil); self?.showOverview() },
                        detach: { [weak self] in self?.popover.performClose(nil); self?.showCompact() },
                        openSection: { [weak self] scope in self?.popover.performClose(nil); self?.showOverview(scope: scope) },
                        openLibrary: { [weak self] in self?.popover.performClose(nil); self?.showOverview(library: true) })
    }

    private func makeWindow(title: String, size: NSSize, minimum: NSSize, key: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = RenderStyle.appearance
        window.titlebarAppearsTransparent = true
        window.title = title
        // SwiftUI specifies content dimensions; the policy works with outer frames.
        // Ask AppKit for the title/chrome conversion instead of hardcoding an offset.
        let initialFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        let minimumFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        geometrySpecs[ObjectIdentifier(window)] = WindowGeometrySpec(key: key,
            initial: initialFrameSize, minimum: minimumFrameSize)
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        return window
    }

    private func restoreGeometry(_ window: NSWindow, key: String) {
        // Content is attached first, and AppKit restores before autosave is enabled.
        // Forced restore lets the pure policy repair legacy undersized frames itself.
        let restored = window.setFrameUsingName(key, force: true)
        applyGeometry(window, saved: restored ? window.frame : nil)
        window.setFrameAutosaveName(key)
        window.delegate = self
        window.saveFrame(usingName: key)
    }

    private func applyGeometry(_ window: NSWindow, saved: NSRect?) {
        guard let spec = geometrySpecs[ObjectIdentifier(window)],
              let placement = RenderWindowGeometry.resolve(saved: saved,
                screens: NSScreen.screens.map(\.visibleFrame), fallbackScreen: NSScreen.main?.visibleFrame,
                initial: spec.initial, minimum: spec.minimum) else { return }
        applyingGeometry = true
        defer { applyingGeometry = false }
        // Update constraints after restoring; small displays must remain recoverable.
        window.minSize = placement.minimum
        if window.frame != placement.frame { window.setFrame(placement.frame, display: window.isVisible) }
    }

    private func saveGeometry(_ notification: Notification) {
        guard !applyingGeometry, let window = notification.object as? NSWindow,
              let spec = geometrySpecs[ObjectIdentifier(window)] else { return }
        window.saveFrame(usingName: spec.key)
    }

    func windowDidMove(_ notification: Notification) {
        guard !applyingGeometry else { return }
        saveGeometry(notification)
        if let window = notification.object as? NSWindow { emitWindowFrame(.move, window: window) }
    }
    func windowDidResize(_ notification: Notification) {
        // Programmatic/AX frame changes can bypass interactive minSize constraints.
        guard !applyingGeometry, let window = notification.object as? NSWindow else { return }
        applyGeometry(window, saved: window.frame)
        saveGeometry(notification)
        emitWindowFrame(.resize, window: window)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard !applyingGeometry, let window = notification.object as? NSWindow else { return }
        applyGeometry(window, saved: window.frame)
        saveGeometry(notification)
    }
    func windowWillClose(_ notification: Notification) {
        saveGeometry(notification)
        if let window = notification.object as? NSWindow {
            emitWindowFrame(.close, window: window)
            syncCompactPreviewVisibility(excluding: window)
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { syncCompactPreviewVisibility() }
    func windowDidDeminiaturize(_ notification: Notification) { syncCompactPreviewVisibility() }
    func popoverDidShow(_ notification: Notification) { syncCompactPreviewVisibility() }
    func popoverDidClose(_ notification: Notification) { syncCompactPreviewVisibility() }
    func applicationDidHide(_ notification: Notification) { syncCompactPreviewVisibility() }
    func applicationDidUnhide(_ notification: Notification) { syncCompactPreviewVisibility() }
    private func syncCompactPreviewVisibility(excluding closingWindow: NSWindow? = nil) {
        let compactVisible = compactWindow.map { $0 !== closingWindow && $0.isVisible && !$0.isMiniaturized } ?? false
        model.setCompactPreviewVisibility(!NSApp.isHidden && (compactVisible || popover.isShown))
    }
    private func emitWindowFrame(_ action: WindowFrameDiagnostic.Action, window: NSWindow) {
        let kind: WindowFrameDiagnostic.Kind
        if window === compactWindow { kind = .compact }
        else if window === overviewWindow { kind = .dashboard }
        else { return }
        windowFrameDiagnostic.record(kind: kind, action: action, frame: window.frame,
            isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
            at: ProcessInfo.processInfo.systemUptime)
    }

    @objc private func applicationBecameActive(_ notification: Notification) {
        loginItems.refresh()
        updateStatus()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        lastMenuPresentation = nil
        updateStatus()
        for window in [overviewWindow, compactWindow].compactMap({ $0 }) {
            applyGeometry(window, saved: window.frame)
            if let spec = geometrySpecs[ObjectIdentifier(window)] { window.saveFrame(usingName: spec.key) }
        }
    }

    private func reveal(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        applyGeometry(window, saved: window.frame)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        emitWindowFrame(.show, window: window)
        syncCompactPreviewVisibility()
    }

    private func showOverview(scope: CatalogScope? = nil, library: Bool = false) {
        let existed = overviewWindow != nil
        if overviewWindow == nil {
            let window = makeWindow(title: "AUTORENDER — Vue générale", size: NSSize(width: 1240, height: 800),
                                    minimum: NSSize(width: 920, height: 650), key: "AUTORENDER.Overview")
            window.contentViewController = RenderHostingController(rootView: ContentView(model: model, openCompact: { [weak self] in self?.showCompact() }, quit: { [weak self] in self?.requestUserQuit() }, initialScope: scope ?? .direct,
                initialLibrary: library || model.config.librarySettings == nil))
            restoreGeometry(window, key: "AUTORENDER.Overview")
            overviewWindow = window
        }
        reveal(overviewWindow)
        if existed {
            var request: [String: Any] = ["library": library]
            if let scope { request["scope"] = scope.rawValue }
            NotificationCenter.default.post(name: CatalogProjectionSnapshot.request, object: model, userInfo: request)
        }
    }

    private func prepareCompact() -> NSWindow {
        if let compactWindow { return compactWindow }
        let window = makeWindow(title: "AUTORENDER — Suivi compact", size: NSSize(width: 520, height: 640),
                                minimum: NSSize(width: 480, height: 340), key: "AUTORENDER.Compact")
        window.contentViewController = RenderHostingController(rootView: summary(detached: true))
        restoreGeometry(window, key: "AUTORENDER.Compact")
        compactWindow = window
        return window
    }

    private func showCompact() { reveal(prepareCompact()) }

    func detachableWindow(for popover: NSPopover) -> NSWindow? { prepareCompact() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOverview()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func togglePopover() {
        if let compactWindow {
            if compactWindow.isVisible && !compactWindow.isMiniaturized {
                compactWindow.orderOut(nil)
                emitWindowFrame(.hide, window: compactWindow)
                syncCompactPreviewVisibility()
            } else {
                reveal(compactWindow)
            }
            return
        }
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            loginItems.refresh()
            popover.contentViewController = RenderHostingController(rootView: summary(detached: false))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let root = NSMenuItem()
        menu.addItem(root)
        let appMenu = NSMenu(title: "AUTORENDER")
        let overview = NSMenuItem(title: "Vue générale", action: #selector(openOverviewAction), keyEquivalent: "1")
        overview.target = self; appMenu.addItem(overview)
        let compact = NSMenuItem(title: "Suivi compact", action: #selector(openCompactAction), keyEquivalent: "2")
        compact.target = self; appMenu.addItem(compact)
        appMenu.addItem(.separator())
        let library = NSMenuItem(title: "Bibliothèque et réglages…", action: #selector(openLibraryAction), keyEquivalent: ",")
        library.target = self; appMenu.addItem(library)
        let login = NSMenuItem(title: "Ouverture de session", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self; appMenu.addItem(login)
        let settings = NSMenuItem(title: "Réglages d’ouverture de session…", action: #selector(openLoginSettings), keyEquivalent: "")
        settings.target = self; appMenu.addItem(settings)
        let updates = NSMenuItem(title: "Rechercher les mises à jour…", action: #selector(checkSoftwareUpdates), keyEquivalent: "")
        updates.target = self; appMenu.addItem(updates)
        let quit = NSMenuItem(title: "Quitter AUTORENDER", action: #selector(quitApplicationAction), keyEquivalent: "q")
        quit.target = self; appMenu.addItem(quit)
        root.submenu = appMenu
        let windowRoot = NSMenuItem(title: "Fenêtre", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Fenêtre")
        windowRoot.submenu = windowMenu
        menu.addItem(windowRoot)
        windowMenu.addItem(NSMenuItem(title: "Fermer", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Réduire", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Agrandir / rétablir", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        let compactSize = NSMenuItem(title: "Taille compacte du suivi", action: #selector(compactSizeAction), keyEquivalent: "")
        compactSize.target = self
        windowMenu.addItem(compactSize)
        let defaultSize = NSMenuItem(title: "Taille par défaut de cette fenêtre", action: #selector(defaultSizeAction), keyEquivalent: "")
        defaultSize.target = self
        windowMenu.addItem(defaultSize)
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "Tout ramener au premier plan", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
    }
    @objc private func toggleLoginItem() {
        loginItems.refresh()
        if loginItems.state == .enabled { loginItems.disable() }
        else if loginItems.state == .requiresApproval { loginItems.openSettings() }
        else { loginItems.enable() }
    }
    @objc private func openLoginSettings() { loginItems.openSettings() }
    @objc private func checkSoftwareUpdates() { softwareUpdates.checkForUpdates() }
    @objc private func quitApplicationAction() { requestUserQuit() }
    private func requestUserQuit() {
        quitRequest.markUserRequest()
        defer { quitRequest.clear() }
        NSApp.terminate(nil)
    }
    @objc private func openLibraryAction() { showOverview(library: true) }
    @objc private func openOverviewAction() { showOverview() }
    @objc private func openCompactAction() { showCompact() }

    private var currentManagedWindow: NSWindow? {
        guard let window = NSApp.keyWindow,
              geometrySpecs[ObjectIdentifier(window)] != nil else { return nil }
        return window
    }

    private var canApplyUserSize: Bool {
        guard let window = currentManagedWindow,
              !window.styleMask.contains(.fullScreen),
              window.sheetParent == nil,
              NSApp.modalWindow == nil else { return false }
        return !NSApp.windows.contains { $0.attachedSheet != nil }
    }

    // Explicit user action: preserve the top edge and horizontal position, then
    // reuse the normal screen/minimum policy and persist its resulting frame.
    private func applyDefaultSize(_ window: NSWindow) {
        guard canApplyUserSize, !window.styleMask.contains(.fullScreen),
              let spec = geometrySpecs[ObjectIdentifier(window)] else { return }
        let resized = NSRect(x: window.frame.minX, y: window.frame.maxY - spec.initial.height,
                             width: spec.initial.width, height: spec.initial.height)
        applyGeometry(window, saved: resized)
        window.saveFrame(usingName: spec.key)
        reveal(window)
    }

    @objc private func compactSizeAction() {
        guard canApplyUserSize else { return }
        applyDefaultSize(prepareCompact())
    }
    @objc private func defaultSizeAction() {
        if let window = currentManagedWindow { applyDefaultSize(window) }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleLoginItem) {
            loginItems.refresh()
            menuItem.title = loginItems.label + (loginItems.error == nil ? "" : " · erreur (voir Options)")
            menuItem.state = loginItems.state == .enabled ? .on : .off
            menuItem.toolTip = loginItems.error
            return loginItems.mayRegister && loginItems.state != .unavailable
        }
        if menuItem.action == #selector(defaultSizeAction) {
            return canApplyUserSize
        }
        if menuItem.action == #selector(compactSizeAction) {
            return canApplyUserSize && (compactWindow.map { !$0.styleMask.contains(.fullScreen) } ?? true)
        }
        return true
    }

    private func updateStatus() {
        let now = Date()
        let observation = model.menuBarObservation(at: now)
        defer { emitStartupDiagnostic(observation: observation) }
        let presentation = MenuBarPresentation.make(snapshot: model.catalogSnapshot,
            observation: observation, now: now)
        guard presentation != lastMenuPresentation else { return }
        lastMenuPresentation = presentation
        guard let button = statusItem?.button else { return }
        let font = button.font ?? NSFont.menuBarFont(ofSize: 0)
        let measure: (String) -> CGFloat = { ( $0 as NSString ).size(withAttributes: [.font: font]).width }
        // Include the logo, image/text gap and button padding inside the fixed cap.
        let reservedWidth = (button.image?.size.width ?? 0) + 6 + 18
        let title = MenuBarWidthPolicy.fit(" " + presentation.title, reservedWidth: reservedWidth, measure: measure)
        let length = min(CGFloat(260), max(NSStatusBar.system.thickness, ceil(measure(title)) + reservedWidth))
        if button.title != title { button.title = title }
        if statusItem?.length != length { statusItem?.length = length }
        if button.toolTip != presentation.tooltip { button.toolTip = presentation.tooltip }
        button.setAccessibilityLabel(presentation.accessibilityLabel)
    }

    private func emitStartupDiagnostic(observation: MenuBarObservation) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard startupDiagnostic.isRecording(at: uptime), let button = statusItem?.button else { return }
        loginItems.refresh()
        let classification: String
        switch observation {
        case .confirmed: classification = "confirmed"
        case .refreshing: classification = "refreshing"
        case .uncertain: classification = "uncertain"
        }
        startupDiagnostic.record(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            pid: ProcessInfo.processInfo.processIdentifier, assignedTitle: button.title,
            itemWidth: Double(statusItem?.length ?? 0), buttonWidth: Double(button.bounds.width),
            observation: classification, loginState: String(describing: loginItems.state),
            loginError: loginItems.error != nil, at: uptime)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let intent = quitRequest.consume()
        if shutdownFinished { return .terminateNow }
        if shutdownTask != nil { return .terminateLater }
        if softwareUpdates.cancelForTermination(intent: intent, completion: { [weak self, weak sender] allowTermination in
            guard let self, let sender else { return }
            if allowTermination { self.finishTermination(sender) }
            else { sender.reply(toApplicationShouldTerminate: false) }
        }) { return .terminateLater }
        finishTermination(sender)
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard shutdownTask == nil else { return }
        model.stop()
        shutdownTask = Task { @MainActor in
            await model.waitForShutdown()
            shutdownFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        modelUpdates?.cancel()
        overviewWindow?.saveFrame(usingName: "AUTORENDER.Overview")
        compactWindow?.saveFrame(usingName: "AUTORENDER.Compact")
        popover.performClose(nil)
        model.stop()
    }
}

