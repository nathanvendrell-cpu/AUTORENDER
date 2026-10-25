#if AUTORENDER_UI_HARNESS
import AppKit
import SwiftUI

@MainActor
final class UIHarness50Delegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var model: MonitorModel?
    private var root: URL?
    private var suiteName: String?
    private var defaults: UserDefaults?
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private let token = UUID().uuidString
    private var fixtureCount: Int {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--job-count"), args.indices.contains(index + 1),
           let value = Int(args[index + 1]), [2, 3, 50].contains(value) { return value }
        return 50
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = RenduLogo.app
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AUTORENDER-UI-HARNESS50-" + token, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            root = directory
            UIHarness50Metrics.root = directory
            try Data(token.utf8).write(to: directory.appendingPathComponent("task-owned.marker"))
            let suite = "fr.robtech.autorender.ui-harness50." + token
            guard let isolatedDefaults = UserDefaults(suiteName: suite) else { throw CocoaError(.fileWriteUnknown) }
            suiteName = suite; defaults = isolatedDefaults
            let snapshot = try fixture50(root: directory)
            let fixtureModel = MonitorModel.fixture(snapshot: snapshot, storageRoot: directory)
            model = fixtureModel
            let overview = window("AUTORENDER — \(fixtureCount) JOBS SIMULÉS · dashboard", size: NSSize(width: 1240, height: 850))
            let compact = window("AUTORENDER — \(fixtureCount) JOBS SIMULÉS · suivi compact", size: NSSize(width: 520, height: 680))
            overview.contentViewController = RenderHostingController(rootView:
                VStack(spacing: 0) {
                    fixtureBanner
                    ContentView(model: fixtureModel, openCompact: { compact.makeKeyAndOrderFront(nil) }, selectionDefaults: isolatedDefaults)
                }.defaultAppStorage(isolatedDefaults))
            compact.contentViewController = RenderHostingController(rootView:
                VStack(spacing: 0) {
                    fixtureBanner
                    MenuSummaryView(model: fixtureModel, detached: true,
                        openOverview: { overview.makeKeyAndOrderFront(nil) },
                        detach: { compact.makeKeyAndOrderFront(nil) }, selectionDefaults: isolatedDefaults)
                }.defaultAppStorage(isolatedDefaults))
            configureGeometry(overview, initial: NSSize(width: 1240, height: 850), minimum: NSSize(width: 920, height: 680))
            configureGeometry(compact, initial: NSSize(width: 520, height: 680), minimum: NSSize(width: 480, height: 370))
            windows = [overview, compact]
            let appMenu = NSMenu(title: "Test UI — SIMULÉ")
            appMenu.addItem(NSMenuItem(title: "Quitter le harness simulé", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            let menu = NSMenu(); let menuRoot = NSMenuItem(); menuRoot.submenu = appMenu; menu.addItem(menuRoot); NSApp.mainMenu = menu
            overview.center(); overview.makeKeyAndOrderFront(nil)
            compact.setFrameOrigin(NSPoint(x: overview.frame.minX + 40, y: overview.frame.minY + 40))
            compact.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let record: [String: Any] = ["label": "SIMULÉ — \(fixtureCount) jobs synthétiques, aucun moteur lancé", "pid": ProcessInfo.processInfo.processIdentifier,
                "known_jobs": snapshot.jobs.count, "works": snapshot.works.count, "storage_root": directory.path, "suite": suite,
                "views": ["ContentView", "MenuSummaryView"], "collection": false, "network": false,
                "previews": 0, "client_data": false, "production_identity": false]
            try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("runtime.json"))
            print("UI_HARNESS50_SIMULATED_ROOT=" + directory.path)
        } catch {
            print("UI_HARNESS50_FAILED=" + String(describing: error))
            NSApp.terminate(nil)
        }
    }
    private var fixtureBanner: some View {
        Text("TEST UI · \(fixtureCount) JOBS SIMULÉS · AUCUN RENDU / RÉSEAU")
            .font(.system(size: 11, weight: .bold)).padding(8).frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.18))
    }
    private func window(_ title: String, size: NSSize) -> NSWindow {
        let result = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        result.isOpaque = false
        result.backgroundColor = .clear
        result.appearance = RenderStyle.appearance
        result.title = title; result.isReleasedWhenClosed = false
        return result
    }
    private func configureGeometry(_ window: NSWindow, initial: NSSize, minimum: NSSize) {
        // Attach SwiftUI content first: its initial hosting size must not replace
        // the native test window's intended frame with a1x32 frame.
        guard let placement = RenderWindowGeometry.resolve(saved: nil,
            screens: NSScreen.screens.map(\.visibleFrame),
            fallbackScreen: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
            initial: initial, minimum: minimum) else { return }
        window.minSize = placement.minimum
        window.isMovableByWindowBackground = true
        window.setFrame(placement.frame, display: false)
    }

    private func fixture50(root: URL) throws -> RenderCatalogSnapshot {
        let now = Date()
        let format = ISO8601DateFormatter()
        let times = [180.0, 120, 60].map { format.string(from: now.addingTimeInterval(-$0)) }
        var health = SourceHealth(); health.online = true; health.observedAt = now
        var jobs: [RenderDashboardJob] = []
        for number in 1...fixtureCount {
            let video = number <= 19
            let audio = number >= 20 && number <= 34
            let type: RenderWorkType = video ? .video : (audio ? .audio : (number <= 42 ? .image : .other))
            let workIndex = number <= 10 ? 1 : (video ? number - 9 : (audio ? number - 19 : number - 34))
            let version = number <= 10 ? number : 1
            let group = video ? "video" : (audio ? "audio" : "other")
            let project = "fixture-project:" + group
            let workName = (video ? "Vidéo simulée " : (audio ? "Son simulé " : "Travail simulé ")) + String(format: "%02d", workIndex)
            let active = video && number % 5 == 1
            let count = number % 5 == 0 ? 240 : (number * 7) % 240
            let process = active ? MacProcess(cpu: nil, ram_mo: nil, duree: nil) : nil
            let raw = MacJob(id: "fixture-job:\(number)", titre: "SIMULÉ — " + workName + " — Version " + String(version),
                sous: "Fixture UI neutre : aucune scène ni donnée client", total: 240, faites: count, en_cours: [], latest: [], times: times,
                proc: process, workType: type, projectID: project)
            var view = RenderDashboard.mac(raw, health: health, projectID: project, workType: type)
            if !video {
                view = RenderDashboardJob(id: view.id, title: view.title, projectID: project, source: .macFolder, workType: type,
                    rawCount: 1, postCount: nil, rawProgress: nil, postProgress: nil, totalProvenance: nil, activity: .unknown,
                    isFresh: true, observedAt: now, lastActivity: now, historicalMedianSeconds: nil, sampledOutputsLastHour: nil,
                    eta: nil, historicalETA: nil, process: nil, gpu: nil, gpuRaw: nil, plans: [], tasks: [],
                    stageDescription: "Métadonnée synthétique ; fichier texte de test, aucun audio/image réellement produit", previewEntries: [])
            }
            view.projectTitle = video ? "Projet vidéo simulé" : (audio ? "Projet audio simulé" : "Autres travaux simulés")
            view.workID = "fixture-work:" + group + ":" + String(workIndex); view.workTitle = workName
            view.versionID = "fixture-version:\(number)"; view.versionLabel = "Version simulée \(version) · job \(number)"
            view.contextProvenance = "Fixture UI synthétique"; view.previewEntries = []
            if number % 5 == 4 { view.retainedHistorical = true; view.isFresh = false; view.eta = nil }
            view.estimatedRemainingSeconds = active ? Double(240 - count) * 60 : nil
            let folder = root.appendingPathComponent("Job-\(number)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let file = folder.appendingPathComponent("fixture-output.txt")
            try Data("SIMULATED UI file-link fixture; not a rendered export.\n".utf8).write(to: file)
            view.openTargets = [RenderFolderTarget(id: "fixture-folder:\(number)", title: "Dossier simulé du job \(number)",
                location: folder, remoteDisplay: nil, isVerified: true, verifiedAt: now)]
            view.revealURL = file
            view.latestOutput = RenderEntry(id: "fixture-output:\(number)", source: .macFolder, job: view.title,
                filename: file.lastPathComponent, modified: now, state: .stable, path: file.path, previewURL: nil)
            jobs.append(view)
        }
        jobs.sort { a, b in
            let aa = a.isFresh && a.activity == .running; let bb = b.isFresh && b.activity == .running
            return aa != bb ? aa : a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
        let projects = RenderDashboard.projects(jobs)
        let works = Dictionary(grouping: jobs, by: { $0.workID ?? $0.id }).map { id, versions in
            RenderCatalogWork(id: id, projectID: versions[0].projectID, title: versions[0].workTitle ?? "Travail simulé", workType: versions[0].workType, jobs: versions)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        var counts = RenderCatalogStateCounts()
        for job in jobs {
            if job.retainedHistorical { counts.historical += 1; continue }
            switch job.activity {
            case .running: counts.running += 1
            case .resumeRequired: counts.resumable += 1
            case .stopped: counts.stopped += 1
            case .countsReached: counts.counted += 1
            case .unknown: counts.unknown += 1
            }
        }
        return RenderCatalogSnapshot(revision: 1, generatedAt: now, jobs: jobs, projects: projects, works: works,
            knownJobCount: jobs.count, observedJobCount: jobs.filter { !$0.retainedHistorical }.count, stateCounts: counts, persistenceIssue: nil)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownFinished { return .terminateNow }
        if shutdownTask != nil { return .terminateLater }
        guard let model else { return .terminateNow }
        model.stop()
        shutdownTask = Task { @MainActor in
            await model.waitForShutdown()
            shutdownFinished = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
        UIHarness50Metrics.root = nil
        if let root, let reports = Bundle.main.object(forInfoDictionaryKey: "UIHarnessReportDirectory") as? String {
            do {
                let target = URL(fileURLWithPath: reports, isDirectory: true)
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let reportFile = target.appendingPathComponent("AUTORENDER-MACOS-UI-HARNESS50-" + token + ".json")
                let raw = try? Data(contentsOf: root.appendingPathComponent("projection-metrics.jsonl"))
                let lines = raw.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\n") ?? []
                let metrics: [[String: Any]] = lines.compactMap { line in
                    guard let data = String(line).data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                let report: [String: Any] = ["label": "SIMULÉ_UI_ONLY", "real_renders_started": 0,
                    "known_synthetic_jobs": fixtureCount, "projection_metrics": metrics, "native_acceptance": false,
                    "scope": "Same final UI views; fixture process; projection timing is not frame time or production performance",
                    "mixed_50_case": "10 video works including one with10versions,15audio works,16other records; no audio/video files rendered",
                    "static_launch_counts": [2,3,50], "same_instance_incremental_arrival": "NOT_TESTED_NO_PUBLIC_FIXTURE_UPDATE_API"]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportFile)
            } catch { print("UI_HARNESS50_REPORT_EXPORT_FAILED=" + String(describing: error)) }
        }
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        if let root, root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL,
           (try? String(contentsOf: root.appendingPathComponent("task-owned.marker"), encoding: .utf8)) == token {
            try? FileManager.default.removeItem(at: root)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
enum UIHarness50Metrics {
    static var root: URL?
    static func recordProjection(known: Int, displayed: Int, seconds: Double) {
        guard let root else { return }
        let file = root.appendingPathComponent("projection-metrics.jsonl")
        let record: [String: Any] = ["label": "SIMULÉ_UI_ONLY", "scope": "mini_snapshot_projection_not_frame_time",
            "known_jobs": known, "displayed_jobs": displayed, "milliseconds": seconds * 1000,
            "at_uptime": ProcessInfo.processInfo.systemUptime]
        guard let json = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: json); try handle.write(contentsOf: Data([10])) } catch { }
    }
}

@main
enum UIHarness50Main {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = UIHarness50Delegate()
        application.delegate = delegate
        application.run()
    }
}
#endif
