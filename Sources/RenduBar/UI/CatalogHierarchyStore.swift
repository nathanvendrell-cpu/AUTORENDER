import Foundation
import Combine

@MainActor final class CatalogHierarchyStore: ObservableObject {
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var rebuilding = false
    private(set) var index = CatalogHierarchyIndex()
    private var key = ""
    private var request: UInt64 = 0
    private var task: Task<Void, Never>?
    func rebuild(records: [CatalogHierarchyRecord], contexts: [String: CatalogHierarchyContext], key: String,
                 revealJobID: String?) {
        guard self.key != key else { return }
        self.key = key; request &+= 1
        let request = request, navigation = index.navigation, navigationGeneration = generation
        task?.cancel(); rebuilding = true
        task = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> CatalogHierarchyIndex? in
                let result = CatalogHierarchyIndex()
                guard result.rebuild(records, cancelled: { Task.isCancelled }, context: { contexts[$0.id] ?? .init() }),
                      !Task.isCancelled else { return nil }
                result.restore(navigation)
                if navigation.expanded.isEmpty, let revealJobID { result.reveal(jobID: revealJobID) }
                return result
            }
            let result = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, let self, self.request == request, let result else { return }
            if self.generation != navigationGeneration { result.restore(self.index.navigation) }
            self.index = result; self.rebuilding = false; self.generation &+= 1
        }
    }
    func cancel() {
        task?.cancel(); task = nil; request &+= 1; rebuilding = false; key = ""
    }
    func reveal(_ jobID: String) { if index.reveal(jobID: jobID) { generation &+= 1 } }
    func toggle(_ id: String) { index.toggle(id); generation &+= 1 }
    func turnPage(_ id: String, forward: Bool) { index.turnPage(id, forward: forward); generation &+= 1 }
    deinit { task?.cancel() }
}

extension CatalogHierarchyRecord {
    init(job: RenderDashboardJob) {
        var labels = [job.workTitle, job.libraryVersion, job.versionLabel ?? job.title].compactMap { $0 }.filter { !$0.isEmpty }
        if labels.isEmpty { labels = [job.title] }
        self.init(id: job.id, title: job.title, projectID: job.projectID, projectTitle: job.projectTitle,
            versionLabel: labels.enumerated().filter { $0.offset == 0 || labels[$0.offset - 1] != $0.element }.map { $0.element }.joined(separator: " · "),
            isDetectedActiveRender: job.isDetectedActiveRender, isFinishedRender: job.isFinishedRender,
            observedAt: job.observedAt, lastActivity: job.lastActivity)
    }
}
extension CatalogHierarchyContext {
    init(job: RenderDashboardJob) {
        self.init(subprojectID: job.subprojectID, subprojectTitle: job.subprojectTitle,
                  sceneID: job.sceneID, sceneTitle: job.sceneTitle)
    }
}
