import Foundation

enum CatalogProjectionSnapshot {
    static func active(_ jobs: [RenderDashboardJob], revision: UInt64, now: Date = Date()) -> RenderCatalogSnapshot {
        let jobs = jobs.filter { job in
            guard job.isDetectedActiveRender, let observed = job.observedAt else { return false }
            let age = now.timeIntervalSince(observed)
            return age.isFinite && age >= 0 && age <= (job.source.isShadow ? 120 : 30)
        }
        let grouped = Dictionary(grouping: jobs) { CatalogPresentationStore.workKey(projectID: $0.projectID, workID: $0.workID ?? "job:" + $0.id) }
        let works = grouped.values.compactMap { values -> RenderCatalogWork? in
            guard let first = values.first else { return nil }
            return RenderCatalogWork(id: first.workID ?? "job:" + first.id, projectID: first.projectID,
                title: first.workTitle ?? first.sceneTitle ?? first.title, workType: first.workType, jobs: values)
        }
        var counts = RenderCatalogStateCounts(); counts.running = jobs.count
        return RenderCatalogSnapshot(revision: revision, generatedAt: Date(), jobs: jobs,
            projects: RenderDashboard.projects(jobs), works: works, knownJobCount: jobs.count,
            observedJobCount: jobs.count, stateCounts: counts, persistenceIssue: nil)
    }
    static func history(_ snapshot: RenderCatalogSnapshot, revision: UInt64) -> RenderCatalogSnapshot {
        RenderCatalogSnapshot(revision: revision, generatedAt: snapshot.generatedAt, jobs: snapshot.jobs,
            projects: snapshot.projects, works: snapshot.works, knownJobCount: snapshot.knownJobCount,
            observedJobCount: snapshot.observedJobCount, stateCounts: snapshot.stateCounts,
            persistenceIssue: snapshot.persistenceIssue, historyRevision: revision)
    }
    static let request = Notification.Name("AUTORENDER.OverviewSectionRequest")
}
