import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    let openCompact: () -> Void
    let quit: () -> Void
    @StateObject private var selection: CatalogSelectionController
    private var projectID: String { selection.projectID }
    private var selectedWorkID: String { selection.workID }
    private var jobID: String { selection.jobID }
    init(model: MonitorModel, openCompact: @escaping () -> Void, quit: @escaping () -> Void = { NSApp.terminate(nil) }, initialScope: CatalogScope = .direct, initialLibrary: Bool = false, selectionDefaults: UserDefaults = .standard) {
        self.model = model; self.openCompact = openCompact; self.quit = quit
        _catalogScope = State(initialValue: initialScope)
        _showLibrary = State(initialValue: initialLibrary)
        _selection = StateObject(wrappedValue: CatalogSelectionController(defaults: selectionDefaults))
    }
    @StateObject private var activeHierarchy = CatalogHierarchyStore()
    @StateObject private var historyHierarchy = CatalogHierarchyStore()
    private var hierarchy: CatalogHierarchyStore { catalogScope == .direct ? activeHierarchy : historyHierarchy }
    @State private var projectPage = 0
    @State private var activeProjectionRevision: UInt64 = 0
    @State private var emptyActiveTitle = "Observation en attente"
    @State private var showLibrary = false
    @StateObject private var presentation = CatalogPresentationStore()
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    @State private var appliedNavigationID = ""
    @State private var query = ""
    @State private var catalogScope: CatalogScope = .direct
    @State private var organizingJob: RenderDashboardJob?

    @State private var filter: Filter = .all
    @State private var workFilter: WorkFilter = .all
    @State private var showHistory = false
    @State private var showSources = false

    private var projects: [RenderDashboardProject] { presentation.projects }
    // Preserve unavailable saved identities while showing useful current content.
    // Explicit dashboard navigation stays exact, even before its job is discovered.
    private var selectedProject: RenderDashboardProject? {
        visibleProjects.first { $0.id == projectID } ?? (selection.explicitDashboardTarget == nil ? visibleProjects.first : nil)
    }
    private var selectedWork: RenderCatalogWork? {
        guard let project = selectedProject else { return nil }
        if let work = presentation.work(projectID: project.id, workID: selectedWorkID),
           presentation.visibleJobsByWork[CatalogPresentationStore.workKey(projectID: project.id, workID: work.id)] != nil { return work }
        return selection.explicitDashboardTarget == nil ? presentation.visibleWorksByProject[project.id]?.first : nil
    }
    private var selectedJob: RenderDashboardJob? {
        guard let work = selectedWork else { return nil }
        if let job = presentation.visibleJobByID[jobID], job.projectID == work.projectID,
           presentation.workByJob[job.id]?.id == work.id { return job }
        return selection.explicitDashboardTarget == nil ? presentation.visibleJobsByWork[CatalogPresentationStore.workKey(projectID: work.projectID, workID: work.id)]?.first : nil
    }
    private func matches(_ job: RenderDashboardJob) -> Bool { presentation.visibleJobIDs.contains(job.id) }
    private var visibleProjects: [RenderDashboardProject] { presentation.visibleProjects }
    private func rebuildPresentation() {
        if catalogScope == .direct {
            activeProjectionRevision &+= 1
            switch model.menuBarObservation(at: Date()) {
            case .confirmed: emptyActiveTitle = "Aucun rendu actif détecté"
            case .refreshing: emptyActiveTitle = "Actualisation en cours"
            case .uncertain: emptyActiveTitle = "Activité à confirmer"
            }
        }
        let snapshot = catalogScope == .direct
            ? CatalogProjectionSnapshot.active(model.activeRenderJobs, revision: activeProjectionRevision)
            : CatalogProjectionSnapshot.history(model.catalogSnapshot, revision: model.historyRevision)
        presentation.rebuild(snapshot, query: query, scope: catalogScope, source: filter, type: workFilter)
        if let job = presentation.visibleJobByID[jobID], job.projectID != selection.projectID,
           let work = presentation.workByJob[job.id] { selection.choose(job, workID: work.id) }
        if catalogScope == .direct { selection.reconcileActive(presentation) }
        else { selection.reconcile(presentation) }
        let jobs = snapshot.jobs.filter { presentation.visibleJobIDs.contains($0.id) }
        let contexts = Dictionary(jobs.map { ($0.id, CatalogHierarchyContext(job: $0)) }, uniquingKeysWith: { first, _ in first })
        let revision = catalogScope == .direct ? snapshot.revision : model.historyRevision
        let key = "\(revision)|\(catalogScope.rawValue)|\(query)|\(filter.rawValue)|\(workFilter.rawValue)"
        hierarchy.rebuild(records: jobs.map { CatalogHierarchyRecord(job: $0) }, contexts: contexts, key: key, revealJobID: selectedJob?.id)
        if let position = visibleProjects.firstIndex(where: { $0.id == selectedProject?.id }) { projectPage = position / 50 }
        else { projectPage = 0 }
    }

    private func applyDashboardNavigation() {
        guard let request = selection.dashboardNavigation, request.id != appliedNavigationID else { return }
        appliedNavigationID = request.id
        if let job = model.catalogSnapshot.jobs.first(where: { $0.id == request.jobID }),
           let targetScope = CatalogScope.dashboardScope(for: job) {
            selection.apply(request)
            catalogScope = request.scope == .finished && model.config.jobArchives[job.id] == nil && job.isTerminalRender ? .finished : targetScope
        } else if request.scope == .archived || request.scope == .finished {
            selection.apply(request)
            catalogScope = request.scope
        } else {
            catalogScope = .direct
            showSources = true
        }
        query = ""; filter = .all; workFilter = .all
        showHistory = false
        rebuildPresentation()
        selection.consumeDashboardNavigation(request.id)
    }
    var body: some View { presentedLayout }

    private var baseLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error = model.configurationError { Text("Préférences indisponibles").font(.system(size: 12)).foregroundStyle(.orange).help(error) }
            HStack(alignment: .top, spacing: 18) {
                sidebar.frame(width: 310, alignment: .leading)
                ScrollView {
                    if let target = selection.explicitDashboardTarget, !presentation.visibleJobIDs.contains(target.jobID) {
                        explicitTargetUnavailable(target)
                    } else if visibleProjects.isEmpty {
                        emptyFilters
                    } else if let project = selectedProject, !(presentation.visibleWorksByProject[project.id] ?? []).isEmpty {
                        projectDashboard(project)
                    } else {
                        emptySelection
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Progression par version")
                Spacer()
                Button("Moniteur complet") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:4420/")!) }.buttonStyle(.link)
                Button("Quitter", action: quit).buttonStyle(.link)
            }.font(.system(size: 11)).foregroundStyle(muted)
        }.padding(22).foregroundStyle(ink).renderWindowSurface()
            .frame(minWidth: 920, minHeight: 650)
    }

    private var observedLayout: some View {
        baseLayout
            .onAppear(perform: appear)
            .onChange(of: selection.dashboardNavigation?.id) { applyDashboardNavigation() }
            .onChange(of: model.catalogSnapshot.revision) { if catalogScope == .direct { rebuildPresentation() } }
            .onChange(of: model.historyRevision) { rebuildPresentation() }
            .onChange(of: model.observationRevision) { if catalogScope == .direct { rebuildPresentation() } }
            .onReceive(NotificationCenter.default.publisher(for: CatalogProjectionSnapshot.request, object: model), perform: receiveOverviewRequest)
    }

    private var filteredLayout: some View {
        observedLayout
            .onChange(of: query) { rebuildPresentation() }
            .onChange(of: catalogScope) { rebuildPresentation() }
            .onChange(of: filter) { rebuildPresentation() }
            .onChange(of: workFilter) { rebuildPresentation() }
            .onChange(of: jobID) { selection.remember(presentation); showHistory = false }
            .onChange(of: selectedWorkID) { selection.remember(presentation) }
    }

    private var presentedLayout: some View {
        filteredLayout
            .onDisappear(perform: stopProjection)
            .sheet(isPresented: $showLibrary) { LibrarySettingsView(model: model) }
            .sheet(isPresented: $showSources) { SourcesView(model: model) }
            .sheet(isPresented: $showHistory) { if let job = selectedJob { HistoryPanel(model: model, job: job) } }
            .sheet(item: $organizingJob) { OrganisationView(model: model, job: $0) }
    }

    private func appear() { applyDashboardNavigation(); rebuildPresentation() }
    private func stopProjection() {
        activeHierarchy.cancel(); historyHierarchy.cancel(); model.setVisiblePreviewEntries([])
    }
    private func receiveOverviewRequest(_ notification: Notification) {
        if let id = notification.userInfo?["restoredJobID"] as? String,
           var job = model.catalogSnapshot.jobs.first(where: { $0.id == id }), job.isTerminalRender {
            job.archivedAt = nil
            let workID = presentation.workByJob[id]?.id ?? job.workID ?? "job:" + job.id
            selection.openInDashboard(job, workID: workID)
            applyDashboardNavigation()
            return
        }
        if let raw = notification.userInfo?["scope"] as? String, let scope = CatalogScope(rawValue: raw) {
            selection.clearDashboardTarget(); catalogScope = scope; resetSecondaryFilters()
        }
        if notification.userInfo?["library"] as? Bool == true { showLibrary = true }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: RenduLogo.app).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUTORENDER").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(2.8).foregroundStyle(accent)
                    Text("Rendus").font(.system(size: 28, weight: .semibold))
                    Text("Projets · sous-projets · scènes · versions").font(.system(size: 12)).foregroundStyle(muted)
                }
            }.renderWindowDragRegion(enabled: true)
            Spacer()
            Button("Bibliothèque") { showLibrary = true }.buttonStyle(.bordered)
            Button("Suivi compact", action: openCompact).buttonStyle(.bordered)
            Button("Sources suivies") { showSources = true }.buttonStyle(.bordered)
            Button { model.refreshNow() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Rechercher un travail ou une version", text: $query).textFieldStyle(.roundedBorder)
            Picker("État", selection: Binding(get: { catalogScope }, set: { selection.clearDashboardTarget(); catalogScope = $0 })) {
                ForEach(CatalogScope.mainSections, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("PROJETS · \(visibleProjects.count)").font(.system(size: 11, weight: .bold)).tracking(1)
            Picker("Source", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Picker("Travail", selection: $workFilter) {
                ForEach(WorkFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleProjects.dropFirst(projectPage * 50).prefix(50))) { project in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 5) {
                                CatalogFolderName(name: project.title, targets: presentation.targetsByProject[project.id] ?? [])
                                    .font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
                                Spacer(minLength: 2)
                                Button { choose(project) } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.plain).help("Afficher les travaux du projet").accessibilityLabel("Sélectionner le projet " + project.title)
                            }
                            Text(catalogScope == .direct ? "\(presentation.visibleCountByProject[project.id] ?? 0) versions en cours" : "\(presentation.visibleCountByProject[project.id] ?? 0) versions affichées").font(.system(size: 11)).foregroundStyle(muted)
                            Text(presentation.freshByProject[project.id] == true ? "Sources récentes" : "Dernier relevé / source indisponible")
                                .font(.system(size: 10)).foregroundStyle(muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(project.id == selectedProject?.id ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).renderGlass(radius: 12, shadow: 2)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(project.id == selectedProject?.id ? accent : Color.clear, lineWidth: 1.5))

                    }
                    if visibleProjects.isEmpty { Text("Aucun projet pour ces filtres.").font(.system(size: 12)).foregroundStyle(muted) }
                }
            }
            if visibleProjects.count > 50 {
                HStack {
                    Button("Précédent") { projectPage -= 1 }.disabled(projectPage == 0)
                    Text("\(projectPage * 50 + 1)–\(min((projectPage + 1) * 50, visibleProjects.count)) / \(visibleProjects.count)").font(.system(size: 10))
                    Button("Suivant") { projectPage += 1 }.disabled((projectPage + 1) * 50 >= visibleProjects.count)
                }.font(.system(size: 11))
            }
            Divider()
            Text("\(presentation.visibleJobIDs.count) versions · \(catalogScope.rawValue)").font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    private func choose(_ project: RenderDashboardProject) { selection.choose(project, presentation: presentation) }
    private func choose(_ work: RenderCatalogWork) { selection.choose(work, presentation: presentation); showHistory = false }

    private func resetSecondaryFilters() {
        query = ""; filter = .all; workFilter = .all
        rebuildPresentation()
    }
    private var emptyScopeTitle: String {
        switch catalogScope {
        case .direct: return emptyActiveTitle
        case .finished: return "Aucun rendu fait pour ces filtres"
        case .archived: return "Aucune archive pour ces filtres"
        case .unclassified: return "Aucun rendu à classer pour ces filtres"
        case .all, .follow: return "Aucun rendu pour ces filtres"
        }
    }
    private var emptyFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30)).foregroundStyle(accent)
            Text(emptyScopeTitle)
                .font(.system(size: 23, weight: .semibold))
            Text(catalogScope == .direct ? "Les rendus qui cessent d’être actifs quittent cette vue automatiquement. Les candidats restent dans Sources." : model.catalogSnapshot.knownJobCount == 0 ? "Aucun rendu connu. Vérifiez les sources connectées et les dossiers suivis." : "Cette combinaison de source, de type et de recherche ne correspond à aucun rendu.")
                .font(.system(size: 13)).foregroundStyle(muted)
            Text("Dernier cycle d’observation : " + model.lastScan.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11)).foregroundStyle(muted)
            HStack(spacing: 12) {
                Button(catalogScope == .archived ? "Voir toutes les archives" : "Réinitialiser les filtres", action: resetSecondaryFilters)
                    .buttonStyle(.borderedProminent)
                Button("Voir les rendus terminés") { selection.clearDashboardTarget(); catalogScope = .finished; resetSecondaryFilters() }.buttonStyle(.bordered)
                Button("Sources suivies") { showSources = true }.buttonStyle(.bordered)
            }
        }.padding(24).frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading).renderGlass()
    }

    private func explicitTargetUnavailable(_ target: DashboardNavigationRequest) -> some View {
        let known = presentation.workByJob[target.jobID] != nil
        return VStack(alignment: .leading, spacing: 12) {
            Text(known ? "Version demandée hors du filtre actuel" : "Version demandée indisponible")
                .font(.system(size: 21, weight: .semibold))
            Text(known ? "Son état a pu changer depuis l’ouverture. La cible reste conservée ; aucune autre version n’est sélectionnée." : "Cette version n’est pas encore présente dans le catalogue. La cible reste conservée pendant l’actualisation.")
                .font(.system(size: 13)).foregroundStyle(muted)
            HStack {
                if let job = model.catalogSnapshot.jobs.first(where: { $0.id == target.jobID }),
                   let section = CatalogScope.dashboardScope(for: job) {
                    Button("Afficher cette version") { catalogScope = section; resetSecondaryFilters() }.buttonStyle(.borderedProminent)
                }
                Button("Sources suivies") { showSources = true }.buttonStyle(.bordered)
                Button("Actualiser les sources") { model.refreshNow() }.buttonStyle(.bordered)
            }
            Text("Vous pouvez aussi choisir explicitement un autre projet dans la liste.")
                .font(.system(size: 11)).foregroundStyle(muted)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading).renderGlass()
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(selection.explicitDashboardTarget == nil ? "Choisissez un projet pour ces filtres" : "Version demandée indisponible").font(.system(size: 21, weight: .semibold))
            Text(selection.explicitDashboardTarget == nil ? "Sélectionnez un projet dans la liste pour afficher ses versions." : "Cette version n’est pas présente dans le catalogue actuel. Actualisez les sources ou sélectionnez un autre travail.").font(.system(size: 13)).foregroundStyle(muted)
            Button("Ouvrir le suivi compact", action: openCompact).buttonStyle(.borderedProminent)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectDashboard(_ project: RenderDashboardProject) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                CatalogFolderName(name: project.title, targets: presentation.targetsByProject[project.id] ?? [])
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                CatalogFolderMenu(targets: presentation.targetsByProject[project.id] ?? [], label: "Dossiers des versions", iconOnly: true)
                Spacer()
                Text("\(presentation.visibleCountByProject[project.id] ?? 0) versions").font(.system(size: 11)).foregroundStyle(muted)
            }
            ScrollView {
                CatalogHierarchyBrowser(store: hierarchy, projectID: project.id, selectedJobID: selectedJob?.id) { id in
                    guard let job = presentation.visibleJobByID[id], let work = presentation.workByJob[id] else { return }
                    selection.choose(job, workID: work.id); showHistory = false
                }
            }.frame(height: 260)
            if let job = selectedJob, matches(job) {
                JobDetailView(model: model, job: job, onOrganize: { organizingJob = $0 }, onHistory: { showHistory = true })
            } else {
                Text("Choisissez une version dans son sous-projet et sa scène.").font(.system(size: 12)).foregroundStyle(muted)
            }
        }.frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
