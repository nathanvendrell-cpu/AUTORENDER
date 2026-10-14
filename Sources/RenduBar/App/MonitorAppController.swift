import AppKit
import SwiftUI
import Combine

@MainActor
final class RenduAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate, NSMenuItemValidation {
    private let model = MonitorModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var overviewWindow: NSWindow?
    private var compactWindow: NSWindow?
    private var modelUpdates: AnyCancellable?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private struct WindowGeometrySpec {
        let key: String
        let initial: NSSize
        let minimum: NSSize
    }
    private var geometrySpecs: [ObjectIdentifier: WindowGeometrySpec] = [:]
    private var applyingGeometry = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = RenduLogo.app
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 520, height: 600)
        popover.contentViewController = RenderHostingController(rootView: summary(detached: false))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = RenduLogo.menu
        item.button?.toolTip = "AUTORENDER — rendus Mac et Shadow"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        modelUpdates = model.$catalogSnapshot.map(\.revision).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        installApplicationMenu()
        showOverview()
        model.start()
    }

    private func summary(detached: Bool) -> MenuSummaryView {
        MenuSummaryView(model: model, detached: detached,
                        openOverview: { [weak self] in self?.popover.performClose(nil); self?.showOverview() },
                        detach: { [weak self] in self?.popover.performClose(nil); self?.showCompact() })
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

    func windowDidMove(_ notification: Notification) { saveGeometry(notification) }
    func windowDidResize(_ notification: Notification) {
        // Programmatic/AX frame changes can bypass interactive minSize constraints.
        guard !applyingGeometry, let window = notification.object as? NSWindow else { return }
        applyGeometry(window, saved: window.frame)
        saveGeometry(notification)
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard !applyingGeometry, let window = notification.object as? NSWindow else { return }
        applyGeometry(window, saved: window.frame)
        saveGeometry(notification)
    }
    func windowWillClose(_ notification: Notification) { saveGeometry(notification) }

    @objc private func screenParametersChanged(_ notification: Notification) {
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
    }

    private func showOverview() {
        if overviewWindow == nil {
            let window = makeWindow(title: "AUTORENDER — Vue générale", size: NSSize(width: 1240, height: 800),
                                    minimum: NSSize(width: 920, height: 650), key: "AUTORENDER.Overview")
            window.contentViewController = RenderHostingController(rootView: ContentView(model: model, openCompact: { [weak self] in self?.showCompact() }))
            restoreGeometry(window, key: "AUTORENDER.Overview")
            overviewWindow = window
        }
        reveal(overviewWindow)
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
        if let compactWindow { reveal(compactWindow); return }
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
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
        appMenu.addItem(NSMenuItem(title: "Quitter AUTORENDER", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
        if menuItem.action == #selector(defaultSizeAction) {
            return canApplyUserSize
        }
        if menuItem.action == #selector(compactSizeAction) {
            return canApplyUserSize && (compactWindow.map { !$0.styleMask.contains(.fullScreen) } ?? true)
        }
        return true
    }

    private func updateStatus() {
        let snapshot = model.catalogSnapshot
        statusItem?.button?.title = " \(snapshot.stateCounts.running) actifs"
        statusItem?.button?.toolTip = "AUTORENDER · \(snapshot.knownJobCount) rendus connus · \(snapshot.stateCounts.running) en cours · \(snapshot.stateCounts.resumable) à reprendre"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownFinished { return .terminateNow }
        if shutdownTask != nil { return .terminateLater }
        model.stop()
        shutdownTask = Task { @MainActor in
            await model.waitForShutdown()
            shutdownFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self,
            name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
        modelUpdates?.cancel()
        overviewWindow?.saveFrame(usingName: "AUTORENDER.Overview")
        compactWindow?.saveFrame(usingName: "AUTORENDER.Compact")
        popover.performClose(nil)
        model.stop()
    }
}

