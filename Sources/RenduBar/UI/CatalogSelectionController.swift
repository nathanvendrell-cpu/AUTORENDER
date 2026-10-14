import Foundation
import Combine

struct DashboardNavigationRequest: Codable, Equatable {
    let id: String
    let projectID: String
    let workID: String
    let jobID: String
    let scopeValue: String
    var scope: CatalogScope { CatalogScope(rawValue: scopeValue) ?? .all }
}

@MainActor
final class CatalogSelectionController: ObservableObject {
    @Published var projectID: String { didSet { persist(projectID, key: "AUTORENDER.SelectedProject", previous: oldValue) } }
    @Published var workID: String { didSet { persist(workID, key: "AUTORENDER.SelectedWork", previous: oldValue) } }
    @Published var jobID: String { didSet { persist(jobID, key: "AUTORENDER.SelectedJob", previous: oldValue) } }
    @Published private(set) var dashboardNavigation: DashboardNavigationRequest?
    @Published private(set) var explicitDashboardTarget: DashboardNavigationRequest?
    private let defaults: UserDefaults
    private var remembered: [String: String]
    private var memoryJSON: String
    private var observer: NSObjectProtocol?
    private var navigationObserver: NSObjectProtocol?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        projectID = defaults.string(forKey: "AUTORENDER.SelectedProject") ?? ""
        workID = defaults.string(forKey: "AUTORENDER.SelectedWork") ?? ""
        jobID = defaults.string(forKey: "AUTORENDER.SelectedJob") ?? ""
        memoryJSON = defaults.string(forKey: "AUTORENDER.JobSelectionByWork") ?? "{}"
        remembered = Self.decode(memoryJSON)
        dashboardNavigation = nil
        explicitDashboardTarget = nil
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        navigationObserver = NotificationCenter.default.addObserver(forName: Self.navigationNotification, object: defaults, queue: .main) { [weak self] notification in
            guard let request = notification.userInfo?["request"] as? DashboardNavigationRequest else { return }
            Task { @MainActor in self?.dashboardNavigation = request }
        }
    }
    private static let navigationNotification = Notification.Name("AUTORENDER.OpenDashboardRequest")
    private func persist(_ value: String, key: String, previous: String) {
        if value != previous, defaults.string(forKey: key) != value { defaults.set(value, forKey: key) }
    }
    private func refresh() {
        let project = defaults.string(forKey: "AUTORENDER.SelectedProject") ?? ""
        let work = defaults.string(forKey: "AUTORENDER.SelectedWork") ?? ""
        let job = defaults.string(forKey: "AUTORENDER.SelectedJob") ?? ""
        if projectID != project { projectID = project }
        if workID != work { workID = work }
        if jobID != job { jobID = job }
        let json = defaults.string(forKey: "AUTORENDER.JobSelectionByWork") ?? "{}"
        if json != memoryJSON { memoryJSON = json; remembered = Self.decode(json) }
    }
    private static func decode(_ text: String) -> [String: String] {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    func reconcile(_ presentation: CatalogPresentationStore) {
        // Keep the exact requested identity until the user chooses another target.
        // A known archive can be reactivated between the click and this projection.
        if explicitDashboardTarget != nil { return }

        if projectID.isEmpty {
            if let first = presentation.visibleProjects.first { choose(first, presentation: presentation) }
            return
        }
        if presentation.projectByID[projectID] == nil, let migrated = presentation.projects.first(where: { $0.legacyIDs.contains(projectID) }) { projectID = migrated.id }
        if presentation.work(projectID: projectID, workID: workID) == nil {
            if let previous = presentation.workByJob[jobID], previous.projectID == projectID { workID = previous.id }
            else if workID.isEmpty, let first = presentation.visibleWorksByProject[projectID]?.first { choose(first, presentation: presentation) }
        }
        guard !presentation.visibleJobIDs.isEmpty, presentation.projectByID[projectID] != nil else { return }
        guard let works = presentation.visibleWorksByProject[projectID], !works.isEmpty else {
            if let first = presentation.visibleProjects.first { choose(first, presentation: presentation) }
            return
        }
        if let work = works.first(where: { $0.id == workID }) {
            if !presentation.visibleJobIDs.contains(jobID), presentation.workByJob[jobID] != nil {
                choose(work, presentation: presentation)
            } else if jobID.isEmpty { choose(work, presentation: presentation) }
        } else if presentation.work(projectID: projectID, workID: workID) != nil {
            choose(works[0], presentation: presentation)
        }
    }
    func clearDashboardTarget() { explicitDashboardTarget = nil }
    func reconcileActive(_ presentation: CatalogPresentationStore) {
        if let target = explicitDashboardTarget, !presentation.visibleJobIDs.contains(target.jobID) {
            explicitDashboardTarget = nil
        }
        guard !presentation.visibleJobIDs.isEmpty else { return }
        if !presentation.visibleJobIDs.contains(jobID), let first = presentation.visibleProjects.first {
            choose(first, presentation: presentation)
        }
        reconcile(presentation)
    }
    func choose(_ project: RenderDashboardProject, presentation: CatalogPresentationStore) {
        explicitDashboardTarget = nil
        if project.id == projectID, presentation.visibleJobIDs.contains(jobID) { return }
        projectID = project.id
        if let first = presentation.visibleWorksByProject[project.id]?.first { choose(first, presentation: presentation) }
        else { workID = ""; jobID = "" }
    }
    func choose(_ work: RenderCatalogWork, presentation: CatalogPresentationStore) {
        explicitDashboardTarget = nil
        projectID = work.projectID; workID = work.id
        let key = CatalogPresentationStore.workKey(projectID: work.projectID, workID: work.id)
        let visible = presentation.visibleJobsByWork[key] ?? []
        if let previous = remembered[key], visible.contains(where: { $0.id == previous }) { jobID = previous }
        else { jobID = visible.first?.id ?? "" }
    }
    func choose(_ job: RenderDashboardJob, workID: String) {
        explicitDashboardTarget = nil
        projectID = job.projectID; self.workID = workID; jobID = job.id
    }
    func openInDashboard(_ job: RenderDashboardJob, workID: String) {
        guard let targetScope = CatalogScope.dashboardScope(for: job) else { return }
        choose(job, workID: workID)
        let request = DashboardNavigationRequest(id: UUID().uuidString, projectID: job.projectID,
            workID: workID, jobID: job.id, scopeValue: targetScope.rawValue)
        dashboardNavigation = request
        NotificationCenter.default.post(name: Self.navigationNotification, object: defaults, userInfo: ["request": request])
    }
    func consumeDashboardNavigation(_ id: String) {
        if dashboardNavigation?.id == id { dashboardNavigation = nil }
    }
    func apply(_ request: DashboardNavigationRequest) {
        explicitDashboardTarget = request
        projectID = request.projectID; workID = request.workID; jobID = request.jobID
    }
    func remember(_ presentation: CatalogPresentationStore) {
        guard let work = presentation.work(projectID: projectID, workID: workID), work.jobs.contains(where: { $0.id == jobID }) else { return }
        let key = CatalogPresentationStore.workKey(projectID: projectID, workID: workID)
        guard remembered[key] != jobID else { return }
        remembered[key] = jobID
        if let data = try? JSONEncoder().encode(remembered), let json = String(data: data, encoding: .utf8) {
            memoryJSON = json; defaults.set(json, forKey: "AUTORENDER.JobSelectionByWork")
        }
    }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
    }
}
