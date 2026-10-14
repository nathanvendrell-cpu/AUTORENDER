import AppKit
import SwiftUI
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
