import SwiftUI
struct JobDetailView: View {
    @ObservedObject var model: MonitorModel
    let job: RenderDashboardJob
    @StateObject private var preview = PreviewPresentationStore()
    let onOrganize: (RenderDashboardJob) -> Void
    let onHistory: () -> Void
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                CatalogFolderName(name: job.versionLabel ?? job.title, targets: job.openTargets)
                    .font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(job.source.rawValue + " · " + (job.workType?.label ?? "Type à préciser"))
                    .font(.system(size: 12)).foregroundStyle(muted)
                Text("Relevé : " + (job.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "date indisponible"))
                    .font(.system(size: 11)).foregroundStyle(muted)
                Text(RenderStatus.label(job)).font(.system(size: 12, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(activityColor(job).opacity(0.12), in: Capsule()).foregroundStyle(activityColor(job))
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { folderAction; archiveAction; organizeAction }
                VStack(alignment: .leading, spacing: 8) { folderAction; HStack { archiveAction; organizeAction } }
            }
            if job.workType == nil {
                Button("Préciser le type du travail") { onOrganize(job) }.buttonStyle(.link).font(.system(size: 12))
            }
            if !job.isFresh || job.retainedHistorical {
                Text("Dernier relevé conservé. L’activité actuelle et la fin estimée ne sont pas attestées.")
                    .font(.system(size: 12)).foregroundStyle(muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .top)], alignment: .leading, spacing: 12) {
                DashboardProgressView(title: job.source == .shadowMonitor ? "Images brutes" : (job.source == .macMonitor ? "Images comptées" : "Fichiers détectés"), count: job.rawCount, progress: job.rawProgress, isFresh: job.isFresh && !job.retainedHistorical, activity: job.activity, compact: true)
                if job.source == .shadowMonitor || job.postCount != nil {
                    DashboardProgressView(title: "Images post", count: job.postCount, progress: job.postProgress, isFresh: job.isFresh && !job.retainedHistorical, activity: job.activity, compact: true)
                }
            }
            if job.isFresh, !job.retainedHistorical, job.activity == .running, let eta = job.eta {
                metric("Fin estimée au rythme mesuré", value: eta.formatted(date: .abbreviated, time: .shortened), detail: "Source récente · processus actif · total déclaré")
            }
            previews(job)
            HStack {
                Text("Exports de cette version").font(.system(size: 12)).foregroundStyle(muted)
                Spacer()
                Button("Historique des exports") { onHistory() }.buttonStyle(.bordered)
            }
            if !job.plans.isEmpty { plans(job) }
            DisclosureGroup("Diagnostic de la source et mesures historiques") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], spacing: 12) {
                        metric("Intervalle historique médian", value: job.historicalMedianSeconds.map(duration) ?? "Indisponible", detail: "Entre sorties horodatées · échantillon API")
                        metric("Débit historique", value: job.sampledOutputsLastHour.map { "\($0) sorties / h" } ?? "Indisponible", detail: "Échantillon borné, heure avant le relevé")
                    }
                    if let stage = job.stageDescription { metric("Détails / réglages source", value: stage, detail: "Spécifications fournies ; aucune étape courante inférée") }
                    processDetails(job)
                    if let provenance = job.totalProvenance {
                        Text("Total déclaré : " + provenance).font(.system(size: 11)).foregroundStyle(muted).textSelection(.enabled)
                    }
                    Text(job.contextProvenance).font(.system(size: 11)).foregroundStyle(muted).textSelection(.enabled)
                }.padding(.top, 10)
            }.font(.system(size: 12)).foregroundStyle(muted)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 24)
            .task(id: preview.requestID) { model.setVisiblePreviewEntries(preview.entries) }
            .onAppear { preview.rebuild(job) }
            .onChange(of: job.previewEntries) { preview.rebuild(job) }
            .onChange(of: job.id) { preview.rebuild(job) }
            .onDisappear { model.setVisiblePreviewEntries([]) }
    }
    private var folderAction: some View {
        CatalogFolderMenu(targets: job.openTargets, latest: job.latestOutput, revealURL: job.revealURL)
    }
    private var archiveAction: some View {
        Button(model.config.jobArchives[job.id] != nil ? "Restaurer" : "Archiver") { model.setJobArchived(model.config.jobArchives[job.id] == nil, forJobID: job.id) }
            .disabled(model.config.jobArchives[job.id] == nil && !job.canArchive).buttonStyle(.bordered)
    }
    private var organizeAction: some View {
        Button("Organiser") { onOrganize(job) }.buttonStyle(.bordered)
    }

    private func activityColor(_ job: RenderDashboardJob) -> Color {
        guard job.isFresh, !job.retainedHistorical else { return .orange }
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
            .renderGlass(radius: 10, shadow: 2)
    }
    private func previews(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("DERNIERS APERÇUS").font(.system(size: 10, weight: .bold)).tracking(0.8); Spacer(); Button("Réessayer") { model.retryVisiblePreviews() }.buttonStyle(.link).font(.system(size: 11)) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(preview.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(.clear)
                            if let image = model.thumbnail(for: entry) { Image(nsImage: image).resizable().scaledToFit() }
                            else { Text(model.previewStatus(for: entry).label).font(.system(size: 11)).foregroundStyle(muted) }
                        }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 10))
                        Text(entry.filename).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(entry.modified.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(muted)
                        Text(entry.state.rawValue).font(.system(size: 10)).foregroundStyle(muted)
                    }.frame(maxWidth: .infinity)
                }
            }
            if preview.entries.isEmpty { Text("Aucun aperçu pour cette version. Consultez les dossiers ou l’historique des exports.").font(.system(size: 12)).foregroundStyle(muted).frame(minHeight: 72) }
        }
    }
    private func processDetails(_ job: RenderDashboardJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIVITÉ · " + RenderStatus.label(job)).font(.system(size: 11, weight: .semibold))
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
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 10, shadow: 2)
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
                }.padding(10).renderGlass(radius: 9, shadow: 2)
            }
            }
        }
    }

}

@MainActor
final class PreviewPresentationStore: ObservableObject {
    @Published private(set) var requestID = ""
    @Published private(set) var entries: [RenderEntry] = []
    func rebuild(_ job: RenderDashboardJob) {
        var seen = Set<String>()
        let selected = Array(job.previewEntries.sorted { $0.modified > $1.modified }.filter {
            seen.insert($0.path ?? $0.previewURL ?? $0.id).inserted
        }.prefix(2))
        let identity = job.id + "|" + RenderPreviewRequest.fingerprint(entries: selected)
        if entries != selected { entries = selected }
        if identity != requestID { requestID = identity }
    }
}
