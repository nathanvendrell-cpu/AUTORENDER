import AppKit
import SwiftUI
struct SourcesView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.dismiss) private var dismiss
    @State private var shadowFolderInput = ""
    @State private var folderError = false
    @State private var nativeAssociationMessage = ""
    private var nativeCandidates: [RenderDashboardJob] { NativeSourcesPresentation.candidates(model.catalogSnapshot.jobs) }
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Sources suivies").font(.system(size: 20, weight: .semibold)); Spacer(); Button("Fermer") { dismiss() } }
            if let error = model.configurationError { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            Text("Mac · " + model.folderHealth.label + " · " + model.folderHealth.message).font(.system(size: 12)).foregroundStyle(muted)
            Text("Shadow · " + model.remoteHealth.label).font(.system(size: 12)).foregroundStyle(muted)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nativeSourcesPanel
                    Divider()
                    foldersPanel
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(22).frame(width: 620, height: 680).preferredColorScheme(.light).renderGlass()
    }
    private var nativeSourcesPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Découverte et sources à confirmer").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Actualiser") { model.refreshLocalDiscovery() }.buttonStyle(.bordered)
            }
            Text("Observation des processus · " + model.nativeHealth.label)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(muted)
            Text(model.nativeHealth.message).font(.system(size: 11)).foregroundStyle(muted).textSelection(.enabled)
            if let date = model.nativeHealth.checkedAt ?? model.nativeHealth.observedAt {
                Text("Contrôle : " + date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            if let issue = model.registryDiscoveryError {
                Label("Registre local : " + issue, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Un processus présent ne prouve pas un rendu actif. Les compteurs et le total restent indéterminés sans métadonnées attribuées.")
                .font(.system(size: 11)).foregroundStyle(muted)
            Text("\(nativeCandidates.count) observations dans le catalogue")
                .font(.system(size: 11, weight: .semibold))
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(nativeCandidates) { job in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(job.versionLabel ?? job.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(NativeSourcesPresentation.status(job)).font(.system(size: 11)).foregroundStyle(muted)
                        Text("Relevé : " + (job.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "date inconnue"))
                            .font(.system(size: 10)).foregroundStyle(muted)
                        if NativeSourcesPresentation.needsOutputFolder(job), job.id.hasPrefix("mac:native:") {
                            Text("Dossier de sortie non associé").font(.system(size: 11)).foregroundStyle(muted)
                            Button("Associer un dossier de sortie…") { associateNativeFolder(job) }
                                .buttonStyle(.bordered).disabled(model.nativeProcessIdentity(forJobID: job.id) == nil)
                        } else {
                            CatalogFolderMenu(targets: job.openTargets, latest: job.latestOutput, revealURL: job.revealURL, label: "Dossier de sortie")
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 12, shadow: 2)
                }
            }
            if nativeCandidates.isEmpty {
                Text("Aucun candidat observé dans le catalogue. Vérifiez le dernier contrôle et la couverture de la source.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            if !nativeAssociationMessage.isEmpty {
                Text(nativeAssociationMessage).font(.system(size: 11)).foregroundStyle(muted)
            }
        }
    }
    private func associateNativeFolder(_ job: RenderDashboardJob) {
        guard model.nativeProcessIdentity(forJobID: job.id) != nil else {
            nativeAssociationMessage = "Ce processus n’est plus observé. Actualisez la découverte locale."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        panel.prompt = "Associer"
        panel.message = "Choisissez le dossier exact des sorties de ce processus. Cette association ne déclare ni activité, ni total."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        nativeAssociationMessage = model.setNativeRunOutputFolder(url, forJobID: job.id)
            ? "Dossier associé. L’observation locale actualise ses données."
            : "Association indisponible. Vérifiez les préférences et actualisez la découverte locale."
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
    }}


enum NativeSourcesPresentation {
    static func candidates(_ jobs: [RenderDashboardJob]) -> [RenderDashboardJob] {
        jobs.filter { $0.id.hasPrefix("mac:native:") || CatalogScope.dashboardScope(for: $0) == nil }.sorted { lhs, rhs in
            let leftHistorical = !lhs.isFresh || lhs.retainedHistorical
            let rightHistorical = !rhs.isFresh || rhs.retainedHistorical
            if leftHistorical != rightHistorical { return !leftHistorical }
            let leftDate = lhs.observedAt ?? .distantPast, rightDate = rhs.observedAt ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.id < rhs.id
        }
    }
    static func status(_ job: RenderDashboardJob) -> String {
        guard job.isFresh, !job.retainedHistorical else { return "Dernier relevé · activité actuelle non attestée" }
        return job.activity == .unknown || (job.activity == .running && !job.isDetectedActiveRender) ? "Activité à confirmer · tâche non qualifiée" : RenderStatus.label(job)
    }
    static func needsOutputFolder(_ job: RenderDashboardJob) -> Bool { job.openTargets.isEmpty }
}
