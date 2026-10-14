import AppKit
import SwiftUI
struct MenuSummaryView: View {
    @ObservedObject var model: MonitorModel
    let detached: Bool
    let openOverview: () -> Void
    let detach: () -> Void
    @StateObject private var selection: CatalogSelectionController
    private var jobID: String { selection.jobID }
    init(model: MonitorModel, detached: Bool, openOverview: @escaping () -> Void, detach: @escaping () -> Void, selectionDefaults: UserDefaults = .standard) {
        self.model = model; self.detached = detached; self.openOverview = openOverview; self.detach = detach
        _selection = StateObject(wrappedValue: CatalogSelectionController(defaults: selectionDefaults))
    }
    @AppStorage("AUTORENDER.CompactHiddenRenderIDs") private var hiddenIDsJSON = "[]"
    @State private var hiddenIDs = Set<String>()
    @State private var listError = ""
    @State private var query = ""
    @State private var scope: CatalogScope = .direct
    @State private var sections: [CatalogSection] = []
    @State private var activeCount = 0
    @State private var finishedCount = 0
    @State private var showSources = false
    @State private var archivedCount = 0
    @State private var eligibleCount = 0
    @State private var knownCount = 0
    @State private var displayedCount = 0
    @StateObject private var presentation = CatalogPresentationStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                HStack(spacing: 9) {
                    Image(nsImage: RenduLogo.app).resizable().frame(width: 30, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AUTORENDER").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(RenderStyle.blue)
                        Text(scope == .direct ? "Rendus en cours" : "Rendus " + scope.rawValue.lowercased()).font(.system(size: 13, weight: .semibold))
                    }
                }.renderWindowDragRegion(enabled: detached)
                Spacer()
                if !detached {
                    Button(action: detach) { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain).help("Détacher le suivi compact").accessibilityLabel("Détacher le suivi compact")
                }
                Button { model.refreshNow() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("Actualiser")
            }
            HStack(spacing: 10) {
                countBadge("Actifs", activeCount, .green)
                countBadge("Terminés", finishedCount, .secondary)
                countBadge("Archives", archivedCount, .secondary)
                Spacer()
            }
            HStack {
                TextField("Rechercher projet, travail ou version", text: $query).textFieldStyle(.roundedBorder)
                Picker("Afficher", selection: $scope) {
                    ForEach(CatalogScope.mainSections, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
            }
            HStack {
                Button("Archiver \(eligibleCount) terminés") { model.archiveCompletedJobs() }
                    .buttonStyle(.bordered).disabled(eligibleCount == 0)
                    .help("Archive les rendus dont la fin est établie. Aucun fichier n’est supprimé.")
                Spacer()
                Menu("Options") {
                    Button("Voir les archives (\(archivedCount))") { query = ""; scope = .archived }
                    Button("Voir les rendus terminés") { query = ""; scope = .finished }
                    Button("Sources suivies") { showSources = true }
                    Divider()
                    Button("Réafficher les rendus masqués (\(hiddenIDs.count))") { hiddenIDs.removeAll(); saveHiddenIDs() }.disabled(hiddenIDs.isEmpty)
                    Button("Restaurer toutes les archives") { model.restoreAllArchivedJobs() }.disabled(model.config.jobArchives.isEmpty)
                }.menuStyle(.borderlessButton)

            }.font(.system(size: 11))
            if let error = model.configurationError { Text("Préférences indisponibles").font(.system(size: 11)).foregroundStyle(.orange).help(error) }
            if !listError.isEmpty { Text(listError).font(.system(size: 10)).foregroundStyle(.orange) }
            if let error = model.archiveError { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sections) { section in
                        Text(section.title + " · \(section.jobs.count)").font(.system(size: 11, weight: .bold)).foregroundStyle(RenderStyle.secondary).padding(.top, 5)
                        ForEach(section.jobs) { job in
                            CompactCatalogJobRow(model: model, archivePreferred: model.config.jobArchives[job.id] != nil, job: job, selected: job.id == jobID, hiddenFromFollow: hiddenIDs.contains(job.id), onToggleHidden: { toggleHidden(job.id) }) {
                                let current = model.catalogSnapshot.jobs.first { $0.id == job.id } ?? job
                                selection.openInDashboard(current, workID: presentation.workByJob[job.id]?.id ?? job.id)
                                selection.remember(presentation)
                                openOverview()
                            }
                        }
                    }
                    if displayedCount == 0 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(query.isEmpty && scope == .direct ? "Aucun rendu actif détecté. Les rendus terminés restent accessibles dans leur section." : "Aucun rendu pour ce filtre.")
                                .font(.system(size: 12)).foregroundStyle(RenderStyle.secondary)
                            Text("Dernier relevé : " + (model.catalogSnapshot.jobs.compactMap(\.observedAt).max()?.formatted(date: .abbreviated, time: .shortened) ?? "indisponible"))
                                .font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                            HStack {
                                Button("Voir les rendus terminés") { query = ""; scope = .finished }.buttonStyle(.bordered)
                                Button("Sources suivies") { showSources = true }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 20)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.catalogSnapshot.persistenceIssue != nil {
                Text("Catalogue non enregistré : les nouveaux rendus pourraient ne pas survivre à une relance.")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            HStack {
                Text("\(displayedCount) affichés · \(scope.rawValue)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Vue générale", action: openOverview).buttonStyle(.bordered)
            }
        }.padding(14).frame(minWidth: 480, maxWidth: 740, minHeight: 340, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .renderWindowSurface()
            .onAppear { loadHiddenIDs(); projectRows() }
            .onChange(of: hiddenIDsJSON) { loadHiddenIDs(); projectRows() }
            .onChange(of: model.catalogSnapshot.revision) { projectRows() }
            .onChange(of: query) { projectRows() }
            .onChange(of: scope) { projectRows() }
            .sheet(isPresented: $showSources) { SourcesView(model: model) }
    }

    private func loadHiddenIDs() {
        hiddenIDs = Set(hiddenIDsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }
    private func saveHiddenIDs() {
        if let data = try? JSONEncoder().encode(hiddenIDs.sorted()), let value = String(data: data, encoding: .utf8), value != hiddenIDsJSON { hiddenIDsJSON = value }
        projectRows()
    }
    private func toggleHidden(_ id: String) {
        guard let job = model.catalogSnapshot.jobs.first(where: { $0.id == id }) else { listError = "Rendu indisponible. Actualisez la liste."; return }
        guard let updated = CompactVisibility.toggledHiddenIDs(for: job, hiddenIDs: hiddenIDs) else {
            listError = "Ce rendu est actif : il reste dans la liste."; return
        }
        hiddenIDs = updated
        listError = ""; saveHiddenIDs()
    }
    private func countBadge(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)").fontWeight(.semibold).monospacedDigit()
            Text(title)
        }.font(.system(size: 10))
    }
    private func projectRows() {
        #if AUTORENDER_UI_HARNESS
        let projectionStart = ProcessInfo.processInfo.systemUptime
        defer { UIHarness50Metrics.recordProjection(known: knownCount, displayed: displayedCount,
            seconds: ProcessInfo.processInfo.systemUptime - projectionStart) }
        #endif
        let snapshot = model.catalogSnapshot
        let jobs = snapshot.jobs
        knownCount = snapshot.knownJobCount
        activeCount = jobs.filter { CatalogScope.direct.matches($0) }.count
        finishedCount = jobs.filter { CatalogScope.finished.matches($0) }.count
        archivedCount = snapshot.archivedJobCount
        eligibleCount = jobs.filter(\.canArchive).count
        presentation.rebuild(snapshot, query: query, scope: scope)
        sections = presentation.sections.compactMap { section in
            let visible = section.jobs.filter { CompactVisibility.isVisible($0, scope: scope, hiddenIDs: hiddenIDs) }
            return visible.isEmpty ? nil : CatalogSection(id: section.id, title: section.title, jobs: visible)
        }
        displayedCount = sections.reduce(0) { $0 + $1.jobs.count }
        if scope == .direct { activeCount = displayedCount }


    }
}


enum CompactVisibility {
    static func isProtected(_ job: RenderDashboardJob) -> Bool {
        CatalogScope.direct.matches(job)
    }
    static func toggledHiddenIDs(for job: RenderDashboardJob, hiddenIDs: Set<String>) -> Set<String>? {
        var updated = hiddenIDs
        if updated.contains(job.id) { updated.remove(job.id) }
        else {
            guard !isProtected(job) else { return nil }
            updated.insert(job.id)
        }
        return updated
    }
    static func isVisible(_ job: RenderDashboardJob, scope: CatalogScope, hiddenIDs: Set<String>) -> Bool {
        isProtected(job) || scope == .all || !hiddenIDs.contains(job.id)
    }
}
