import SwiftUI

struct CatalogHierarchyBrowser: View {
    @ObservedObject var store: CatalogHierarchyStore
    let projectID: String
    let selectedJobID: String?
    let selectJob: (String) -> Void
    var body: some View {
        let _ = store.generation
        let rows = store.index.rows(projectID: projectID)
        VStack(alignment: .leading, spacing: 6) {
            if store.rebuilding { ProgressView("Actualisation du classement…").controlSize(.small) }
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(rows) { row in
                    if row.kind == .page {
                        HStack {
                            Text("\(row.pageStart)–\(row.pageEnd) / \(row.count)").font(.system(size: 10)).monospacedDigit()
                            Spacer()
                            Button("Précédent") { store.turnPage(row.parentID, forward: false) }.disabled(!row.previousPage)
                            Button("Suivant") { store.turnPage(row.parentID, forward: true) }.disabled(!row.nextPage)
                        }.font(.system(size: 11)).padding(.leading, CGFloat(row.depth) * 14)
                    } else {
                        Button {
                            if let id = row.jobID { selectJob(id) } else { store.toggle(row.id) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: row.jobID != nil ? "film.stack" : (row.expanded ? "chevron.down" : "chevron.right"))
                                    .foregroundStyle(RenderStyle.blue).frame(width: 16)
                                Text(row.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                Spacer()
                                if row.jobID == nil { Text("\(row.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(RenderStyle.secondary) }
                                if row.activeCount > 0 { Circle().fill(.green).frame(width: 5, height: 5) }
                            }.padding(9).frame(maxWidth: .infinity, alignment: .leading)
                                .background(row.jobID == selectedJobID ? RenderStyle.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                .renderGlass(radius: 12, shadow: 2)
                        }.buttonStyle(.plain).padding(.leading, CGFloat(row.depth) * 14).help(row.title)
                    }
                }
            }
            if store.index.lastProjectionWasLimited {
                Text("Affichage limité à \(store.index.maximumRows) lignes. Fermez un groupe pour explorer les autres.")
                    .font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            }
        }.onChange(of: selectedJobID) { if let selectedJobID { store.reveal(selectedJobID) } }
    }
}
