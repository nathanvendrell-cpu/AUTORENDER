import SwiftUI
struct OrganisationView: View {
    @ObservedObject var model: MonitorModel
    let organizingJob: RenderDashboardJob
    @Environment(\.dismiss) private var dismiss
    @State private var organizeWorkID: String?
    @State private var organizeWorkTitle: String
    @State private var organizeVersionLabel: String
    @State private var organizeError = ""
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    init(model: MonitorModel, job: RenderDashboardJob) {
        self.model = model; organizingJob = job
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
            Text("Les autres versions peuvent être rattachées au même travail. Les fichiers et identifiants source sont conservés.")
                .font(.system(size: 11)).foregroundStyle(muted)
            if !organizeError.isEmpty { Text(organizeError).font(.system(size: 11)).foregroundStyle(.orange) }
            HStack {
                Button("Retirer l’organisation locale") {
                    let job = organizingJob
                    if model.setJobContext(nil, forJobID: job.id) { dismiss() }
                    else { organizeError = model.organizationError ?? "Ce job n’est plus disponible. Actualisez le catalogue." }
                }.buttonStyle(.link)
                Spacer()
                Button("Annuler") { dismiss() }
                Button("Enregistrer", action: saveOrganization).buttonStyle(.borderedProminent)
                    .disabled(organizeWorkID == nil && organizeWorkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(22).frame(width: 540).preferredColorScheme(.light).renderGlass()
            .onChange(of: organizeWorkID) {
                if let id = organizeWorkID, let work = organizationWorks.first(where: { $0.id == id }) { organizeWorkTitle = work.title }
            }
    }
    private func saveOrganization() {
        let job = organizingJob
        let name = organizeWorkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = organizeVersionLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = model.config.jobContexts[job.id]
        let work = organizeWorkID.flatMap { id in organizationWorks.first { $0.id == id } }
        let context = RenderJobContext(projectID: existing?.projectID,
            workID: job.sourceWorkID ?? work?.id ?? "user-work:" + UUID().uuidString,
            versionID: job.sourceVersionID ?? existing?.versionID ?? job.versionID,
            workTitle: job.sourceWorkID != nil ? name : (work?.title ?? name), versionLabel: label.isEmpty ? nil : label)
        if model.setJobContext(context, forJobID: job.id) { dismiss() }
        else { organizeError = model.organizationError ?? "L’organisation n’a pas été enregistrée. Actualisez le catalogue puis réessayez." }
    }

}
