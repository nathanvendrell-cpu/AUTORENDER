import Foundation
import Combine

@MainActor
final class CatalogPresentationStore: ObservableObject {
    @Published private(set) var sections: [CatalogSection] = []
    private(set) var targetsByProject: [String: [RenderFolderTarget]] = [:]
    private(set) var projects: [RenderDashboardProject] = []
    private(set) var projectByID: [String: RenderDashboardProject] = [:]
    private(set) var workByKey: [String: RenderCatalogWork] = [:]
    private(set) var workByJob: [String: RenderCatalogWork] = [:]
    private(set) var visibleProjects: [RenderDashboardProject] = []
    private(set) var visibleWorksByProject: [String: [RenderCatalogWork]] = [:]
    private(set) var visibleJobsByWork: [String: [RenderDashboardJob]] = [:]
    private(set) var visibleJobByID: [String: RenderDashboardJob] = [:]
    private(set) var visibleCountByProject: [String: Int] = [:]
    private(set) var freshByProject: [String: Bool] = [:]
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
    private struct Rank {
        let priority: Int
        let newest: Date
        let title: String
        let id: String
    }
    private static func rank(_ jobs: [RenderDashboardJob], title: String, id: String) -> Rank {
        var best = 6, newest = Date.distantPast
        for job in jobs { best = min(best, priority(job)); newest = max(newest, job.observedAt ?? .distantPast) }
        return Rank(priority: best, newest: newest, title: title, id: id)
    }
    private static func precedes(_ lhs: Rank, _ rhs: Rank) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.newest != rhs.newest { return lhs.newest > rhs.newest }
        let order = lhs.title.compare(rhs.title, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }
    func rebuild(_ snapshot: RenderCatalogSnapshot, query: String, scope: CatalogScope, source: Filter = .all, type: WorkFilter = .all) {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = Signature(revision: snapshot.revision, query: search, scope: scope, source: source, type: type)
        guard signature != next else { return }
        signature = next
        projects = snapshot.projects
        targetsByProject = Dictionary(snapshot.projects.map { ($0.id, $0.openTargets) }, uniquingKeysWith: { first, _ in first })
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
        visibleJobByID = Dictionary(filtered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        visibleCountByProject = [:]; freshByProject = [:]
        for job in filtered {
            visibleCountByProject[job.projectID, default: 0] += 1
            freshByProject[job.projectID] = (freshByProject[job.projectID] ?? true) && job.isFresh
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
        let jobsByProject = Dictionary(grouping: filtered, by: \.projectID)
        let projectRanks = Dictionary(visibleProjects.map { ($0.id, Self.rank(jobsByProject[$0.id] ?? [], title: $0.title, id: $0.id)) }, uniquingKeysWith: { first, _ in first })
        visibleProjects.sort { lhs, rhs in
            guard let left = projectRanks[lhs.id], let right = projectRanks[rhs.id] else { return lhs.id < rhs.id }
            return Self.precedes(left, right)
        }
        var workRanks: [String: Rank] = [:]
        for works in visibleWorksByProject.values {
            for work in works {
                let key = Self.workKey(projectID: work.projectID, workID: work.id)
                workRanks[key] = Self.rank(visibleJobsByWork[key] ?? [], title: work.title, id: work.id)
            }
        }
        for projectID in Array(visibleWorksByProject.keys) {
            visibleWorksByProject[projectID] = (visibleWorksByProject[projectID] ?? []).sorted { lhs, rhs in
                guard let left = workRanks[Self.workKey(projectID: lhs.projectID, workID: lhs.id)],
                      let right = workRanks[Self.workKey(projectID: rhs.projectID, workID: rhs.id)] else { return lhs.id < rhs.id }
                return Self.precedes(left, right)
            }
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
