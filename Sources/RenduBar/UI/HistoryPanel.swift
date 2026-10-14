import SwiftUI
struct HistoryPanel: View {
    @ObservedObject var model: MonitorModel
    let job: RenderDashboardJob
    @StateObject private var history = HistoryController()
    @Environment(\.dismiss) private var dismiss
    private let ink = RenderStyle.ink
    private let muted = RenderStyle.secondary
    private let accent = RenderStyle.blue
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Historique · " + (job.title)).font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("Fermer") { dismiss() }
            }
            Text(history.coverage.isEmpty ? "Inventaire de la version sélectionnée" : history.coverage).font(.system(size: 11)).foregroundStyle(muted)
            Text("\(history.items.count) sur cette page · " + (history.known.map { "\($0) inventoriés" } ?? "total inventorié inconnu") + " · distinct du total de rendu")
                .font(.system(size: 10)).foregroundStyle(muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(history.items) { entry in row(entry) }
                    if history.items.isEmpty && !history.loading { Text("Aucun fichier dans ce scope.").font(.system(size: 12)).foregroundStyle(muted) }
                }
            }
            HStack {
                if history.loading { ProgressView().controlSize(.small); Text("Chargement des métadonnées…").font(.system(size: 11)) }
                Spacer()
                Button("Actualiser l’inventaire") { load(append: false) }.disabled(history.loading)
                if history.previousCursor != nil { Button("Page précédente") { load(direction: .previous) }.disabled(history.loading) }
                if history.cursor != nil { Button("Page suivante") { load(append: true) }.disabled(history.loading) }
            }
        }.padding(22).frame(width: 780, height: 600).preferredColorScheme(.light).renderGlass()
            .onAppear { load(append: false) }.onDisappear { history.cancel() }
    }
    private func load(append: Bool) { load(direction:append ? .next : .refresh) }
    private func load(direction: HistoryController.Direction) {
        history.load(job: job, direction: direction) { job, cursor, limit in
            await model.historyPage(for: job, cursor: cursor, limit: limit)
        }
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
                    RoundedRectangle(cornerRadius: 7).fill(.clear)
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
            .renderGlass(radius: 10, shadow: 2)
        }.buttonStyle(.plain)
    }

}
