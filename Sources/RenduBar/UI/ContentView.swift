import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    let openCompact: () -> Void
    @StateObject private var selection: CatalogSelectionController
    private var projectID: String { selection.projectID }
    private var selectedWorkID: String { selection.workID }
    private var jobID: String { selection.jobID }
    init(model: MonitorModel, openCompact: @escaping () -> Void, selectionDefaults: UserDefaults = .standard) {
        self.model = model; self.openCompact = openCompact
        _selection = StateObject(wrappedValue: CatalogSelectionController(defaults: selectionDefaults))
    }
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
        let works = presentation.visibleWorksByProject[project.id] ?? []
        return works.first { $0.id == selectedWorkID } ?? (selection.explicitDashboardTarget == nil ? works.first : nil)
    }
    private var selectedJob: RenderDashboardJob? {
        guard let work = selectedWork else { return nil }
        let jobs = presentation.visibleJobsByWork[CatalogPresentationStore.workKey(projectID: work.projectID, workID: work.id)] ?? []
        return jobs.first { $0.id == jobID } ?? (selection.explicitDashboardTarget == nil ? jobs.first : nil)
    }
    private func matches(_ job: RenderDashboardJob) -> Bool { presentation.visibleJobIDs.contains(job.id) }
    private var visibleProjects: [RenderDashboardProject] { presentation.visibleProjects }
    private func rebuildPresentation() {
        presentation.rebuild(model.catalogSnapshot, query: query, scope: catalogScope, source: filter, type: workFilter)
        if catalogScope == .direct { selection.reconcileActive(presentation) }
        else { selection.reconcile(presentation) }
    }

    private func applyDashboardNavigation() {
        guard let request = selection.dashboardNavigation, request.id != appliedNavigationID else { return }
        appliedNavigationID = request.id
        if let job = model.catalogSnapshot.jobs.first(where: { $0.id == request.jobID }),
           let targetScope = CatalogScope.dashboardScope(for: job) {
            selection.apply(request)
            catalogScope = targetScope
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
    var body: some View {
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
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(.system(size: 11)).foregroundStyle(muted)
        }.padding(22).foregroundStyle(ink).renderWindowSurface()
            .frame(minWidth: 920, minHeight: 650)
            .onAppear { applyDashboardNavigation(); rebuildPresentation() }
            .onChange(of: selection.dashboardNavigation?.id) { applyDashboardNavigation() }
            .onChange(of: model.catalogSnapshot.revision) { rebuildPresentation() }
            .onChange(of: query) { rebuildPresentation() }
            .onChange(of: catalogScope) { rebuildPresentation() }
            .onChange(of: filter) { rebuildPresentation() }
            .onChange(of: workFilter) { rebuildPresentation() }
            .onChange(of: jobID) { selection.remember(presentation); showHistory = false }
            .onChange(of: selectedWorkID) { selection.remember(presentation) }
            .onDisappear { model.setVisiblePreviewEntries([]) }
            .sheet(isPresented: $showSources) { SourcesView(model: model) }
            .sheet(isPresented: $showHistory) { if let job = selectedJob { HistoryPanel(model: model, job: job) } }
            .sheet(item: $organizingJob) { OrganisationView(model: model, job: $0) }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(nsImage: RenduLogo.app).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUTORENDER").font(.system(size: 14, weight: .bold, design: .rounded)).tracking(2.8).foregroundStyle(accent)
                    Text("Rendus").font(.system(size: 28, weight: .semibold))
                    Text("Projets · versions").font(.system(size: 12)).foregroundStyle(muted)
                }
            }.renderWindowDragRegion(enabled: true)
            Spacer()
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
                    ForEach(visibleProjects) { project in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 5) {
                                CatalogFolderName(name: project.title, targets: project.openTargets)
                                    .font(.system(size: 14, weight: .semibold)).multilineTextAlignment(.leading)
                                Spacer(minLength: 2)
                                Button { choose(project) } label: { Image(systemName: "arrow.right.circle") }
                                    .buttonStyle(.plain).help("Afficher les travaux du projet").accessibilityLabel("Sélectionner le projet " + project.title)
                            }
                            Text(catalogScope == .direct ? "\(project.jobs.filter(matches).count) versions en cours" : "\(project.jobs.filter(matches).count) versions affichées").font(.system(size: 11)).foregroundStyle(muted)
                            Text(project.jobs.allSatisfy(\.isFresh) ? "Sources récentes" : "Dernier relevé / source indisponible")
                                .font(.system(size: 10)).foregroundStyle(muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(project.id == selectedProject?.id ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).renderGlass(radius: 12, shadow: 2)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(project.id == selectedProject?.id ? accent : Color.clear, lineWidth: 1.5))

                    }
                    if visibleProjects.isEmpty { Text("Aucun projet pour ces filtres.").font(.system(size: 12)).foregroundStyle(muted) }
                }
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
    private var emptyFilters: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30)).foregroundStyle(accent)
            Text(catalogScope == .direct ? "Aucun rendu actif détecté" : catalogScope == .finished ? "Aucun rendu terminé pour ces filtres" : "Aucune archive pour ces filtres")
                .font(.system(size: 23, weight: .semibold))
            Text(catalogScope == .direct ? "Les rendus qui cessent d’être actifs quittent cette vue automatiquement. Les candidats restent dans Sources." : model.catalogSnapshot.jobs.isEmpty ? "Aucun rendu connu. Vérifiez les sources connectées et les dossiers suivis." : "Cette combinaison de source, de type et de recherche ne correspond à aucun rendu.")
                .font(.system(size: 13)).foregroundStyle(muted)
            Text("Dernier relevé : " + (model.catalogSnapshot.jobs.compactMap(\.observedAt).max()?.formatted(date: .abbreviated, time: .shortened) ?? "indisponible"))
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
        let works = presentation.visibleWorksByProject[project.id] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                CatalogFolderName(name: project.title, targets: project.openTargets)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                CatalogFolderMenu(targets: project.openTargets, label: "Dossiers des versions", iconOnly: true)
                Spacer()
                Text("\(works.count) \(works.count == 1 ? "travail" : "travaux") · versions séparées").font(.system(size: 11)).foregroundStyle(muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(works) { work in
                        Button { choose(work) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: work.id == selectedWork?.id ? "square.stack.fill" : "square.stack").foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(work.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    Text("\(presentation.visibleJobsByWork[CatalogPresentationStore.workKey(projectID: work.projectID, workID: work.id)]?.count ?? 0) versions · " + (work.workType?.label ?? "Type non déclaré"))
                                        .font(.system(size: 10)).foregroundStyle(muted)
                                }
                                Spacer()
                                let active = presentation.visibleActiveCount(projectID: work.projectID, workID: work.id)
                                Text(catalogScope == .direct ? "\(active) en cours" : catalogScope.rawValue).font(.system(size: 10)).monospacedDigit().foregroundStyle(muted)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(work.id == selectedWork?.id ? accent.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10)).renderGlass(radius: 12, shadow: 2)
                        }.buttonStyle(.plain).help(work.title)
                    }
                }
            }.frame(maxHeight: 190)
            if let work = selectedWork {
                if work.jobs.count > 1 || !work.id.hasPrefix("job:") {
                HStack {
                    Text(work.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Picker("Version", selection: Binding(get: { selectedJob?.id ?? jobID }, set: { id in
                        if let job = work.jobs.first(where: { $0.id == id }) { selection.choose(job, workID: work.id) }
                    })) {
                        ForEach(presentation.visibleJobsByWork[CatalogPresentationStore.workKey(projectID: work.projectID, workID: work.id)] ?? []) { Text($0.versionLabel ?? $0.title).tag($0.id) }
                    }.pickerStyle(.menu).frame(maxWidth: 360)
                }
                }
                if let job = selectedJob, matches(job) {
                    JobDetailView(model: model, job: job, onOrganize: { organizingJob = $0 }, onHistory: { showHistory = true })
                } else { Text("Choisissez une version correspondant à ces filtres.").font(.system(size: 12)).foregroundStyle(muted) }
            } else { Text("Choisissez un travail. Les versions ne sont pas regroupées sans identité explicite.").font(.system(size: 12)).foregroundStyle(muted) }
        }.frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
