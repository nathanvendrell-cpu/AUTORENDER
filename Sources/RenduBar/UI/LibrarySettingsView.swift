import AppKit
import SwiftUI

extension RenderLibraryState {
    var displayTitle: String {
        switch self {
        case .inMemory: return "En mémoire · aucun fichier confirmé"
        case .needsClassification: return "À classer"
        case .previewOnly: return "Aperçu uniquement"
        case .awaitingTransfer: return "En attente de transfert"
        case .ready: return "Prêt"
        case .moved: return "Déplacé et vérifié"
        case .copiedSourceKept: return "Copié · source conservée"
        case .conflict: return "Conflit à résoudre"
        case .undone: return "Opération annulée"
        case .failed: return "Opération non confirmée"
        }
    }
}

struct LibrarySettingsView: View {
    @ObservedObject var model: MonitorModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: RenderLibraryMode = .catalogueOnly
    @State private var root = ""
    @State private var approveFuture = false
    @State private var message = ""
    @State private var page = 0
    @State private var selected = Set<String>()
    @State private var plans: [RenderLibraryPlan] = []
    @State private var allowLegacy = false
    @State private var allowLocalMove = false
    @State private var confirmBatch = false
    @State private var editingBinding: RenderProjectBinding?
    @State private var undoRecord: RenderLibraryRecord?
    @State private var working = false
    @State private var operation: Task<Void, Never>?
    @State private var jobTitles: [String: String] = [:]
    private var records: [RenderLibraryRecord] { model.libraryRecords }
    private var eligiblePlans: Bool {
        !plans.isEmpty && plans.count <= 200 && plans.allSatisfy {
            $0.target != nil && ($0.state == .ready || (allowLegacy && $0.state == .previewOnly))
                && ($0.candidate.originalRemotePath != nil || allowLocalMove)
        }
    }
    var body: some View { dialogLayout }
    private var baseLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Bibliothèque et classement").font(.system(size: 21, weight: .semibold, design: .rounded))
                Spacer()
                Button("Terminer") { dismiss() }.disabled(working || model.libraryBusy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    configuration
                    if let bindings = model.config.projectBindings, !bindings.isEmpty {
                        Text("PROJETS LIÉS").font(.system(size: 11, weight: .bold)).tracking(1)
                        ForEach(bindings) { binding in
                            HStack {
                                Text(binding.title).font(.system(size: 12, weight: .semibold))
                                Text("\(binding.roots.count) racine(s)").font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                                Spacer()
                                Button("Corriger…") { editingBinding = binding }.disabled(model.libraryBusy || working)
                            }.padding(10).renderGlass(radius: 12, shadow: 2)
                        }
                    }
                    if !model.libraryActivities.isEmpty {
                        Text("ÉTAT DES RENDUS").font(.system(size: 11, weight: .bold)).tracking(1)
                        ForEach(Array(model.libraryActivities.prefix(200))) { activity in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(jobTitles[activity.id] ?? "Rendu suivi").font(.system(size: 12, weight: .semibold))
                                Text(activity.state.displayTitle).font(.system(size: 11))
                                Text(activity.detail).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 12, shadow: 2)
                        }
                    }
                    journal
                    if !plans.isEmpty { preview }
                }.padding(2)
            }
            if model.libraryBusy || working { ProgressView("Opération en cours…").controlSize(.small) }
            if let error = model.libraryError { Text(error).font(.system(size: 11)).foregroundStyle(.orange) }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary) }
        }.padding(22).frame(width: 760).frame(minHeight: 480, idealHeight: 660, maxHeight: 740).foregroundStyle(RenderStyle.ink).renderWindowSurface()
    }
    private var lifecycleLayout: some View {
        baseLayout.interactiveDismissDisabled(model.libraryBusy || working)
            .onAppear {
                mode = model.librarySettings.mode; root = model.librarySettings.rootPath
                refreshTitles()
                operation = Task { await model.reloadLibraryRecords(); refreshTitles() }
            }
            .onChange(of: model.historyRevision) { refreshTitles() }
            .onChange(of: model.libraryRecords.map(\.id)) { refreshTitles(); selected.formIntersection(Set(records.map(\.id))) }
            .onDisappear { operation?.cancel() }
            .sheet(item: $editingBinding) { ProjectBindingEditor(model: model, binding: $0) }
    }
    private var dialogLayout: some View {
        lifecycleLayout.confirmationDialog("Valider ce lot exact de \(plans.count) fichiers ?", isPresented: $confirmBatch, titleVisibility: .visible) {
                Button("Valider les fichiers listés") { applyPlans() }
            } message: { Text("Les sources, destinations et autorisations ci-dessus définissent ce lot. Les fichiers seront revérifiés avant l’opération.") }
            .confirmationDialog("Annuler cette opération ?", isPresented: Binding(get: { undoRecord != nil }, set: { if !$0 { undoRecord = nil } }), titleVisibility: .visible) {
                if let record = undoRecord {
                    Button("Annuler cette opération uniquement") {
                        working = true
                        operation = Task {
                            let success = await model.undoLibraryRecord(record.id, approvedRecordID: record.id)
                            message = success ? "Annulation confirmée dans le journal." : "Annulation non confirmée. Consultez le journal."
                            working = false; undoRecord = nil
                        }
                    }
                }
            } message: {
                if let record = undoRecord { Text("Source : \(record.plan.candidate.originalRemotePath ?? record.plan.candidate.localFile.path)\nDestination : \(record.plan.target?.path ?? "non renseignée")\nRetour : \(record.remoteReturn?.originalPath ?? record.returnPath?.path ?? record.plan.candidate.localFile.path)") }
            }
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $mode) { ForEach(RenderLibraryMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text(mode == .catalogueOnly
                 ? "Détection et classement dans AUTORENDER, avec liens vers les fichiers existants. Les fichiers restent à leur emplacement."
                 : "Même catalogue, avec classement physique des sorties finalisées dans le dossier choisi, journal et annulation.")
                .font(.system(size: 12)).foregroundStyle(RenderStyle.secondary)
            if mode == .managedLibrary {
                HStack {
                    TextField("Dossier de bibliothèque", text: $root).textFieldStyle(.roundedBorder)
                    Button("Choisir…") { chooseRoot() }
                }
                Toggle("Activer ce classement pour les rendus démarrés après l’activation", isOn: $approveFuture).font(.system(size: 12))
                Text("Les anciens médias restent en place. Leur traitement nécessite un aperçu et une validation du lot exact.").font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            }
            HStack {
                Button(mode == .managedLibrary ? "Activer pour les nouveaux rendus" : "Enregistrer ce mode") {
                    if model.setLibraryMode(mode, rootPath: root, manageFutureJobs: approveFuture) {
                        approveFuture = false; message = "Choix enregistré. Le journal indique les opérations réellement confirmées."
                    } else { message = model.libraryError ?? model.configurationError ?? "Choix non enregistré." }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.libraryBusy || working || (mode == .managedLibrary && (!approveFuture || root.isEmpty)))
                if let date = model.librarySettings.activatedAt { Text("Activation : " + date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(RenderStyle.secondary) }
            }
            Toggle("Autoriser l’enregistrement des futurs Render Result de Blender", isOn: Binding(
                get: { model.librarySettings.exportInMemory == true },
                set: { if !model.setInMemoryExportEnabled($0) { message = "Choix d’export non enregistré." } }))
                .font(.system(size: 12)).disabled(model.libraryBusy || working)
            Text("L’export en mémoire et le transfert PC restent indiqués comme en attente tant que leurs preuves ne sont pas confirmées.").font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
        }.padding(14).renderGlass()
    }
    private var journal: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("OPÉRATIONS PAR FICHIER").font(.system(size: 11, weight: .bold)).tracking(1)
                Spacer()
                Button("Actualiser le journal") { operation = Task { await model.reloadLibraryRecords() } }.disabled(model.libraryBusy || working)
            }
            Text("\(records.count) opérations récentes chargées. L’état d’un fichier ne vaut pas achèvement du rendu entier.").font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            if records.isEmpty { Text("Aucune opération confirmée dans ce journal.").font(.system(size: 12)).foregroundStyle(RenderStyle.secondary) }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(records.dropFirst(page * 50).prefix(50))) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle(isOn: Binding(get: { selected.contains(record.id) }, set: { if $0 { selected.insert(record.id) } else { selected.remove(record.id) } })) {
                            Text(record.contextJob?.versionLabel ?? jobTitles[record.plan.candidate.jobID] ?? record.plan.candidate.localFile.lastPathComponent)
                                .font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        }
                        Text(record.state.displayTitle + " · " + record.at.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11))
                        Text(record.detail).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
                        Text("Type : \(record.plan.candidate.type) · \(record.plan.candidate.take)").font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                        if record.state == .moved || record.state == .copiedSourceKept {
                            Button("Annuler cette opération…") { undoRecord = record }.font(.system(size: 11)).disabled(model.libraryBusy || working)
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 12, shadow: 2)
                }
            }
            HStack {
                Button("Précédent") { page -= 1 }.disabled(page == 0)
                Text("\(min(page * 50 + 1, records.count))–\(min((page + 1) * 50, records.count)) / \(records.count)").font(.system(size: 10)).monospacedDigit()
                Button("Suivant") { page += 1 }.disabled((page + 1) * 50 >= records.count)
                Spacer()
                Button("Aperçu de la sélection (\(selected.count))") { previewSelection() }.disabled(selected.isEmpty || selected.count > 200 || model.libraryBusy || working)
            }.font(.system(size: 11))
        }
    }
    private var preview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("APERÇU DU LOT · \(plans.count) FICHIERS").font(.system(size: 11, weight: .bold)).tracking(1)
            ForEach(plans, id: \.id) { plan in
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.candidate.localFile.lastPathComponent).font(.system(size: 12, weight: .semibold))
                    Text("Source : " + (plan.candidate.originalRemotePath ?? plan.candidate.localFile.path))
                    Text("Destination : " + (plan.target?.path ?? "Non confirmée"))
                    Text(plan.state.displayTitle + " · " + plan.reason).foregroundStyle(RenderStyle.secondary)
                }.font(.system(size: 10)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 12, shadow: 2)
            }
            Toggle("Inclure ces fichiers antérieurs à l’activation", isOn: $allowLegacy).font(.system(size: 12))
            Toggle("Autoriser le déplacement des sources locales listées", isOn: $allowLocalMove).font(.system(size: 12))
            Text("Les copies dont la source est conservée restent signalées comme telles. La disponibilité du retour est vérifiée lors de l’annulation.").font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            Button("Valider ce lot exact…") { confirmBatch = true }.buttonStyle(.borderedProminent).disabled(!eligiblePlans || model.libraryBusy || working)
        }.padding(14).renderGlass()
    }
    private func previewSelection() {
        var seen = Set<String>()
        let candidates = records.filter { selected.contains($0.id) }.map(\.plan.candidate).filter { seen.insert($0.id).inserted }
        guard !candidates.isEmpty, candidates.count <= 200 else { return }
        allowLegacy = false; allowLocalMove = false; working = true
        operation = Task { plans = await model.previewLibraryBatch(candidates); working = false }
    }
    private func applyPlans() {
        guard eligiblePlans else { return }
        let exact = plans, approval = RenderLibraryApproval(planIDs: Set(plans.map(\.id)), allowLegacy: allowLegacy, allowLocalMove: allowLocalMove)
        working = true
        operation = Task {
            let result = await model.applyLibraryBatch(exact, approval: approval)
            message = "\(result.count) opération(s) retournée(s). Consultez leurs états réels dans le journal."
            plans = []; selected = []; working = false
        }
    }
    private func chooseRoot() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url { root = url.path }
    }
    private func refreshTitles() {
        let wanted = Set(model.libraryActivities.map(\.id) + records.map { $0.plan.candidate.jobID })
        jobTitles = Dictionary(model.catalogSnapshot.jobs.filter { wanted.contains($0.id) }.map { ($0.id, $0.versionLabel ?? $0.title) }, uniquingKeysWith: { first, _ in first })
        page = min(page, max(0, (records.count - 1) / 50))
    }
}
