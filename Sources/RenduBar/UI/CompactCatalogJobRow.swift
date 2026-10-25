import SwiftUI
struct CompactCatalogJobRow: View {
    @ObservedObject var model: MonitorModel
    let archivePreferred: Bool
    let job: RenderDashboardJob
    let selected: Bool
    let hiddenFromFollow: Bool
    let onToggleHidden: () -> Void
    let onOpen: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    Button(action: onOpen) { CompactCatalogIndicator(job: job) }
                        .buttonStyle(.plain).help("Afficher le détail").accessibilityLabel("Afficher le détail de " + job.title)
                        .accessibilityValue((job.rawProgress?.percentLabel ?? "Progression indéterminée") + ", " + remainingLabel)
                    if let entry = compactPreviewEntry {
                        Group {
                            if let image = model.thumbnail(for: entry) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else {
                                Text(model.previewStatus(for: entry).label)
                                    .font(.system(size: 8)).foregroundStyle(RenderStyle.secondary)
                            }
                        }.frame(width: 72, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .help("Dernière image terminée · " + entry.filename)
                            .accessibilityLabel("Aperçu de la dernière image terminée : " + entry.filename)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    CatalogFolderName(name: job.versionLabel ?? job.title, targets: job.openTargets)
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text((hiddenFromFollow ? "Masqué de la liste · " : "") + RenderStatus.label(job) + " · " + job.source.rawValue)
                        .font(.system(size: 11)).foregroundStyle(RenderStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("Relevé : " + (job.observedAt?.formatted(date: .abbreviated, time: .shortened) ?? "date inconnue"))
                        .font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                    Text((job.source == .shadowMonitor ? "Brut · " : "") + (job.rawProgress?.countLabel ?? job.rawCount.flatMap { $0 >= 0 ? "\($0) détectés" : nil } ?? "Compteur indisponible"))
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    if let latest = job.latestOutput {
                        Text("Dernière sortie · " + latest.filename).font(.system(size: 10)).foregroundStyle(RenderStyle.secondary).lineLimit(1)
                    }
                    if let post = job.postProgress { Text("Post · " + post.countLabel).font(.system(size: 11)).monospacedDigit() }
                    if let progress = job.rawProgress { Text("Restant · \(progress.total - progress.completed)").font(.system(size: 11)).monospacedDigit() }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(remainingLabel).font(.system(size: 11)).foregroundStyle(RenderStyle.secondary)
                    if let timing = job.nativeFrameTiming, timing.sampleCount > 0,
                       timing.meanSeconds.isFinite, timing.meanSeconds > 0 {
                        Text("Vitesse · " + secondsLabel(timing.meanSeconds) + " s/image")
                            .font(.system(size: 10)).foregroundStyle(RenderStyle.secondary)
                            .monospacedDigit().help(timingHelp(timing))
                    }
                }
                Spacer(minLength: 8)
                Menu { rowActions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Actions de suivi de cette version").accessibilityLabel("Actions de " + job.title)
                CatalogFolderMenu(targets: job.openTargets, latest: job.latestOutput, revealURL: job.revealURL, label: "Dossiers et fichier de cette version", iconOnly: true)
                Button(action: onOpen) { Image(systemName: "arrow.right.circle") }
                    .buttonStyle(.plain).help("Afficher le détail de cette version").accessibilityLabel("Afficher la version " + job.title)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? RenderStyle.blue.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 12)).renderGlass(radius: 12, shadow: 2)
            .accessibilityElement(children: .contain)
            .contextMenu { rowActions }
            .task(id: compactPreviewRequestID) {
                model.setCompactPreview(compactPreviewEntry, forJobID: job.id)
            }
            .onDisappear { model.setCompactPreview(nil, forJobID: job.id) }
    }
    private var compactPreviewEntry: RenderEntry? {
        job.previewEntries.filter {
            $0.source == .macFolder && $0.monitorJobID == job.id &&
            $0.localPreviewProof?.jobID == job.id && $0.state != .pending &&
            ($0.filename as NSString).pathExtension.lowercased() == "png"
        }.max { $0.modified < $1.modified }
    }
    private var compactPreviewRequestID: String {
        job.id + "|" + String(model.compactPreviewVisible) + "|" +
            RenderPreviewRequest.fingerprint(entries: compactPreviewEntry.map { [$0] } ?? [])
    }
    private func secondsLabel(_ seconds: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "fr_FR"), seconds)
    }
    private func timingHelp(_ timing: RenderFrameTiming) -> String {
        var label = "Moyenne sur \(timing.sampleCount) images · " + timing.provenance
        if let latest = timing.latestSeconds, latest.isFinite, latest > 0 {
            label += " · Dernière image vérifiée : " + secondsLabel(latest) + " s"
        }
        return label
    }
    @ViewBuilder private var rowActions: some View {
        Button("Ouvrir dans le dashboard", action: onOpen)
        Divider()
        Button(hiddenFromFollow ? "Réafficher dans la liste" : "Masquer de la liste", action: onToggleHidden)
            .disabled(!hiddenFromFollow && CompactVisibility.isProtected(job))
        Divider()
        if job.isArchived || archivePreferred {
            Button("Désarchiver") { model.setJobArchived(false, forJobID: job.id) }
        } else {
            Button("Archiver ce rendu terminé") { model.setJobArchived(true, forJobID: job.id) }.disabled(!job.canArchive)
        }
    }
    private var remainingLabel: String {
        guard job.isFresh, !job.retainedHistorical, job.activity == .running,
              let seconds = job.estimatedRemainingSeconds, seconds.isFinite, seconds >= 0 else { return "Estimation indisponible" }
        if seconds < 60 { return String(format: "≈ %.0f s restantes", seconds) }
        if seconds < 3600 { return String(format: "≈ %.0f min restantes", ceil(seconds / 60)) }
        return String(format: "≈ %.0f h %.0f min restantes", floor(seconds / 3600), ceil(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }
}
