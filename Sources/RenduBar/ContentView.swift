import AppKit
import SwiftUI

private enum Filter: String, CaseIterable { case all = "Ensemble", mac = "Mac", shadow = "Shadow" }
private enum WorkFilter: String, CaseIterable {
    case all = "Tous les travaux", video = "Vidéo", image = "Image / photo", audio = "Audio / musique", other = "Autres", unknown = "Non identifié"
    func matches(_ type: RenderWorkType?) -> Bool {
        switch self {
        case .all: return true
        case .video: return type == .video
        case .image: return type == .image
        case .audio: return type == .audio
        case .other: return type == .other
        case .unknown: return type == nil
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: MonitorModel
    let openCompact: () -> Void
    @AppStorage("AUTORENDER.SelectedProject") private var projectID = ""
    @AppStorage("AUTORENDER.SelectedJob") private var jobID = ""
    @AppStorage("AUTORENDER.SelectedWork") private var selectedWorkID = ""
    @AppStorage("AUTORENDER.JobSelectionByWork") private var savedJobsJSON = "{}"
    @State private var query = ""
    @State private var catalogScope: CatalogScope = .all
    @State private var historyItems: [RenderEntry] = []
    @State private var historyCursor: String?
    @State private var historyCoverage = ""
    @State private var historyKnown: Int?
    @State private var historyLoading = false
    @State private var historyRevision: UInt64?
    @State private var historyGeneration = UUID()
    @State private var showOrganize = false
    @State private var organizingJob: RenderDashboardJob?
    @State private var organizeWorkID: String?
    @State private var organizeWorkTitle = ""
    @State private var organizeVersionLabel = ""
    @State private var organizeError = ""

    @State private var filter: Filter = .all
    @State private var workFilter: WorkFilter = .all
    @State private var showHistory = false
    @State private var showSources = false
    @State private var showFolders = true
    @State private var shadowFolderInput = ""
    @State private var folderError = false
    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { colorScheme == .dark ? Color(red: 0.94, green: 0.94, blue: 0.91) : Color(red: 0.10, green: 0.10, blue: 0.12) }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.68, blue: 0.71) : Color(red: 0.40, green: 0.40, blue: 0.44) }
    private var canvas: Color { colorScheme == .dark ? Color(red: 0.07, green: 0.07, blue: 0.09) : Color(red: 0.96, green: 0.955, blue: 0.94) }
    private var card: Color { colorScheme == .dark ? Color(red: 0.11, green: 0.11, blue: 0.13) : .white }
    private let accent = Color(red: 0.23, green: 0.40, blue: 0.86)
    private var projects: [RenderDashboardProject] { model.dashboardProjects }
    private var selectedProject: RenderDashboardProject? { projects.first { $0.id == projectID } }
    private var selectedWork: RenderCatalogWork? { model.catalogSnapshot.works.first { $0.id == selectedWorkID && $0.projectID == projectID } }
    private var selectedJob: RenderDashboardJob? { selectedWork?.jobs.first { $0.id == jobID } }
    private func matches(_ job: RenderDashboardJob) -> Bool {
        catalogScope.matches(job) && (query.isEmpty || [job.title, job.versionLabel ?? "", job.workTitle ?? "", job.projectTitle ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }) && (filter == .all || (filter == .shadow ? job.source.isShadow : !job.source.isShadow)) && workFilter.matches(job.workType)
    }
    private var visibleProjects: [RenderDashboardProject] { projects.filter { $0.jobs.contains(where: matches) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(alignment: .top, spacing: 18) {
                sidebar.frame(width: 230)
                ScrollView {
                    if let project = selectedProject {
                        projectDashboard(project)
                    } else {
                        emptySelection
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Text("Lecture seule · progression propre à chaque version")
                Spacer()
                Button("Moniteur complet") { NSWorkspace.shared.open(URL(string: "http://127.0.0.1:4420/")!) }.buttonStyle(.link)
                Button("Quitter") { NSApp.terminate(nil) }.buttonStyle(.link)
            }.font(.system(size: 11)).foregroundStyle(muted)
        }.padding(22).foregroundStyle(ink).background(canvas)
            .frame(minWidth: 920, minHeight: 650)
            .onAppear(perform: initializeSelection)
            .onChange(of: model.catalogSnapshot.revision) { initializeSelection() }
            .onChange(of: jobID) { rememberSelection() }
            .onChange(of: selectedWorkID) { rememberSelection() }
            .onDisappear { model.setVisiblePreviewEntries([]) }
            .sheet(isPresented: $showSources) { sourcesSheet }
            .sheet(isPresented: $showHistory) { historySheet }
            .sheet(isPresented: $showOrganize) { organizeSheet }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: RenduLogo.app).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("AUTORENDER").font(.system(size: 25, weight: .semibold, design: .rounded))
                Text("Projets · versions · activité mesurée").font(.system(size: 12)).foregroundStyle(muted)
            }
            Spacer()
            Button("Suivi compact", action: openCompact).buttonStyle(.bordered)
            Button("Sources suivies") { showSources = true }.buttonStyle(.bordered)
            Button { model.refreshNow() } label: { Label("Actualiser", systemImage: "arrow.clockwise") }.buttonStyle(.bordered)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Rechercher un travail ou une version", text: $query).textFieldStyle(.roundedBorder)
            Picker("État", selection: $catalogScope) {
                ForEach(CatalogScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Text("PROJETS").font(.system(size: 11, weight: .bold)).tracking(1)
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
                            Text("\(project.jobs.count) job(s) / version(s)").font(.system(size: 11)).foregroundStyle(muted)
                            Text(project.jobs.allSatisfy(\.isFresh) ? "Sources récentes" : "Dernier relevé / source indisponible")
                                .font(.system(size: 10)).foregroundStyle(muted)
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(project.id == projectID ? accent.opacity(0.12) : card, in: RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(project.id == projectID ? accent : Color.clear, lineWidth: 1.5))

                    }
                    if visibleProjects.isEmpty { Text("Aucun projet pour ces filtres.").font(.system(size: 12)).foregroundStyle(muted) }
                }
            }
            Divider()
            Text("Les versions restent distinctes. Aucun pourcentage global n’est calculé.").font(.system(size: 11)).foregroundStyle(muted)
        }
    }

    private func initializeSelection() {
        if projectID.isEmpty {
            if let first = visibleProjects.first { choose(first) }
            return
        }
        if selectedProject == nil, let migrated = projects.first(where: { $0.legacyIDs.contains(projectID) }) { projectID = migrated.id }
        if selectedWork == nil {
            let available = model.catalogSnapshot.works.filter { $0.projectID == projectID }
            if let previous = available.first(where: { $0.jobs.contains(where: { $0.id == jobID }) }) { selectedWorkID = previous.id }
            else if selectedWorkID.isEmpty, let first = available.first(where: { $0.jobs.contains(where: matches) }) { choose(first) }
        }
    }
    private func choose(_ project: RenderDashboardProject) {
        if project.id == projectID && selectedWork != nil { return }
        projectID = project.id
        if let first = model.catalogSnapshot.works.first(where: { $0.projectID == project.id && $0.jobs.contains(where: matches) }) { choose(first) }
        else { selectedWorkID = ""; jobID = "" }
    }
    private func selectionKey(_ work: RenderCatalogWork) -> String { "\(work.projectID.utf8.count):\(work.projectID)\(work.id)" }
    private func choose(_ work: RenderCatalogWork) {
        projectID = work.projectID; selectedWorkID = work.id
        let remembered = (savedJobsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:])[selectionKey(work)]
        if let remembered, work.jobs.contains(where: { $0.id == remembered && matches($0) }) { jobID = remembered }
        else { jobID = work.jobs.first(where: matches)?.id ?? "" }
        showHistory = false
    }
    private func rememberSelection() {
        guard let work = selectedWork, work.jobs.contains(where: { $0.id == jobID }) else { return }
        var saved = savedJobsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        saved[selectionKey(work)] = jobID
        if let data = try? JSONEncoder().encode(saved), let text = String(data: data, encoding: .utf8), text != savedJobsJSON { savedJobsJSON = text }
    }

    private var emptySelection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(projectID.isEmpty ? "Choisissez un projet" : "Le projet sélectionné est indisponible").font(.system(size: 21, weight: .semibold))
            Text("La sélection est conservée. Le suivi compact affiche tous les jobs connus automatiquement.").font(.system(size: 13)).foregroundStyle(muted)
            Button("Ouvrir le suivi compact", action: openCompact).buttonStyle(.borderedProminent)
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func projectDashboard(_ project: RenderDashboardProject) -> some View {
        let works = model.catalogSnapshot.works.filter { $0.projectID == project.id && $0.jobs.contains(where: matches) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                CatalogFolderName(name: project.title, targets: project.openTargets)
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                CatalogFolderMenu(targets: project.openTargets, label: "Dossiers des versions", iconOnly: true)
                Spacer()
                Text("\(works.count) travaux · versions séparées").font(.system(size: 11)).foregroundStyle(muted)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(works) { work in
                        Button { choose(work) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: work.id == selectedWorkID ? "square.stack.fill" : "square.stack").foregroundStyle(accent)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(work.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text("\(work.jobs.count) version(s) · " + (work.workType?.label ?? "Type non déclaré"))
                                        .font(.system(size: 10)).foregroundStyle(muted)
                                }
                                Spacer()
                                let active = work.jobs.filter { $0.isFresh && !$0.retainedHistorical && $0.activity == .running }.count
                                Text("\(active) en cours").font(.system(size: 10)).monospacedDigit().foregroundStyle(muted)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(work.id == selectedWorkID ? accent.opacity(0.12) : card, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).help(work.title)
                    }
                }
            }.frame(maxHeight: 190)
            if let work = selectedWork {
                HStack {
                    Text(work.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Picker("Version", selection: $jobID) {
                        ForEach(work.jobs.filter(matches)) { Text($0.versionLabel ?? $0.title).tag($0.id) }
                    }.pickerStyle(.menu).frame(maxWidth: 360)
                }
                if let job = selectedJob, matches(job) {
                    jobDashboard(job)
                        .task(id: previewRequestID(job)) { model.setVisiblePreviewEntries(usefulPreviews(job)) }
                        .onDisappear { model.setVisiblePreviewEntries([]) }
                } else { Text("Choisissez une version pour ce filtre. La précédente sélection reste conservée.").font(.system(size: 12)).foregroundStyle(muted) }
            } else { Text("Choisissez un travail. Les versions ne sont pas regroupées sans identité explicite.").font(.system(size: 12)).foregroundStyle(muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func previewRequestID(_ job: RenderDashboardJob) -> String {
        job.id + "|" + usefulPreviews(job).map { $0.id + ":" + String($0.modified.timeIntervalSinceReferenceDate) }.joined(separator: "|")
    }

    private func jobDashboard(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.versionLabel ?? job.title).font(.system(size: 17, weight: .semibold))
                    Text(job.source.rawValue + " · " + (job.workType?.label ?? "Travail non identifié"))
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                Spacer()
                CatalogFolderMenu(targets: job.openTargets, latest: job.latestOutput, revealURL: job.revealURL)
                Button("Organiser") { beginOrganizing(job) }.buttonStyle(.bordered)
                Text(job.activityLabel).font(.system(size: 12, weight: .semibold)).padding(8)
                    .background(activityColor(job).opacity(0.12), in: Capsule()).foregroundStyle(activityColor(job))
            }
            if !job.isFresh || job.activity != .running {
                Text(!job.isFresh ? "Dernier relevé conservé. Activité actuelle et ETA indisponibles." : "Aucun rendu actif confirmé pour cette version. Aucune ETA future courante.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            HStack(alignment: .top, spacing: 14) {
                previews(job).frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    DashboardProgressView(title: job.source == .shadowMonitor ? "Images brutes" : (job.source == .macMonitor ? "Images comptées" : "Fichiers détectés"), count: job.rawCount, progress: job.rawProgress, isFresh: job.isFresh, activity: job.activity)
                    if job.source == .shadowMonitor || job.postCount != nil {
                        DashboardProgressView(title: "Images post", count: job.postCount, progress: job.postProgress, isFresh: job.isFresh, activity: job.activity)
                    }
                    metric("Intervalle historique médian", value: job.historicalMedianSeconds.map(duration) ?? "Indisponible", detail: "Entre sorties horodatées · échantillon API")
                    metric("Débit historique", value: job.sampledOutputsLastHour.map { "\($0) sorties / h" } ?? "Indisponible", detail: "Échantillon borné, heure avant le relevé")
                    metric("Fin estimée au rythme mesuré", value: job.eta.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Indisponible", detail: "Uniquement processus actif, source récente et total réel")
                }.frame(width: 280)
            }
            if let stage = job.stageDescription { metric("Détails / réglages source", value: stage, detail: "Spécifications fournies ; aucune étape courante inférée") }
            processDetails(job)
            if !job.plans.isEmpty { plans(job) }
            HStack {
                Text("Relevé : " + (job.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "date indisponible"))
                Spacer()
                Button("Historique des exports") { showHistory = true }.buttonStyle(.bordered)
            }.font(.system(size: 11)).foregroundStyle(muted)
            if let provenance = job.totalProvenance {
                Text("Total déclaré : " + provenance).font(.system(size: 10)).foregroundStyle(muted).textSelection(.enabled)
            }
        }.padding(16).background(card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func activityColor(_ job: RenderDashboardJob) -> Color {
        guard job.isFresh else { return .orange }
        switch job.activity {
        case .running: return .green
        case .stopped, .resumeRequired: return .orange
        case .countsReached: return accent
        case .unknown: return muted
        }
    }
    private func duration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0f s", seconds) : String(format: "%.0f min %.0f s", floor(seconds / 60), seconds.truncatingRemainder(dividingBy: 60))
    }
    private func metric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(muted)
            Text(value).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
            Text(detail).font(.system(size: 10)).foregroundStyle(muted)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    private func usefulPreviews(_ job: RenderDashboardJob) -> [RenderEntry] {
        var seen = Set<String>()
        return Array(job.previewEntries.sorted { $0.modified > $1.modified }.filter {
            seen.insert($0.path ?? $0.previewURL ?? $0.id).inserted
        }.prefix(2))
    }
    private func previews(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DEUX DERNIERS APERÇUS").font(.system(size: 10, weight: .bold)).tracking(0.8)
            HStack(alignment: .top, spacing: 8) {
                ForEach(usefulPreviews(job)) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(canvas)
                            if let image = model.thumbnail(for: entry) { Image(nsImage: image).resizable().scaledToFit() }
                            else { Text("Aperçu indisponible").font(.system(size: 11)).foregroundStyle(muted) }
                        }.frame(height: 265).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(entry.filename).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(muted)
                        Text(entry.state.rawValue).font(.system(size: 10)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity)
                }
            }
            if job.previewEntries.isEmpty { Text("Aucun aperçu pour cette version.").font(.system(size: 12)).foregroundStyle(muted).frame(height: 265) }
            Text("Aperçu décodé ≠ achèvement du rendu.").font(.system(size: 10)).foregroundStyle(muted)
        }
    }
    private func processDetails(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PROCESSUS · " + job.activityLabel).font(.system(size: 11, weight: .semibold))
            if let process = job.process {
                HStack {
                    if let ram = process.ram_mo { Text("RAM \(ram) Mo") }
                    if let cpu = process.cpu { Text("CPU " + cpu) }
                    if let elapsed = process.duree { Text("Durée " + elapsed) }
                }.font(.system(size: 12))
            }
            if let gpu = job.gpu {
                Text(String(format: "GPU %.0f %% · VRAM %.0f / %.0f Mo · %.0f °C", gpu.utilizationPercent, gpu.usedMiB, gpu.totalMiB, gpu.temperatureCelsius))
                    .font(.system(size: 12))
            }
            ForEach(job.tasks, id: \.name) { task in
                Text(task.name + " · " + task.state).font(.system(size: 11)).foregroundStyle(muted)
            }
            Text("Tâche Ready = prête/planifiée ; aucune preuve de rendu actif.").font(.system(size: 10)).foregroundStyle(muted)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(canvas, in: RoundedRectangle(cornerRadius: 10))
    }
    private func plans(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.isFresh ? "PLANS · relevé récent" : "PLANS · dernier relevé").font(.system(size: 11, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading, spacing: 8) {
            ForEach(job.plans) { plan in
                VStack(alignment: .leading, spacing: 5) {
                    Text(plan.id + (plan.team.map { " · Équipe \($0)" } ?? "")).font(.system(size: 11, weight: .semibold))
                    Text(plan.progress?.countLabel ?? "Compteur indisponible").font(.system(size: 11)).monospacedDigit()
                    if let progress = plan.progress { ProgressView(value: progress.fraction).tint(accent) }
                }.padding(10).background(canvas, in: RoundedRectangle(cornerRadius: 9))
            }
            }
        }
    }

    private func beginOrganizing(_ job: RenderDashboardJob) {
        organizingJob = job
        let current = model.catalogSnapshot.works.first { $0.jobs.contains { $0.id == job.id } }
        organizeWorkID = current?.id
        organizeWorkTitle = current?.title ?? job.workTitle ?? ""
        organizeVersionLabel = job.versionLabel ?? ""
        organizeError = ""
        showOrganize = true
    }
    private var organizationWorks: [RenderCatalogWork] {
        guard let job = organizingJob else { return [] }
        return model.catalogSnapshot.works.filter { $0.projectID == job.projectID }
    }
    private var organizeSheet: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Organiser cette version").font(.system(size: 20, weight: .semibold))
            Text(organizingJob?.title ?? "Version indisponible").font(.system(size: 12)).foregroundStyle(muted).lineLimit(3)
            Picker("Travail", selection: $organizeWorkID) {
                Text("Créer un nouveau travail").tag(String?.none)
                ForEach(organizationWorks) { Text($0.title).tag(Optional($0.id)) }
            }.pickerStyle(.menu).disabled(organizingJob?.sourceWorkID != nil)
            if organizeWorkID == nil || organizingJob?.sourceWorkID != nil {
                TextField("Nom du travail", text: $organizeWorkTitle).textFieldStyle(.roundedBorder)
            }
            TextField("Libellé de cette version (facultatif)", text: $organizeVersionLabel).textFieldStyle(.roundedBorder)
            if organizingJob?.sourceWorkID != nil {
                Text("Ce travail est identifié par la source. Vous pouvez changer son libellé local, pas son rattachement.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            Text("Les autres versions peuvent être rattachées au même travail. Les fichiers et identifiants source sont conservés.")
                .font(.system(size: 11)).foregroundStyle(muted)
            if !organizeError.isEmpty { Text(organizeError).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("Retirer l’organisation locale") {
                    guard let job = organizingJob else { return }
                    if model.setJobContext(nil, forJobID: job.id) { showOrganize = false }
                    else { organizeError = model.organizationError ?? "Ce job n’est plus disponible. Actualisez le catalogue." }
                }.buttonStyle(.link)
                Spacer()
                Button("Annuler") { showOrganize = false }
                Button("Enregistrer", action: saveOrganization).buttonStyle(.borderedProminent)
                    .disabled(organizeWorkID == nil && organizeWorkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 540).background(canvas)
            .onChange(of: organizeWorkID) {
                if let id = organizeWorkID, let work = organizationWorks.first(where: { $0.id == id }) { organizeWorkTitle = work.title }
            }
    }
    private func saveOrganization() {
        guard let job = organizingJob else { return }
        let name = organizeWorkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = organizeVersionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = model.config.jobContexts[job.id]
        let work = organizeWorkID.flatMap { id in organizationWorks.first { $0.id == id } }
        let context = RenderJobContext(projectID: existing?.projectID,
            workID: job.sourceWorkID ?? work?.id ?? "user-work:" + UUID().uuidString,
            versionID: job.sourceVersionID ?? existing?.versionID ?? job.versionID,
            workTitle: job.sourceWorkID != nil ? name : (work?.title ?? name), versionLabel: label.isEmpty ? nil : label)
        if model.setJobContext(context, forJobID: job.id) { showOrganize = false }
        else { organizeError = model.organizationError ?? "L’organisation n’a pas été enregistrée. Actualisez le catalogue puis réessayez." }
    }

    private var sourcesSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Sources suivies").font(.system(size: 20, weight: .semibold)); Spacer(); Button("Fermer") { showSources = false } }
            Text("Mac · " + model.folderHealth.label + " · " + model.folderHealth.message).font(.system(size: 12)).foregroundStyle(muted)
            Text("Shadow · " + model.remoteHealth.label).font(.system(size: 12)).foregroundStyle(muted)
            ScrollView { foldersPanel }
        }.padding(22).frame(width: 530, height: 580).background(canvas)
    }
    private var historySheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Historique · " + (selectedJob?.title ?? "version indisponible")).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Fermer") { showHistory = false }
            }
            Text(historyCoverage.isEmpty ? "Inventaire de la version sélectionnée" : historyCoverage).font(.system(size: 11)).foregroundStyle(muted)
            Text("\(historyItems.count) chargés · " + (historyKnown.map { "\($0) inventoriés" } ?? "total inventorié inconnu") + " · distinct du total de rendu")
                .font(.system(size: 10)).foregroundStyle(muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(historyItems) { entry in row(entry) }
                    if historyItems.isEmpty && !historyLoading { Text("Aucun fichier dans ce scope.").font(.system(size: 12)).foregroundStyle(muted) }
                }
            }
            HStack {
                if historyLoading { ProgressView().controlSize(.small); Text("Chargement des métadonnées…").font(.system(size: 11)) }
                Spacer()
                Button("Actualiser l’inventaire") { Task { await loadHistory(append: false) } }.disabled(historyLoading)
                if historyCursor != nil { Button("Page suivante") { Task { await loadHistory(append: true) } }.disabled(historyLoading) }
            }
        }.padding(22).frame(width: 780, height: 600).background(canvas)
            .task(id: jobID) { await loadHistory(append: false) }
    }
    private func loadHistory(append: Bool) async {
        guard let job = selectedJob else { historyItems = []; historyCursor = nil; historyCoverage = "Version indisponible"; return }
        let scope = job.id
        let generation = UUID(); historyGeneration = generation
        historyLoading = true
        if !append { historyItems = []; historyCursor = nil; historyKnown = nil; historyRevision = nil; historyCoverage = "Inventaire en cours…" }
        let page = await model.historyPage(for: job, cursor: append ? historyCursor : nil, limit: 40)
        guard !Task.isCancelled, showHistory, historyGeneration == generation, selectedJob?.id == scope else { return }
        if append, let historyRevision, historyRevision != page.snapshotRevision {
            historyLoading = false; historyCursor = nil; historyCoverage = "Catalogue modifié : actualisez cet inventaire avant de continuer."; return
        }
        var seen = Set(historyItems.map(\.id))
        let entries = page.entries.filter { seen.insert($0.id).inserted }
        historyItems += entries; historyCursor = page.nextCursor; historyKnown = page.totalKnown
        historyCoverage = page.coverage; historyRevision = page.snapshotRevision; historyLoading = false
    }

    private func row(_ entry: RenderEntry) -> some View {
        Button {
            if entry.state == .stable || entry.state == .complete,
               let url = model.openURL(for: entry), url.isFileURL {
                CatalogFolderActions.reveal(url, filename: entry.filename)
            }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(canvas)
                    if let image = model.thumbnail(for: entry) {
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: 96, height: 72)
                    } else {
                        Image(systemName: entry.fileMediaType == .video ? "film" :
                              (entry.fileMediaType == .audio ? "waveform" :
                               (entry.fileMediaType == .image ? "photo" : "cube.transparent")))
                            .font(.system(size: 18)).foregroundStyle(muted)
                    }
                }.frame(width: 96, height: 72).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.job).font(.system(size: 11, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    Text(entry.filename).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 5) {
                        Text(entry.source.rawValue)
                        Text("·")
                        Text("Fichier : " + entry.fileMediaType.rawValue)
                        Text("·")
                        Text(entry.modified.formatted(date: .omitted, time: .shortened))
                    }.font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer(minLength: 4)
                Text(entry.state.rawValue)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(entry.state == .complete ? Color.green :
                                     (entry.state == .stable ? Color.blue : Color.orange))
            }
            .padding(7)
            .background(card, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
    }

    private func folderWorkTypePicker(_ path: String) -> some View {
        Picker("Travail", selection: Binding<RenderWorkType?>(
            get: { model.config.folderWorkTypes[path] },
            set: { model.setFolderWorkType($0, path: path) }
        )) {
            Text("Non défini").tag(RenderWorkType?.none)
            ForEach(RenderWorkType.allCases, id: \.self) { type in
                Text(type.label).tag(Optional(type))
            }
        }.pickerStyle(.menu).help("Catégorie déclarée pour ce dossier, indépendante du format des fichiers")
    }

    private var foldersPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Définissez le type de travail si vous le connaissez. Toute application exportant dans un dossier choisi peut être suivie. Aucun balayage de tout le Mac ou de Shadow.")
                .foregroundStyle(muted)
            Button("Ajouter un dossier Mac…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url { model.addMacFolder(url) }
            }
            ForEach(model.config.macFolders, id: \.self) { path in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Retirer") { model.removeMacFolder(path) }.buttonStyle(.link)
                    }
                    folderWorkTypePicker(path)
                }.font(.system(size: 10))
            }
            Divider()
            Text("Shadow : indiquer le dossier exact des exports (ex. C:/renders/brut).")
                .foregroundStyle(muted)
            HStack {
                TextField("C:/.../exports", text: $shadowFolderInput)
                    .textFieldStyle(.roundedBorder)
                Button("Ajouter") {
                    folderError = !model.addShadowFolder(shadowFolderInput.trimmingCharacters(in: .whitespaces))
                    if !folderError { shadowFolderInput = "" }
                }
            }
            if folderError { Text("Chemin Shadow absolu C:/... requis, sans caractères spéciaux.")
                .foregroundStyle(.red) }
            ForEach(model.config.shadowFolders, id: \.self) { path in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Retirer") { model.removeShadowFolder(path) }.buttonStyle(.link)
                    }
                    folderWorkTypePicker(path)
                }.font(.system(size: 10))
            }
            if !model.config.shadowFolders.isEmpty {
                Text("\(model.remoteHealth.label) · \(model.remoteHealth.message)")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
        }.padding(.top, 8)
    }
}

struct DashboardProgressView: View {
    let title: String
    let count: Int?
    let progress: RenderProgress?
    let isFresh: Bool
    let activity: RenderActivity
    var compact = false
    private let accent = Color(red: 0.23, green: 0.40, blue: 0.86)
    private let warm = Color(red: 0.82, green: 0.49, blue: 0.17)
    private var measuredMotion: Bool { isFresh && activity == .running }
    private var trackInk: Color { measuredMotion ? accent : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(isFresh ? "Relevé récent" : "Dernier relevé").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let progress {
                HStack(spacing: 12) {
                    if compact { progressRing(progress).frame(width: 54, height: 54) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(progress.countLabel)
                            .font(.system(size: compact ? 21 : 25, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("Restant : \(progress.total - progress.completed)")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !compact {
                        Text(progress.percentLabel).font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit().padding(.horizontal, 9).padding(.vertical, 6)
                            .background(accent.opacity(0.10), in: Capsule())
                    }
                }
                markedRail(progress)
                if !measuredMotion {
                    Text(isFresh ? "Indicateur figé · " + activity.rawValue : "Indicateur figé · dernier relevé")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                Text(count.flatMap { $0 >= 0 ? "\($0) signalés" : nil } ?? "Compteur indisponible")
                    .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                Text("Progression et restants indéterminés · total non fourni ou incohérent")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .combine)
    }

    private func progressRing(_ progress: RenderProgress) -> some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4)
            Circle().trim(from: 0, to: progress.fraction)
                .stroke(trackInk, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(measuredMotion ? .easeOut(duration: 0.25) : nil, value: progress.fraction)
            Text(progress.percentLabel).font(.system(size: 10, weight: .semibold)).monospacedDigit()
        }.padding(3).accessibilityHidden(true)
    }

    private func markedRail(_ progress: RenderProgress) -> some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                    Capsule().fill(trackInk).frame(width: width * progress.fraction, height: 6)
                    ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                        Rectangle().fill(Color.primary.opacity(0.24)).frame(width: 1, height: 10)
                            .offset(x: width * tick)
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 3).stroke(warm, lineWidth: 1.5).frame(width: 10, height: 9).offset(x: -2, y: 2)
                        RoundedRectangle(cornerRadius: 3).stroke(accent, lineWidth: 1.5).frame(width: 10, height: 9)
                        RoundedRectangle(cornerRadius: 3).stroke(Color.primary, lineWidth: 1.5).frame(width: 10, height: 9).offset(x: 2, y: -2)
                    }.frame(width: 18, height: 18)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .offset(x: min(max(0, width - 18), max(0, width * progress.fraction - 9)))
                }.frame(height: 18)
                    .animation(measuredMotion ? .easeOut(duration: 0.25) : nil, value: progress.fraction)
            }.frame(height: 18)
            HStack { Text("0"); Spacer(); Text("25"); Spacer(); Text("50"); Spacer(); Text("75"); Spacer(); Text("100 %") }
                .font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
        }.accessibilityHidden(true)
    }
}

// UI projection is rebuilt only for a snapshot/filter change; it never parses source payloads.
enum CatalogScope: String, CaseIterable {
    case all = "Tous", direct = "Direct", history = "Historique"
    func matches(_ job: RenderDashboardJob) -> Bool {
        switch self {
        case .all: return true
        case .direct: return job.isFresh && !job.retainedHistorical && job.activity == .running
        case .history: return job.retainedHistorical || job.activity == .countsReached
        }
    }
}

struct CatalogSection: Identifiable {
    let id: String
    let title: String
    let jobs: [RenderDashboardJob]
}

struct CompactCatalogIndicator: View {
    let job: RenderDashboardJob
    private let accent = Color(red: 0.23, green: 0.40, blue: 0.86)
    private var active: Bool { job.isFresh && !job.retainedHistorical && job.activity == .running }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 2)
            if let progress = job.rawProgress {
                RoundedRectangle(cornerRadius: 8).trim(from: 0, to: progress.fraction)
                    .stroke(active ? accent : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .animation(active ? .easeOut(duration: 0.25) : nil, value: progress.fraction)
                Text(progress.percentLabel).font(.system(size: 9, weight: .semibold)).monospacedDigit()
            } else { Text("—").font(.system(size: 14, weight: .semibold)) }
        }.frame(width: 48, height: 38).accessibilityHidden(true)
    }
}

struct CompactCatalogJobRow: View {
    let job: RenderDashboardJob
    let selected: Bool
    let onOpen: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Button(action: onOpen) { CompactCatalogIndicator(job: job) }
                .buttonStyle(.plain).help("Afficher le détail").accessibilityLabel("Afficher le détail de " + job.title)
                .accessibilityValue((job.rawProgress?.percentLabel ?? "Progression indéterminée") + ", " + remainingLabel)
            VStack(alignment: .leading, spacing: 3) {
                CatalogFolderName(name: job.workTitle ?? job.title, targets: job.openTargets)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(job.versionLabel ?? job.title).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                Text(job.activityLabel + " · " + job.source.rawValue).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 5) {
                    Text((job.source == .shadowMonitor ? "Brut " : "") + (job.rawProgress?.countLabel ?? job.rawCount.flatMap { $0 >= 0 ? "\($0) détectés" : nil } ?? "Compteur indisponible"))
                    if let post = job.postProgress { Text("Post " + post.countLabel) }
                    if let progress = job.rawProgress { Text("Reste \(progress.total - progress.completed)") }
                }.font(.system(size: 10)).monospacedDigit().lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 3) {
                Text(remainingLabel).font(.system(size: 11, weight: .medium)).monospacedDigit()
                Text(job.historicalMedianSeconds.map { String(format: "≈ %.0f s / sortie", $0) } ?? "Cadence indéterminée")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                Text(job.observedAt?.formatted(date: .omitted, time: .shortened) ?? "Date inconnue").font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 9) {
                    CatalogFolderMenu(targets: job.openTargets, latest: job.latestOutput, revealURL: job.revealURL, label: "Dossiers et fichier de cette version", iconOnly: true)
                    Button(action: onOpen) { Image(systemName: "arrow.right.circle") }.buttonStyle(.plain).help("Afficher le détail de cette version")
                }
            }.frame(width: 112, alignment: .trailing)
        }.padding(.horizontal, 9).padding(.vertical, 9)
            .background(Color.primary.opacity(selected ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain)
    }
    private var remainingLabel: String {
        guard job.isFresh, !job.retainedHistorical, job.activity == .running,
              let seconds = job.estimatedRemainingSeconds, seconds.isFinite, seconds >= 0 else { return "Temps indéterminé" }
        if seconds < 60 { return String(format: "≈ %.0f s", seconds) }
        if seconds < 3600 { return String(format: "≈ %.0f min", ceil(seconds / 60)) }
        return String(format: "≈ %.0f h %.0f min", floor(seconds / 3600), ceil(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }
}

// All menu targets come from the cached media snapshot. No directory inference or stat in body.
enum CatalogFolderActions {
    static func open(_ target: RenderFolderTarget) {
        guard target.isVerified, let location = target.location, location.isFileURL else { return }
        if !NSWorkspace.shared.open(location) {
            let alert = NSAlert(); alert.messageText = "Dossier indisponible"; alert.informativeText = target.title; alert.runModal()
        }
    }
    static func copyRemote(_ target: RenderFolderTarget) {
        guard let path = target.remoteDisplay else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
    }
    static func reveal(_ location: URL, filename: String) {
        guard location.isFileURL else { return }
        // A single targeted check only after the user requests the file.
        guard FileManager.default.fileExists(atPath: location.path) else {
            let alert = NSAlert(); alert.messageText = "Ce fichier n’est plus disponible"; alert.informativeText = filename; alert.runModal(); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }

}

struct CatalogFolderMenu: View {
    let targets: [RenderFolderTarget]
    var latest: RenderEntry? = nil
    var revealURL: URL? = nil
    var label = "Dossiers / fichier"
    var iconOnly = false
    var body: some View {
        Menu {
            ForEach(targets) { target in
                if target.isVerified && target.location != nil {
                    Button { CatalogFolderActions.open(target) } label: { Label(target.title, systemImage: "folder") }
                } else if target.remoteDisplay != nil {
                    Button { CatalogFolderActions.copyRemote(target) } label: { Label(target.title + " · distant — copier le chemin", systemImage: "doc.on.doc") }
                } else { Text(target.title + " · indisponible") }
            }
            if let latest, let revealURL, revealURL.isFileURL {
                if !targets.isEmpty { Divider() }
                Button { CatalogFolderActions.reveal(revealURL, filename: latest.filename) } label: { Label("Révéler « " + latest.filename + " »", systemImage: "doc.viewfinder") }
            }
            if targets.isEmpty && revealURL == nil { Text("Aucun dossier lié disponible") }
        } label: {
            if iconOnly { Image(systemName: "folder") }
            else { Label(label, systemImage: "folder") }
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("Dossiers exacts de cette version ; fichier connu révélé dans Finder, sans lecture automatique")
            .accessibilityLabel(label)
    }
}

struct CatalogFolderName: View {
    let name: String
    let targets: [RenderFolderTarget]
    var body: some View {
        let local = targets.filter { $0.isVerified && $0.location != nil }
        if targets.count == 1, let target = local.first {
            Button { CatalogFolderActions.open(target) } label: { Text(name) }.buttonStyle(.plain)
                .help("Ouvrir le dossier : " + target.title).accessibilityLabel("Ouvrir le dossier de " + name)
        } else if !targets.isEmpty {
            Menu {
                ForEach(targets) { target in
                    if target.isVerified && target.location != nil {
                        Button(target.title) { CatalogFolderActions.open(target) }
                    } else if target.remoteDisplay != nil {
                        Button(target.title + " · distant — copier le chemin") { CatalogFolderActions.copyRemote(target) }
                    } else { Text(target.title + " · indisponible") }
                }
            } label: { Text(name) }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                .help("Choisir un dossier exact lié à " + name)
        } else { Text(name).help("Aucun dossier lié ; utilisez l’accès au détail") }
    }
}
