import Foundation
import Combine

@MainActor
final class HistoryController: ObservableObject {
    typealias Loader = (RenderDashboardJob, String?, Int) async -> RenderHistoryPage
    enum Direction { case refresh, next, previous }
    // One visible page (40 entries) replaces the previous page; no growing page/cursor stack.
    @Published private(set) var items: [RenderEntry] = []
    @Published private(set) var cursor: String?
    @Published private(set) var previousCursor: String?
    @Published private(set) var coverage = ""
    @Published private(set) var known: Int?
    @Published private(set) var loading = false
    private var revision: UInt64?
    private var scope: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    func load(job: RenderDashboardJob, append: Bool, loader: @escaping Loader) {
        load(job:job,direction:append ? .next : .refresh,loader:loader)
    }

    func load(job: RenderDashboardJob, direction: Direction, loader: @escaping Loader) {
        let refresh=direction == .refresh || scope != job.id
        let requestedCursor=refresh ? nil : (direction == .previous ? previousCursor : cursor)
        guard refresh || requestedCursor != nil else { return }
        task?.cancel()
        let token=UUID();generation=token
        if refresh {
            items=[];cursor=nil;previousCursor=nil;known=nil;revision=nil
            coverage="Inventaire en cours…"
        }
        scope=job.id;loading=true
        task=Task { [weak self] in
            let page=await loader(job,requestedCursor,40)
            guard let self,self.generation == token else { return }
            defer {self.loading=false;self.task=nil}
            guard !Task.isCancelled,self.scope == job.id else {return}
            if !refresh,let revision=self.revision,revision != page.snapshotRevision {
                self.cursor=nil;self.previousCursor=nil
                self.coverage="Catalogue modifié : actualisez cet inventaire avant de continuer."
                return
            }
            self.items=page.entries
            self.cursor=page.nextCursor;self.previousCursor=page.previousCursor;self.known=page.totalKnown
            self.coverage=page.coverage;self.revision=page.snapshotRevision
        }
    }
    func cancel() {
        generation=UUID();task?.cancel();task=nil;loading=false;scope=nil
        items=[];cursor=nil;previousCursor=nil;known=nil;revision=nil;coverage=""
    }
    deinit { task?.cancel() }
}
