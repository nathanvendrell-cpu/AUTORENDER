import SwiftUI
struct OrganisationView: View {
    @ObservedObject var model: MonitorModel
    let organizingJob: RenderDashboardJob
    @Environment(\.dismiss) private var dismiss
    @State private var organizeWorkID: String?
    @State private var organizeWorkTitle: String
    @State private var organizeVersionLabel: String
    @State private var organizeError = ""
    @State private var projectID: String
    @State private var projectTitle: String
    @State private var subprojectID: String
    @State private var subprojectTitle: String
    @State private var sceneID: String
    @State private var sceneTitle: String
    @State private var libraryVersion: String
    @State private var bindRoot = false
    @State private var applyRule = false
    private let ruleID: String
    @State private var rootPath: String
    private let newProjectID: String
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    init(model: MonitorModel, job: RenderDashboardJob) {
        self.model = model; organizingJob = job
        let prior = model.config.jobContexts[job.id]
        newProjectID = "user-project:" + UUID().uuidString
        ruleID = "user-rule:" + UUID().uuidString
        _projectID = State(initialValue: prior?.projectID ?? (job.hasVerifiedProjectContext == true ? job.projectID : ""))
        _projectTitle = State(initialValue: prior?.projectTitle ?? (job.hasVerifiedProjectContext == true ? job.projectTitle ?? "" : ""))
        _subprojectID = State(initialValue: prior?.subprojectID ?? job.subprojectID ?? "user-subproject:" + UUID().uuidString)
        _subprojectTitle = State(initialValue: prior?.subprojectTitle ?? job.subprojectTitle ?? "")
        _sceneID = State(initialValue: prior?.sceneID ?? job.sceneID ?? "user-scene:" + UUID().uuidString)
        _sceneTitle = State(initialValue: prior?.sceneTitle ?? job.sceneTitle ?? job.sourceContext?.sceneName ?? "")
        _libraryVersion = State(initialValue: prior?.libraryVersion ?? job.libraryVersion ?? "")
        let sourcePath = job.sourceContext?.filePath ?? job.sourceContext?.scriptPath ?? ""
        _rootPath = State(initialValue: sourcePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").dropLast().joined(separator: "/"))
        if sourcePath.hasPrefix("/") { _rootPath = State(initialValue: "/" + sourcePath.split(separator: "/").dropLast().joined(separator: "/")) }

        let work = model.catalogSnapshot.works.first { $0.jobs.contains { $0.id == job.id } }
        _organizeWorkID = State(initialValue: work?.id)
        _organizeWorkTitle = State(initialValue: work?.title ?? job.workTitle ?? "")
        _organizeVersionLabel = State(initialValue: job.versionLabel ?? "")
    }
    private var organizationWorks: [RenderCatalogWork] {
        let job = organizingJob
        return model.catalogSnapshot.works.filter { $0.projectID == job.projectID }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Organiser cette version").font(.system(size: 20, weight: .semibold))
            Text(organizingJob.title).font(.system(size: 12)).foregroundStyle(muted).lineLimit(3)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) { classificationFields }
            }.frame(minHeight: 280, idealHeight: 420, maxHeight: 500)
            HStack {
                Button("Retirer l’organisation locale") {
                    let job = organizingJob
                    if model.setJobContext(nil, forJobID: job.id) { dismiss() }
                    else { organizeError = model.organizationError ?? "Ce job n’est plus disponible. Actualisez le catalogue." }
                }.buttonStyle(.link)
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer", action: saveOrganization).buttonStyle(.borderedProminent)
                    .disabled(model.libraryBusy || projectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 580).preferredColorScheme(.light).renderGlass()
            .onChange(of: projectID) {
                if let project = (model.config.projectBindings ?? []).first(where: { $0.id == projectID }) { projectTitle = project.title }
            }
            .onChange(of: organizeWorkID) {
                if let id = organizeWorkID, let work = organizationWorks.first(where: { $0.id == id }) { organizeWorkTitle = work.title }
            }
    }
    @ViewBuilder private var classificationFields: some View {
            Text("Projet → sous-projet → scène → déclinaison/version").font(.system(size: 11)).foregroundStyle(muted)
            Picker("Projet lié", selection: $projectID) {
                Text("Créer un projet distinct").tag("")
                ForEach(model.config.projectBindings ?? []) { Text($0.title).tag($0.id) }
                if !projectID.isEmpty, !(model.config.projectBindings ?? []).contains(where: { $0.id == projectID }) {
                    Text(projectTitle.isEmpty ? "Projet actuel" : projectTitle).tag(projectID)
                }
            }.pickerStyle(.menu)
            TextField("Nom du projet", text: $projectTitle).textFieldStyle(.roundedBorder)
            TextField("Sous-projet (facultatif)", text: $subprojectTitle).textFieldStyle(.roundedBorder)
            TextField("Scène", text: $sceneTitle).textFieldStyle(.roundedBorder)
            TextField("Version normalisée, par exemple v050", text: $libraryVersion).textFieldStyle(.roundedBorder)
            if organizingJob.sourceContext?.namespace != nil {
                Toggle("Lier aussi cette racine au projet pour les prochains rendus", isOn: $bindRoot).font(.system(size: 11))
                Toggle("Réutiliser ce sous-projet et cette scène pour ce fichier", isOn: $applyRule).font(.system(size: 11))
                if bindRoot || applyRule {
                    TextField("Racine de cette source", text: $rootPath).textFieldStyle(.roundedBorder)
                    Text("Règle limitée à cette source, cette racine, la base du fichier et la scène native. Les versions restent lues séparément.").font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            Text(organizingJob.contextProvenance).font(.system(size: 10)).foregroundStyle(muted).lineLimit(3)
            Picker("Travail", selection: $organizeWorkID) {
                Text("Créer un nouveau travail").tag(String?.none)
                ForEach(organizationWorks) { Text($0.title).tag(Optional($0.id)) }
            }.pickerStyle(.menu).disabled(organizingJob.sourceWorkID != nil)
            if organizeWorkID == nil || organizingJob.sourceWorkID != nil {
                TextField("Nom du travail", text: $organizeWorkTitle).textFieldStyle(.roundedBorder)
            }
            TextField("Libellé de cette version (facultatif)", text: $organizeVersionLabel).textFieldStyle(.roundedBorder)
            if organizingJob.sourceWorkID != nil {
                Text("Ce travail est identifié par la source. Vous pouvez changer son libellé local, pas son rattachement.")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            Text("Les identifiants stables et les médias sont conservés. Le classement de cette version et les liaisons choisies sont enregistrés séparément.")
                .font(.system(size: 11)).foregroundStyle(muted)
            if !organizeError.isEmpty { Text(organizeError).font(.system(size: 11)).foregroundStyle(.orange) }
    }
    private func saveOrganization() {
        let job = organizingJob
        let name = organizeWorkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = organizeVersionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = model.config.jobContexts[job.id]
        let work = organizeWorkID.flatMap { id in organizationWorks.first { $0.id == id } }
        let chosenProject = projectID.isEmpty ? newProjectID : projectID
        let cleanProject = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubproject = subprojectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanScene = sceneTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionText = libraryVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard versionText.isEmpty || RenderVersionToken.version(versionText) != nil else { organizeError = "Version attendue au format v050."; return }
        if bindRoot {
            guard let namespace = job.sourceContext?.namespace, let root = RenderContextPath.absolute(rootPath) else {
                organizeError = "Source et racine absolue nécessaires pour lier les prochains rendus."; return
            }
            var bindings = model.config.projectBindings ?? []
            let newRoot = RenderProjectRoot(path: root, namespace: namespace)
            if let index = bindings.firstIndex(where: { $0.id == chosenProject }) {
                bindings[index].title = cleanProject
                if !bindings[index].roots.contains(newRoot) { bindings[index].roots.append(newRoot) }
            } else { bindings.append(RenderProjectBinding(id: chosenProject, title: cleanProject, roots: [newRoot])) }
            guard model.setProjectBindings(bindings) else { organizeError = model.organizationError ?? "Liaison non enregistrée."; return }
        }
        let context = RenderJobContext(projectID: chosenProject, projectTitle: cleanProject,
            subprojectID: cleanSubproject.isEmpty ? nil : subprojectID, subprojectTitle: cleanSubproject.isEmpty ? nil : cleanSubproject,
            sceneID: sceneID, sceneTitle: cleanScene, libraryVersion: RenderVersionToken.version(versionText),
            workID: job.sourceWorkID ?? work?.id ?? "user-work:" + UUID().uuidString,
            versionID: job.sourceVersionID ?? existing?.versionID ?? job.versionID,
            workTitle: job.sourceWorkID != nil ? name : (work?.title ?? name), versionLabel: label.isEmpty ? nil : label)
        if applyRule {
            guard let source = job.sourceContext, let namespace = source.namespace,
                  let root = RenderContextPath.absolute(rootPath), let file = source.filePath ?? source.scriptPath else {
                organizeError = "Source, racine et fichier attestés nécessaires à la règle."; return
            }
            let future = RenderJobContext(projectID: chosenProject, projectTitle: cleanProject,
                subprojectID: cleanSubproject.isEmpty ? nil : subprojectID, subprojectTitle: cleanSubproject.isEmpty ? nil : cleanSubproject,
                sceneID: sceneID, sceneTitle: cleanScene, libraryVersion: nil, workID: nil, versionID: nil, workTitle: nil, versionLabel: nil)
            let rule = RenderContextRule(id: ruleID, rootPath: root, namespace: namespace, nativeSceneName: source.sceneName,
                context: future, canonicalFileBase: RenderVersionToken.parse(RenderContextPath.leaf(file)).base)
            var rules = model.config.contextRules ?? []
            if let index = rules.firstIndex(where: { $0.id == ruleID }) { rules[index] = rule } else { rules.append(rule) }
            guard model.setContextRules(rules) else { organizeError = model.organizationError ?? "Règle non enregistrée ; les liaisons déjà enregistrées sont conservées."; return }
        }
        if model.setJobContext(context, forJobID: job.id) { dismiss() }
        else { organizeError = model.organizationError ?? "L’organisation n’a pas été enregistrée. Actualisez le catalogue puis réessayez." }
    }

}
