import Foundation
import Combine

@MainActor
final class CatalogPresentationStore: ObservableObject {
    @Published private(set) var sections: [CatalogSection] = []
    private(set) var projects: [RenderDashboardProject] = []
    private(set) var projectByID: [String: RenderDashboardProject] = [:]
    private(set) var workByKey: [String: RenderCatalogWork] = [:]
    private(set) var workByJob: [String: RenderCatalogWork] = [:]
    private(set) var visibleProjects: [RenderDashboardProject] = []
    private(set) var visibleWorksByProject: [String: [RenderCatalogWork]] = [:]
    private(set) var visibleJobsByWork: [String: [RenderDashboardJob]] = [:]
    private(set) var visibleJobIDs: Set<String> = []
    private var signature: Signature?

    private struct Signature: Equatable {
        let revision: UInt64
        let query: String
        let scope: CatalogScope
        let source: Filter
        let type: WorkFilter
    }
    nonisolated static func workKey(projectID: String, workID: String) -> String {
        "\(projectID.utf8.count):\(projectID)\(workID)"
    }
    func work(projectID: String, workID: String) -> RenderCatalogWork? {
        workByKey[Self.workKey(projectID: projectID, workID: workID)]
    }
    func visibleActiveCount(projectID: String, workID: String) -> Int {
        (visibleJobsByWork[Self.workKey(projectID: projectID, workID: workID)] ?? []).filter {
            CatalogScope.direct.matches($0)
        }.count
    }
    private static func priority(_ job: RenderDashboardJob) -> Int {
        if job.isArchived { return 5 }
        guard job.isFresh, !job.retainedHistorical else { return 4 }
        switch job.activity {
        case .running: return 0
        case .resumeRequired, .stopped: return 1
        case .unknown: return 2
        case .countsReached: return 3
        }
    }
    private static func precedes(_ lhs: [RenderDashboardJob], title lhsTitle: String, id lhsID: String,
                                 _ rhs: [RenderDashboardJob], title rhsTitle: String, id rhsID: String) -> Bool {
        let left = lhs.map(priority).min() ?? 6, right = rhs.map(priority).min() ?? 6
        if left != right { return left < right }
        let leftDate = lhs.compactMap(\.observedAt).max() ?? .distantPast
        let rightDate = rhs.compactMap(\.observedAt).max() ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        let titleOrder = lhsTitle.compare(rhsTitle, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        return lhsID < rhsID
    }
    func rebuild(_ snapshot: RenderCatalogSnapshot, query: String, scope: CatalogScope, source: Filter = .all, type: WorkFilter = .all) {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = Signature(revision: snapshot.revision, query: search, scope: scope, source: source, type: type)
        guard signature != next else { return }
        signature = next
        projects = snapshot.projects
        projectByID = Dictionary(snapshot.projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        workByKey = [:]; workByJob = [:]
        for work in snapshot.works {
            workByKey[Self.workKey(projectID: work.projectID, workID: work.id)] = work
            for job in work.jobs { workByJob[job.id] = work }
        }
        let filtered = snapshot.jobs.filter { job in
            scope.matches(job) && type.matches(job.workType)
                && (source == .all || (source == .shadow ? job.source.isShadow : !job.source.isShadow))
                && (search.isEmpty || [job.title, job.projectTitle ?? "", job.workTitle ?? "", job.versionLabel ?? "", job.source.rawValue].contains { $0.localizedCaseInsensitiveContains(search) })
        }
        visibleJobIDs = Set(filtered.map(\.id))
        visibleProjects = snapshot.projects.filter { $0.jobs.contains { visibleJobIDs.contains($0.id) } }
        visibleWorksByProject = [:]; visibleJobsByWork = [:]
        for work in snapshot.works {
            let jobs = work.jobs.filter { visibleJobIDs.contains($0.id) }
            if !jobs.isEmpty {
                visibleWorksByProject[work.projectID, default: []].append(work)
                visibleJobsByWork[Self.workKey(projectID: work.projectID, workID: work.id)] = jobs
            }
        }
        visibleProjects.sort { lhs, rhs in
            Self.precedes(lhs.jobs.filter { visibleJobIDs.contains($0.id) }, title: lhs.title, id: lhs.id,
                          rhs.jobs.filter { visibleJobIDs.contains($0.id) }, title: rhs.title, id: rhs.id)
        }
        for projectID in Array(visibleWorksByProject.keys) {
            let works = (visibleWorksByProject[projectID] ?? []).sorted { lhs, rhs in
                Self.precedes(visibleJobsByWork[Self.workKey(projectID: lhs.projectID, workID: lhs.id)] ?? [], title: lhs.title, id: lhs.id,
                              visibleJobsByWork[Self.workKey(projectID: rhs.projectID, workID: rhs.id)] ?? [], title: rhs.title, id: rhs.id)
            }
            visibleWorksByProject[projectID] = works
        }
        var order: [String] = [], grouped: [String: [RenderDashboardJob]] = [:], titles: [String: String] = [:]
        for job in filtered {
            let candidate = workByJob[job.id]
            let work = candidate?.id.hasPrefix("job:") == false ? candidate : nil
            let key = work.map { Self.workKey(projectID: job.projectID, workID: $0.id) } ?? "project:" + job.projectID
            if grouped[key] == nil {
                order.append(key)
                let projectTitle = projectByID[job.projectID]?.title ?? job.projectTitle ?? "Projet non identifié"
                titles[key] = work.map { $0.title == projectTitle ? projectTitle : projectTitle + " · " + $0.title } ?? projectTitle
            }
            grouped[key, default: []].append(job)
        }
        sections = order.map { CatalogSection(id: $0, title: titles[$0] ?? "Travail non identifié", jobs: grouped[$0] ?? []) }
    }
}
