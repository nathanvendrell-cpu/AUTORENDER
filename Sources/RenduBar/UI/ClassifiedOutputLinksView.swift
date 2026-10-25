import AppKit
import SwiftUI

/// One indexed metadata page for the selection. File locations are verified only on a user click.
struct ClassifiedOutputLinksView: View {
    @ObservedObject var model: MonitorModel
    let jobID: String
    @State private var records: [RenderLibraryRecord] = []
    @State private var cursors: [String?] = [nil]
    @State private var page = 0
    @State private var nextCursor: String?
    @State private var refresh: UInt64 = 0
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var working = false
    @State private var message = ""
    @State private var undoRecord: RenderLibraryRecord?
    @State private var operation: Task<Void, Never>?
    private var activity: RenderLibraryActivity? { model.libraryActivities.first { $0.id == jobID } }
    private var cursor: String? { cursors.indices.contains(page) ? cursors[page] : nil }
    private var requestKey: String { jobID + "|" + (cursor ?? "first") + "|" + String(refresh) + "|" + (activity.map { $0.state.rawValue + $0.detail } ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Fichiers de ce rendu").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Actualiser ces fichiers") { refresh &+= 1 }.font(.system(size: 11)).disabled(loading || working)
            }
            if let activity { Text(activity.detail).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary) }
            if loading { ProgressView("Lecture du journal…").controlSize(.small) }
            if records.isEmpty && !loading {
                Text("Aucun fichier classé enregistré pour cette sélection. Les liens source restent disponibles.")
                    .font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
            }
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(records) { record in fileRow(record) }
            }
            if page > 0 || nextCursor != nil {
                HStack {
                    Button("Précédent") { page -= 1 }.disabled(page == 0 || loading || working)
                    Text("Page \(page + 1) · \(records.count) fichiers").font(.system(size: 10)).monospacedDigit()
                    Button("Suivant") {
                        guard let nextCursor else { return }
                        cursors = Array(cursors.prefix(page + 1)); cursors.append(nextCursor); page += 1
                    }.disabled(nextCursor == nil || loading || working)
                }.font(.system(size: 11))
            }
            if !message.isEmpty { Text(message).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary).textSelection(.enabled) }
        }.padding(12).renderGlass(radius: 12, shadow: 2)
            .task(id: requestKey) { await loadMetadata() }
            .onChange(of: jobID) { cursors = [nil]; page = 0; records = []; nextCursor = nil; message = "" }
            .onDisappear { operation?.cancel() }
            .confirmationDialog("Annuler ce classement de fichier ?", isPresented: Binding(get: { undoRecord != nil }, set: { if !$0 { undoRecord = nil } }), titleVisibility: .visible) {
                if let record = undoRecord {
                    Button("Annuler cette opération uniquement") {
                        working = true
                        operation = Task {
                            let success = await model.undoLibraryRecord(record.id, approvedRecordID: record.id)
                            message = success ? "Annulation confirmée. Le lien source sera revérifié à l’ouverture." : "Annulation non confirmée ; consultez le journal."
                            working = false; undoRecord = nil; refresh &+= 1
                        }
                    }
                }
            } message: {
                if let record = undoRecord {
                    Text("Source : \(record.plan.candidate.originalRemotePath ?? record.plan.candidate.localFile.path)\nClassé : \(record.plan.target?.path ?? "Non confirmé")\nCette opération précise est la seule concernée.")
                }
            }
    }
    private func fileRow(_ record: RenderLibraryRecord) -> some View {
        let restored = record.state == .undone
        let available = restored || record.state == .moved || record.state == .copiedSourceKept
        return VStack(alignment: .leading, spacing: 5) {
            Text(restored ? record.plan.candidate.localFile.lastPathComponent : (record.plan.target?.lastPathComponent ?? record.plan.candidate.localFile.lastPathComponent))
                .font(.system(size: 12, weight: .semibold)).lineLimit(2)
            Text(record.state.displayTitle).font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
            if available {
                HStack {
                    if restored && record.remoteReturn != nil {
                        Button("Copier le chemin PC restauré") { copyRemoteSource(record) }
                    } else {
                        Button(restored ? "Ouvrir le dossier source" : "Ouvrir le dossier classé") { openFolder(record, restored: restored) }
                        Button(restored ? "Révéler le fichier source" : "Révéler ce fichier") { reveal(record) }
                    }
                    if !restored { Button("Annuler ce classement…") { undoRecord = record } }
                }.font(.system(size: 11)).disabled(working || model.libraryBusy)
            }
        }.padding(9).frame(maxWidth: .infinity, alignment: .leading).renderGlass(radius: 10, shadow: 1)
    }
    private func loadMetadata() async {
        let request = UUID(); requestID = request; loading = true
        defer { if requestID == request { loading = false } }
        let result = await model.libraryRecords(forJobID: jobID, cursor: cursor, limit: 50)
        guard !Task.isCancelled, requestID == request else { return }
        records = result.records; nextCursor = result.nextCursor
    }
    private func openFolder(_ record: RenderLibraryRecord, restored: Bool) {
        working = true
        operation = Task {
            defer { working = false }
            guard let location = await model.libraryLocation(forRecordID: record.id), !Task.isCancelled else { message = "Fichier non confirmé ; aucun dossier ouvert."; return }
            guard location.classified != restored, let file = location.fileURL else {
                message = location.remoteDisplay.map { "Source restaurée sur le PC : " + $0 } ?? "Le lien a changé. Actualisez les fichiers avant de l’ouvrir."; return
            }
            if !NSWorkspace.shared.open(file.deletingLastPathComponent()) { message = "Ouverture du dossier non confirmée." }
        }
    }
    private func reveal(_ record: RenderLibraryRecord) {
        working = true
        operation = Task { let success = await model.revealLibraryRecord(record.id); if !success { message = "Fichier non confirmé. Actualisez le journal." }; working = false }
    }
    private func copyRemoteSource(_ record: RenderLibraryRecord) {
        working = true
        operation = Task {
            defer { working = false }
            guard let location = await model.libraryLocation(forRecordID: record.id), !Task.isCancelled,
                  !location.classified, let path = location.remoteDisplay else { message = "Chemin source non confirmé."; return }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
            message = "Chemin PC restauré copié."
        }
    }
}
