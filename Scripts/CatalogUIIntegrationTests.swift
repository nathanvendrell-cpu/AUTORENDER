import Foundation

@main enum CatalogUIIntegrationTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(value(), message)
    }
    @MainActor static func settled(_ store: CatalogHierarchyStore) async {
        let limit = ProcessInfo.processInfo.systemUptime + 15
        while store.rebuilding, ProcessInfo.processInfo.systemUptime < limit { try? await Task.sleep(for: .milliseconds(5)) }
        check(!store.rebuilding, "Projection worker did not settle")
    }
    @MainActor static func main() async throws {
        let now = Date()
        var health = SourceHealth(); health.online = true; health.observedAt = now
        var active = RenderDashboard.mac(MacJob(id: "active", titre: "Active", sous: nil, total: 10, faites: 3,
            en_cours: [], latest: [], times: [], proc: MacProcess(cpu: "0", ram_mo: 1, duree: "00:01")), health: health, projectID: "project-A", workType: .image)
        active.taskQualification = .nativeRenderCommand; active.workID = "work"; active.projectTitle = "A"
        active.subprojectID = "sub"; active.subprojectTitle = "Sub"; active.sceneID = "scene"; active.sceneTitle = "Scene"
        active.libraryVersion = "v050"; active.versionLabel = "Image"; active.contextAssignment = .assigned
        var done = RenderDashboard.mac(MacJob(id: "done", titre: "Done", sous: nil, total: 10, faites: 10,
            en_cours: [], latest: [], times: [], proc: nil), health: health, projectID: "project-B", workType: .video)
        done.workID = "work"; done.projectTitle = "B"; done.contextAssignment = .assigned
        let fresh = CatalogProjectionSnapshot.active([active, done], revision: 1, now: now)
        check(fresh.jobs.map(\.id) == [active.id], "Compact accepts only actual active records")
        check(fresh.projects.count == 1 && fresh.works.count == 1, "Active projection does not import historical groups")
        check(CatalogProjectionSnapshot.active([active], revision: 2, now: now.addingTimeInterval(31)).jobs.isEmpty, "Expired active excluded at existing cycle")
        check(CatalogProjectionSnapshot.active([active], revision: 3, now: now.addingTimeInterval(-1)).jobs.isEmpty, "Future observation excluded")
        let past = CatalogProjectionSnapshot.history(fresh, revision: 77)
        check(past.revision == 77 && past.historyRevision == 77, "Historical key distinct from live catalogue revision")
        let record = CatalogHierarchyRecord(job: active), context = CatalogHierarchyContext(job: active)
        check(record.id == active.id && record.versionLabel?.contains("v050") == true && context.sceneID == "scene", "UI maps canonical context without rewriting identities")
        let store = CatalogHierarchyStore()
        let big = (0..<50_000).map { number -> CatalogHierarchyRecord in
            var copy = record; copy.id = String(number); return copy
        }
        store.rebuild(records: big, contexts: [:], key: "old-generation", revealJobID: nil)
        store.rebuild(records: [record], contexts: [record.id: context], key: "new-generation", revealJobID: record.id)
        await settled(store)
        check(store.index.indexedJobs == 1 && store.index.jobsByID[record.id] != nil, "Cancelled old worker cannot overwrite new projection")
        let accepted = store.generation
        store.rebuild(records: big, contexts: [:], key: "new-generation", revealJobID: nil)
        check(!store.rebuilding && store.generation == accepted && store.index.indexedJobs == 1, "Same historical revision ignores activity-only changes")
        store.cancel(); store.rebuild(records: [record], contexts: [record.id: context], key: "new-generation", revealJobID: record.id)
        await settled(store)
        check(store.index.indexedJobs == 1, "Reopening after cancel rebuilds instead of getting stuck")
        store.cancel()
        let fixtureParent = ProcessInfo.processInfo.environment["AUTORENDER_UI_FIXTURE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let temp = fixtureParent.appendingPathComponent("autoren-ui-settings-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var config = AppConfig()
        for number in 0..<4 { config.jobArchives["mac:qa:archived-\(number)"] = Date(timeIntervalSince1970: 1_700_000_000 + Double(number)) }
        try JSONEncoder().encode(config).write(to: temp.appendingPathComponent("config.json"))
        let model = MonitorModel(storageRoot: temp, initialSnapshot: .empty, collectionEnabled: false)
        check(model.config.librarySettings == nil, "Setup is unchosen until explicit save")
        check(model.config.archivePayloadError == nil && model.config.jobArchives == config.jobArchives, "All four supported archive IDs and dates loaded before mode change")
        check(!model.setLibraryMode(.managedLibrary, rootPath: temp.appendingPathComponent("Library").path, manageFutureJobs: false), "Managed mode requires explicit future activation")
        check(model.setLibraryMode(.managedLibrary, rootPath: temp.appendingPathComponent("Library").path, manageFutureJobs: true), "Setup uses real mode API")
        check(model.librarySettings.mode == .managedLibrary && model.librarySettings.activatedAt != nil, "Actual configured state read back")
        check(model.libraryError == nil, "Successful setup clears earlier activation error")
        check(model.config.jobArchives == config.jobArchives, "Mode setup preserves all four archive IDs and dates")
        check(model.setInMemoryExportEnabled(true) && model.librarySettings.exportInMemory == true, "In-memory export has separate opt-in API")
        check(model.setLibraryMode(.catalogueOnly), "Catalogue-only mode remains available")
        check(model.config.jobArchives == config.jobArchives, "Changing modes never clears archives")
        model.stop(); await model.waitForShutdown()
        var windowRows: [String] = []
        let diagnostic = WindowFrameDiagnostic(requested: true, canonical: true, startedAt: 100, write: { windowRows.append($0) })
        diagnostic.record(kind: .compact, action: .show, frame: CGRect(x: -500, y: 0, width: 520, height: 640), at: 101)
        diagnostic.record(kind: .compact, action: .close, frame: CGRect(x: -500, y: 0, width: 520, height: 640), at: 102)
        diagnostic.record(kind: .compact, action: .show, frame: CGRect(x: -500, y: 0, width: 520, height: 640), at: 103)
        check(windowRows.count == 3, "Close/reopen frame events retained even for identical frame")
        for _ in 0..<30 { diagnostic.record(kind: .dashboard, action: .resize, frame: CGRect(x: 0, y: 0, width: 920, height: 650), at: 104) }
        check(windowRows.count == 24, "Frame diagnostic bounded")
        let ruleContext = RenderJobContext(projectID: "project-A", projectTitle: "A", sceneID: "scene", sceneTitle: "Scene", workID: nil, versionID: nil, workTitle: nil, versionLabel: nil)
        let rule = RenderContextRule(id: "rule", rootPath: "D:/shots", namespace: "shadow:one", context: ruleContext, canonicalFileBase: "test")
        let one = RenderSourceContext(filePath: "D:/shots/test_v001.blend", sceneName: "Scene", namespace: "shadow:one", origin: .nativeBlender)
        let other = RenderSourceContext(filePath: "D:/shots/test_v001.blend", sceneName: "Scene", namespace: "shadow:two", origin: .nativeBlender)
        check(rule.matches(one) && !rule.matches(other), "New UI rule cannot classify another PC at identical path")
        print("PASS \(checks) actual-model setup/projection/cancellation/context policy checks; isolated storage, synthetic windows, no native UI or media mutation")
    }
}
