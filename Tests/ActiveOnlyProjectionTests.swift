import Foundation
@main enum ActiveOnlyProjectionTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func job(_ id: String, active: Bool = false, done: Bool = false, unknown: Bool = false, archived: Bool = false, qualified: Bool = true) -> RenderDashboardJob {
        var health = SourceHealth(); health.online = true; health.observedAt = Date()
        var payload = MacJob(id: id, titre: "SIMULATED", sous: nil, total: 241, faites: done ? 241 : 57,
                             en_cours: [], latest: [], times: [], proc: active ? MacProcess(cpu: nil, ram_mo: nil, duree: nil) : nil)
        payload.processReported = !unknown
        var value = RenderDashboard.mac(payload, health: health, projectID: id, workType: .video)
        if active && qualified { value.taskQualification = .nativeRenderCommand }
        value.workID = "work:" + id; value.workTitle = "SIMULATED"; value.projectTitle = "SIMULATED"
        if archived { value.archivedAt = Date(timeIntervalSince1970: 1700000000) }
        return value
    }
    static func snapshot(_ jobs: [RenderDashboardJob], revision: UInt64) -> RenderCatalogSnapshot {
        RenderCatalogSnapshot(revision: revision, generatedAt: Date(), jobs: jobs, projects: RenderDashboard.projects(jobs),
            works: jobs.map { RenderCatalogWork(id: $0.workID!, projectID: $0.projectID, title: "SIMULATED", workType: .video, jobs: [$0]) },
            knownJobCount: jobs.count, observedJobCount: jobs.count, stateCounts: RenderCatalogStateCounts(), persistenceIssue: nil)
    }
    @MainActor static func main() {
        let suite = CommandLine.arguments[1]; precondition(suite.hasPrefix("fr.robtech.autorender.active-only-test."))
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); defaults.synchronize() }
        let a = job("a", active: true), b = job("b", active: true), done = job("done", done: true), archive = job("archive", done: true, archived: true), unknown = job("unknown", unknown: true), stopped = job("stopped")
        var stale = a; stale.id = "stale"; stale.isFresh = false
        var historical = b; historical.id = "historical"; historical.retainedHistorical = true
        let unqualifiedPID = job("unqualified-pid", active: true, qualified: false)
        let jobs = [unknown, unqualifiedPID, archive, stale, done, stopped, historical, a, b]
        let dates = jobs.filter(\.isArchived).map { $0.archivedAt! }
        let store = CatalogPresentationStore(), selection = CatalogSelectionController(defaults: defaults)
        check(!CatalogScope.direct.matches(unqualifiedPID), "bare legacy PID treated as qualified production")
        check(CatalogScope.mainSections == [.direct, .finished, .archived], "primary sections mix candidates")
        store.rebuild(snapshot(jobs, revision: 1), query: "", scope: .direct)
        check(store.visibleJobIDs == Set([a.id, b.id]), "active projection contains stale, terminal, unknown or stopped")
        selection.choose(unknown, workID: unknown.workID!); selection.reconcileActive(store)
        check(store.visibleJobIDs.contains(selection.jobID), "missing/inactive remembered selection blocks an available active")
        check(store.sections.flatMap(\.jobs).count == 2, "active cards/count mismatch")
        check(!CatalogScope.direct.matches(stale) && !CatalogScope.direct.matches(historical), "old active observation displayed as current")
        // UI consumes qualified activity from the producer; it does not infer GPU use or require a new output per tick.
        let stable = [a, b]; store.rebuild(snapshot(stable, revision: 2), query: "", scope: .direct)
        check(store.visibleJobIDs == Set([a.id, b.id]) && a.rawCount == 57 && a.gpu == nil, "stable between-frame output hidden or GPU fabricated")
        selection.openInDashboard(a, workID: a.workID!); selection.apply(selection.dashboardNavigation!)
        let completedA = job("a", done: true)
        store.rebuild(snapshot([completedA, b, unknown], revision: 3), query: "", scope: .direct); selection.reconcileActive(store)
        check(store.visibleJobIDs == Set([b.id]) && selection.jobID == b.id, "completed active remains selected or blocks next active")
        check(selection.explicitDashboardTarget == nil, "expired explicit active target retained")
        store.rebuild(snapshot([completedA, unknown, stopped], revision: 4), query: "", scope: .direct); selection.reconcileActive(store)
        check(store.visibleJobIDs.isEmpty && store.visibleProjects.isEmpty && store.visibleJobsByWork.isEmpty, "empty active screen retains previous cards")
        store.rebuild(snapshot(jobs, revision: 5), query: "", scope: .finished)
        check(store.visibleJobIDs == Set([done.id]), "finished section mixes archives or nonterminal jobs")
        selection.openInDashboard(done, workID: done.workID!); let finishRequest = selection.dashboardNavigation!
        check(finishRequest.scope == .finished && finishRequest.jobID == done.id, "finished route wrong")
        selection.apply(finishRequest); selection.reconcile(store)
        check(selection.jobID == done.id, "finished exact target replaced")
        selection.openInDashboard(archive, workID: archive.workID!); let archiveRequest = selection.dashboardNavigation!
        check(archiveRequest.scope == .archived && archiveRequest.jobID == archive.id, "archive route wrong")
        store.rebuild(snapshot(jobs, revision: 6), query: "", scope: .archived); selection.apply(archiveRequest); selection.reconcile(store)
        check(selection.jobID == archive.id && store.visibleJobIDs == Set([archive.id]), "archive exact target replaced")
        let masked = Set([done.id, archive.id])
        check(!CompactVisibility.isVisible(done, scope: .finished, hiddenIDs: masked) && CompactVisibility.isVisible(done, scope: .finished, hiddenIDs: []), "finished masking/restoration fails")
        check(!CompactVisibility.isVisible(archive, scope: .archived, hiddenIDs: masked) && CompactVisibility.isVisible(archive, scope: .archived, hiddenIDs: []), "archive masking/restoration fails")
        check(CompactVisibility.toggledHiddenIDs(for: a, hiddenIDs: []) == nil, "qualified active can be hidden")
        selection.openInDashboard(done, workID: done.workID!); let restoreRoute = selection.dashboardNavigation!
        check(restoreRoute.scope == .finished && restoreRoute.jobID == done.id, "mask lifecycle targets wrong section/job")
        var lifecycleIDs = CompactVisibility.toggledHiddenIDs(for: done, hiddenIDs: [])!
        check(lifecycleIDs.contains(done.id) && !CompactVisibility.isVisible(done, scope: .finished, hiddenIDs: lifecycleIDs), "toggle does not remove terminal card")
        lifecycleIDs.removeAll()
        check(CompactVisibility.isVisible(done, scope: .finished, hiddenIDs: lifecycleIDs), "global restore does not recover terminal card")
        let archiveHidden = CompactVisibility.toggledHiddenIDs(for: archive, hiddenIDs: [])!
        let archiveRestored = CompactVisibility.toggledHiddenIDs(for: archive, hiddenIDs: archiveHidden)!
        check(!CompactVisibility.isVisible(archive, scope: .archived, hiddenIDs: archiveHidden) && CompactVisibility.isVisible(archive, scope: .archived, hiddenIDs: archiveRestored), "archive toggle/reverse route fails")
        let previous = selection.dashboardNavigation?.id; selection.openInDashboard(unknown, workID: unknown.workID!)
        check(selection.dashboardNavigation?.id == previous && CatalogScope.dashboardScope(for: unknown) == nil, "unknown candidate navigates into main screen")
        check(NativeSourcesPresentation.candidates(jobs).contains(where: { $0.id == unknown.id }), "unknown candidate absent from Sources")
        check(jobs.filter(\.isArchived).map { $0.archivedAt! } == dates && jobs.count == 9, "projection deleted files/archive state")
        print("ActiveOnlyProjectionTests: \(checks) checks PASS; SIMULATED producer activity only; no native/render/GPU proof")
    }
}
