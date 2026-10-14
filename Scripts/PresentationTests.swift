import Foundation

@main enum PresentationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1; precondition(condition(), message)
    }
    static func job(_ id: String, project: String, work: String, active: Bool = false) -> RenderDashboardJob {
        var health = SourceHealth(); health.online = true; health.observedAt = Date()
        var job = RenderDashboard.mac(MacJob(id: id, titre: id, sous: nil, total: 10, faites: active ? 3 : 10, en_cours: [], latest: [], times: [], proc: active ? MacProcess(cpu: "1", ram_mo: 1, duree: "00:01") : nil), health: health, projectID: project, workType: .video)
        // Explicit simulated qualification, not evidence from legacy process counters.
        job.taskQualification = active ? .nativeRenderCommand : nil
        job.workID = work; job.workTitle = work; job.versionLabel = id
        return job
    }
    static func snapshot(_ jobs: [RenderDashboardJob], revision: UInt64) -> RenderCatalogSnapshot {
        let grouped = Dictionary(grouping: jobs) { CatalogPresentationStore.workKey(projectID: $0.projectID, workID: $0.workID!) }
        let works = grouped.values.map { values in RenderCatalogWork(id: values[0].workID!, projectID: values[0].projectID, title: values[0].workTitle!, workType: .video, jobs: values) }.sorted { $0.projectID + $0.id < $1.projectID + $1.id }
        return RenderCatalogSnapshot(revision: revision, generatedAt: Date(), jobs: jobs, projects: RenderDashboard.projects(jobs), works: works, knownJobCount: jobs.count, observedJobCount: jobs.count, stateCounts: RenderCatalogStateCounts(), persistenceIssue: nil)
    }
    @MainActor static func main() async {
        var jobs = (1...50).map { job("version-\($0)", project: $0 <= 25 ? "A" : "B", work: "shared-work", active: $0 % 2 == 0) }
        jobs[0].archivedAt = Date()
        let store = CatalogPresentationStore()
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .all)
        check(store.sections.flatMap(\.jobs).count == 50, "Known renders lost")
        check(store.work(projectID: "A", workID: "shared-work")?.jobs.count == 25, "Project/work collision A")
        check(store.work(projectID: "B", workID: "shared-work")?.jobs.count == 25, "Project/work collision B")
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .archived)
        check(store.visibleJobIDs == [jobs[0].id], "Archive visibility")
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .direct)
        check(store.visibleJobIDs.count == 25, "Fresh running scope")
        store.rebuild(snapshot(jobs, revision: 1), query: "version-50", scope: .all)
        check(store.visibleJobIDs == [jobs[49].id] && store.visibleProjects.count == 1, "Search leakage")
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .all, type: .audio)
        check(store.visibleJobIDs.isEmpty, "Declared media filter")
        let suite = "fr.robtech.autorender.selection-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .all)
        let selection = CatalogSelectionController(defaults: defaults)
        selection.choose(store.work(projectID: "A", workID: "shared-work")!, presentation: store)
        selection.jobID = jobs[3].id; selection.remember(store)
        selection.choose(store.work(projectID: "B", workID: "shared-work")!, presentation: store)
        selection.jobID = jobs[49].id; selection.remember(store)
        selection.choose(store.work(projectID: "A", workID: "shared-work")!, presentation: store)
        check(selection.jobID == jobs[3].id, "Per-work remembered selection leaked across projects")
        let relaunched = CatalogSelectionController(defaults: defaults)
        check(relaunched.projectID == "A" && relaunched.jobID == jobs[3].id, "Selection did not persist")
        relaunched.choose(store.work(projectID: "B", workID: "shared-work")!, presentation: store)
        check(relaunched.jobID == jobs[49].id, "Per-work memory did not persist")
        relaunched.projectID = "missing"; relaunched.workID = "missing-work"; relaunched.jobID = "missing-job"
        relaunched.reconcile(store)
        check(relaunched.projectID == "missing" && relaunched.jobID == "missing-job", "Unavailable selection discarded")
        let a = job("old", project: "A", work: "job:old"), b = job("new", project: "A", work: "job:new")
        store.rebuild(snapshot([a,b], revision: 2), query: "", scope: .all)
        check(store.sections.count == 1 && store.sections[0].jobs.count == 2, "Isolated works must display directly under project without mutating identity")
        check(store.workByJob[a.id]?.id == "job:old", "Presentation grouping changed business identity")
        let preview = PreviewPresentationStore()
        let date = Date(timeIntervalSince1970: 100)
        func entry(_ id: String, offset: Double, state: RenderState = .pending, name: String? = nil) -> RenderEntry {
            RenderEntry(id: id, source: .macFolder, job: "simulated", filename: name ?? id + ".png", modified: date.addingTimeInterval(offset), state: state, path: "/simulated/" + id + ".png", previewURL: nil)
        }
        var previewJob = a
        previewJob.previewEntries = [entry("one", offset: 1), entry("two", offset: 2), entry("three", offset: 3)]
        preview.rebuild(previewJob)
        check(preview.entries.map(\.id) == ["three", "two"], "Visible previews must stay bounded and latest-first")
        let pendingIdentity = preview.requestID
        previewJob.previewEntries[2].state = .stable
        preview.rebuild(previewJob)
        check(preview.requestID != pendingIdentity && preview.entries[0].state == .stable, "Pending to stable must refresh UI request with unchanged ID/date")
        let stableIdentity = preview.requestID
        preview.rebuild(previewJob)
        check(preview.requestID == stableIdentity, "Unchanged preview data should not change request identity")
        previewJob.previewEntries[2] = entry("three", offset: 3, state: .stable, name: "updated-label.png")
        preview.rebuild(previewJob)
        check(preview.requestID == stableIdentity && preview.entries[0].filename == "updated-label.png", "Metadata must refresh independently of unchanged cache identity")
        previewJob.id = "different-selected-job"
        preview.rebuild(previewJob)
        check(preview.requestID != stableIdentity, "Selected job identity must isolate requests")
        previewJob.previewEntries = []
        preview.rebuild(previewJob)
        check(preview.entries.isEmpty, "Empty selected preview scope must clear old entries")
        let history = HistoryController()
        let gate = HistoryGate()
        let loader: HistoryController.Loader = { _, _, _ in await gate.page() }
        history.load(job: a, append: false, loader: loader)
        await waitFor(gate, count: 1)
        history.load(job: b, append: false, loader: loader)
        await waitFor(gate, count: 2)
        gate.finish(0, coverage: "obsolete", cursor: nil, revision: 1)
        for _ in 0..<10 { await Task.yield() }
        check(history.loading && history.coverage != "obsolete", "Old job response overwrote current request")
        gate.finish(1, coverage: "new", cursor: "next", revision: 2)
        for _ in 0..<10 { await Task.yield() }
        check(!history.loading && history.coverage == "new" && history.cursor == "next", "Current page not applied")
        history.load(job: b, append: true, loader: loader)
        await waitFor(gate, count: 3)
        gate.finish(2, coverage: "different revision", cursor: "bad", revision: 3)
        for _ in 0..<10 { await Task.yield() }
        check(!history.loading && history.cursor == nil && history.coverage.contains("Catalogue modifié"), "Mixed revision pagination")
        history.load(job: a, append: false, loader: loader)
        await waitFor(gate, count: 4)
        history.cancel()
        check(!history.loading, "Dismiss left loading true")
        gate.finish(3, coverage: "late dismissed", cursor: "bad", revision: 4)
        for _ in 0..<10 { await Task.yield() }
        check(!history.loading && history.coverage != "late dismissed", "Dismissed response changed state")
        print("PASS \(checks) presentation and history checks; simulated metadata only")
    }
    @MainActor static func waitFor(_ gate: HistoryGate, count: Int) async {
        for _ in 0..<10000 { if gate.pending.count >= count { return }; await Task.yield() }
        preconditionFailure("Loader did not start")
    }
}

@MainActor final class HistoryGate {
    var pending: [CheckedContinuation<RenderHistoryPage, Never>] = []
    func page() async -> RenderHistoryPage { await withCheckedContinuation { pending.append($0) } }
    func finish(_ index: Int, coverage: String, cursor: String?, revision: UInt64) {
        pending[index].resume(returning: RenderHistoryPage(entries: [], nextCursor: cursor, totalKnown: 0, coverage: coverage, snapshotRevision: revision))
    }
}
