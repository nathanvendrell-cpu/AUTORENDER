import AppKit
import SwiftUI
import Combine

@MainActor
final class RenduAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MonitorModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var overviewWindow: NSWindow?
    private var compactWindow: NSWindow?
    private var modelUpdates: AnyCancellable?
    private var selectionUpdates: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = RenduLogo.app
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 520, height: 600)
        popover.contentViewController = NSHostingController(rootView: summary(detached: false))
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = RenduLogo.menu
        item.button?.toolTip = "AUTORENDER — rendus Mac et Shadow"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        modelUpdates = model.$catalogSnapshot.map(\.revision).removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatus() }
        }
        installApplicationMenu()
        selectionUpdates = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateStatus() }
        }
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
        window.title = title
        window.minSize = minimum
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName(key)
        if !window.setFrameUsingName(key) { window.center() }
        // Restore a saved frame onto a connected screen after a display is removed.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.isMovableByWindowBackground = true
        return window
    }

    private func reveal(_ window: NSWindow?) {
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showOverview() {
        if overviewWindow == nil {
            let window = makeWindow(title: "AUTORENDER — Vue générale", size: NSSize(width: 1240, height: 800),
                                    minimum: NSSize(width: 920, height: 650), key: "AUTORENDER.Overview")
            window.contentViewController = NSHostingController(rootView: ContentView(model: model, openCompact: { [weak self] in self?.showCompact() }))
            overviewWindow = window
        }
        reveal(overviewWindow)
    }

    private func prepareCompact() -> NSWindow {
        if let compactWindow { return compactWindow }
        let window = makeWindow(title: "AUTORENDER — Suivi compact", size: NSSize(width: 520, height: 640),
                                minimum: NSSize(width: 480, height: 340), key: "AUTORENDER.Compact")
        window.contentViewController = NSHostingController(rootView: summary(detached: true))
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
        NSApp.mainMenu = menu
    }
    @objc private func openOverviewAction() { showOverview() }
    @objc private func openCompactAction() { showCompact() }

    private func updateStatus() {
        let snapshot = model.catalogSnapshot
        statusItem?.button?.title = " \(snapshot.stateCounts.running) actifs"
        statusItem?.button?.toolTip = "AUTORENDER · \(snapshot.knownJobCount) jobs connus · \(snapshot.stateCounts.running) en cours · \(snapshot.stateCounts.resumable) à reprendre"
    }

    func applicationWillTerminate(_ notification: Notification) {
        modelUpdates?.cancel()
        if let selectionUpdates { NotificationCenter.default.removeObserver(selectionUpdates) }
        overviewWindow?.saveFrame(usingName: "AUTORENDER.Overview")
        compactWindow?.saveFrame(usingName: "AUTORENDER.Compact")
        popover.performClose(nil)
        model.stop()
    }
}

struct MenuSummaryView: View {
    @ObservedObject var model: MonitorModel
    let detached: Bool
    let openOverview: () -> Void
    let detach: () -> Void
    @AppStorage("AUTORENDER.SelectedProject") private var projectID = ""
    @AppStorage("AUTORENDER.SelectedJob") private var jobID = ""
    @AppStorage("AUTORENDER.SelectedWork") private var workID = ""
    @State private var query = ""
    @State private var scope: CatalogScope = .all
    @State private var sections: [CatalogSection] = []
    @State private var activeCount = 0
    @State private var stoppedCount = 0
    @State private var historicalCount = 0
    @State private var knownCount = 0
    @State private var displayedCount = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(nsImage: RenduLogo.app).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUTORENDER").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Tous les jobs des sources suivies").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                if !detached {
                    Button(action: detach) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("Détacher le suivi compact").accessibilityLabel("Détacher le suivi compact")
                }
                Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Actualiser")
            }
            HStack(spacing: 10) {
                countBadge("Actifs", activeCount, .green)
                countBadge("À reprendre", stoppedCount, .orange)
                countBadge("Historiques", historicalCount, .secondary)
                Spacer()
            }
            HStack {
                TextField("Rechercher projet, travail ou version", text: $query).textFieldStyle(.roundedBorder)
                Picker("Afficher", selection: $scope) {
                    ForEach(CatalogScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sections) { section in
                        Text(section.title).font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary).padding(.top, 5)
                        ForEach(section.jobs) { job in
                            CompactCatalogJobRow(job: job, selected: job.id == jobID) {
                                projectID = job.projectID
                                workID = model.catalogSnapshot.works.first { $0.jobs.contains { $0.id == job.id } }?.id ?? job.id
                                jobID = job.id
                                openOverview()
                            }
                        }
                    }
                    if displayedCount == 0 {
                        Text(query.isEmpty && scope == .all ? "En attente des sources suivies." : "Aucun job pour ce filtre.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.catalogSnapshot.persistenceIssue != nil {
                Text("Catalogue non enregistré : les nouveaux jobs pourraient ne pas survivre à une relance.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack {
                Text("\(displayedCount) affichés / \(knownCount) connus · sources suivies")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Vue générale", action: openOverview).buttonStyle(.bordered)
            }
        }.padding(14).frame(minWidth: 480, minHeight: 340)
            .background(colorScheme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.09) : Color(red: 0.96, green: 0.955, blue: 0.94))
            .onAppear(perform: projectRows)
            .onChange(of: model.catalogSnapshot.revision) { projectRows() }
            .onChange(of: query) { projectRows() }
            .onChange(of: scope) { projectRows() }
    }

    private func countBadge(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(title)
        }.font(.system(size: 10))
    }
    private func projectRows() {
        #if AUTORENDER_UI_HARNESS
        let projectionStart = ProcessInfo.processInfo.systemUptime
        defer { UIHarness50Metrics.recordProjection(known: knownCount, displayed: displayedCount,
            seconds: ProcessInfo.processInfo.systemUptime - projectionStart) }
        #endif
        let snapshot = model.catalogSnapshot
        let jobs = snapshot.jobs
        knownCount = snapshot.knownJobCount
        activeCount = snapshot.stateCounts.running
        stoppedCount = snapshot.stateCounts.resumable
        historicalCount = snapshot.stateCounts.historical
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = jobs.filter { job in
            scope.matches(job) && (search.isEmpty || [job.projectTitle ?? "", job.workTitle ?? job.title, job.versionLabel ?? "", job.title, job.source.rawValue].contains { $0.localizedCaseInsensitiveContains(search) })
        }
        displayedCount = filtered.count
        let workByJob = snapshot.works.reduce(into: [String: RenderCatalogWork]()) { lookup, work in
            for job in work.jobs { lookup[job.id] = work }
        }
        var order: [String] = []
        var grouped: [String: [RenderDashboardJob]] = [:]
        var titles: [String: String] = [:]
        for job in filtered {
            let work = workByJob[job.id]
            let workID = work?.id ?? job.id
            let key = "\(job.projectID.utf8.count):\(job.projectID)\(workID)"
            if grouped[key] == nil {
                order.append(key)
                let project = snapshot.projects.first { $0.id == job.projectID }?.title ?? job.projectTitle ?? "Projet non identifié"
                titles[key] = project + " · " + (work?.title ?? job.workTitle ?? job.title)
            }
            grouped[key, default: []].append(job)
        }
        sections = order.map { CatalogSection(id: $0, title: titles[$0] ?? "Travail non identifié", jobs: grouped[$0] ?? []) }

    }
}

#if !AUTORENDER_UI_HARNESS
@main
enum RenduBarMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = RenduAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
#endif
